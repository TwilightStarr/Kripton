import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../domain/entities.dart';
import 'markdown.dart';
import 'ooxml.dart';
import 'project_snapshot.dart';
import 'project_zip.dart';

const _textExt = {
  'txt', 'md', 'dart', 'py', 'js', 'ts', 'tsx', 'jsx', 'java', 'kt', 'c', 'cc',
  'cpp', 'h', 'hpp', 'json', 'yaml', 'yml', 'xml', 'html', 'css', 'csv',
  'gradle', 'sh', 'sql', 'rs', 'go', 'swift', 'toml', 'ini', 'cmake', 'properties',
};

const _maxChars = 200000;

String _ext(String n) {
  final i = n.lastIndexOf('.');
  return i < 0 ? '' : n.substring(i + 1).toLowerCase();
}

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String _fromDocx(List<int> bytes) {
  final f = ZipDecoder().decodeBytes(bytes).findFile('word/document.xml');
  if (f == null) return '';
  final xml = utf8.decode(f.content as List<int>, allowMalformed: true);
  return _unescape(xml
      .replaceAll('</w:p>', '\n')
      .replaceAll('<w:tab/>', '\t')
      .replaceAll(RegExp(r'<[^>]+>'), ''));
}

String _pdfStr(String s) {
  final b = StringBuffer();
  final oct = RegExp(r'[0-7]');
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c != '\\' || i + 1 >= s.length) {
      b.write(c);
      continue;
    }
    final n = s[++i];
    if (n == 'n') {
      b.write('\n');
    } else if (n == 'r' || n == 't') {
      b.write(' ');
    } else if (oct.hasMatch(n)) {
      var o = n;
      while (o.length < 3 && i + 1 < s.length && oct.hasMatch(s[i + 1])) {
        o += s[++i];
      }
      b.writeCharCode(int.parse(o, radix: 8));
    } else {
      b.write(n);
    }
  }
  return b.toString();
}

final _pdfTok = RegExp(
  r'\[(?:\\.|[^\]\\])*\]\s*TJ|\((?:\\.|[^\\)])*\)\s*Tj|\bET\b',
);
final _pdfLit = RegExp(r'\(((?:\\.|[^\\)])*)\)|(-?\d+\.?\d*)');

String _fromPdf(List<int> bytes) {
  final raw = latin1.decode(bytes);
  final out = StringBuffer();
  var pos = 0;
  while (true) {
    final s = raw.indexOf('stream', pos);
    if (s < 0) break;
    var st = s + 6;
    if (raw.startsWith('\r\n', st)) {
      st += 2;
    } else if (raw.startsWith('\n', st)) {
      st += 1;
    }
    final e = raw.indexOf('endstream', st);
    if (e < 0) break;
    pos = e + 9;
    List<int> data = bytes.sublist(st, e);
    try {
      data = zlib.decode(data);
    } catch (_) {}
    final txt = latin1.decode(data, allowInvalid: true);
    if (!txt.contains('Tj') && !txt.contains('TJ')) continue;
    for (final m in _pdfTok.allMatches(txt)) {
      final t = m.group(0)!;
      if (t == 'ET') {
        out.write('\n');
      } else if (t.endsWith('TJ')) {
        for (final x in _pdfLit.allMatches(t)) {
          if (x.group(1) != null) {
            out.write(_pdfStr(x.group(1)!));
          } else {
            final v = double.tryParse(x.group(2)!);
            if (v != null && v < -250) out.write(' ');
          }
        }
      } else {
        out.write(_pdfStr(_pdfLit.firstMatch(t)!.group(1)!));
        out.write(' ');
      }
    }
  }
  return out.toString().replaceAll(RegExp(r'[ \t]+\n'), '\n').trim();
}

String _fromZip(List<int> bytes) {
  final b = StringBuffer();
  for (final f in ZipDecoder().decodeBytes(bytes).files) {
    if (!f.isFile) continue;
    final e = _ext(f.name);
    if (!_textExt.contains(e) && e != 'docx' && e != 'pdf') continue;
    final data = f.content as List<int>;
    final t = e == 'docx'
        ? _fromDocx(data)
        : (e == 'pdf' ? _fromPdf(data) : utf8.decode(data, allowMalformed: true));
    b
      ..writeln('=== ${f.name} ===')
      ..writeln(t)
      ..writeln();
    if (b.length > _maxChars) break;
  }
  return b.toString();
}

String _extract(String name, List<int> bytes) {
  final e = _ext(name);
  final String r;
  if (e == 'zip') {
    r = _fromZip(bytes);
  } else if (e == 'docx') {
    r = _fromDocx(bytes);
  } else if (e == 'pdf') {
    r = _fromPdf(bytes);
  } else {
    r = utf8.decode(bytes, allowMalformed: true);
  }
  return r.length > _maxChars ? r.substring(0, _maxChars) : r;
}

