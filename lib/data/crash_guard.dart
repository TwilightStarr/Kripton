import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// documents/crash.log (en çok 200 KB), documents/last_op.json ve
/// documents/crash_state.json yönetimi.
/// Yapılandırılmadıysa (testler) tüm çağrılar sessizce no-op'tur.
class CrashGuard {
  static const maxLogBytes = 200 * 1024;
  static Directory? _dir;

  /// Art arda native/beklenmedik çökme sayısı (yükleme profilini küçültmek için).
  static int _streak = 0;

  /// Son işlenen Android ApplicationExitInfo kaydının zaman damgası (ms).
  static int _exitSeenMs = 0;

  static int get crashStreak => _streak;
  static int get exitSeenMs => _exitSeenMs;

  /// Açılışta çağrılır. Önceki oturumdan last_op.json kaldıysa bir işlem yarım kalmıştır.
  /// Bu tek başına çökme kanıtı değildir (kullanıcı/sistem süreci öldürmüş olabilir);
  /// kesin neden main.dart'ta ApplicationExitInfo ile belirlenir.
  static Future<Map<String, dynamic>?> init({Directory? dir}) async {
    _dir = dir ?? await getApplicationDocumentsDirectory();
    _loadState();
    final f = File('${_dir!.path}/last_op.json');
    try {
      if (!f.existsSync()) return null;
      final raw = jsonDecode(f.readAsStringSync());
      f.deleteSync();
      final op = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      log('Önceki oturumda yarım kalan işlem', jsonEncode(op), null);
      return op;
    } catch (_) {
      return null;
    }
  }

  static void _loadState() {
    try {
      final f = File('${_dir!.path}/crash_state.json');
      if (!f.existsSync()) return;
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _streak = (m['streak'] as num?)?.toInt() ?? 0;
      _exitSeenMs = (m['exitSeenMs'] as num?)?.toInt() ?? 0;
    } catch (_) {}
  }

  static void _saveState() {
    final d = _dir;
    if (d == null) return;
    try {
      File('${d.path}/crash_state.json').writeAsStringSync(
        jsonEncode({'streak': _streak, 'exitSeenMs': _exitSeenMs}),
        flush: true,
      );
    } catch (_) {}
  }

  /// Yarım kalan işlem sistem/native nedeniyle kesildiğinde çağrılır.
  static void recordCrash() {
    _streak++;
    _saveState();
  }

  /// Bir kullanıcı üretimi hatasız bittiğinde çağrılır; sayaç sıfırlanır.
  static void markOk() {
    if (_streak == 0) return;
    _streak = 0;
    _saveState();
  }

  static void setExitSeen(int ms) {
    _exitSeenMs = ms;
    _saveState();
  }

  static void log(String source, Object error, StackTrace? st) {
    final d = _dir;
    if (d == null) return;
    try {
      final entry = utf8.encode('[${DateTime.now().toIso8601String()}] $source: $error\n${st ?? ''}\n\n');
      final f = File('${d.path}/crash.log');
      final old = f.existsSync() ? f.readAsBytesSync() : const <int>[];
      final room = maxLogBytes - entry.length;
      final bytes = entry.length >= maxLogBytes
          ? entry.sublist(entry.length - maxLogBytes)
          : [...(old.length > room ? old.sublist(old.length - room) : old), ...entry];
      f.writeAsBytesSync(bytes, flush: true);
    } catch (_) {}
  }

  /// crash.log içeriği (UI'den kopyalamak için). Yoksa boş metin.
  static Future<String> readLog() async {
    final d = _dir;
    if (d == null) return '';
    try {
      final f = File('${d.path}/crash.log');
      return f.existsSync() ? await f.readAsString() : '';
    } catch (_) {
      return '';
    }
  }

  /// /proc/meminfo MemAvailable (MB). Okunamazsa null.
  static int? memAvailableMbSync() {
    try {
      final s = File('/proc/meminfo').readAsStringSync();
      final m = RegExp(r'^MemAvailable:\s+(\d+)\s*kB', multiLine: true).firstMatch(s);
      return m == null ? null : int.parse(m.group(1)!) ~/ 1024;
    } catch (_) {
      return null;
    }
  }

  /// Native çağrıdan ÖNCE senkron ve flush'lı yazılır; süreç ölürse iz kalır.
  static void beginOp(String op, {String? model, int? size, int? contextSize, Map<String, Object?>? extra}) {
    final d = _dir;
    if (d == null) return;
    try {
      File('${d.path}/last_op.json').writeAsStringSync(
        jsonEncode({
          'op': op,
          'model': model,
          'size': size,
          'contextSize': contextSize,
          'time': DateTime.now().toIso8601String(),
          ...?extra,
        }),
        flush: true,
      );
    } catch (_) {}
  }

  static void endOp() {
    final d = _dir;
    if (d == null) return;
    try {
      final f = File('${d.path}/last_op.json');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}
