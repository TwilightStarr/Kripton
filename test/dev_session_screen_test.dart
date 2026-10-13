// Görev 7/19: Geliştirme Modu ekranı testleri. Gerçek ağ/disk yok: sahte okuma kaynağı, sahte saat,
// sahte denetim ve sahte diff kaynağı kullanılır.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/dev_ledger.dart' show DevRole;
import 'package:kripton_ai/application/dev_session_store.dart';
import 'package:kripton_ai/application/settings_controller.dart';
import 'package:kripton_ai/core/theme.dart';
import 'package:kripton_ai/presentation/dev_diff_view.dart';
import 'package:kripton_ai/presentation/dev_session_providers.dart';
import 'package:kripton_ai/presentation/dev_session_screen.dart';

// ------------------------------------------------------------------ sahteler

class FakeFeed extends DevSessionFeed {
  final StreamController<DevEvent> _ctl = StreamController<DevEvent>.broadcast();
  final List<DevEvent> stored = <DevEvent>[];
  DevSessionState? session;
  Map<String, DevChange> changes = <String, DevChange>{};
  DevLedgerSummary ledger = DevLedgerSummary.empty;
  List<String> failures = const <String>[];

  void emit(DevEvent e) {
    stored.add(e);
    _ctl.add(e);
  }

  @override
  Stream<DevEvent> get events => _ctl.stream;

  @override
  Future<List<DevEvent>> tail(int n) async =>
      stored.length <= n ? List<DevEvent>.of(stored) : stored.sublist(stored.length - n);

  @override
  Future<DevSessionState?> loadSession() async => session;

  @override
  Future<Map<String, DevChange>> loadChanges() async => Map<String, DevChange>.of(changes);

  @override
  Future<DevLedgerSummary> ledgerSummary() async => ledger;

  @override
  Future<List<String>> ciFailures() async => failures;

  Future<void> close() => _ctl.close();
}

class FakeControls implements DevSessionControls {
  final List<String> calls = <String>[];

  @override
  bool get canPause => true;

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<String?> openPullRequest() async {
    calls.add('pr');
    return 'https://github.com/o/r/pull/1';
  }
}

class FakeDiffSource implements DevDiffSource {
  FakeDiffSource(this.versions);

  final DevFileVersions versions;
  final List<String> asked = <String>[];

  @override
  Future<DevFileVersions?> load(String path, DevChange change) async {
    asked.add(path);
    return versions;
  }
}

final DateTime _t0 = DateTime.utc(2026, 10, 13, 9);

/// `OutlinedButton.icon` özel bir alt sınıf üretir; `byType` alt sınıfı eşleştirmez.
Finder btn(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton, description: 'OutlinedButton'),
    );

DevEvent ev(
  int i, {
  DevEventKind kind = DevEventKind.analiz,
  DevEventLevel level = DevEventLevel.bilgi,
  String? msg,
  String sha = '',
  String runUrl = '',
  List<String> files = const [],
  DateTime? ts,
}) =>
    DevEvent(
      ts: ts ?? _t0.add(Duration(seconds: i)),
      kind: kind,
      level: level,
      message: msg ?? 'olay $i',
      sha: sha,
      runUrl: runUrl,
      files: files,
    );

DevSessionState mkSession({
  DevSessionStatus status = DevSessionStatus.calisiyor,
  DateTime? startedAt,
  DateTime? updatedAt,
  Map<String, int>? counters,
  String note = '',
  String phase = 'Düzeltme (2)',
}) =>
    DevSessionState(
      id: 'oturum-1',
      status: status,
      repo: 'organizasyon-adi-cok-uzun/cok-uzun-depo-adi-kripton-uygulamasi',
      branch: 'kripton/dev-20261013-094500-cok-uzun-dal-adi-ornegi',
      baseBranch: 'main',
      headSha: '0123456789abcdef',
      startedAt: startedAt ?? DateTime.utc(2026, 10, 13, 10),
      updatedAt: updatedAt ?? DateTime.utc(2026, 10, 13, 12),
      counters: counters ?? const {'commit': 7, 'ret': 3, 'ciHata': 2, 'ciYesil': 1, 'geriAlma': 1, 'bekleme': 2},
      blockedFiles: const ['lib/a.dart'],
      models: const {
        DevRole.analyst: 'gemini:gemini-2.5-pro-ultra-cok-uzun-model-adi-ornegi',
        DevRole.fixer: 'groq:llama-3.3-70b-versatile-code-instruct-uzun',
        DevRole.verifier: 'openrouter:meta-llama/llama-3.3-70b-instruct:free',
        'hedef': 'Uygulamanın tüm ekranlarını erişilebilir yap ve testlerini yaz, uzun bir hedef metni',
        'sonYesil': 'abcdef1234567890',
      },
      phase: phase,
      note: note,
    );

