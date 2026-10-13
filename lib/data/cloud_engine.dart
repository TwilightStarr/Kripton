// Değişiklik: yeni dosya. Bulut motoru: Gemini -> Groq -> OpenRouter otomatik yedekli LlmEngine +
// Gemini Google Arama ile araştırma. Yeni paket gerekmez (dart:io HttpClient).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../domain/entities.dart';
import 'chatml_parser.dart';
import 'crash_guard.dart';
import 'llm_engine.dart';
import 'secret_mask.dart';
import 'secret_store.dart';
import 'storage.dart';

/// Bulut modellerinin sahte "dosya yolu" öneki (örn. `cloud:auto`).
const String kCloudPathPrefix = 'cloud:';

/// Hibrit mod ve araştırma için kullanılan "otomatik bulut" modelinin kimliği.
const String kCloudAutoModelId = 'cloud-auto';

/// Bulut modelinin bağlam penceresi (token). Ücretsiz katman dakikalık token sınırlarına
/// takılmamak için bilinçli olarak mütevazı tutulur.
const int kCloudContextTokens = 24000;

/// Tüm sağlayıcılar kota beklerken tek bir üretimin en çok bekleyeceği süre.
const Duration kCloudMaxWait = Duration(minutes: 25);

/// Tek üretim için en çok sağlayıcı denemesi (sonsuz döngü koruması).
const int kCloudMaxAttempts = 14;

enum CloudProvider { gemini, groq, openrouter }

extension CloudProviderInfo on CloudProvider {
  String get label => switch (this) {
        CloudProvider.gemini => 'Gemini',
        CloudProvider.groq => 'Groq',
        CloudProvider.openrouter => 'OpenRouter',
      };

  /// Varsayılan model adı. Sağlayıcılar model adlarını değiştirebilir; Ayarlar'dan düzenlenebilir.
  String get defaultModel => switch (this) {
        CloudProvider.gemini => 'gemini-2.5-flash',
        CloudProvider.groq => 'llama-3.3-70b-versatile',
        CloudProvider.openrouter => 'meta-llama/llama-3.3-70b-instruct:free',
      };

  /// İstekler arası en kısa süre (ms): ücretsiz katman dakikalık istek sınırını aşmamak için.
  int get minGapMs => switch (this) {
        CloudProvider.gemini => 2500,
        CloudProvider.groq => 3000,
        CloudProvider.openrouter => 3500,
      };

  /// OpenAI uyumlu sağlayıcılarda üretim üst sınırı.
  int get maxOutputCap => switch (this) {
        CloudProvider.gemini => 60000,
        CloudProvider.groq => 8000,
        CloudProvider.openrouter => 8000,
      };

  String get keyHint => switch (this) {
        CloudProvider.gemini => 'aistudio.google.com → Get API key',
        CloudProvider.groq => 'console.groq.com → API Keys',
        CloudProvider.openrouter => 'openrouter.ai → Keys',
      };
}

CloudProvider? _providerById(String id) {
  for (final p in CloudProvider.values) {
    if (p.name == id) return p;
  }
  return null;
}

/// Model adındaki sık hataları temizler: baştaki/sondaki ve içteki boşluklar (NBSP, sıfır genişlikli
/// karakterler dahil), tırnaklar, `models/` öneki. Sağlayıcının bilinen model listesi ([known]) verilirse
/// büyük/küçük harf farkı listedeki yazıma çevrilir; liste yoksa küçük harfe indirilir (Gemini, Groq ve
/// OpenRouter model kimlikleri küçük harflidir). Sonuç boşsa boş metin döner; çağıran varsayılana düşer.
String normalizeModelName(String raw, {Iterable<String>? known}) {
  var s = raw.replaceAll(RegExp(r'[\s\u00A0\u200B\u200C\u200D\uFEFF]+'), '');
  s = s.replaceAll(RegExp('^["\'`]+|["\'`]+\$'), '');
  if (s.toLowerCase().startsWith('models/')) s = s.substring(7);
  if (s.isEmpty) return '';
  final lower = s.toLowerCase();
  if (known != null) {
    for (final k in known) {
      if (k.toLowerCase() == lower) return k;
    }
  }
  return lower;
}

class CloudProviderConfig {
  CloudProviderConfig({this.apiKey = '', required this.model, this.enabled = true});

  String apiKey;
  String model;
  bool enabled;

  bool get usable => enabled && apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  @override
  String toString() => 'CloudProviderConfig(model: $model, enabled: $enabled, key: ${SecretMask.placeholder})';

  /// Yalnızca sır OLMAYAN alanlar: API anahtarı JSON'a yazılmaz (güvenli depoda tutulur).
  Map<String, dynamic> toJson() => {'model': model, 'enabled': enabled};
}

/// Kalıcı bulut ayarları. Sır olmayan alanlar `cloud_config.json` içinde, API anahtarları güvenli depoda
/// ([SecretVault], anahtar adları `cloud.gemini` / `cloud.groq` / `cloud.openrouter`) durur.
class CloudConfig {
  CloudConfig._();

  /// Singleton olmayan, varsayılan değerli yeni örnek (testler ve yalıtılmış kullanım).
  CloudConfig.isolated();

  static final CloudConfig instance = CloudConfig._();

  static const String fileName = 'cloud_config.json';

  final Map<CloudProvider, CloudProviderConfig> providers = {
    for (final p in CloudProvider.values) p: CloudProviderConfig(model: p.defaultModel),
  };

  /// Otomatik modda deneme sırası.
  List<CloudProvider> order = [CloudProvider.gemini, CloudProvider.groq, CloudProvider.openrouter];

  /// Otonom modda hedef için Gemini + Google Arama ile araştırma yapılsın mı?
  bool research = true;

  /// Hibrit: önce yerel modeller; takılınca ve en sonda bulut son doğrulaması (otonom mod).
  bool hybrid = true;

  bool get anyUsable => providers.values.any((c) => c.usable);

  /// Güvenli depo kullanılamadığında doldurulur (arayüz gösterebilir); sorun yoksa null.
  SecretStoreUnavailable? secretStatus;

  /// Henüz güvenli depoya taşınamamış, eski JSON'da duran düz metin anahtarlar.
  final Map<CloudProvider, String> _legacyPlain = <CloudProvider, String>{};

  /// Taşınamayan eski düz metin diskte kaldıysa: sonraki başarılı kayıtta `.bak`/`.corrupt` kopyaları silinir.
  bool _needsPurge = false;

