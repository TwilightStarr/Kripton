import 'project_snapshot.dart';

/// Bilinen paketler için güvenli sürüm kısıtları (modelin import ettiği ama pubspec'e yazmadığı
/// paketler otomatik eklenir). `any`: sürümü SDK ile birlikte pub çözsün.
const kKnownPackages = <String, String>{
  'flutter_riverpod': '^2.5.1',
  'riverpod': '^2.5.1',
  'provider': '^6.1.2',
  'http': '^1.2.2',
  'dio': '^5.7.0',
  'path': '^1.9.0',
  'path_provider': '^2.1.4',
  'shared_preferences': '^2.3.2',
  'sqflite': '^2.3.3',
  'intl': 'any',
  'collection': 'any',
  'meta': 'any',
  'archive': '^3.6.1',
  'crypto': '^3.0.3',
  'url_launcher': '^6.3.0',
  'file_picker': '^8.1.2',
  'open_filex': '^4.5.0',
  'uuid': '^4.5.1',
  'equatable': '^2.0.5',
  'cupertino_icons': '^1.0.8',
  'google_fonts': '^6.2.1',
  'flutter_bloc': '^8.1.6',
  'bloc': '^8.1.4',
  'get_it': '^8.0.0',
  'go_router': '^14.2.0',
  'hive_flutter': '^1.1.0',
  'cached_network_image': '^3.4.1',
  'image_picker': '^1.1.2',
  'permission_handler': '^11.3.1',
  'wakelock_plus': '^1.2.8',
  'fl_chart': '^0.69.0',
  'flutter_animate': '^4.5.0',
  'pdf': '^3.11.1',
};

/// SDK ile gelen, pubspec'te `sdk: flutter` olarak bildirilen paketler.
const _flutterSdkPackages = <String>{'flutter', 'flutter_test', 'flutter_localizations'};

/// Proje denetiminde bulunan bir sorun.
class ProjectProblem {
  const ProjectProblem(this.path, this.message);

  final String path;
  final String message;

  @override
  String toString() => path.isEmpty ? message : '$path: $message';
}

/// Dart kaynağında parantez/köşeli/süslü parantez ve metin dengesi denetimi.
/// Yorumlar, tek/üç tırnaklı ve ham (r'') metinler ile `${...}` ara değerlemesi tanınır.
/// Sorun yoksa null, varsa kısa Türkçe açıklama döner.
String? dartBalanceProblem(String source) {
  final s = _Scan(source)..code();
  return s.problem;
}

class _Scan {
  _Scan(this.s);

  final String s;
  int i = 0;
  int line = 1;
  String? problem;

  static const _open = '([{';
  static const _close = ')]}';

  static final _identRe = RegExp(r'[A-Za-z0-9_]');

  bool _isIdent(String c) => _identRe.hasMatch(c);

  void code({bool interp = false}) {
    final stack = <String>[];
    final lines = <int>[];
    while (i < s.length && problem == null) {
      final c = s[i];
      if (c == '\n') {
        line++;
        i++;
        continue;
      }
      if (c == '/' && i + 1 < s.length) {
        final n = s[i + 1];
        if (n == '/') {
          while (i < s.length && s[i] != '\n') {
            i++;
          }
          continue;
        }
        if (n == '*') {
          final startLine = line;
          i += 2;
          var closed = false;
          while (i < s.length) {
            if (s[i] == '*' && i + 1 < s.length && s[i + 1] == '/') {
              i += 2;
              closed = true;
              break;
            }
            if (s[i] == '\n') line++;
            i++;
          }
          if (!closed) problem = 'Kapanmamış /* yorum (satır $startLine).';
          continue;
        }
      }
      if (c == "'" || c == '"') {
        final raw = i > 0 && s[i - 1] == 'r' && (i < 2 || !_isIdent(s[i - 2]));
        _string(c, raw);
        continue;
      }
      final oi = _open.indexOf(c);
      if (oi >= 0) {
        stack.add(c);
        lines.add(line);
        i++;
        continue;
      }
      final ci = _close.indexOf(c);
      if (ci >= 0) {
        if (stack.isEmpty) {
          if (interp && c == '}') {
            i++;
            return;
          }
          problem = 'Fazladan "$c" (satır $line).';
          return;
        }
        if (stack.last != _open[ci]) {
          problem = '"${stack.last}" (satır ${lines.last}) ile "$c" (satır $line) eşleşmiyor.';
          return;
        }
        stack.removeLast();
        lines.removeLast();
        i++;
        continue;
      }
      i++;
    }
    if (problem != null) return;
    if (interp) {
      problem = r'Kapanmamış ${...} ifadesi.';
      return;
    }
    if (stack.isNotEmpty) {
      problem = 'Kapanmamış "${stack.last}" (satır ${lines.last}).';
    }
  }