const _langExt = {
  'dart': 'dart', 'python': 'py', 'py': 'py', 'javascript': 'js', 'js': 'js',
  'typescript': 'ts', 'ts': 'ts', 'cpp': 'cpp', 'c++': 'cpp', 'c': 'c',
  'java': 'java', 'kotlin': 'kt', 'kt': 'kt', 'json': 'json', 'yaml': 'yml',
  'yml': 'yml', 'html': 'html', 'css': 'css', 'bash': 'sh', 'sh': 'sh',
  'xml': 'xml', 'markdown': 'md', 'md': 'md', 'cmake': 'cmake', 'rust': 'rs',
  'go': 'go', 'swift': 'swift', 'sql': 'sql',
};

final _fenceRe = RegExp(r'```([^\n`]*)\n(.*?)```', dotAll: true);
final _pathTokRe = RegExp(r'^[\w\-./]+\.\w{1,8}$');
final _pathLineRe = RegExp(
  r'^\W*(?:(?:dosya|file|yol|path)\s*:\s*)?\W*([\w\-./]+\.\w{1,8})\W*$',
  caseSensitive: false,
);
final _pathCommentRe = RegExp(r'^(?://|#|<!--|/\*)\s*(?:File|Dosya|Path)?\s*:?\s*([\w\-./]+\.\w{1,8})');

String _safePath(String path) {
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((e) => e.isNotEmpty && e != '.' && e != '..')
      .toList();
  return parts.join('/');
}

/// Kod bloğunun dosya yolunu bulur: bilgi satırı (```dart lib/a.dart), bloğun hemen üstündeki
/// "Dosya: yol" / "yol" satırı veya gövdenin ilk satırındaki yorum. Bulunamazsa null.
String? _fencePath(String c, RegExpMatch m, int last) {
  final info = m.group(1)!.trim();
  final body = m.group(2)!;
  final tokens = info.isEmpty ? <String>[] : info.split(RegExp(r'\s+'));
  final lang = tokens.isEmpty ? '' : tokens.first.toLowerCase();
  String? path;
  for (final t in tokens.skip(1)) {
    if (_pathTokRe.hasMatch(t)) path = t;
  }
  if (path == null && tokens.length == 1 && _pathTokRe.hasMatch(tokens.first) && !_langExt.containsKey(lang)) {
    path = tokens.first;
  }
  if (path == null) {
    final before = c.substring(last, m.start).trimRight().split('\n');
    if (before.isNotEmpty) {
      final pm = _pathLineRe.firstMatch(before.last.trim());
      if (pm != null) path = pm.group(1);
    }
  }
  if (path == null) {
    final first = body.split('\n').first.trim();
    final cm = _pathCommentRe.firstMatch(first);
    if (cm != null) path = cm.group(1);
  }
  return path;
}

/// Çıktıda dosya yolu belirlenebilen kod bloklarının (güvenli) yolları.
/// OutputValidator ZIP sözleşmesini, ZIP üreticisiyle AYNI kuralla denetlemek için kullanır.
List<String> namedFencePaths(String c) {
  final out = <String>[];
  var last = 0;
  for (final m in _fenceRe.allMatches(c)) {
    final path = _fencePath(c, m, last);
    last = m.end;
    if (path == null) continue;
    final safe = _safePath(path);
    if (safe.isNotEmpty) out.add(safe);
  }
  return out;
}

Map<String, String> _splitFiles(String c) {
  final out = <String, String>{};
  var n = 0;
  var last = 0;
  for (final m in _fenceRe.allMatches(c)) {
    final info = m.group(1)!.trim();
    final body = m.group(2)!;
    final tokens = info.isEmpty ? <String>[] : info.split(RegExp(r'\s+'));
    final lang = tokens.isEmpty ? '' : tokens.first.toLowerCase();
    final path = _fencePath(c, m, last);
    last = m.end;
    var name = path == null ? '' : _safePath(path);
    if (name.isEmpty) {
      name = 'dosya_${++n}.${_langExt[lang] ?? 'txt'}';
    }
    var unique = name;
    var k = 1;
    while (out.containsKey(unique)) {
      final dot = name.lastIndexOf('.');
      unique = dot > 0 ? '${name.substring(0, dot)}_${++k}${name.substring(dot)}' : '${name}_${++k}';
    }
    out[unique] = body;
  }
  // Kod bloğu yoksa her şey tek dosyaya düşer. Normal akışta OutputValidator bunu dosya üretilmeden
  // yakalar; bu yedek yalnızca kullanıcı "yine de indir" dediğinde devreye girer.
  if (out.isEmpty) out['cikti.txt'] = c;
  return out;
}

class _Built {
  final String ext;
  final Uint8List bytes;
  final String preview;
  final List<TreeEntry> tree;

  const _Built(this.ext, this.bytes, this.preview, [this.tree = const []]);
}

/// Çıktıdaki kod bloklarını yol → içerik olarak ayırır (ZIP üreticisiyle AYNI kural).
/// Kod bloğu yoksa tek `cikti.txt` döner.
Map<String, String> splitOutputFiles(String c) => _splitFiles(c);