  /// Ayarları yükler. Eski JSON'da düz metin anahtar varsa güvenli depoya taşır: yaz → geri oku → aynı mı
  /// doğrula → ancak o zaman JSON'u sırsız yeniden yaz. Doğrulama başarısızsa eski JSON'a dokunulmaz ve
  /// anahtar yalnızca oturum belleğinde tutulur. Güvenli depo kullanılamıyorsa [SecretStoreUnavailable] döner.
  Future<SecretStoreUnavailable?> load([Storage? storage, SecretVault? vault]) async {
    final st = storage ?? Storage();
    final v = vault ?? SecretVault.instance;
    final legacy = <CloudProvider, String>{};
    try {
      final raw = await st.loadJson(fileName);
      if (raw is Map) {
        final prov = raw['providers'];
        if (prov is Map) {
          for (final p in CloudProvider.values) {
            final m = prov[p.name];
            if (m is! Map) continue;
            final c = providers[p]!;
            final key = m['key'];
            if (key is String && key.trim().isNotEmpty) {
              legacy[p] = key.trim();
              SecretMask.register(key.trim());
            }
            final modelRaw = m['model'];
            final model = normalizeModelName(modelRaw is String ? modelRaw : '');
            c.model = model.isEmpty ? p.defaultModel : model;
            c.enabled = m['enabled'] != false;
          }
        }
        final ord = raw['order'];
        if (ord is List) {
          final parsed = <CloudProvider>[];
          for (final e in ord) {
            final p = e is String ? _providerById(e) : null;
            if (p != null && !parsed.contains(p)) parsed.add(p);
          }
          for (final p in CloudProvider.values) {
            if (!parsed.contains(p)) parsed.add(p);
          }
          order = parsed;
        }
        research = raw['research'] != false;
        hybrid = raw['hybrid'] != false;
      }
    } catch (e, st2) {
      // Beklenmeyen biçim: varsayılanlarla devam; uygulama açılışta çökmez.
      CrashGuard.log('Bulut ayarları okunamadı', e, st2);
    }

    // Sırlar: güvenli depodan (JSON bozuk/eksik olsa bile) okunur; eski düz metin varsa taşınır.
    final failed = <String>[];
    var pendingPlain = false;
    _legacyPlain.clear();
    for (final p in CloudProvider.values) {
      final c = providers[p]!;
      final key = SecretKeys.cloud(p.name);
      final old = legacy[p] ?? '';
      try {
        if (old.isEmpty) {
          c.apiKey = ((await v.read(key)) ?? '').trim();
          if (c.apiKey.isNotEmpty && await v.isSessionOnly(key)) failed.add(key);
        } else {
          final persisted = ((await v.readPersisted(key)) ?? '').trim();
          if (persisted.isNotEmpty) {
            // Zaten taşınmış; JSON'daki eski kopya (ör. .bak'tan dönen) yalnızca silinecek.
            c.apiKey = ((await v.read(key)) ?? persisted).trim();
          } else {
            c.apiKey = old;
            if (!await v.write(key, old)) {
              failed.add(key);
              pendingPlain = true;
              _legacyPlain[p] = old;
            }
          }
        }
      } catch (e, st2) {
        CrashGuard.log('Bulut anahtarı okunamadı ($key)', e, st2);
        if (old.isNotEmpty) {
          c.apiKey = old;
          _legacyPlain[p] = old;
          pendingPlain = true;
        }
        failed.add(key);
      }
      SecretMask.register(c.apiKey);
    }

    if (legacy.isNotEmpty && !pendingPlain) {
      // Hepsi güvenli depoda doğrulandı: JSON'u sırsız yeniden yaz, eski düz metin kopyaları sil.
      try {
        await _writeJson(st);
        await purgeSecretFileCopies(st, fileName);
      } catch (e, st2) {
        CrashGuard.log('Bulut ayarları sırsız yeniden yazılamadı', e, st2);
      }
    } else if (legacy.isEmpty) {
      // Bozuk dosya kenara alınmışsa içinde eski düz metin anahtar parçası kalmış olabilir.
      await purgeSecretFileCopies(st, fileName, corruptOnly: true);
    }
    if (pendingPlain) _needsPurge = true;
    secretStatus = failed.isEmpty ? null : SecretStoreUnavailable(keys: failed);
    return secretStatus;
  }

  Future<void> _writeJson(Storage st) => st.saveJson(fileName, {
        'v': 2,
        'providers': {
          for (final e in providers.entries)
            e.key.name: {
              ...e.value.toJson(),
              // Yalnızca zaten diskte duran, taşınamamış ve değişmemiş eski anahtar korunur (yeni düz metin yazılmaz).
              if (_legacyPlain[e.key] != null && _legacyPlain[e.key] == e.value.apiKey.trim())
                'key': _legacyPlain[e.key],
            },
        },
        'order': [for (final p in order) p.name],
        'research': research,
        'hybrid': hybrid,
      });

  /// Ayarları kaydeder: anahtarlar güvenli depoya (yazıp doğrulayarak), geri kalanı JSON'a gider.
  /// Güvenli depo yazamazsa anahtar yalnızca bellekte kalır ve [SecretStoreUnavailable] döner.
  Future<SecretStoreUnavailable?> save([Storage? storage, SecretVault? vault]) async {
    final st = storage ?? Storage();
    final v = vault ?? SecretVault.instance;
    final failed = <String>[];
    for (final e in providers.entries) {
      final c = e.value;
      final key = SecretKeys.cloud(e.key.name);
      final value = c.apiKey.trim();
      SecretMask.register(value);
      try {
        if (value.isEmpty) {
          await v.delete(key);
          _legacyPlain.remove(e.key);
        } else if (await v.write(key, value)) {
          _legacyPlain.remove(e.key);
        } else {
          failed.add(key);
        }
      } catch (err, st2) {
        CrashGuard.log('Bulut anahtarı kaydedilemedi ($key)', err, st2);
        failed.add(key);
      }
    }
    try {
      await _writeJson(st);
      if (_legacyPlain.isEmpty && _needsPurge) {
        await purgeSecretFileCopies(st, fileName);
        _needsPurge = false;
      }
    } catch (e, st2) {
      CrashGuard.log('Bulut ayarları yazılamadı', e, st2);
    }
    CloudEngine.resetCooldowns(); // anahtar/model değişti: bekleme süreleri sıfırlanır
    secretStatus = failed.isEmpty ? null : SecretStoreUnavailable(keys: failed);
    return secretStatus;
  }
}

/// Yol bulut modeline mi ait?
bool isCloudPath(String? path) => path != null && path.startsWith(kCloudPathPrefix);

