import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/project_snapshot.dart';
import 'package:kripton_ai/data/project_zip.dart';

List<int> _zip(Map<String, String> files, {Map<String, List<int>> bin = const {}}) {
  final a = Archive();
  files.forEach((p, b) {
    final d = utf8.encode(b);
    a.addFile(ArchiveFile(p, d.length, d));
  });
  bin.forEach((p, d) => a.addFile(ArchiveFile(p, d.length, d)));
  return ZipEncoder().encode(a)!;
}

ProjectSnapshot _demo() => ProjectSnapshot(
  name: 'Demo',
  text: {
    'pubspec.yaml': 'name: demo\nversion: 1.0.0+3\n\ndependencies:\n  flutter:\n    sdk: flutter\n',
    'lib/main.dart': "import 'package:flutter/material.dart';\nvoid main() {}\n",
    'lib/ayarlar.dart': 'class AyarSayfasi {}\nenum Tema { acik, koyu }\n',
    'README.md': 'demo',
  },
  binary: {
    'assets/a.png': [1, 2, 3],
  },
);

void main() {
  group('ProjectSnapshot', () {
    test('tek üst klasörü soyar; metin/ikili ayırır; .git ve .. yollarını atlar', () {
      final bytes = _zip(
        {
          'Proje-main/pubspec.yaml': 'name: x\n',
          'Proje-main/lib/main.dart': 'void main() {}\n',
          'Proje-main/.git/config': 'gizli',
          'Proje-main/build/out.txt': 'cikti',
        },
        bin: {'Proje-main/assets/logo.png': [9, 9, 9]},
      );
      final s = ProjectSnapshot.fromZipBytes(bytes);
      expect(s.name, 'Proje-main');
      expect(s.text.keys, containsAll(['pubspec.yaml', 'lib/main.dart']));
      expect(s.binary.keys, ['assets/logo.png']);
      expect(s.has('.git/config'), isFalse);
      expect(s.has('build/out.txt'), isFalse);
      expect(s.pubspecName, 'x');
    });

    test('üst klasör yoksa soyma yapılmaz', () {
      final s = ProjectSnapshot.fromZipBytes(_zip({'a.txt': 'x', 'lib/b.dart': 'y'}));
      expect(s.text.keys.toSet(), {'a.txt', 'lib/b.dart'});
      expect(s.name, 'proje');
    });

    test('overlay yeni nesne döner, tabanı değiştirmez', () {
      final base = _demo();
      final next = base.overlay({'lib/main.dart': 'void main() { }\n', 'lib/yeni.dart': 'class Y {}\n'});
      expect(base.text['lib/main.dart'], contains('flutter/material'));
      expect(next.text['lib/yeni.dart'], 'class Y {}\n');
      expect(next.binary.keys, ['assets/a.png']);
    });

    test('compareTo yeni ve değişen dosyaları ayırır', () {
      final base = _demo();
      final next = base.overlay({'lib/main.dart': 'void main() {}\n// ek\n', 'lib/yeni.dart': 'class Y {}\n'});
      final c = base.compareTo(next);
      expect(c.added, ['lib/yeni.dart']);
      expect(c.modified, ['lib/main.dart']);
      expect(c.total, 2);
      expect(c.markdown(task: 'dene'), contains('lib/yeni.dart'));
    });

    test('toZipBytes gidiş-dönüş: ikili dosyalar ve üst klasör korunur', () {
      final base = _demo();
      final bytes = base.toZipBytes(topFolder: 'Demo', extra: {'NOT.md': 'x'});
      final back = ProjectSnapshot.fromZipBytes(bytes);
      expect(back.name, 'Demo');
      expect(back.text['lib/ayarlar.dart'], base.text['lib/ayarlar.dart']);
      expect(back.binary['assets/a.png'], [1, 2, 3]);
      expect(back.has('NOT.md'), isTrue);
    });

    test('digest: ağaç başta, göreve en ilgili dosya içerikle gelir, sınır aşılmaz', () {
      final d = _demo().digest('ayarlar sayfasına tema seçimi ekle', maxChars: 1500);
      expect(d, startsWith('# MEVCUT PROJE: Demo'));
      expect(d, contains('lib/ayarlar.dart'));
      expect(d, contains('class AyarSayfasi'));
      expect(d.length, lessThanOrEqualTo(1500));
    });

    test('relevantFiles: yol ve içerik eşleşmesine göre sıralar', () {
      final r = _demo().relevantFiles('ayarlar tema', limit: 2);
      expect(r.first, 'lib/ayarlar.dart');
    });

    test('signatures sınıf/enum adlarını çıkarır', () {
      expect(
        ProjectSnapshot.signatures('class A {}\nabstract class B {}\nenum C { x }\n'),
        ['class A', 'class B', 'enum C'],
      );
    });
  });

  group('bumpPubspecBuild', () {
    test('yapı numarasını artırır, satır sonunu korur', () {
      expect(bumpPubspecBuild('name: a\nversion: 1.0.0+3\n\ndeps:\n'), 'name: a\nversion: 1.0.0+4\n\ndeps:\n');
    });

    test('yapı numarası yoksa +1 ekler; version yoksa dokunmaz', () {
      expect(bumpPubspecBuild('version: 2.1.0\n'), 'version: 2.1.0+1\n');
      expect(bumpPubspecBuild('name: a\n'), 'name: a\n');
    });
  });

  group('buildProjectZip (taban projeyle)', () {
    test('dosyalar bindirilir, sürüm artar, günlük ve özet eklenir, ikili dosyalar korunur', () {
      final r = buildProjectZip(
        files: {'lib/yeni.dart': 'class Yeni {}\n'},
        rawContent: 'ham çıktı',
        title: 'Demo',
        task: 'yeni sınıf ekle',
        base: _demo(),
        now: DateTime(2026, 10, 5, 12, 30),
      );
      final names = ZipDecoder().decodeBytes(r.bytes).files.map((f) => f.name).toSet();
      expect(names, containsAll([
        'Demo/lib/yeni.dart',
        'Demo/lib/main.dart',
        'Demo/assets/a.png',
        'Demo/CHANGELOG.md',
        'Demo/KRIPTON_DEGISIKLIKLER.md',
        'Demo/KRIPTON_CIKTI.md',
      ]));
      final back = ProjectSnapshot.fromZipBytes(r.bytes);
      expect(back.text['pubspec.yaml'], contains('version: 1.0.0+4'));
      expect(back.text['CHANGELOG.md'], contains('2026-10-05 12:30'));
      expect(back.text['CHANGELOG.md'], contains('yeni: lib/yeni.dart'));
      expect(r.changes!.added, ['lib/yeni.dart']);
      expect(r.tree.last.path, startsWith('(+'));
    });

    test('model pubspec.yaml yazdıysa sürüme dokunulmaz', () {
      final r = buildProjectZip(
        files: {'pubspec.yaml': 'name: demo\nversion: 9.0.0+1\n'},
        rawContent: 'x',
        title: 'Demo',
        base: _demo(),
      );
      final back = ProjectSnapshot.fromZipBytes(r.bytes);
      expect(back.text['pubspec.yaml'], contains('version: 9.0.0+1'));
    });

    test('yeni paket import edilirse pubspec bağımlılığı eklenir', () {
      final r = buildProjectZip(
        files: {'lib/p.dart': "import 'package:provider/provider.dart';\nclass P {}\n"},
        rawContent: 'x',
        title: 'Demo',
        base: _demo(),
      );
      final back = ProjectSnapshot.fromZipBytes(r.bytes);
      expect(back.text['pubspec.yaml'], contains('provider: ^6.1.2'));
    });
  });
}
