import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/ci_batch.dart';
import 'package:kripton_ai/data/github_ci.dart';
import 'package:kripton_ai/data/project_snapshot.dart';

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
      printf "import 'package:demo/main.dart';\nvoid main() { MyApp(); }\n" > test/widget_test.dart
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
}