/// Uygulama modeli listesine eklenen bulut "modelleri" (indirme/silme gerektirmez).
List<GgufModel> cloudModels() => const [
      GgufModel(
        id: kCloudAutoModelId,
        name: 'Bulut: Otomatik (Gemini → Groq → OpenRouter)',
        family: 'Bulut',
        parameters: 'API',
        quantization: 'bulut',
        sizeGb: 0,
        ramGb: 0,
        tokensPerSec: 'ağa bağlı',
        quality: 'Kota dolunca sıradaki sağlayıcıya otomatik geçer',
        url: '',
        fileName: 'cloud-auto',
        template: ChatTemplate.chatml,
        localPath: 'cloud:auto',
      ),
      GgufModel(
        id: 'cloud-gemini',
        name: 'Bulut: Yalnızca Gemini',
        family: 'Bulut',
        parameters: 'API',
        quantization: 'bulut',
        sizeGb: 0,
        ramGb: 0,
        tokensPerSec: 'ağa bağlı',
        quality: 'Google AI Studio anahtarı',
        url: '',
        fileName: 'cloud-gemini',
        template: ChatTemplate.chatml,
        localPath: 'cloud:gemini',
      ),
      GgufModel(
        id: 'cloud-groq',
        name: 'Bulut: Yalnızca Groq',
        family: 'Bulut',
        parameters: 'API',
        quantization: 'bulut',
        sizeGb: 0,
        ramGb: 0,
        tokensPerSec: 'ağa bağlı',
        quality: 'Groq anahtarı',
        url: '',
        fileName: 'cloud-groq',
        template: ChatTemplate.chatml,
        localPath: 'cloud:groq',
      ),
      GgufModel(
        id: 'cloud-openrouter',
        name: 'Bulut: Yalnızca OpenRouter',
        family: 'Bulut',
        parameters: 'API',
        quantization: 'bulut',
        sizeGb: 0,
        ramGb: 0,
        tokensPerSec: 'ağa bağlı',
        quality: 'OpenRouter anahtarı',
        url: '',
        fileName: 'cloud-openrouter',
        template: ChatTemplate.chatml,
        localPath: 'cloud:openrouter',
      ),
    ];

final RegExp _wsRe = RegExp(r'\s');

/// Sağlayıcı hatasının sınıfı; bekleme (cooldown) politikasını belirler.
enum _Kind { rateLimit, server, network, timeout, auth, notFound, badRequest, tooLarge, blocked, empty, badResponse, other }

/// Yeniden deneme / zaman aşımı / geri çekilme ayarları. Varsayılanlar üretim içindir;
/// testler çok kısa değerlerle kendi politikasını verir.
class CloudRetryPolicy {
  const CloudRetryPolicy({
    this.maxAttempts = kCloudMaxAttempts,
    this.baseDelayMs = 15000,
    this.maxDelayMs = 10 * 60 * 1000,
    this.jitter = 0.2,
    this.minCooldownMs = 15000,
    this.minWaitMs = 500,
    this.paceScale = 1.0,
    this.maxWait = kCloudMaxWait,
    this.connectTimeout = const Duration(seconds: 30),
    this.headersTimeout = const Duration(seconds: 120),
    this.idleTimeout = const Duration(seconds: 120),
    this.errorBodyTimeout = const Duration(seconds: 20),
    this.maxStreamDuration = const Duration(minutes: 20),
    this.researchAttempts = 3,
  });

  /// Tek üretimde en çok sağlayıcı denemesi (sonsuz döngü koruması).
  final int maxAttempts;

  /// İlk ardışık başarısızlıktan sonraki bekleme (ms); her yeni başarısızlıkta ikiye katlanır.
  final int baseDelayMs;
  final int maxDelayMs;

  /// 0..1: beklemeye uygulanan rastgele sapma oranı (aynı anda başlayan istekler eşzamanlanmasın).
  final double jitter;

  /// Her hata sonrası sağlayıcının en az bu kadar (ms) dinlendirilmesi.
  final int minCooldownMs;

  /// Tüm sağlayıcılar beklemedeyken döngünün en kısa uyku süresi (ms).
  final int minWaitMs;

  /// Sağlayıcıların istek aralığı ([CloudProviderInfo.minGapMs]) çarpanı; 0 = aralık yok.
  final double paceScale;

  /// Tüm sağlayıcılar kota beklerken tek üretimin en çok bekleyeceği süre.
  final Duration maxWait;
  final Duration connectTimeout;
  final Duration headersTimeout;

  /// Akışta iki olay arasında izin verilen en uzun sessizlik.
  final Duration idleTimeout;
  final Duration errorBodyTimeout;

  /// Tek akışın toplam en uzun süresi (yavaş damlatan sunucuya karşı).
  final Duration maxStreamDuration;

  /// [cloudResearch] için en çok deneme.
  final int researchAttempts;

  /// [failures]. ardışık başarısızlıktan sonra beklenecek süre: `base * 2^(n-1)`, tavanlı, ± sapma.
  int backoffMs(int failures, math.Random rnd) {
    final n = failures < 1 ? 1 : (failures > 24 ? 24 : failures);
    final exp = math.min(maxDelayMs.toDouble(), baseDelayMs.toDouble() * (1 << (n - 1)));
    final j = jitter <= 0 ? 0.0 : exp * jitter * (rnd.nextDouble() * 2 - 1);
    final v = (exp + j).round();
    return v < 0 ? 0 : v;
  }
}

/// Bulut isteklerini dışarıdan iptal etmek için (ör. [cloudResearch]).
class CloudCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final ls = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final l in ls) {
      try {
        l();
      } catch (_) {}
    }
  }

  void _add(void Function() l) {
    if (_cancelled) {
      l();
    } else {
      _listeners.add(l);
    }
  }

  void _remove(void Function() l) => _listeners.remove(l);
}

/// Sağlayıcı hatası. Bekleme süresi: [fixedCoolMs] varsa o; yoksa max([hintMs], üstel geri çekilme).
class _CloudError implements Exception {
  _CloudError(this.message, this.kind, {this.hintMs, this.fixedCoolMs, this.emitted = 0, this.capTokens});

  final String message;
  final _Kind kind;

  /// Sunucunun bildirdiği bekleme (Retry-After / retryDelay); yoksa null.
  final int? hintMs;

  /// Düzeltilmeden geçmeyecek hatalar (anahtar, model adı, geçersiz istek) için sabit bekleme.
  final int? fixedCoolMs;

  /// Hatadan önce istemciye iletilen GÖRÜNÜR metin uzunluğu.
  final int emitted;

  /// Sağlayıcının bildirdiği çıktı (max_tokens) üst sınırı; varsa sonraki istekler bu değerle yapılır.
  final int? capTokens;

  @override
  String toString() => message;
}

/// Bir üretim/araştırma çalıştırması: iptal, açık HTTP istemcisi ve iptal edilebilir uyku.
class _CloudRun {
  bool cancelled = false;
  HttpClient? client;
  Timer? _sleepTimer;
  Completer<void>? _sleepDone;
  CloudCancelToken? _token;

  void attach(CloudCancelToken? token) {
    _token = token;
    token?._add(cancel);
  }

  void cancel() {
    cancelled = true;
    final c = client;
    client = null;
    if (c != null) {
      try {
        c.close(force: true);
      } catch (_) {}
    }
    _wake();
  }

