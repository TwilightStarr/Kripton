import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Metin olarak okunan dosya uzantıları (diğerleri ikili sayılır ve olduğu gibi taşınır).
const kProjectTextExt = <String>{
  'dart', 'yaml', 'yml', 'md', 'txt', 'json', 'xml', 'gradle', 'kts', 'properties',
  'sh', 'pro', 'html', 'css', 'js', 'ts', 'kt', 'java', 'swift', 'plist', 'cmake',
  'toml', 'ini', 'csv', 'gitignore', 'metadata', 'lock',
};

const _skipDirs = <String>{'.git', '.dart_tool', 'build', '.idea', '.gradle', 'node_modules'};

/// Tek bir dosya için üst sınırlar (bellek ve bağlam koruması).
const kMaxTextFileBytes = 400 * 1024;
const kMaxBinaryFileBytes = 4 * 1024 * 1024;
const kMaxProjectFiles = 2500;

String _normPath(String raw) {
  final parts = raw
      .replaceAll('\\', '/')
      .split('/')
      .where((e) => e.isNotEmpty && e != '.' && e != '..')
      .toList();
  return parts.join('/');
}

String _extOf(String path) {
  final name = path.split('/').last;
  final i = name.lastIndexOf('.');
  if (i < 0) return name.startsWith('.') ? name.substring(1).toLowerCase() : '';
  return name.substring(i + 1).toLowerCase();
}

const _foldFrom = 'İIıÇçĞğÖöŞşÜüÂâÎîÛû';
const _foldTo = 'iiiccggoossuuaaiiuu';

String _fold(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    final i = _foldFrom.indexOf(ch);
    b.write(i >= 0 ? _foldTo[i] : ch.toLowerCase());
  }
  return b.toString();
}

final _wordSplit = RegExp(r'[^\p{L}\p{N}_]+', unicode: true);

/// Görevden arama kökleri (en az 4 harf, ilk 5 harf kök).
List<String> _stems(String task) {
  final out = <String>{};
  for (final raw in task.split(_wordSplit)) {
    final f = _fold(raw);
    if (f.length < 4) continue;
    out.add(f.substring(0, f.length < 5 ? f.length : 5));
  }
  return out.toList();
}

/// Bir proje dizininin bellekteki hâli: metin dosyaları + ikili dosyalar.
///
/// Kripton'un "kendini geliştirme" döngüsünün temelidir: kaynak ZIP'i okunur, görev için özet
/// çıkarılır, modelin ürettiği dosyalar üstüne bindirilir ve tam proje ZIP olarak yazılır.
class ProjectSnapshot {
  ProjectSnapshot({
    required this.name,
    Map<String, String>? text,
    Map<String, List<int>>? binary,
  })  : text = text ?? <String, String>{},
        binary = binary ?? <String, List<int>>{};

  final String name;
  final Map<String, String> text;
  final Map<String, List<int>> binary;

  int get fileCount => text.length + binary.length;

  bool get isEmpty => fileCount == 0;

  List<String> get paths => [...text.keys, ...binary.keys]..sort();

  bool has(String path) => text.containsKey(path) || binary.containsKey(path);

