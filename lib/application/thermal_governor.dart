import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// tok/s düşüşüne (ve varsa PowerManager termal durumuna) göre thread sayısını kademeli ayarlar.
/// Saf mantık: zaman [now] ile verilir, test edilebilir.
class ThermalGovernor {
  ThermalGovernor({
    this.ladder = const [8, 6, 4],
    this.baselineWindow = const Duration(seconds: 30),
    this.dropRatio = 0.70,
    this.recoverRatio = 0.90,
    this.recoverHold = const Duration(seconds: 90), // geri yükselme yavaş
    this.cooldown = const Duration(seconds: 15), // iki adım arası bekleme
  });

  final List<int> ladder;
  final Duration baselineWindow;
  final double dropRatio;
  final double recoverRatio;
  final Duration recoverHold;
  final Duration cooldown;

  int _level = 0;
  double? _baseline; // ilk 30 sn ortalaması
  double _sumTps = 0;
  int _n = 0;
  DateTime? _start;
  DateTime? _lastChange;
  DateTime? _goodSince;
  int osThermalStatus = 0; // 0..6 (THERMAL_STATUS_NONE..SHUTDOWN)

  int get threads => ladder[_level];
  double? get baseline => _baseline;

  void reset() {
    _level = 0;
    _baseline = null;
    _sumTps = 0;
    _n = 0;
    _start = null;
    _lastChange = null;
    _goodSince = null;
  }

  /// Her ölçüm penceresinde (ör. 2-3 sn) çağır. Thread sayısı değiştiyse yenisini döner.
  int? onSample(double tps, DateTime now) {
    if (tps <= 0) return null;
    _start ??= now;
    if (_baseline == null) {
      _sumTps += tps;
      _n++;
      if (now.difference(_start!) >= baselineWindow && _n >= 3) _baseline = _sumTps / _n;
      return null;
    }
    final b = _baseline!;
    final hot = osThermalStatus >= 2; // MODERATE ve üstü
    final cooled = _lastChange == null || now.difference(_lastChange!) >= cooldown;
    if ((tps < b * dropRatio || osThermalStatus >= 3) && cooled && _level < ladder.length - 1) {
      _level++;
      _lastChange = now;
      _goodSince = null;
      // Yeni thread sayısıyla taban tok/s doğal olarak düşer: tabanı orantılı ölçekle.
      _baseline = b * ladder[_level] / ladder[_level - 1];
      return threads;
    }
    if (_level > 0 && !hot && tps >= b * recoverRatio) {
      _goodSince ??= now;
      if (now.difference(_goodSince!) >= recoverHold && cooled) {
        final prev = ladder[_level];
        _level--;
        _lastChange = now;
        _goodSince = null;
        _baseline = b * ladder[_level] / prev;
        return threads;
      }
    } else {
      _goodSince = null;
    }
    return null;
  }
}

/// Opsiyonel Android köprüsü. Native taraf (MainActivity) `kripton/thermal` kanalında
/// `getThermalStatus` -> int (PowerManager.getCurrentThermalStatus) ve `isCharging` -> bool sunarsa kullanılır;
/// yoksa MissingPluginException yakalanır ve yalnızca tok/s ölçümüne dayanılır.
class DeviceThermal {
  static const _ch = MethodChannel('kripton/thermal');
  static bool _missing = false;

  static Future<int?> status() async {
    if (_missing || !Platform.isAndroid) return null;
    try {
      return await _ch.invokeMethod<int>('getThermalStatus');
    } on MissingPluginException {
      _missing = true;
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool?> charging() async {
    if (_missing || !Platform.isAndroid) return null;
    try {
      return await _ch.invokeMethod<bool>('isCharging');
    } on MissingPluginException {
      _missing = true;
      return null;
    } catch (_) {
      return null;
    }
  }
}
