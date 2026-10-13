import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'crash_guard.dart';

/// Küçük JSON dosyaları için atomik yazma ve bozulmaya dayanıklı okuma.
///
/// Yazma: `yol.tmp` dosyasına yazılıp flush edilir; mevcut GEÇERLİ dosya `yol.bak` olarak
/// saklanır; sonra `yol.tmp` -> `yol` yeniden adlandırılır. Süreç herhangi bir noktada ölse bile
/// ya eski ya yeni sürüm okunabilir kalır.
///
/// Okuma: ana dosya bozuk/yarım ise `yol.corrupt` olarak kenara alınır (inceleme için), sırayla
/// `yol.tmp` ve `yol.bak` denenir; geçerli olan ana dosyaya geri yüklenir. Hiçbir durumda
/// istisna fırlatmaz (bulunamazsa null).
///
/// Aynı yola yapılan okuma/yazma işlemleri sıraya dizilir (eşzamanlı yazmada tmp dosyası bozulmaz).
class AtomicFile {
  AtomicFile._();

  static final Map<String, Future<void>> _chains = <String, Future<void>>{};

  static Future<T> _serial<T>(String path, Future<T> Function() job) {
    final prev = _chains[path] ?? Future<void>.value();
    final result = Completer<T>();
    final next = prev.then((_) async {
      try {
        result.complete(await job());
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    _chains[path] = next;
    next.whenComplete(() {
      if (identical(_chains[path], next)) _chains.remove(path);
    });
    return result.future;
  }

  /// Şu an sırada bekleyen/çalışan yol sayısı (sızıntı testi için).
  static int get pendingPaths => _chains.length;

  /// [data]'yı JSON olarak atomik yazar. Yazılamazsa istisna fırlatır (çağıran yakalar);
  /// başarısız yazmada ana dosya ve yedek dokunulmadan kalır.
  static Future<void> writeJson(String path, Object? data) {
    final text = jsonEncode(data); // kodlanamayan veri kuyruğa girmeden hata verir
    return _serial<void>(path, () => _write(path, text));
  }

  static Future<void> _write(String path, String text) async {
    final main = File(path);
    final tmp = File('$path.tmp');
    final bak = File('$path.bak');
    await tmp.parent.create(recursive: true);
    try {
      await tmp.writeAsString(text, flush: true);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    if (await main.exists()) {
      final current = await _tryParse(main);
      try {
        if (current.ok) {
          if (await bak.exists()) await bak.delete();
          await main.rename(bak.path); // son SAĞLAM sürüm yedeklenir
        } else {
          await _quarantine(main); // bozuk dosya, sağlam yedeğin üstüne yazılmaz
        }
      } catch (_) {}
    }
    try {
      await tmp.rename(path);
    } catch (_) {
      // rename başarısızsa (nadir) kopyalayarak tamamla.
      await tmp.copy(path);
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }

  /// Dosyayı okur. Bozuk/yok ise yedeklerden kurtarır; bulunamazsa null döner.
  static Future<Object?> readJson(String path) => _serial<Object?>(path, () async {
        try {
          return await _read(path);
        } catch (e, st) {
          CrashGuard.log('Depolama okuma', e, st);
          return null;
        }
      });

  static Future<Object?> _read(String path) async {
    final main = File(path);
    final first = await _tryParse(main);
    if (first.ok) return first.value;
    if (first.existed) {
      await _quarantine(main);
      CrashGuard.log('Depolama', 'Bozuk dosya kenara alındı: $path.corrupt', null);
    }
    for (final candidate in <File>[File('$path.tmp'), File('$path.bak')]) {
      final r = await _tryParse(candidate);
      if (!r.ok) continue;
      try {
        await candidate.copy(path); // ana dosyayı geri yükle
        if (candidate.path.endsWith('.tmp')) await candidate.delete();
      } catch (_) {}
      CrashGuard.log('Depolama', 'Yedekten kurtarıldı: ${candidate.path}', null);
      return r.value;
    }
    return null;
  }

  /// Ana dosya, tmp ve yedeği siler (bozuk-kopya `.corrupt` incelemek için kalır).
  static Future<void> delete(String path) => _serial<void>(path, () async {
        for (final f in <String>[path, '$path.tmp', '$path.bak']) {
          try {
            final file = File(f);
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      });

  /// [path] dosyasının bir kopyasını `yol.<etiket>` adıyla saklar (en iyi çaba).
  static Future<void> backupCopy(String path, String label) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.copy('$path.$label');
    } catch (_) {}
  }

  static Future<({bool ok, bool existed, Object? value})> _tryParse(File f) async {
    try {
      if (!await f.exists()) return (ok: false, existed: false, value: null);
      final text = await f.readAsString();
      return (ok: true, existed: true, value: jsonDecode(text));
    } catch (_) {
      return (ok: false, existed: true, value: null);
    }
  }

  static Future<void> _quarantine(File f) async {
    try {
      final target = File('${f.path}.corrupt');
      if (await target.exists()) await target.delete();
      await f.rename(target.path);
    } catch (_) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }
}
