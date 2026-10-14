// Görev 9/19: uzun süre açık kalma dayanıklılığı testleri. Sahte repo/CI/havuz/AI ve sahte saat; gerçek ağ yok.
// Senaryolar: (1) 48 saatlik simüle oturum (sınırlar), (2) servis zaman aşımı → duraklat → devam (veri kaybı yok),
// (3) süreç ölümü + resume (aynı dal/sayaç/bloklu dosya, kesinti süreden sayılmaz), (4) ağ kesintisi (repo + model),
// (5) kota yavaşlatma, (6) termal duraklat/devam, (7) iptal duraklamayı çözer.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/dev_ledger.dart';
import 'package:kripton_ai/application/dev_mode.dart';
import 'package:kripton_ai/application/dev_model_pool.dart';
import 'package:kripton_ai/application/dev_session_engine.dart';
import 'package:kripton_ai/application/dev_session_store.dart';
import 'package:kripton_ai/application/workflow_runner.dart' show CancelToken;
import 'package:kripton_ai/data/ci_feedback.dart';
import 'package:kripton_ai/data/cloud_engine.dart';
import 'package:kripton_ai/data/github_ci.dart';
import 'package:kripton_ai/data/github_repo.dart';
import 'package:kripton_ai/data/native_services.dart' show KeepAliveEvent, KeepAliveEventKind;
import 'package:kripton_ai/data/project_snapshot.dart';
import 'package:kripton_ai/data/secret_mask.dart';

final String _token = 'gh${'p'}_${'Q' * 30}0000';

const _pubspec = '''
name: demo
version: 1.0.0+1
dependencies:
  flutter:
    sdk: flutter
  http: ^1.2.2
flutter:
  uses-material-design: true
''';

const _main = '''
import 'package:flutter/material.dart';
import 'util.dart';

void main() {
  runApp(const Text('x'));
}

int hesapla(int a) {
  return a + 1;
}

int ikili() {
  return 2;
}
''';

Map<String, String> _files() => {
      'pubspec.yaml': _pubspec,
      'lib/main.dart': _main,
      'lib/util.dart': 'int yardim() => 1;\n',
    };

String _patch(String path, String old, String neu) =>
    '<<<<<<< DOSYA: $path\n<<<<<<< ESKİ\n$old\n=======\n$neu\n>>>>>>> YENİ\n';

const _finding = 'Dosya: lib/main.dart\nYer: hesapla\nSorun: dönüş değeri yanlış\nDüzeltme: bir artır';
const _clean = '[SORUN YOK]';
const _approve = 'KARAR: ONAY\n- yama bulguyu çözüyor';
const _reject = 'KARAR: RED\n- bulguyla ilgisiz';

/// Kullanıcı metnindeki ilk `return a + K;` değerini bulup K → K+1 yaması üretir.
String _bump(String user) {
  final m = RegExp(r'return a \+ (\d+);').firstMatch(user);
  final k = m == null ? 1 : int.parse(m.group(1)!);
  return _patch('lib/main.dart', '  return a + $k;', '  return a + ${k + 1};');
}

// ------------------------------------------------------------------ sahte repo

class _Commit {
  _Commit(this.sha, this.files);

  final String sha;
  final Map<String, String> files;
}

class _Repo implements DevRepoPort {
  _Repo(Map<String, String> files) {
    _commits.add(_Commit(_sha(), {...files}));
  }

  final List<_Commit> _commits = [];
  int _n = 0;
  String? branch;
  int commitCalls = 0;
  int revertCalls = 0;
  int prCalls = 0;
  bool injectConflict = false;
  int failCommits = 0;
  final List<String?> createNames = [];
  final List<Map<String, String?>> committed = [];

  String _sha() => 'c${_n++}'.padRight(40, '0');

  _Commit get _cur => _commits.last;
  String get head => _cur.sha;
  Map<String, String> get files => _cur.files;

