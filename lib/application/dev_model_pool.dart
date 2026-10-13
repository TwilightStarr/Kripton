// Görev 5/19 (Geliştirme Modu v2): model havuzu (otomatik seçim).
//
// Anahtarı olan her sağlayıcıda modelleri keşfeder, yalnızca ücretsiz olanları sağlık testinden geçirir ve
// rollere (analist, düzeltici, doğrulayıcı) atar. (sağlayıcı, model) başına cooldown, günlük kota parkı ve
// devre kesici tutar; limit/hata olunca [DevModelPool.pick] otomatik başka modele geçer.
//
// Model adları koda GÖMÜLMEZ: adaylar keşfedilir, sıralama ad/etiket/bağlam sezgisiyle yapılır.
// Ağ yok: [CloudModelService] enjekte edilir (testlerde sahte). Sırlar hiçbir çıktıda yer almaz; metinler
// SecretMask'ten geçer. Hiçbir public yöntem istisna fırlatmaz.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../data/atomic_file.dart';
import '../data/cloud_engine.dart';
import '../data/cloud_models.dart';
import '../data/secret_mask.dart';
import 'dev_guard.dart' show VerifierPolicy;
import 'dev_ledger.dart';

/// Havuz kimliği: `sağlayıcı:model` (ör. `groq:...`). [VerifierPolicy.providerOf] bu biçimi tanır.
String poolModelId(CloudProvider p, String model) => '${p.name}:$model';

/// Havuz kimliğinden sağlayıcıyı çıkarır; tanınmazsa null.
CloudProvider? poolProviderOf(String id) {
  final i = id.indexOf(':');
  if (i <= 0) return null;
  final n = id.substring(0, i);
  for (final p in CloudProvider.values) {
    if (p.name == n) return p;
  }
  return null;
}

/// Havuz kimliğinden ham model adını çıkarır (`openrouter:x/y:free` -> `x/y:free`).
String poolModelNameOf(String id) {
  final i = id.indexOf(':');
  return i <= 0 ? id : id.substring(i + 1);
}

/// Bir adayın ücretsiz olup olmadığı: OpenRouter'da yalnızca `:free` ile biten kimlikler; Gemini AI Studio
/// ve Groq için anahtarın ücretsiz katmanı geçerli sayılır (kota yoksa sağlık testi 429 `limit: 0` ile eler).
bool isFreeCandidate(CloudProvider p, String model) {
  if (p == CloudProvider.openrouter) return model.toLowerCase().endsWith(':free');
  return true;
}

// ------------------------------------------------------------------ sezgiler

/// Ad/etiket/bağlam tabanlı sıralama sezgileri. Belirli model adı içermez; yalnızca kalıplar.
class ModelHeuristics {
  const ModelHeuristics._();

  static final RegExp _params = RegExp(r'(?<![a-z0-9.])(\d+(?:\.\d+)?)b(?![a-z0-9])');
  // Sözcük sınırlı: `gemini` içindeki `mini` ya da `provider` içindeki `pro` yanlış eşleşmesin.
  static final RegExp _big = RegExp(
    r'(?<![a-z0-9])(pro|ultra|max|large|opus|sonnet|plus|reasoner|reasoning|thinking|r1)(?![a-z0-9])',
  );
  static final RegExp _small = RegExp(
    r'(?<![a-z0-9])(lite|mini|small|nano|tiny|micro|haiku|edge|instant)(?![a-z0-9])',
  );
  static final RegExp _unstable = RegExp(r'preview|experimental|(^|[-_/])exp($|[-_.:])');
  static final RegExp _poorFit = RegExp(
    r'gemma|learnlm|robotics|computer-use|compound|deep-research|vision|(^|[-_/])vl($|[-_.:])|(^|[-_/])ocr($|[-_.:])|translate|(^|[-_/])aya',
  );
  static final RegExp _code = RegExp(r'coder|codestral|devstral|starcoder|code|deepseek');

  static String _text(String model, String label) => '$model $label'.toLowerCase();

  /// Parametre sayısı (milyar); adda yoksa null. `a22b` gibi etkin-parametre ekleri yok sayılır.
  static double? paramsBillions(String model) {
    double? best;
    for (final m in _params.allMatches(model.toLowerCase())) {
      final v = double.tryParse(m.group(1)!);
      if (v != null && (best == null || v > best)) best = v;
    }
    return best;
  }

  /// Genel güç puanı (yaklaşık 0..8).
  static double strength(String model, {String label = ''}) {
    final t = _text(model, label);
    var s = 1.5;
    final b = paramsBillions(model);
    if (b != null) {
      s = 0.6 * (math.log(b + 1) / math.ln2);
      if (s > 5.5) s = 5.5;
    } else {
      if (_big.hasMatch(t)) s += 2.5;
      if (t.contains('flash')) s += 1.5;
    }
    if (b != null && _big.hasMatch(t)) s += 0.5;
    if (_small.hasMatch(t)) s -= 1.5;
    if (_unstable.hasMatch(t)) s -= 0.3;
    if (_poorFit.hasMatch(t)) s -= 3.0;
    return s;
  }

  /// Kod odaklılık puanı (0..3): coder/code/devstral..., "flash" hafif artı.
  static double codeAffinity(String model, {String label = ''}) {
    final t = _text(model, label);
    var s = 0.0;
    if (_code.hasMatch(t)) s += 2.0;
    if (t.contains('flash') && !t.contains('lite')) s += 0.8;
    if (t.contains('instruct') || t.contains('versatile')) s += 0.3;
    return s;
  }

  /// Bağlam puanı: `log2(bağlam / 8192)`, 0..7 aralığında. Bilinmeyen bağlam 8k sayılır.
  static double contextScore(int? tokens) {
    final c = (tokens == null || tokens <= 0) ? 8192 : tokens;
    final v = math.log(c / 8192) / math.ln2;
    return v < 0 ? 0 : (v > 7 ? 7 : v);
  }
}