List<DevChange> mkChanges() {
  const statuses = DevChangeStatus.values;
  return [
    for (var i = 0; i < 14; i++)
      DevChange(
        path: i == 0
            ? 'lib/src/service.dart'
            : 'lib/presentation/cok/uzun/klasor/yolu/ornek_dosya_adi_numara_$i.dart',
        status: statuses[i % statuses.length],
        commitSha: 'abcdef0123456789$i',
        updatedAt: _t0.add(Duration(minutes: i == 0 ? 100 : i)),
        commits: i + 1,
        last: const DevContentDigest(length: 120, lines: 6, hash: 'deadbeefdeadbeef', preview: 'x'),
      ),
  ];
}

FakeFeed richFeed() {
  final f = FakeFeed();
  f.session = mkSession();
  f.changes = {for (final c in mkChanges()) c.path: c};
  f.ledger = const DevLedgerSummary(
    models: [
      DevModelStat(modelId: 'gemini:gemini-2.5-pro-ultra-cok-uzun-model-adi-ornegi', rejects: 6, rate: 0.7, samples: 9, demoted: true),
      DevModelStat(modelId: 'groq:llama-3.3-70b-versatile-code-instruct-uzun', rejects: 2, rate: 0.2, samples: 8),
      DevModelStat(modelId: 'openrouter:meta-llama/llama-3.3-70b-instruct:free', rejects: 1, rate: 0, samples: 0),
    ],
    gates: [DevGateStat(code: 'G3', count: 5), DevGateStat(code: 'G5', count: 2), DevGateStat(code: 'V1', count: 1)],
  );
  final long = 'Çok uzun bir mesaj ' * 12;
  final kinds = DevEventKind.values;
  for (var i = 0; i < 40; i++) {
    final k = kinds[i % kinds.length];
    f.stored.add(ev(
      i,
      kind: k,
      level: i % 7 == 0 ? DevEventLevel.hata : (i % 3 == 0 ? DevEventLevel.uyari : DevEventLevel.bilgi),
      msg: '$k olayı $i $long',
      sha: k == DevEventKind.commit ? 'abcdef0123456789' : '',
    ));
  }
  f.stored.add(ev(
    100,
    kind: DevEventKind.ci,
    level: DevEventLevel.uyari,
    msg: 'Actions başarısız (aşama: build, imza ab12, 2. kez, başarısız düzeltme: 1).',
    sha: 'abcdef0123456789',
    runUrl: 'https://github.com/o/r/actions/runs/123',
    files: ['lib/main.dart: error: Undefined name x ' * 4, 'lib/b.dart: error: hata ' * 4],
  ));
  return f;
}

class Harness {
  Harness({FakeFeed? feed, this.controls, this.diff, this.settings = const AppSettings()}) : feed = feed ?? FakeFeed();

  final FakeFeed feed;
  final FakeControls? controls;
  final FakeDiffSource? diff;
  final AppSettings settings;
  DateTime clock = DateTime.utc(2026, 10, 13, 12);
  final List<bool> wake = <bool>[];
  final List<String> copied = <String>[];
  DevViewTuning tuning = const DevViewTuning(
    pollEvery: Duration(seconds: 30),
    refreshDebounce: Duration(milliseconds: 100),
  );

  ProviderContainer container(WidgetTester t) => ProviderScope.containerOf(t.element(find.byType(DevSessionScreen)));