  @override
  Future<WorkBranch> createWorkBranch(String baseBranch, {String? name}) async {
    createNames.add(name);
    final exists = name != null && branch == name;
    branch ??= name ?? 'kripton/dev-fake';
    return WorkBranch(name: branch!, headSha: head, baseBranch: baseBranch, baseSha: _commits.first.sha, resumed: exists);
  }

  @override
  Future<RepoLoadResult> loadSnapshotWithInfo(String b) async => RepoLoadResult(
        ProjectSnapshot(name: 'demo', text: {...files}),
        head,
        RepoLoadStats(headSha: head, treeSha: 't'),
      );

  @override
  Future<String> commitChanges(String b, String expected, Map<String, String?> changes, String message) async {
    commitCalls++;
    if (failCommits > 0) {
      failCommits--;
      throw const SocketException('bağlantı koptu');
    }
    if (injectConflict) {
      injectConflict = false;
      _commits.add(_Commit(_sha(), {...files, 'NOTES.md': 'başka biri yazdı'}));
    }
    if (expected != head) {
      throw DevConflictException(branch: b, expectedSha: expected, actualSha: head);
    }
    final next = {...files};
    changes.forEach((k, v) => v == null ? next.remove(k) : next[k] = v);
    committed.add({...changes});
    _commits.add(_Commit(_sha(), next));
    return head;
  }

  @override
  Future<String> revertTo(String b, String target, String message, {String? expectedHeadSha}) async {
    revertCalls++;
    final t = _commits.firstWhere((c) => c.sha == target);
    _commits.add(_Commit(_sha(), {...t.files}));
    return head;
  }

  @override
  Future<PullRequestInfo> openPullRequest(String h, String base, String title, String body, {bool draft = false}) async {
    prCalls++;
    return PullRequestInfo(
      number: 1,
      htmlUrl: 'https://example.test/pr/1',
      state: 'open',
      headRef: h,
      baseRef: base,
      headSha: head,
    );
  }
}

// ------------------------------------------------------------------ sahte CI

CiFailure _failure(String sha, {String message = 'undefined_function hata', String code = 'undefined_function'}) {
  final r = CiResult(
    ok: false,
    stage: 'analyze',
    diagnostics: [
      CiDiagnostic(
        path: 'lib/main.dart',
        line: 9,
        column: 3,
        severity: 'error',
        message: message,
        raw: 'error • $message • lib/main.dart:9:3',
        code: code,
      ),
    ],
    stageLog: 'error • $message • lib/main.dart:9:3',
    exitCode: 1,
  );
  return CiFailure(
    signature: CiFailureSignature.of(r),
    feedback: 'ARAÇ ÇIKTISI: $message',
    result: r,
    sha: sha,
    runUrl: 'https://example.test/run/1',
  );
}

class _Ci implements DevCiPort {
  _Ci(this.repo, [List<Future<CiOutcome> Function()>? script]) : script = script ?? [];

  final _Repo repo;
  final List<Future<CiOutcome> Function()> script;
  int calls = 0;

  @override
  Future<CiOutcome> checkBranch(String branch, {void Function(String status)? status}) async {
    calls++;
    if (script.isEmpty) return CiSuccess(sha: repo.head);
    return script.removeAt(0)();
  }
}

Future<CiOutcome> Function() _ok(_Repo r) => () async => CiSuccess(sha: r.head);
Future<CiOutcome> Function() _fail(_Repo r, {String message = 'undefined_function hata', String code = 'undefined_function'}) =>
    () async => _failure(r.head, message: message, code: code);
Future<CiOutcome> Function() _infra(_Repo r, {String message = 'ağ koptu'}) => () async =>
    CiInfraError(reason: CiInfraReason.network, message: message, sha: r.head);

// ------------------------------------------------------------------ sahte havuz ve AI

class _Pool implements DevPoolPort {
  _Pool({this.single = false});