// ------------------------------------------------------------------ aday ve durum

/// Havuzdaki tek aday (sağlayıcı + model).
class PoolModel {
  const PoolModel({
    required this.provider,
    required this.model,
    this.label = '',
    this.contextTokens,
  });

  final CloudProvider provider;
  final String model;
  final String label;
  final int? contextTokens;

  String get id => poolModelId(provider, model);

  @override
  String toString() => id;
}

/// Sağlık durumu.
enum PoolHealth { untested, verified, failed }

/// Devre kesici durumu.
enum PoolCircuit { closed, open, halfOpen }

/// Bir adayın şu anki kullanılabilirliği.
enum PoolAvailability { available, probe, cooldown, parked, circuitOpen, probing, blocked, dead }

/// [DevModelPool] eşikleri. Varsayılanlar üretim içindir; testler kısa değerler verir.
class DevPoolPolicy {
  const DevPoolPolicy({
    this.failureThreshold = 3,
    this.breakerOpenBase = const Duration(minutes: 2),
    this.breakerOpenMax = const Duration(minutes: 30),
    this.probeTimeout = const Duration(minutes: 3),
    this.transientCooldown = const Duration(seconds: 20),
    this.softCooldown = const Duration(seconds: 30),
    this.rateLimitDefault = const Duration(seconds: 60),
    this.rateLimitMax = const Duration(minutes: 15),
    this.minQuotaPark = const Duration(minutes: 5),
    this.authBlock = const Duration(hours: 2),
    this.notFoundBlock = const Duration(hours: 6),
    this.failedTestCooldown = const Duration(minutes: 5),
    this.testsPerProvider = 6,
    this.healthyTarget = 3,
    this.cacheTtl = const Duration(hours: 6),
    this.maxCandidatesPerProvider = 40,
  });

  /// Bu kadar ardışık (sayılan) hatadan sonra devre açılır.
  final int failureThreshold;
  final Duration breakerOpenBase;
  final Duration breakerOpenMax;

  /// Yarı-açık durumda verilen deneme isteğinin sonucu gelmezse bu süreden sonra yeni deneme verilir.
  final Duration probeTimeout;

  /// Sunucu/ağ/zaman aşımı/boş yanıt sonrası en kısa dinlendirme.
  final Duration transientCooldown;

  /// Geçersiz istek / güvenlik engeli gibi modelin sağlığını bozmayan hatalar sonrası dinlendirme.
  final Duration softCooldown;
  final Duration rateLimitDefault;
  final Duration rateLimitMax;

  /// Günlük kota parkının en kısa süresi (sıfırlanma saati hesabı bundan kısa çıkarsa).
  final Duration minQuotaPark;
  final Duration authBlock;
  final Duration notFoundBlock;
  final Duration failedTestCooldown;

  /// Keşifte sağlayıcı başına en çok sağlık testi ve hedeflenen sağlıklı aday sayısı.
  final int testsPerProvider;
  final int healthyTarget;

  /// Son-bilinen-iyi sağlık sonucunun yeniden test edilmeden geçerli sayıldığı süre.
  final Duration cacheTtl;
  final int maxCandidatesPerProvider;
}

/// Havuza bildirilen istek sonucu türü.
enum PoolOutcomeKind {
  success,
  rateLimit,
  dailyQuota,
  server,
  network,
  timeout,
  auth,
  notFound,
  badRequest,
  tooLarge,
  blocked,
  empty,

  /// Model çalıştı ama çıktısı kapılarca reddedildi: havuz durumu DEĞİŞMEZ (güveni [ModelTrust] izler).
  badOutput,
  other,
}

/// Bir isteğin sonucu: [DevModelPool.report] girdisi.
class PoolReport {
  PoolReport({
    required this.modelId,
    required this.kind,
    this.retryAfter,
    String message = '',
  }) : message = _clip(message);

  final String modelId;
  final PoolOutcomeKind kind;

  /// Sunucunun bildirdiği bekleme (Retry-After / retryDelay / sıfırlanma zamanı); yoksa null.
  final Duration? retryAfter;

  /// Redakte edilmiş kısa açıklama.
  final String message;

  PoolReport.success(String modelId) : this(modelId: modelId, kind: PoolOutcomeKind.success);

  /// HTTP durum kodundan sınıflandırır (engine'in hata sınıflandırmasıyla aynı mantık).
  /// [body] içindeki `X-RateLimit-Reset` (OpenRouter, epoch sn/ms) günlük sıfırlanma için kullanılır.
  factory PoolReport.fromHttp({
    required String modelId,
    required int status,
    String body = '',
    String? retryAfterHeader,
    DateTime? now,
  }) {
    final lower = body.toLowerCase();
    Duration? hint = parseCloudRetryAfter(body, header: retryAfterHeader);
    final reset = RegExp(r'x-ratelimit-reset"?\s*[:=]\s*"?(\d{10,13})').firstMatch(lower);
    if (reset != null) {
      final raw = int.tryParse(reset.group(1)!);
      if (raw != null) {
        final at = DateTime.fromMillisecondsSinceEpoch(raw >= 100000000000 ? raw : raw * 1000, isUtc: true);
        final d = at.difference((now ?? DateTime.now()).toUtc());
        if (!d.isNegative) hint = d;
      }
    }
    final PoolOutcomeKind kind;
    if (status == 429) {
      kind = isDailyQuotaBody(body) ? PoolOutcomeKind.dailyQuota : PoolOutcomeKind.rateLimit;
    } else if (status == 401 || status == 403) {
      kind = PoolOutcomeKind.auth;
    } else if (status == 404) {
      kind = PoolOutcomeKind.notFound;
    } else if (status == 413) {
      kind = PoolOutcomeKind.tooLarge;
    } else if (status == 400) {
      kind = PoolOutcomeKind.badRequest;
    } else if (status == 408) {
      kind = PoolOutcomeKind.timeout;
    } else if (status >= 500) {
      kind = PoolOutcomeKind.server;
    } else {
      kind = PoolOutcomeKind.other;
    }
    return PoolReport(modelId: modelId, kind: kind, retryAfter: hint, message: 'HTTP $status');
  }

