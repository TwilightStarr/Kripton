// Görev 3/10: CiFeedback, CiFailureSignature ve CiOutcome testleri. Gerçek biçimli log fixture'ları
// (test/fixtures/ci/) kullanılır; ağ yok.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/ci_feedback.dart';
import 'package:kripton_ai/data/github_ci.dart';

String _fx(String name) => File('test/fixtures/ci/$name').readAsStringSync();

CiResult _parse(String name) => CiLogParser.parseJobLog(_fx(name), runUrl: 'https://github.com/o/r/actions/runs/1');

String _describe(CiOutcome o) => switch (o) {
      CiSuccess() => 'success',
      CiFailure(:final signature) => 'failure:${signature.stage}',
      CiInfraError(:final reason) => 'infra:${reason.name}',
      CiCancelled() => 'cancelled',
    };

/// Bütçe testleri için: 60 info, 3 uyarı, tekrarlı hatalar içeren analyze günlüğü.
CiResult _bigAnalyze() {
  final b = StringBuffer('##KRIPTON-BEGIN:analyze\nAnalyzing kripton_ai...\n');
  for (var i = 0; i < 60; i++) {
    b.writeln("   info • Use 'const' with the constructor $i • lib/ui/i$i.dart:${i + 1}:5 • prefer_const_constructors");
  }
  for (var i = 0; i < 3; i++) {
    b.writeln("warning • Unused import: 'dart:io$i' • lib/data/w$i.dart:1:8 • unused_import");
  }
  b.writeln("  error • The method 'foo' isn't defined for the type 'Bar' • lib/data/x.dart:12:5 • undefined_method");
  for (var i = 0; i < 20; i++) {
    b.writeln("  error • Undefined name 'q' • lib/data/x.dart:${100 + i}:3 • undefined_identifier");
  }
  b.writeln('83 issues found.');
  b.writeln('##KRIPTON-END:analyze:1');
  return CiLogParser.parseJobLog(b.toString());
}