  Future<void> pump(WidgetTester t, Size size) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          devSessionFeedProvider.overrideWithValue(feed),
          devWakelockProvider.overrideWithValue((bool on) async {
            wake.add(on);
          }),
          devClockProvider.overrideWithValue(() => clock),
          devViewTuningProvider.overrideWithValue(tuning),
          devOpenUrlProvider.overrideWithValue((String u) async => false),
          devCopyProvider.overrideWithValue((String s) async {
            copied.add(s);
          }),
          if (controls != null) devControlsProvider.overrideWithValue(controls),
          if (diff != null) devDiffSourceProvider.overrideWithValue(diff),
          settingsProvider.overrideWith(() => SettingsController(settings)),
        ],
        child: MaterialApp(theme: buildTheme(), home: const DevSessionScreen()),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    await t.pump(const Duration(milliseconds: 50));
  }

  Future<void> dispose(WidgetTester t) async {
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    await feed.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => KPalette.current = KPalette.gece);

  // ---------------------------------------------------------------- diff (saf)

  group('computeLineDiff', () {
    test('aynı içerikte fark yok', () {
      final r = computeLineDiff('a\nb\n', 'a\nb\n');
      expect(r.identical, isTrue);
      expect(r.lines, isEmpty);
    });

    test('ekleme, silme ve bağlam; satır numaraları', () {
      final r = computeLineDiff('a\nb\nc\nd', 'a\nc\nd\ne');
      expect(r.added, 1);
      expect(r.removed, 1);
      expect(r.lines.map((l) => l.kind).toList(), [
        DevDiffKind.context,
        DevDiffKind.removed,
        DevDiffKind.context,
        DevDiffKind.context,
        DevDiffKind.added,
      ]);
      expect(r.lines[1].text, 'b');
      expect(r.lines[1].oldNo, 2);
      expect(r.lines[4].text, 'e');
      expect(r.lines[4].newNo, 4);
      expect(r.coarse, isFalse);
      expect(r.truncated, isFalse);
    });

    test('yeni dosya tümüyle eklendi, silinen dosya tümüyle silindi', () {
      final a = computeLineDiff(null, 'x\ny\n');
      expect(a.added, 2);
      expect(a.removed, 0);
      final d = computeLineDiff('x\ny\n', null);
      expect(d.removed, 2);
      expect(d.added, 0);
    });

    test('uzak değişiklikler arasında değişmeyen satırlar özetlenir', () {
      final base = [for (var i = 0; i < 100; i++) 'satir $i'];
      final changed = List<String>.of(base)
        ..[2] = 'DEGISTI 2'
        ..[90] = 'DEGISTI 90';
      final r = computeLineDiff(base.join('\n'), changed.join('\n'));
      expect(r.added, 2);
      expect(r.removed, 2);
      expect(r.lines.any((l) => l.kind == DevDiffKind.skipped && l.skippedCount > 50), isTrue);
      expect(r.lines.length, lessThan(30));
    });

    test('çok büyük diff kaba karşılaştırılır ve kesilir', () {
      final a = [for (var i = 0; i < 3000; i++) 'eski $i'].join('\n');
      final b = [for (var i = 0; i < 3000; i++) 'yeni $i'].join('\n');
      final r = computeLineDiff(a, b);
      expect(r.coarse, isTrue);
      expect(r.truncated, isTrue);
      expect(r.lines.length, lessThanOrEqualTo(const DevDiffLimits().maxOutputLines));
      expect(r.hiddenChangedLines, greaterThan(0));
      expect(r.added, 3000);
      expect(r.removed, 3000);
    });

    test('küçük sınırla LCS yerine kaba diff', () {
      final r = computeLineDiff('a\nb\nc\nd', 'a\nx\ny\nd', limits: const DevDiffLimits(maxCells: 1));
      expect(r.coarse, isTrue);
      expect(r.added, 2);
      expect(r.removed, 2);
    });

    test('sır görüntülenmeden maskelenir', () {
      final token = 'ghp_${'A' * 30}';
      final r = computeLineDiff('a\n', 'a\nanahtar = $token\n');
      final text = r.lines.map((l) => l.text).join('\n');
      expect(text.contains(token), isFalse);
    });

    test('CRLF satırları LF ile aynı sayılır', () {
      final r = computeLineDiff('a\r\nb\r\n', 'a\nb\n');
      expect(r.identical, isTrue);
    });
  });

  group('türetilmiş durum (saf)', () {
    test('devElapsed özgün başlangıçtan hesaplar; bitmişte son güncellemede donar', () {
      final s = mkSession(
        startedAt: DateTime.utc(2026, 10, 13, 6),
        updatedAt: DateTime.utc(2026, 10, 13, 11, 59),
      );
      // resume sonrası updatedAt yakın olsa da süre özgün başlangıçtan sayılır.
      expect(devElapsed(s, DateTime.utc(2026, 10, 13, 12)), const Duration(hours: 6));
      final done = mkSession(
        status: DevSessionStatus.tamamlandi,
        startedAt: DateTime.utc(2026, 10, 13, 6),
        updatedAt: DateTime.utc(2026, 10, 13, 8),
      );
      expect(devElapsed(done, DateTime.utc(2026, 10, 14)), const Duration(hours: 2));
    });

    test('devFormatDuration', () {
      expect(devFormatDuration(const Duration(hours: 22)), '22:00:00');
      expect(devFormatDuration(const Duration(seconds: 80)), '0:01:20');
      expect(devFormatDuration(const Duration(days: 2, hours: 3, minutes: 4, seconds: 5)), '2 g 03:04:05');
      expect(devFormatDuration(const Duration(seconds: -5)), '0:00:00');
    });

    test('deriveCiInfo: başarılı, başarısız ve bekleyen', () {
      var ci = deriveCiInfo(DevCiInfo.none, [
        ev(1, kind: DevEventKind.ci, msg: 'Actions çalışıyor: build', runUrl: 'https://x/y/1'),
      ]);
      expect(ci.state, DevCiState.calisiyor);
      expect(ci.runUrl, 'https://x/y/1');
      ci = deriveCiInfo(ci, [
        ev(2, kind: DevEventKind.ci, level: DevEventLevel.uyari, msg: 'Actions başarısız (aşama: test, imza a1, 1. kez, başarısız düzeltme: 0).', sha: 's1', files: ['lib/a.dart: hata']),
      ]);
      expect(ci.state, DevCiState.basarisiz);
      expect(ci.stage, 'test');
      expect(ci.failures, ['lib/a.dart: hata']);
      ci = deriveCiInfo(ci, [ev(3, kind: DevEventKind.ci, msg: 'Actions başarılı.', sha: 's2')]);
      expect(ci.state, DevCiState.basarili);
      expect(ci.failures, isEmpty);
      ci = deriveCiInfo(ci, [ev(4, kind: DevEventKind.bekleme, msg: 'Actions/ağ sorunu (rateLimit): x — 30 sn sonra yeniden denenecek.')]);
      expect(ci.state, DevCiState.bekliyor);
    });

    test('deriveWaitInfo: yeniden deneme zamanı ve temizlenme', () {
      final w = deriveWaitInfo(null, [
        ev(0, kind: DevEventKind.bekleme, level: DevEventLevel.uyari, msg: 'analist için tüm modeller parkta; 45 sn bekleniyor (x).'),
      ]);
      expect(w, isNotNull);
      expect(w!.retryAt, _t0.add(const Duration(seconds: 45)));
      expect(deriveWaitInfo(w, [ev(1, kind: DevEventKind.commit, msg: 'Commit atıldı')]), isNull);
      expect(deriveWaitInfo(w, [ev(1, kind: DevEventKind.analiz, level: DevEventLevel.uyari, msg: 'model hatası')]), isNotNull);
    });

    test('DevEventWindow: sınır, gezinme ve canlıya dönüş', () {
      final w = DevEventWindow(capacity: 5);
      w.resetTo([for (var i = 0; i < 3; i++) ev(i)], maybeMore: false);
      expect(w.items.length, 3);
      expect(w.hasOlder, isFalse);
      w.append([for (var i = 3; i < 10; i++) ev(i)]);
      expect(w.items.length, 5);
      expect(w.items.first.message, 'olay 5');
      expect(w.hasOlder, isTrue);
      w.showPage([for (var i = 0; i < 5; i++) ev(i)], newer: 5, hasOlder: false);
      expect(w.atTail, isFalse);
      w.append([ev(10), ev(11)]);
      expect(w.items.length, 5);
      expect(w.newer, 7);
    });
  });

  // ---------------------------------------------------------------- kaynak denetimi

  test('ekran dosyalarında alttan açılan sayfa kullanılmaz', () {
    final bad = <String>[
      'show${'Modal'}BottomSheet',
      'show${'Bottom'}Sheet',
      '${'Bottom'}Sheet',
      'bottom${'Sheet'}:',
    ];
    for (final f in const [
      'lib/presentation/dev_session_screen.dart',
      'lib/presentation/dev_diff_view.dart',
      'lib/presentation/dev_session_providers.dart',
    ]) {
      final src = File(f).readAsStringSync();
      for (final b in bad) {
        expect(src.contains(b), isFalse, reason: '$f içinde "$b" geçmemeli');
      }
    }
  });

  // ---------------------------------------------------------------- widget: düzen / taşma

  group('düzen ve taşma', () {
    testWidgets('1280x800: 3 sütun, taşma yok', (t) async {
      final h = Harness(feed: richFeed());
      await h.pump(t, const Size(1280, 800));
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('dev-layout-wide')), findsOneWidget);
      expect(find.byKey(const ValueKey('dev-layout-medium')), findsNothing);
      expect(find.byType(TabBar), findsNothing);
      expect(find.byKey(const ValueKey('dev-timeline-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('dev-files-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('dev-log-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('dev-ci-list')), findsOneWidget);
      expect(find.text('Çalışıyor'), findsOneWidget);
      expect(find.text('Dalı PR olarak aç'), findsOneWidget);
      expect(find.text('CI: başarısız'), findsWidgets);
      await h.dispose(t);
    });

    testWidgets('800x1280: 2 sütun, taşma yok', (t) async {
      final h = Harness(feed: richFeed());
      await h.pump(t, const Size(800, 1280));
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('dev-layout-medium')), findsOneWidget);
      expect(find.byKey(const ValueKey('dev-layout-wide')), findsNothing);
      expect(find.byType(TabBar), findsNothing);
      expect(find.byKey(const ValueKey('dev-files-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('dev-log-list')), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('400x800: sekmeler, her sekme taşmadan çizilir, alttan sayfa yok', (t) async {
      final h = Harness(feed: richFeed());
      await h.pump(t, const Size(400, 800));
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('dev-layout-tabs')), findsOneWidget);
      expect(find.byType(TabBar), findsOneWidget);
      for (final tab in const ['Dosyalar', 'Günlük', 'CI ve defter', 'Aşamalar']) {
        await t.tap(find.text(tab));
        await t.pump(const Duration(milliseconds: 400));
        await t.pump(const Duration(milliseconds: 400));
        expect(t.takeException(), isNull, reason: 'sekme: $tab');
      }
      expect(find.byType(BottomSheet), findsNothing);
      await h.dispose(t);
    });

    testWidgets('sınır genişlikler: 999 ve 600 dp taşmaz', (t) async {
      for (final w in const [999.0, 1000.0, 600.0, 599.0]) {
        final h = Harness(feed: richFeed());
        await h.pump(t, Size(w, 800));
        expect(t.takeException(), isNull, reason: 'genişlik $w');
        await h.dispose(t);
      }
    });

    testWidgets('Sade Mod: animasyon kapalı ve üç boyutta taşma yok', (t) async {
      for (final size in const [Size(1280, 800), Size(800, 1280), Size(400, 800)]) {
        final h = Harness(feed: richFeed(), settings: const AppSettings(liteOnStart: true));
        await h.pump(t, size);
        expect(t.takeException(), isNull, reason: '$size');
        expect(TickerMode.of(t.element(find.byType(Scaffold).first)), isFalse);
        await h.dispose(t);
      }
    });

    testWidgets('kaynak bağlı değilse açıklama gösterilir', (t) async {
      t.view.physicalSize = const Size(800, 600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        ProviderScope(
          overrides: [devWakelockProvider.overrideWithValue((bool on) async {})],
          child: MaterialApp(theme: buildTheme(), home: const DevSessionScreen()),
        ),
      );
      await t.pump();
      expect(find.textContaining('kaynağı bağlı değil'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  // ---------------------------------------------------------------- widget: canlı güncelleme

  group('canlı güncelleme', () {
    testWidgets('geçen süre saniyede güncellenir ve özgün başlangıçtan hesaplanır', (t) async {
      final f = FakeFeed()..session = mkSession(startedAt: DateTime.utc(2026, 10, 13, 10));
      final h = Harness(feed: f);
      await h.pump(t, const Size(1280, 800));
      expect(find.textContaining('Geçen 2:00:00'), findsOneWidget);
      expect(find.textContaining('Kalan 22:00:00 / 24 sa'), findsOneWidget);
      h.clock = h.clock.add(const Duration(seconds: 5));
      await t.pump(const Duration(seconds: 5));
      expect(find.textContaining('Geçen 2:00:05'), findsOneWidget);
      expect(find.textContaining('Kalan 21:59:55'), findsOneWidget);

      // Resume: kontrol noktası güncellense de başlangıç değişmez.
      f.session = mkSession(startedAt: DateTime.utc(2026, 10, 13, 10), updatedAt: h.clock);
      f.emit(ev(500, kind: DevEventKind.asama, msg: 'Oturum devam ediyor: x'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Geçen 2:00:05'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('bitmiş oturumda süre donar', (t) async {
      final f = FakeFeed()
        ..session = mkSession(
          status: DevSessionStatus.tamamlandi,
          startedAt: DateTime.utc(2026, 10, 13, 10),
          updatedAt: DateTime.utc(2026, 10, 13, 11),
        );
      final h = Harness(feed: f);
      await h.pump(t, const Size(1280, 800));
      expect(find.textContaining('Geçen 1:00:00'), findsOneWidget);
      h.clock = h.clock.add(const Duration(minutes: 30));
      await t.pump(const Duration(seconds: 3));
      expect(find.textContaining('Geçen 1:00:00'), findsOneWidget);
      expect(find.text('Bitti'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('olay akışı günlüğü, zaman çizgisini ve CI özetini günceller', (t) async {
      final f = FakeFeed()..session = mkSession();
      final h = Harness(feed: f);
      await h.pump(t, const Size(1280, 800));
      expect(find.text('Henüz olay yok.'), findsWidgets);

      f.emit(ev(1, kind: DevEventKind.asama, msg: 'Tur 1: lib/main.dart'));
      f.emit(ev(2, kind: DevEventKind.analiz, msg: 'Sorun bulundu: eksik null kontrolü'));
      f.emit(ev(3, kind: DevEventKind.ci, level: DevEventLevel.uyari, msg: 'Actions başarısız (aşama: analyze, imza x, 1. kez, başarısız düzeltme: 0).', runUrl: 'https://github.com/o/r/actions/runs/9', sha: 'abcdef0123'));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump();

      expect(find.textContaining('Sorun bulundu: eksik null kontrolü'), findsOneWidget); // günlük
      expect(find.textContaining('Tur 1: lib/main.dart'), findsWidgets); // günlük + zaman çizgisi
      expect(find.text('CI: başarısız'), findsWidgets);
      expect(find.textContaining('Aşama: analyze'), findsOneWidget);
      expect(find.textContaining('https://github.com/o/r/actions/runs/9'), findsOneWidget);
      expect(t.takeException(), isNull);
      await h.dispose(t);
    });

    testWidgets('commit olayı dosya listesini tazeler; seçilince diff görünür', (t) async {
      final f = FakeFeed()..session = mkSession();
      final diff = FakeDiffSource(const DevFileVersions(
        before: 'alpha\nbeta\ngamma\n',
        after: 'alpha\nBETA\ngamma\ndelta\n',
      ));
      final h = Harness(feed: f, diff: diff);
      await h.pump(t, const Size(1280, 800));
      expect(find.text('Henüz değişen dosya yok.'), findsOneWidget);

      f.changes = {
        'lib/src/service.dart': DevChange(
          path: 'lib/src/service.dart',
          status: DevChangeStatus.degistirildi,
          commitSha: 'abcdef0123456789',
          updatedAt: _t0,
          commits: 2,
        ),
      };
      f.emit(ev(1, kind: DevEventKind.commit, msg: 'Commit atıldı', sha: 'abcdef0123456789'));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump();
      expect(find.text('lib/src/service.dart'), findsOneWidget);
      expect(find.text('Değişti'), findsOneWidget);

      await t.tap(find.text('lib/src/service.dart'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      expect(diff.asked, ['lib/src/service.dart']);
      expect(find.byType(DevDiffView), findsOneWidget);
      expect(find.text('BETA'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      expect(find.text('delta'), findsOneWidget);
      expect(find.text('+2 eklendi'), findsOneWidget);
      expect(find.text('−1 silindi'), findsOneWidget);

      await t.tap(find.byTooltip('Diff görünümünü kapat'));
      await t.pump();
      expect(find.byType(DevDiffView), findsNothing);
      expect(t.takeException(), isNull);
      await h.dispose(t);
    });

    testWidgets('diff kaynağı yoksa içerik özeti ile açıklama gösterilir', (t) async {
      final h = Harness(feed: richFeed());
      await h.pump(t, const Size(1280, 800));
      await t.tap(find.text('lib/src/service.dart'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Diff kaynağı bağlı değil.'), findsOneWidget);
      expect(find.textContaining('Son içerik: 6 satır'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('telefonda dosya seçilince diff aynı sekmede açılır, geri dönülür', (t) async {
      final diff = FakeDiffSource(const DevFileVersions(before: 'a\n', after: 'a\nb\n'));
      final h = Harness(feed: richFeed(), diff: diff);
      await h.pump(t, const Size(400, 800));
      await t.tap(find.text('Dosyalar'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.text('lib/src/service.dart'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byType(DevDiffView), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await t.tap(find.byTooltip('Dosya listesine dön'));
      await t.pump();
      expect(find.byType(DevDiffView), findsNothing);
      expect(t.takeException(), isNull);
      await h.dispose(t);
    });

    testWidgets('seviye filtresi', (t) async {
      final f = FakeFeed()..session = mkSession();
      f.stored.addAll([
        ev(1, msg: 'sıradan bilgi'),
        ev(2, level: DevEventLevel.uyari, msg: 'dikkat uyarısı'),
        ev(3, level: DevEventLevel.hata, msg: 'kötü hata'),
      ]);
      final h = Harness(feed: f);
      await h.pump(t, const Size(1280, 800));
      expect(find.textContaining('sıradan bilgi'), findsOneWidget);
      expect(find.textContaining('dikkat uyarısı'), findsOneWidget);
      expect(find.textContaining('kötü hata'), findsOneWidget);
      await t.tap(find.text('Hata'));
      await t.pump();
      expect(find.textContaining('sıradan bilgi'), findsNothing);
      expect(find.textContaining('dikkat uyarısı'), findsNothing);
      expect(find.textContaining('kötü hata'), findsOneWidget);
      await t.tap(find.text('Tümü'));
      await t.pump();
      expect(find.textContaining('sıradan bilgi'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('sırlar ekranda görünmez', (t) async {
      final f = FakeFeed()..session = mkSession();
      final token = 'ghp_${'q' * 30}';
      f.stored.add(ev(1, msg: 'istek başarısız, belirteç $token sızdı'));
      final h = Harness(feed: f);
      await h.pump(t, const Size(1280, 800));
      expect(find.textContaining(token), findsNothing);
      expect(find.textContaining('ghp_qqqq'), findsNothing);
      expect(find.textContaining('istek başarısız'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('Bekliyor: neden ve yeniden deneme zamanı gösterilir', (t) async {
      final f = FakeFeed()
        ..session = mkSession(status: DevSessionStatus.bekliyor, note: 'Actions/ağ bekleniyor: rateLimit');
      final h = Harness(feed: f);
      f.stored.add(ev(
        0,
        kind: DevEventKind.bekleme,
        level: DevEventLevel.uyari,
        msg: 'Actions/ağ sorunu (rateLimit): sınır aşıldı — AI\'ya hata diye verilmez; 90 sn sonra yeniden denenecek.',
        ts: h.clock.subtract(const Duration(seconds: 10)),
      ));
      await h.pump(t, const Size(1280, 800));
      expect(find.text('Bekleniyor'), findsOneWidget);
      expect(find.textContaining('sınır aşıldı'), findsWidgets);
      expect(find.textContaining('Yeniden deneme: 0:01:20 sonra'), findsOneWidget);
      expect(find.text('Bekliyor'), findsOneWidget); // durum rozeti (metin olarak)
      h.clock = h.clock.add(const Duration(seconds: 30));
      await t.pump(const Duration(seconds: 30));
      expect(find.textContaining('Yeniden deneme: 0:00:50 sonra'), findsOneWidget);
      await h.dispose(t);
    });
  });

  // ---------------------------------------------------------------- performans

  group('performans', () {
    testWidgets('güncellemeler saniyede en çok 4 kez yayınlanır', (t) async {
      final f = FakeFeed()..session = mkSession();
      final h = Harness(feed: f);
      await h.pump(t, const Size(1280, 800));
      final c = h.container(t);
      final before = c.read(devSessionViewProvider).revision;
      for (var i = 0; i < 100; i++) {
        f.emit(ev(i + 1, msg: 'akış $i'));
        await t.pump(const Duration(milliseconds: 10));
      }
      final during = c.read(devSessionViewProvider).revision - before;
      expect(during, lessThanOrEqualTo(4), reason: '1 sn içinde yayın sayısı');
      expect(during, greaterThan(0));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump();
      expect(c.read(devSessionViewProvider).events.length, 100);
      expect(c.read(devSessionViewProvider).events.last.message, 'akış 99');
      await h.dispose(t);
    });

    testWidgets('RAM penceresi 500 olayı geçmez; Daha eski store\'dan sayfalar', (t) async {
      final f = FakeFeed()..session = mkSession();
      for (var i = 0; i < 120; i++) {
        f.stored.add(ev(i));
      }
      final h = Harness(feed: f);
      await h.pump(t, const Size(1280, 800));
      final c = h.container(t);
      expect(c.read(devSessionViewProvider).events.length, 120);
      expect(c.read(devSessionViewProvider).hasOlder, isFalse);

      for (var i = 120; i < 720; i++) {
        f.emit(ev(i));
        if (i % 100 == 0) await t.pump(const Duration(milliseconds: 300));
      }
      await t.pump(const Duration(milliseconds: 300));
      await t.pump();

      var v = c.read(devSessionViewProvider);
      expect(v.events.length, 500);
      expect(v.events.last.message, 'olay 719');
      expect(v.events.first.message, 'olay 220');
      expect(v.hasOlder, isTrue);
      expect(v.atTail, isTrue);
      expect(find.text('Daha eski'), findsOneWidget);

      await t.tap(find.text('Daha eski'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      v = c.read(devSessionViewProvider);
      expect(v.events.length, lessThanOrEqualTo(500));
      expect(v.events.last.message, 'olay 619');
      expect(v.events.first.message, 'olay 120');
      expect(v.newer, 100);
      expect(v.atTail, isFalse);
      expect(find.textContaining('Canlıya dön (100 yeni olay)'), findsOneWidget);

      // Gezinirken gelen olay pencereyi değiştirmez, yalnızca sayaç artar.
      f.emit(ev(720));
      await t.pump(const Duration(milliseconds: 300));
      v = c.read(devSessionViewProvider);
      expect(v.events.last.message, 'olay 619');
      expect(v.newer, 101);

      await t.tap(find.textContaining('Canlıya dön'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      v = c.read(devSessionViewProvider);
      expect(v.atTail, isTrue);
      expect(v.events.length, 500);
      expect(v.events.last.message, 'olay 720');
      expect(t.takeException(), isNull);
      await h.dispose(t);
    });

    testWidgets('ekran kapanınca abonelik ve zamanlayıcılar bırakılır', (t) async {
      final f = FakeFeed()..session = mkSession();
      final h = Harness(feed: f);
      await h.pump(t, const Size(1280, 800));
      f.emit(ev(1));
      await h.dispose(t);
      // Bekleyen zamanlayıcı kalırsa test çatısı burada hata verir.
      await t.pump(const Duration(seconds: 120));
    });
  });

  // ---------------------------------------------------------------- ekran kilidi ve denetimler

  group('ekran kilidi', () {
    testWidgets('açılışta etkinleştirilir; oturum sürüyorsa kapanışta bırakılmaz', (t) async {
      final f = FakeFeed()..session = mkSession();
      final h = Harness(feed: f);
      await h.pump(t, const Size(1280, 800));
      expect(h.wake, [true]);
      await h.dispose(t);
      expect(h.wake, [true]);
    });

    testWidgets('oturum bitmişse kapanışta bırakılır', (t) async {
      final f = FakeFeed()..session = mkSession(status: DevSessionStatus.tamamlandi);
      final h = Harness(feed: f);
      await h.pump(t, const Size(1280, 800));
      await h.dispose(t);
      expect(h.wake, [true, false]);
    });
  });

  group('denetimler', () {
    testWidgets('bağlı değilken düğmeler pasif', (t) async {
      final h = Harness(feed: richFeed());
      await h.pump(t, const Size(1280, 800));
      final pause = t.widget<OutlinedButton>(btn('Duraklat'));
      expect(pause.onPressed, isNull);
      final stop = t.widget<OutlinedButton>(btn('Durdur'));
      expect(stop.onPressed, isNull);
      await h.dispose(t);
    });

    testWidgets('Duraklat, Durdur (onaylı) ve PR çağrılır; dokunma hedefleri ≥ 48 dp', (t) async {
      final ctl = FakeControls();
      final h = Harness(feed: richFeed(), controls: ctl);
      await h.pump(t, const Size(1280, 800));

      for (final label in const ['Duraklat', 'Durdur', 'Dalı PR olarak aç']) {
        final size = t.getSize(btn(label));
        expect(size.height, greaterThanOrEqualTo(48), reason: label);
        expect(size.width, greaterThanOrEqualTo(48), reason: label);
      }

      await t.tap(btn('Duraklat'));
      await t.pump();
      await t.pump();
      expect(ctl.calls, ['pause']);

      await t.tap(btn('Durdur'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);
      await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Vazgeç')));
      await t.pump(const Duration(milliseconds: 300));
      expect(ctl.calls, ['pause']);

      await t.tap(btn('Durdur'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Durdur')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(ctl.calls, ['pause', 'stop']);

      await t.tap(btn('Dalı PR olarak aç'));
      await t.pump();
      await t.pump();
      expect(ctl.calls, ['pause', 'stop', 'pr']);
      expect(t.takeException(), isNull);
      await h.dispose(t);
    });

    testWidgets('duraklatılmış oturumda Devam gösterilir', (t) async {
      final ctl = FakeControls();
      final f = FakeFeed()..session = mkSession(status: DevSessionStatus.duraklatildi);
      final h = Harness(feed: f, controls: ctl);
      await h.pump(t, const Size(1280, 800));
      expect(find.text('Duraklatıldı'), findsOneWidget);
      await t.tap(btn('Devam'));
      await t.pump();
      await t.pump();
      expect(ctl.calls, ['resume']);
      await h.dispose(t);
    });

    testWidgets('çalıştırma bağlantısı açılamazsa panoya kopyalanır', (t) async {
      final h = Harness(feed: richFeed());
      await h.pump(t, const Size(1280, 800));
      await t.ensureVisible(find.byTooltip('Bağlantıyı kopyala'));
      await t.pump();
      await t.tap(find.byTooltip('Bağlantıyı kopyala'));
      await t.pump();
      expect(h.copied, ['https://github.com/o/r/actions/runs/123']);
      await h.dispose(t);
    });
  });

  group('hata defteri ve erişilebilirlik', () {
    testWidgets('model başına ret oranı ve en sık kapı gösterilir', (t) async {
      final h = Harness(feed: richFeed());
      await h.pump(t, const Size(1280, 800));
      // Defter bölümü sağ-alt panelde kaydırılabilir listededir.
      await t.scrollUntilVisible(
        find.textContaining('En sık kapı: G3'),
        100,
        scrollable: find.descendant(of: find.byKey(const ValueKey('dev-ci-list')), matching: find.byType(Scrollable)),
      );
      expect(find.textContaining('En sık kapı: G3'), findsOneWidget);
      expect(find.textContaining('ret oranı %70'), findsWidgets);
      expect(t.takeException(), isNull);
      await h.dispose(t);
    });

    testWidgets('durum yalnızca renkle değil metin ve ikonla verilir; Semantics etiketleri var', (t) async {
      final handle = t.ensureSemantics();
      final h = Harness(feed: richFeed());
      await h.pump(t, const Size(1280, 800));
      expect(find.text('Çalışıyor'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline), findsWidgets);
      expect(find.bySemanticsLabel('Durum: Çalışıyor'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Geçen süre .* kalan süre .*')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Commit sayısı 7')), findsOneWidget);
      handle.dispose();
      await h.dispose(t);
    });
  });
}