  void _wake() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final d = _sleepDone;
    _sleepDone = null;
    if (d != null && !d.isCompleted) d.complete();
  }

  /// [ms] kadar bekler; iptalde hemen döner. Dinleyici/zamanlayıcı birikmez.
  Future<void> sleep(int ms) {
    if (cancelled || ms <= 0) return Future<void>.value();
    _wake();
    final done = Completer<void>();
    _sleepDone = done;
    _sleepTimer = Timer(Duration(milliseconds: ms), _wake);
    return done.future;
  }

  /// Çalıştırma bittiğinde kaynakları bırakır (idempotent).
  void dispose() {
    _wake();
    _token?._remove(cancel);
    _token = null;
    final c = client;
    client = null;
    if (c != null) {
      try {
        c.close(force: true);
      } catch (_) {}
    }
  }
}

/// Giden istek tanımı (sağlayıcıya göre kurulur).
class _CloudRequest {
  _CloudRequest(this.uri, this.headers, this.body);
  final Uri uri;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
}

/// TÜM bulut HTTP istekleri buradan geçer: bağlantı/başlık/gövde zaman aşımı, iptalde istemciyi
/// kapatma, 200 dışı yanıtı sınıflandırılmış [_CloudError]'a çevirme. İstisnaları normalize ETMEZ;
/// çağıran [CloudEngine._asCloudError] ile tek noktadan çevirir.
class _CloudHttp {
  _CloudHttp(this.policy, this.run);

  final CloudRetryPolicy policy;
  final _CloudRun run;