  void _string(String q, bool raw) {
    final startLine = line;
    final triple = s.startsWith(q * 3, i);
    i += triple ? 3 : 1;
    while (i < s.length && problem == null) {
      final c = s[i];
      if (triple) {
        if (s.startsWith(q * 3, i)) {
          i += 3;
          return;
        }
      } else {
        if (c == q) {
          i++;
          return;
        }
        if (c == '\n') {
          problem = 'Kapanmamış metin (satır $startLine). Metin içindeki tırnaklar kaçırılmalı.';
          return;
        }
      }
      if (c == '\n') line++;
      if (!raw && c == r'\') {
        if (i + 1 < s.length && s[i + 1] == '\n') line++;
        i += 2;
        continue;
      }
      if (!raw && c == r'$') {
        if (i + 1 < s.length && s[i + 1] == '{') {
          i += 2;
          code(interp: true);
          continue;
        }
        i++;
        while (i < s.length && _isIdent(s[i])) {
          i++;
        }
        continue;
      }
      i++;
    }
    problem ??= 'Kapanmamış metin (satır $startLine).';
  }
}

final _importRe = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

final _placeholderRe = RegExp(
  r'^\s*(?://|#)?\s*(?:\.\.\.|…|geri kalan[ıi]?\b.*|diğer .* aynı|rest of (?:the )?(?:code|file).*|remaining code.*|kodun geri kalanı.*)\s*$',
  caseSensitive: false,
  multiLine: true,
);

/// Flutter proje denetimi ve iskelet tamamlama.
class FlutterProjectKit {
  const FlutterProjectKit._();

  /// Dosya kümesi bir Flutter projesi gibi görünüyor mu?
  static bool looksLikeFlutter(Map<String, String> files) {
    final pub = files['pubspec.yaml'];
    if (pub != null && RegExp(r'^\s*flutter\s*:', multiLine: true).hasMatch(pub)) return true;
    for (final e in files.entries) {
      if (e.key.endsWith('.dart') && e.value.contains('package:flutter/')) return true;
    }
    return false;
  }

  /// Üretilen [generated] dosyaları (varsa [base] üstüne bindirilerek) denetler.
  /// Yalnızca derleme/çalışmayı bozan SORUNLARI döner.
  static List<ProjectProblem> check(
    Map<String, String> generated, {
    ProjectSnapshot? base,
  }) {
    final merged = <String, String>{...?base?.text, ...generated};
    final present = <String>{...merged.keys, ...?base?.binary.keys};
    if (!looksLikeFlutter(merged)) return const [];
    final problems = <ProjectProblem>[];
    final pubName = _pubName(merged['pubspec.yaml']);
    final declared = _declaredDeps(merged['pubspec.yaml']);

    // Yalnızca modelin yazdığı dosyalar denetlenir (mevcut taban kod zaten çalışıyordu).
    for (final e in generated.entries) {
      final path = e.key;
      final body = e.value;
      if (!path.endsWith('.dart')) continue;
      final bal = dartBalanceProblem(body);
      if (bal != null) problems.add(ProjectProblem(path, bal));
      if (_placeholderRe.hasMatch(body)) {
        problems.add(
          ProjectProblem(path, 'Kısaltılmış içerik ("..." veya "geri kalanı aynı"); dosya TAM yazılmalı.'),
        );
      }
      for (final m in _importRe.allMatches(body)) {
        final uri = m.group(1)!;
        final miss = _unresolved(uri, path, pubName, present, declared);
        if (miss != null) problems.add(ProjectProblem(path, miss));
      }
    }
    if (base == null) {
      final main = merged['lib/main.dart'];
      if (main == null) {
        problems.add(const ProjectProblem('lib/main.dart', 'Giriş dosyası yok.'));
      } else if (!RegExp(r'\bmain\s*\(').hasMatch(main)) {
        problems.add(const ProjectProblem('lib/main.dart', 'main() fonksiyonu yok.'));
      }
    }
    return problems;
  }

