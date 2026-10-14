// Görev 6/19 (Geliştirme Modu v2): ORKESTRATÖR (DevSessionEngine).
//
// Önceki beş parçayı tek döngüde birleştirir:
//   hazırlık → dal aç/devam et → planla → analiz → düzeltme → kapılar (DevGuard) → doğrulayıcı
//   → commit (DevRepoClient) → Actions (CiOutcome) → [yeşil: sonraki parça] [kırmızı: CiFeedback ile düzeltme
//   → kapılar → doğrulayıcı → commit → tekrar] → kararlılık (ardışık temiz geçiş + CI yeşil) → bitti.
//
// Değişmezler (kodda zorlanır):
//  * Hiçbir yama, DevGuard VE bağımsız doğrulayıcıdan geçmeden commitlenmez (commit tek yerden: _commit).
//  * Varsayılan dala/PR birleştirmeye hiçbir yol yoktur (port arayüzünde merge YOK).
//  * Altyapı hatası (CiInfraError) AI'ya "düzelt" diye verilmez; geri çekilmeyle beklenir.
//  * Kendi CancelToken'ını tutar; AppController'ın eski _cancel alanından bağımsızdır.
//  * Sırlar olaylara/loglara girmez: her metin SecretMask.redact'ten ve DevSessionStore'dan geçer.
//
// Ağ/AI bağımlılıkları arayüzlerle (port) enjekte edilir; testler sahte repo/CI/model kullanır.
import 'dart:async';
import 'dart:io' show HandshakeException, HttpException, InternetAddress, SocketException, TlsException;

import '../data/chatml_parser.dart' show neutralizeChatMlMarkers, restoreChatMlMarkers;
import '../data/ci_feedback.dart';
import '../data/cloud_engine.dart';
import '../data/github_ci.dart';
import '../data/flutter_project_check.dart' show ProjectProblem;
import '../data/github_repo.dart';
import '../data/llm_engine.dart' show GenerationFailedException;
import '../data/native_services.dart' show KeepAliveEvent, KeepAliveEventKind;
import '../data/project_snapshot.dart';
import '../data/secret_mask.dart';
import 'autopilot.dart';
import 'ci_batch.dart';
import 'dev_guard.dart';
import 'dev_ledger.dart';
import 'dev_mode.dart';
import 'dev_model_pool.dart';
import 'dev_session_store.dart';
import 'workflow_runner.dart' show CancelToken, CancelledException;

/// Kalp atışı olayı aralığı.
const Duration kDevHeartbeatEvery = Duration(minutes: 5);

// ====================================================================== portlar

/// Depo katmanı (DevRepoClient'ın oturumun kullandığı kısmı). Bilerek birleştirme (merge) YOK.
abstract class DevRepoPort {
  Future<WorkBranch> createWorkBranch(String baseBranch, {String? name});
  Future<RepoLoadResult> loadSnapshotWithInfo(String branch);
  Future<String> commitChanges(String branch, String expectedHeadSha, Map<String, String?> changes, String message);
  Future<String> revertTo(String branch, String targetSha, String message, {String? expectedHeadSha});
  Future<PullRequestInfo> openPullRequest(String head, String base, String title, String body, {bool draft});
}

/// Actions katmanı. Dal ucu ilerlediyse (iş akışı commit'i) sonuçtaki `sha` yeni uçtur.
abstract class DevCiPort {
  Future<CiOutcome> checkBranch(String branch, {void Function(String status)? status});
}

/// Model havuzu.
abstract class DevPoolPort {
  PoolPick pick(String role, {Set<String> exclude, String? differFrom});
  bool report(PoolReport r);
}

/// Model çağrısı hatası; havuza bildirilecek sınıflandırmayı taşır.
class DevModelCallException implements Exception {
  DevModelCallException(this.report);

  final PoolReport report;

  @override
  String toString() => 'Model çağrısı başarısız (${report.kind.name}): ${report.message}';
}

/// Seçilen [model] ile TEK seferlik (sistem + kullanıcı) çağrı; ham metni döner.
/// Başarısızlıkta [DevModelCallException] (tercih) ya da herhangi bir istisna fırlatır; iptalde
/// [CancelledException]. [ct] iptal edilince hızlı dönmelidir.
typedef DevModelCall = Future<String> Function(PoolModel model, String system, String user, CancelToken ct);

/// İptal edilebilir uyku (testlerde sahte saati ilerletir).
typedef DevSleep = Future<void> Function(Duration d, CancelToken ct);

// ====================================================================== Görev 9/19: dayanıklılık

/// Oturumu duraklatan nedenler. Aynı anda birden çok neden etkin olabilir; hepsi kalkınca oturum sürer.
enum DevPauseReason { kullanici, servisZamanAsimi, termal }

extension DevPauseReasonText on DevPauseReason {
  String get label {
    switch (this) {
      case DevPauseReason.kullanici:
        return 'kullanıcı duraklattı';
      case DevPauseReason.servisZamanAsimi:
        return 'ön plan servisi sistem tarafından durduruldu (zaman aşımı)';
      case DevPauseReason.termal:
        return 'cihaz aşırı ısındı';
    }
  }
}

/// Duraklatma kapısı: motor her adımın başında [waitOpen] ile buraya uğrar. Duraklatma süren çağrıyı (model/CI)
/// yarıda kesmez; çağrı bitince bir sonraki kapıda bekler. Commit zaten atomik olduğundan veri kaybı olmaz.
class DevPauseGate {
  final Set<DevPauseReason> _reasons = <DevPauseReason>{};
  final List<void Function(Set<DevPauseReason> reasons)> _listeners = <void Function(Set<DevPauseReason>)>[];
  Completer<void>? _open;

  bool get paused => _reasons.isNotEmpty;

  Set<DevPauseReason> get reasons => Set<DevPauseReason>.unmodifiable(_reasons);

  /// Neden kümesi her değiştiğinde çağrılır (dinleyici hataları yutulur).
  void addListener(void Function(Set<DevPauseReason> reasons) l) => _listeners.add(l);

  void removeListener(void Function(Set<DevPauseReason> reasons) l) => _listeners.remove(l);

  /// Yeni bir neden eklendiyse true.
  bool pause(DevPauseReason r) {
    if (!_reasons.add(r)) return false;
    _notify();
    return true;
  }

  /// Neden kaldırıldıysa true; hiç neden kalmadıysa bekleyenler uyanır.
  bool resume(DevPauseReason r) {
    if (!_reasons.remove(r)) return false;
    _notify();
    if (_reasons.isEmpty) wake();
    return true;
  }

  /// Tüm nedenleri kaldırır (kullanıcı Devam dediğinde).
  void resumeAll() {
    if (_reasons.isEmpty) return;
    _reasons.clear();
    _notify();
    wake();
  }

  /// Duraklatma yoksa hemen döner; varsa [wake]/[resume] çağrılana kadar bekler (dinleyici BİRİKTİRMEZ).
  Future<void> waitOpen() {
    if (!paused) return Future<void>.value();
    return (_open ??= Completer<void>()).future;
  }

