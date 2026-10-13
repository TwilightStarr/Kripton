import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/profile_zip.dart';

Uint8List zipOf(Map<String, String> files) {
  final a = Archive();
  files.forEach((k, v) {
    final d = utf8.encode(v);
    a.addFile(ArchiveFile(k, d.length, d));
  });
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

void main() {
  test('metin dosyalarını parçalar, ikili/gizli dosyaları atlar', () {
    final bytes = zipOf({
      'ben/hakkimda.md': '# Ben\n\nAdım Ali. İstanbul\'da yaşıyorum.\n\nYazılım mühendisiyim.',
      'ben/notlar.txt': 'Kedim Pamuk.',
      'ben/foto.png': 'PNG',
      '__MACOSX/ben/._hakkimda.md': 'x',
      '.gizli.txt': 'x',
    });
    final r = parseProfileZip(bytes, 'ben.zip');
    expect(r.source.name, 'ben.zip');
    expect(r.source.fileCount, 2);
    expect(r.source.chunks.map((c) => c.path).toSet(), {'ben/hakkimda.md', 'ben/notlar.txt'});
    expect(r.source.chunks.map((c) => c.text).join(' '), contains('Pamuk'));
    expect(r.skipped.single, contains('foto.png'));
  });

  test('uzun metin parçalara bölünür ve hiçbiri sınırı aşmaz', () {
    final text = List.generate(60, (i) => 'Paragraf $i: ${'kelime ' * 40}').join('\n\n');
    final chunks = chunkText(text);
    expect(chunks.length, greaterThan(5));
    expect(chunks.every((c) => c.length <= kProfileChunkMax), isTrue);
    final one = chunkText('x ' * 3000);
    expect(one.every((c) => c.length <= kProfileChunkMax), isTrue);
  });

  test('html etiketleri ayıklanır', () {
    final r = parseProfileZip(
      zipOf({'a.html': '<html><script>var x=1;</script><body><p>Merhaba &amp; selam</p></body></html>'}),
      'a.zip',
    );
    expect(r.source.chunks.single.text, contains('Merhaba & selam'));
    expect(r.source.chunks.single.text, isNot(contains('var x')));
  });

  test('docx metni okunur', () {
    final docx = zipOf({
      'word/document.xml':
          '<w:document><w:body><w:p><w:r><w:t>Doktora öğrencisiyim</w:t></w:r></w:p><w:p><w:r><w:t>Kitap okurum</w:t></w:r></w:p></w:body></w:document>',
    });
    final a = Archive()..addFile(ArchiveFile('cv.docx', docx.length, docx));
    final r = parseProfileZip(Uint8List.fromList(ZipEncoder().encode(a)!), 'cv.zip');
    expect(r.source.chunks.map((c) => c.text).join('\n'), allOf(contains('Doktora'), contains('Kitap okurum')));
  });

  test('hatalı girdiler Türkçe FormatException verir', () {
    expect(() => parseProfileZip(Uint8List(0), 'x.zip'), throwsFormatException);
    expect(() => parseProfileZip(Uint8List.fromList([1, 2, 3, 4]), 'x.zip'), throwsFormatException);
    expect(() => parseProfileZip(zipOf({'a.png': 'x'}), 'x.zip'), throwsFormatException);
  });

  test('yol geçişi (..) normalleştirilir', () {
    final r = parseProfileZip(zipOf({'../../etc/notlar.txt': 'merhaba dünya'}), 'x.zip');
    expect(r.source.chunks.single.path, 'etc/notlar.txt');
  });
}