  /// İstisnadan sınıflandırır (zaman aşımı, ağ; diğerleri `other`).
  factory PoolReport.fromError(String modelId, Object error) {
    final PoolOutcomeKind kind;
    if (error is TimeoutException) {
      kind = PoolOutcomeKind.timeout;
    } else if (error is SocketException || error is HandshakeException || error is HttpException) {
      kind = PoolOutcomeKind.network;
    } else {
      kind = PoolOutcomeKind.other;
    }
    return PoolReport(modelId: modelId, kind: kind, message: error.runtimeType.toString());
  }

  static String _clip(String s) {
    final r = SecretMask.redact(s).replaceAll(RegExp(r'\s+'), ' ').trim();
    return r.length <= 200 ? r : '${r.substring(0, 200)}…';
  }
}

/// [DevModelPool.pick] sonucu durumu.
enum PoolPickStatus {
  /// [PoolPick.model] kullanılabilir.
  ok,

  /// Adaylar var ama hepsi parkta/dinleniyor: [PoolPick.waitFor] kadar bekle (başarısız SAYMA).
  wait,

  /// Hiç aday yok (anahtar yok, keşif yapılmadı ya da hepsi elendi).
  none,
}

/// Rol için seçim sonucu.
class PoolPick {
  const PoolPick._(this.status, this.model, this.waitFor, this.reason, this.needsAttention, this.warnings);

  const PoolPick.ok(PoolModel model, {List<String> warnings = const []})
      : this._(PoolPickStatus.ok, model, null, '', false, warnings);

  const PoolPick.wait(Duration waitFor, String reason, {bool needsAttention = false})
      : this._(PoolPickStatus.wait, null, waitFor, reason, needsAttention, const []);

  const PoolPick.none(String reason) : this._(PoolPickStatus.none, null, null, reason, true, const []);

  final PoolPickStatus status;
  final PoolModel? model;

  /// Hepsi parktaysa EN KISA bekleme süresi.
  final Duration? waitFor;
  final String reason;

  /// true: bekleme kendiliğinden çözülmez (anahtar reddedildi, model kalktı); kullanıcıya bildir.
  final bool needsAttention;

  /// Örn. "model aynı rol/sağlayıcıyla çakıştı" uyarıları.
  final List<String> warnings;

  bool get ok => status == PoolPickStatus.ok;
}

/// Üç rolün atanması.
class RoleAssignment {
  const RoleAssignment({required this.analyst, required this.fixer, required this.verifier, this.warnings = const []});

  final PoolPick analyst;
  final PoolPick fixer;
  final PoolPick verifier;
  final List<String> warnings;

  bool get complete => analyst.ok && fixer.ok && verifier.ok;

  /// Üç rolde de aynı model mi (tek model durumu)?
  bool get singleModel =>
      complete && analyst.model!.id == fixer.model!.id && fixer.model!.id == verifier.model!.id;
}

/// Sağlayıcı başına keşif sonucu.
class ProviderDiscovery {
  const ProviderDiscovery({
    required this.provider,
    required this.kind,
    required this.message,
    this.listed = 0,
    this.free = 0,
    this.tested = 0,
    this.healthy = 0,
    this.fromCache = false,
  });

  final CloudProvider provider;
  final CloudCheckKind kind;
  final String message;
  final int listed;
  final int free;
  final int tested;
  final int healthy;
  final bool fromCache;
}

class PoolDiscovery {
  const PoolDiscovery(this.providers);

  final List<ProviderDiscovery> providers;

  int get healthy => providers.fold(0, (a, b) => a + b.healthy);
}

/// Arayüz/ günlük için bir adayın anlık görüntüsü.
class PoolModelStatus {
  const PoolModelStatus({
    required this.model,
    required this.health,
    required this.circuit,
    required this.availability,
    required this.consecutiveFailures,
    this.until,
    this.latencyMs,
  });

  final PoolModel model;
  final PoolHealth health;
  final PoolCircuit circuit;
  final PoolAvailability availability;
  final int consecutiveFailures;
  final DateTime? until;
  final int? latencyMs;
}

typedef PoolLog = void Function(String message, {String? modelId, bool warning});

class _Entry {
  _Entry(this.model);

  final PoolModel model;
  PoolHealth health = PoolHealth.untested;
  DateTime? testedAt;
  int? latencyMs;

  DateTime? cooldownUntil;
  DateTime? parkedUntil;
  DateTime? deadUntil;

  int failures = 0; // ardışık, devre kesiciye sayılan
  int rateHits = 0; // ardışık 429 (üstel geri çekilme)
  int openStreak = 0;
  PoolCircuit circuit = PoolCircuit.closed;
  DateTime? openUntil;
  DateTime? probeStartedAt;
}

// ------------------------------------------------------------------ havuz

/// Model havuzu. Ayrıntılar dosya başlığında.
class DevModelPool {
  DevModelPool({
    required this.service,
    required this.config,
    this.policy = const DevPoolPolicy(),
    this.trust,
    this.cacheFile,
    this.log,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
    math.Random? random,
    CloudRetryPolicy? retry,
  })  : _now = now ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed,
        _rnd = random ?? math.Random(),
        _retry = retry ?? const CloudRetryPolicy(jitter: 0);

  final CloudModelService service;

  /// Anahtarlar `config.providers[p]` altından okunur (`apiKey` + `enabled`).
  final CloudConfig config;
  final DevPoolPolicy policy;

  /// Görev 4 güven puanı ([DevLedger.trust]); sıralamaya girer. Havuz güveni GÜNCELLEMEZ (defter yapar).
  final ModelTrust? trust;

  /// Son-bilinen-iyi önbelleği (JSON, AtomicFile). null = kalıcılık yok. Sır içermez.
  final File? cacheFile;
  final PoolLog? log;

  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;
  final math.Random _rnd;
  final CloudRetryPolicy _retry;

