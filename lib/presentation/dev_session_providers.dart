// Görev 7/19 (Geliştirme Modu v2): Geliştirme Modu ekranının Riverpod OKUMA katmanı.
//
// Bu dosya motoru/depoyu bilmez; yalnızca [DevSessionFeed] (okuma) arayüzünü tüketir. Üretim bağlantısı
// (DevSessionStore + DevLedger -> [DevStoreFeed]) ve eylemler ([DevSessionControls]) Prompt 8'de
// provider override ile verilir. Hiçbiri verilmezse ekran "kaynak bağlı değil" gösterir.
//
// Performans (saatlerce açık): olaylar kuyruğa alınır ve en çok `flushEvery` (250 ms => ≤4/sn)
// aralıkla TEK durum güncellemesiyle uygulanır; zamanlayıcı yalnızca iş varken kurulur. RAM'deki pencere
// en çok `windowSize` (500) olaydır; eskiler [DevSessionViewController.loadOlder] ile store'dan sayfalanır.
// Provider autoDispose'tur: ekran kapanınca abonelik ve zamanlayıcılar iptal edilir.

import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../application/dev_ledger.dart';
import '../application/dev_session_store.dart';
import '../application/settings_controller.dart';
import '../data/secret_mask.dart';
import 'dev_diff_view.dart';

// ------------------------------------------------------------------ okuma arayüzü

/// Defter özeti: model başına ret ve en sık kapılar.
class DevModelStat {
  const DevModelStat({
    required this.modelId,
    required this.rejects,
    required this.rate,
    required this.samples,
    this.demoted = false,
  });

  final String modelId;

  /// Defterdeki ret sayısı.
  final int rejects;

  /// EWMA ret oranı (0..1; bilinmiyorsa 0). [samples] 0 ise oran bilinmiyor demektir.
  final double rate;
  final int samples;
  final bool demoted;
}

class DevGateStat {
  const DevGateStat({required this.code, required this.count});

  final String code;
  final int count;
}

class DevLedgerSummary {
  const DevLedgerSummary({this.models = const [], this.gates = const []});

  static const DevLedgerSummary empty = DevLedgerSummary();

  /// Ret sayısına göre çoktan aza.
  final List<DevModelStat> models;

  /// Ret sayısına göre çoktan aza.
  final List<DevGateStat> gates;

  String get signature =>
      '${models.map((m) => '${m.modelId}:${m.rejects}:${m.samples}:${m.rate.toStringAsFixed(3)}:${m.demoted}').join(';')}|'
      '${gates.map((g) => '${g.code}:${g.count}').join(';')}';
}

/// Eski dosya içeriği (null = dosya yoktu) ve yeni içerik (null = silindi).
class DevFileVersions {
  const DevFileVersions({this.before, this.after});

  final String? before;
  final String? after;
}

/// Ekranın okuduğu her şey. Üretim: [DevStoreFeed]. Testler: sahte uygulama.
abstract class DevSessionFeed {
  /// Canlı olaylar (yayın).
  Stream<DevEvent> get events;

  /// Son [n] olay (eskiden yeniye).
  Future<List<DevEvent>> tail(int n);

  Future<DevSessionState?> loadSession();

  Future<Map<String, DevChange>> loadChanges();

  Future<DevLedgerSummary> ledgerSummary();

  /// Son CI hatalarının kısa listesi (maskelenmiş). Bilinmiyorsa boş: ekran olaydaki ileti ile yetinir.
  Future<List<String>> ciFailures() async => const <String>[];
}

/// Üretim bağdaştırıcısı: [DevSessionStore] + [DevLedger].
class DevStoreFeed implements DevSessionFeed {
  DevStoreFeed({required this.store, this.ledger, this.ciFailureLoader});

  final DevSessionStore store;
  final DevLedger? ledger;

  /// İsteğe bağlı: son CI hatalarını getirir (ör. CiLogStore'dan).
  final Future<List<String>> Function()? ciFailureLoader;

  @override
  Stream<DevEvent> get events => store.events;

  @override
  Future<List<DevEvent>> tail(int n) => store.tail(n);

  @override
  Future<DevSessionState?> loadSession() => store.loadSession();

  @override
  Future<Map<String, DevChange>> loadChanges() => store.loadChanges();