  final bool single;
  int waitFirst = 0;
  int picks = 0;
  final List<PoolReport> reports = [];
  static const _a = PoolModel(provider: CloudProvider.gemini, model: 'analist-m');
  static const _f = PoolModel(provider: CloudProvider.groq, model: 'fixer-m');
  static const _v = PoolModel(provider: CloudProvider.openrouter, model: 'ver-m:free');

  @override
  PoolPick pick(String role, {Set<String> exclude = const {}, String? differFrom}) {
    picks++;
    if (waitFirst > 0) {
      waitFirst--;
      return const PoolPick.wait(Duration(seconds: 7), 'hepsi parkta');
    }
    if (role == DevRole.analyst) return const PoolPick.ok(_a);
    if (role == DevRole.fixer) return const PoolPick.ok(_f);
    return PoolPick.ok(single ? _f : _v);
  }

  @override
  bool report(PoolReport r) {
    reports.add(r);
    return true;
  }
}

class _Ai {
  int analystCalls = 0;
  int fixerCalls = 0;
  int verifierCalls = 0;
  final List<String> analystPrompts = [];
  String Function(int n, String user) analyst = (n, _) => n == 1 ? _finding : _clean;
  String Function(int n, String user) fixer = (n, user) => _bump(user);
  String Function(int n, String user) verifier = (n, _) => _approve;
  void Function(int n)? onAnalyst;

  Future<String> call(PoolModel m, String system, String user, CancelToken ct) async {
    if (system == DevPrompts.analystSystem || system == DevPrompts.improverSystem) {
      analystCalls++;
      analystPrompts.add(user);
      onAnalyst?.call(analystCalls);
      return analyst(analystCalls, user);
    }
    if (system == DevPrompts.fixerSystem) {
      fixerCalls++;
      return fixer(fixerCalls, user);
    }
    if (system == DevPrompts.verifierSystem) {
      verifierCalls++;
      return verifier(verifierCalls, user);
    }
    throw StateError('bilinmeyen sistem istemi');
  }
}

// ------------------------------------------------------------------ düzen

class _Clock {
  DateTime t = DateTime.utc(2026, 10, 13, 8);
  final List<Duration> sleeps = [];

  Future<void> sleep(Duration d, CancelToken ct) async {
    sleeps.add(d);
    t = t.add(d);
    await Future<void>.delayed(Duration.zero);
  }
}

class _Rig {
  _Rig({
    Map<String, String>? files,
    bool single = false,
    List<Future<CiOutcome> Function()> Function(_Repo)? ciScript,
    DevSessionConfig? config,
    required this.tmp,
    String sessionId = 's1',
    bool defaultSleep = false,
    this.gate,
    DevNetProbe? probe,
  }) {
    repo = _Repo(files ?? _files());
    ci = _Ci(repo, ciScript?.call(repo));
    pool = _Pool(single: single);
    store = DevSessionStore(
      baseDir: tmp,
      sessionId: sessionId,
      flushInterval: const Duration(milliseconds: 20),
      now: () => clock.t,
    );
    ledger = DevLedger(dir: Directory('${tmp.path}/ledger'));
    cfg = config ?? _cfg();
    engine = DevSessionEngine(
      config: cfg,
      repo: repo,
      ci: ci,
      callModel: ai.call,
      pool: pool,
      store: store,
      ledger: ledger,
      now: () => clock.t,
      sleep: defaultSleep ? null : clock.sleep,
      gate: gate,
      netProbe: probe ?? (() async => false),
    );
  }

  final Directory tmp;
  final DevPauseGate? gate;
  late final _Repo repo;
  late final _Ci ci;
  late final _Pool pool;
  late final DevSessionStore store;
  late final DevLedger ledger;
  late final DevSessionConfig cfg;
  late final DevSessionEngine engine;
  final _Ai ai = _Ai();
  final _Clock clock = _Clock();
}

