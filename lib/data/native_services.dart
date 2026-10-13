import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';

/// Android ApplicationExitInfo kaydı (MainActivity.kt'den gelir; Android 11 öncesi yoktur).
class ExitInfo {
  const ExitInfo({
    required this.reason,
    required this.reasonName,
    required this.timestamp,
    this.description,
    this.trace,
    this.importance,
    this.pssKb,
    this.rssKb,
    this.status,
  });

  final int reason;
  final String reasonName;
  final int timestamp;
  final String? description;

  /// Yalnızca CRASH_NATIVE gibi durumlarda; süzülmüş tombstone satırları.
  final String? trace;
  final int? importance;
  final int? pssKb;
  final int? rssKb;
  final int? status;

  factory ExitInfo.fromMap(Map<dynamic, dynamic> m) => ExitInfo(
        reason: (m['reason'] as num?)?.toInt() ?? -1,
        reasonName: (m['reasonName'] as String?) ?? 'UNKNOWN',
        timestamp: (m['timestamp'] as num?)?.toInt() ?? 0,
        description: m['description'] as String?,
        trace: m['trace'] as String?,
        importance: (m['importance'] as num?)?.toInt(),
        pssKb: (m['pssKb'] as num?)?.toInt(),
        rssKb: (m['rssKb'] as num?)?.toInt(),
        status: (m['status'] as num?)?.toInt(),
      );
}

class ProcessExitInfo {
  static const _ch = MethodChannel('kripton/exit_info');

  /// sinceMs'ten yeni son çıkış kaydı; yoksa, desteklenmiyorsa veya hata olursa null.
  static Future<ExitInfo?> lastSince(int sinceMs) async {
    try {
      final m = await _ch.invokeMapMethod<dynamic, dynamic>('lastExit', {
        'sinceMs': sinceMs,
      });
      if (m == null) return null;
      return ExitInfo.fromMap(m);
    } catch (_) {
      return null;
    }
  }
}

/// Memory stats used to choose a model profile and stop generation before Android's LMK.
class MemSnapshot {
  const MemSnapshot({
    required this.totalBytes,
    required this.availableBytes,
    required this.pressureAvailableBytes,
    required this.thresholdBytes,
    required this.lowMemory,
    required this.appPssBytes,
    required this.reclaimableCacheBytes,
  });

  final int? totalBytes;
  final int? availableBytes;
  final int? pressureAvailableBytes;
  final int? thresholdBytes;
  final bool lowMemory;
  final int? appPssBytes;
  final int? reclaimableCacheBytes;

  bool get underPressure =>
      lowMemory ||
      (pressureAvailableBytes != null &&
          thresholdBytes != null &&
          pressureAvailableBytes! < thresholdBytes! * 1.3);
}

/// Android memory channels, with /proc/meminfo fallback for missing/older native channels.
class MemInfoNative {
  static const _channel = MethodChannel('kripton/meminfo');
  static const _trimChannel = EventChannel('kripton/memory_pressure');
  static final StreamController<String> _notifications =
      StreamController<String>.broadcast();

  static Stream<int> get trimEvents => _trimChannel
      .receiveBroadcastStream()
      .where((event) => event is num)
      .map((event) => (event as num).toInt());

  static Stream<String> get notifications => _notifications.stream;

  static void notify(String message) {
    if (!_notifications.isClosed) _notifications.add(message);
  }

  static Future<MemSnapshot> current() async {
    Map<dynamic, dynamic>? native;
    try {
      native = await _channel.invokeMapMethod<dynamic, dynamic>(
        'getMemoryInfo',
      );
    } catch (_) {
      native = null;
    }

    Map<String, int> proc = const {};
    try {
      proc = _parseProcMeminfo(await File('/proc/meminfo').readAsString());
    } catch (_) {}

    final nativeTotal = (native?['totalMem'] as num?)?.toInt();
    final nativeAvailable = (native?['availMem'] as num?)?.toInt();
    final procAvailable = proc['MemAvailable'];
    final total = nativeTotal ?? proc['MemTotal'];
    final pressureAvailable = nativeAvailable ?? procAvailable;
    final cached = proc['Cached'];
    final shmem = proc['Shmem'] ?? 0;
    final reclaimable = cached == null
        ? null
        : math.max(0, cached - shmem + (proc['SReclaimable'] ?? 0)).toInt();
    final available = (procAvailable ?? nativeAvailable);
    final adjusted =
        available == null ? null : available + ((reclaimable ?? 0) ~/ 2);
    final threshold = (native?['threshold'] as num?)?.toInt() ??
        (total == null ? null : (total * 0.05).round());

    return MemSnapshot(
      totalBytes: total,
      availableBytes: adjusted,
      pressureAvailableBytes: pressureAvailable,
      thresholdBytes: threshold,
      lowMemory: native?['lowMemory'] == true,
      appPssBytes: (native?['appPssBytes'] as num?)?.toInt(),
      reclaimableCacheBytes: reclaimable,
    );
  }

  static Map<String, int> _parseProcMeminfo(String input) {
    final result = <String, int>{};
    for (final match in RegExp(
      r'^([A-Za-z_()]+):\s+(\d+)\s*kB',
      multiLine: true,
    ).allMatches(input)) {
      result[match.group(1)!] = int.parse(match.group(2)!) * 1024;
    }
    return result;
  }
}

/// Üretim/yükleme sırasında ön plan servisi (dataSync) çalıştırır; referans sayımlıdır.
/// Hata olursa sessizce yutulur: servis yoksa üretim yine de dener.
class NativeKeepAlive {
  static const _ch = MethodChannel('kripton/keepalive');
  static int _refs = 0;

  static Future<void> acquire() async {
    if (_refs++ == 0) await _call('start');
  }

  static Future<void> release() async {
    if (_refs == 0) return;
    if (--_refs == 0) await _call('stop');
  }

  static Future<void> _call(String method) async {
    try {
      await _ch.invokeMethod<void>(method);
    } catch (_) {}
  }
}