  @override
  Future<DevLedgerSummary> ledgerSummary() async {
    final l = ledger;
    if (l == null) return DevLedgerSummary.empty;
    final byModel = l.statsByModel();
    final models = <DevModelStat>[
      for (final e in byModel.entries)
        DevModelStat(
          modelId: e.key,
          rejects: e.value,
          rate: l.trust.rate(e.key),
          samples: l.trust.samples(e.key),
          demoted: l.trust.isDemoted(e.key),
        ),
    ];
    return DevLedgerSummary(
      models: List<DevModelStat>.unmodifiable(models),
      gates: List<DevGateStat>.unmodifiable([
        for (final e in l.statsByGate().entries) DevGateStat(code: e.key, count: e.value),
      ]),
    );
  }

  @override
  Future<List<String>> ciFailures() async {
    final f = ciFailureLoader;
    if (f == null) return const <String>[];
    try {
      return [for (final s in await f()) SecretMask.redact(s)];
    } catch (_) {
      return const <String>[];
    }
  }
}

/// Diff için dosya içeriklerini getirir (store yalnızca özet tuttuğu için depo/dal okunur).
abstract class DevDiffSource {
  /// Bulunamazsa null.
  Future<DevFileVersions?> load(String path, DevChange change);
}

/// Ekrandaki denetimlerin eylemleri. Bağlama Prompt 8'dedir.
abstract class DevSessionControls {
  bool get canPause;

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  /// Dalı TASLAK PR olarak açar; PR adresini döner (açılamazsa istisna fırlatır).
  Future<String?> openPullRequest();
}

/// Sınırlar (kalan süre ve commit üst sınırı için). Üretimde `DevSessionConfig`'ten verilir.
class DevSessionLimits {
  const DevSessionLimits({this.maxDuration = const Duration(hours: 24), this.maxCommits = 200});

  final Duration maxDuration;
  final int maxCommits;
}

/// Ayar düğmeleri (testlerde kısaltılır).
class DevViewTuning {
  const DevViewTuning({
    this.flushEvery = const Duration(milliseconds: 250),
    this.liteFlushEvery = const Duration(seconds: 1),
    this.pollEvery = const Duration(seconds: 10),
    this.refreshDebounce = const Duration(seconds: 1),
    this.windowSize = 500,
    this.olderPage = 100,
    this.maxQueue = 2000,
  });

  /// En çok 4 güncelleme/sn.
  final Duration flushEvery;

  /// Sade Mod'da daha seyrek güncelleme.
  final Duration liteFlushEvery;
  final Duration pollEvery;
  final Duration refreshDebounce;

  /// RAM'de tutulan en çok olay.
  final int windowSize;

  /// "Daha eski" tıklamasında pencerenin geri kaydığı olay sayısı.
  final int olderPage;
  final int maxQueue;
}

// ------------------------------------------------------------------ providerlar

/// Okuma kaynağı. null: bağlı değil (ekran bunu belirtir). Prompt 8'de override edilir.
final devSessionFeedProvider = Provider<DevSessionFeed?>((ref) => null);

final devDiffSourceProvider = Provider<DevDiffSource?>((ref) => null);

final devControlsProvider = Provider<DevSessionControls?>((ref) => null);

final devLimitsProvider = Provider<DevSessionLimits>((ref) => const DevSessionLimits());

final devViewTuningProvider = Provider<DevViewTuning>((ref) => const DevViewTuning());

/// Saat (testlerde sahte saat verilir).
final devClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Ekranı açık tutar/bırakır. Varsayılan: `wakelock_plus` (uygulamanın mevcut yardımcısı).
typedef DevWakelock = Future<void> Function(bool on);

final devWakelockProvider = Provider<DevWakelock>((ref) {
  return (bool on) async {
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {}
  };
});

/// Çalıştırma bağlantısını açar; açılamadıysa false (çağıran panoya kopyalar).
typedef DevOpenUrl = Future<bool> Function(String url);

final devOpenUrlProvider = Provider<DevOpenUrl>((ref) {
  return (String url) async {
    final u = Uri.tryParse(url);
    if (u == null || u.scheme != 'https') return false;
    try {
      await AndroidIntent(action: 'action_view', data: url).launch();
      return true;
    } catch (_) {
      return false;
    }
  };
});