DevSessionConfig _cfg({
  int maxConsecutiveFailures = 12,
  Duration infraWaitingAfter = const Duration(minutes: 30),
  Duration maxDuration = const Duration(days: 3),
  bool openPullRequest = false,
}) =>
    DevSessionConfig(
      repo: 'sahip/depo',
      baseBranch: 'main',
      maxDuration: maxDuration,
      maxConsecutiveFailures: maxConsecutiveFailures,
      infraWaitingAfter: infraWaitingAfter,
      openPullRequest: openPullRequest,
    );

Future<void> _until(Future<bool> Function() cond, {int tries = 400}) async {
  for (var i = 0; i < tries; i++) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Koşul zamanında sağlanmadı.');
}

Future<List<DevEvent>> _events(DevSessionStore s) async {
  await s.flush();
  return s.tail(5000);
}

String _readAll(Directory d) {
  final b = StringBuffer();
  for (final e in d.listSync(recursive: true)) {
    if (e is File) b.writeln(e.readAsStringSync());
  }
  return b.toString();
}


void main() {
  late Directory tmp;

  setUp(() {
    SecretMask.clear();
    tmp = Directory.systemTemp.createTempSync('devresil_test_');
  });

  tearDown(() {
    SecretMask.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  int dirBytes(Directory d) {
    var n = 0;
    for (final e in d.listSync(recursive: true)) {
      if (e is File) n += e.lengthSync();
    }
    return n;
  }

  test('(1) 48 saatlik simüle oturum: olay/log/sayaç sınırları aşılmaz, bekleyen uyku kalmaz', () async {
    // 48 saat boyunca Actions altyapı hatası (10 dk'lık tavanlı beklemeler) → sonra yeşil.
    final rig = _Rig(
      tmp: tmp,
      config: _cfg(maxDuration: const Duration(days: 5)),
      ciScript: (r) => [for (var i = 0; i < 300; i++) _infra(r), _ok(r)],
    );
    rig.ai.analyst = (n, _) => _clean;
    final t0 = rig.clock.t;
    final res = await rig.engine.run();
    final elapsed = rig.clock.t.difference(t0);
    expect(elapsed, greaterThan(const Duration(hours: 48)));
    expect(res.reason, DevStopReason.kararli);
    expect(rig.engine.counters.length, lessThanOrEqualTo(64));
    expect(rig.engine.cancelToken.pendingWaits, 0);
    final ev = await _events(rig.store);
    expect(ev.length, lessThanOrEqualTo(5000)); // RAM'e alınan pencere sınırlı
    // Diskteki olay günlüğü döner: asıl dosya + en çok rotatedKeep yedek (+ küçük json'lar).
    expect(dirBytes(Directory('${tmp.path}')), lessThan(4 * 1024 * 1024));
    final saved = (await rig.store.loadSession())!;
    expect(saved.counters.keys.where((k) => k.startsWith('imza:')).length, lessThanOrEqualTo(16));
    expect(saved.counters['cfgSureDk'], const Duration(days: 5).inMinutes);
  });

  test('(2) servis zaman aşımı: oturum çökmez, duraklar, kontrol noktası yazılır; devam edince yama kaybolmaz', () async {
    final events = StreamController<KeepAliveEvent>.broadcast();
    final gate = DevPauseGate();
    final sub = bindServiceTimeout(events: events.stream, gate: gate);
    final rig = _Rig(tmp: tmp, gate: gate);
    rig.ai.onAnalyst = (n) {
      if (n == 1) events.add(const KeepAliveEvent(KeepAliveEventKind.timeout, fgsType: 1));
    };
    final fut = rig.engine.run();
    await _until(() async {
      final s = await rig.store.loadSession();
      return s != null && s.status == DevSessionStatus.duraklatildi && s.phase == 'Duraklatıldı';
    });
    expect(gate.reasons, contains(DevPauseReason.servisZamanAsimi));
    expect(rig.repo.commitCalls, 0); // doğrulanmış yama commit'ten ÖNCE bekliyor
    final mid = (await rig.store.loadSession())!;
    expect(mid.branch, rig.repo.branch);
    expect(mid.note, contains('zaman aşımı'));
    final ev1 = await _events(rig.store);
    expect(ev1.any((e) => e.message.contains('duraklatılıyor') && e.level == DevEventLevel.uyari), isTrue);

    rig.engine.resume(DevPauseReason.servisZamanAsimi);
    final res = await fut.timeout(const Duration(seconds: 20));
    expect(res.reason, DevStopReason.kararli);
    expect(rig.repo.commitCalls, greaterThanOrEqualTo(1));
    expect(rig.repo.files['lib/main.dart'], contains('return a + 2;')); // veri kaybı yok
    await sub.cancel();
    await events.close();
  });

  test('(2b) iptal, duraklamada bekleyen oturumu hızla çözer', () async {
    final gate = DevPauseGate()..pause(DevPauseReason.kullanici);
    final rig = _Rig(tmp: tmp, gate: gate);
    final fut = rig.engine.run();
    await _until(() async => (await rig.store.loadSession())?.status == DevSessionStatus.duraklatildi);
    rig.engine.cancel();
    final res = await fut.timeout(const Duration(seconds: 5));
    expect(res.status, DevSessionStatus.iptal);
    expect(rig.repo.commitCalls, 0);
  });

  test('(3) süreç ölümü + resume: aynı dal, sayaç, bloklu dosya; kesinti süreden sayılmaz; yapılandırma kontrol noktasından', () async {
    final hang = Completer<CiOutcome>();
    final first = _Rig(
      tmp: tmp,
      config: _cfg(maxDuration: const Duration(hours: 2)),
      ciScript: (r) => [_ok(r), () => hang.future],
    );
    unawaited(first.engine.run()); // süreç "ölür"
    await _until(() async {
      final s = await first.store.loadSession();
      return s != null && (s.counters['commit'] ?? 0) == 1 && first.ci.calls >= 2;
    });
    final saved = (await first.store.loadSession())!.copyWith(blockedFiles: ['lib/util.dart']);
    expect(saved.status, DevSessionStatus.calisiyor); // açılışta "çalışıyordu" olarak görünür

    final cfg = DevSessionConfig.fromCheckpoint(saved);
    expect(cfg.maxDuration, const Duration(hours: 2));
    expect(cfg.repo, 'sahip/depo');

    // 10 saat sonra yeni süreç: kesinti sayılmazsa 2 saatlik süre çoktan dolmuş olurdu.
    final clock = _Clock()..t = first.clock.t.add(const Duration(hours: 10));
    final repo = first.repo;
    final ai = _Ai()..analyst = (n, _) => _clean;
    final store2 = DevSessionStore(
      baseDir: tmp,
      sessionId: 's1',
      flushInterval: const Duration(milliseconds: 20),
      now: () => clock.t,
    );
    final engine2 = DevSessionEngine(
      config: cfg,
      repo: repo,
      ci: _Ci(repo),
      callModel: ai.call,
      pool: _Pool(),
      store: store2,
      ledger: DevLedger(dir: Directory('${tmp.path}/ledger2')),
      now: () => clock.t,
      sleep: clock.sleep,
      netProbe: () async => false,
    );
    final res = await engine2.run(resumeFrom: saved);
    expect(res.reason, DevStopReason.kararli);
    expect(res.branch, saved.branch);
    expect(engine2.counters['commit'], 1);
    expect(engine2.blockedFiles, contains('lib/util.dart'));
    expect(repo.revertCalls, 0);
    final ev = await _events(store2);
    expect(ev.any((e) => e.message.contains('süreç kesintisi')), isTrue);
  });

  test('(4) ağ kesintisi: commit ağı koparsa başarısızlık sayılmaz, bekler, bağlantı dönünce sürer', () async {
    final rig = _Rig(tmp: tmp);
    rig.repo.failCommits = 6; // 5+10+20+40+80+160 sn ≈ 5 dk
    final res = await rig.engine.run();
    expect(res.reason, DevStopReason.kararli);
    expect(rig.repo.commitCalls, greaterThanOrEqualTo(7));
    expect(rig.engine.counters['ret'] ?? 0, 0);
    expect(rig.engine.counters['agKesinti'], 1);
    final ev = await _events(rig.store);
    expect(ev.any((e) => e.message.contains('Ağ/sunucu kesintisi (commit)')), isTrue);
    expect(ev.any((e) => e.message.contains('Bağlantı döndü')), isTrue);
    // Uzun kesinti → "bekliyor" kontrol noktası yazıldı (olay günlüğünden izlenir).
    expect(ev.any((e) => e.kind == DevEventKind.bekleme), isTrue);
    // Tavan: hiçbir tek uyku dilimi 5 dk'yı aşmaz.
    expect(rig.clock.sleeps.every((d) => d <= const Duration(minutes: 5)), isTrue);
    expect(rig.repo.files['lib/main.dart'], contains('return a + 2;'));
  });

  test('(4b) model çağrısında ağ hatası model hatası SAYILMAZ (maxModelAttempts aşılsa da)', () async {
    final rig = _Rig(tmp: tmp);
    var thrown = 0;
    final inner = rig.ai.call;
    final engine = DevSessionEngine(
      config: _cfg(),
      repo: rig.repo,
      ci: rig.ci,
      callModel: (m, sys, user, ct) async {
        if (thrown < 8) {
          thrown++;
          throw DevModelCallException(
            PoolReport(modelId: m.id, kind: PoolOutcomeKind.network, message: 'ağ yok'),
          );
        }
        return inner(m, sys, user, ct);
      },
      pool: rig.pool,
      store: rig.store,
      ledger: rig.ledger,
      now: () => rig.clock.t,
      sleep: rig.clock.sleep,
      netProbe: () async => false,
    );
    final res = await engine.run();
    expect(thrown, 8);
    expect(res.reason, DevStopReason.kararli);
    expect(res.status, DevSessionStatus.tamamlandi);
  });

  test('isDevNetworkError: ağ/5xx/hız sınırı bekleme; yetki/404 kalıcı', () {
    expect(isDevNetworkError(const SocketException('x')), isTrue);
    expect(isDevNetworkError(TimeoutException('x')), isTrue);
    expect(isDevNetworkError(CiTransientException('x')), isTrue);
    expect(isDevNetworkError(CiHttpException(503, 'x')), isTrue);
    expect(isDevNetworkError(CiHttpException(403, 'x', retryAfter: const Duration(seconds: 30))), isTrue);
    expect(isDevNetworkError(CiHttpException(401, 'x')), isFalse);
    expect(isDevNetworkError(CiHttpException(404, 'x')), isFalse);
    expect(isDevNetworkError(StateError('x')), isFalse);
  });

  test('(5) kota: kullanım arttıkça istekler seyrekleşir; başlık 0 ise sıfırlanmaya kadar bekler', () async {
    var t = DateTime.utc(2026, 10, 14, 10);
    final waits = <Duration>[];
    final q = DevQuotaBudget(
      hourlyBudget: 100,
      now: () => t,
      sleep: (d, ct) async {
        waits.add(d);
        t = t.add(d);
      },
    );
    final send = q.wrap((r) async => GithubHttpResponse(200, '{}'));
    final req = GithubHttpRequest(method: 'GET', uri: Uri.parse('https://api.github.com/x'));
    for (var i = 0; i < 49; i++) {
      await send(req);
    }
    expect(q.level, DevQuotaLevel.normal);
    expect(waits, isEmpty);
    await send(req); // 50. istek → dikkat
    expect(q.level, DevQuotaLevel.dikkat);
    await send(req);
    expect(waits, isNotEmpty);
    expect(waits.last, lessThanOrEqualTo(const Duration(seconds: 5)));
    for (var i = 0; i < 25; i++) {
      await send(req);
    }
    expect(q.level.index, greaterThanOrEqualTo(DevQuotaLevel.kisitli.index));
    // Bir saat sonra bütçe boşalır.
    t = t.add(const Duration(minutes: 61));
    expect(q.usedLastHour, 0);
    expect(q.level, DevQuotaLevel.normal);
    // Başlıktan kalan 0 → tükendi; bekleme sıfırlanma zamanına (tavan 15 dk) kadar.
    final reset = t.add(const Duration(minutes: 7)).millisecondsSinceEpoch ~/ 1000;
    final capped = DevQuotaBudget(
      hourlyBudget: 100,
      now: () => t,
      sleep: (d, ct) async {
        waits.add(d);
        t = t.add(d);
      },
    );
    final send2 = capped.wrap((r) async => GithubHttpResponse(
          403,
          '{}',
          headers: {'x-ratelimit-remaining': '0', 'x-ratelimit-limit': '5000', 'x-ratelimit-reset': '$reset'},
        ));
    await send2(req);
    expect(capped.level, DevQuotaLevel.tukendi);
    waits.clear();
    await send2(req);
    expect(waits.single, lessThanOrEqualTo(const Duration(minutes: 15)));
    expect(waits.single, greaterThan(const Duration(minutes: 5)));
  });

  test('(5b) motor kota düzeyi değişince olay yazar', () async {
    var t = DateTime.utc(2026, 10, 14, 10);
    final q = DevQuotaBudget(hourlyBudget: 10, now: () => t, sleep: (d, ct) async {});
    for (var i = 0; i < 8; i++) {
      q.recordRequest();
    }
    final rig = _Rig(tmp: tmp);
    final engine = DevSessionEngine(
      config: _cfg(),
      repo: rig.repo,
      ci: rig.ci,
      callModel: rig.ai.call,
      pool: rig.pool,
      store: rig.store,
      ledger: rig.ledger,
      now: () => rig.clock.t,
      sleep: rig.clock.sleep,
      quota: q,
    );
    await engine.run();
    final ev = await _events(rig.store);
    expect(ev.any((e) => e.message.contains('GitHub kotası azalıyor')), isTrue);
    expect(engine.counters['kotaYavas'], greaterThanOrEqualTo(1));
    t = t.add(const Duration(hours: 2));
  });

  test('(6) termal: SEVERE+ → duraklat; 90 sn LIGHT altında kalınca devam (histerezis)', () async {
    var t = DateTime.utc(2026, 10, 14, 10);
    final gate = DevPauseGate();
    int? status = 0;
    final m = DevResilienceMonitor(gate: gate, thermalStatus: () async => status, now: () => t);
    await m.tick();
    expect(gate.paused, isFalse);
    status = 3;
    await m.tick();
    expect(gate.reasons, {DevPauseReason.termal});
    status = 2; // MODERATE: hâlâ sıcak
    t = t.add(const Duration(minutes: 5));
    await m.tick();
    expect(gate.paused, isTrue);
    status = 1;
    await m.tick();
    expect(gate.paused, isTrue); // soğuma süresi dolmadı
    t = t.add(const Duration(seconds: 91));
    await m.tick();
    expect(gate.paused, isFalse);
    status = null; // kanal yok: durum korunur
    await m.tick();
    expect(gate.paused, isFalse);
  });

  test('(6b) termal duraklamada motor yeni iş başlatmaz, soğuyunca sürer', () async {
    final gate = DevPauseGate();
    final rig = _Rig(tmp: tmp, gate: gate);
    rig.ai.onAnalyst = (n) {
      if (n == 1) gate.pause(DevPauseReason.termal);
    };
    final fut = rig.engine.run();
    await _until(() async => (await rig.store.loadSession())?.status == DevSessionStatus.duraklatildi);
    final commitsWhilePaused = rig.repo.commitCalls;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rig.repo.commitCalls, commitsWhilePaused);
    gate.resume(DevPauseReason.termal);
    final res = await fut.timeout(const Duration(seconds: 20));
    expect(res.reason, DevStopReason.kararli);
  });
}