  static String? _unresolved(
    String uri,
    String from,
    String? pubName,
    Set<String> present,
    Set<String> declared,
  ) {
    if (uri.startsWith('dart:')) return null;
    if (uri.startsWith('package:')) {
      final rest = uri.substring('package:'.length);
      final slash = rest.indexOf('/');
      if (slash < 0) return null;
      final pkg = rest.substring(0, slash);
      final inner = rest.substring(slash + 1);
      final unknownOwn = pubName == null &&
          !_flutterSdkPackages.contains(pkg) &&
          !declared.contains(pkg) &&
          !kKnownPackages.containsKey(pkg);
      if (pkg == pubName || unknownOwn) {
        return present.contains('lib/$inner')
            ? null
            : 'Import edilen "lib/$inner" dosyası projede yok ($uri).';
      }
      // Üçüncü taraf paket: bildirilmemişse iskelet adımı ekler; bilinmiyorsa uyarı yeterli değil, sorun.
      if (_flutterSdkPackages.contains(pkg) || declared.contains(pkg)) return null;
      if (kKnownPackages.containsKey(pkg)) return null;
      return 'Bilinmeyen paket "$pkg" import edilmiş ve pubspec.yaml içinde bildirilmemiş.';
    }
    // Göreli yol.
    final dir = from.contains('/') ? from.substring(0, from.lastIndexOf('/')) : '';
    final target = _resolve(dir, uri);
    return present.contains(target) ? null : 'Import edilen "$uri" dosyası projede yok ($target).';
  }

  static String _resolve(String dir, String rel) {
    final parts = <String>[...dir.split('/').where((e) => e.isNotEmpty)];
    for (final seg in rel.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }

  /// pubspec yokken, `package:X/...` import'larından projenin kendi paket adını çıkarır:
  /// bilinen/SDK paketi olmayan ve `lib/...` altında karşılığı bulunan ilk ad.
  static String? _inferOwnPackage(Map<String, String> files) {
    for (final e in files.entries) {
      if (!e.key.endsWith('.dart')) continue;
      for (final m in _importRe.allMatches(e.value)) {
        final uri = m.group(1)!;
        if (!uri.startsWith('package:')) continue;
        final rest = uri.substring(8);
        final slash = rest.indexOf('/');
        if (slash < 0) continue;
        final pkg = rest.substring(0, slash);
        if (_flutterSdkPackages.contains(pkg) || kKnownPackages.containsKey(pkg)) continue;
        if (files.containsKey('lib/${rest.substring(slash + 1)}')) return pkg;
      }
    }
    return null;
  }

  static String? _pubName(String? pubspec) {
    if (pubspec == null) return null;
    return RegExp(r'^name:\s*([A-Za-z0-9_]+)', multiLine: true).firstMatch(pubspec)?.group(1);
  }

  /// `dependencies:` ve `dev_dependencies:` altında bildirilen paket adları.
  static Set<String> _declaredDeps(String? pubspec) {
    final out = <String>{};
    if (pubspec == null) return out;
    var inBlock = false;
    for (final line in pubspec.split('\n')) {
      if (RegExp(r'^(dependencies|dev_dependencies|dependency_overrides)\s*:').hasMatch(line)) {
        inBlock = true;
        continue;
      }
      if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('\t') && !line.startsWith('#')) {
        inBlock = false;
        continue;
      }
      if (!inBlock) continue;
      final m = RegExp(r'^  ([A-Za-z0-9_]+)\s*:').firstMatch(line);
      if (m != null) out.add(m.group(1)!);
    }
    return out;
  }

