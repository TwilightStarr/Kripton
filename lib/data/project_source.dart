import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import 'project_snapshot.dart';

/// Geliştirilecek projenin kaynağı: uygulamaya gömülü Kripton kaynağı veya kullanıcının seçtiği ZIP.
class ProjectSource {
  const ProjectSource._();

  /// [Workflow.baseProject] değeri: Kripton'un kendi kaynağı.
  static const selfRef = 'asset:self';

  /// Kaynak paketi (tool/pack_self_source.sh üretir; CI her derlemede yeniler).
  static const selfAsset = 'assets/self/kripton_source.zip';

  /// Bir ZIP'in yoluna (veya `asset:self`'e) göre anlık görüntüyü okur. Ayrıştırma Isolate'ta yapılır.
  /// Kaynak yoksa/okunamazsa [StateError] fırlatır (Türkçe, kullanıcıya gösterilebilir).
  static Future<ProjectSnapshot> load(String ref) async {
    final name = ref == selfRef ? 'Kripton' : null;
    Uint8List bytes;
    try {
      if (ref == selfRef) {
        final d = await rootBundle.load(selfAsset);
        bytes = d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
      } else {
        bytes = await File(ref).readAsBytes();
      }
    } catch (_) {
      throw StateError(
        ref == selfRef
            ? 'Kripton kaynak paketi bulunamadı ($selfAsset). `./tool/pack_self_source.sh` '
                  'çalıştırıp uygulamayı yeniden derleyin veya "Proje ZIP\'i seç" ile kaynağı verin.'
            : 'Proje dosyası okunamadı: $ref',
      );
    }
    if (bytes.isEmpty) {
      throw StateError(
        'Proje paketi boş: ${ref == selfRef ? selfAsset : p.basename(ref)}. '
        '`./tool/pack_self_source.sh` ile kaynak paketini üretin.',
      );
    }
    try {
      return await Isolate.run(() => ProjectSnapshot.fromZipBytes(bytes, name: name));
    } catch (e) {
      throw StateError('Proje ZIP\'i açılamadı: $e');
    }
  }

  /// Seçilen ZIP'i uygulama deposuna kopyalar (önbellek temizlenince kaybolmasın); yeni yolu döner.
  static Future<String> copyInto(Directory dir, String sourcePath) async {
    if (!await dir.exists()) await dir.create(recursive: true);
    final dest = p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}_${p.basename(sourcePath)}');
    await File(sourcePath).copy(dest);
    return dest;
  }
}
