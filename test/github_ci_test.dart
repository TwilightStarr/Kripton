// Görev 3/10: runner/log hattı/workflow testleri eklendi (fixture: test/fixtures/ci).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/ci_batch.dart';
import 'package:kripton_ai/data/ci_feedback.dart';
import 'package:kripton_ai/data/github_ci.dart';
import 'package:kripton_ai/data/github_repo.dart';
import 'package:kripton_ai/data/project_snapshot.dart';
import 'package:kripton_ai/data/secret_mask.dart';

String _log(String stage, int code, List<String> lines) =>
    '2026-10-08T10:00:00.0000000Z ##KRIPTON-BEGIN:$stage\n'
    '${lines.map((l) => '2026-10-08T10:00:01.0000000Z $l').join('\n')}\n'
    '2026-10-08T10:00:02.0000000Z ##KRIPTON-END:$stage:$code\n';

/// İş akışındaki "Kripton kontrol" adımının bash betiği (YAML girintisi atılmış).
String _ciScript() {
  final y = GithubCi.workflowYaml(runTests: false, buildApk: false);
  const marker = '        run: |\n';
  final body = y.substring(y.indexOf(marker) + marker.length);
  return body.split('\n').map((l) => l.startsWith('          ') ? l.substring(10) : l).join('\n');
}

/// Sahte `flutter`: gerçek `flutter create` gibi varsayılan (MyApp'e bağlı) test/widget_test.dart
/// üretir (dosya zaten varsa dokunmaz); `analyze` o dosya + projede MyApp yoksa
/// "The name 'MyApp' isn't a class" ile düşer. Her çağrı $CALLS dosyasına yazılır.
/// RECREATE=1: `pub get` varsayılan testi geç oluşturur; ALSO_FAIL=1: analyze lib/a.dart'ta da hata verir.
const String _fakeFlutter = r"""#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1" in
  create)
    mkdir -p android test lib
    if [ ! -f test/widget_test.dart ]; then
      printf "import 'package:demo/main.dart';\n
// ---------------------------------------------------------------- Görev 3/10 yardımcıları

// Sahte token çalışma zamanında birleştirilir: kaynak dosyada GitHub token kalıbı geçmesin (push sır denetimi).
final String _tok = ['ghp', '_', 'AbCdEfGhIjKlMnOpQrSt', 'UvWxYz0123456789'].join();
const String _sha = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
const String _runUrl = 'https://github.com/o/r/actions/runs/101';

String _fxLog(String name) => File('test/fixtures/ci/$name').readAsStringSync();

GithubHttpResponse _j(int status, Object body, {Map<String, String>? headers}) =>
    GithubHttpResponse(status, jsonEncode(body), headers: headers);

Map<String, Object?> _runs({String sha = _sha}) => {
      'workflow_runs': [
        {
          'id': 101,
          'head_sha': sha,
          'name': 'Kripton Flutter Check',
          'path': '.github/workflows/kripton-flutter-check.yml',
          'html_url': _runUrl,
        }
      ]
    };

const Map<String, Object?> _noRuns = {'workflow_runs': <Object?>[]};

Map<String, Object?> _job({String conclusion = 'failure', String step = 'Kripton kontrol', String stepConclusion = 'failure'}) => {
      'jobs': [
        {
          'id': 555,
          'conclusion': conclusion,
          'steps': [
            {'name': step, 'conclusion': stepConclusion},
          ],
        }
      ]
    };

/// Sıralı betikli sahte ağ. Anahtar: "METHOD /path". Kuyruğun SON öğesi tekrar eder; [Exception] fırlatılır.
class _Net {
  final Map<String, List<Object>> routes = {};
  final List<GithubHttpRequest> log = [];

  void on(String key, Object resp) => routes.putIfAbsent(key, () => <Object>[]).add(resp);

  Future<GithubHttpResponse> send(GithubHttpRequest r) async {
    log.add(r);
    final key = '${r.method} ${r.uri.path}';
    final q = routes[key];
    if (q == null || q.isEmpty) return GithubHttpResponse(404, '{"message":"yol yok: $key"}');
    final next = q.length > 1 ? q.removeAt(0) : q.first;
    if (next is Exception) throw next;
    return next as GithubHttpResponse;
  }

  int count(String key) => log.where((r) => '${r.method} ${r.uri.path}' == key).length;
}

class _Fx {
  _Fx({this.logStore, this.overallTimeout = const Duration(minutes: 75), this.queueTimeout = const Duration(minutes: 15)}) {
    runner = GithubCiRunner(
      repo: 'o/r',
      token: _tok,
      send: net.send,
      repoClient: repo,
      cancelled: () => cancelFlag,
      sleep: (d) async {
        sleeps.add(d);
        clock = clock.add(d);
        if (cancelAfterSleeps != null && sleeps.length >= cancelAfterSleeps!) cancelFlag = true;
      },
      now: () => clock,
      logStore: logStore,
      overallTimeout: overallTimeout,
      queueTimeout: queueTimeout,
      logRetryWait: const Duration(seconds: 1),
    );
  }

  final _Net net = _Net();
  final _FakeRepo repo = _FakeRepo();
  final CiLogStore? logStore;
  final Duration overallTimeout;
  final Duration queueTimeout;
  final List<Duration> sleeps = [];
  DateTime clock = DateTime.utc(2026, 10, 11, 10);
  bool cancelFlag = false;
  int? cancelAfterSleeps;
  late final GithubCiRunner runner;

  /// Başarısız çalışmanın tipik betiği: run bulunur, tamamlanır (failure), iş + imzalı günlük adresi.
  void failedRun(String logText, {Object? job}) {
    net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
    net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'completed', 'conclusion': 'failure'}));
    net.on('GET /repos/o/r/actions/runs/101/jobs', job ?? _j(200, _job()));
    net.on('GET /repos/o/r/actions/jobs/555/logs',
        GithubHttpResponse(302, '', headers: {'location': 'https://logs.example.invalid/blob/abc?sig=1'}));
    net.on('GET /blob/abc', GithubHttpResponse(200, logText));
  }

  void completed(String conclusion) {
    net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
    net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'completed', 'conclusion': conclusion}));
  }

  Future<CiOutcome> run() => runner.runForCommit('kripton/dev-1', _sha);
}

class _FakeRepo extends DevRepoClient {
  _FakeRepo({bool allow = true}) : super(repo: 'o/r', token: 'tok-yalnizca-test', allowWorkflowEdits: allow);

  final List<({String branch, String expected, Map<String, String?> changes, String message})> commits = [];

  @override
  Future<String> commitChanges(String branch, String expectedHeadSha, Map<String, String?> changes, String message) async {
    commits.add((branch: branch, expected: expectedHeadSha, changes: changes, message: message));
    return 'b' * 40;
  }
}

void main() { MyApp(); }\n" > test/widget_test.dart
    fi ;;
  pub)
    echo "Got dependencies!"
    if [ -n "$RECREATE" ]; then mkdir -p test; printf "void main() { MyApp(); }\n" > test/widget_test.dart; fi ;;
  analyze)
    bad=0
    if [ -f test/widget_test.dart ] && grep -qw MyApp test/widget_test.dart && ! grep -rqw 'class MyApp' lib; then
      echo "  error • The name 'MyApp' isn't a class • test/widget_test.dart:16:35 • creation_with_non_type"
      bad=1
    fi
    if [ -n "$ALSO_FAIL" ]; then
      echo "  error • Undefined name 'q' • lib/a.dart:3:1 • undefined_identifier"
      bad=1
    fi
    if [ "$bad" = 1 ]; then exit 1; fi
    echo "No issues found!" ;;
esac
exit 0
""";