  Future<T> post<T>(
    CloudProvider pr,
    _CloudRequest r, {
    required Future<T> Function(HttpClientResponse res) onOk,
  }) async {
    final client = HttpClient()..connectionTimeout = policy.connectTimeout;
    run.client = client;
    try {
      if (run.cancelled) throw StateError('İstek iptal edildi.');
      final req = await client.postUrl(r.uri).timeout(policy.connectTimeout);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      r.headers.forEach(req.headers.set);
      final bytes = utf8.encode(jsonEncode(r.body));
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(policy.headersTimeout);
      if (res.statusCode != 200) {
        final body = await readBody(res, policy.errorBodyTimeout);
        throw CloudEngine._errorFor(pr, res.statusCode, body, res.headers);
      }
      return await onOk(res);
    } finally {
      if (identical(run.client, client)) run.client = null;
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  /// Gövdeyi sınırlı bellekle okur (bozuk UTF-8 hata vermez).
  static Future<String> readBody(HttpClientResponse res, Duration timeout, {int maxChars = 512 * 1024}) async {
    final b = StringBuffer();
    var n = 0;
    await for (final chunk in res.transform(const Utf8Decoder(allowMalformed: true)).timeout(timeout)) {
      final room = maxChars - n;
      if (room <= 0) break;
      b.write(chunk.length > room ? chunk.substring(0, room) : chunk);
      n += chunk.length;
    }
    return b.toString();
  }
}

/// Bulut API'lerine bağlanan motor. `cloud:auto` -> ayarlardaki sıra; `cloud:gemini|groq|openrouter` -> yalnızca o sağlayıcı.
class CloudEngine implements LlmEngine {
  CloudEngine({
    CloudConfig? config,
    CloudRetryPolicy policy = const CloudRetryPolicy(),
    Map<CloudProvider, Uri>? endpoints,
  })  : _config = config ?? CloudConfig.instance,
        _policy = policy,
        _endpoints = endpoints;

  final CloudConfig _config;
  final CloudRetryPolicy _policy;

  /// Sağlayıcı uç noktalarını değiştirir (testler: yerel sahte sunucu). Null = gerçek adresler.
  final Map<CloudProvider, Uri>? _endpoints;

  /// Sağlayıcı -> bu zamana (ms, epoch) kadar denenmez. Motor örnekleri arasında paylaşılır.
  static final Map<CloudProvider, int> _cool = {};
  static final Map<CloudProvider, int> _nextCallMs = {};

  /// Sağlayıcı -> ardışık başarısızlık sayısı (üstel geri çekilme); başarıda sıfırlanır.
  static final Map<CloudProvider, int> _fails = {};
  static final Map<CloudProvider, _Kind> _lastKind = {};

  /// Sağlayıcı -> hata mesajından öğrenilen çıktı token üst sınırı (402 bakiye / 429 OTPM).
  static final Map<CloudProvider, int> _outCap = {};
  static final math.Random _rnd = math.Random();

  static void resetCooldowns() {
    _cool.clear();
    _fails.clear();
    _lastKind.clear();
    _nextCallMs.clear();
    _outCap.clear();
  }

  String? _loaded;
  final Set<_CloudRun> _runs = <_CloudRun>{};
  int _active = 0;
  Completer<void> _idle = Completer<void>()..complete();

  /// Son başarılı üretimi yapan sağlayıcı (arayüz/günlük için).
  String? lastProviderLabel;

  @override
  String? get loadedPath => _loaded;

  @override
  int? get contextSize => _loaded == null ? null : kCloudContextTokens;

  @override
  int? get batchSize => null;

  @override
  Future<void> ensureLoaded(String path, {int? expectedBytes}) async {
    if (!isCloudPath(path)) {
      throw GenerationFailedException('Geçersiz bulut modeli yolu: $path', code: 'CLOUD_PATH');
    }
    _loaded = path;
  }

  @override
  Future<bool> waitNativeIdle(Duration timeout) async {
    if (_active == 0) return true;
    try {
      await _idle.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  void _enter() {
    if (_active++ == 0) _idle = Completer<void>();
  }

  void _exit() {
    if (--_active <= 0) {
      _active = 0;
      if (!_idle.isCompleted) _idle.complete();
    }
  }

  void _cancelAll() {
    for (final r in List<_CloudRun>.of(_runs)) {
      r.cancel();
    }
  }

  @override
  Future<void> stop() async {
    _cancelAll();
  }

  @override
  Future<void> dispose() async {
    _cancelAll();
    _loaded = null; // yeniden kullanılabilir (RoutingEngine boşaltma sözleşmesi)
  }

  List<CloudProvider> _orderFor(String path) {
    final id = path.substring(kCloudPathPrefix.length);
    final single = _providerById(id);
    if (single != null) return [single];
    return List<CloudProvider>.of(_config.order);
  }

  @override
  Stream<String> generate(String prompt, {int maxTokens = 1536}) {
    final run = _CloudRun();
    late StreamController<String> c;
    c = StreamController<String>(
      onListen: () {
        _enter();
        _runs.add(run);
        unawaited(
          _drive(run, c, prompt, maxTokens).catchError((Object e, StackTrace st) {
            // _drive kendi içinde her şeyi yakalar; buraya yalnızca beklenmeyen bir yarış düşer.
            CrashGuard.log('Bulut üretim (iç hata)', e.toString(), st);
          }),
        );
      },
      onCancel: () {
        run.cancel();
      },
    );
    return c.stream;
  }

  Future<void> _drive(_CloudRun run, StreamController<String> c, String prompt, int maxTokens) async {
    try {
      final path = _loaded;
      if (path == null) throw StateError('Bulut modeli seçilmedi.');
      final ChatMlParse parsed;
      try {
        parsed = parseChatMl(prompt, lenient: true);
      } on ChatMlFormatException catch (e) {
        throw GenerationFailedException(
          'Bulut için istem ChatML olarak ayrıştırılamadı: ${e.message}',
          code: 'CLOUD_CHATML',
        );
      }
      if (parsed.turns.isEmpty) {
        throw const GenerationFailedException('Bulut isteğinde kullanıcı mesajı yok.', code: 'CLOUD_EMPTY_PROMPT');
      }
      await _withFailover(run, c, parsed, maxTokens, _orderFor(path));
    } catch (e, st) {
      CrashGuard.log('Bulut üretim', e.toString(), st);
      if (!run.cancelled && !c.isClosed) {
        c.addError(
          e is GenerationFailedException
              ? e
              : GenerationFailedException(
                  'Bulut üretimi başarısız: ${SecretMask.redact(e.toString())}',
                  code: 'CLOUD_GENERATE',
                ),
          st,
        );
      }
    } finally {
      _runs.remove(run);
      run.dispose();
      _exit();
      if (!c.isClosed) {
        // Dinleyici duraklatılmışsa close() tamamlanmayabilir; üretimi bunun için bekletme.
        unawaited(c.close().catchError((Object _) {}));
      }
    }
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Her türlü istisnayı (ağ, TLS, zaman aşımı, bozuk veri, beklenmeyen) sınıflandırılmış hataya çevirir.
  static _CloudError _asCloudError(Object e) {
    if (e is _CloudError) return e;
    if (e is TimeoutException) return _CloudError('zaman aşımı', _Kind.timeout);
    if (e is SocketException) {
      return _CloudError('ağ hatası (${SecretMask.redact(e.message)})', _Kind.network);
    }
    if (e is TlsException) {
      return _CloudError('TLS hatası (${SecretMask.redact(e.message)})', _Kind.network);
    }
    if (e is HttpException) {
      return _CloudError('HTTP hatası (${SecretMask.redact(e.message)})', _Kind.network);
    }
    if (e is FormatException) {
      return _CloudError('bozuk yanıt (${SecretMask.redact(e.message)})', _Kind.badResponse);
    }
    return _CloudError('beklenmeyen hata (${SecretMask.redact(e.toString())})', _Kind.other);
  }

  /// Başarısızlığı kaydeder ve sağlayıcıyı üstel geri çekilmeyle dinlendirir.
  void _registerFailure(CloudProvider pr, _CloudError e) {
    final fails = (_fails[pr] ?? 0) + 1;
    _fails[pr] = fails;
    _lastKind[pr] = e.kind;
    final cool = e.fixedCoolMs ?? math.max(e.hintMs ?? 0, _policy.backoffMs(fails, _rnd));
    _cool[pr] = _nowMs() + math.max(_policy.minCooldownMs, cool);
  }

  Future<void> _withFailover(
    _CloudRun run,
    StreamController<String> c,
    ChatMlParse p,
    int maxTokens,
    List<CloudProvider> order,
  ) async {
    final startedAt = _nowMs();
    final errors = <String>[];
    var attempts = 0;
    while (true) {
      if (run.cancelled) return;
      final now = _nowMs();
      CloudProvider? pick;
      for (final pr in order) {
        final cfg = _config.providers[pr];
        if (cfg == null || !cfg.usable) continue;
        if ((_cool[pr] ?? 0) <= now) {
          pick = pr;
          break;
        }
      }
      if (pick == null) {
        final usable = [
          for (final pr in order)
            if (_config.providers[pr]?.usable ?? false) pr,
        ];
        if (usable.isEmpty) {
          throw const GenerationFailedException(
            'Hiçbir bulut sağlayıcı için API anahtarı girilmemiş. Geliştirme Modu → Bulut ayarları bölümünden anahtar ekle.',
            code: 'CLOUD_NO_KEY',
          );
        }
        var soonest = _cool[usable.first] ?? 0;
        for (final pr in usable) {
          soonest = math.min(soonest, _cool[pr] ?? 0);
        }
        final waitMs = math.max(_policy.minWaitMs, soonest - now);
        if (now - startedAt + waitMs > _policy.maxWait.inMilliseconds) {
          final allAuth = usable.every((pr) => _lastKind[pr] == _Kind.auth);
          final last = errors.isEmpty ? 'bilgi yok' : errors.last;
          throw allAuth
              ? GenerationFailedException(
                  'Bulut API anahtarı reddedildi ($last). Anahtarı Bulut ayarlarından kontrol et.',
                  code: 'CLOUD_AUTH',
                )
              : GenerationFailedException(
                  'Tüm bulut sağlayıcıların kotası dolu görünüyor ($last). '
                  'Daha sonra yeniden dene veya başka bir sağlayıcı anahtarı ekle.',
                  code: 'CLOUD_QUOTA',
                );
        }
        CrashGuard.log('Bulut', 'Tüm sağlayıcılar beklemede; ${(waitMs / 1000).ceil()} sn bekleniyor', null);
        await run.sleep(waitMs);
        continue;
      }
      if (++attempts > _policy.maxAttempts) {
        throw GenerationFailedException(
          'Bulut üretimi ${_policy.maxAttempts} denemede başarısız: ${errors.isEmpty ? 'bilinmeyen hata' : errors.last}',
          code: 'CLOUD_ATTEMPTS',
        );
      }
      try {
        await _call(run, c, pick, p, maxTokens);
        if (run.cancelled) return;
        _fails[pick] = 0;
        _lastKind.remove(pick);
        if (lastProviderLabel != pick.label) {
          CrashGuard.log('Bulut', 'Sağlayıcı: ${pick.label} (${_config.providers[pick]?.model})', null);
        }
        lastProviderLabel = pick.label;
        return;
      } catch (e) {
        if (run.cancelled) return;
        final ce = _asCloudError(e);
        _registerFailure(pick, ce);
        final learned = ce.capTokens;
        if (learned != null) {
          final prev = _outCap[pick];
          if (prev == null || learned < prev) {
            _outCap[pick] = learned;
            attempts = math.max(0, attempts - 1); // sınır öğrenildi: bu deneme sayılmaz, hemen yeniden denenir
          }
        }
        errors.add('${pick.label}: ${ce.message}');
        CrashGuard.log('Bulut hata', '${pick.label}: ${ce.message}', null);
        if (ce.emitted > 0) {
          // Metin kısmen iletildi: başka sağlayıcıyla sürdürmek çıktıyı bozar; üst katman yeniden dener.
          throw GenerationFailedException(
            'Bulut akışı yarıda kesildi (${pick.label}): ${ce.message}',
            code: 'CLOUD_MIDSTREAM',
          );
        }
      }
    }
  }

  /// Sağlayıcı istekleri arasında asgari aralık (ücretsiz katman dakikalık istek sınırı).
  Future<void> _pace(_CloudRun run, CloudProvider pr) async {
    final now = _nowMs();
    final at = _nextCallMs[pr] ?? 0;
    _nextCallMs[pr] = math.max(now, at) + (pr.minGapMs * _policy.paceScale).round();
    if (at > now) await run.sleep(at - now);
  }

  Uri _endpointFor(CloudProvider pr, CloudProviderConfig cfg) {
    final o = _endpoints?[pr];
    if (o != null) return o;
    return switch (pr) {
      CloudProvider.gemini => Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/${cfg.model.trim()}:streamGenerateContent?alt=sse',
        ),
      CloudProvider.groq => Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
      CloudProvider.openrouter => Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
    };
  }

  _CloudRequest _buildRequest(CloudProvider pr, CloudProviderConfig cfg, ChatMlParse p, int maxTokens) {
    final Uri uri;
    try {
      uri = _endpointFor(pr, cfg);
    } on FormatException catch (e) {
      throw _CloudError(
        'geçersiz model adı/adres (${SecretMask.redact(e.message)})',
        _Kind.badRequest,
        fixedCoolMs: 5 * 60 * 1000,
      );
    }
    return pr == CloudProvider.gemini ? _geminiRequest(uri, cfg, p, maxTokens) : _openAiRequest(uri, pr, cfg, p, maxTokens);
  }

  Future<void> _call(
    _CloudRun run,
    StreamController<String> c,
    CloudProvider pr,
    ChatMlParse p,
    int maxTokens,
  ) async {
    final cfg = _config.providers[pr];
    if (cfg == null) throw _CloudError('sağlayıcı ayarı yok', _Kind.other, fixedCoolMs: 60 * 60 * 1000);
    SecretMask.register(cfg.apiKey);
    await _pace(run, pr);
    if (run.cancelled) return;
    final req = _buildRequest(pr, cfg, p, maxTokens);
    await _CloudHttp(_policy, run).post<void>(pr, req, onOk: (res) => _consume(run, c, pr, res));
  }

  /// SSE akışını okur ve metni [c]'ye iletir. Boş/bozuk yanıtı sınıflandırılmış hataya çevirir.
  Future<void> _consume(_CloudRun run, StreamController<String> c, CloudProvider pr, HttpClientResponse res) async {
    var visible = 0; // boşluk dışı karakter sayısı: yalnızca boşluktan oluşan yanıt "boş" sayılır
    final nonSse = StringBuffer(); // SSE olmayan gövde (düz JSON hata/yanıt) tanılama ve kurtarma için
    final watch = Stopwatch()..start();

    var pendingWs = ''; // baştaki boşluklar, görünür metin gelene dek tutulur (boş yanıt temiz sayılsın)
    void emit(String text) {
      if (text.isEmpty) return;
      final v = text.replaceAll(_wsRe, '').length;
      if (visible == 0 && v == 0) {
        if (pendingWs.length < 4096) pendingWs += text;
        return;
      }
      visible += v;
      final out = pendingWs.isEmpty ? text : '$pendingWs$text';
      pendingWs = '';
      if (!run.cancelled && !c.isClosed) c.add(out);
    }

    try {
      final lines = res.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter());
      await for (final line in lines.timeout(_policy.idleTimeout)) {
        if (run.cancelled) return;
        if (watch.elapsed > _policy.maxStreamDuration) {
          throw _CloudError('akış çok uzun sürdü', _Kind.timeout, emitted: visible);
        }
        final data = _sseData(line);
        if (data == null) {
          if (nonSse.length < 8192 && line.trim().isNotEmpty && !line.startsWith(':')) nonSse.writeln(line);
          continue;
        }
        if (data == '[DONE]') break;
        Object? j;
        try {
          j = jsonDecode(data);
        } catch (_) {
          continue; // bozuk/yarım satır
        }
        if (j is! Map) continue;
        if (j['error'] != null) {
          throw CloudEngine._errorFor(pr, _errCode(j['error']), jsonEncode(j), null, emitted: visible);
        }
        final text = _textOf(pr, j);
        if (text.isNotEmpty) {
          emit(text);
        } else if (pr == CloudProvider.gemini) {
          final block = _geminiBlock(j);
          if (block != null) {
            throw _CloudError(block, _Kind.blocked, hintMs: 20000, emitted: visible);
          }
        }
      }
    } on TimeoutException {
      throw _CloudError('akış zaman aşımı', _Kind.timeout, emitted: visible);
    } on SocketException catch (e) {
      if (run.cancelled) return;
      throw _CloudError('bağlantı koptu (${SecretMask.redact(e.message)})', _Kind.network, emitted: visible);
    } on HttpException catch (e) {
      if (run.cancelled) return;
      throw _CloudError('bağlantı koptu (${SecretMask.redact(e.message)})', _Kind.network, emitted: visible);
    } on TlsException catch (e) {
      if (run.cancelled) return;
      throw _CloudError('TLS hatası (${SecretMask.redact(e.message)})', _Kind.network, emitted: visible);
    }
    if (run.cancelled) return;
    if (visible == 0 && nonSse.isNotEmpty) {
      // Sunucu SSE yerine düz JSON döndürmüş olabilir (hata gövdesi veya tek parça yanıt).
      _recoverPlainJson(pr, nonSse.toString(), emit, visible);
    }
    if (visible == 0) {
      final hint = nonSse.isEmpty ? '' : ' (${SecretMask.redact(_briefBody(nonSse.toString()))})';
      throw _CloudError('boş yanıt$hint', _Kind.empty, hintMs: 20000);
    }
  }

  /// Düz JSON gövdeden hata fırlatır veya metni [emit] ile iletir; tanınmazsa sessizce döner.
  static void _recoverPlainJson(CloudProvider pr, String raw, void Function(String) emit, int emittedSoFar) {
    Object? j;
    try {
      j = jsonDecode(raw.trim());
    } catch (_) {
      return;
    }
    final items = j is List ? j : <Object?>[j];
    for (final it in items) {
      if (it is! Map) continue;
      if (it['error'] != null) {
        throw CloudEngine._errorFor(pr, _errCode(it['error']), jsonEncode(it), null, emitted: emittedSoFar);
      }
      final t = _textOf(pr, it);
      if (t.isNotEmpty) emit(t);
    }
  }

  static String _textOf(CloudProvider pr, Map j) => pr == CloudProvider.gemini ? _geminiText(j) : _openAiText(j);

  static String? _sseData(String line) {
    if (!line.startsWith('data:')) return null; // yorum (": ...") ve boş satırlar
    final d = line.substring(5).trim();
    return d.isEmpty ? null : d;
  }

  static int _errCode(Object? err) {
    if (err is Map) {
      final c = err['code'];
      if (c is num) return c.toInt();
      if (c is String) return int.tryParse(c) ?? 500;
    }
    return 500;
  }

  _CloudRequest _geminiRequest(Uri uri, CloudProviderConfig cfg, ChatMlParse p, int maxTokens) {
    final body = <String, dynamic>{
      'contents': [
        for (final t in p.turns)
          {
            'role': t.role == ChatMlRole.assistant ? 'model' : 'user',
            'parts': [
              {'text': t.text},
            ],
          },
      ],
      'generationConfig': {
        'maxOutputTokens': math.min(CloudProvider.gemini.maxOutputCap, maxTokens + 4096),
        'temperature': 0.2,
      },
    };
    final sys = p.system;
    if (sys != null && sys.trim().isNotEmpty) {
      body['systemInstruction'] = {
        'parts': [
          {'text': sys},
        ],
      };
    }
    return _CloudRequest(uri, {'x-goog-api-key': cfg.apiKey.trim()}, body);
  }

  _CloudRequest _openAiRequest(Uri uri, CloudProvider pr, CloudProviderConfig cfg, ChatMlParse p, int maxTokens) {
    final body = <String, dynamic>{
      'model': cfg.model.trim(),
      'stream': true,
      'temperature': 0.2,
      'max_tokens': math.min(math.min(pr.maxOutputCap, _outCap[pr] ?? pr.maxOutputCap), maxTokens),
      'messages': [
        for (final m in p.messages) {'role': m.role.name, 'content': m.text},
      ],
    };
    final headers = <String, String>{'Authorization': 'Bearer ${cfg.apiKey.trim()}'};
    if (pr == CloudProvider.openrouter) {
      headers['X-Title'] = 'Kripton';
    }
    return _CloudRequest(uri, headers, body);
  }

  static String _geminiText(Map j) {
    final cands = j['candidates'];
    if (cands is! List || cands.isEmpty) return '';
    final first = cands.first;
    if (first is! Map) return '';
    final content = first['content'];
    if (content is! Map) return '';
    final parts = content['parts'];
    if (parts is! List) return '';
    final b = StringBuffer();
    for (final part in parts) {
      if (part is! Map) continue;
      if (part['thought'] == true) continue; // düşünce özetleri çıktıya karışmaz
      final t = part['text'];
      if (t is String) b.write(t);
    }
    return b.toString();
  }

  /// Gemini isteği/yanıtı güvenlik nedeniyle engellediyse açıklama; yoksa null.
  static String? _geminiBlock(Map j) {
    final fb = j['promptFeedback'];
    if (fb is Map && fb['blockReason'] != null) return 'istek engellendi (${fb['blockReason']})';
    final cands = j['candidates'];
    if (cands is List && cands.isNotEmpty && cands.first is Map) {
      final fr = (cands.first as Map)['finishReason'];
      if (fr is String && (fr == 'SAFETY' || fr == 'RECITATION' || fr == 'PROHIBITED_CONTENT')) {
        return 'yanıt engellendi ($fr)';
      }
    }
    return null;
  }

  static String _openAiText(Map j) {
    final ch = j['choices'];
    if (ch is! List || ch.isEmpty) return '';
    final first = ch.first;
    if (first is! Map) return '';
    final delta = first['delta'];
    if (delta is Map && delta['content'] is String) return delta['content'] as String;
    final message = first['message']; // akışsız (düz JSON) yanıt
    if (message is Map && message['content'] is String) return message['content'] as String;
    return '';
  }

  /// HTTP durum koduna göre hatayı sınıflandırır ve sağlayıcının ne kadar dinlendirileceğini belirler.
  static _CloudError _errorFor(
    CloudProvider pr,
    int status,
    String body,
    HttpHeaders? headers, {
    int emitted = 0,
  }) {
    final brief = _briefBody(body);
    final lower = body.toLowerCase();
    final cap = _capHint(body);
    String msg;
    _Kind kind;
    int? hint;
    int? fixed;
    if (status == 429) {
      final daily = lower.contains('perday') || lower.contains('per day') || lower.contains('daily');
      kind = _Kind.rateLimit;
      if (daily) {
        fixed = 30 * 60 * 1000;
      } else {
        hint = _retryAfterMs(body, headers);
      }
      msg = 'kota/sınır (429): $brief';
    } else if (status == 401 || status == 403) {
      kind = _Kind.auth;
      fixed = 6 * 60 * 60 * 1000;
      msg = 'anahtar reddedildi ($status): $brief';
    } else if (status == 404) {
      kind = _Kind.notFound;
      fixed = 6 * 60 * 60 * 1000;
      msg = 'model/uç nokta bulunamadı (404): model adını kontrol et. $brief';
    } else if (status == 413) {
      kind = _Kind.tooLarge;
      fixed = 60 * 1000;
      msg = 'istek çok büyük (413): $brief';
    } else if (status == 400) {
      kind = _Kind.badRequest;
      fixed = 5 * 60 * 1000;
      msg = 'geçersiz istek (400): $brief';
    } else if (status == 408) {
      kind = _Kind.timeout;
      msg = 'sunucu zaman aşımı (408): $brief';
    } else if (status >= 500) {
      kind = _Kind.server;
      hint = _retryAfterMs(body, headers);
      msg = 'sunucu hatası ($status): $brief';
    } else {
      kind = _Kind.other;
      fixed = 60 * 1000;
      msg = 'HTTP $status: $brief';
    }
    if (cap != null) {
      // Sınır düzeltilebilir bir hata: bekleme yok, düşürülmüş max_tokens ile hemen yeniden denenir.
      hint = null;
      fixed = 0;
      msg = '$msg → çıktı sınırı $cap token\'a indirilecek';
    }
    return _CloudError(SecretMask.redact(msg), kind, hintMs: hint, fixedCoolMs: fixed, emitted: emitted, capTokens: cap);
  }

  /// Hata gövdesinden güvenli bir `max_tokens` değeri çıkarır; yoksa null.
  ///  * OpenRouter 402: "... can only afford 1599" -> bakiyenin ~%90'ı
  ///  * Groq 429 OTPM: "output tokens per minute (OTPM): Limit 1000" -> limitin %80'i (1000 -> 800)
  static int? _capHint(String body) {
    final afford = RegExp(r'can only afford (\d+)', caseSensitive: false).firstMatch(body);
    if (afford != null) {
      final n = int.tryParse(afford.group(1)!);
      if (n != null && n > 0) return math.max(64, (n * 0.9).floor());
    }
    final otpm = RegExp(r'output tokens per minute[^:]*:\s*Limit\s*(\d+)', caseSensitive: false).firstMatch(body);
    if (otpm != null) {
      final n = int.tryParse(otpm.group(1)!);
      if (n != null && n > 0) return math.max(64, (n * 0.8).floor());
    }
    return null;
  }

  static int? _retryAfterMs(String body, HttpHeaders? headers) {
    final h = headers?.value('retry-after');
    if (h != null) {
      final s = double.tryParse(h.trim());
      if (s != null) return (s * 1000).ceil().clamp(1000, 15 * 60 * 1000);
    }
    // Gemini: "retryDelay": "34s"
    final m = RegExp(r'"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"').firstMatch(body);
    if (m != null) {
      final s = double.tryParse(m.group(1)!);
      if (s != null) return (s * 1000).ceil().clamp(1000, 15 * 60 * 1000);
    }
    // Groq: "Please try again in 7.5s" / "in 1m3.2s"
    final g = RegExp(r'try again in (?:(\d+)m)?(\d+(?:\.\d+)?)s').firstMatch(body);
    if (g != null) {
      final mins = int.tryParse(g.group(1) ?? '0') ?? 0;
      final s = double.tryParse(g.group(2)!) ?? 0;
      return ((mins * 60 + s) * 1000).ceil().clamp(1000, 15 * 60 * 1000);
    }
    return null;
  }

  static String _briefBody(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is Map) {
        final m = (j['error'] as Map)['message'];
        if (m is String && m.isNotEmpty) return m.length > 220 ? '${m.substring(0, 220)}…' : m;
      }
    } catch (_) {}
    final t = body.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > 220 ? '${t.substring(0, 220)}…' : t;
  }
}

/// Otonom mod için araştırma: Gemini + Google Arama (yalnızca Gemini anahtarı varsa).
/// Hiçbir koşulda istisna fırlatmaz; başarısızlıkta null döner ve oturum araştırmasız sürer.
/// Geçici hatalarda (429/5xx/ağ) üstel geri çekilmeyle [CloudRetryPolicy.researchAttempts] kez dener;
/// [cancel] ile her an iptal edilebilir.
Future<String?> cloudResearch(
  String goal, {
  String projectHint = '',
  CloudCancelToken? cancel,
  CloudRetryPolicy policy = const CloudRetryPolicy(),
  CloudConfig? config,
  Uri? endpoint,
}) async {
  final run = _CloudRun();
  try {
    final cfg = config ?? CloudConfig.instance;
    if (!cfg.research) return null;
    final g = cfg.providers[CloudProvider.gemini];
    if (g == null || !g.usable) return null;
    if ((CloudEngine._cool[CloudProvider.gemini] ?? 0) > DateTime.now().millisecondsSinceEpoch) return null;
    SecretMask.register(g.apiKey);
    run.attach(cancel);

    final uri = endpoint ??
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/${g.model.trim()}:generateContent');
    final prompt = 'Bir Flutter/Dart projesini şu hedef doğrultusunda geliştireceğiz:\n$goal\n\n'
        '${projectHint.isEmpty ? '' : 'Proje bağımlılıkları: $projectHint\n\n'}'
        'Web\'de ARAŞTIR ve Türkçe, madde madde, en çok 1800 karakterlik kısa bir not yaz: '
        '(1) bu hedef için güncel en iyi uygulama yaklaşımı, (2) kullanılabilecek güncel Flutter/Dart '
        'paketleri ve sık yapılan hatalar, (3) kaçınılması gereken kullanımdan kalkmış API\'ler. '
        'Kod yazma; yalnızca doğrulanmış bilgi ver, emin olmadığını belirt.';
    final req = _CloudRequest(
      uri,
      {'x-goog-api-key': g.apiKey.trim()},
      {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'tools': [
          {'google_search': <String, dynamic>{}},
        ],
        'generationConfig': {'maxOutputTokens': 4096, 'temperature': 0.2},
      },
    );

    final attempts = policy.researchAttempts < 1 ? 1 : policy.researchAttempts;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (run.cancelled) return null;
      try {
        final body = await _CloudHttp(policy, run).post<String>(
          CloudProvider.gemini,
          req,
          onOk: (res) => _CloudHttp.readBody(res, policy.headersTimeout),
        );
        if (run.cancelled) return null;
        CloudEngine._fails[CloudProvider.gemini] = 0;
        return _researchText(body);
      } catch (e, st) {
        if (run.cancelled) return null;
        final ce = CloudEngine._asCloudError(e);
        CrashGuard.log('Bulut araştırma', ce.message, attempt == attempts ? st : null);
        final transient = ce.fixedCoolMs == null;
        if (!transient || attempt == attempts) {
          // Kalıcı hata (anahtar/model) veya deneme hakkı bitti: sağlayıcıyı dinlendir, araştırmasız sürsün.
          CloudEngine._cool[CloudProvider.gemini] = DateTime.now().millisecondsSinceEpoch +
              (ce.fixedCoolMs ?? math.max(policy.minCooldownMs, ce.hintMs ?? 0));
          return null;
        }
        // Geçici hata: üstel geri çekilme (iptal edilebilir uyku), en çok 60 sn.
        final waitMs = math.max(ce.hintMs ?? 0, policy.backoffMs(attempt, CloudEngine._rnd));
        await run.sleep(math.min(waitMs, 60000));
      }
    }
    return null;
  } catch (e, st) {
    CrashGuard.log('Bulut araştırma', e.toString(), st);
    return null;
  } finally {
    run.dispose();
  }
}

/// Araştırma yanıtından (düz JSON) kısa not + kaynak başlıkları üretir; anlamsızsa null.
String? _researchText(String body) {
  final j = jsonDecode(body);
  if (j is! Map) return null;
  final text = CloudEngine._geminiText(j).trim();
  if (text.isEmpty) return null;
  final sources = <String>[];
  final cands = j['candidates'];
  if (cands is List && cands.isNotEmpty && cands.first is Map) {
    final gm = (cands.first as Map)['groundingMetadata'];
    if (gm is Map && gm['groundingChunks'] is List) {
      for (final ch in gm['groundingChunks'] as List) {
        if (ch is Map && ch['web'] is Map) {
          final title = (ch['web'] as Map)['title'];
          if (title is String && title.isNotEmpty && !sources.contains(title) && sources.length < 5) {
            sources.add(title);
          }
        }
      }
    }
  }
  final out = StringBuffer(text.length > 1600 ? text.substring(0, 1600) : text);
  if (sources.isNotEmpty) out.write('\nKaynaklar: ${sources.join(', ')}');
  return out.toString();
}