  final Map<String, _Entry> _entries = <String, _Entry>{};
  final Map<CloudProvider, DateTime> _providerBlockedUntil = {};
  final Map<CloudProvider, String> _providerBlockReason = {};
  final Map<String, String> _assigned = <String, String>{};
  final Map<CloudProvider, DateTime> _listedAt = {};
  Future<void> _saveChain = Future<void>.value();

  /// Önbellek okunamadı/yazılamadı sayacı (havuz bellekte çalışmaya devam eder).
  int cacheFailures = 0;

  int get size => _entries.length;

  /// Kimliği verilen aday (yoksa null).
  PoolModel? modelById(String id) => _entries[id]?.model;

  void _note(String message, {String? modelId, bool warning = false}) {
    try {
      log?.call(SecretMask.redact(message), modelId: modelId, warning: warning);
    } catch (_) {}
  }

  bool _hasKey(CloudProvider p) {
    final c = config.providers[p];
    return c != null && c.enabled && c.apiKey.trim().isNotEmpty;
  }

  String _key(CloudProvider p) => config.providers[p]?.apiKey.trim() ?? '';

  // ------------------------------------------------------------ keşif

  /// Önbelleği yükler (varsa). Bozuk/eksik dosya sessizce yok sayılır.
  Future<void> load() async {
    final f = cacheFile;
    if (f == null) return;
    try {
      final raw = await AtomicFile.readJson(f.path);
      if (raw is! Map) return;
      final list = raw['models'];
      if (list is! List) return;
      final blocked = raw['blocked'];
      for (final e in list) {
        if (e is! Map) continue;
        final prov = _providerByName(e['p']);
        final name = e['m'];
        if (prov == null || name is! String || name.isEmpty) continue;
        if (!isFreeCandidate(prov, name)) continue;
        final label = e['l'];
        final ctx = e['c'];
        final entry = _Entry(PoolModel(
          provider: prov,
          model: name,
          label: label is String ? label : '',
          contextTokens: ctx is num ? ctx.toInt() : null,
        ));
        final h = e['h'];
        entry.health = h == 'ok'
            ? PoolHealth.verified
            : (h == 'fail' ? PoolHealth.failed : PoolHealth.untested);
        entry.testedAt = _date(e['t']);
        entry.latencyMs = e['lat'] is num ? (e['lat'] as num).toInt() : null;
        entry.parkedUntil = _future(e['park']);
        entry.cooldownUntil = _future(e['cool']);
        entry.deadUntil = _future(e['dead']);
        _entries[entry.model.id] = entry;
      }
      if (blocked is Map) {
        blocked.forEach((k, v) {
          final prov = _providerByName(k);
          final until = _future(v);
          if (prov != null && until != null) {
            _providerBlockedUntil[prov] = until;
            _providerBlockReason[prov] = 'önceki oturumdan bekleme';
          }
        });
      }
    } catch (_) {
      cacheFailures++;
    }
  }

  CloudProvider? _providerByName(Object? n) {
    for (final p in CloudProvider.values) {
      if (p.name == n) return p;
    }
    return null;
  }

  DateTime? _date(Object? v) {
    if (v is! String) return null;
    return DateTime.tryParse(v);
  }

  DateTime? _future(Object? v) {
    final d = _date(v);
    return (d != null && d.isAfter(_now())) ? d : null;
  }

  Future<void> _save() {
    final f = cacheFile;
    if (f == null) return Future<void>.value();
    final data = <String, Object?>{
      'v': 1,
      'models': [
        for (final e in _entries.values)
          {
            'p': e.model.provider.name,
            'm': e.model.model,
            if (e.model.label.isNotEmpty) 'l': e.model.label,
            if (e.model.contextTokens != null) 'c': e.model.contextTokens,
            'h': e.health == PoolHealth.verified ? 'ok' : (e.health == PoolHealth.failed ? 'fail' : 'new'),
            if (e.testedAt != null) 't': e.testedAt!.toUtc().toIso8601String(),
            if (e.latencyMs != null) 'lat': e.latencyMs,
            if (e.parkedUntil != null) 'park': e.parkedUntil!.toUtc().toIso8601String(),
            if (e.cooldownUntil != null) 'cool': e.cooldownUntil!.toUtc().toIso8601String(),
            if (e.deadUntil != null) 'dead': e.deadUntil!.toUtc().toIso8601String(),
          },
      ],
      'blocked': {
        for (final e in _providerBlockedUntil.entries) e.key.name: e.value.toUtc().toIso8601String(),
      },
    };
    _saveChain = _saveChain.then((_) async {
      try {
        await AtomicFile.writeJson(f.path, data);
      } catch (_) {
        cacheFailures++;
      }
    });
    return _saveChain;
  }

  /// Bir sağlayıcının önbellek/aday/bekleme durumunu siler (anahtar değişince çağır).
  void invalidateProvider(CloudProvider p) {
    _entries.removeWhere((_, e) => e.model.provider == p);
    _providerBlockedUntil.remove(p);
    _providerBlockReason.remove(p);
    _listedAt.remove(p);
    _assigned.removeWhere((_, id) => poolProviderOf(id) == p);
    unawaited(_save());
  }

  /// Anahtarı olan sağlayıcılarda modelleri listeler, ücretsizleri süzer, sezgiyle sıralar, ilk
  /// [DevPoolPolicy.testsPerProvider] adayı sağlık testinden geçirir. Sağlayıcılar paralel, bir sağlayıcının
  /// testleri sıralı ve [CloudProviderInfo.minGapMs] aralıklıdır. Hiçbir koşulda istisna fırlatmaz.
  Future<PoolDiscovery> discover({bool force = false}) async {
    final jobs = <Future<ProviderDiscovery>>[];
    for (final p in CloudProvider.values) {
      if (!_hasKey(p)) {
        _entries.removeWhere((_, e) => e.model.provider == p);
        continue;
      }
      jobs.add(_discoverProvider(p, force).catchError((Object e) {
        return ProviderDiscovery(
          provider: p,
          kind: CloudCheckKind.other,
          message: 'Keşif başarısız (${e.runtimeType}).',
        );
      }));
    }
    final out = await Future.wait(jobs);
    await _save();
    return PoolDiscovery(out);
  }

