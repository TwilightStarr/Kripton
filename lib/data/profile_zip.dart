import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../domain/chat_models.dart';

/// Sınırlar (zip bombası / dev dosya koruması).
const int kProfileMaxZipBytes = 20 * 1024 * 1024;
const int kProfileMaxFileBytes = 2 * 1024 * 1024;
const int kProfileMaxTotalBytes = 24 * 1024 * 1024;
const int kProfileMaxFiles = 400;
const int kProfileMaxChars = 400000;
const int kProfileChunkTarget = 700;
const int kProfileChunkMax = 950;

const _textExt = {
  'txt', 'md', 'markdown', 'json', 'csv', 'tsv', 'yaml', 'yml', 'html', 'htm', 'xml', 'log', 'ini', 'toml',
};

/// [parseProfileZip] sonucu.
class ProfileImportResult {
  const ProfileImportResult({required this.source, required this.skipped});

  final ProfileSource source;

  /// "dosya: neden" biçiminde atlananlar (kullanıcıya özetlenir).
  final List<String> skipped;
}

String _ext(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

String _safe(String path) => path
    .replaceAll('\\', '/')
    .split('/')
    .where((e) => e.isNotEmpty && e != '.' && e != '..')
    .join('/');

/// Kullanıcının kendisi hakkında yazdığı ZIP'i metin parçalarına çevirir. Saf Dart: Isolate'ta çalıştırılabilir.
///
/// Okunanlar: metin türleri (txt/md/json/csv/html…) ve docx. Diğerleri "atlandı" olarak raporlanır.
/// Hatalı/boş/çok büyük ZIP için [FormatException] (Türkçe ileti) fırlatır.
ProfileImportResult parseProfileZip(Uint8List bytes, String zipName, {DateTime? now}) {
  if (bytes.isEmpty) throw const FormatException('ZIP dosyası boş.');
  if (bytes.length > kProfileMaxZipBytes) {
    throw const FormatException('ZIP en fazla 20 MB olabilir.');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const FormatException('Bu dosya geçerli bir ZIP değil.');
  }
  final files = archive.files.where((f) => f.isFile).toList();
  if (files.length > kProfileMaxFiles) {
    throw FormatException('ZIP içinde en fazla $kProfileMaxFiles dosya olabilir (bulunan: ${files.length}).');
  }
  var declared = 0;
  for (final f in files) {
    declared += f.size;
  }
  if (declared > kProfileMaxTotalBytes) {
    throw const FormatException('ZIP açıldığında çok büyük (en fazla ~24 MB).');
  }

  final skipped = <String>[];
  final chunks = <ProfileChunk>[];
  var fileCount = 0;
  var chars = 0;
  final sorted = [...files]..sort((a, b) => a.name.compareTo(b.name));
  for (final f in sorted) {
    final path = _safe(f.name);
    if (path.isEmpty) continue;
    final base = path.split('/').last;
    if (path.startsWith('__MACOSX/') || base.startsWith('.')) continue;
    if (chars >= kProfileMaxChars) {
      skipped.add('$path: toplam metin sınırı doldu');
      continue;
    }
    final e = _ext(base);
    final isDocx = e == 'docx';
    if (!isDocx && !_textExt.contains(e)) {
      skipped.add('$path: desteklenmeyen tür');
      continue;
    }
    if (f.size > kProfileMaxFileBytes) {
      skipped.add('$path: dosya çok büyük (>2 MB)');
      continue;
    }
    String text;
    try {
      final data = f.content;
      final raw = data is Uint8List ? data : Uint8List.fromList(List<int>.from(data as List));
      text = isDocx ? _docxText(raw) : utf8.decode(raw, allowMalformed: true);
    } catch (_) {
      skipped.add('$path: okunamadı');
      continue;
    }
    if (e == 'html' || e == 'htm') text = _stripTags(text);
    text = text.replaceAll('\u0000', '').trim();
    if (text.isEmpty) {
      skipped.add('$path: boş');
      continue;
    }
    if (chars + text.length > kProfileMaxChars) {
      text = text.substring(0, kProfileMaxChars - chars);
    }
    chars += text.length;
    fileCount++;
    for (final c in chunkText(text)) {
      chunks.add(ProfileChunk(path, c));
    }
  }
  if (chunks.isEmpty) {
    throw const FormatException(
      'ZIP içinde okunabilir metin bulunamadı. .txt, .md, .json, .csv, .html veya .docx dosyaları ekle.',
    );
  }
  final t = now ?? DateTime.now();
  return ProfileImportResult(
    source: ProfileSource(
      id: 'src-${t.microsecondsSinceEpoch}',
      name: zipName,
      importedAt: t.millisecondsSinceEpoch,
      fileCount: fileCount,
      chunks: chunks,
    ),
    skipped: skipped,
  );
}

/// Metni paragraf sınırlarında ~[target] karakterlik parçalara böler (hiçbiri [max]'ı aşmaz).
List<String> chunkText(String text, {int target = kProfileChunkTarget, int max = kProfileChunkMax}) {
  final paras = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split(RegExp(r'\n\s*\n'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty);
  final out = <String>[];
  final cur = StringBuffer();
  void flush() {
    final s = cur.toString().trim();
    if (s.isNotEmpty) out.add(s);
    cur.clear();
  }

  for (final para in paras) {
    if (para.length > max) {
      flush();
      out.addAll(_splitLong(para, max));
      continue;
    }
    if (cur.isNotEmpty && cur.length + para.length + 2 > target) flush();
    if (cur.isNotEmpty) cur.write('\n\n');
    cur.write(para);
  }
  flush();
  return out;
}

/// Uzun paragrafı cümle/boşluk sınırından [max] karakteri aşmayacak şekilde böler.
List<String> _splitLong(String s, int max) {
  final out = <String>[];
  var rest = s;
  while (rest.length > max) {
    var cut = -1;
    for (final sep in const ['. ', '! ', '? ', '\n', '; ', ', ', ' ']) {
      final i = rest.lastIndexOf(sep, max - 1);
      if (i > max ~/ 3) {
        cut = i + sep.length;
        break;
      }
    }
    if (cut < 0) cut = max;
    out.add(rest.substring(0, cut).trim());
    rest = rest.substring(cut).trim();
  }
  if (rest.isNotEmpty) out.add(rest);
  return out.where((e) => e.isNotEmpty).toList();
}

final _tagRe = RegExp(r'<[^>]*>');
final _scriptRe = RegExp(r'<(script|style)[^>]*>.*?</\1>', dotAll: true, caseSensitive: false);

String _stripTags(String html) => _unescape(html.replaceAll(_scriptRe, ' ').replaceAll(_tagRe, ' '))
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n');

String _unescape(String s) => s
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

/// docx → düz metin (paragraflar satır sonu olur). Yalnızca `word/document.xml` okunur.
String _docxText(Uint8List bytes) {
  final a = ZipDecoder().decodeBytes(bytes);
  for (final f in a.files) {
    if (f.name == 'word/document.xml') {
      final data = f.content;
      final raw = data is Uint8List ? data : Uint8List.fromList(List<int>.from(data as List));
      final xml = utf8.decode(raw, allowMalformed: true);
      final withBreaks = xml
          .replaceAll(RegExp(r'</w:p>'), '\n\n')
          .replaceAll(RegExp(r'<w:tab/>'), ' ')
          .replaceAll(RegExp(r'<w:br[^>]*/>'), '\n');
      return _unescape(withBreaks.replaceAll(_tagRe, '')).trim();
    }
  }
  throw const FormatException('docx içinde metin yok');
}
