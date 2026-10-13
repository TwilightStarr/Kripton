import 'dart:io';

/// Boş depolama alanı. Repoda native (Kotlin) kod yok; Android'de `df` (toybox) kullanılır.
/// Okunamazsa null döner ve çağıran kontrolü atlar (indirmeyi engellemez).
class DiskSpace {
  static Future<int?> freeBytes(String path) async {
    try {
      final r = await Process.run('df', ['-Pk', path]).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return null;
      return parseDfAvailableBytes('${r.stdout}');
    } catch (_) {
      return null;
    }
  }

  /// `df -Pk` çıktısı: Filesystem 1024-blocks Used Available Capacity Mounted-on. Available (KiB) -> bayt.
  static int? parseDfAvailableBytes(String output) {
    final matches = RegExp(
      r'^.+?\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+\S.*$',
      multiLine: true,
    ).allMatches(output).toList();
    if (matches.isEmpty) return null;
    return int.parse(matches.last.group(3)!) * 1024;
  }
}