  Future<ProviderDiscovery> _discoverProvider(CloudProvider p, bool force) async {
    final key = _key(p);
    final listed = await service.fetchModels(p, key);
    if (!listed.ok) {
      if (listed.kind == CloudCheckKind.invalidKey) {
        _entries.removeWhere((_, e) => e.model.provider == p);
        _block(p, policy.authBlock, 'anahtar reddedildi');
        _note('${p.label}: anahtar geçersiz; sağlayıcı devre dışı.', warning: true);
        return ProviderDiscovery(provider: p, kind: listed.kind, message: SecretMask.redact(listed.message));
      }
      // Liste alınamadı (ağ/kota/5xx): son-bilinen-iyi adaylar korunur.
      final cached = _entries.values.where((e) => e.model.provider == p).length;
      _note('${p.label}: model listesi alınamadı (${listed.kind.name}); önbellekteki $cached aday kullanılacak.',
          warning: true);
      return ProviderDiscovery(
        provider: p,
        kind: listed.kind,
        message: SecretMask.redact(listed.message),
        free: cached,
        healthy: _entries.values
            .where((e) => e.model.provider == p && e.health == PoolHealth.verified)
            .length,
        fromCache: true,
      );
    }

    _listedAt[p] = _now();
    _providerBlockedUntil.remove(p);
    _providerBlockReason.remove(p);

    final fresh = <PoolModel>[];
    for (final m in listed.models) {
      if (!isFreeCandidate(p, m.id)) continue;
      fresh.add(PoolModel(provider: p, model: m.id, label: m.label, contextTokens: m.contextTokens));
    }
    // Listeden kalkan modeller (emekli) havuzdan çıkar.
    final freshIds = {for (final m in fresh) m.id};
    _entries.removeWhere((id, e) => e.model.provider == p && !freshIds.contains(id));
    for (final m in fresh) {
      final old = _entries[m.id];
      if (old == null) {
        _entries[m.id] = _Entry(m);
      } else {
        // bağlam/etiket güncellensin; durum korunur
        final e = _Entry(m)
          ..health = old.health
          ..testedAt = old.testedAt
          ..latencyMs = old.latencyMs
          ..cooldownUntil = old.cooldownUntil
          ..parkedUntil = old.parkedUntil
          ..deadUntil = old.deadUntil
          ..failures = old.failures
          ..rateHits = old.rateHits
          ..openStreak = old.openStreak
          ..circuit = old.circuit
          ..openUntil = old.openUntil
          ..probeStartedAt = old.probeStartedAt;
        _entries[m.id] = e;
      }
    }

    // Sezgisel ön sıralama: en umut verici adaylar önce test edilir.
    final ranked = _entries.values.where((e) => e.model.provider == p).toList()
      ..sort((a, b) => _compareGeneric(b.model, a.model));
    if (ranked.length > policy.maxCandidatesPerProvider) {
      for (final extra in ranked.sublist(policy.maxCandidatesPerProvider)) {
        _entries.remove(extra.model.id);
      }
      ranked.removeRange(policy.maxCandidatesPerProvider, ranked.length);
    }

    var tested = 0;
    var healthy = 0;
    for (final e in ranked) {
      final isFresh = !force &&
          e.health == PoolHealth.verified &&
          e.testedAt != null &&
          _now().difference(e.testedAt!) < policy.cacheTtl;
      if (isFresh) healthy++;
    }
    var providerBroken = false;
    for (final e in ranked) {
      if (providerBroken) break;
      if (healthy >= policy.healthyTarget || tested >= policy.testsPerProvider) break;
      final cachedOk = !force &&
          e.health == PoolHealth.verified &&
          e.testedAt != null &&
          _now().difference(e.testedAt!) < policy.cacheTtl;
      if (cachedOk) continue;
      if (tested > 0) {
        await _sleep(Duration(milliseconds: (p.minGapMs * 1.0).round()));
      }
      tested++;
      final r = await service.testModel(p, key, e.model.model);
      e.testedAt = _now();
      switch (r.kind) {
        case CloudCheckKind.ok:
          e.health = PoolHealth.verified;
          e.latencyMs = r.latencyMs;
          e.failures = 0;
          e.rateHits = 0;
          e.circuit = PoolCircuit.closed;
          e.cooldownUntil = null;
          e.parkedUntil = null;
          e.deadUntil = null;
          healthy++;
        case CloudCheckKind.quota:
          // Model var ama kotası dolu/yok: aday kalır, parkta (daha sonra devralabilir).
          e.health = PoolHealth.untested;
          _applyQuota(e, r.dailyQuota, r.retryAfter);
        case CloudCheckKind.invalidKey:
          providerBroken = true;
          _entries.removeWhere((_, x) => x.model.provider == p);
          _block(p, policy.authBlock, 'anahtar reddedildi');
          _note('${p.label}: anahtar test sırasında reddedildi.', warning: true);
        case CloudCheckKind.notFound:
          e.health = PoolHealth.failed;
          e.deadUntil = _now().add(policy.notFoundBlock);
        case CloudCheckKind.noKey:
        case CloudCheckKind.emptyList:
        case CloudCheckKind.network:
        case CloudCheckKind.timeout:
        case CloudCheckKind.other:
          e.health = PoolHealth.failed;
          e.cooldownUntil = _now().add(policy.failedTestCooldown);
          e.failures = 1;
      }
    }
    final total = _entries.values.where((e) => e.model.provider == p).length;
    final good = _entries.values.where((e) => e.model.provider == p && e.health == PoolHealth.verified).length;
    _note('${p.label}: ${listed.models.length} model listelendi, $total ücretsiz aday, $tested test, $good sağlıklı.');
    return ProviderDiscovery(
      provider: p,
      kind: providerBroken ? CloudCheckKind.invalidKey : CloudCheckKind.ok,
      message: providerBroken ? 'Anahtar reddedildi.' : 'Keşif tamam.',
      listed: listed.models.length,
      free: total,
      tested: tested,
      healthy: good,
    );
  }

