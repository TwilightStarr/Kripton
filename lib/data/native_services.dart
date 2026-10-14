import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:android_intent_plus/android_intent.dart';
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

/// Ön plan servisinden gelen olay türleri (KriptonKeepAliveService -> MainActivity -> Dart).
enum KeepAliveEventKind {
  /// Servis ön plana alındı.
  started,

  /// Servis ön plana alınamadı (ör. uygulama arka plandayken başlatma yasağı, bildirim izni yok).
  startFailed,

  /// Sistem servisin süresini doldurdu (Android 15+ `Service.onTimeout`). Servis kendini kapatır; oturum
  /// duraklatılmalı, kontrol noktası yazılmalı ve kullanıcı bilgilendirilmelidir.
  timeout,
}

class KeepAliveEvent {
  const KeepAliveEvent(this.kind, {this.fgsType, this.at});

  final KeepAliveEventKind kind;

  /// `timeout` için sistemin bildirdiği ön plan servisi türü (bilinmiyorsa null / -1).
  final int? fgsType;

  /// Olayın zamanı (milisaniye; native saat).
  final DateTime? at;

  /// Native haritasından; tanınmayan tür için null.
  static KeepAliveEvent? fromMap(Map<dynamic, dynamic> m) {
    final KeepAliveEventKind? kind;
    switch (m['kind']) {
      case 'started':
        kind = KeepAliveEventKind.started;
      case 'startFailed':
        kind = KeepAliveEventKind.startFailed;
      case 'timeout':
        kind = KeepAliveEventKind.timeout;
      default:
        kind = null;
    }
    if (kind == null) return null;
    final at = (m['at'] as num?)?.toInt();
    final type = (m['fgsType'] as num?)?.toInt();
    return KeepAliveEvent(
      kind,
      fgsType: type == null || type < 0 ? null : type,
      at: at == null || at <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
    );
  }
}

/// Üretim/yükleme/geliştirme oturumu boyunca ön plan servisini çalıştırır; referans sayımlıdır.
/// Android 14+ ve bu uygulamada servis türü `specialUse` (zaman aşımı yok); 29-33'te `dataSync`.
/// Sistem yine de servisi sonlandırırsa [events] `timeout` yayar. Hata olursa sessizce yutulur:
/// servis yoksa üretim yine de dener.
class NativeKeepAlive {
  static const _ch = MethodChannel('kripton/keepalive');
  static const _evCh = EventChannel('kripton/keepalive_events');
  static int _refs = 0;
  static bool _failed = false;
  static Stream<KeepAliveEvent>? _events;

  /// Son başlatma denemesi başarısız mı (servis ön planda değil).
  static bool get startFailed => _failed;

  /// Şu an servise tutunan işlem sayısı (test/teşhis).
  static int get references => _refs;

  /// Servis olayları (yayın akışı). Kanal yoksa (test/eski derleme) boş akıştır; hata yutulur.
  static Stream<KeepAliveEvent> get events => _events ??= _evCh
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => KeepAliveEvent.fromMap(e as Map<dynamic, dynamic>))
      .where((e) => e != null)
      .map((e) => e!)
      .handleError((Object _) {});

  static Future<void> acquire() async {
    if (_refs++ == 0) await _start();
  }

  static Future<void> release() async {
    if (_refs == 0) return;
    if (--_refs == 0) {
      _failed = false;
      await _call<bool>('stop');
    }
  }

  /// Zaman aşımından sonra (kullanıcı uygulamayı öne getirip "Devam" dediğinde) servisi yeniden başlatır.
  /// Hiçbir işlem tutunmuyorsa bir şey yapmaz. Başarılıysa true.
  static Future<bool> restart() async {
    if (_refs == 0) return false;
    return _start();
  }

  /// [sinceMs]'den (epoch ms) yeni bir zaman aşımı kaydı varsa döner. Uygulama süreci zaman aşımı sırasında
  /// ölü/arka planda olsa bile native taraf kaydı SharedPreferences'ta tutar.
  static Future<KeepAliveEvent?> lastTimeoutSince(int sinceMs) async {
    try {
      final m = await _ch.invokeMapMethod<dynamic, dynamic>('lastTimeout');
      if (m == null) return null;
      final e = KeepAliveEvent.fromMap({...m, 'kind': 'timeout'});
      if (e == null) return null;
      final at = e.at?.millisecondsSinceEpoch ?? 0;
      return at > sinceMs ? e : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _start() async {
    final ok = await _call<bool>('start');
    // Kanal yoksa (null) engel sayma: üretim yine de dener.
    _failed = ok == false;
    return ok ?? true;
  }

  static Future<T?> _call<T>(String method) async {
    try {
      return await _ch.invokeMethod<T>(method);
    } catch (_) {
      return null;
    }
  }
}

/// Pil optimizasyonu muafiyeti durumu.
enum BatteryExemptState { granted, denied, unknown }

/// "Pil optimizasyonundan muaf tut" akışı (yeni paket yok: `android_intent_plus` + keepalive kanalı).
/// Reddedilirse oturum çalışır ama arayüz net uyarı gösterir. Xiaomi/HyperOS ek ayarları için
/// `miui_hint.dart` (maybeShowMiuiHint) kullanılır.
class BatteryOptimization {
  static const _ch = MethodChannel('kripton/keepalive');
  static const String packageName = 'com.kripton.ai';

  /// Muaf mı? Kanal yoksa/hata olursa [BatteryExemptState.unknown].
  static Future<BatteryExemptState> status() async {
    if (!Platform.isAndroid) return BatteryExemptState.unknown;
    try {
      final v = await _ch.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      if (v == null) return BatteryExemptState.unknown;
      return v ? BatteryExemptState.granted : BatteryExemptState.denied;
    } catch (_) {
      return BatteryExemptState.unknown;
    }
  }

  /// Sistem muafiyet isteği penceresini açar; olmazsa pil optimizasyonu ayar listesini. Açılabildiyse true.
  /// (Sonuç anında bilinmez; kullanıcı dönünce [status] yeniden okunur.)
  static Future<bool> request() async {
    if (!Platform.isAndroid) return false;
    try {
      await const AndroidIntent(
        action: 'android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
        data: 'package:$packageName',
      ).launch();
      return true;
    } catch (_) {
      try {
        await const AndroidIntent(action: 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS').launch();
        return true;
      } catch (_) {
        return false;
      }
    }
  }
}