/// Panoya metin kopyalar (testlerde değiştirilebilir).
final devCopyProvider = Provider<Future<void> Function(String)>((ref) {
  return (String t) => Clipboard.setData(ClipboardData(text: t));
});

/// Orta sütundaki seçili dosya yolu (düzen değişince korunur).
final devSelectedFileProvider = StateProvider.autoDispose<String?>((ref) => null);

// ------------------------------------------------------------------ türetilmiş modeller

enum DevCiState { yok, calisiyor, basarili, basarisiz, bekliyor }

/// Son CI çalıştırması özeti (olaylardan türetilir).
class DevCiInfo {
  const DevCiInfo({
    this.state = DevCiState.yok,
    this.stage = '',
    this.failures = const [],
    this.runUrl = '',
    this.sha = '',
  });

  static const DevCiInfo none = DevCiInfo();

  final DevCiState state;
  final String stage;
  final List<String> failures;
  final String runUrl;
  final String sha;

  DevCiInfo withFailures(List<String> f) =>
      DevCiInfo(state: state, stage: stage, failures: f, runUrl: runUrl, sha: sha);

  String get signature => '${state.name}|$stage|${failures.join('¦')}|$runUrl|$sha';
}

String _short(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

/// Yeni olaylardan CI özetini günceller (saf; testlenebilir).
DevCiInfo deriveCiInfo(DevCiInfo prev, Iterable<DevEvent> events) {
  var cur = prev;
  for (final e in events) {
    if (e.kind == DevEventKind.ci) {
      final m = e.message;
      if (m.startsWith('Actions başarılı')) {
        cur = DevCiInfo(state: DevCiState.basarili, stage: 'Tüm aşamalar', runUrl: e.runUrl, sha: e.sha);
      } else if (m.startsWith('Actions başarısız')) {
        final mm = RegExp(r'aşama:\s*([^,)]+)').firstMatch(m);
        cur = DevCiInfo(
          state: DevCiState.basarisiz,
          stage: mm?.group(1)?.trim() ?? '',
          failures: e.files.isNotEmpty ? e.files.take(20).toList() : [_short(m, 300)],
          runUrl: e.runUrl,
          sha: e.sha,
        );
      } else {
        cur = DevCiInfo(
          state: DevCiState.calisiyor,
          stage: _short(m, 120),
          runUrl: e.runUrl.isNotEmpty ? e.runUrl : cur.runUrl,
          sha: e.sha.isNotEmpty ? e.sha : cur.sha,
        );
      }
    } else if (e.kind == DevEventKind.bekleme && e.message.startsWith('Actions/ağ')) {
      cur = DevCiInfo(
        state: DevCiState.bekliyor,
        stage: _short(e.message, 160),
        runUrl: e.runUrl.isNotEmpty ? e.runUrl : cur.runUrl,
        sha: cur.sha,
      );
    }
  }
  return cur;
}

/// "Bekliyor" nedeni ve yeniden deneme zamanı (son `bekleme` olayından).
class DevWaitInfo {
  const DevWaitInfo({required this.reason, this.retryAt, required this.since});

  final String reason;

  /// Mesajdaki "N sn" ifadesinden hesaplanır; yoksa null.
  final DateTime? retryAt;
  final DateTime since;
}

bool _clearsWait(DevEvent e) {
  switch (e.kind) {
    case DevEventKind.asama:
    case DevEventKind.ci:
    case DevEventKind.geriAlma:
      return true;
    case DevEventKind.analiz:
    case DevEventKind.yama:
    case DevEventKind.commit:
      return e.level == DevEventLevel.bilgi;
    case DevEventKind.bekleme:
    case DevEventKind.kalpAtisi:
    case DevEventKind.durum:
      return false;
  }
}

/// Yeni olaylardan bekleme bilgisini günceller (saf).
DevWaitInfo? deriveWaitInfo(DevWaitInfo? prev, Iterable<DevEvent> events) {
  var cur = prev;
  for (final e in events) {
    if (e.kind == DevEventKind.bekleme) {
      DateTime? retry;
      final ms = RegExp(r'(\d+)\s*sn').allMatches(e.message).toList();
      if (ms.isNotEmpty) {
        final secs = int.tryParse(ms.last.group(1) ?? '');
        if (secs != null) retry = e.ts.add(Duration(seconds: secs));
      }
      cur = DevWaitInfo(reason: e.message, retryAt: retry, since: e.ts);
    } else if (cur != null && _clearsWait(e)) {
      cur = null;
    }
  }
  return cur;
}

/// Bellekte tutulan sınırlı olay penceresi (saf; testlenebilir).
class DevEventWindow {
  DevEventWindow({this.capacity = 500});

  final int capacity;
  List<DevEvent> _items = const <DevEvent>[];

  /// Pencereden daha YENİ olan (gösterilmeyen) olay sayısı; 0 = canlı kuyruktayız.
  int newer = 0;

  /// Store'da daha eski olay olabilir.
  bool hasOlder = false;

  List<DevEvent> get items => _items;

  bool get atTail => newer == 0;

  void resetTo(List<DevEvent> tail, {required bool maybeMore}) {
    final over = tail.length > capacity;
    _items = List<DevEvent>.unmodifiable(over ? tail.sublist(tail.length - capacity) : tail);
    newer = 0;
    hasOlder = maybeMore || over;
  }

  /// Canlıda sona ekler (en eskiler düşer); gezinme modunda yalnızca [newer] artar.
  void append(List<DevEvent> batch) {
    if (batch.isEmpty) return;
    if (!atTail) {
      newer += batch.length;
      return;
    }
    final all = <DevEvent>[..._items, ...batch];
    if (all.length > capacity) {
      _items = List<DevEvent>.unmodifiable(all.sublist(all.length - capacity));
      hasOlder = true;
    } else {
      _items = List<DevEvent>.unmodifiable(all);
    }
  }

  void showPage(List<DevEvent> page, {required int newer, required bool hasOlder}) {
    _items = List<DevEvent>.unmodifiable(page.length > capacity ? page.sublist(page.length - capacity) : page);
    this.newer = newer;
    this.hasOlder = hasOlder;
  }
}

enum DevLoadPhase { loading, ready, noSource }

/// Ekranın tek durum nesnesi. Widget'lar `select` ile yalnızca ilgili alanı izler.
class DevSessionView {
  const DevSessionView({
    this.phase = DevLoadPhase.loading,
    this.session,
    this.events = const <DevEvent>[],
    this.newer = 0,
    this.hasOlder = false,
    this.loadingOlder = false,
    this.changes = const <DevChange>[],
    this.ledger = DevLedgerSummary.empty,
    this.ci = DevCiInfo.none,
    this.wait,
    this.revision = 0,
  });

  final DevLoadPhase phase;
  final DevSessionState? session;

  /// En çok `windowSize` olay, eskiden yeniye.
  final List<DevEvent> events;

  /// Gezinme modunda pencerenin gösterilmeyen yeni olay sayısı (0 = canlı).
  final int newer;
  final bool hasOlder;
  final bool loadingOlder;

  /// En son değişen önce.
  final List<DevChange> changes;
  final DevLedgerSummary ledger;
  final DevCiInfo ci;
  final DevWaitInfo? wait;

  /// Her yayınlanan güncellemede artar (test/ölçüm için).
  final int revision;

  bool get atTail => newer == 0;

  DevSessionView copyWith({
    DevLoadPhase? phase,
    DevSessionState? session,
    List<DevEvent>? events,
    int? newer,
    bool? hasOlder,
    bool? loadingOlder,
    List<DevChange>? changes,
    DevLedgerSummary? ledger,
    DevCiInfo? ci,
    DevWaitInfo? wait,
    bool clearWait = false,
  }) =>
      DevSessionView(
        phase: phase ?? this.phase,
        session: session ?? this.session,
        events: events ?? this.events,
        newer: newer ?? this.newer,
        hasOlder: hasOlder ?? this.hasOlder,
        loadingOlder: loadingOlder ?? this.loadingOlder,
        changes: changes ?? this.changes,
        ledger: ledger ?? this.ledger,
        ci: ci ?? this.ci,
        wait: clearWait ? null : (wait ?? this.wait),
        revision: revision + 1,
      );
}

bool devSessionActiveStatus(DevSessionStatus s) =>
    s == DevSessionStatus.hazir ||
    s == DevSessionStatus.calisiyor ||
    s == DevSessionStatus.bekliyor ||
    s == DevSessionStatus.duraklatildi;

/// Geçen süre: bitmiş oturumda son güncellemeye kadar, aksi halde [now]'a kadar. Başlangıç, kontrol
/// noktasındaki ÖZGÜN `startedAt`'tır (resume'da değişmez).
Duration devElapsed(DevSessionState s, DateTime now) {
  final end = devSessionActiveStatus(s.status) ? now : s.updatedAt;
  final d = end.difference(s.startedAt);
  return d.isNegative ? Duration.zero : d;
}

bool _sameSession(DevSessionState? a, DevSessionState? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.status != b.status ||
      a.headSha != b.headSha ||
      a.branch != b.branch ||
      a.repo != b.repo ||
      a.phase != b.phase ||
      a.note != b.note ||
      a.startedAt != b.startedAt ||
      (!devSessionActiveStatus(a.status) && a.updatedAt != b.updatedAt) ||
      a.counters.length != b.counters.length ||
      a.models.length != b.models.length) {
    return false;
  }
  for (final e in a.counters.entries) {
    if (b.counters[e.key] != e.value) return false;
  }
  for (final e in a.models.entries) {
    if (b.models[e.key] != e.value) return false;
  }
  return true;
}

