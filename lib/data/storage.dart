import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/entities.dart';

class Storage {
  Directory? _root;

  Future<Directory> _base() async => _root ??= await getApplicationDocumentsDirectory();

  Future<Directory> _sub(String name) async {
    final d = Directory(p.join((await _base()).path, name));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Directory> modelsDir() => _sub('models');

  Future<Directory> outputsDir() => _sub('outputs');

  /// Kullanıcının geliştirmek için seçtiği proje ZIP'lerinin kalıcı kopyaları.
  Future<Directory> projectsDir() => _sub('projects');

  Future<void> _write(String name, Object data) async {
    final f = File(p.join((await _base()).path, name));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(data), flush: true);
    await tmp.rename(f.path);
  }

  Future<Object?> _read(String name) async {
    try {
      final f = File(p.join((await _base()).path, name));
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<List<Workflow>?> loadWorkflows() async {
    final raw = await _read('workflows.json');
    if (raw is! List) return null;
    try {
      return raw
          .map((e) => Workflow.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> saveWorkflows(List<Workflow> list) =>
      _write('workflows.json', list.map((e) => e.toJson()).toList());

  /// Görünüm / performans tercihleri (tema, sade mod). Okunamazsa boş harita.
  Future<Map<String, dynamic>> loadSettings() async {
    final raw = await _read('settings.json');
    return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  }

  Future<void> saveSettings(Map<String, dynamic> data) =>
      _write('settings.json', data);

  Future<Map<String, Map<String, String>>> loadRegistry() async {
    final raw = await _read('model_registry.json');
    final out = <String, Map<String, String>>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is Map) {
          out[k as String] = v.map((a, b) => MapEntry(a as String, b as String));
        }
      });
    }
    return out;
  }

  Future<void> saveRegistry(Map<String, Map<String, String>> reg) =>
      _write('model_registry.json', reg);
}
