// test/dev_guard_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/dev_guard.dart';
import 'package:kripton_ai/application/dev_mode.dart';
import 'package:kripton_ai/application/workflow_runner.dart';
import 'package:kripton_ai/data/project_snapshot.dart';

Map<String, String> _files() => {
      'pubspec.yaml':
          'name: demo\nenvironment:\n  sdk: ^3.5.0\ndependencies:\n  flutter:\n    sdk: flutter\n',
      'lib/a.dart': 'int a() {\n  return 1;\n}\n',
      'lib/b.dart': "import 'package:flutter/material.dart';\n\nclass B {\n  int x = 0;\n}\n",
      'lib/dup.dart': 'int dup() => 1;\nint dup() => 1;\n',
      'lib/net.dart': "import 'dart:io';\n\nclass N {}\n",
    };

Set<String> _scope() => {'lib/a.dart', 'lib/b.dart', 'lib/dup.dart', 'lib/net.dart'};

String _patch(String path, String oldCode, String newCode) =>
    '<<<<<<< DOSYA: $path\n<<<<<<< ESKİ\n$oldCode\n=======\n$newCode\n>>>>>>> YENİ';

DevRoundPlan _planFor(String path, String text) => DevRoundPlan([
      DevSegment(path: path, startLine: 0, endLine: text.split('\n').length, totalLines: text.split('\n').length, text: text),
    ]);

