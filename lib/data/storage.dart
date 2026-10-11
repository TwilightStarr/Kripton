import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/entities.dart';
import 'atomic_file.dart';
import 'crash_guard.dart';

class Storage {
  /// [root] verilirse (testler) uygulama belgeler klasörü yerine o klasör kullanılır.
  Storage({Directory? root}) : _root = root;

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

  Future<String> _path(String name) async => p.join((await _base()).path, name);

  /// Atomik yazma: tmp dosya + rename; önceki sağlam sürüm `.bak` olarak kalır.
  Future<void> _write(String name, Object data) async =>
      AtomicFile.writeJson(await _path(name), data);

  /// Okuma bozulmaya dayanıklıdır: bozuk dosya `.corrupt` olarak kenara alınır, yedekten kurtarılır.
  /// Hiçbir koşulda istisna fırlatmaz; okunamazsa null döner.
  Future<Object?> _read(String name) async {
    try {
      return await AtomicFile.readJson(await _path(name));
    } catch (e, st) {
      CrashGuard.log('Depolama okuma ($name)', e, st);
      return null;
    }
  }

  /// Genel amaçlı küçük JSON dosyaları (ör. otonom mod kontrol noktası).
  Future<Object?> loadJson(String name) => _read(name);

  Future<void> saveJson(String name, Object data) => _write(name, data);

  Future<void> deleteJson(String name) async {
    try {
      await AtomicFile.delete(await _path(name));
    } catch (_) {}
  }

  /// Akışları okur. Tek tek ayrıştırılır: bozuk bir kayıt diğerlerini kaybettirmez.
  /// Hiçbiri ayrıştırılamazsa (veya dosya yoksa) null; ayrıştırılamayan veri `.unparsable` kopyasına alınır.
  Future<List<Workflow>?> loadWorkflows() async {
    final raw = await _read('workflows.json');
    if (raw is! List) return null;
    final out = <Workflow>[];
    var bad = 0;
    for (final e in raw) {
      try {
        out.add(Workflow.fromJson(Map<String, dynamic>.from(e as Map)));
      } catch (_) {
        bad++;
      }
    }
    if (bad > 0) {
      CrashGuard.log('Depolama', 'workflows.json: $bad kayıt ayrıştırılamadı', null);
      await AtomicFile.backupCopy(await _path('workflows.json'), 'unparsable');
    }
    return out.isEmpty ? null : out;
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
          out['$k'] = {
            for (final e in v.entries)
              if (e.value != null) '${e.key}': '${e.value}',
          };
        }
      });
    }
    return out;
  }

  Future<void> saveRegistry(Map<String, Map<String, String>> reg) =>
      _write('model_registry.json', reg);
}
