// Görev 6/19: DevSessionEngine testleri. Sahte repo, sahte CI, sahte havuz ve betikli sahte AI motorları;
// gerçek ağ yok, gerçek sır yok (sahte token çalışma zamanında birleştirilir). Sahte saat: beklemeler gerçek
// süre harcamaz.
//
// Senaryolar: (1) uydurma yol → commit yok; (2) doğrulayıcı RED → commit yok; (3) CI kırmızı → düzeltme → yeşil;
// (4) aynı imza 3 kez → revert + bloklu dosya; (5) çakışma → yeniden yükle; (6) infraError → bekle;
// (7) süreç ortasında kes → resume aynı dalda; (8) iptal; (9) olay/loglarda sahte token geçmez.
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
  }) {
    repo = _Repo(files ?? _files());
    ci = _Ci(repo, ciScript?.call(repo));
    pool = _Pool(single: single);
    store = DevSessionStore(
      baseDir: tmp,
      sessionId: sessionId,
      flushInterval: const Duration(milliseconds: 20),
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
    );
  }

  final Directory tmp;
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
    tmp = Directory.systemTemp.createTempSync('devengine_test_');
  });

  tearDown(() {
    SecretMask.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('(1) saçma/uydurma yol çıktısı: commit YOK, kapı reddi deftere yazılır', () async {
    final rig = _Rig(tmp: tmp, config: _cfg(maxConsecutiveFailures: 2));
    rig.ai.analyst = (n, _) => _finding;
    rig.ai.fixer = (n, _) =>
        _patch('lib/yok.dart', 'int x() => 1;', 'int x() => 2;') +
        _patch('../../etc/passwd', 'a', 'b');
    final r = await rig.engine.run();
    expect(rig.repo.commitCalls, 0);
    expect(rig.ai.verifierCalls, 0);
    expect(rig.ai.fixerCalls, greaterThan(0));
    expect(r.reason, DevStopReason.azamiHata);
    expect(r.status, DevSessionStatus.hata);
    expect(rig.ledger.statsByGate().keys, contains('G2'));
    expect(rig.repo.files['lib/main.dart'], _main);
  });

  test('(2) doğrulayıcı RED: commit YOK; ret defterde V1 olarak görünür', () async {
    final rig = _Rig(tmp: tmp, config: _cfg(maxConsecutiveFailures: 2));
    rig.ai.analyst = (n, _) => _finding;
    rig.ai.verifier = (n, _) => _reject;
    final r = await rig.engine.run();
    expect(rig.repo.commitCalls, 0);
    expect(rig.ai.verifierCalls, greaterThan(0));
    expect(r.reason, DevStopReason.azamiHata);
    expect(rig.ledger.statsByGate().keys, contains('V1'));
  });

  test('(2b) belirsiz doğrulayıcı çıktısı RED sayılır; bağımsız doğrulayıcı yoksa commit YOK', () async {
    final unclear = _Rig(tmp: tmp, config: _cfg(maxConsecutiveFailures: 1));
    unclear.ai.analyst = (n, _) => _finding;
    unclear.ai.verifier = (n, _) => 'Bence iyi görünüyor.';
    await unclear.engine.run();
    expect(unclear.repo.commitCalls, 0);
    expect(unclear.ledger.statsByGate().keys, contains('V2'));

    final dir2 = Directory('${tmp.path}/b')..createSync();
    final single = _Rig(tmp: dir2, single: true, config: _cfg(maxConsecutiveFailures: 1));
    single.ai.analyst = (n, _) => _finding;
    await single.engine.run();
    expect(single.repo.commitCalls, 0);
    expect(single.ai.verifierCalls, 0);
  });

  test('(3) CI kırmızı → CiFeedback ile düzeltme → yeşil; commit yalnızca onaylı yamayla', () async {
    final rig = _Rig(tmp: tmp, ciScript: (r) => [_ok(r), _fail(r), _ok(r)]);
    final res = await rig.engine.run();
    expect(res.status, DevSessionStatus.tamamlandi);
    expect(res.reason, DevStopReason.kararli);
    expect(res.commits, 2);
    expect(rig.repo.commitCalls, 2);
    expect(rig.repo.files['lib/main.dart'], contains('return a + 3;'));
    expect(rig.ai.verifierCalls, greaterThanOrEqualTo(2));
    expect(rig.ai.fixerCalls, 2);
    expect(rig.engine.lastGreenSha, rig.repo.head);
    expect(rig.repo.revertCalls, 0);
    final ev = await _events(rig.store);
    expect(ev.any((e) => e.kind == DevEventKind.commit), isTrue);
    expect(ev.any((e) => e.kind == DevEventKind.ci), isTrue);
    final saved = await rig.store.loadSession();
    expect(saved!.status, DevSessionStatus.tamamlandi);
    expect(saved.counters['commit'], 2);
    expect((await rig.store.loadChanges()).containsKey('lib/main.dart'), isTrue);
  });

  test('(4) aynı CiFailureSignature 3 kez → son yeşil commit\'e revert + bloklu dosya', () async {
    final rig = _Rig(tmp: tmp, ciScript: (r) => [_ok(r), _fail(r), _fail(r), _fail(r)]);
    final base = rig.repo.head;
    final res = await rig.engine.run();
    expect(rig.repo.revertCalls, 1);
    expect(rig.engine.blockedFiles, contains('lib/main.dart'));
    expect(rig.repo.files['lib/main.dart'], _main);
    expect(rig.engine.lastGreenSha, rig.repo.head);
    expect(rig.repo.head, isNot(base)); // geçmiş silinmez: revert yeni commit'tir
    expect(res.reason, DevStopReason.kararli); // döngü devam etti, sonsuz döngü yok
    final ev = await _events(rig.store);
    expect(ev.any((e) => e.kind == DevEventKind.geriAlma), isTrue);
    expect(rig.ledger.statsByGate().keys, contains('C1'));
    final saved = await rig.store.loadSession();
    expect(saved!.blockedFiles, contains('lib/main.dart'));
    expect(saved.counters['geriAlma'], 1);
  });

  test('(4b) düzeltme M kez üst üste başarısız → revert', () async {
    final rig = _Rig(
      tmp: tmp,
      ciScript: (r) => [
        _ok(r),
        _fail(r, message: 'hata bir', code: 'k1'),
        _fail(r, message: 'hata iki', code: 'k2'),
        _fail(r, message: 'hata üç', code: 'k3'),
        _fail(r, message: 'hata dört', code: 'k4'),
      ],
    );
    await rig.engine.run();
    expect(rig.repo.revertCalls, 1);
    expect(rig.engine.blockedFiles, contains('lib/main.dart'));
  });

  test('(5) çakışma: snapshot yeniden yüklenir, parça baştan işlenir, başkasının değişikliği korunur', () async {
    final rig = _Rig(tmp: tmp);
    rig.repo.injectConflict = true;
    rig.ai.analyst = (n, _) => n <= 2 ? _finding : _clean;
    final res = await rig.engine.run();
    expect(rig.engine.counters['cakisma'], 1);
    expect(rig.repo.commitCalls, 2);
    expect(res.commits, 1);
    expect(rig.repo.files['NOTES.md'], isNotNull);
    expect(rig.repo.files['lib/main.dart'], contains('return a + 2;'));
    expect(res.reason, DevStopReason.kararli);
  });

  test('(6) infraError AI\'ya verilmez; geri çekilmeyle beklenir; uzarsa "bekliyor", çökmez', () async {
    DevSessionStatus? seen;
    late _Rig rig;
    rig = _Rig(
      tmp: tmp,
      config: _cfg(infraWaitingAfter: const Duration(seconds: 50)),
      ciScript: (r) => [
        _infra(r),
        _infra(r),
        () async {
          seen = (await rig.store.loadSession())?.status;
          return CiSuccess(sha: r.head);
        },
      ],
    );
    rig.ai.analyst = (n, _) => _clean;
    final res = await rig.engine.run();
    expect(seen, DevSessionStatus.bekliyor);
    expect(res.status, DevSessionStatus.tamamlandi);
    expect(rig.ai.fixerCalls, 0);
    expect(rig.clock.sleeps.take(2).toList(), [const Duration(seconds: 30), const Duration(seconds: 60)]);
    final ev = await _events(rig.store);
    expect(ev.where((e) => e.kind == DevEventKind.bekleme).length, greaterThanOrEqualTo(2));
    expect(rig.ledger.entryCount, 0);
  });

  test('(6b) tüm modeller parkta: bekler (başarısız sayılmaz), sonra sürer', () async {
    final rig = _Rig(tmp: tmp);
    rig.pool.waitFirst = 2;
    rig.ai.analyst = (n, _) => _clean;
    final res = await rig.engine.run();
    expect(res.reason, DevStopReason.kararli);
    expect(rig.clock.sleeps.take(2).toList(), [const Duration(seconds: 7), const Duration(seconds: 7)]);
    expect(rig.engine.counters['bekleme'], greaterThanOrEqualTo(2));
    expect(rig.pool.reports.where((r) => r.kind == PoolOutcomeKind.success), isNotEmpty);
    final ev = await _events(rig.store);
    expect(ev.any((e) => e.kind == DevEventKind.bekleme), isTrue);
  });

  test('kalp atışı: bekleme sırasında 5 dakikada bir olay yayılır', () async {
    final rig = _Rig(
      tmp: tmp,
      ciScript: (r) => [for (var i = 0; i < 5; i++) _infra(r), _ok(r)],
    );
    rig.ai.analyst = (n, _) => _clean;
    final beats = <DevEvent>[];
    final sub = rig.store.events.where((e) => e.kind == DevEventKind.kalpAtisi).listen(beats.add);
    await rig.engine.run();
    await sub.cancel();
    expect(beats.length, greaterThanOrEqualTo(2));
  });

  test('(7) süreç ortasında kes → resume AYNI dalda, kayıtlı sayaç ve bloklu dosyalarla sürer', () async {
    final hang = Completer<CiOutcome>();
    late _Rig first;
    first = _Rig(
      tmp: tmp,
      ciScript: (r) => [_ok(r), () => hang.future],
    );
    unawaited(first.engine.run()); // süreç "ölür": ikinci CI çağrısı hiç dönmez
    await _until(() async {
      final s = await first.store.loadSession();
      return s != null && (s.counters['commit'] ?? 0) == 1 && first.ci.calls >= 2;
    });
    final branch1 = first.repo.branch;
    final saved0 = (await first.store.loadSession())!;
    final saved = saved0.copyWith(blockedFiles: ['lib/util.dart']);
    expect(saved.branch, branch1);

    // Yeni süreç: aynı depo (aynı dal), aynı oturum klasörü.
    final repo = first.repo;
    final ai = _Ai()..analyst = (n, _) => _clean;
    final store2 = DevSessionStore(baseDir: tmp, sessionId: 's1', flushInterval: const Duration(milliseconds: 20));
    final clock = _Clock();
    final engine2 = DevSessionEngine(
      config: _cfg(),
      repo: repo,
      ci: _Ci(repo),
      callModel: ai.call,
      pool: _Pool(),
      store: store2,
      ledger: DevLedger(dir: Directory('${tmp.path}/ledger2')),
      now: () => clock.t,
      sleep: clock.sleep,
    );
    final res = await engine2.run(resumeFrom: saved);
    expect(repo.createNames.last, branch1); // kayıtlı dal adıyla devam
    expect(engine2.branch, branch1);
    expect(engine2.counters['commit'], 1); // sayaç taşındı
    expect(engine2.blockedFiles, contains('lib/util.dart'));
    expect(ai.analystPrompts.any((p) => p.contains('Dosya: lib/util.dart')), isFalse);
    expect(res.reason, DevStopReason.kararli);
    expect(res.branch, branch1);
    expect(repo.revertCalls, 0);
  });

  test('(8) iptal: analiz sırasında iptal → commit yok, durum iptal', () async {
    final rig = _Rig(tmp: tmp);
    rig.ai.analyst = (n, _) => _finding;
    rig.ai.onAnalyst = (n) => rig.engine.cancel();
    final res = await rig.engine.run();
    expect(res.status, DevSessionStatus.iptal);
    expect(res.reason, DevStopReason.iptal);
    expect(rig.repo.commitCalls, 0);
    expect(rig.engine.cancelToken.cancelled, isTrue);
    expect((await rig.store.loadSession())!.status, DevSessionStatus.iptal);
  });

  test('(8b) iptal: gerçek uykudaki bekleme hızlı yanıt verir, bekleyen uyku kalmaz', () async {
    final rig = _Rig(
      tmp: tmp,
      defaultSleep: true,
      ciScript: (r) => [for (var i = 0; i < 50; i++) _infra(r)],
    );
    final fut = rig.engine.run();
    await _until(() async => rig.ci.calls >= 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final sw = Stopwatch()..start();
    rig.engine.cancel();
    final res = await fut.timeout(const Duration(seconds: 5));
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    expect(res.status, DevSessionStatus.iptal);
    expect(rig.engine.cancelToken.pendingWaits, 0);
  });

  test('iptal belirteci motora özgüdür (paylaşılmaz)', () {
    final a = DevSessionEngine(
      config: _cfg(),
      repo: _Repo(_files()),
      ci: _Ci(_Repo(_files())),
      callModel: _Ai().call,
      pool: _Pool(),
      store: DevSessionStore(baseDir: tmp, sessionId: 'x1'),
      ledger: DevLedger(),
    );
    final b = DevSessionEngine(
      config: _cfg(),
      repo: _Repo(_files()),
      ci: _Ci(_Repo(_files())),
      callModel: _Ai().call,
      pool: _Pool(),
      store: DevSessionStore(baseDir: tmp, sessionId: 'x2'),
      ledger: DevLedger(),
    );
    a.cancel();
    expect(a.cancelToken.cancelled, isTrue);
    expect(b.cancelToken.cancelled, isFalse);
    expect(identical(a.cancelToken, b.cancelToken), isFalse);
  });

  test('(9) olay, kontrol noktası ve defterde sahte token geçmez', () async {
    SecretMask.register(_token);
    final rig = _Rig(
      tmp: tmp,
      ciScript: (r) => [
        _infra(r, message: 'bağlantı hatası Authorization: $_token'),
        _ok(r),
      ],
    );
    rig.ai.analyst = (n, _) => n == 1 ? '$_finding\nNot: anahtar $_token' : _clean;
    rig.ai.verifier = (n, _) => 'KARAR: RED\n- sızıntı $_token';
    rig.ai.fixer = (n, user) => _bump(user);
    var thrown = false;
    final inner = rig.ai.analyst;
    rig.ai.analyst = (n, u) {
      if (n == 2 && !thrown) {
        thrown = true;
        throw Exception('boom $_token');
      }
      return inner(n, u);
    };
    await rig.engine.run();
    await rig.store.flush();
    await rig.ledger.flush();
    final all = _readAll(tmp);
    expect(all.contains(_token), isFalse);
    expect(all, isNotEmpty);
    final tail = (await rig.store.tail(5000)).map((e) => e.message).join('\n');
    expect(tail.contains(_token), isFalse);
  });

  test('openPullRequest açıkken kararlı bitişte YALNIZCA taslak PR açılır; birleştirme portta yoktur', () async {
    final rig = _Rig(tmp: tmp, config: _cfg(openPullRequest: true));
    final res = await rig.engine.run();
    expect(res.reason, DevStopReason.kararli);
    expect(rig.repo.prCalls, 1);
    expect(res.prUrl, 'https://example.test/pr/1');
  });

  test('azami commit sınırı: oturum durur, sonsuz döngü yok', () async {
    final rig = _Rig(
      tmp: tmp,
      config: DevSessionConfig(repo: 'o/r', baseBranch: 'main', maxCommits: 1),
    );
    rig.ai.analyst = (n, _) => _finding;
    final res = await rig.engine.run();
    expect(res.reason, DevStopReason.azamiCommit);
    expect(res.commits, 1);
  });

  test('azami süre: sahte saat dolunca oturum biter', () async {
    final rig = _Rig(
      tmp: tmp,
      config: _cfg(maxDuration: const Duration(minutes: 10)),
      ciScript: (r) => [for (var i = 0; i < 100; i++) _infra(r)],
    );
    final res = await rig.engine.run();
    expect(res.reason, DevStopReason.sureDoldu);
    expect(res.status, DevSessionStatus.tamamlandi);
  });
}