String _eventKey(DevEvent e) => '${e.ts.millisecondsSinceEpoch}|${e.kind.name}|${e.message}';

bool _affectsDerived(DevEvent e) =>
    e.kind == DevEventKind.commit ||
    e.kind == DevEventKind.ci ||
    e.kind == DevEventKind.geriAlma ||
    e.kind == DevEventKind.yama ||
    e.kind == DevEventKind.bekleme ||
    e.kind == DevEventKind.durum ||
    e.kind == DevEventKind.asama;

// ------------------------------------------------------------------ denetleyici

/// Olayları kuyruğa alıp seyrekleştirerek uygulayan, oturumu/dosyaları/defteri periyodik tazeleyen
/// okuma denetleyicisi.
class DevSessionViewController extends AutoDisposeNotifier<DevSessionView> {
  DevSessionFeed? _feed;
  DevViewTuning _tuning = const DevViewTuning();
  Duration _flushEvery = const Duration(milliseconds: 250);
  bool _disposed = false;
  bool _ready = false;
  StreamSubscription<DevEvent>? _sub;
  Timer? _flushTimer;
  Timer? _pollTimer;
  Timer? _refreshTimer;
  final List<DevEvent> _queue = <DevEvent>[];
  final List<DevEvent> _early = <DevEvent>[];
  late DevEventWindow _win;
  bool _refreshing = false;
  bool _refreshAgain = false;
  String _changesSig = '';