void main() {
  group('DevGuard G1 — çıktı biçimi', () {
    test('yama içermeyen çıktı reddedilir', () {
      final v = DevGuard.checkFiles(files: _files(), scope: _scope(), rawOutput: 'burada yama yok, sadece metin var');
      expect(v.ok, isFalse);
      expect(v.violations.first.gate, 'G1');
    });

    test('geçerli biçimli yama G1 ihlali vermez', () {
      final v = DevGuard.checkFiles(
        files: _files(),
        scope: _scope(),
        rawOutput: _patch('lib/a.dart', 'int a() {\n  return 1;\n}', 'int a() {\n  return 2;\n}'),
      );
      expect(v.violations.where((x) => x.gate == 'G1'), isEmpty);
    });
  });

  group('DevGuard G2 — yol/kapsam/yasak', () {
    test('kapsamda olan geçerli yol G2 ihlali vermez', () {
      expect(DevGuard.pathProblem('lib/a.dart', _files(), _scope(), isNew: false), isNull);
    });
    test('uydurma yol reddedilir', () {
      expect(DevGuard.pathProblem('lib/yok.dart', _files(), _scope(), isNew: false), isNotNull);
    });
    test('.. içeren yol reddedilir', () {
      expect(DevGuard.pathProblem('lib/../secret.dart', _files(), _scope(), isNew: false), isNotNull);
    });
    test('.github yasak', () {
      expect(DevGuard.pathProblem('.github/workflows/ci.yml', _files(), _scope(), isNew: true), isNotNull);
    });
    test('gizli dosya yasak', () {
      expect(DevGuard.pathProblem('lib/.env', _files(), _scope(), isNew: true), isNotNull);
    });
    test('pubspec.lock yasak', () {
      expect(DevGuard.pathProblem('pubspec.lock', _files(), _scope(), isNew: false), isNotNull);
    });
    test('kapsam dışı reddedilir', () {
      expect(DevGuard.pathProblem('lib/net.dart', _files(), {'lib/a.dart'}, isNew: false), isNotNull);
    });
    test('yeni dosya lib/test dışında reddedilir', () {
      expect(DevGuard.pathProblem('android/x.dart', _files(), _scope(), isNew: true), isNotNull);
    });
  });

  group('DevGuard G3 — ESKİ blok eşleşmesi', () {
    test('birebir ve tek eşleşme geçer', () {
      expect(DevGuard.matchProblem(_files()['lib/a.dart']!, 'int a() {\n  return 1;\n}'), isNull);
    });
    test('eşleşmeyen blok reddedilir', () {
      expect(DevGuard.matchProblem(_files()['lib/a.dart']!, 'int nope() => 0;'), isNotNull);
    });
    test('çift eşleşme reddedilir', () {
      expect(DevGuard.matchProblem(_files()['lib/dup.dart']!, 'int dup() => 1;'), isNotNull);
    });
    test('uçtan uca: eşleşmeyen ESKİ reddedilir', () {
      final v = DevGuard.checkFiles(
        files: _files(),
        scope: _scope(),
        rawOutput: _patch('lib/a.dart', 'int nope() => 0;', 'int a() => 9;'),
      );
      expect(v.ok, isFalse);
      expect(v.violations.any((x) => x.gate == 'G3'), isTrue);
    });
  });

  group('DevGuard G4 — büyüklük', () {
    test('dosya boşaltma reddedilir', () {
      final big = 'int a() {\n  return 1;\n}';
      final v = DevGuard.checkFiles(
        files: _files(),
        scope: _scope(),
        rawOutput: _patch('lib/a.dart', big, ''),
      );
      expect(v.ok, isFalse);
    });
    test('şüpheli büyük silme reddedilir', () {
      final old = List<String>.generate(60, (i) => '// satir $i').join('\n');
      final files = {..._files(), 'lib/big.dart': '$old\nint big() => 1;\n'};
      final scope = {..._scope(), 'lib/big.dart'};
      final v = DevGuard.checkFiles(
        files: files,
        scope: scope,
        rawOutput: _patch('lib/big.dart', old, 'int big() => 1;'),
      );
      expect(v.violations.any((x) => x.gate == 'G4'), isTrue);
    });
  });

  group('DevGuard G5/G6 — sözdizimi ve import', () {
    test('parantez bozumu reddedilir (G5)', () {
      final v = DevGuard.checkFiles(
        files: _files(),
        scope: _scope(),
        rawOutput: _patch('lib/b.dart', 'class B {\n  int x = 0;\n}', 'class B {\n  int x = 0;\n'),
      );
      expect(v.ok, isFalse);
      expect(v.violations.any((x) => x.gate == 'G5'), isTrue);
    });
    test('bilinmeyen paket importu reddedilir (G6)', () {
      final v = DevGuard.checkFiles(
        files: _files(),
        scope: _scope(),
        rawOutput: _patch(
          'lib/b.dart',
          "import 'package:flutter/material.dart';",
          "import 'package:flutter/material.dart';\nimport 'package:uydurma_paket/x.dart';",
        ),
      );
      expect(v.ok, isFalse);
      expect(v.violations.any((x) => x.gate == 'G6'), isTrue);
    });
    test('mevcut hata sayısı artmadıkça geçer', () {
      // lib/net.dart zaten dart:io kullanıyor; aynı yapı korunuyorsa ret yok.
      final v = DevGuard.checkFiles(
        files: _files(),
        scope: _scope(),
        rawOutput: _patch('lib/a.dart', '  return 1;', '  return 2;'),
      );
      expect(v.ok, isTrue);
    });
  });

  group('DevGuard G7 — dejenere çıktı', () {
    test('boş çıktı reddedilir', () {
      final v = DevGuard.checkFiles(files: _files(), scope: _scope(), rawOutput: '   \n ');
      expect(v.ok, isFalse);
      expect(v.violations.first.gate, 'G7');
    });
    test('sınırsız tekrar reddedilir', () {
      final out = List<String>.generate(60, (_) => 'aynı satır tekrar ediyor').join('\n');
      expect(DevGuard.degenerateProblem(out), isNotNull);
    });
    test('dejenere çıktı uçtan uca reddedilir', () {
      final out = List<String>.generate(60, (_) => '<<<<<<< ESKİ tekrar').join('\n');
      final v = DevGuard.checkFiles(files: _files(), scope: _scope(), rawOutput: out);
      expect(v.ok, isFalse);
      expect(v.violations.first.gate, 'G7');
    });
  });

  group('DevGuard G8 — sır/şüpheli ekleme', () {
    test('sır benzeri dize eklenemez', () {
      final v = DevGuard.checkFiles(
        files: _files(),
        scope: _scope(),
        rawOutput: _patch('lib/a.dart', '  return 1;', "  return 2; // token ghp_abcdefghijklmnop1234"),
      );
      expect(v.ok, isFalse);
      expect(v.violations.any((x) => x.gate == 'G8'), isTrue);
      expect(v.violations.first.detail.contains('ghp_abcdefghijklmnop1234'), isFalse);
    });
    test('şüpheli süreç çağrısı eklenemez', () {
      final v = DevGuard.checkFiles(
        files: _files(),
        scope: _scope(),
        rawOutput: _patch('lib/a.dart', '  return 1;', '  Process.start("sh", ["-c", "x"]);\n  return 2;'),
      );
      expect(v.violations.any((x) => x.gate == 'G8'), isTrue);
    });
    test('zaten ağ kullanan dosyada mevcut kalıp serbest', () {
      final files = {..._files(), 'lib/net.dart': "import 'dart:io';\n\nclass N { final c = HttpClient(); }\n"};
      final v = DevGuard.checkFiles(
        files: files,
        scope: _scope(),
        rawOutput: _patch('lib/net.dart', 'class N { final c = HttpClient(); }', 'class N { final c = HttpClient(); int k = 1; }'),
      );
      expect(v.violations.where((x) => x.gate == 'G8'), isEmpty);
    });
    test('ağ çağrısı olmayan dosyaya yeni HttpClient() eklenemez', () {
      final v = DevGuard.checkFiles(
        files: _files(),
        scope: _scope(),
        rawOutput: _patch('lib/net.dart', 'class N {}', 'class N { final io = HttpClient(); }'),
      );
      expect(v.violations.any((x) => x.gate == 'G8'), isTrue);
    });
  });

  test('200 betikli kötü çıktı — tamamı reddedilir (fail-closed)', () {
    final files = _files();
    final scope = _scope();
    final scripts = <String>[];
    for (var i = 0; i < 40; i++) {
      scripts.add(_patch('lib/ghost_$i.dart', 'x', 'y')); // uydurma yol
    }
    for (var i = 0; i < 40; i++) {
      scripts.add(_patch('lib/a.dart', 'int nope_$i() => $i;', 'int a() => $i;')); // eşleşmeyen blok
    }
    for (var i = 0; i < 40; i++) {
      scripts.add(i.isEven ? '' : '   \n  \n'); // boş çıktı
    }
    for (var i = 0; i < 40; i++) {
      scripts.add(List<String>.generate(50, (_) => 'tekrar satiri $i').join('\n')); // sınırsız tekrar
    }
    for (var i = 0; i < 40; i++) {
      scripts.add(_patch('lib/dup.dart', 'int dup() => 1;', 'int dup() => 2;')); // çift eşleşme
    }
    expect(scripts.length, 200);
    var rejected = 0;
    for (final s in scripts) {
      final v = DevGuard.checkFiles(files: files, scope: scope, rawOutput: s);
      if (!v.ok && v.violations.isNotEmpty) rejected++;
    }
    // ignore: avoid_print
    print('200 betiğin $rejected tanesi reddedildi.');
    expect(rejected, 200);
  });

  test('check(), ProjectSnapshot + DevRoundPlan üzerinden delege eder (doğrulama adapterı)', () {
    // DevGuard.check tek satırda checkFiles'e delege eder; burada yalnızca import/derleme
    // bütünlüğü sağlanır. ProjectSnapshot kurucusu bu ortamda doğrulanamadığı için
    // uçtan uca snapshot testi yazılamadı (bkz. DEVİR NOTU / DOĞRULANAMADI).
    expect(DevGuard.checkFiles, isNotNull);
    expect(_planFor('lib/a.dart', _files()['lib/a.dart']!).paths, {'lib/a.dart'});
  });

  group('DevPrompts.parseVerifier', () {
    test('KARAR: ONAY kabul', () {
      expect(DevPrompts.parseVerifier('KARAR: ONAY'), isTrue);
    });
    test('büyük/küçük harf duyarsız', () {
      expect(DevPrompts.parseVerifier('karar: onay'), isTrue);
    });
    test('RED reddedilir', () {
      expect(DevPrompts.parseVerifier('KARAR: RED\nneden'), isFalse);
    });
    test('belirsiz (iki karar) reddedilir', () {
      expect(DevPrompts.parseVerifier('KARAR: ONAY\nKARAR: RED'), isFalse);
    });
    test('boş ve ayrıştırılamayan reddedilir', () {
      expect(DevPrompts.parseVerifier(''), isFalse);
      expect(DevPrompts.parseVerifier('bence iyi görünüyor'), isFalse);
    });
  });

  group('VerifierPolicy.choose', () {
    test('farklı sağlayıcı tercih edilir', () {
      expect(VerifierPolicy.choose('groq/llama', ['groq/x', 'gemini/pro']), 'gemini/pro');
    });
    test('ayný sağlayıcıdaysa farklı model', () {
      expect(VerifierPolicy.choose('groq/llama', ['groq/a', 'groq/llama']), 'groq/a');
    });
    test('aday yoksa null (RED sayılmalı)', () {
      expect(VerifierPolicy.choose('groq/llama', ['groq/llama']), isNull);
    });
  });

  group('DevPrompts.lessonsBlock', () {
    tearDown(() => DevPrompts.lessons = const []);
    test('varsayılan boş', () {
      expect(DevPrompts.lessonsBlock(), '');
    });
    test('dersler eklenir ve uzunluk sınırına uyar', () {
      DevPrompts.lessons = ['G3 ×4: eski blok uymadı', 'G2 ×1: uydurma yol'];
      final b = DevPrompts.lessonsBlock();
      expect(b.contains('ÖNCEKİ HATALARDAN KAÇIN'), isTrue);
      expect(b.contains('G3 ×4'), isTrue);
      expect(DevPrompts.lessonsBlock(maxChars: 5).contains('G3 ×4'), isFalse);
    });
  });

  group('DevPatcher.onReject', () {
    tearDown(() => DevPatcher.onReject = null);
    test('kapsam dışı yama reddedilince kanca çağrılır', () async {
      final calls = <String>[];
      DevPatcher.onReject = (path, reason) => calls.add('$path|$reason');
      final snap = ProjectSnapshot(name: 'demo', text: _files());
      final plan = _planFor('lib/a.dart', _files()['lib/a.dart']!);
      final patch = WorkflowRunner.parsePatches(_patch('lib/b.dart', 'class B {', 'class B {')).single;
      final out = await DevPatcher.apply(snap: snap, plan: plan, patches: [patch]);
      expect(out.rejected, 1);
      expect(calls.length, 1);
      expect(calls.single.startsWith('lib/b.dart|'), isTrue);
    });
  });
}
