import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/ci_batch.dart';
import 'package:kripton_ai/data/github_ci.dart';
import 'package:kripton_ai/data/project_snapshot.dart';

String _log(String stage, int code, List<String> lines) =>
    '2026-10-08T10:00:00.0000000Z ##KRIPTON-BEGIN:$stage\n'
    '${lines.map((l) => '2026-10-08T10:00:01.0000000Z $l').join('\n')}\n'
    '2026-10-08T10:00:02.0000000Z ##KRIPTON-END:$stage:$code\n';

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

  test('iş akışı işaretçi ve aşamaları içerir', () {
    final y = GithubCi.workflowYaml(runTests: true, buildApk: false);
    expect(y.contains("KRIPTON_TEST: '1'"), isTrue);
    expect(y.contains("KRIPTON_BUILD: '0'"), isTrue);
    expect(y.contains('flutter analyze --no-fatal-infos'), isTrue);
  });
}