  /// Geçerli bir Dart paket adı üretir (küçük harf, rakam, alt çizgi; harfle başlar).
  static String packageName(String title) {
    const from = 'çÇğĞıİöÖşŞüÜâÂîÎûÛ';
    const to = 'ccggiioossuuaaiiuu';
    final b = StringBuffer();
    for (final r in title.runes) {
      final ch = String.fromCharCode(r);
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch.toLowerCase());
    }
    var out = b.toString().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    if (out.isEmpty) out = 'kripton_app';
    if (RegExp(r'^[0-9]').hasMatch(out)) out = 'app_$out';
    const reserved = {'test', 'flutter', 'dart', 'class', 'new', 'null', 'true', 'false', 'void'};
    if (reserved.contains(out)) out = '${out}_app';
    return out.length > 40 ? out.substring(0, 40) : out;
  }

  /// Eksik iskelet dosyalarını ve pubspec bağımlılıklarını tamamlar.
  /// [files] değiştirilmez; sonuç [ScaffoldResult.files] içindedir.
  static ScaffoldResult scaffold(
    Map<String, String> files, {
    required String title,
    bool addBoilerplate = true,
  }) {
    final out = <String, String>{...files};
    final added = <String>[];
    final deps = <String>[];
    final name = _pubName(out['pubspec.yaml']) ?? _inferOwnPackage(out) ?? packageName(title);

    if (addBoilerplate && !out.containsKey('pubspec.yaml')) {
      out['pubspec.yaml'] = _pubspecTemplate(name, title);
      added.add('pubspec.yaml');
    }
    // Import edilen ama bildirilmemiş paketleri ekle.
    final declared = _declaredDeps(out['pubspec.yaml']);
    final needed = <String>{};
    for (final e in out.entries) {
      if (!e.key.endsWith('.dart')) continue;
      for (final m in _importRe.allMatches(e.value)) {
        final uri = m.group(1)!;
        if (!uri.startsWith('package:')) continue;
        final rest = uri.substring(8);
        final slash = rest.indexOf('/');
        if (slash < 0) continue;
        final pkg = rest.substring(0, slash);
        if (pkg == name || _flutterSdkPackages.contains(pkg) || declared.contains(pkg)) continue;
        if (kKnownPackages.containsKey(pkg)) needed.add(pkg);
      }
    }
    if (needed.isNotEmpty && out.containsKey('pubspec.yaml')) {
      var pub = out['pubspec.yaml']!;
      for (final pkg in needed.toList()..sort()) {
        pub = _addDependency(pub, pkg, kKnownPackages[pkg]!);
        deps.add(pkg);
      }
      out['pubspec.yaml'] = pub;
    }
    void addIfMissing(String path, String body) {
      if (!addBoilerplate || out.containsKey(path)) return;
      out[path] = body;
      added.add(path);
    }

    addIfMissing('.gitignore', _gitignore);
    addIfMissing('README.md', '# $title\n\nKripton tarafından üretilen Flutter projesi.\n\n'
        '```\n./kurulum.sh\nflutter run\n```\n');
    addIfMissing('kurulum.sh', _kurulum(name));
    addIfMissing('test/widget_test.dart', _widgetTest);
    addIfMissing('.github/workflows/build-apk.yml', _workflow);
    return ScaffoldResult(files: out, addedFiles: added, addedDependencies: deps, packageName: name);
  }

  static String _addDependency(String pubspec, String pkg, String version) {
    final lines = pubspec.split('\n');
    final idx = lines.indexWhere((l) => RegExp(r'^dependencies\s*:').hasMatch(l));
    final entry = '  $pkg: $version';
    if (idx < 0) {
      return '${pubspec.trimRight()}\n\ndependencies:\n  flutter:\n    sdk: flutter\n$entry\n';
    }
    var end = idx + 1;
    while (end < lines.length) {
      final l = lines[end];
      if (l.isNotEmpty && !l.startsWith(' ') && !l.startsWith('\t') && !l.startsWith('#')) break;
      end++;
    }
    // Bloğun sonundaki boş satırların önüne ekle.
    var at = end;
    while (at > idx + 1 && lines[at - 1].trim().isEmpty) {
      at--;
    }
    lines.insert(at, entry);
    return lines.join('\n');
  }

  static String _pubspecTemplate(String name, String title) => '''
name: $name
description: ${title.replaceAll(RegExp(r'[\r\n:#]'), ' ').trim()}
publish_to: none
version: 1.0.0+1

environment:
  sdk: ">=3.5.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter

flutter:
  uses-material-design: true
''';

  static const _gitignore = '''
.dart_tool/
.packages
build/
.flutter-plugins
.flutter-plugins-dependencies
*.iml
.idea/
local.properties
.gradle/
''';

  static const _widgetTest = '''
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('proje iskeleti', () {
    expect(1 + 1, 2);
  });
}
''';

  static String _kurulum(String name) => '''
#!/usr/bin/env bash
set -e
flutter create --project-name $name --org com.kripton --platforms android .
flutter pub get
flutter analyze
''';

  static const _workflow = '''
name: Build APK

on:
  push:
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - run: bash kurulum.sh
      - run: flutter test
      - run: flutter build apk --release
      - uses: actions/upload-artifact@v4
        with:
          name: apk
          path: build/app/outputs/flutter-apk/app-release.apk
''';
}

/// [FlutterProjectKit.scaffold] sonucu.
class ScaffoldResult {
  const ScaffoldResult({
    required this.files,
    required this.addedFiles,
    required this.addedDependencies,
    required this.packageName,
  });

  final Map<String, String> files;
  final List<String> addedFiles;
  final List<String> addedDependencies;
  final String packageName;

  bool get changedAnything => addedFiles.isNotEmpty || addedDependencies.isNotEmpty;
}