  @override
  DevSessionView build() {
    final feed = ref.watch(devSessionFeedProvider);
    final tuning = ref.watch(devViewTuningProvider);
    final lite = ref.read(settingsProvider).liteOnStart;
    ref.onDispose(_dispose);
    _disposed = false;
    _ready = false;
    _refreshing = false;
    _refreshAgain = false;
    _changesSig = '';
    _tuning = tuning;
    _flushEvery = lite && tuning.liteFlushEvery > tuning.flushEvery ? tuning.liteFlushEvery : tuning.flushEvery;
    _win = DevEventWindow(capacity: tuning.windowSize);
    if (feed == null) return const DevSessionView(phase: DevLoadPhase.noSource);
    _feed = feed;
    _sub = feed.events.listen(_onEvent, onError: (Object _) {});
    scheduleMicrotask(_init);
    return const DevSessionView();
  }

  void _dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    _flushTimer?.cancel();
    _pollTimer?.cancel();
    _refreshTimer?.cancel();
    _flushTimer = null;
    _pollTimer = null;
    _refreshTimer = null;
    _queue.clear();
    _early.clear();
  }

  void _emit(DevSessionView Function(DevSessionView v) f) {
    if (_disposed) return;
    state = f(state);
  }

  Future<void> _init() async {
    final feed = _feed;
    if (feed == null || _disposed) return;
    var tail = const <DevEvent>[];
    try {
      tail = await feed.tail(_tuning.windowSize);
    } catch (_) {
      tail = const <DevEvent>[];
    }
    if (_disposed) return;
    _win.resetTo(tail, maybeMore: tail.length >= _tuning.windowSize);
    _mergeEarly(tail);
    _ready = true;
    final items = _win.items;
    final ci = deriveCiInfo(DevCiInfo.none, items);
    final wait = deriveWaitInfo(null, items);
    _emit((v) => v.copyWith(
          phase: DevLoadPhase.ready,
          events: items,
          newer: 0,
          hasOlder: _win.hasOlder,
          ci: ci,
          wait: wait,
          clearWait: wait == null,
        ));
    await _refreshDerived();
    if (_disposed) return;
    _pollTimer = Timer.periodic(_tuning.pollEvery, (_) => unawaited(_refreshDerived()));
  }

  void _mergeEarly(List<DevEvent> tail) {
    if (_early.isEmpty) return;
    final from = tail.length > 300 ? tail.length - 300 : 0;
    final seen = <String>{for (var i = from; i < tail.length; i++) _eventKey(tail[i])};
    final fresh = [for (final e in _early) if (!seen.contains(_eventKey(e))) e];
    _early.clear();
    if (fresh.isNotEmpty) _win.append(fresh);
  }

  void _onEvent(DevEvent e) {
    if (_disposed) return;
    if (!_ready) {
      if (_early.length < _tuning.maxQueue) _early.add(e);
      return;
    }
    _queue.add(e);
    if (_queue.length > _tuning.maxQueue) {
      _queue.removeRange(0, _queue.length - _tuning.maxQueue);
    }
    _flushTimer ??= Timer(_flushEvery, _flushNow);
  }

  void _flushNow() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_disposed || _queue.isEmpty) return;
    final batch = List<DevEvent>.of(_queue);
    _queue.clear();
    _win.append(batch);
    final ci = deriveCiInfo(state.ci, batch);
    final wait = deriveWaitInfo(state.wait, batch);
    _emit((v) => v.copyWith(
          events: _win.items,
          newer: _win.newer,
          hasOlder: _win.hasOlder,
          ci: ci,
          wait: wait,
          clearWait: wait == null,
        ));
    if (batch.any(_affectsDerived)) {
      _refreshTimer ??= Timer(_tuning.refreshDebounce, () {
        _refreshTimer = null;
        unawaited(_refreshDerived());
      });
    }
  }

  /// Oturum kontrol noktasını, dosya listesini ve defteri yeniden okur; değişmediyse yayın yapmaz.
  Future<void> _refreshDerived() async {
    final feed = _feed;
    if (feed == null || _disposed) return;
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        DevSessionState? session;
        Map<String, DevChange>? changes;
        DevLedgerSummary? ledger;
        List<String> failures = const <String>[];
        try {
          session = await feed.loadSession();
        } catch (_) {}
        try {
          changes = await feed.loadChanges();
        } catch (_) {}
        try {
          ledger = await feed.ledgerSummary();
        } catch (_) {}
        if (_disposed) return;
        if (state.ci.state == DevCiState.basarisiz) {
          try {
            failures = await feed.ciFailures();
          } catch (_) {}
          if (_disposed) return;
        }

        var changed = false;
        DevSessionState? newSession;
        if (session != null && !_sameSession(session, state.session)) {
          newSession = session;
          changed = true;
        }
        List<DevChange>? newChanges;
        if (changes != null) {
          final list = changes.values.toList()
            ..sort((a, b) {
              final c = b.updatedAt.compareTo(a.updatedAt);
              return c != 0 ? c : a.path.compareTo(b.path);
            });
          final sig = list.map((c) => '${c.path}|${c.status.name}|${c.commitSha}|${c.commits}').join(';');
          if (sig != _changesSig) {
            _changesSig = sig;
            newChanges = List<DevChange>.unmodifiable(list);
            changed = true;
          }
        }
        DevLedgerSummary? newLedger;
        if (ledger != null && ledger.signature != state.ledger.signature) {
          newLedger = ledger;
          changed = true;
        }
        DevCiInfo? newCi;
        if (failures.isNotEmpty && state.ci.state == DevCiState.basarisiz) {
          final merged = state.ci.withFailures(failures.take(20).toList());
          if (merged.signature != state.ci.signature) {
            newCi = merged;
            changed = true;
          }
        }
        if (changed) {
          _emit((v) => v.copyWith(session: newSession, changes: newChanges, ledger: newLedger, ci: newCi));
        }
      } while (_refreshAgain && !_disposed);
    } finally {
      _refreshing = false;
    }
  }

  /// Hemen tazele (elle).
  Future<void> refreshNow() => _refreshDerived();

  /// Pencereyi [DevViewTuning.olderPage] olay geri kaydırır (store'dan okur).
  Future<void> loadOlder() async {
    final feed = _feed;
    if (feed == null || _disposed || !_ready || state.loadingOlder || !state.hasOlder) return;
    _flushNow(); // kuyruktaki olaylar `newer` sayacına işlensin
    _emit((v) => v.copyWith(loadingOlder: true));
    try {
      final newer = _win.newer + _tuning.olderPage;
      final cap = _tuning.windowSize;
      final all = await feed.tail(newer + cap);
      if (_disposed) return;
      if (all.length <= newer) {
        _win.hasOlder = false;
        _emit((v) => v.copyWith(loadingOlder: false, hasOlder: false));
        return;
      }
      final end = all.length - newer;
      final start = end - cap < 0 ? 0 : end - cap;
      _win.showPage(all.sublist(start, end), newer: newer, hasOlder: all.length >= newer + cap);
      _emit((v) => v.copyWith(
            events: _win.items,
            newer: _win.newer,
            hasOlder: _win.hasOlder,
            loadingOlder: false,
          ));
    } catch (_) {
      _emit((v) => v.copyWith(loadingOlder: false));
    }
  }

  /// Canlı sona dön (en yeni [DevViewTuning.windowSize] olay).
  Future<void> jumpToLatest() async {
    final feed = _feed;
    if (feed == null || _disposed || !_ready) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    _queue.clear();
    List<DevEvent> tail;
    try {
      tail = await feed.tail(_tuning.windowSize);
    } catch (_) {
      return;
    }
    if (_disposed) return;
    _win.resetTo(tail, maybeMore: tail.length >= _tuning.windowSize);
    _mergeEarly(tail);
    _emit((v) => v.copyWith(events: _win.items, newer: 0, hasOlder: _win.hasOlder, loadingOlder: false));
  }
}