  // ------------------------------------------------------------ sıralama

  /// Rolsüz genel sıralama (test sırası için): güç + hafif bağlam; eşitlikte bağlam sonra kimlik (yeni sürüm önde).
  int _compareGeneric(PoolModel a, PoolModel b) {
    final sa = ModelHeuristics.strength(a.model, label: a.label) + 0.2 * ModelHeuristics.contextScore(a.contextTokens);
    final sb = ModelHeuristics.strength(b.model, label: b.label) + 0.2 * ModelHeuristics.contextScore(b.contextTokens);
    final c = sa.compareTo(sb);
    if (c != 0) return c;
    return _tieBreak(a, b);
  }

  int _tieBreak(PoolModel a, PoolModel b) {
    final c = (a.contextTokens ?? 0).compareTo(b.contextTokens ?? 0);
    if (c != 0) return c;
    return a.id.compareTo(b.id);
  }

  /// Rol puanı (büyük = iyi). Güven puanı düşmüşse puan kırılır; doğrulanmamış aday hafif cezalıdır.
  double _roleScore(String role, _Entry e) {
    final m = e.model;
    final str = ModelHeuristics.strength(m.model, label: m.label);
    double s;
    if (role == DevRole.analyst) {
      s = ModelHeuristics.contextScore(m.contextTokens) * 1.0 + str * 0.8;
    } else if (role == DevRole.fixer) {
      s = str + ModelHeuristics.codeAffinity(m.model, label: m.label) * 1.5 +
          (ModelHeuristics.contextScore(m.contextTokens) >= 2 ? 0.3 : 0.0);
    } else {
      s = str + (RegExp(r'(?<![a-z0-9])(pro|reasoner|reasoning|thinking|r1)(?![a-z0-9])', caseSensitive: false).hasMatch(m.model) ? 0.5 : 0.0);
    }
    if (e.health == PoolHealth.untested) s -= 1.0;
    if (e.health == PoolHealth.failed) s -= 2.0;
    final t = trust;
    if (t != null) {
      final n = t.samples(m.id);
      if (n > 0) s -= 4.0 * t.rate(m.id) * (n >= 5 ? 1.0 : n / 5.0);
    }
    return s;
  }

  // ------------------------------------------------------------ kullanılabilirlik

  /// Adayın şu anki kullanılabilirliği. Birden çok engel varsa DURUM ve bitiş zamanı EN GEÇ biten engelindir
  /// (bekleme süresi, adayın gerçekten kullanılabilir olacağı ana göre hesaplanır).
  (PoolAvailability, DateTime?) _availability(_Entry e, DateTime now) {
    PoolAvailability? state;
    DateTime? latest;
    void consider(PoolAvailability a, DateTime? until) {
      if (until == null || !until.isAfter(now)) return;
      if (latest == null || until.isAfter(latest!)) {
        latest = until;
        state = a;
      }
    }

    consider(PoolAvailability.blocked, _providerBlockedUntil[e.model.provider]);
    consider(PoolAvailability.dead, e.deadUntil);
    consider(PoolAvailability.parked, e.parkedUntil);
    consider(PoolAvailability.cooldown, e.cooldownUntil);
    if (e.circuit == PoolCircuit.open) consider(PoolAvailability.circuitOpen, e.openUntil);
    if (e.circuit != PoolCircuit.closed) {
      final started = e.probeStartedAt;
      if (started != null) consider(PoolAvailability.probing, started.add(policy.probeTimeout));
    }
    if (state != null) return (state!, latest);
    // Açık süresi doldu: yarı-açık, tek deneme isteği verilir.
    if (e.circuit != PoolCircuit.closed) return (PoolAvailability.probe, null);
    return (PoolAvailability.available, null);
  }

  bool _usable(PoolAvailability a) => a == PoolAvailability.available || a == PoolAvailability.probe;

  /// [role] için en uygun sağlıklı adayı verir. [exclude]: kullanılmayacak model kimlikleri (sert).
  /// [differFrom]: genelde düzelticinin kimliği; doğrulayıcı için farklı SAĞLAYICI tercih edilir, aynı model
  /// yalnızca başka seçenek yoksa verilir. Başka rollere atanmış modeller yumuşak biçimde ikinci plana düşer.
  /// Güveni düşmüş ([ModelTrust.isDemoted]) modeller de yalnızca başka seçenek yoksa seçilir.
  /// Hepsi parktaysa [PoolPickStatus.wait] ve EN KISA bekleme süresi döner.
  PoolPick pick(String role, {Set<String> exclude = const {}, String? differFrom}) {
    try {
      return _pick(role, exclude, differFrom);
    } catch (e) {
      return PoolPick.none('Seçim hatası (${e.runtimeType}).');
    }
  }