  /// ZIP baytlarından okur. Tek üst klasör (ör. `Kripton-main/`) otomatik soyulur;
  /// `..` içeren yollar, `.git/` ve `build/` gibi klasörler atlanır.
  factory ProjectSnapshot.fromZipBytes(List<int> bytes, {String? name}) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entries = <String, ArchiveFile>{};
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final p = _normPath(f.name);
      if (p.isEmpty) continue;
      final segs = p.split('/');
      if (segs.any(_skipDirs.contains)) continue;
      entries[p] = f;
      if (entries.length > kMaxProjectFiles) {
        throw FormatException('Projede $kMaxProjectFiles dosyadan fazlası var.');
      }
    }
    var prefix = '';
    if (entries.isNotEmpty) {
      final firsts = entries.keys.map((e) => e.split('/').first).toSet();
      final allNested = entries.keys.every((e) => e.contains('/'));
      if (firsts.length == 1 && allNested) prefix = '${firsts.first}/';
    }
    final snap = ProjectSnapshot(
      name: name ?? (prefix.isEmpty ? 'proje' : prefix.substring(0, prefix.length - 1)),
    );
    entries.forEach((path, f) {
      final rel = prefix.isEmpty ? path : path.substring(prefix.length);
      if (rel.isEmpty) return;
      final data = f.content as List<int>;
      if (kProjectTextExt.contains(_extOf(rel))) {
        if (data.length > kMaxTextFileBytes) {
          snap.binary[rel] = data;
        } else {
          snap.text[rel] = utf8.decode(data, allowMalformed: true);
        }
      } else if (data.length <= kMaxBinaryFileBytes) {
        snap.binary[rel] = data;
      }
    });
    return snap;
  }

  /// Dosyaları üstüne bindirilmiş YENİ bir anlık görüntü döner (bu nesne değişmez).
  ProjectSnapshot overlay(Map<String, String> changed) {
    final next = ProjectSnapshot(
      name: name,
      text: {...text},
      binary: {...binary},
    );
    changed.forEach((path, body) {
      final p = _normPath(path);
      if (p.isEmpty) return;
      next.binary.remove(p);
      next.text[p] = body;
    });
    return next;
  }

  /// Tam proje ZIP'i. [topFolder] doluysa tüm dosyalar o klasörün altına konur.
  Uint8List toZipBytes({String? topFolder, Map<String, String> extra = const {}}) {
    final a = Archive();
    final prefix = (topFolder == null || topFolder.isEmpty) ? '' : '$topFolder/';
    final all = <String, List<int>>{
      for (final e in binary.entries) e.key: e.value,
      for (final e in text.entries) e.key: utf8.encode(e.value),
      for (final e in extra.entries) e.key: utf8.encode(e.value),
    };
    final keys = all.keys.toList()..sort();
    for (final k in keys) {
      final d = all[k]!;
      a.addFile(ArchiveFile('$prefix$k', d.length, d));
    }
    return Uint8List.fromList(ZipEncoder().encode(a)!);
  }

  /// `pubspec.yaml` içindeki paket adı (yoksa null).
  String? get pubspecName {
    final m = RegExp(r'^name:\s*([A-Za-z0-9_]+)', multiLine: true)
        .firstMatch(text['pubspec.yaml'] ?? '');
    return m?.group(1);
  }

  /// Girintili dosya ağacı özeti (yalnızca yol ve satır sayısı).
  String treeSummary({int maxLines = 70}) {
    final lines = <String>[];
    for (final p in paths) {
      final t = text[p];
      lines.add(t == null ? '$p (ikili)' : '$p (${_lineCount(t)} satır)');
    }
    if (lines.length <= maxLines) return lines.join('\n');
    final shown = lines.take(maxLines).join('\n');
    return '$shown\n… (+${lines.length - maxLines} dosya daha)';
  }

  /// Göreve göre sıralanmış ilgili dosyalar (en ilgili ilk). Yalnızca metin dosyaları.
  List<String> relevantFiles(String task, {int limit = 6}) {
    final stems = _stems(task);
    final scored = <MapEntry<String, int>>[];
    text.forEach((path, body) {
      final isCode = path.startsWith('lib/') || path.startsWith('test/');
      var score = isCode ? 1 : 0;
      final fp = _fold(path);
      final fb = _fold(body);
      for (final s in stems) {
        if (fp.contains(s)) score += 6;
        final hits = _countUpTo(fb, s, 6);
        score += hits;
      }
      if (path == 'pubspec.yaml') score += 1;
      if (score > 0) scored.add(MapEntry(path, score));
    });
    scored.sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    return scored.take(limit).map((e) => e.key).toList();
  }

  /// Modele verilecek proje özeti: ağaç + en ilgili dosyaların (kırpılmış) içeriği + diğer
  /// dosyaların imzaları. EN ÖNEMLİ bilgi başta: runner ekleri sondan keser.
  String digest(String task, {int maxChars = 6000}) {
    final b = StringBuffer()
      ..writeln('# MEVCUT PROJE: $name ($fileCount dosya)')
      ..writeln('Aşağıdaki dosya yolları GERÇEKTİR; yeni dosya eklerken bu yapıya uy.')
      ..writeln()
      ..writeln('## Dosya ağacı')
      ..writeln(treeSummary(maxLines: 45))
      ..writeln();
    final relevant = relevantFiles(task, limit: 4);
    var used = b.length;
    final fullBudget = ((maxChars - used) * 0.6).floor();
    var fullUsed = 0;
    if (relevant.isNotEmpty && fullBudget > 400) {
      b.writeln('## Göreve en ilgili dosyalar');
      for (final p in relevant) {
        final body = text[p]!;
        final room = fullBudget - fullUsed;
        if (room < 300) break;
        final cut = body.length > room ? '${body.substring(0, room)}\n… (kırpıldı)' : body;
        b
          ..writeln('Dosya: $p')
          ..writeln('```')
          ..writeln(cut)
          ..writeln('```');
        fullUsed += cut.length;
      }
      b.writeln();
    }
    used = b.length;
    final sig = StringBuffer();
    final shown = relevant.toSet();
    for (final p in text.keys.toList()..sort()) {
      if (!p.endsWith('.dart') || shown.contains(p)) continue;
      final s = signatures(text[p]!);
      if (s.isEmpty) continue;
      sig.writeln('- $p: ${s.join('; ')}');
      if (used + sig.length > maxChars) break;
    }
    if (sig.isNotEmpty) {
      b
        ..writeln('## Diğer Dart dosyalarının imzaları')
        ..write(sig);
    }
    final out = b.toString();
    return out.length > maxChars ? out.substring(0, maxChars) : out;
  }

  /// Üst düzey sınıf / enum / mixin / extension / fonksiyon adları (kısa imzalar).
  static List<String> signatures(String dart, {int limit = 8}) {
    final out = <String>[];
    final re = RegExp(
      r'^(?:abstract\s+|final\s+|base\s+|sealed\s+|interface\s+)*(class|enum|mixin|extension)\s+([A-Za-z_][A-Za-z0-9_]*)',
      multiLine: true,
    );
    for (final m in re.allMatches(dart)) {
      out.add('${m.group(1)} ${m.group(2)}');
      if (out.length >= limit) return out;
    }
    final fn = RegExp(
      r'^(?:Future<[^>]*>|Future|void|String|int|bool|double|List<[^>]*>|Map<[^>]*>|Widget)\s+([a-z_][A-Za-z0-9_]*)\s*\(',
      multiLine: true,
    );
    for (final m in fn.allMatches(dart)) {
      out.add('fn ${m.group(1)}');
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Bu anlık görüntüden [next]'e değişiklik özeti.
  ChangeSummary compareTo(ProjectSnapshot next) {
    final added = <String>[];
    final modified = <String>[];
    var delta = 0;
    next.text.forEach((path, body) {
      final old = text[path];
      if (old == null) {
        added.add(path);
        delta += _lineCount(body);
      } else if (old != body) {
        modified.add(path);
        delta += _lineCount(body) - _lineCount(old);
      }
    });
    added.sort();
    modified.sort();
    return ChangeSummary(added: added, modified: modified, lineDelta: delta);
  }

  static int _lineCount(String s) => s.isEmpty ? 0 : '\n'.allMatches(s).length + 1;

  static int _countUpTo(String hay, String needle, int cap) {
    var n = 0;
    var i = 0;
    while (n < cap) {
      i = hay.indexOf(needle, i);
      if (i < 0) break;
      n++;
      i += needle.length;
    }
    return n;
  }
}

/// İki sürüm arasındaki dosya değişiklikleri.
class ChangeSummary {
  const ChangeSummary({
    required this.added,
    required this.modified,
    required this.lineDelta,
  });

  final List<String> added;
  final List<String> modified;
  final int lineDelta;

  bool get isEmpty => added.isEmpty && modified.isEmpty;

  int get total => added.length + modified.length;

  String markdown({String? title, String? task}) {
    final b = StringBuffer()..writeln('# ${title ?? 'Değişiklik özeti'}');
    if (task != null && task.trim().isNotEmpty) {
      b
        ..writeln()
        ..writeln('**Görev:** ${task.trim()}');
    }
    b
      ..writeln()
      ..writeln('Toplam: ${added.length} yeni, ${modified.length} değişen dosya; '
          'satır farkı ${lineDelta >= 0 ? '+' : ''}$lineDelta.');
    if (added.isNotEmpty) {
      b
        ..writeln()
        ..writeln('## Yeni dosyalar');
      for (final p in added) {
        b.writeln('- $p');
      }
    }
    if (modified.isNotEmpty) {
      b
        ..writeln()
        ..writeln('## Değişen dosyalar');
      for (final p in modified) {
        b.writeln('- $p');
      }
    }
    return b.toString();
  }
}