final devSessionViewProvider =
    NotifierProvider.autoDispose<DevSessionViewController, DevSessionView>(DevSessionViewController.new);

// ------------------------------------------------------------------ diff

/// Diff sağlayıcısının anahtarı (yol + son commit: yeni commit gelince yeniden hesaplanır).
class DevDiffKey {
  const DevDiffKey(this.path, this.sha);

  final String path;
  final String sha;

  @override
  bool operator ==(Object other) => other is DevDiffKey && other.path == path && other.sha == sha;

  @override
  int get hashCode => Object.hash(path, sha);
}

/// Diff yükleme sonucu: [result] ya da açıklayıcı [unavailable].
class DevDiffLoad {
  const DevDiffLoad({this.result, this.unavailable = ''});

  final DevDiffResult? result;
  final String unavailable;
}

final devDiffProvider = FutureProvider.autoDispose.family<DevDiffLoad, DevDiffKey>((ref, key) async {
  final src = ref.watch(devDiffSourceProvider);
  if (src == null) {
    return const DevDiffLoad(unavailable: 'Diff kaynağı bağlı değil.');
  }
  final changes = ref.read(devSessionViewProvider).changes;
  DevChange? change;
  for (final c in changes) {
    if (c.path == key.path) {
      change = c;
      break;
    }
  }
  if (change == null) return const DevDiffLoad(unavailable: 'Dosya kaydı bulunamadı.');
  try {
    final v = await src.load(key.path, change);
    if (v == null) return const DevDiffLoad(unavailable: 'Dosya içeriği alınamadı.');
    final before = change.status == DevChangeStatus.eklendi ? null : v.before;
    final after = change.status == DevChangeStatus.silindi ? null : v.after;
    return DevDiffLoad(result: computeLineDiff(before, after));
  } catch (e) {
    return DevDiffLoad(unavailable: 'Diff yüklenemedi: ${SecretMask.redact('$e')}');
  }
});
