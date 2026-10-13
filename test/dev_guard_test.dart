// Görev 4/10: DevGuard kapıları (G1-G8), doğrulayıcı ayrıştırıcı, doğrulayıcı seçimi ve DevPatcher kancası.
// Saf Dart: ağ yok, gerçek sır yok (sahte anahtarlar çalışma zamanında birleştirilir).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/dev_guard.dart';
import 'package:kripton_ai/application/dev_mode.dart';
import 'package:kripton_ai/application/workflow_runner.dart';
import 'package:kripton_ai/data/project_snapshot.dart';
import 'package:kripton_ai/data/secret_mask.dart';

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

ProjectSnapshot _snap([Map<String, String>? extra]) => ProjectSnapshot(
  name: 'demo',
  text: {
    'pubspec.yaml': _pubspec,
    'lib/main.dart': _main,
    'lib/util.dart': 'int yardim() => 1;\n',
    'lib/other.dart': 'int baska() => 3;\n',
    ...?extra,
  },
);

String _patch(String path, String old, String neu) =>
    '<<<<<<< DOSYA: $path\n<<<<<<< ESKİ\n$old\n=======\n$neu\n>>>>>>> YENİ\n';

String _newFile(String path, String body) => '<<<<<<< DOSYA: $path\n<<<<<<< TAM\n$body\n>>>>>>> YENİ\n';

final String _valid = _patch('lib/main.dart', '  return a + 1;', '  return a + 2;');

GuardVerdict _run(
  String out, {
  ProjectSnapshot? snap,
  Set<String>? scope,
  String finding = '',
  DevGuardLimits limits = const DevGuardLimits(),
}) => DevGuard.check(
  snap ?? _snap(),
  scope: scope ?? {'lib/main.dart'},
  rawOutput: out,
  finding: finding,
  limits: limits,
);

void _expectRejected(GuardVerdict v, String gate) {
  expect(v.ok, isFalse, reason: v.summary);
  expect(v.changes, isEmpty);
  expect(v.gates, contains(gate), reason: v.summary);
}

/// Her satırı farklı, boyutu istenen kadar büyük (dejenere sayılmayan) Dart metni.
String _varied(int lines) => [for (var i = 0; i < lines; i++) 'int f$i() => $i;'].join('\n');

class _BoomSnapshot implements ProjectSnapshot {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('boom');
}

