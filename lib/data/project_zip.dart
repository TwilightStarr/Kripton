import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../domain/entities.dart';
import 'flutter_project_check.dart';
import 'project_snapshot.dart';

/// [buildProjectZip] sonucu.
class ProjectZipResult {
  const ProjectZipResult({
    required this.bytes,
    required this.tree,
    required this.preview,
    this.changes,
  });

  final Uint8List bytes;
  final List<TreeEntry> tree;
  final String preview;

  /// Taban proje verilmişse taban ile sonuç arasındaki değişiklikler.
  final ChangeSummary? changes;
}

/// `pubspec.yaml` içindeki `version: 1.2.3+4` değerinin yapı numarasını bir artırır.
/// Yapı numarası yoksa `+1` ekler; `version:` satırı yoksa metni değiştirmez.
String bumpPubspecBuild(String pubspec) {
  final re = RegExp(r'^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?[ \t\r]*$', multiLine: true);
  final m = re.firstMatch(pubspec);
  if (m == null) return pubspec;
  final next = (int.tryParse(m.group(2) ?? '') ?? 0) + 1;
  return pubspec.replaceRange(m.start, m.end, 'version: ${m.group(1)}+$next');
}

String _two(int v) => v.toString().padLeft(2, '0');

String _stamp(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

/// Modelin ürettiği [files] (yol → içerik) değerlerinden ZIP üretir.
///
/// * [base] YOKSA: Flutter projesi gibi görünüyorsa eksik iskelet (pubspec, .gitignore,
///   kurulum.sh, test, CI) ve bildirilmemiş bilinen paketler tamamlanır; `KRIPTON_RAPOR.md` eklenir.
/// * [base] VARSA: dosyalar tabanın üstüne bindirilir, TAM proje (ikili dosyalar dahil) yazılır;
///   pubspec sürüm numarası artırılır, `CHANGELOG.md` ve `KRIPTON_DEGISIKLIKLER.md` eklenir.
ProjectZipResult buildProjectZip({
  required Map<String, String> files,
  required String rawContent,
  required String title,
  String task = '',
  ProjectSnapshot? base,
  DateTime? now,
}) {
  final when = now ?? DateTime.now();
  final raw = rawContent;
  if (base == null) return _plain(files, raw, title, task, when);
  return _overBase(files, raw, title, task, base, when);
}

ProjectZipResult _plain(
  Map<String, String> files,
  String raw,
  String title,
  String task,
  DateTime when,
) {
  var out = <String, String>{...files};
  final extras = <String, String>{};
  if (FlutterProjectKit.looksLikeFlutter(out)) {
    final sc = FlutterProjectKit.scaffold(out, title: title);
    out = sc.files;
    final b = StringBuffer()
      ..writeln('# Kripton proje raporu')
      ..writeln()
      ..writeln('Oluşturulma: ${_stamp(when)}')
      ..writeln('Paket adı: ${sc.packageName}');
    if (task.trim().isNotEmpty) b.writeln('Görev: ${task.trim()}');
    b
      ..writeln()
      ..writeln('## Kripton tarafından eklenen eksik dosyalar');
    if (sc.addedFiles.isEmpty) b.writeln('- (yok)');
    for (final f in sc.addedFiles) {
      b.writeln('- $f');
    }
    b
      ..writeln()
      ..writeln('## pubspec.yaml\'a eklenen bağımlılıklar');
    if (sc.addedDependencies.isEmpty) b.writeln('- (yok)');
    for (final d in sc.addedDependencies) {
      b.writeln('- $d');
    }
    b
      ..writeln()
      ..writeln('## Sonraki adımlar')
      ..writeln('1. `./kurulum.sh` (Android platform dosyalarını üretir, paketleri indirir, analiz eder)')
      ..writeln('2. `flutter test` ve `flutter run`');
    extras['KRIPTON_RAPOR.md'] = b.toString();
  }
  final a = Archive();
  final tree = <TreeEntry>[];
  void add(String path, String body) {
    final d = utf8.encode(body);
    a.addFile(ArchiveFile(path, d.length, d));
    tree.add(TreeEntry(path, d.length));
  }

  out.forEach(add);
  extras.forEach(add);
  add('CIKTI.md', raw);
  final bytes = Uint8List.fromList(ZipEncoder().encode(a)!);
  return ProjectZipResult(
    bytes: bytes,
    tree: tree,
    preview: tree.map((t) => '${t.path}  (${t.size} B)').join('\n'),
  );
}

ProjectZipResult _overBase(
  Map<String, String> files,
  String raw,
  String title,
  String task,
  ProjectSnapshot base,
  DateTime when,
) {
  var merged = base.overlay(files);
  // Yeni import'lar için eksik bağımlılıkları ekle (yalnızca pubspec; iskelet dosyası eklenmez).
  final sc = FlutterProjectKit.scaffold(merged.text, title: title, addBoilerplate: false);
  if (sc.addedDependencies.isNotEmpty) {
    merged = merged.overlay({'pubspec.yaml': sc.files['pubspec.yaml']!});
  }
  // Model pubspec'e dokunmadıysa yapı numarasını artır: her üretim ayrı sürüm olur.
  final basePub = base.text['pubspec.yaml'];
  if (basePub != null && merged.text['pubspec.yaml'] == basePub) {
    merged = merged.overlay({'pubspec.yaml': bumpPubspecBuild(basePub)});
  } else if (basePub != null && merged.text['pubspec.yaml'] != null && !files.containsKey('pubspec.yaml')) {
    // Yalnızca bağımlılık eklendi: sürüm yine de artsın.
    merged = merged.overlay({'pubspec.yaml': bumpPubspecBuild(merged.text['pubspec.yaml']!)});
  }
  final summary = base.compareTo(merged);

  final entry = StringBuffer()
    ..writeln('## ${_stamp(when)}')
    ..writeln();
  if (task.trim().isNotEmpty) {
    entry
      ..writeln('Görev: ${task.trim().replaceAll('\n', ' ')}')
      ..writeln();
  }
  for (final p in summary.added) {
    entry.writeln('- yeni: $p');
  }
  for (final p in summary.modified) {
    entry.writeln('- değişen: $p');
  }
  final oldLog = base.text['CHANGELOG.md'];
  final log = oldLog == null || oldLog.trim().isEmpty
      ? '# Değişiklik günlüğü\n\n$entry'
      : () {
          final nl = oldLog.indexOf('\n');
          final head = nl < 0 ? oldLog : oldLog.substring(0, nl);
          final rest = nl < 0 ? '' : oldLog.substring(nl + 1);
          return '$head\n\n$entry\n${rest.trimLeft()}';
        }();
  merged = merged.overlay({'CHANGELOG.md': log});

  final report = summary.markdown(title: 'Kripton değişiklik özeti', task: task);
  final extras = <String, String>{
    'KRIPTON_DEGISIKLIKLER.md': report,
    'KRIPTON_CIKTI.md': raw,
  };
  final folder = base.name.isEmpty ? null : base.name;
  final bytes = merged.toZipBytes(topFolder: folder, extra: extras);

  final tree = <TreeEntry>[];
  final changed = <String>{...summary.added, ...summary.modified, 'CHANGELOG.md'};
  for (final p in changed.toList()..sort()) {
    final body = merged.text[p];
    if (body != null) tree.add(TreeEntry(p, utf8.encode(body).length));
  }
  tree
    ..add(TreeEntry('KRIPTON_DEGISIKLIKLER.md', utf8.encode(report).length))
    ..add(TreeEntry('KRIPTON_CIKTI.md', utf8.encode(raw).length));
  final unchanged = merged.fileCount - changed.length;
  if (unchanged > 0) tree.add(TreeEntry('(+$unchanged değişmeyen dosya)', 0));
  return ProjectZipResult(
    bytes: bytes,
    tree: tree,
    preview: report,
    changes: summary,
  );
}