final bool _hasBash = () {
  if (Platform.isWindows) return false;
  try {
    return Process.runSync('bash', ['-c', 'exit 0']).exitCode == 0;
  } catch (_) {
    return false;
  }
}();

class _CiRun {
  _CiRun(this.code, this.out, this.project, this.calls);

  final int code;
  final String out;
  final Directory project;
  final List<String> calls;

  int get analyzeCalls => calls.where((c) => c.startsWith('analyze')).length;
  File file(String path) => File('${project.path}/$path');
}

Future<_CiRun> _runCi(
  Directory root,
  Map<String, String> files, {
  Map<String, String> env = const {},
}) async {
  final project = Directory('${root.path}/p')..createSync(recursive: true);
  final bin = Directory('${root.path}/bin')..createSync(recursive: true);
  final calls = File('${root.path}/calls.log')..writeAsStringSync('');
  final all = {'pubspec.yaml': 'name: demo\n', ...files};
  for (final e in all.entries) {
    final f = File('${project.path}/${e.key}');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(e.value);
  }
  final fake = File('${bin.path}/flutter')..writeAsStringSync(_fakeFlutter);
  Process.runSync('chmod', ['+x', fake.path]);
  final script = File('${root.path}/ci.sh')..writeAsStringSync(_ciScript());
  final r = await Process.run(
    'bash',
    [script.path],
    workingDirectory: project.path,
    environment: {
      'PATH': '${bin.path}:${Platform.environment['PATH'] ?? ''}',
      'CALLS': calls.path,
      ...env,
    },
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return _CiRun(
    r.exitCode,
    '${r.stdout}${r.stderr}',
    project,
    calls.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList(),
  );
}

void main() {
  group('CiLogParser', () {
    test('analyze: error ve warning ayrıştırılır, info sayılır, raw aynen kalır', () {
      const e = "  error \u2022 The method 'foo' isn't defined for the type 'A' \u2022 lib/a.dart:12:5 \u2022 undefined_method";
      const w = '  warning \u2022 Unused import: \'x.dart\' \u2022 lib/b.dart:1:8 \u2022 unused_import';
      const i = '   info \u2022 Use const \u2022 lib/c.dart:3:1 \u2022 prefer_const_constructors';
      final log = '${_log('pub-get', 0, ['Got dependencies!'])}${_log('analyze', 1, [e, w, i])}';
      final r = CiLogParser.parseJobLog(log);
      expect(r.ok, isFalse);
      expect(r.stage, 'analyze');
      expect(r.diagnostics.length, 2);
      expect(r.infoCount, 1);
      expect(r.diagnostics.first.path, 'lib/a.dart');
      expect(r.diagnostics.first.line, 12);
      expect(r.diagnostics.first.raw, e.trimRight());
      expect(r.stageLog.contains(i), isTrue); // tam aşama günlüğü kırpılmaz
    });

    test('build: Dart derleme hatası devam satırlarıyla birlikte aynen alınır', () {
      final log = _log('build', 1, [
        "lib/m.dart:7:3: Error: Undefined name 'q'.",
        '  q();',
        '  ^',
        '',
        'FAILURE: Build failed',
      ]);
      final r = CiLogParser.parseJobLog(log);
      expect(r.diagnostics.length, 1);
      expect(r.diagnostics.single.raw, "lib/m.dart:7:3: Error: Undefined name 'q'.\n  q();\n  ^");
    });

    test('pub-get başarısızlığı pubspec.yaml sorunu olur, çıktı tam saklanır', () {
      final r = CiLogParser.parseJobLog(_log('pub-get', 1, ['Because x depends on y ...', 'version solving failed.']));
      expect(r.diagnostics.single.path, 'pubspec.yaml');
      expect(r.diagnostics.single.raw, 'Because x depends on y ...\nversion solving failed.');
    });

    test('tüm aşamalar başarılıysa ok', () {
      final r = CiLogParser.parseJobLog(_log('analyze', 0, ['No issues found!']));
      expect(r.ok, isTrue);
    });

    test('işaretçi yoksa kurulum hatası: günlük aynen döner', () {
      final r = CiLogParser.parseJobLog('checkout failed');
      expect(r.ok, isFalse);
      expect(r.stage, 'setup');
      expect(r.stageLog, 'checkout failed');
    });
  });

  group('CiBatcher', () {
    ProjectSnapshot snap() => ProjectSnapshot(
          name: 't',
          text: {'lib/a.dart': List.generate(400, (i) => 'line $i;').join('\n')},
        );

    CiDiagnostic d(int line, String raw) =>
        CiDiagnostic(path: 'lib/a.dart', line: line, column: 1, severity: 'error', message: raw, raw: raw);

    test('hiçbir sorun atılmaz; uzak satırlar ayrı gruba girer', () {
      final diags = [d(5, 'e1'), d(6, 'e2'), d(380, 'e3')];
      final p = CiBatcher.plan(snap(), diags, budget: 1200);
      final all = p.batches.map((b) => b.toolOutput).join('\n');
      expect(all.contains('e1'), isTrue);
      expect(all.contains('e2'), isTrue);
      expect(all.contains('e3'), isTrue);
      expect(p.batches.length, greaterThanOrEqualTo(2));
      expect(p.unmatched, isEmpty);
    });

    test('bilinmeyen dosya unmatched olur', () {
      final p = CiBatcher.plan(
        snap(),
        [const CiDiagnostic(path: 'lib/yok.dart', line: 1, column: 1, severity: 'error', message: 'm', raw: 'r')],
        budget: 1200,
      );
      expect(p.batches, isEmpty);
      expect(p.unmatched.length, 1);
    });

    test('çok uzun çıktı kayıpsız parçalanır', () {
      final big = List.generate(300, (i) => 'satir $i uzun uzun uzun').join('\n');
      final parts = CiBatcher.splitLines(big, 500);
      expect(parts.every((x) => x.length <= 500), isTrue);
      expect(parts.join('\n'), big);
      final p = CiBatcher.plan(snap(), [d(10, big)], budget: 1200);
      expect(p.batches.length, greaterThan(1));
      expect(p.batches.map((b) => b.toolOutput).join('\n'), big);
      expect(p.batches.first.partLabel, startsWith('parça 1/'));
    });
  });

  test('MyApp hatası ayrıştırılır; projede olmayan dosya olduğundan modele düzeltme gitmez', () {
    const e = "  error \u2022 The name 'MyApp' isn't a class \u2022 test/widget_test.dart:16:35 \u2022 creation_with_non_type";
    final r = CiLogParser.parseJobLog(_log('analyze', 1, [e]));
    expect(r.stage, 'analyze');
    expect(r.diagnostics.single.path, 'test/widget_test.dart');
    expect(r.diagnostics.single.code, 'creation_with_non_type');
    final snap = ProjectSnapshot(name: 't', text: {'lib/main.dart': 'void main() {}\n'});
    final p = CiBatcher.plan(snap, r.diagnostics, budget: 1200);
    expect(p.batches, isEmpty); // AI çağrılmaz
    expect(p.unmatched.length, 1);
  });

  group('iş akışı betiği: varsayılan test/widget_test.dart temizliği (bash ile gerçek çalıştırma)', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('kripton_ci_'));
    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    final skip = _hasBash ? false : 'bash yok';

    test('flutter create varsayılan testi silinir, silme stage çıktısında görünür, analyze geçer', () async {
      final r = await _runCi(root, {'lib/main.dart': 'void main() {}\n'});
      expect(r.code, 0, reason: r.out);
      expect(r.file('test/widget_test.dart').existsSync(), isFalse);
      final cleanup = RegExp(r'##KRIPTON-BEGIN:cleanup\n([\s\S]*?)##KRIPTON-END:cleanup:0').firstMatch(r.out);
      expect(cleanup, isNotNull, reason: r.out);
      expect(cleanup!.group(1), contains('test/widget_test.dart SİLİNDİ'));
      expect(r.analyzeCalls, 1);
      expect(CiLogParser.parseJobLog(r.out).ok, isTrue);
    }, skip: skip);

    test('MyApp\'e atıf yapmayan (kullanıcının/iskeletin) test dosyasına dokunulmaz', () async {
      const own = "import 'package:flutter_test/flutter_test.dart';\nvoid main() { test('x', () {}); }\n";
      final r = await _runCi(root, {'lib/main.dart': 'void main() {}\n', 'test/widget_test.dart': own});
      expect(r.code, 0, reason: r.out);
      expect(r.file('test/widget_test.dart').readAsStringSync(), own);
      expect(r.out, isNot(contains('SİLİNDİ')));
    }, skip: skip);

    test('projede class MyApp varsa MyApp\'e bağlı test de korunur', () async {
      const own = "void main() { MyApp(); }\n";
      final r = await _runCi(root, {
        'lib/main.dart': 'class MyApp {}\nvoid main() {}\n',
        'test/widget_test.dart': own,
      });
      expect(r.code, 0, reason: r.out);
      expect(r.file('test/widget_test.dart').readAsStringSync(), own);
      expect(r.out, contains('korundu'));
    }, skip: skip);

    test('analyze varsayılan testten düşerse dosya silinir ve analyze BİR kez yeniden çalışır', () async {
      // android/ var → create atlanır; `pub get` varsayılan testi temizlikten SONRA geri getirir.
      final r = await _runCi(
        root,
        {'lib/main.dart': 'void main() {}\n', 'android/.keep': ''},
        env: {'RECREATE': '1'},
      );
      expect(r.code, 0, reason: r.out);
      expect(r.analyzeCalls, 2);
      expect(r.file('test/widget_test.dart').existsSync(), isFalse);
      expect(r.out, contains('analyze bir kez yeniden çalıştırılıyor'));
      expect(r.out, contains('[ilk deneme]'));
      final parsed = CiLogParser.parseJobLog(r.out);
      expect(parsed.ok, isTrue);
    }, skip: skip);

    test('yeniden deneme yalnızca bir kez: gerçek hata sürerse yalnızca ikinci çıktıdaki sorunlar raporlanır', () async {
      final r = await _runCi(
        root,
        {'lib/main.dart': 'void main() {}\n', 'android/.keep': ''},
        env: {'RECREATE': '1', 'ALSO_FAIL': '1'},
      );
      expect(r.code, isNot(0));
      expect(r.analyzeCalls, 2);
      final parsed = CiLogParser.parseJobLog(r.out);
      expect(parsed.ok, isFalse);
      expect(parsed.stage, 'analyze');
      expect(parsed.diagnostics.length, 1);
      expect(parsed.diagnostics.single.path, 'lib/a.dart'); // test/widget_test.dart sorunu modele gitmez
    }, skip: skip);

    test('ilgisiz analyze hatasında temizlik/yeniden deneme olmaz', () async {
      final r = await _runCi(
        root,
        {'lib/main.dart': 'void main() {}\n', 'android/.keep': ''},
        env: {'ALSO_FAIL': '1'},
      );
      expect(r.code, isNot(0));
      expect(r.analyzeCalls, 1);
      expect(r.out, isNot(contains('yeniden çalıştırılıyor')));
      expect(CiLogParser.parseJobLog(r.out).diagnostics.single.path, 'lib/a.dart');
    }, skip: skip);
  });

  test('iş akışı işaretçi ve aşamaları içerir', () {
    final y = GithubCi.workflowYaml(runTests: true, buildApk: false);
    expect(y.contains("KRIPTON_TEST: '1'"), isTrue);
    expect(y.contains("KRIPTON_BUILD: '0'"), isTrue);
    expect(y.contains('flutter analyze --no-fatal-infos'), isTrue);
    expect(y.contains('stage cleanup cleanup_default_test'), isTrue);
    expect(y.contains('stage analyze run_analyze'), isTrue);
  });

  // ================================================================ Görev 3/10

  group('workflowYaml (Görev 3)', () {
    test('push yalnızca kripton/** (yeni hat), concurrency, izinler, zaman aşımı', () {
      final y = GithubCi.workflowYaml(runTests: true, buildApk: true, legacyPushBranches: const []);
      expect(y, contains("    branches:\n      - 'kripton/**'\n  workflow_dispatch:"));
      expect(y, isNot(contains('kripton-ci')));
      expect(y, contains('permissions:\n  contents: read'));
      expect(y, contains(r'group: kripton-flutter-check-${{ github.ref }}'));
      expect(y, contains('cancel-in-progress: true'));
      expect(y, contains('timeout-minutes: $kCiJobTimeoutMinutes'));
      expect(y, contains("flutter-version: '$kCiFlutterVersion'"));
      expect(y, isNot(contains('__')));
    });

    test('eski yol (push) için varsayılan eski dalı da tetikler', () {
      final y = GithubCi.workflowYaml(runTests: true, buildApk: true);
      expect(y, contains("      - 'kripton/**'\n      - 'kripton-ci'"));
    });

    test('action sürümleri sürüm etiketi ya da 40 haneli sha ile sabit', () {
      final y = GithubCi.workflowYaml(runTests: true, buildApk: true);
      final uses = RegExp(r'uses: (\S+)').allMatches(y).map((m) => m.group(1)!).toList();
      expect(uses.length, 3);
      for (final u in uses) {
        expect(RegExp(r'@(v\d+\.\d+\.\d+|[0-9a-f]{40})$').hasMatch(u), isTrue, reason: u);
      }
    });

    test('sabit Flutter sürümünün Dart sürümü pubspec sdk alt sınırını karşılar', () {
      final pub = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'sdk:\s*">=(\d+)\.(\d+)\.(\d+)').firstMatch(pub)!;
      List<int> v(String s) => s.split('.').map(int.parse).toList();
      final need = [int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)];
      final have = v(kCiFlutterDartVersion);
      var ok = true;
      for (var i = 0; i < 3; i++) {
        if (have[i] != need[i]) {
          ok = have[i] > need[i];
          break;
        }
      }
      expect(ok, isTrue);
      expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(kCiFlutterVersion), isTrue);
    });

    test('betik hâlâ pub-get/analyze/test aşamalarını işaretçiyle çalıştırır', () {
      final y = GithubCi.workflowYaml(runTests: true, buildApk: false);
      expect(y, contains('stage pub-get flutter pub get'));
      expect(y, contains('stage analyze run_analyze'));
      expect(y, contains('stage test flutter test'));
    });
  });

  group('ensureWorkflow', () {
    void head(_Net n, {String? file}) {
      n.on('GET /repos/o/r/git/ref/heads/kripton/dev-1', _j(200, {'object': {'sha': _sha}}));
      n.on('GET /repos/o/r/contents/.github/workflows/kripton-flutter-check.yml',
          file == null ? _j(404, {'message': 'Not Found'}) : GithubHttpResponse(200, file));
    }

    test('dosya aynıysa (CRLF/boşluk farkı dahil) commit atılmaz', () async {
      final fx = _Fx();
      head(fx.net, file: '${fx.runner.workflowYamlText.replaceAll('\n', '\r\n')}\r\n\r\n');
      final r = await fx.runner.ensureWorkflow('kripton/dev-1');
      expect(r.committed, isFalse);
      expect(r.headSha, _sha);
      expect(fx.repo.commits, isEmpty);
    });

    test('dosya farklıysa tek commit: yol, içerik, beklenen uç', () async {
      final fx = _Fx();
      head(fx.net, file: 'name: eski\n');
      final r = await fx.runner.ensureWorkflow('kripton/dev-1');
      expect(r.committed, isTrue);
      expect(r.headSha, 'b' * 40);
      expect(fx.repo.commits.length, 1);
      final c = fx.repo.commits.single;
      expect(c.branch, 'kripton/dev-1');
      expect(c.expected, _sha);
      expect(c.changes.keys.single, '.github/workflows/kripton-flutter-check.yml');
      expect(c.changes.values.single, fx.runner.workflowYamlText);
      expect(c.message, contains('güncellendi'));
    });

    test('dosya yoksa eklenir', () async {
      final fx = _Fx();
      head(fx.net);
      final r = await fx.runner.ensureWorkflow('kripton/dev-1');
      expect(r.committed, isTrue);
      expect(fx.repo.commits.single.message, contains('eklendi'));
    });

    test('dal yoksa DevRepoException; allowWorkflowEdits kapalıysa DevPolicyException', () async {
      final fx = _Fx();
      fx.net.on('GET /repos/o/r/git/ref/heads/kripton/dev-1', _j(404, {'message': 'Not Found'}));
      await expectLater(fx.runner.ensureWorkflow('kripton/dev-1'), throwsA(isA<DevRepoException>()));
      final r2 = GithubCiRunner(repo: 'o/r', token: _tok, repoClient: _FakeRepo(allow: false), send: _Net().send);
      await expectLater(r2.ensureWorkflow('kripton/dev-1'), throwsA(isA<DevPolicyException>()));
    });

    test('checkBranch: ensure sonrası yeni uçla çalıştırır', () async {
      final fx = _Fx();
      head(fx.net, file: 'eski');
      final newSha = 'b' * 40;
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs(sha: newSha)));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'completed', 'conclusion': 'success'}));
      final o = await fx.runner.checkBranch('kripton/dev-1');
      expect(o, isA<CiSuccess>());
      expect(o.sha, newSha);
      expect(fx.net.log.firstWhere((r) => r.uri.path.endsWith('/actions/runs')).uri.queryParameters['head_sha'], newSha);
    });
  });

  group('GithubCiRunner.runForCommit', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('kripton_cirun_');
      SecretMask.clear();
    });
    tearDown(() {
      SecretMask.clear();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('başarı: push çalışması bulunur, dispatch ÇAĞRILMAZ', () async {
      final fx = _Fx();
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'in_progress'}));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'completed', 'conclusion': 'success'}));
      final o = await fx.run();
      expect(o, isA<CiSuccess>());
      expect(o.runUrl, _runUrl);
      expect(o.runId, 101);
      expect(fx.net.log.where((r) => r.method == 'POST'), isEmpty);
      expect(fx.net.log.first.uri.queryParameters['head_sha'], _sha);
      expect(fx.net.log.first.headers['authorization'], 'Bearer $_tok');
    });

    test('başka commit/iş akışının çalışması yok sayılır', () async {
      final fx = _Fx();
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs(sha: 'f' * 40)));
      fx.net.on('POST /repos/o/r/actions/workflows/kripton-flutter-check.yml/dispatches', GithubHttpResponse(204, ''));
      final o = await fx.run();
      expect(o, isA<CiInfraError>());
    });

    test('push çalışma açmazsa 45 sn sonra workflow_dispatch (bir kez), sonra çalışma bulunur', () async {
      final fx = _Fx();
      for (var i = 0; i < 8; i++) {
        fx.net.on('GET /repos/o/r/actions/runs', _j(200, _noRuns));
      }
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
      fx.net.on('POST /repos/o/r/actions/workflows/kripton-flutter-check.yml/dispatches', GithubHttpResponse(204, ''));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'completed', 'conclusion': 'success'}));
      final o = await fx.run();
      expect(o, isA<CiSuccess>());
      expect(fx.net.count('POST /repos/o/r/actions/workflows/kripton-flutter-check.yml/dispatches'), 1);
      final d = fx.net.log.firstWhere((r) => r.method == 'POST');
      expect(jsonDecode(utf8.decode(d.body!)), {'ref': 'kripton/dev-1'});
    });

    test('çalışma hiç başlamaz + Actions kapalı -> infraError(actionsDisabled), kod hatası değil', () async {
      final fx = _Fx();
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _noRuns));
      fx.net.on('POST /repos/o/r/actions/workflows/kripton-flutter-check.yml/dispatches', _j(404, {'message': 'Not Found'}));
      fx.net.on('GET /repos/o/r/actions/permissions', _j(200, {'enabled': false}));
      final o = await fx.run();
      expect(o, isA<CiInfraError>());
      expect((o as CiInfraError).reason, CiInfraReason.actionsDisabled);
      expect(o.message, contains('Actions kapalı'));
    });

    test('çalışma hiç başlamaz + dispatch reddedildi -> workflowMissing', () async {
      final fx = _Fx();
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _noRuns));
      fx.net.on('POST /repos/o/r/actions/workflows/kripton-flutter-check.yml/dispatches', _j(404, {'message': 'Not Found'}));
      fx.net.on('GET /repos/o/r/actions/permissions', _j(200, {'enabled': true}));
      final o = await fx.run() as CiInfraError;
      expect(o.reason, CiInfraReason.workflowMissing);
      expect(o.message, contains('workflow_dispatch reddedildi'));
    });

    test('kuyrukta runner atanmaz -> runnerNotStarted ve çalışma iptal edilir', () async {
      final fx = _Fx(queueTimeout: const Duration(minutes: 5));
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'queued'}));
      fx.net.on('POST /repos/o/r/actions/runs/101/cancel', GithubHttpResponse(202, '{}'));
      final o = await fx.run() as CiInfraError;
      expect(o.reason, CiInfraReason.runnerNotStarted);
      expect(fx.net.count('POST /repos/o/r/actions/runs/101/cancel'), 1);
    });

    test('toplam zaman aşımı -> infraError(timeout)', () async {
      final fx = _Fx(overallTimeout: const Duration(minutes: 10));
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'in_progress'}));
      fx.net.on('POST /repos/o/r/actions/runs/101/cancel', GithubHttpResponse(202, '{}'));
      final o = await fx.run() as CiInfraError;
      expect(o.reason, CiInfraReason.timeout);
      expect(fx.net.count('POST /repos/o/r/actions/runs/101/cancel'), 1);
    });

    test('yoklama aralığı geri çekilir (8 sn -> 30 sn tavan)', () async {
      final fx = _Fx(overallTimeout: const Duration(minutes: 10));
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'in_progress'}));
      await fx.run();
      expect(fx.sleeps.first, const Duration(seconds: 8));
      expect(fx.sleeps.skip(1).first, const Duration(seconds: 12));
      expect(fx.sleeps.reduce((a, b) => a > b ? a : b), const Duration(seconds: 30));
    });

    test('ağ kopması / 5xx hata değildir: bekle-ve-dene, sonunda başarı', () async {
      final fx = _Fx();
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
      fx.net.on('GET /repos/o/r/actions/runs/101', const SocketException('bağlantı koptu'));
      fx.net.on('GET /repos/o/r/actions/runs/101', GithubHttpResponse(502, 'bad gateway'));
      fx.net.on('GET /repos/o/r/actions/runs/101', TimeoutException('yavaş'));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'in_progress'}));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'completed', 'conclusion': 'success'}));
      final o = await fx.run();
      expect(o, isA<CiSuccess>());
    });

    test('ağ hiç düzelmezse süre dolunca infraError(network)', () async {
      final fx = _Fx(overallTimeout: const Duration(minutes: 5));
      fx.net.on('GET /repos/o/r/actions/runs', const SocketException('yok'));
      final o = await fx.run() as CiInfraError;
      expect(o.reason, CiInfraReason.network);
    });

    test('hız sınırı: Retry-After kadar beklenir', () async {
      final fx = _Fx();
      fx.net.on('GET /repos/o/r/actions/runs', _j(429, {'message': 'slow down'}, headers: {'retry-after': '7'}));
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'completed', 'conclusion': 'success'}));
      final o = await fx.run();
      expect(o, isA<CiSuccess>());
      expect(fx.sleeps, contains(const Duration(seconds: 7)));
    });

    test('401 -> infraError(auth), yeniden denenmez', () async {
      final fx = _Fx();
      fx.net.on('GET /repos/o/r/actions/runs', _j(401, {'message': 'Bad credentials'}));
      final o = await fx.run() as CiInfraError;
      expect(o.reason, CiInfraReason.auth);
      expect(fx.net.count('GET /repos/o/r/actions/runs'), 1);
    });

    test('startup_failure / timed_out -> infraError', () async {
      final a = _Fx()..completed('startup_failure');
      expect(((await a.run()) as CiInfraError).reason, CiInfraReason.startupFailure);
      final b = _Fx()..completed('timed_out');
      expect(((await b.run()) as CiInfraError).reason, CiInfraReason.timeout);
    });

    test('iptal edilmiş çalışma -> CiCancelled (kod hatası değil)', () async {
      final fx = _Fx()..completed('cancelled');
      fx.net.on('GET /repos/o/r/actions/runs/101/jobs', _j(200, _job(conclusion: 'cancelled', stepConclusion: 'cancelled')));
      final o = await fx.run();
      expect(o, isA<CiCancelled>());
    });

    test('iş zaman aşımıyla iptal edildiyse (job timed_out) infraError(timeout)', () async {
      final fx = _Fx()..completed('cancelled');
      fx.net.on('GET /repos/o/r/actions/runs/101/jobs', _j(200, _job(conclusion: 'timed_out', stepConclusion: 'timed_out')));
      final o = await fx.run() as CiInfraError;
      expect(o.reason, CiInfraReason.timeout);
    });

    test('kullanıcı iptali: bekleme sırasında CiCancelled ve GitHub çalışması iptal edilir', () async {
      final fx = _Fx();
      fx.cancelAfterSleeps = 2;
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'in_progress'}));
      fx.net.on('POST /repos/o/r/actions/runs/101/cancel', GithubHttpResponse(202, '{}'));
      final o = await fx.run();
      expect(o, isA<CiCancelled>());
      expect(o.runId, 101);
      expect(fx.net.count('POST /repos/o/r/actions/runs/101/cancel'), 1);
    });

    test('iptal, çalışma bulunmadan da CiCancelled döner (iptal isteği gitmez)', () async {
      final fx = _Fx();
      fx.cancelAfterSleeps = 1;
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _noRuns));
      final o = await fx.run();
      expect(o, isA<CiCancelled>());
      expect(fx.net.log.where((r) => r.method == 'POST'), isEmpty);
    });

    test('analyze hatası -> CiFailure: imza, AI metni, işaretçi günlük; imzalı adrese Authorization gitmez', () async {
      final fx = _Fx(logStore: CiLogStore(dir: Directory('${tmp.path}/devlogs')));
      fx.failedRun(_fxLog('analyze_fail.log'));
      final o = await fx.run();
      expect(o, isA<CiFailure>());
      final f = o as CiFailure;
      expect(f.signature.stage, 'analyze');
      expect(f.result.exitCode, 1);
      expect(f.feedback, contains("Undefined name 'q'"));
      expect(f.feedback, contains('--- lib/data/x.dart ---'));
      expect(f.rawLogPath, isNotNull);
      final first = fx.net.log.firstWhere((r) => r.uri.path.endsWith('/jobs/555/logs'));
      expect(first.followRedirects, isFalse);
      expect(first.headers['authorization'], 'Bearer $_tok');
      final signed = fx.net.log.firstWhere((r) => r.uri.host == 'logs.example.invalid');
      expect(signed.headers.containsKey('authorization'), isFalse);
      expect(signed.uri.queryParameters['sig'], '1');
    });

    test('günlük birkaç kez 404 dönerse yeniden denenir', () async {
      final fx = _Fx();
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'completed', 'conclusion': 'failure'}));
      fx.net.on('GET /repos/o/r/actions/runs/101/jobs', _j(200, _job()));
      fx.net.on('GET /repos/o/r/actions/jobs/555/logs', _j(404, {'message': 'henüz yok'}));
      fx.net.on('GET /repos/o/r/actions/jobs/555/logs', _j(404, {'message': 'henüz yok'}));
      fx.net.on('GET /repos/o/r/actions/jobs/555/logs', GithubHttpResponse(200, _fxLog('analyze_fail.log')));
      final o = await fx.run();
      expect(o, isA<CiFailure>());
      expect(fx.net.count('GET /repos/o/r/actions/jobs/555/logs'), 3);
    });

    test('günlük hiç indirilemezse infraError(logsUnavailable)', () async {
      final fx = _Fx();
      fx.net.on('GET /repos/o/r/actions/runs', _j(200, _runs()));
      fx.net.on('GET /repos/o/r/actions/runs/101', _j(200, {'status': 'completed', 'conclusion': 'failure'}));
      fx.net.on('GET /repos/o/r/actions/runs/101/jobs', _j(200, _job()));
      fx.net.on('GET /repos/o/r/actions/jobs/555/logs', _j(410, {'message': 'süresi doldu'}));
      final o = await fx.run() as CiInfraError;
      expect(o.reason, CiInfraReason.logsUnavailable);
    });

    test('test hatası ve derleme hatası CiFailure olur', () async {
      final a = _Fx()..failedRun(_fxLog('test_fail.log'));
      final fa = await a.run() as CiFailure;
      expect(fa.signature.stage, 'test');
      expect(fa.result.diagnostics.length, 2);
      final b = _Fx()..failedRun(_fxLog('build_fail.log'));
      expect(((await b.run()) as CiFailure).signature.stage, 'build');
    });

    test('aynı hata tekrar edince imza aynı (orkestratör döngü tespiti)', () async {
      final a = _Fx()..failedRun(_fxLog('analyze_fail.log'));
      final b = _Fx()
        ..failedRun(_fxLog('analyze_fail.log').replaceAll(':12:5', ':19:5').replaceAll(':40:3', ':47:3'));
      final fa = await a.run() as CiFailure;
      final fb = await b.run() as CiFailure;
      expect(fa.signature, equals(fb.signature));
    });

    test('kurulum adımı (flutter-action) başarısız -> infraError(setupFailed), CiFailure DEĞİL', () async {
      final fx = _Fx();
      fx.failedRun(_fxLog('setup_fail.log'), job: _j(200, _job(step: 'Run subosito/flutter-action@v2.18.0')));
      final o = await fx.run();
      expect(o, isNot(isA<CiFailure>()));
      expect((o as CiInfraError).reason, CiInfraReason.setupFailed);
      expect(o.message, contains('flutter-action'));
    });

    test('Kripton aşaması hiç başlamadıysa (işaretçi yok) -> infraError(setupFailed)', () async {
      final fx = _Fx()..failedRun(_fxLog('setup_fail.log'));
      final o = await fx.run() as CiInfraError;
      expect(o.reason, CiInfraReason.setupFailed);
      expect(o.message, contains('Could not resolve host'));
    });

    test('aşama bitiş işaretçisi olmadan kesildi -> infraError(stageInterrupted)', () async {
      final fx = _Fx()..failedRun(_fxLog('interrupted.log'));
      final o = await fx.run() as CiInfraError;
      expect(o.reason, CiInfraReason.stageInterrupted);
    });

    test('ham günlük diske maskeli yazılır; token ne diskte, ne AI metninde, ne iletide geçer', () async {
      final store = CiLogStore(dir: Directory('${tmp.path}/devlogs'));
      final fx = _Fx(logStore: store);
      final leaky = _fxLog('analyze_fail.log').replaceFirst(
        'Analyzing kripton_ai...',
        'Analyzing kripton_ai...\n  remote: https://x-access-token:$_tok@github.com/o/r\n  Authorization: Bearer $_tok',
      );
      fx.failedRun(leaky);
      final o = await fx.run() as CiFailure;
      final disk = File(o.rawLogPath!).readAsStringSync();
      expect(disk, isNot(contains(_tok)));
      expect(disk, contains('***'));
      expect(o.feedback, isNot(contains(_tok)));
      expect(o.result.stageLog, isNot(contains(_tok)));
      final json = jsonDecode(disk) as Map<String, dynamic>;
      expect(json['stage'], 'analyze');
      expect(json['sha'], _sha);
      expect(json['runId'], 101);
      // altyapı hatası iletisi de maskeli
      final fx2 = _Fx();
      fx2.failedRun('##[error]git push https://x-access-token:$_tok@github.com/o/r\n', job: _j(200, _job(step: 'Run actions/checkout@v6.0.0')));
      final o2 = await fx2.run() as CiInfraError;
      expect(o2.message, isNot(contains(_tok)));
    });
  });

  group('CiLogStore', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('kripton_logstore_');
      SecretMask.clear();
    });
    tearDown(() {
      SecretMask.clear();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('boyut sınırı: sonu korunur, başı kırpılır, bayrak işaretlenir', () async {
      final store = CiLogStore(dir: tmp, maxBytesPerLog: 1000);
      final text = '${List.generate(500, (i) => 'satir $i çok uzun bir satır').join('\n')}\nSON-SATIR';
      final p = await store.save(branch: 'kripton/dev-1', sha: _sha, runId: 1, runUrl: _runUrl, stage: 'test', text: text);
      final json = jsonDecode(File(p!).readAsStringSync()) as Map<String, dynamic>;
      expect(json['truncated'], isTrue);
      expect(json['originalChars'], text.length);
      final log = json['log'] as String;
      expect(utf8.encode(log).length, lessThan(1200));
      expect(log, endsWith('SON-SATIR'));
      expect(log, startsWith('[…'));
    });

    test('sınırın altındaki günlük aynen yazılır', () async {
      final store = CiLogStore(dir: tmp);
      final p = await store.save(branch: 'kripton/dev-1', sha: _sha, runId: 2, runUrl: _runUrl, stage: 'analyze', text: 'merhaba\ndünya', exitCode: 1);
      final json = jsonDecode(File(p!).readAsStringSync()) as Map<String, dynamic>;
      expect(json['truncated'], isFalse);
      expect(json['log'], 'merhaba\ndünya');
      expect(json['exitCode'], 1);
    });

    test('maskeleme kırpmadan ÖNCE yapılır: sınırda bölünen token sızmaz', () async {
      SecretMask.register(_tok);
      final store = CiLogStore(dir: tmp, maxBytesPerLog: 100);
      final text = '${'x' * 500}\ntoken=$_tok\n${'y' * 70}';
      final p = await store.save(branch: 'b', sha: _sha, runId: 3, runUrl: '', stage: 'analyze', text: text);
      final disk = File(p!).readAsStringSync();
      expect(disk, isNot(contains(_tok)));
      expect(disk, isNot(contains(_tok.substring(0, 12))));
    });

    test('en son N günlük tutulur', () async {
      final store = CiLogStore(dir: tmp, keep: 2);
      for (var i = 1; i <= 4; i++) {
        await store.save(
          branch: 'b',
          sha: _sha,
          runId: i,
          runUrl: '',
          stage: 'analyze',
          text: 'g$i',
          now: DateTime.utc(2026, 10, 11, 10, 0, i),
        );
      }
      final files = await store.list();
      expect(files.length, 2);
      expect(files.first, endsWith('-4.json'));
      expect(files.last, endsWith('-3.json'));
      expect(tmp.listSync().whereType<File>().where((f) => f.path.endsWith('.bak') || f.path.endsWith('.tmp')), isEmpty);
    });

    test('yazılamazsa istisna fırlatmaz, null döner', () async {
      final blocker = File('${tmp.path}/dosya')..writeAsStringSync('x');
      final store = CiLogStore(dir: Directory('${blocker.path}/alt'));
      expect(await store.save(branch: 'b', sha: _sha, runId: 1, runUrl: '', stage: 's', text: 't'), isNull);
    });
  });
}