void main() {
  tearDown(SecretMask.clear);

  group('G1 çıktı biçimi', () {
    test('geçerli ESKİ/YENİ yaması ok döner ve TAM yeni içeriği verir', () {
      final v = _run(_valid);
      expect(v.ok, isTrue, reason: v.summary);
      expect(v.violations, isEmpty);
      expect(v.changedPaths, ['lib/main.dart']);
      expect(v.changes['lib/main.dart'], contains('return a + 2;'));
      expect(v.changes['lib/main.dart'], isNot(contains('return a + 1;')));
      expect(v.changes['lib/main.dart'], contains('int ikili()'));
    });

    test('yama bloğu olmayan metin reddedilir', () {
      _expectRejected(_run('Merhaba, hatayı düzelttim, her şey yolunda.'), DevGate.format);
    });

    test('kesik (kapanmamış) blok reddedilir', () {
      final cut = _valid.substring(0, _valid.indexOf('>>>>>>>'));
      _expectRejected(_run(cut), DevGate.format);
    });

    test('yeni kodda sızan ======= işareti reddedilir', () {
      final out = _patch('lib/main.dart', '  return a + 1;', '  return 2;\n=======\n  return 3;');
      _expectRejected(_run(out), DevGate.format);
    });

    test('ESKİ işareti olmayan blok reddedilir', () {
      const out = '<<<<<<< DOSYA: lib/main.dart\n  return a + 1;\n=======\n  return a + 2;\n>>>>>>> YENİ\n';
      _expectRejected(_run(out), DevGate.format);
    });

    test('değişiklik üretmeyen (eski == yeni) yama ok değildir', () {
      final v = _run(_patch('lib/main.dart', '  return a + 1;', '  return a + 1;'));
      _expectRejected(v, DevGate.format);
    });

    test('iç hata (istisna) fail-closed: ok false, G0', () {
      final v = DevGuard.check(_BoomSnapshot(), scope: {'lib/main.dart'}, rawOutput: _valid);
      expect(v.ok, isFalse);
      expect(v.gates, {DevGate.internal});
    });
  });

  group('G2 yol / kapsam / yasak', () {
    test('lib/ altında yeni .dart dosyası geçer', () {
      final v = _run(_newFile('lib/yeni.dart', 'int yeni() => 1;\n'));
      expect(v.ok, isTrue, reason: v.summary);
      expect(v.changes.keys, ['lib/yeni.dart']);
    });

    test('uydurma (var olmayan) yol reddedilir', () {
      _expectRejected(_run(_patch('lib/uydurma.dart', 'a', 'b')), DevGate.path);
    });

    test('kapsam dışındaki var olan dosya reddedilir', () {
      _expectRejected(_run(_patch('lib/other.dart', 'int baska() => 3;', 'int baska() => 4;')), DevGate.path);
    });

    test('yasak yollar reddedilir (.github, .git, pubspec.lock, .env, anahtar dosyası)', () {
      const forbidden = [
        '.github/workflows/ci.yml',
        '.git/config',
        'pubspec.lock',
        '.env',
        '.env.local',
        'android/key.properties',
        'android/app/upload.jks',
        'certs/server.pem',
        'android/local.properties',
      ];
      for (final f in forbidden) {
        final snap = _snap({f: 'x = 1\n'});
        final v = _run(_patch(f, 'x = 1', 'x = 2'), snap: snap, scope: {f});
        _expectRejected(v, DevGate.path);
      }
    });

    test('.. mutlak yol ve geçersiz yol parçaları reddedilir', () {
      for (final f in ['../x.dart', 'lib/../x.dart', '/lib/main.dart', 'lib//x.dart', 'lib/./x.dart', 'C:/x.dart']) {
        _expectRejected(_run(_newFile(f, 'int x() => 1;\n')), DevGate.path);
      }
    });

    test('yeni dosya lib/ ve test/ dışına veya .dart dışına yazılamaz', () {
      _expectRejected(_run(_newFile('tool/x.dart', 'int x() => 1;\n')), DevGate.path);
      _expectRejected(_run(_newFile('lib/x.txt', 'merhaba\n')), DevGate.path);
    });

    test('var olan dosya TAM bloğuyla değiştirilemez; büyük/küçük harf çakışması reddedilir', () {
      _expectRejected(_run(_newFile('lib/main.dart', 'void main() {}\n')), DevGate.path);
      _expectRejected(_run(_newFile('lib/Util.dart', 'int x() => 1;\n')), DevGate.path);
    });
  });

  group('G3 ESKİ blok eşleşmesi', () {
    test('birebir ve tek eşleşme geçer', () {
      expect(_run(_valid).ok, isTrue);
    });

    test('eşleşmeyen ESKİ blok reddedilir', () {
      _expectRejected(_run(_patch('lib/main.dart', '  return a + 99;', '  return 0;')), DevGate.match);
    });

    test('yalnızca boşluğu farklı blok reddedilir (bulanık eşleşme YOK)', () {
      _expectRejected(_run(_patch('lib/main.dart', '  return  a + 1;', '  return a + 2;')), DevGate.match);
    });

    test('birden çok yerde eşleşen ESKİ blok reddedilir', () {
      final snap = _snap({'lib/dup.dart': 'int a() => 1;\nint b() => 1;\n'});
      final v = _run(_patch('lib/dup.dart', '=> 1;', '=> 2;'), snap: snap, scope: {'lib/dup.dart'});
      _expectRejected(v, DevGate.match);
      expect(v.summary, contains('birden çok'));
    });

    test('boş ESKİ blok reddedilir', () {
      const out = '<<<<<<< DOSYA: lib/main.dart\n<<<<<<< ESKİ\n=======\nx\n>>>>>>> YENİ\n';
      _expectRejected(_run(out), DevGate.match);
    });

    test('ikinci yama, birincinin sonucuna göre BİREBİR ve tek eşleşmeli', () {
      final ok = _patch('lib/main.dart', '  return a + 1;', '  return a + 2;') +
          _patch('lib/main.dart', '  return 2;', '  return 3;');
      final v = _run(ok);
      expect(v.ok, isTrue, reason: v.summary);
      expect(v.changes['lib/main.dart'], contains('return 3;'));
      final bad = _patch('lib/main.dart', '  return a + 1;', '  return a + 2;') +
          _patch('lib/main.dart', '  return a + 1;', '  return a + 3;');
      _expectRejected(_run(bad), DevGate.match);
    });
  });

  group('G4 değişiklik büyüklüğü', () {
    final bigBody = [for (var i = 0; i < 30; i++) "  print('satir numarasi $i');"].join('\n');
    final bigFile = 'void buyuk() {\n$bigBody\n}\n';

    test('büyük bloğu tek yorumla silmek reddedilir', () {
      final snap = _snap({'lib/big.dart': bigFile});
      final v = _run(_patch('lib/big.dart', bigBody, '  // kaldırıldı'), snap: snap, scope: {'lib/big.dart'});
      _expectRejected(v, DevGate.size);
    });

    test('dosyayı boşaltmak reddedilir', () {
      _expectRejected(_run(_patch('lib/util.dart', 'int yardim() => 1;', ' '), scope: {'lib/util.dart'}), DevGate.size);
    });

    test('toplu silme (>80 satır) reddedilir', () {
      final lines = [for (var i = 0; i < 200; i++) 'int v$i = $i;'];
      final snap = _snap({'lib/liste.dart': '${lines.join('\n')}\n'});
      final a = lines.sublist(0, 70).join('\n');
      final b = lines.sublist(100, 170).join('\n');
      final repl = [for (var i = 0; i < 20; i++) '// kaldirildi $i'].join('\n');
      final out = _patch('lib/liste.dart', a, repl) + _patch('lib/liste.dart', b, '$repl 2');
      _expectRejected(_run(out, snap: snap, scope: {'lib/liste.dart'}), DevGate.size);
    });

    test('aşırı büyük yeni dosya reddedilir', () {
      _expectRejected(_run(_newFile('lib/dev.dart', _varied(2600))), DevGate.size);
    });

    test('yama sayısı ve diff üst sınırı uygulanır', () {
      final two = _patch('lib/main.dart', '  return a + 1;', '  return a + 2;') +
          _patch('lib/main.dart', '  return 2;', '  return 3;');
      _expectRejected(_run(two, limits: const DevGuardLimits(maxPatches: 1)), DevGate.size);
      _expectRejected(_run(_valid, limits: const DevGuardLimits(maxDiffChars: 10)), DevGate.size);
    });
  });

  group('G5 sözdizimi / regresyon', () {
    test('dengesiz parantez getiren değişiklik reddedilir', () {
      _expectRejected(_run(_patch('lib/main.dart', '  return a + 1;', '  return (a + 2;')), DevGate.regression);
    });

    test('var olan hata artmıyorsa geçer', () {
      final snap = _snap({'lib/broken.dart': 'void f() {\n  var a = 1;\n'});
      final v = _run(_patch('lib/broken.dart', '  var a = 1;', '  var a = 2;'), snap: snap, scope: {'lib/broken.dart'});
      expect(v.ok, isTrue, reason: v.summary);
    });

    test('pubspec.yaml bozulursa reddedilir', () {
      final v = _run(_patch('pubspec.yaml', 'dependencies:', '# kaldırıldı'), scope: {'pubspec.yaml'});
      _expectRejected(v, DevGate.regression);
    });
  });

  group('G6 import', () {
    test('dart:, bildirilmiş paket ve var olan dosya import\'ları geçer', () {
      final v = _run(
        _patch(
          'lib/main.dart',
          "import 'util.dart';",
          "import 'dart:math';\nimport 'package:http/http.dart' as http;\nimport 'other.dart';\nimport 'util.dart';",
        ),
      );
      expect(v.ok, isTrue, reason: v.summary);
    });

    test('bildirilmemiş paket, olmayan dosya, bilinmeyen dart: ve kök dışı import reddedilir', () {
      const bad = [
        "import 'package:uydurma_paket/x.dart';",
        "import 'yok.dart';",
        "import 'dart:nope';",
        "import 'package:demo/yok.dart';",
        "import '../../x.dart';",
        "import 'http://example.com/x.dart';",
      ];
      for (final imp in bad) {
        _expectRejected(_run(_patch('lib/main.dart', "import 'util.dart';", "$imp\nimport 'util.dart';")), DevGate.imports);
      }
    });

    test('pubspec\'ten hâlâ import edilen paketin kaldırılması reddedilir', () {
      final snap = _snap({'lib/net.dart': "import 'package:http/http.dart' as http;\nint n() => 1;\n"});
      final v = _run(_patch('pubspec.yaml', '  http: ^1.2.2', ''), snap: snap, scope: {'pubspec.yaml'});
      _expectRejected(v, DevGate.imports);
    });
  });

  group('G7 boş / dejenere', () {
    test('boş ve yalnızca boşluk çıktısı reddedilir', () {
      for (final s in ['', '   ', '\n\n\t \n']) {
        _expectRejected(_run(s), DevGate.degenerate);
      }
    });

    test('aynı yama bloğunun tekrarı reddedilir', () {
      _expectRejected(_run(_valid + _valid), DevGate.degenerate);
    });

    test('sınırsız satır / sözcük / karakter tekrarı reddedilir', () {
      _expectRejected(_run('${_valid}tamam\n' * 1 + 'tamam\n' * 500), DevGate.degenerate);
      _expectRejected(_run('$_valid${'abc ' * 400}'), DevGate.degenerate);
      _expectRejected(_run('$_valid${'x' * 300}'), DevGate.degenerate);
    });

    test('yeni kod olarak tekrar eden satırlar reddedilir', () {
      final rep = List.filled(40, '  print("ayni satir tekrar");').join('\n');
      _expectRejected(_run(_patch('lib/main.dart', '  return a + 1;', '$rep\n  return a + 1;')), DevGate.degenerate);
    });
  });

  group('G8 sır / şüpheli ekleme', () {
    test('sır biçimli dize eklemek reddedilir ve değer ayrıntıya sızmaz', () {
      final fakes = ['AIza${'B' * 30}', 'gsk_${'C' * 24}', 'ghp_${'D' * 30}', 'sk-or-${'E' * 20}'];
      for (final fake in fakes) {
        final v = _run(_patch('lib/main.dart', '  return a + 1;', "  const k = '$fake';\n  return a + 1;"));
        _expectRejected(v, DevGate.suspicious);
        expect(v.summary, isNot(contains(fake)));
        for (final x in v.violations) {
          expect(x.detail, isNot(contains(fake)));
        }
      }
    });

    test('kayıtlı sırrı koda eklemek reddedilir', () {
      const secret = 'zzKayitliSir-9f8e7d6c5b';
      SecretMask.register(secret);
      final v = _run(_patch('lib/main.dart', '  return a + 1;', "  const k = '$secret';\n  return a + 1;"));
      _expectRejected(v, DevGate.suspicious);
      expect(v.summary, isNot(contains(secret)));
    });

    test('apiKey gibi sıradan değişken adları yanlış pozitif vermez', () {
      final v = _run(_patch('lib/main.dart', '  return a + 1;', '  final apiKey = cfg.apiKey;\n  return a + 1;'));
      expect(v.ok, isTrue, reason: v.summary);
    });

    test('ilgisiz yere eklenen süreç/ağ çağrısı reddedilir', () {
      _expectRejected(
        _run(_patch('lib/main.dart', '  return a + 1;', "  Process.run('ls', []);\n  return a + 1;")),
        DevGate.suspicious,
      );
      _expectRejected(
        _run(_patch('lib/main.dart', '  return a + 1;', "  http.get(Uri.parse('x'));\n  return a + 1;")),
        DevGate.suspicious,
      );
    });

    test('bulgu ilgiliyse veya dosyada zaten varsa süreç çağrısı geçer', () {
      final out = _patch('lib/main.dart', '  return a + 1;', "  Process.run('ls', []);\n  return a + 1;");
      expect(_run(out, finding: 'Sorun: süreç çalıştırma eksik').ok, isTrue);
      final snap = _snap({'lib/main.dart': "${_main}void x() { Process.run('a', []); }\n"});
      expect(_run(out, snap: snap).ok, isTrue);
    });
  });

  group('Kabul: geçersiz hiçbir çıktı ok döndüremez', () {
    test('200 betikli kötü çıktının tamamı reddedilir', () {
      final dupSnap = _snap({'lib/dup.dart': 'int a() => 1;\nint b() => 1;\n'});
      final cases = <({String name, ProjectSnapshot snap, Set<String> scope, String out})>[];
      for (var i = 0; i < 40; i++) {
        cases.add((
          name: 'uydurma yol #$i',
          snap: _snap(),
          scope: {'lib/main.dart'},
          out: _patch('lib/uydurma_$i.dart', 'eski $i', 'yeni $i'),
        ));
        cases.add((
          name: 'eşleşmeyen blok #$i',
          snap: _snap(),
          scope: {'lib/main.dart'},
          out: _patch('lib/main.dart', '  return a + ${100 + i};', '  return 0;'),
        ));
        cases.add((
          name: 'boş çıktı #$i',
          snap: _snap(),
          scope: {'lib/main.dart'},
          out: [' ' * i, '\n' * i, '\t' * i][i % 3],
        ));
        cases.add((
          name: 'sınırsız tekrar #$i',
          snap: _snap(),
          scope: {'lib/main.dart'},
          out: switch (i % 3) {
            0 => '${'abc ' * (300 + i)}',
            1 => '$_valid${'tamam $i\n' * (50 + i)}',
            _ => '<<<<<<< DOSYA: lib/main.dart\n' * (20 + i),
          },
        ));
        cases.add((
          name: 'çift eşleşme #$i',
          snap: dupSnap,
          scope: {'lib/dup.dart'},
          out: _patch('lib/dup.dart', '=> 1;', '=> $i;'),
        ));
      }
      expect(cases.length, 200);
      var rejected = 0;
      for (final c in cases) {
        final v = DevGuard.check(c.snap, scope: c.scope, rawOutput: c.out);
        if (!v.ok && v.changes.isEmpty && v.violations.isNotEmpty) rejected++;
        expect(v.ok, isFalse, reason: c.name);
        expect(v.changes, isEmpty, reason: c.name);
      }
      // ignore: avoid_print
      print('GEÇERSİZ ÇIKTI: $rejected/${cases.length} reddedildi');
      expect(rejected, 200);
    });

    test('geçerli çıktının her kesik öneki reddedilir (kesik çıktı ok olamaz)', () {
      final end = _valid.indexOf('>>>>>>> YENİ') + '>>>>>>> YENİ'.length;
      var n = 0;
      for (var cut = 0; cut < end; cut++) {
        final v = _run(_valid.substring(0, cut));
        expect(v.ok, isFalse, reason: 'cut=$cut');
        n++;
      }
      // ignore: avoid_print
      print('KESİK ÖNEK: $n/$n reddedildi');
      expect(_run(_valid).ok, isTrue);
    });

    test('rastgele bozulmuş geçerli çıktılar (300) reddedilir', () {
      final rnd = Random(42);
      for (var i = 0; i < 300; i++) {
        late String out;
        switch (rnd.nextInt(5)) {
          case 0:
            out = _valid.replaceFirst('lib/main.dart', 'lib/${rnd.nextInt(1 << 30)}.dart');
          case 1:
            final at = _valid.indexOf('return a + 1;') + 3;
            out = '${_valid.substring(0, at)}Z${_valid.substring(at)}';
          case 2:
            out = _valid.replaceFirst('>>>>>>> YENİ', '');
          case 3:
            out = _valid + _valid;
          default:
            out = _valid + 'x' * (200 + rnd.nextInt(200));
        }
        final v = _run(out);
        expect(v.ok, isFalse, reason: 'i=$i\n$out');
      }
    });
  });

  test('ok olan kararın diff metni eski/yeni satırları gösterir', () {
    final v = _run(_valid);
    final d = v.diffText();
    expect(d, contains('@@ lib/main.dart @@'));
    expect(d, contains('-   return a + 1;'));
    expect(d, contains('+   return a + 2;'));
    expect(v.diffText(maxChars: 10), contains('diff kırpıldı'));
  });

  group('Doğrulayıcı (parseVerifier)', () {
    test('katı ONAY kabul edilir', () {
      final v = parseVerifier('KARAR: ONAY\n- bulgu çözüldü\n- ilgisiz değişiklik yok');
      expect(v.approved, isTrue);
      expect(v.reasons.length, 2);
      expect(parseVerifier('**KARAR: ONAY**').approved, isTrue);
      expect(parseVerifier('  KARAR: ONAY  \r\n- tamam').approved, isTrue);
    });

    test('açık RED, V1 kapısıyla ayrıştırılır', () {
      final v = parseVerifier('KARAR: RED\n- yeni hata\n- ilgisiz silme');
      expect(v.approved, isFalse);
      expect(v.parsed, isTrue);
      expect(v.gate, DevGate.verifierRed);
      expect(v.reasons, ['yeni hata', 'ilgisiz silme']);
    });

    test('belirsiz / boş / biçim dışı çıktı RED sayılır (V2)', () {
      const bad = [
        '',
        '   \n ',
        'Bence iyi görünüyor',
        'ONAY',
        'KARAR ONAY',
        'KARAR: BELKİ',
        'Evet, KARAR: ONAY',
        'karar: onay',
        'KARAR: ONAY\nKARAR: ONAY',
        'KARAR: ONAY\n- a\n- b\n- c\n- d',
        'KARAR: ONAY\ngerekçe tire olmadan',
        'Düşünüyorum...\nKARAR: ONAY',
      ];
      for (final s in bad) {
        final v = parseVerifier(s);
        expect(v.approved, isFalse, reason: s);
        expect(v.gate, DevGate.verifierUnparsable, reason: s);
      }
    });

    test('ONAY ile RED birlikte geçiyorsa RED (güvenli yön)', () {
      final v = parseVerifier('KARAR: ONAY\n- iyi\nKARAR: RED');
      expect(v.approved, isFalse);
      expect(v.gate, DevGate.verifierRed);
      expect(parseVerifier('karar: red').approved, isFalse);
    });

    test('aşırı uzun ONAY metni RED sayılır', () {
      expect(parseVerifier('KARAR: ONAY\n- ${'a' * 3000}').approved, isFalse);
    });

    test('gerekçelerde sır maskelenir', () {
      final fake = 'ghp_${'F' * 30}';
      final v = parseVerifier('KARAR: RED\n- anahtar $fake sızmış');
      expect(v.reasons.join(' '), isNot(contains(fake)));
    });

    test('özellik: rastgele metin yalnızca katı biçimdeyse ONAY olur', () {
      final rnd = Random(7);
      const words = ['KARAR:', 'ONAY', 'RED', '-', 'iyi', '\n', 'karar', 'onay', '**', 'ama', '•'];
      var approvals = 0;
      for (var i = 0; i < 2000; i++) {
        final body = [for (var k = 0; k < 1 + rnd.nextInt(10); k++) words[rnd.nextInt(words.length)]].join(
          rnd.nextBool() ? ' ' : '',
        );
        final s = '${rnd.nextBool() ? 'KARAR: ONAY\n' : ''}$body';
        final v = parseVerifier(s);
        if (v.approved) {
          approvals++;
          final first = s.trim().split('\n').first.replaceAll(RegExp(r'^[*`\s]+|[*`\s]+$'), '');
          expect(first, 'KARAR: ONAY', reason: s);
          expect(RegExp(r'KARAR\s*:\s*[*`\s]*RED\b', caseSensitive: false).hasMatch(s), isFalse, reason: s);
        }
      }
      expect(approvals, greaterThan(0));
    });
  });

  group('VerifierPolicy', () {
    test('yamayı yazan modelden FARKLI sağlayıcıyı seçer', () {
      expect(VerifierPolicy.choose('cloud:gemini', ['cloud:gemini', 'cloud:groq']), 'cloud:groq');
      expect(VerifierPolicy.choose('gemini-2.5-flash', ['gemini-2.0-flash', 'llama-3.3-70b-versatile']),
          'llama-3.3-70b-versatile');
    });

    test('fixer ile aynı model hiçbir koşulda seçilmez (büyük/küçük harf dahil)', () {
      expect(VerifierPolicy.choose('Gemini-2.5-Flash', ['gemini-2.5-flash', 'GEMINI-2.5-FLASH']), isNull);
      expect(VerifierPolicy.choose('a', const []), isNull);
      expect(VerifierPolicy.choose('a', ['a', '  ', 'A']), isNull);
    });

    test('farklı sağlayıcı yoksa aynı sağlayıcının başka modeli (zayıf bağımsızlık işaretiyle)', () {
      final c = VerifierPolicy.chooseDetailed('gemini-2.5-flash', ['gemini-2.5-flash', 'gemini-2.0-flash']);
      expect(c!.modelId, 'gemini-2.0-flash');
      expect(c.differentProvider, isFalse);
    });

    test('avoid listesindeki model yalnızca başka seçenek yoksa kullanılır', () {
      expect(
        VerifierPolicy.choose(
          'gemini-2.5-flash',
          ['llama-3.3-70b-versatile', 'meta-llama/llama-3.3-70b-instruct:free'],
          avoid: {'llama-3.3-70b-versatile'},
        ),
        'meta-llama/llama-3.3-70b-instruct:free',
      );
      expect(
        VerifierPolicy.choose('gemini-2.5-flash', ['llama-3.3-70b-versatile'], avoid: {'llama-3.3-70b-versatile'}),
        'llama-3.3-70b-versatile',
      );
    });

    test('sağlayıcı çıkarımı', () {
      expect(VerifierPolicy.providerOf('cloud:groq'), 'groq');
      expect(VerifierPolicy.providerOf('gemini-2.5-flash'), 'gemini');
      expect(VerifierPolicy.providerOf('meta-llama/llama-3.3-70b-instruct:free'), 'openrouter');
      expect(VerifierPolicy.providerOf('cloud-auto'), 'auto');
    });
  });

  group('DevPrompts ve DevPatcher kancaları', () {
    DevRoundPlan plan() => const DevRoundPlan([
      DevSegment(path: 'lib/main.dart', startLine: 0, endLine: 5, totalLines: 5, text: 'void main() {}'),
    ]);

    test('verifierSystem katı biçimi ister; verifierUser girdileri sınırlar', () {
      expect(DevPrompts.verifierSystem, contains('KARAR: ONAY'));
      expect(DevPrompts.verifierSystem, contains('KARAR: RED'));
      final u = DevPrompts.verifierUser('b' * 5000, 'd' * 9000);
      expect(u.length, lessThan(8000));
      expect(u, contains('BULGU:'));
      expect(u, contains('DIFF'));
    });

    test('lessons kancası: varsayılan boş ise istem DEĞİŞMEZ, doluysa eklenir', () {
      final report = const DevReport(findings: [DevFinding('lib/main.dart', 'Dosya: lib/main.dart\nSorun: x')], dropped: 0, raw: '');
      final base = DevPrompts.fixerUser(plan(), report);
      expect(DevPrompts.fixerUser(plan(), report, lessons: ''), base);
      expect(DevPrompts.fixerUser(plan(), report, lessons: '  \n'), base);
      final with_ = DevPrompts.fixerUser(plan(), report, lessons: 'ÖNCEKİ HATALARDAN KAÇIN:\n- G3');
      expect(with_, startsWith(base));
      expect(with_, endsWith('- G3'));
      expect(DevPrompts.withLessons('S', ''), 'S');
      expect(DevPrompts.withLessons('S', 'L'), 'S\n\nL');
    });

    test('gateOfReason metinleri kapı koduna eşler', () {
      expect(DevPatcher.gateOfReason('geçersiz yol'), 'G2');
      expect(DevPatcher.gateOfReason('bu turun kapsamı dışında'), 'G2');
      expect(DevPatcher.gateOfReason('ESKİ blok boş'), 'G3');
      expect(DevPatcher.gateOfReason('şüpheli büyük silme'), 'G4');
      expect(DevPatcher.gateOfReason('dosya boşaldı'), 'G4');
      expect(DevPatcher.gateOfReason('boş dosya'), 'G1');
      expect(DevPatcher.gateOfReason('Fazladan "}" (satır 3).', fallback: 'G5'), 'G5');
    });

    test('DevPatcher.apply onReject ile her reddi (kapı koduyla) bildirir', () async {
      final got = <String>[];
      final patches = WorkflowRunner.parsePatches(
        _patch('lib/uydurma.dart', 'a', 'b') +
            _patch('lib/main.dart', '  return a + 99;', '  return 0;') +
            _patch('lib/main.dart', '  return a + 1;', '  return (a + 2;'),
      );
      final out = await DevPatcher.apply(
        snap: _snap(),
        plan: DevRoundPlan([
          DevSegment(path: 'lib/main.dart', startLine: 0, endLine: 15, totalLines: 15, text: _main),
        ]),
        patches: patches,
        onReject: (path, gate, detail) => got.add('$gate:$path'),
      );
      expect(out.changed, isEmpty);
      expect(got, ['G2:lib/uydurma.dart', 'G3:lib/main.dart', 'G5:lib/main.dart']);
    });
  });
}