  PoolPick _pick(String role, Set<String> exclude, String? differFrom) {
    final now = _now();
    final pool = _entries.values
        .where((e) => !exclude.contains(e.model.id) && _hasKey(e.model.provider))
        .toList();
    if (pool.isEmpty) {
      return const PoolPick.none('Havuzda aday yok: anahtar gir ya da modelleri keşfet.');
    }
    final usable = <_Entry>[];
    DateTime? soonest;
    var soonestAttention = false;
    var soonestReason = '';
    for (final e in pool) {
      final (a, until) = _availability(e, now);
      if (_usable(a)) {
        usable.add(e);
        continue;
      }
      if (until != null && (soonest == null || until.isBefore(soonest))) {
        soonest = until;
        soonestAttention = a == PoolAvailability.blocked || a == PoolAvailability.dead;
        soonestReason = switch (a) {
          PoolAvailability.blocked => '${e.model.provider.label}: ${_providerBlockReason[e.model.provider] ?? 'engelli'}',
          PoolAvailability.dead => 'model bulunamadı',
          PoolAvailability.parked => 'günlük kota doldu',
          PoolAvailability.cooldown => 'istek sınırı/dinlenme',
          PoolAvailability.circuitOpen => 'devre kesici açık',
          _ => 'deneme isteği sürüyor',
        };
      }
    }
    if (usable.isEmpty) {
      if (soonest == null) return const PoolPick.none('Kullanılabilir aday yok.');
      var wait = soonest.difference(now);
      if (wait < const Duration(seconds: 1)) wait = const Duration(seconds: 1);
      return PoolPick.wait(wait, 'Tüm modeller beklemede ($soonestReason).', needsAttention: soonestAttention);
    }

    final fixerProv = differFrom == null ? '' : VerifierPolicy.providerOf(differFrom);
    final taken = <String>{
      for (final r in _assigned.entries)
        if (r.key != role) r.value,
    };
    final demoted = trust?.demoted() ?? const <String>{};
    _Entry? best;
    var bestPenalty = 1 << 30;
    var bestScore = -1e9;
    for (final e in usable) {
      final id = e.model.id;
      var penalty = 0;
      if (differFrom != null && id.toLowerCase() == differFrom.trim().toLowerCase()) penalty += 8;
      if (role == DevRole.verifier && differFrom != null && VerifierPolicy.providerOf(id) == fixerProv) penalty += 4;
      if (taken.contains(id)) penalty += 2;
      if (demoted.contains(id)) penalty += 1;
      final score = _roleScore(role, e);
      final better = penalty < bestPenalty ||
          (penalty == bestPenalty &&
              (score > bestScore || (score == bestScore && best != null && _tieBreak(e.model, best.model) > 0)));
      if (better) {
        best = e;
        bestPenalty = penalty;
        bestScore = score;
      }
    }
    final chosen = best!;
    // yarı-açık deneme: yalnızca bir istek
    final (avail, _) = _availability(chosen, now);
    if (avail == PoolAvailability.probe) {
      chosen.circuit = PoolCircuit.halfOpen;
      chosen.probeStartedAt = now;
    }
    _assigned[role] = chosen.model.id;
    final warnings = <String>[];
    if (bestPenalty >= 8) {
      warnings.add('Tek model: ${chosen.model.id} hem düzeltici hem doğrulayıcı; ayrı istek ve ayrı sistem prompt\'u kullanılmalı.');
    } else if (role == DevRole.verifier && differFrom != null && bestPenalty >= 4) {
      warnings.add('Doğrulayıcı düzelticiyle aynı sağlayıcıda (${chosen.model.provider.label}); bağımsızlık sınırlı.');
    }
    return PoolPick.ok(chosen.model, warnings: warnings);
  }

  /// Üç rolü sırayla atar: analist -> düzeltici -> doğrulayıcı (doğrulayıcı düzelticiden farklı sağlayıcıdan
  /// tercihen). Tek sağlayıcı/tek model durumunda uyarı üretir. Rol atamaları sonraki [pick] çağrılarında
  /// çakışmayı önlemek için hatırlanır.
  RoleAssignment assign({Set<String> exclude = const {}}) {
    _assigned.clear();
    final analyst = pick(DevRole.analyst, exclude: exclude);
    final fixer = pick(DevRole.fixer, exclude: exclude);
    final verifier = pick(DevRole.verifier, exclude: exclude, differFrom: fixer.model?.id);
    final warnings = <String>[
      ...fixer.warnings,
      ...verifier.warnings,
    ];
    final a = analyst.model?.id, f = fixer.model?.id, v = verifier.model?.id;
    if (a != null && f != null && v != null) {
      if (a == f && f == v) {
        warnings.add('Havuzda tek model var: üç rol ayrı istek ve ayrı sistem prompt\'uyla aynı modeli kullanacak.');
      } else if (f == v) {
        warnings.add('Doğrulayıcı düzelticiyle aynı model; ayrı istek ve ayrı sistem prompt\'u şart.');
      } else if (a == f || a == v) {
        warnings.add('Analist başka bir rolle aynı modeli paylaşıyor.');
      }
      final providers = {VerifierPolicy.providerOf(a), VerifierPolicy.providerOf(f), VerifierPolicy.providerOf(v)};
      if (providers.length == 1 && !(a == f && f == v)) {
        warnings.add('Tek sağlayıcı: roller farklı modellere atandı ama sağlayıcı bağımsızlığı yok.');
      }
    }
    return RoleAssignment(analyst: analyst, fixer: fixer, verifier: verifier, warnings: warnings);
  }

  // ------------------------------------------------------------ durum makinesi

  /// Bir isteğin sonucunu işler. Bilinmeyen kimlikte false döner. Asla istisna fırlatmaz.
  bool report(PoolReport r) {
    try {
      return _report(r);
    } catch (_) {
      return false;
    }
  }