  /// Bekleyenleri uyandırır (neden kümesine dokunmaz; iptalde motor kullanır).
  void wake() {
    final c = _open;
    _open = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  void _notify() {
    final snapshot = reasons;
    for (final l in List<void Function(Set<DevPauseReason>)>.of(_listeners)) {
      try {
        l(snapshot);
      } catch (_) {}
    }
  }
}

/// Ağ yoklaması (testlerde sahte). true: internet erişilebilir görünüyor.
typedef DevNetProbe = Future<bool> Function();

/// Varsayılan yoklama: `api.github.com` adı çözülebiliyor mu (5 sn). Doze/uçak modunda false döner.
Future<bool> devNetworkReachable() async {
  try {
    final r = await InternetAddress.lookup('api.github.com').timeout(const Duration(seconds: 5));
    return r.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Ağ/geçici sunucu hatası mı? Evet ise başarısızlık değil BEKLEME sayılır.
/// 401/403(sınırsız)/404/409/422 gibi kalıcı hatalar burada false döner (yükselir).
bool isDevNetworkError(Object e) {
  if (e is SocketException ||
      e is TimeoutException ||
      e is HandshakeException ||
      e is TlsException ||
      e is HttpException) {
    return true;
  }
  if (e is CiTransientException) return true;
  if (e is CiHttpException) {
    final s = e.status;
    return s <= 0 || s == 408 || s == 429 || s >= 500 || e.retryAfter != null;
  }
  return false;
}

/// Sunucunun istediği bekleme (varsa).
Duration? devRetryAfterOf(Object e) => e is CiHttpException ? e.retryAfter : null;

// ------------------------------------------------------------------ GitHub kota bütçesi

/// Kota baskısı. Düzey yükseldikçe istekler arası asgari aralık büyür (yoklama seyrekleşir).
enum DevQuotaLevel { normal, dikkat, kisitli, kritik, tukendi }

/// Saatlik GitHub istek bütçesi: istekleri dakika kovalarında sayar (RAM'de en çok ~61 giriş) ve yanıt
/// başlıklarındaki `x-ratelimit-*` değerlerini de dikkate alır. [wrap], `GithubHttpSender`'ı sarar; böylece
/// `DevRepoClient` ve `GithubCiRunner`'ın tüm istekleri (CI yoklaması dahil) sayılır ve yavaşlatılır.
class DevQuotaBudget {
  DevQuotaBudget({
    this.hourlyBudget = 3000,
    DateTime Function()? now,
    Future<void> Function(Duration d, CancelToken? ct)? sleep,
    this.maxWait = const Duration(minutes: 15),
    this.spacingAttention = const Duration(seconds: 5),
    this.spacingLimited = const Duration(seconds: 20),
    this.spacingCritical = const Duration(seconds: 60),
  })  : _now = now ?? DateTime.now,
        _sleep = sleep ?? _defaultSleep;

  /// Bu oturumun saatlik ayıracağı istek sayısı (GitHub kişisel belirteç sınırı 5000/sa; geri kalanı
  /// kullanıcının başka işleri içindir).
  final int hourlyBudget;
  final Duration maxWait;
  final Duration spacingAttention;
  final Duration spacingLimited;
  final Duration spacingCritical;
  final DateTime Function() _now;
  final Future<void> Function(Duration d, CancelToken? ct) _sleep;

  final Map<int, int> _perMinute = <int, int>{};
  int? _remaining;
  int? _limit;
  DateTime? _resetAt;
  DateTime? _lastSentAt;

  /// Toplam sayaç (yalnızca bilgi; bellekte tek tamsayı).
  int totalRequests = 0;

  static Future<void> _defaultSleep(Duration d, CancelToken? ct) =>
      ct == null ? Future<void>.delayed(d) : ct.wait(d);

  int _minuteOf(DateTime t) => t.millisecondsSinceEpoch ~/ 60000;

  void _prune() {
    final cutoff = _minuteOf(_now()) - 60;
    _perMinute.removeWhere((m, _) => m <= cutoff);
  }

  /// Son 60 dakikadaki istek sayısı.
  int get usedLastHour {
    _prune();
    var n = 0;
    for (final v in _perMinute.values) {
      n += v;
    }
    return n;
  }

  /// Başlıklardan öğrenilen kalan hak (sıfırlanma zamanı geçtiyse bilinmiyor sayılır).
  int? get remaining {
    _forgetStaleHeaders();
    return _remaining;
  }

  void _forgetStaleHeaders() {
    final r = _resetAt;
    if (r != null && !_now().isBefore(r)) {
      _remaining = null;
      _limit = null;
      _resetAt = null;
    }
  }

  /// 0..1+ arası kullanım oranı (bütçe sayacı ile başlıklardan hangisi kötüyse).
  double get pressure {
    _forgetStaleHeaders();
    final byCount = hourlyBudget <= 0 ? 1.0 : usedLastHour / hourlyBudget;
    var byHeader = 0.0;
    final lim = _limit;
    final rem = _remaining;
    if (lim != null && lim > 0 && rem != null) byHeader = 1.0 - (rem / lim);
    return byCount > byHeader ? byCount : byHeader;
  }

  DevQuotaLevel get level {
    _forgetStaleHeaders();
    if (_remaining != null && _remaining! <= 0) return DevQuotaLevel.tukendi;
    final p = pressure;
    if (p >= 1.0) return DevQuotaLevel.tukendi;
    if (p >= 0.90) return DevQuotaLevel.kritik;
    if (p >= 0.75) return DevQuotaLevel.kisitli;
    if (p >= 0.50) return DevQuotaLevel.dikkat;
    return DevQuotaLevel.normal;
  }

  /// Düzeye göre istekler arası asgari aralık ([DevQuotaLevel.tukendi] için [exhaustedWait]).
  Duration get spacing {
    switch (level) {
      case DevQuotaLevel.normal:
        return Duration.zero;
      case DevQuotaLevel.dikkat:
        return spacingAttention;
      case DevQuotaLevel.kisitli:
        return spacingLimited;
      case DevQuotaLevel.kritik:
        return spacingCritical;
      case DevQuotaLevel.tukendi:
        return exhaustedWait;
    }
  }

  /// Kota bittiğinde bekleme: bilinen sıfırlanmaya, yoksa en eski kovanın düşmesine kadar (en çok [maxWait]).
  Duration get exhaustedWait {
    final r = _resetAt;
    var d = Duration.zero;
    if (r != null) {
      d = r.difference(_now());
    } else {
      _prune();
      if (_perMinute.isNotEmpty) {
        var oldest = _perMinute.keys.first;
        for (final m in _perMinute.keys) {
          if (m < oldest) oldest = m;
        }
        final free = DateTime.fromMillisecondsSinceEpoch((oldest + 61) * 60000, isUtc: true);
        d = free.difference(_now());
      }
    }
    if (d < const Duration(seconds: 1)) d = const Duration(seconds: 1);
    return d > maxWait ? maxWait : d;
  }

  /// Bir sonraki isteğe kadar beklenmesi gereken süre.
  Duration nextDelay() {
    final lv = level;
    if (lv == DevQuotaLevel.normal) return Duration.zero;
    if (lv == DevQuotaLevel.tukendi) return exhaustedWait;
    final last = _lastSentAt;
    if (last == null) return Duration.zero;
    final d = last.add(spacing).difference(_now());
    return d.isNegative ? Duration.zero : d;
  }

  void recordRequest() {
    totalRequests++;
    final m = _minuteOf(_now());
    _perMinute[m] = (_perMinute[m] ?? 0) + 1;
    _prune();
  }

  /// `x-ratelimit-remaining/limit/reset` başlıklarını işler (başlık adları küçük harf).
  void recordResponse(Map<String, String> headers) {
    final rem = int.tryParse(headers['x-ratelimit-remaining'] ?? '');
    final lim = int.tryParse(headers['x-ratelimit-limit'] ?? '');
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    if (rem != null) _remaining = rem;
    if (lim != null) _limit = lim;
    if (reset != null) _resetAt = DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true);
  }

  /// İstekten önce çağrılır; gerekirse bekler (iptal edilebilir).
  Future<void> pace(CancelToken? ct) async {
    final w = nextDelay();
    if (w > Duration.zero) await _sleep(w, ct);
    _lastSentAt = _now();
  }

  /// `DevRepoClient(send: quota.wrap(githubHttpSend, cancel: ct))` biçiminde kullanılır.
  GithubHttpSender wrap(GithubHttpSender inner, {CancelToken? cancel}) => (GithubHttpRequest r) async {
        await pace(cancel);
        if (cancel != null && cancel.cancelled) throw const CiCancelledException();
        recordRequest();
        final resp = await inner(r);
        recordResponse(resp.headers);
        return resp;
      };
}

// ------------------------------------------------------------------ termal ilke ve izleyici

/// Android termal durumu (0..6; THERMAL_STATUS_NONE..SHUTDOWN). Eşikler `autopilotNeedsCooldown` (≥3) ile aynı.
const int kDevThermalPauseAt = 3;

/// Histerezisli termal karar: [kDevThermalPauseAt] ve üstünde duraklat; LIGHT (1) ve altına inip
/// [coolHold] boyunca öyle kalınca devam et. Saf mantık: zaman dışarıdan verilir.
class DevThermalPolicy {
  DevThermalPolicy({
    this.pauseAt = kDevThermalPauseAt,
    this.resumeAtMost = 1,
    this.coolHold = const Duration(seconds: 90),
  });

  final int pauseAt;
  final int resumeAtMost;
  final Duration coolHold;

  bool _hot = false;
  DateTime? _coolSince;

  bool get hot => _hot;

  /// Yeni ölçüm; dönüş: oturum şimdi termal nedenle duraklatılmış olmalı mı. Ölçüm yoksa (null) durum korunur.
  bool update(int? status, DateTime now) {
    if (status == null) return _hot;
    if (status >= pauseAt) {
      _hot = true;
      _coolSince = null;
      return true;
    }
    if (!_hot) return false;
    if (status <= resumeAtMost) {
      _coolSince ??= now;
      if (now.difference(_coolSince!) >= coolHold) {
        _hot = false;
        _coolSince = null;
        return false;
      }
    } else {
      _coolSince = null;
    }
    return true;
  }
}

/// Termal durumu düzenli okuyup [DevPauseGate]'e [DevPauseReason.termal] ekler/kaldırır.
/// Üretimde `thermalStatus: DeviceThermal.status` verilir (kanal yoksa null döner: hiçbir şey yapılmaz).
class DevResilienceMonitor {
  DevResilienceMonitor({
    required this.gate,
    this.thermalStatus,
    DevThermalPolicy? policy,
    this.pollEvery = const Duration(seconds: 30),
    DateTime Function()? now,
  })  : policy = policy ?? DevThermalPolicy(),
        _now = now ?? DateTime.now;

  final DevPauseGate gate;
  final Future<int?> Function()? thermalStatus;
  final DevThermalPolicy policy;
  final Duration pollEvery;
  final DateTime Function() _now;
  Timer? _timer;

  void start() {
    _timer ??= Timer.periodic(pollEvery, (_) => unawaited(tick()));
  }

  /// Tek ölçüm (testler doğrudan çağırır).
  Future<void> tick() async {
    final f = thermalStatus;
    if (f == null) return;
    int? s;
    try {
      s = await f();
    } catch (_) {
      s = null;
    }
    final shouldPause = policy.update(s, _now());
    if (shouldPause) {
      gate.pause(DevPauseReason.termal);
    } else {
      gate.resume(DevPauseReason.termal);
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Ön plan servisi zaman aşımı olayını duraklatmaya bağlar (Android 15 dataSync/shortService vb.).
/// Servis kapanınca motor çökmez: bir sonraki kapıda duraklar, kontrol noktası yazılır.
StreamSubscription<KeepAliveEvent> bindServiceTimeout({
  required Stream<KeepAliveEvent> events,
  required DevPauseGate gate,
  void Function(KeepAliveEvent e)? onTimeout,
}) =>
    events.listen(
      (e) {
        if (e.kind != KeepAliveEventKind.timeout) return;
        gate.pause(DevPauseReason.servisZamanAsimi);
        try {
          onTimeout?.call(e);
        } catch (_) {}
      },
      onError: (Object _) {},
    );


// ====================================================================== üretim bağdaştırıcıları

class DevRepoClientPort implements DevRepoPort {
  DevRepoClientPort(this._c);

  final DevRepoClient _c;

  @override
  Future<WorkBranch> createWorkBranch(String baseBranch, {String? name}) =>
      _c.createWorkBranch(baseBranch, name: name);

  @override
  Future<RepoLoadResult> loadSnapshotWithInfo(String branch) => _c.loadSnapshotWithInfo(branch);

  @override
  Future<String> commitChanges(String branch, String expectedHeadSha, Map<String, String?> changes, String message) =>
      _c.commitChanges(branch, expectedHeadSha, changes, message);

  @override
  Future<String> revertTo(String branch, String targetSha, String message, {String? expectedHeadSha}) =>
      _c.revertTo(branch, targetSha, message, expectedHeadSha: expectedHeadSha);

  @override
  Future<PullRequestInfo> openPullRequest(String head, String base, String title, String body, {bool draft = false}) =>
      _c.openPullRequest(head, base, title, body, draft: draft);
}

class GithubCiRunnerPort implements DevCiPort {
  GithubCiRunnerPort(this._r);

  final GithubCiRunner _r;

  @override
  Future<CiOutcome> checkBranch(String branch, {void Function(String status)? status}) =>
      _r.checkBranch(branch, status: status);
}

class DevModelPoolPort implements DevPoolPort {
  DevModelPoolPort(this._p);

  final DevModelPool _p;

  @override
  PoolPick pick(String role, {Set<String> exclude = const {}, String? differFrom}) =>
      _p.pick(role, exclude: exclude, differFrom: differFrom);

  @override
  bool report(PoolReport r) => _p.report(r);
}

/// Üretim model çağırıcısı: seçilen (sağlayıcı, model) çiftini, yalnızca o sağlayıcının anahtarını içeren
/// yalıtılmış bir [CloudConfig] ile [CloudEngine]'e verir. İptal tek bir dinleyiciyle ([ct.onCancel]) bağlanır.
class CloudDevModelCaller {
  CloudDevModelCaller({required CloudConfig source, required CancelToken ct, int maxTokens = 6000})
      : _source = source,
        _maxTokens = maxTokens {
    unawaited(ct.onCancel.then((_) {
      final s = _stop;
      if (s != null) unawaited(s());
    }));
  }

  final CloudConfig _source;
  final int _maxTokens;
  Future<void> Function()? _stop;

  Future<String> call(PoolModel model, String system, String user, CancelToken ct) async {
    if (ct.cancelled) throw const CancelledException();
    final key = _source.providers[model.provider]?.apiKey.trim() ?? '';
    if (key.isEmpty) {
      throw DevModelCallException(PoolReport(
        modelId: model.id,
        kind: PoolOutcomeKind.auth,
        message: 'API anahtarı yok',
      ));
    }
    final iso = CloudConfig.isolated();
    final pc = iso.providers[model.provider]!;
    pc
      ..apiKey = key
      ..model = model.model
      ..enabled = true;
    final engine = CloudEngine(
      config: iso,
      policy: const CloudRetryPolicy(
        maxAttempts: 2,
        minCooldownMs: 0,
        minWaitMs: 200,
        maxWait: Duration(seconds: 20),
      ),
    );
    _stop = engine.stop;
    try {
      await engine.ensureLoaded('$kCloudPathPrefix${model.provider.name}');
      final prompt = '<|im_start|>system\n${neutralizeChatMlMarkers(system)}<|im_end|>\n'
          '<|im_start|>user\n${neutralizeChatMlMarkers(user)}<|im_end|>\n'
          '<|im_start|>assistant\n';
      final b = StringBuffer();
      await for (final t in engine.generate(prompt, maxTokens: _maxTokens)) {
        if (ct.cancelled) throw const CancelledException();
        b.write(t);
      }
      if (ct.cancelled) throw const CancelledException();
      return restoreChatMlMarkers(b.toString());
    } on CancelledException {
      rethrow;
    } catch (e) {
      if (ct.cancelled) throw const CancelledException();
      final msg = SecretMask.redact('$e');
      final code = e is GenerationFailedException ? e.code : null;
      final PoolOutcomeKind kind;
      Duration? retry;
      if (code == 'CLOUD_AUTH' || code == 'CLOUD_NO_KEY') {
        kind = PoolOutcomeKind.auth;
      } else if (code == 'CLOUD_QUOTA') {
        kind = PoolOutcomeKind.rateLimit;
        retry = const Duration(seconds: 60);
      } else {
        kind = PoolOutcomeKind.other;
      }
      throw DevModelCallException(PoolReport(modelId: model.id, kind: kind, retryAfter: retry, message: msg));
    } finally {
      _stop = null;
      try {
        await engine.dispose();
      } catch (_) {}
    }
  }
}

// ====================================================================== yapılandırma / sonuç

class DevSessionConfig {
  const DevSessionConfig({
    required this.repo,
    required this.baseBranch,
    this.goal = '',
    this.maxDuration = const Duration(hours: 24),
    this.maxCommits = 200,
    this.maxConsecutiveFailures = 12,
    this.stablePassesNeeded = kAutopilotStablePasses,
    this.maxPartRetries = 3,
    this.maxFailedFixes = 3,
    this.sameSignatureLimit = 3,
    this.maxConflictsInRow = 5,
    this.maxModelAttempts = 6,
    this.chunkChars = 6000,
    this.heartbeatEvery = kDevHeartbeatEvery,
    this.infraWaitingAfter = const Duration(minutes: 30),
    this.maxWait = const Duration(minutes: 15),
    this.openPullRequest = false,
    this.networkBackoffStart = const Duration(seconds: 5),
    this.networkBackoffMax = const Duration(minutes: 5),
    this.networkWaitingAfter = const Duration(minutes: 2),
    this.networkProbeEvery = const Duration(seconds: 15),
    this.maxSnapshotChars = 64 * 1024 * 1024,
  });

  /// Kayıtlı kontrol noktasından (süreç ölümü sonrası) yapılandırma kurar. Süre ve commit sınırı sayaçlarda
  /// (`cfgSureDk`, `cfgMaxCommit`), hedef `models['hedef']` içinde saklanır; diğer sınırlar varsayılandır.
  factory DevSessionConfig.fromCheckpoint(DevSessionState s) {
    final min = s.counters['cfgSureDk'] ?? 0;
    final commits = s.counters['cfgMaxCommit'] ?? 0;
    return DevSessionConfig(
      repo: s.repo,
      baseBranch: s.baseBranch.isEmpty ? 'main' : s.baseBranch,
      goal: s.models['hedef'] ?? '',
      maxDuration: min > 0 ? Duration(minutes: min) : const Duration(hours: 24),
      maxCommits: commits > 0 ? commits : 200,
    );
  }

  /// `sahip/depo` (olaylarda ve kontrol noktasında görünür).
  final String repo;
  final String baseBranch;

  /// Kararlılıktan sonra uygulanacak geliştirme hedefi (boşsa yalnızca hata düzeltilir).
  final String goal;

  /// Azami oturum süresi (günlerce olabilir).
  final Duration maxDuration;

  /// Azami commit sayısı (revert commit'leri dahil değildir).
  final int maxCommits;

  /// Art arda bu kadar başarısız parçadan sonra oturum "hata" ile biter.
  final int maxConsecutiveFailures;
  final int stablePassesNeeded;

  /// K: aynı parça için en çok yeniden deneme (ilk deneme hariç).
  final int maxPartRetries;

  /// M: CI kırmızıyken üst üste başarısız düzeltme sayısı; aşılırsa revert.
  final int maxFailedFixes;

  /// Aynı CiFailureSignature bu kadar görülürse revert.
  final int sameSignatureLimit;
  final int maxConflictsInRow;
  final int maxModelAttempts;
  final int chunkChars;
  final Duration heartbeatEvery;

  /// Altyapı hatası bu kadar sürerse oturum "bekliyor" durumuna geçer (çökmez, beklemeye devam eder).
  final Duration infraWaitingAfter;

  /// Tek bekleme çağrısının üst sınırı (model parkı).
  final Duration maxWait;

  /// Bitişte (kararlı/süre/commit sınırı) taslak PR açılsın mı? Asla birleştirilmez.
  final bool openPullRequest;

  /// Ağ kesintisinde ilk bekleme ve tavanı (üstel; tavanlı). Başarısızlık sayılmaz.
  final Duration networkBackoffStart;
  final Duration networkBackoffMax;

  /// Kesinti bu kadar sürerse oturum "bekliyor" durumuna geçer (olay + kontrol noktası).
  final Duration networkWaitingAfter;

  /// Bekleme sırasında ağın dönüp dönmediğine bakma aralığı.
  final Duration networkProbeEvery;

  /// Bellekteki depo metninin (karakter) uyarı eşiği; aşılırsa olay yazılır (dosyalar atılmaz).
  final int maxSnapshotChars;

  /// Yalnızca depo/dal/hedef alanlarını değiştirilmiş kopya (diğer sınırlar aynen korunur).
  DevSessionConfig copyWith({String? repo, String? baseBranch, String? goal}) => DevSessionConfig(
        repo: repo ?? this.repo,
        baseBranch: baseBranch ?? this.baseBranch,
        goal: goal ?? this.goal,
        maxDuration: maxDuration,
        maxCommits: maxCommits,
        maxConsecutiveFailures: maxConsecutiveFailures,
        stablePassesNeeded: stablePassesNeeded,
        maxPartRetries: maxPartRetries,
        maxFailedFixes: maxFailedFixes,
        sameSignatureLimit: sameSignatureLimit,
        maxConflictsInRow: maxConflictsInRow,
        maxModelAttempts: maxModelAttempts,
        chunkChars: chunkChars,
        heartbeatEvery: heartbeatEvery,
        infraWaitingAfter: infraWaitingAfter,
        maxWait: maxWait,
        openPullRequest: openPullRequest,
        networkBackoffStart: networkBackoffStart,
        networkBackoffMax: networkBackoffMax,
        networkWaitingAfter: networkWaitingAfter,
        networkProbeEvery: networkProbeEvery,
        maxSnapshotChars: maxSnapshotChars,
      );
}

enum DevStopReason { kararli, sureDoldu, azamiCommit, azamiHata, iptal, hata, planYok }

class DevSessionResult {
  const DevSessionResult({
    required this.status,
    required this.reason,
    required this.branch,
    required this.headSha,
    required this.commits,
    required this.message,
    this.prUrl,
  });

  final DevSessionStatus status;
  final DevStopReason reason;
  final String branch;
  final String headSha;
  final int commits;
  final String message;
  final String? prUrl;
}

class _StopSession implements Exception {
  _StopSession(this.status, this.reason, this.message);

  final DevSessionStatus status;
  final DevStopReason reason;
  final String message;
}

class _ModelUnavailable implements Exception {
  _ModelUnavailable(this.message);

  final String message;
}

class _Reply {
  const _Reply(this.modelId, this.text);

  final String modelId;
  final String text;
}

enum _Patch { committed, rejected, conflict }

// ====================================================================== motor

class DevSessionEngine {
  DevSessionEngine({
    required this.config,
    required this.repo,
    required this.ci,
    required this.callModel,
    required this.pool,
    required this.store,
    required this.ledger,
    CancelToken? cancelToken,
    DateTime Function()? now,
    DevSleep? sleep,
    DevPauseGate? gate,
    this.quota,
    DevNetProbe? netProbe,
  })  : cancelToken = cancelToken ?? CancelToken(),
        gate = gate ?? DevPauseGate(),
        _probe = netProbe ?? devNetworkReachable,
        _now = now ?? DateTime.now,
        _sleep = sleep ?? ((d, ct) => ct.wait(d));

  final DevSessionConfig config;
  final DevRepoPort repo;
  final DevCiPort ci;
  final DevModelCall callModel;
  final DevPoolPort pool;
  final DevSessionStore store;
  final DevLedger ledger;

  /// Bu oturuma ÖZGÜ iptal belirteci (AppController'ın eski `_cancel` alanıyla paylaşılmaz).
  final CancelToken cancelToken;
  final DateTime Function() _now;
  final DevSleep _sleep;

  /// Duraklatma kapısı (kullanıcı, servis zaman aşımı, termal). Dışarıdan paylaşılabilir.
  final DevPauseGate gate;

  /// GitHub kota bütçesi (isteğe bağlı). Aynı örnek `DevRepoClient`/`GithubCiRunner` göndericisine `wrap` ile verilmelidir.
  final DevQuotaBudget? quota;
  final DevNetProbe _probe;

  /// İptal: her bekleme ve ağ çağrısı hızlı döner. İdempotent.
  void cancel() {
    cancelToken.cancel();
    gate.wake(); // duraklamada bekleyen motor iptali fark etsin
  }

  /// Duraklatır (idempotent). Süren çağrı bitince bir sonraki kapıda durur; kontrol noktası hemen yazılır.
  bool pause([DevPauseReason reason = DevPauseReason.kullanici]) => gate.pause(reason);

  /// Verilen nedeni kaldırır; başka neden kalmadıysa oturum sürer.
  bool resume([DevPauseReason reason = DevPauseReason.kullanici]) => gate.resume(reason);

  bool get paused => gate.paused;

  // ---- çalışma durumu
  bool _running = false;
  String _branch = '';
  String _base = '';
  String _head = '';
  String _lastGreen = '';
  ProjectSnapshot _snap = ProjectSnapshot(name: 'proje');
  final Map<String, int> _c = <String, int>{};
  final Set<String> _blocked = <String>{};
  final List<String> _sigs = <String>[];
  final Map<String, String> _models = <String, String>{};
  final Map<String, int> _detSeen = <String, int>{};
  List<String> _lastCommitPaths = <String>[];
  DevPlanner _planner = DevPlanner();
  late AutopilotConvergence _conv;
  bool _improving = false;
  int _failStreak = 0;
  int _conflictRow = 0;
  bool _waitingState = false;
  String _phase = '';
  String _lastCiStatus = '';
  late DateTime _startedAt;
  late DateTime _deadline;
  late DateTime _lastBeat;
  String _goal = '';
  DateTime? _netOutageAt;
  bool _netWaiting = false;
  DevQuotaLevel _lastQuotaLevel = DevQuotaLevel.normal;
  bool _memWarned = false;

  /// Sayaçların anlık kopyası (arayüz/test).
  Map<String, int> get counters => Map<String, int>.unmodifiable(_c);
  Set<String> get blockedFiles => Set<String>.unmodifiable(_blocked);
  String get branch => _branch;
  String get headSha => _head;
  String get lastGreenSha => _lastGreen;

  int _n(String k) => _c[k] ?? 0;
  void _inc(String k) => _c[k] = _n(k) + 1;

  // ------------------------------------------------------------------ giriş

  /// Yeni oturum başlatır; [resumeFrom] verilirse AYNI dalda, kayıtlı bloklu dosyalar ve sayaçlarla sürer.
  Future<DevSessionResult> run({DevSessionState? resumeFrom}) async {
    if (_running) throw StateError('Oturum zaten çalışıyor.');
    _running = true;
    gate.addListener(_onGateChange);
    try {
      return await _runInner(resumeFrom);
    } on _StopSession catch (s) {
      return _safeFinish(s.status, s.reason, s.message);
    } on CancelledException {
      return _safeFinish(DevSessionStatus.iptal, DevStopReason.iptal, 'İptal edildi.');
    } on CiCancelledException {
      return _safeFinish(DevSessionStatus.iptal, DevStopReason.iptal, 'İptal edildi.');
    } catch (e) {
      if (cancelToken.cancelled) {
        return _safeFinish(DevSessionStatus.iptal, DevStopReason.iptal, 'İptal edildi.');
      }
      return _safeFinish(DevSessionStatus.hata, DevStopReason.hata, 'Oturum hatayla durdu: ${_safe('$e', 400)}');
    } finally {
      _running = false;
      gate.removeListener(_onGateChange);
      try {
        await store.flush();
        await ledger.flush();
      } catch (_) {}
    }
  }

  Future<DevSessionResult> _safeFinish(DevSessionStatus st, DevStopReason r, String msg) async {
    try {
      return await _finish(st, r, msg);
    } catch (_) {
      return DevSessionResult(
        status: st,
        reason: r,
        branch: _branch,
        headSha: _head,
        commits: _n('commit'),
        message: _safe(msg, 400),
      );
    }
  }

  Future<DevSessionResult> _runInner(DevSessionState? saved) async {
    _startedAt = saved?.startedAt ?? _now();
    _deadline = _startedAt.add(config.maxDuration);
    _lastBeat = _now();
    var downtime = Duration.zero;
    if (saved != null) {
      // Süreç kesintisi (telefon kapandı/uygulama öldürüldü) oturum süresinden sayılmaz.
      downtime = _now().difference(saved.updatedAt);
      if (downtime > Duration.zero) {
        _deadline = _deadline.add(downtime);
      } else {
        downtime = Duration.zero;
      }
    }
    _base = (saved != null && saved.baseBranch.isNotEmpty) ? saved.baseBranch : config.baseBranch;
    _goal = config.goal.trim();
    if (saved != null) {
      _c.addAll(saved.counters);
      _blocked.addAll(saved.blockedFiles);
      _sigs.addAll(saved.lastSignatures);
      _models.addAll(saved.models);
      _lastGreen = saved.models['sonYesil'] ?? '';
      _models.remove('sonYesil');
      if (_goal.isEmpty) _goal = saved.models['hedef'] ?? '';
    }
    // Süreç ölümünden sonra yapılandırmayı kontrol noktasından kurabilmek için sınırlar sayaç olarak saklanır.
    _c['cfgSureDk'] = config.maxDuration.inMinutes;
    _c['cfgMaxCommit'] = config.maxCommits;
    if (_goal.isNotEmpty) _models['hedef'] = _goal.length > 150 ? _goal.substring(0, 150) : _goal;
    _improving = _n('gelistirme') == 1 && _goal.isNotEmpty;
    _conv = AutopilotConvergence(stablePasses: _n('kararli'));

    _phase = 'Hazırlık';
    _say(
      DevEventKind.asama,
      saved == null
          ? 'Oturum başlıyor: ${config.repo}'
          : 'Oturum devam ediyor: ${config.repo}'
              '${downtime > Duration.zero ? ' (süreç kesintisi ${autopilotDurationText(downtime)}; süreden sayılmadı)' : ''}',
    );
    final wb = await _net(
      'dal açma',
      () => repo.createWorkBranch(
        _base,
        name: (saved != null && saved.branch.isNotEmpty) ? saved.branch : null,
      ),
    );
    _check();
    _branch = wb.name;
    _say(
      DevEventKind.asama,
      wb.resumed ? 'Çalışma dalına devam: $_branch' : 'Çalışma dalı açıldı: $_branch (taban: $_base)',
      sha: wb.headSha,
    );
    await _reload();
    await _save(DevSessionStatus.calisiyor);

    var needCi = true; // başlangıç taban çizgisi: mevcut ucun yeşil olduğu kanıtlanmalı
    while (true) {
      _check();
      await _pauseGate();
      _quotaWatch();
      final stop = _limitStop();
      if (stop != null) throw stop;
      await _beat();

      if (needCi) {
        await _ciPhase();
        needCi = false;
        continue;
      }

      // ---- planla (bloklu dosyalar hariç)
      _phase = 'Planlama';
      final view = ProjectSnapshot(
        name: _snap.name,
        text: {
          for (final e in _snap.text.entries)
            if (!_blocked.contains(e.key)) e.key: e.value,
        },
      );
      final plan = _planner.plan(view, chunkChars: config.chunkChars, wrap: true);
      if (plan == null) {
        throw _StopSession(DevSessionStatus.tamamlandi, DevStopReason.planYok, 'İncelenecek içerik kalmadı.');
      }
      if (_conv.onPass(_planner.passes)) {
        _c['kararli'] = _conv.stablePasses;
        if (_conv.stablePasses >= config.stablePassesNeeded) {
          if (_lastGreen != _head || _lastGreen.isEmpty) {
            needCi = true; // kararlı demeden önce CI yeşil olmalı
            continue;
          }
          if (_goal.isNotEmpty && !_improving) {
            _improving = true;
            _c['gelistirme'] = 1;
            _conv.stablePasses = 0;
            _c['kararli'] = 0;
            _say(DevEventKind.durum, 'Proje kararlı; hedef doğrultusunda geliştirmeye geçildi.');
            await _save(DevSessionStatus.calisiyor);
            continue;
          }
          throw _StopSession(
            DevSessionStatus.tamamlandi,
            DevStopReason.kararli,
            _improving
                ? 'Hedef için yeni iyileştirme kalmadı; proje kararlı ve CI yeşil.'
                : 'Proje kararlı: ardışık temiz geçişler ve CI yeşil.',
          );
        }
      }

      _inc('tur');
      final round = _n('tur');
      _phase = _improving ? 'Geliştirme önerisi' : 'Analiz';
      _say(DevEventKind.analiz, 'Tur $round: ${plan.labels.join(', ')}', files: plan.paths.toList());

      // ---- analiz (analist)
      final _Reply analyst;
      try {
        final lessons = ledger.lessons();
        analyst = await _call(
          DevRole.analyst,
          _improving ? DevPrompts.improverSystem : DevPrompts.analystSystem,
          _improving
              ? DevPrompts.improverUser(_snap, plan, round, _goal, lessons: lessons)
              : DevPrompts.analystUser(
                  _snap,
                  plan,
                  round,
                  DevPlanner.estimateSteps(_snap, chunkChars: config.chunkChars),
                  lessons: lessons,
                ),
        );
      } on _ModelUnavailable catch (e) {
        _failStreak++;
        _say(DevEventKind.analiz, 'Analist modeli kullanılamadı: ${e.message}', level: DevEventLevel.uyari);
        await _wait(autopilotBackoff(_failStreak));
        continue;
      }
      _models[DevRole.analyst] = analyst.modelId;

      var report = DevReport.parse(analyst.text, _snap, scope: plan.paths);
      var det = 0;
      if (!_improving) {
        final fresh = <ProjectProblem>[];
        for (final pr in AutopilotChecks.problemsFor(_snap, plan.paths)) {
          if (_detSeen.length > 5000) _detSeen.clear();
          final key = '${pr.path}|${pr.message}';
          final seen = (_detSeen[key] ?? 0) + 1;
          _detSeen[key] = seen;
          if (seen <= 2) fresh.add(pr);
        }
        final findings = AutopilotChecks.toFindings(fresh);
        det = findings.length;
        if (findings.isNotEmpty) {
          report = DevReport(findings: [...findings, ...report.findings], dropped: report.dropped, raw: analyst.text);
        }
      }
      if (!report.hasFindings) {
        _conv.recordRound(fixed: 0, deterministicProblems: 0);
        _planner.advance(plan);
        _failStreak = 0;
        _say(DevEventKind.analiz, 'Tur $round: sorun bulunamadı.', modelId: analyst.modelId);
        await _save(DevSessionStatus.calisiyor);
        continue;
      }
      _say(
        DevEventKind.analiz,
        'Tur $round: ${report.findings.length} sorun bulundu.',
        modelId: analyst.modelId,
        files: [for (final f in report.findings) f.path],
      );

      // ---- düzeltme → kapılar → doğrulayıcı → commit
      final res = await _attemptPatch(
        plan,
        finding: report.forFixer(),
        userFor: (lessons) => DevPrompts.fixerUser(plan, report, lessons: lessons),
        label: 'Tur $round: ${plan.labels.join(', ')}',
      );
      if (res == _Patch.conflict) {
        _conflictRow++;
        if (_conflictRow < config.maxConflictsInRow) continue; // snapshot yeniden yüklendi: parçayı baştan işle
        _failStreak++;
        _conflictRow = 0;
        _planner.advance(plan);
        _say(DevEventKind.durum, 'Art arda çakışma sınırı aşıldı; parça atlandı.', level: DevEventLevel.uyari);
        continue;
      }
      _conflictRow = 0;
      if (res == _Patch.committed) {
        _conv.recordRound(fixed: 1, deterministicProblems: det);
        _planner.advance(plan, changedPaths: _lastCommitPaths.toSet());
        _failStreak = 0;
        needCi = true;
      } else {
        _conv.recordRound(fixed: 0, deterministicProblems: report.findings.length);
        _planner.advance(plan);
        _failStreak++;
        _say(
          DevEventKind.yama,
          'Parça için geçerli yama üretilemedi (art arda başarısız: $_failStreak).',
          level: DevEventLevel.uyari,
        );
      }
      await _save(DevSessionStatus.calisiyor);
    }
  }

  // ------------------------------------------------------------------ CI aşaması

  /// Mevcut uç için Actions çalıştırır; yeşile ya da (revert ile) yeşil duruma dönene kadar sürer.
  Future<void> _ciPhase() async {
    var infra = 0;
    var infraTotal = Duration.zero;
    var failedFixes = 0;
    var fixPending = false; // son kırmızıdan sonra bir düzeltme commit'lendi
    CiFailure? pending;
    while (true) {
      _check();
      await _pauseGate();
      _limitCheck();
      final CiOutcome out;
      if (pending != null) {
        out = pending;
        pending = null;
      } else {
        _phase = 'Actions';
        out = await _net('Actions', () => ci.checkBranch(_branch, status: _ciStatus));
        _check();
      }

      if (out is CiCancelled) throw const CancelledException();

      if (out is CiInfraError) {
        infra++;
        _inc('bekleme');
        final d = autopilotBackoff(infra);
        infraTotal += d;
        _say(
          DevEventKind.bekleme,
          'Actions/ağ sorunu (${out.reason.name}): ${_safe(out.message, 500)} — AI\'ya hata diye verilmez; '
          '${d.inSeconds} sn sonra yeniden denenecek.',
          level: DevEventLevel.uyari,
          runUrl: out.runUrl,
        );
        if (!_waitingState && (infraTotal >= config.infraWaitingAfter || _needsUser(out.reason))) {
          _waitingState = true;
          await _save(DevSessionStatus.bekliyor, note: 'Actions/ağ bekleniyor: ${out.reason.name}');
        }
        await _wait(d);
        continue;
      }
      if (_waitingState) {
        _waitingState = false;
        infra = 0;
        infraTotal = Duration.zero;
        await _save(DevSessionStatus.calisiyor);
      }
      infra = 0;
      infraTotal = Duration.zero;

      if (out is CiSuccess) {
        if (out.sha.isNotEmpty && out.sha != _head) await _reload(); // iş akışı commit'i ucu ilerletmiş olabilir
        _lastGreen = _head;
        _clearSignatureCounters();
        _inc('ciYesil');
        _say(DevEventKind.ci, 'Actions başarılı.', sha: _head, runUrl: out.runUrl);
        await _save(DevSessionStatus.calisiyor);
        return;
      }

      if (out is CiFailure) {
        _inc('ciHata');
        final sid = out.signature.id;
        final key = 'imza:$sid';
        final seen = _n(key) + 1;
        _c[key] = seen;
        _capSigCounters();
        if (!_sigs.contains(sid)) _sigs.add(sid);
        if (_sigs.length > 20) _sigs.removeAt(0);
        if (fixPending) {
          failedFixes++;
          fixPending = false;
        }
        _say(
          DevEventKind.ci,
          'Actions başarısız (aşama: ${out.result.stage}, imza $sid, $seen. kez, başarısız düzeltme: $failedFixes).',
          level: DevEventLevel.uyari,
          sha: out.sha,
          runUrl: out.runUrl,
        );
        await _save(DevSessionStatus.calisiyor);
        if (seen >= config.sameSignatureLimit) {
          await _rollback(out, 'aynı hata imzası $seen kez tekrarlandı');
          return;
        }
        if (failedFixes >= config.maxFailedFixes) {
          await _rollback(out, '$failedFixes düzeltme üst üste başarısız oldu');
          return;
        }
        final r = await _ciFix(out);
        if (r == _Patch.committed) {
          fixPending = true;
          continue;
        }
        if (r == _Patch.conflict) {
          pending = out;
          continue;
        }
        failedFixes++;
        if (failedFixes >= config.maxFailedFixes) {
          await _rollback(out, 'düzeltme üretilemedi ($failedFixes deneme)');
          return;
        }
        pending = out;
        await _wait(autopilotBackoff(failedFixes));
        continue;
      }
      // Bilinmeyen sonuç türü (sealed; erişilmez): güvenli tarafta bekle.
      await _wait(const Duration(seconds: 30));
    }
  }

  bool _needsUser(CiInfraReason r) =>
      r == CiInfraReason.auth ||
      r == CiInfraReason.actionsDisabled ||
      r == CiInfraReason.workflowMissing ||
      r == CiInfraReason.startupFailure;

  void _ciStatus(String s) {
    final t = _safe(s, 200);
    if (t == _lastCiStatus) return;
    _lastCiStatus = t;
    _say(DevEventKind.ci, t);
  }

  void _clearSignatureCounters() {
    _c.removeWhere((k, _) => k.startsWith('imza:'));
    _sigs.clear();
  }

  /// CI kırmızıyken düzeltici ile yama üretir (CiFeedback metniyle) → kapılar → doğrulayıcı → commit.
  Future<_Patch> _ciFix(CiFailure f) async {
    _phase = 'CI düzeltme';
    DevRoundPlan? found;
    String? label;
    final cp = CiBatcher.plan(_snap, f.result.diagnostics, budget: config.chunkChars);
    for (final b in cp.batches) {
      if (_blocked.contains(b.path) || !DevPlanner.eligible(b.path)) continue;
      found = b.plan;
      label = b.partLabel;
      break;
    }
    if (found == null) {
      final paths = _lastCommitPaths.where((p) => _snap.text.containsKey(p) && !_blocked.contains(p)).toList();
      if (paths.isEmpty) return _Patch.rejected;
      final v = ProjectSnapshot(name: _snap.name, text: {for (final p in paths) p: _snap.text[p]!});
      found = DevPlanner().plan(v, chunkChars: config.chunkChars, wrap: false);
    }
    if (found == null) return _Patch.rejected;
    final plan = found;
    return _attemptPatch(
      plan,
      finding: f.feedback,
      userFor: (lessons) => DevPrompts.ciFixerUser(plan, f.feedback, f.result.stage, partLabel: label, lessons: lessons),
      label: 'CI düzeltme (${f.result.stage}): ${plan.labels.join(', ')}',
    );
  }

  /// CI kırmızı ve düzeltme sonuçsuz: son yeşil commit'e dön, ilgili dosyaları bloklu işaretle.
  Future<void> _rollback(CiFailure f, String why) async {
    final files = <String>{
      for (final d in f.result.diagnostics)
        if (d.path.isNotEmpty && DevPlanner.eligible(d.path)) d.path,
      ..._lastCommitPaths.where(DevPlanner.eligible),
    };
    if (_lastGreen.isEmpty) {
      _blocked.addAll(files);
      throw _StopSession(
        DevSessionStatus.hata,
        DevStopReason.hata,
        'CI kırmızı ($why) ve geri dönülecek yeşil commit yok. Dal: $_branch',
      );
    }
    _phase = 'Geri alma';
    final msg = 'kripton: son yeşil commit\'e geri dönüş ($why)';
    if (_head != _lastGreen) {
      try {
        _head = await _net('geri alma', () => repo.revertTo(_branch, _lastGreen, msg, expectedHeadSha: _head));
      } on DevConflictException {
        await _reload();
        if (_head != _lastGreen) _head = await _net('geri alma', () => repo.revertTo(_branch, _lastGreen, msg, expectedHeadSha: _head));
      }
    }
    await _reload();
    _lastGreen = _head; // içerik son yeşil ağaçla aynı
    _blocked.addAll(files);
    _inc('geriAlma');
    _clearSignatureCounters();
    _lastCommitPaths = <String>[];
    await ledger.record(DevErrorEntry(
      ts: _now().millisecondsSinceEpoch,
      rol: DevRole.fixer,
      modelId: _models[DevRole.fixer] ?? '',
      kapiKodu: DevGate.ci,
      ayrinti: 'CI geri alma: $why; dosyalar: ${files.join(', ')}',
      dosya: files.isEmpty ? '' : files.first,
    ));
    _say(
      DevEventKind.geriAlma,
      'Son yeşil commit\'e dönüldü ($why). Bloklu dosyalar: ${files.isEmpty ? '-' : files.join(', ')}',
      level: DevEventLevel.uyari,
      files: files.toList(),
      sha: _head,
    );
    await _save(DevSessionStatus.calisiyor);
  }

  // ------------------------------------------------------------------ yama hattı

  /// Düzeltici (en çok 1+K deneme) → DevGuard → bağımsız doğrulayıcı → commit. Commit YALNIZCA burada atılır.
  Future<_Patch> _attemptPatch(
    DevRoundPlan plan, {
    required String finding,
    required String Function(String lessons) userFor,
    required String label,
  }) async {
    for (var attempt = 1; attempt <= config.maxPartRetries + 1; attempt++) {
      _check();
      await _pauseGate();
      _limitCheck();
      _phase = 'Düzeltme ($attempt)';
      final _Reply fx;
      try {
        fx = await _call(DevRole.fixer, DevPrompts.fixerSystem, userFor(ledger.lessons()));
      } on _ModelUnavailable catch (e) {
        _say(DevEventKind.yama, 'Düzeltici modeli kullanılamadı: ${e.message}', level: DevEventLevel.uyari);
        return _Patch.rejected;
      }
      _models[DevRole.fixer] = fx.modelId;

      final v = DevGuard.check(_snap, scope: plan.paths, rawOutput: fx.text, finding: finding);
      if (!v.ok) {
        _inc('ret');
        await ledger.recordVerdict(v, rol: DevRole.fixer, modelId: fx.modelId, deneme: attempt);
        _say(
          DevEventKind.yama,
          'Kapılar reddetti (deneme $attempt/${config.maxPartRetries + 1}): ${_safe(v.summary, 600)}',
          level: DevEventLevel.uyari,
          modelId: fx.modelId,
        );
        continue;
      }

      _phase = 'Doğrulayıcı';
      final _Reply vr;
      try {
        vr = await _call(
          DevRole.verifier,
          DevPrompts.verifierSystem,
          DevPrompts.verifierUser(finding, v.diffText()),
          differFrom: fx.modelId,
          mustDiffer: true,
        );
      } on _ModelUnavailable catch (e) {
        _say(
          DevEventKind.yama,
          'Bağımsız doğrulayıcı yok; yama commitlenmedi: ${e.message}',
          level: DevEventLevel.uyari,
          modelId: fx.modelId,
        );
        return _Patch.rejected;
      }
      _models[DevRole.verifier] = vr.modelId;
      final vv = parseVerifier(vr.text);
      if (!vv.approved) {
        _inc('ret');
        await ledger.recordVerifier(
          vv,
          fixerModelId: fx.modelId,
          verifierModelId: vr.modelId,
          dosya: v.changedPaths.isEmpty ? '' : v.changedPaths.first,
          deneme: attempt,
        );
        _say(
          DevEventKind.yama,
          'Doğrulayıcı reddetti (deneme $attempt): ${_safe(vv.summary, 400)}',
          level: DevEventLevel.uyari,
          modelId: vr.modelId,
          files: v.changedPaths,
        );
        continue;
      }
      await _pauseGate(); // duraklatma istendiyse commit'ten ÖNCE dur (yama doğrulandı, hiçbir şey kaybolmaz)
      await ledger.recordSuccess(modelId: fx.modelId);
      return _commit(v, label, fx.modelId);
    }
    return _Patch.rejected;
  }

  Future<_Patch> _commit(GuardVerdict v, String label, String modelId) async {
    // Son savunma: onaysız/boş yama asla commitlenmez.
    if (!v.ok || v.changes.isEmpty) return _Patch.rejected;
    if (_n('commit') >= config.maxCommits) {
      throw _StopSession(DevSessionStatus.tamamlandi, DevStopReason.azamiCommit, 'Azami commit sayısına ulaşıldı.');
    }
    _phase = 'Commit';
    final changes = <String, String?>{...v.changes};
    final msg = 'kripton: ${_safe(label, 160)}\n\nDosyalar: ${v.changedPaths.join(', ')}';
    final String sha;
    try {
      sha = await _net('commit', () => repo.commitChanges(_branch, _head, changes, msg));
    } on DevConflictException {
      _inc('cakisma');
      _say(DevEventKind.commit, 'Dal ucu oynadı (çakışma); anlık görüntü yeniden yükleniyor.', level: DevEventLevel.uyari);
      await _reload();
      return _Patch.conflict;
    }
    _check();
    final existed = {for (final p in v.changes.keys) p: _snap.text.containsKey(p)};
    _head = sha;
    _snap = ProjectSnapshot(name: _snap.name, text: {..._snap.text, ...v.changes}, binary: _snap.binary);
    for (final e in v.changes.entries) {
      await store.recordChange(
        e.key,
        status: existed[e.key] == true ? DevChangeStatus.degistirildi : DevChangeStatus.eklendi,
        commitSha: sha,
        content: e.value,
      );
    }
    _lastCommitPaths = v.changedPaths;
    _inc('commit');
    _say(
      DevEventKind.commit,
      'Commit atıldı: ${v.changedPaths.join(', ')}',
      files: v.changedPaths,
      sha: sha,
      modelId: modelId,
    );
    await _save(DevSessionStatus.calisiyor);
    return _Patch.committed;
  }

  // ------------------------------------------------------------------ model çağrısı

  Future<_Reply> _call(
    String role,
    String system,
    String user, {
    String? differFrom,
    bool mustDiffer = false,
  }) async {
    var errors = 0;
    var none = 0;
    var netTries = 0;
    while (true) {
      _check();
      await _pauseGate();
      _limitCheck();
      _quotaWatch();
      await _beat();
      final pk = pool.pick(role, differFrom: differFrom);
      if (pk.status == PoolPickStatus.wait) {
        var d = pk.waitFor ?? const Duration(seconds: 30);
        if (d < const Duration(seconds: 1)) d = const Duration(seconds: 1);
        if (d > config.maxWait) d = config.maxWait;
        _inc('bekleme');
        _say(
          DevEventKind.bekleme,
          '$role için tüm modeller parkta/dinleniyor; ${d.inSeconds} sn bekleniyor (${_safe(pk.reason, 200)}).',
          level: DevEventLevel.uyari,
        );
        await _wait(d);
        continue;
      }
      if (pk.status == PoolPickStatus.none || pk.model == null) {
        none++;
        _say(
          DevEventKind.bekleme,
          '$role için kullanılabilir model yok: ${_safe(pk.reason, 200)}',
          level: DevEventLevel.uyari,
        );
        if (none > 5) throw _ModelUnavailable(pk.reason);
        await _wait(autopilotBackoff(none));
        continue;
      }
      final m = pk.model!;
      if (mustDiffer && differFrom != null && m.id == differFrom) {
        throw _ModelUnavailable('doğrulayıcı olarak düzelticiden farklı model yok');
      }
      try {
        final raw = await callModel(m, system, user, cancelToken);
        _check();
        if (raw.trim().isEmpty) {
          pool.report(PoolReport(modelId: m.id, kind: PoolOutcomeKind.empty, message: 'boş çıktı'));
          errors++;
          if (errors >= config.maxModelAttempts) throw _ModelUnavailable('model boş çıktı verdi');
          continue;
        }
        pool.report(PoolReport.success(m.id));
        if (_netOutageAt != null) await _netRecovered();
        return _Reply(m.id, raw);
      } on CancelledException {
        rethrow;
      } on _ModelUnavailable {
        rethrow;
      } on DevModelCallException catch (e) {
        pool.report(e.report);
        if (e.report.kind == PoolOutcomeKind.network ||
            (e.report.kind == PoolOutcomeKind.timeout && !await _probe())) {
          // Ağ kopuk: model hatası SAYILMAZ; bekle ve yeniden dene.
          await _netOutage('model', e, ++netTries);
          continue;
        }
        errors++;
        _say(DevEventKind.analiz, 'Model hatası: ${_safe('$e', 300)}', level: DevEventLevel.uyari, modelId: m.id);
        if (errors >= config.maxModelAttempts) throw _ModelUnavailable('model çağrıları başarısız (${e.report.kind.name})');
      } catch (e) {
        if (cancelToken.cancelled) throw const CancelledException();
        final rep = PoolReport.fromError(m.id, e);
        pool.report(rep);
        if (rep.kind == PoolOutcomeKind.network || (rep.kind == PoolOutcomeKind.timeout && !await _probe())) {
          await _netOutage('model', e, ++netTries);
          continue;
        }
        errors++;
        _say(DevEventKind.analiz, 'Model hatası: ${_safe('$e', 300)}', level: DevEventLevel.uyari, modelId: m.id);
        if (errors >= config.maxModelAttempts) throw _ModelUnavailable('model çağrıları başarısız');
      }
    }
  }

  // ------------------------------------------------------------------ yardımcılar

  void _check() {
    if (cancelToken.cancelled) throw const CancelledException();
  }

  /// Süre dolduysa oturumu sonlandırır (bekleme/çağrı döngülerinin içinden de çağrılır).
  void _limitCheck() {
    if (!_now().isBefore(_deadline)) {
      throw _StopSession(DevSessionStatus.tamamlandi, DevStopReason.sureDoldu, 'Azami süre doldu.');
    }
  }

  _StopSession? _limitStop() {
    if (!_now().isBefore(_deadline)) {
      return _StopSession(DevSessionStatus.tamamlandi, DevStopReason.sureDoldu, 'Azami süre doldu.');
    }
    if (_n('commit') >= config.maxCommits) {
      return _StopSession(DevSessionStatus.tamamlandi, DevStopReason.azamiCommit, 'Azami commit sayısına ulaşıldı.');
    }
    if (_failStreak >= config.maxConsecutiveFailures) {
      return _StopSession(
        DevSessionStatus.hata,
        DevStopReason.azamiHata,
        'Art arda $_failStreak başarısız parça; oturum durduruldu.',
      );
    }
    return null;
  }

  /// İptal edilebilir bekleme; kalp atışı aralığında dilimler.
  Future<void> _wait(Duration d) async {
    var left = d;
    while (left > Duration.zero) {
      _check();
      final slice = left < config.heartbeatEvery ? left : config.heartbeatEvery;
      await _sleep(slice, cancelToken);
      left -= slice;
      _check();
      await _pauseGate();
      await _beat();
      _limitCheck();
    }
  }

  Future<void> _beat() async {
    final t = _now();
    if (t.difference(_lastBeat) < config.heartbeatEvery) return;
    _lastBeat = t;
    _say(
      DevEventKind.kalpAtisi,
      'Oturum canlı: $_phase (commit ${_n('commit')}, ret ${_n('ret')}, geri alma ${_n('geriAlma')}'
      '${quota == null ? '' : ', GitHub isteği/sa ${quota!.usedLastHour}'}).',
    );
    await _save(_waitingState ? DevSessionStatus.bekliyor : DevSessionStatus.calisiyor);
  }

  Future<void> _reload() async {
    final r = await _net('depo okuma', () => repo.loadSnapshotWithInfo(_branch));
    _check();
    _snap = r.snapshot;
    _head = r.headSha;
    _checkSnapshotBudget();
  }

  Future<void> _save(DevSessionStatus status, {String note = ''}) async {
    // Duraklatma etkinken "çalışıyor" yazılmaz: süreç şu an öldürülse bile açılışta doğru durum görünür.
    var eff = status;
    var effNote = note;
    if (gate.paused && (status == DevSessionStatus.calisiyor || status == DevSessionStatus.bekliyor)) {
      eff = DevSessionStatus.duraklatildi;
      if (effNote.isEmpty) effNote = 'Duraklatıldı: ${gate.reasons.map((r) => r.label).join('; ')}';
    }
    final models = <String, String>{..._models};
    if (_lastGreen.isNotEmpty) models['sonYesil'] = _lastGreen;
    await store.saveCheckpoint(DevSessionState(
      id: store.id,
      status: eff,
      repo: config.repo,
      branch: _branch,
      baseBranch: _base,
      headSha: _head,
      startedAt: _startedAt,
      updatedAt: _now(),
      counters: _c,
      blockedFiles: _blocked.toList(),
      lastSignatures: _sigs,
      models: models,
      phase: _phase,
      note: effNote,
    ));
  }

  // ------------------------------------------------------------------ Görev 9/19: dayanıklılık yardımcıları

  /// Kontrol noktasını yazar; hata fırlatmaz (dal henüz açılmadıysa yazmaz: eski iyi kayıt bozulmasın).
  Future<void> _saveSafe(DevSessionStatus st, {String note = ''}) async {
    if (_branch.isEmpty) return;
    try {
      await _save(st, note: note);
    } catch (_) {}
  }

  /// Kapı dinleyicisi: duraklatma istenince olay + HEMEN kontrol noktası (süren çağrı bitmeden de yazılır).
  void _onGateChange(Set<DevPauseReason> reasons) {
    if (!_running) return;
    if (reasons.isEmpty) {
      _say(DevEventKind.durum, 'Duraklatma kalktı; oturum sürüyor.');
      return;
    }
    _inc('duraklat');
    final text = reasons.map((r) => r.label).join('; ');
    _say(
      DevEventKind.durum,
      'Oturum duraklatılıyor: $text. Süren işlem bitince durur; ilerleme kontrol noktasına yazıldı.',
      level: DevEventLevel.uyari,
    );
    unawaited(_saveSafe(DevSessionStatus.duraklatildi, note: 'Duraklatıldı: $text'));
  }

  /// Duraklatma etkinse kalkana (ya da iptale) kadar bekler. Beklenen süre oturum süresinden düşülmez.
  Future<void> _pauseGate() async {
    if (!gate.paused) return;
    final t0 = _now();
    final prevPhase = _phase;
    _phase = 'Duraklatıldı';
    await _saveSafe(
      DevSessionStatus.duraklatildi,
      note: 'Duraklatıldı: ${gate.reasons.map((r) => r.label).join('; ')}',
    );
    while (gate.paused) {
      _check();
      await gate.waitOpen();
    }
    _check();
    final held = _now().difference(t0);
    if (held > Duration.zero) _deadline = _deadline.add(held);
    _phase = prevPhase;
    await _saveSafe(_waitingState ? DevSessionStatus.bekliyor : DevSessionStatus.calisiyor);
  }

  /// Ağ/sunucu geçici hatasını BEKLEME sayar: üstel (tavanlı) geri çekilmeyle [op] yeniden denenir.
  /// Kalıcı hatalar ([isDevNetworkError] false), iptal ve çakışma olduğu gibi yükselir.
  Future<T> _net<T>(String what, Future<T> Function() op) async {
    var attempt = 0;
    while (true) {
      _check();
      try {
        final r = await op();
        if (_netOutageAt != null) await _netRecovered();
        return r;
      } catch (e) {
        if (cancelToken.cancelled) throw const CancelledException();
        if (e is CancelledException || e is CiCancelledException || e is _StopSession || !isDevNetworkError(e)) {
          rethrow;
        }
        attempt++;
        await _netOutage(what, e, attempt);
      }
    }
  }

  Duration _netBackoff(int attempt) {
    final max = config.networkBackoffMax.inMilliseconds;
    var ms = config.networkBackoffStart.inMilliseconds;
    if (ms < 1) ms = 1;
    for (var i = 1; i < attempt && ms < max; i++) {
      ms *= 2;
    }
    if (ms > max) ms = max;
    return Duration(milliseconds: ms);
  }

  Future<void> _netOutage(String what, Object e, int attempt) async {
    final first = _netOutageAt == null;
    _netOutageAt ??= _now();
    if (first) _inc('agKesinti');
    var d = _netBackoff(attempt);
    final hint = devRetryAfterOf(e);
    if (hint != null && hint > d) d = hint > config.maxWait ? config.maxWait : hint;
    final down = _now().difference(_netOutageAt!);
    _say(
      DevEventKind.bekleme,
      'Ağ/sunucu kesintisi ($what): ${_safe('$e', 240)} — başarısızlık sayılmadı; '
      '${d.inSeconds} sn sonra yeniden denenecek (kesinti ${autopilotDurationText(down)}).',
      level: DevEventLevel.uyari,
    );
    if (!_netWaiting && down >= config.networkWaitingAfter) {
      _netWaiting = true;
      _waitingState = true;
      await _saveSafe(DevSessionStatus.bekliyor, note: 'Ağ bekleniyor: $what');
    }
    await _netWait(d);
  }

  /// Bekleme; her [DevSessionConfig.networkProbeEvery] ağ yoklanır, dönmüşse erken çıkılır.
  Future<void> _netWait(Duration d) async {
    var left = d;
    var slept = Duration.zero;
    while (left > Duration.zero) {
      _check();
      var slice = left < config.networkProbeEvery ? left : config.networkProbeEvery;
      if (slice > config.heartbeatEvery) slice = config.heartbeatEvery;
      await _sleep(slice, cancelToken);
      left -= slice;
      slept += slice;
      _check();
      await _pauseGate();
      await _beat();
      _limitCheck();
      if (left > Duration.zero && slept >= config.networkBackoffStart && await _probe()) break;
    }
  }

  Future<void> _netRecovered() async {
    final since = _netOutageAt;
    _netOutageAt = null;
    final wasWaiting = _netWaiting;
    _netWaiting = false;
    final len = since == null ? '' : ' (kesinti ${autopilotDurationText(_now().difference(since))})';
    _say(DevEventKind.bekleme, 'Bağlantı döndü$len; oturum sürüyor.');
    if (wasWaiting) {
      _waitingState = false;
      await _saveSafe(DevSessionStatus.calisiyor);
    }
  }

  /// Kota düzeyi değiştiyse olay yazar (yoklamanın seyrekleştiği/rahatladığı görünür olsun).
  void _quotaWatch() {
    final q = quota;
    if (q == null) return;
    final lv = q.level;
    if (lv == _lastQuotaLevel) return;
    final worse = lv.index > _lastQuotaLevel.index;
    _lastQuotaLevel = lv;
    if (worse) _inc('kotaYavas');
    _say(
      DevEventKind.bekleme,
      worse
          ? 'GitHub kotası azalıyor (${lv.name}; son saatte ${q.usedLastHour} istek): yoklama seyrekleştirildi.'
          : 'GitHub kota baskısı azaldı (${lv.name}).',
      level: worse ? DevEventLevel.uyari : DevEventLevel.bilgi,
    );
  }

  /// `imza:*` sayaçları en çok 16 tutulur (kontrol noktası 64 anahtarla sınırlı; günlerce çalışmada şişmesin).
  void _capSigCounters() {
    final keys = _c.keys.where((k) => k.startsWith('imza:')).toList();
    for (var i = 0; i < keys.length - 16; i++) {
      _c.remove(keys[i]);
    }
  }

  /// Bellekteki depo metni eşiği aşarsa BİR kez uyarır (dosya atılmaz: kapılar tam içeriğe ihtiyaç duyar).
  void _checkSnapshotBudget() {
    if (_memWarned) return;
    var n = 0;
    for (final v in _snap.text.values) {
      n += v.length;
    }
    if (n > config.maxSnapshotChars) {
      _memWarned = true;
      _say(
        DevEventKind.durum,
        'Depo metni bellekte yaklaşık ${n ~/ (1024 * 1024)} milyon karakter; RAM baskısı olabilir. '
        'Çok büyük/gereksiz dosyaları depodan çıkarmayı düşün.',
        level: DevEventLevel.uyari,
      );
    }
  }

  void _say(
    DevEventKind kind,
    String message, {
    DevEventLevel level = DevEventLevel.bilgi,
    List<String> files = const [],
    String sha = '',
    String runUrl = '',
    String modelId = '',
  }) {
    store.log(
      kind,
      SecretMask.redact(message),
      level: level,
      files: files,
      sha: sha,
      runUrl: runUrl,
      modelId: modelId,
    );
  }

  static String _safe(String s, int max) {
    final r = SecretMask.redact(s).replaceAll(RegExp(r'\s+'), ' ').trim();
    return r.length <= max ? r : '${r.substring(0, max)}…';
  }

  Future<DevSessionResult> _finish(DevSessionStatus st, DevStopReason r, String msg) async {
    String? prUrl;
    final canPr = config.openPullRequest &&
        _branch.isNotEmpty &&
        _n('commit') > 0 &&
        (r == DevStopReason.kararli || r == DevStopReason.sureDoldu || r == DevStopReason.azamiCommit);
    if (canPr) {
      try {
        final info = await repo.openPullRequest(
          _branch,
          _base,
          'Kripton geliştirme oturumu: ${_n('commit')} commit',
          'Bu taslak PR otomatik açıldı; hiçbir şey birleştirilmedi. İnceleyip kendiniz karar verin.\n\n'
              'Commit: ${_n('commit')}, geri alma: ${_n('geriAlma')}, bloklu dosya: ${_blocked.length}.',
          draft: true,
        );
        prUrl = info.htmlUrl;
        _say(DevEventKind.durum, 'Taslak PR açıldı: ${info.htmlUrl}');
      } catch (e) {
        _say(DevEventKind.durum, 'PR açılamadı: ${_safe('$e', 300)}', level: DevEventLevel.uyari);
      }
    }
    _say(
      DevEventKind.durum,
      'Oturum bitti (${r.name}): $msg',
      level: st == DevSessionStatus.hata ? DevEventLevel.hata : DevEventLevel.bilgi,
      sha: _head,
    );
    _phase = 'Bitti';
    await _save(st, note: msg);
    await store.flush();
    return DevSessionResult(
      status: st,
      reason: r,
      branch: _branch,
      headSha: _head,
      commits: _n('commit'),
      message: _safe(msg, 400),
      prUrl: prUrl,
    );
  }
}