void main() {
  group('CiLogParser (Görev 3 eklemeleri)', () {
    test('analyze: çıkış kodu ve info satırları', () {
      final r = _parse('analyze_fail.log');
      expect(r.stage, 'analyze');
      expect(r.exitCode, 1);
      expect(r.incomplete, isFalse);
      expect(r.diagnostics.length, 4); // 3 error + 1 warning
      expect(r.infoCount, 1);
      expect(CiLogParser.infoLines(r.stageLog).single, contains('prefer_const_constructors'));
    });

    test('test: başarısız testler tek tek, yığın izi aynen', () {
      final r = _parse('test_fail.log');
      expect(r.stage, 'test');
      expect(r.diagnostics.length, 2);
      final a = r.diagnostics[0];
      expect(a.path, 'test/a_test.dart');
      expect(a.line, 12);
      expect(a.message, 'test başarısız: test/a_test.dart: çıkarma hatalı');
      expect(a.raw, contains('Expected: <3>'));
      expect(a.raw, contains('    Actual: <2>'));
      expect(a.raw, contains('package:matcher'));
      final b = r.diagnostics[1];
      expect(b.path, 'test/b_test.dart');
      expect(b.raw, contains('Bad state: engine not ready'));
    });

    test('test: dosya yüklenemedi (derleme hatası) test dosyasına bağlanır', () {
      final r = _parse('test_load_fail.log');
      expect(r.diagnostics.single.path, 'test/c_test.dart');
      expect(r.diagnostics.single.line, 3);
      expect(r.diagnostics.single.message, startsWith('test dosyası yüklenemedi'));
    });

    test('build: iki derleme hatası, devam satırlarıyla', () {
      final r = _parse('build_fail.log');
      expect(r.stage, 'build');
      expect(r.diagnostics.length, 2);
      expect(r.diagnostics.first.raw, "lib/m.dart:7:3: Error: Undefined name 'q'.\n  q();\n  ^");
    });

    test('bitiş işaretçisi olmayan aşama incomplete', () {
      final r = _parse('interrupted.log');
      expect(r.ok, isFalse);
      expect(r.stage, 'analyze');
      expect(r.incomplete, isTrue);
      expect(r.exitCode, isNull);
    });

    test('başarılı günlük ok', () {
      expect(_parse('success.log').ok, isTrue);
    });

    test('işaretçisiz kurulum hatası setup', () {
      final r = _parse('setup_fail.log');
      expect(r.stage, 'setup');
      expect(r.ok, isFalse);
    });
  });

  group('CiFeedback.forAi', () {
    test('başlık, aşama, çıkış kodu, çalışma bağlantısı, dosya bazlı gruplar', () {
      final t = CiFeedback.forAi(_parse('analyze_fail.log'));
      expect(t, startsWith('CI SONUCU: BAŞARISIZ'));
      expect(t, contains('Aşama: analyze (çıkış kodu 1)'));
      expect(t, contains('Çalışma: https://github.com/o/r/actions/runs/1'));
      expect(t, contains('--- lib/data/x.dart ---'));
      expect(t, contains('--- lib/data/y.dart ---'));
      expect(t, contains('3 hata, 1 uyarı, 1 bilgi'));
    });

    test('her hata satırı ham çıktıyla aynen yer alır', () {
      final r = _parse('analyze_fail.log');
      final t = CiFeedback.forAi(r);
      expect(t, contains("  error • The method 'foo' isn't defined for the type 'Bar' • lib/data/x.dart:12:5 • undefined_method"));
      expect(t, contains("  error • Undefined name 'q' • lib/data/x.dart:40:3 • undefined_identifier"));
      expect(t, contains("warning • Unused import: 'dart:io' • lib/data/y.dart:1:8 • unused_import"));
    });

    test('tekrarlar tek satıra iner: ikinci oluşumun ham metni yok, konumu var', () {
      final t = CiFeedback.forAi(_parse('analyze_fail.log'));
      expect(t, contains('  tekrar: 55:9'));
      expect(t, isNot(contains('lib/data/x.dart:55:9 • undefined_identifier')));
    });

    test('test hatası: yığın izi ve beklenen/gerçek değer metinde', () {
      final t = CiFeedback.forAi(_parse('test_fail.log'));
      expect(t, contains('Aşama: test (çıkış kodu 1)'));
      expect(t, contains('Expected: <3>'));
      expect(t, contains('test/a_test.dart 12:5'));
      expect(t, contains('--- test/b_test.dart ---'));
    });

    test('derleme hatası: kod parçası satırları aynen', () {
      final t = CiFeedback.forAi(_parse('build_fail.log'));
      expect(t, contains("lib/m.dart:7:3: Error: Undefined name 'q'."));
      expect(t, contains('    q();'));
      expect(t, contains('Expected a declaration'));
    });

    test('başarılı sonuç', () {
      expect(CiFeedback.forAi(_parse('success.log')), startsWith('CI SONUCU: BAŞARILI'));
    });

    test('bütçe sığıyorsa hiçbir şey atılmaz ve info satırları dahildir', () {
      final rep = CiFeedback.build(_bigAnalyze(), budgetChars: 1000000);
      expect(rep.droppedInfoLines, 0);
      expect(rep.droppedWarningGroups, 0);
      expect(rep.droppedRepeats, 0);
      expect(rep.overBudget, isFalse);
      expect(rep.text, contains('--- bilgi satırları (60) ---'));
      expect(rep.text, contains('  tekrar: 119:3'));
    });

    test('bütçe aşımı sırası: önce info, sonra uyarı, sonra tekrar; hatalar korunur', () {
      final r = _bigAnalyze();
      final full = CiFeedback.build(r, budgetChars: 1000000);

      final s1 = CiFeedback.build(r, budgetChars: full.text.length - 200);
      expect(s1.droppedInfoLines, 60);
      expect(s1.droppedWarningGroups, 0);
      expect(s1.droppedRepeats, 0);
      expect(s1.text, isNot(contains('bilgi satırları (')));
      expect(s1.text, contains('Unused import'));

      final s2 = CiFeedback.build(r, budgetChars: s1.text.length - 100);
      expect(s2.droppedInfoLines, 60);
      expect(s2.droppedWarningGroups, 3);
      expect(s2.droppedRepeats, 0);
      expect(s2.text, isNot(contains('Unused import')));
      expect(s2.text, contains('  tekrar: 119:3'));

      final s3 = CiFeedback.build(r, budgetChars: s2.text.length - 10);
      expect(s3.droppedWarningGroups, 3);
      expect(s3.droppedRepeats, 19);
      expect(s3.text, contains('(+19 tekrar)'));
      expect(s3.text, isNot(contains('  tekrar: 119:3')));
    });

    test('bütçe 1 olsa bile hata satırları kırpılmaz (overBudget işaretlenir)', () {
      final r = _bigAnalyze();
      final rep = CiFeedback.build(r, budgetChars: 1);
      expect(rep.overBudget, isTrue);
      expect(rep.text, contains("The method 'foo' isn't defined for the type 'Bar'"));
      expect(rep.text, contains("Undefined name 'q'"));
      expect(rep.text, contains('lib/data/x.dart:12:5'));
      expect(rep.text, contains('hata satırları eksiksizdir'));
    });

    test('ayrıştırılamayan aşama: hata benzeri satırlar bütçe küçükken de kalır, son satırlar eklenir', () {
      final r = _parse('prebuild_fail.log');
      expect(r.diagnostics, isEmpty);
      final t = CiFeedback.build(r, budgetChars: 600).text;
      expect(t, contains('Aşama: prebuild (çıkış kodu 2)'));
      expect(t, contains('HATA: tool/ci_prebuild.sh: paket bulunamadı'));
      expect(t, contains('satır atıldı'));
      final all = CiFeedback.build(r, budgetChars: 100000).text;
      expect(all, contains('adım 0 tamam'));
      expect(all, isNot(contains('satır atıldı')));
    });
  });

  group('CiFailureSignature', () {
    String shift(String log, int by) => log.replaceAllMapped(
          RegExp(r'(lib/[a-z/_0-9]+\.dart):(\d+):(\d+)'),
          (m) => '${m.group(1)}:${int.parse(m.group(2)!) + by}:${int.parse(m.group(3)!) + by}',
        );

    test('satır/sütun numarası değişince aynı imza', () {
      final a = CiFailureSignature.of(_parse('analyze_fail.log'));
      final b = CiFailureSignature.of(CiLogParser.parseJobLog(shift(_fx('analyze_fail.log'), 7)));
      expect(a, equals(b));
      expect(a.sameAs(b), isTrue);
      expect(a.id, b.id);
      expect(a.id.length, 12);
    });

    test('farklı hata ya da farklı sayı farklı imza', () {
      final a = CiFailureSignature.of(_parse('analyze_fail.log'));
      final fewer = _fx('analyze_fail.log').split('\n').where((l) => !l.contains(':55:9')).join('\n');
      expect(CiFailureSignature.of(CiLogParser.parseJobLog(fewer)), isNot(equals(a)));
      final other = _fx('analyze_fail.log').replaceAll('undefined_method', 'undefined_getter');
      expect(CiFailureSignature.of(CiLogParser.parseJobLog(other)), isNot(equals(a)));
    });

    test('aşama imzaya girer', () {
      final a = CiFailureSignature.of(_parse('build_fail.log'));
      expect(a.stage, 'build');
      expect(a.key, startsWith('build|'));
      expect(a.key, isNot(contains(':7:3')));
    });

    test('derleme hatası iletisi satır numarasından bağımsız', () {
      final a = CiFailureSignature.of(_parse('build_fail.log'));
      final b = CiFailureSignature.of(CiLogParser.parseJobLog(shift(_fx('build_fail.log'), 3)));
      expect(a, equals(b));
    });

    test('test imzası test başlığına bağlıdır, yığın satırına değil', () {
      final a = CiFailureSignature.of(_parse('test_fail.log'));
      final moved = _fx('test_fail.log').replaceAll('a_test.dart 12:5', 'a_test.dart 14:5');
      expect(CiFailureSignature.of(CiLogParser.parseJobLog(moved)), equals(a));
    });

    test('ayrıştırılamayan hata: çıkış kodu + son satır biçimi', () {
      final a = CiFailureSignature.of(_parse('prebuild_fail.log'));
      expect(a.entries.first, 'exit:2');
      expect(a.entries.last, startsWith('tail:'));
    });
  });

  test('CiOutcome kapsamlı switch ile işlenebilir', () {
    final r = _parse('analyze_fail.log');
    final outcomes = <CiOutcome>[
      const CiSuccess(),
      CiFailure(signature: CiFailureSignature.of(r), feedback: 'x', result: r),
      const CiInfraError(reason: CiInfraReason.timeout, message: 'm'),
      const CiCancelled(),
    ];
    expect(outcomes.map(_describe).toList(), ['success', 'failure:analyze', 'infra:timeout', 'cancelled']);
  });
}