  bool _report(PoolReport r) {
    final e = _entries[r.modelId];
    if (e == null) return false;
    final now = _now();
    final wasHalfOpen = e.circuit == PoolCircuit.halfOpen;
    e.probeStartedAt = null;
    switch (r.kind) {
      case PoolOutcomeKind.success:
        e.failures = 0;
        e.rateHits = 0;
        e.openStreak = 0;
        e.circuit = PoolCircuit.closed;
        e.openUntil = null;
        e.cooldownUntil = null;
        e.parkedUntil = null;
        e.deadUntil = null;
        e.health = PoolHealth.verified;
        e.testedAt = now;
        // Çalışan istek, sağlayıcı bloğunu da kaldırır (anahtar düzeltilmiş olabilir).
        _providerBlockedUntil.remove(e.model.provider);
        _providerBlockReason.remove(e.model.provider);
        if (wasHalfOpen) _note('Devre kapandı: ${e.model.id}', modelId: e.model.id);
      case PoolOutcomeKind.rateLimit:
        e.rateHits++;
        final hinted = r.retryAfter;
        var wait = hinted ?? Duration(milliseconds: _retry.backoffMs(e.rateHits, _rnd));
        if (hinted == null && wait < policy.rateLimitDefault) wait = policy.rateLimitDefault;
        if (wait > policy.rateLimitMax) wait = policy.rateLimitMax;
        e.cooldownUntil = _later(e.cooldownUntil, now.add(wait));
        if (wasHalfOpen) {
          // Deneme isteği sınıra takıldı: devre açık kalır, sınır bitince yeniden denenir.
          e.circuit = PoolCircuit.open;
          e.openUntil = e.cooldownUntil;
        }
        _note('Sınır: ${e.model.id} ${wait.inSeconds} sn dinlenecek.', modelId: e.model.id);
      case PoolOutcomeKind.dailyQuota:
        _applyQuota(e, true, r.retryAfter);
        if (e.model.provider == CloudProvider.openrouter) {
          // OpenRouter ücretsiz günlük kota hesap geneli: tüm ':free' adaylar birlikte park edilir.
          for (final o in _entries.values) {
            if (o.model.provider == CloudProvider.openrouter && o.parkedUntil == null) {
              o.parkedUntil = e.parkedUntil;
            }
          }
        }
        if (wasHalfOpen) e.circuit = PoolCircuit.closed;
        _note('Günlük kota: ${e.model.id} ${e.parkedUntil?.toUtc().toIso8601String()} anına kadar park.',
            modelId: e.model.id, warning: true);
      case PoolOutcomeKind.server:
      case PoolOutcomeKind.network:
      case PoolOutcomeKind.timeout:
      case PoolOutcomeKind.empty:
      case PoolOutcomeKind.other:
        _countFailure(e, now, hint: r.retryAfter);
      case PoolOutcomeKind.auth:
        _block(e.model.provider, policy.authBlock, 'anahtar reddedildi');
        e.failures++;
        _note('${e.model.provider.label}: anahtar reddedildi; sağlayıcı ${policy.authBlock.inMinutes} dk park.',
            modelId: e.model.id, warning: true);
      case PoolOutcomeKind.notFound:
        e.deadUntil = now.add(policy.notFoundBlock);
        e.health = PoolHealth.failed;
        _note('Model bulunamadı: ${e.model.id}', modelId: e.model.id, warning: true);
      case PoolOutcomeKind.badRequest:
      case PoolOutcomeKind.blocked:
        e.cooldownUntil = _later(e.cooldownUntil, now.add(policy.softCooldown));
      case PoolOutcomeKind.tooLarge:
      case PoolOutcomeKind.badOutput:
        break; // sağlık değişmez; çağıran isteği küçültür / başka model ister
    }
    unawaited(_save());
    return true;
  }

  DateTime _later(DateTime? a, DateTime b) => (a != null && a.isAfter(b)) ? a : b;

  void _countFailure(_Entry e, DateTime now, {Duration? hint}) {
    e.failures++;
    var cool = policy.transientCooldown;
    if (hint != null && hint > cool) cool = hint;
    e.cooldownUntil = _later(e.cooldownUntil, now.add(cool));
    if (e.circuit == PoolCircuit.halfOpen || e.failures >= policy.failureThreshold) {
      e.openStreak++;
      var open = policy.breakerOpenBase * (1 << math.min(e.openStreak - 1, 10));
      if (open > policy.breakerOpenMax) open = policy.breakerOpenMax;
      e.circuit = PoolCircuit.open;
      e.openUntil = now.add(open);
      _note('Devre açıldı: ${e.model.id} (${open.inSeconds} sn).', modelId: e.model.id, warning: true);
    }
  }

  void _applyQuota(_Entry e, bool daily, Duration? retryAfter) {
    final now = _now();
    if (daily) {
      var until = quotaResetAt(e.model.provider, now);
      if (retryAfter != null && retryAfter >= const Duration(minutes: 10)) {
        until = now.add(retryAfter);
      }
      final min = now.add(policy.minQuotaPark);
      e.parkedUntil = until.isBefore(min) ? min : until;
    } else {
      e.cooldownUntil = _later(e.cooldownUntil, now.add(retryAfter ?? policy.rateLimitDefault));
    }
  }

  /// Günlük kotanın sıfırlanacağı en erken an. Groq/OpenRouter: 00:00 UTC. Gemini: gece yarısı Pasifik saati
  /// (yaz/kış saati belirsizliği için en erken değer olan 07:00 UTC; erken olursa yeniden park edilir).
  static DateTime quotaResetAt(CloudProvider p, DateTime now) {
    final u = now.toUtc();
    final hour = p == CloudProvider.gemini ? 7 : 0;
    var t = DateTime.utc(u.year, u.month, u.day, hour);
    if (!t.isAfter(u)) t = t.add(const Duration(days: 1));
    return t;
  }

  void _block(CloudProvider p, Duration d, String reason) {
    _providerBlockedUntil[p] = _now().add(d);
    _providerBlockReason[p] = reason;
  }

  /// Arayüz/günlük için tüm adayların anlık görüntüsü (rol puanından bağımsız, kimliğe göre sıralı).
  List<PoolModelStatus> snapshot() {
    final now = _now();
    final out = <PoolModelStatus>[];
    for (final e in _entries.values) {
      final (a, until) = _availability(e, now);
      out.add(PoolModelStatus(
        model: e.model,
        health: e.health,
        circuit: e.circuit,
        availability: a,
        consecutiveFailures: e.failures,
        until: until,
        latencyMs: e.latencyMs,
      ));
    }
    out.sort((a, b) => a.model.id.compareTo(b.model.id));
    return out;
  }

  /// Şu an kullanılabilir aday var mı (bekleme gerekmeden)?
  bool get hasUsable {
    final now = _now();
    return _entries.values.any((e) => _hasKey(e.model.provider) && _usable(_availability(e, now).$1));
  }
}