_Built _buildZip(
  String content, {
  required String title,
  String task = '',
  ProjectSnapshot? base,
}) {
  final r = buildProjectZip(
    files: _splitFiles(content),
    rawContent: content,
    title: title,
    task: task,
    base: base,
  );
  return _Built('zip', r.bytes, r.preview, r.tree);
}

ByteData _bd(Uint8List u) => u.buffer.asByteData(u.offsetInBytes, u.lengthInBytes);

Future<_Built> _buildPdf(
  String title,
  String content,
  Uint8List sans,
  Uint8List sansBold,
  Uint8List mono,
) async {
  final base = pw.Font.ttf(_bd(sans));
  final bold = pw.Font.ttf(_bd(sansBold));
  final code = pw.Font.ttf(_bd(mono));
  final widgets = <pw.Widget>[
    pw.Text(title, style: pw.TextStyle(font: bold, fontSize: 24, color: PdfColor.fromHex('#0369A1'))),
    pw.SizedBox(height: 14),
  ];
  pw.Widget heading(String t, double size, double top) => pw.Padding(
        padding: pw.EdgeInsets.only(top: top, bottom: 6),
        child: pw.Text(t, style: pw.TextStyle(font: bold, fontSize: size)),
      );
  for (final b in parseMd(content)) {
    switch (b.kind) {
      case MdKind.h1:
        widgets.add(heading(b.text, 19, 12));
      case MdKind.h2:
        widgets.add(heading(b.text, 16, 10));
      case MdKind.h3:
        widgets.add(heading(b.text, 13, 8));
      case MdKind.bullet:
        widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(left: 12, bottom: 3),
          child: pw.Text('•  ${b.text}', style: const pw.TextStyle(fontSize: 11)),
        ));
      case MdKind.number:
        widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(left: 12, bottom: 3),
          child: pw.Text(b.text, style: const pw.TextStyle(fontSize: 11)),
        ));
      case MdKind.code:
        widgets.add(pw.Container(
          color: PdfColors.grey200,
          padding: const pw.EdgeInsets.symmetric(horizontal: 6),
          child: pw.Text(
            b.text.isEmpty ? ' ' : b.text,
            style: pw.TextStyle(font: code, fontSize: 8.5),
          ),
        ));
      case MdKind.para:
        widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.Text(b.text, style: const pw.TextStyle(fontSize: 11, lineSpacing: 2)),
        ));
    }
  }
  final doc = pw.Document(title: title, author: 'Kripton Yapay Zekâ Agent');
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(40),
    maxPages: 500,
    theme: pw.ThemeData.withFont(base: base, bold: bold),
    build: (_) => widgets,
    footer: (c) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text(
        '${c.pageNumber} / ${c.pagesCount}',
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
      ),
    ),
  ));
  final bytes = await doc.save();
  final preview = content.length > 4000 ? content.substring(0, 4000) : content;
  return _Built('pdf', bytes, preview);
}

String _slug(String s) {
  const from = 'çÇğĞıİöÖşŞüÜâÂîÎûÛ';
  const to = 'cCgGiIoOsSuUaAiIuU';
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  final out = b.toString().replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  final cut = out.length > 40 ? out.substring(0, 40) : out;
  return cut.isEmpty ? 'kripton' : cut;
}

class FileService {
  Future<(Uint8List, Uint8List, Uint8List)>? _fonts;

  Future<(Uint8List, Uint8List, Uint8List)> _loadFonts() => _fonts ??= () async {
        Future<Uint8List> load(String n) async =>
            (await rootBundle.load('assets/fonts/$n')).buffer.asUint8List();
        return (
          await load('DejaVuSans.ttf'),
          await load('DejaVuSans-Bold.ttf'),
          await load('DejaVuSansMono.ttf'),
        );
      }();

  Future<AttachedFile> readAttachment(String name, Uint8List bytes) async {
    final text = await Isolate.run(() => _extract(name, bytes));
    return AttachedFile(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      size: bytes.length,
      content: text,
    );
  }

  Future<Artifact> build({
    required OutputFormat format,
    required String title,
    required String content,
    required Directory dir,
    String task = '',
    ProjectSnapshot? base,
  }) async {
    final fonts = await _loadFonts();
    final built = await Isolate.run<_Built>(() async {
      switch (format) {
        case OutputFormat.zip:
          return _buildZip(content, title: title, task: task, base: base);
        case OutputFormat.pdf:
          return _buildPdf(title, content, fonts.$1, fonts.$2, fonts.$3);
        case OutputFormat.pptx:
          return _Built('pptx', buildPptx(title, content), content);
        case OutputFormat.docx:
          return _Built('docx', buildDocx(title, content), content);
        case OutputFormat.txt:
          return _Built('txt', Uint8List.fromList(utf8.encode(content)), content);
      }
    });
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final filename = '${_slug(title)}_$stamp.${built.ext}';
    final file = File(p.join(dir.path, filename));
    await file.writeAsBytes(built.bytes, flush: true);
    return Artifact(
      format: format,
      filename: filename,
      path: file.path,
      size: built.bytes.length,
      preview: built.preview,
      tree: built.tree,
    );
  }
}
