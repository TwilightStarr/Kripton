// lib/application/telemetry_service.dart
import 'dart:async';
import '../domain/telemetry_entities.dart';

class TelemetryService {
  final StreamController<TelemetryFrame> _controller =
      StreamController<TelemetryFrame>.broadcast();
  final StreamController<LiveLogEntry> _logController =
      StreamController<LiveLogEntry>.broadcast();

  Stream<TelemetryFrame> get telemetryStream => _controller.stream;
  Stream<LiveLogEntry> get logStream => _logController.stream;

  Timer? _throttleTimer;
  TelemetryFrame? _pendingFrame;

  static const int _maxRecentLogs = 200;
  final List<LiveLogEntry> _recent = [];

  /// Son günlük kayıtları (en yeni sonda); karelere eklenir.
  List<LiveLogEntry> get recentLogs => List.unmodifiable(_recent);

  /// Yayınlanan son kare; panel akış sürerken açılırsa boş görünmesin diye saklanır.
  TelemetryFrame? lastFrame;
  ThermalStatus _currentThermalStatus = ThermalStatus.normal;

  int get currentThrottleMs =>
      _currentThermalStatus == ThermalStatus.critical ? 500 : 100;

  void onThermalStatusChanged(ThermalStatus status) {
    _currentThermalStatus = status;
    addLog(
      status == ThermalStatus.critical ? LogLevel.warn : LogLevel.info,
      'ThermalGovernor',
      'Termal durum: ${status.name}. Telemetri aralığı: ${currentThrottleMs}ms olarak ayarlandı.',
    );
  }

  void emitThrottled(TelemetryFrame frame) {
    _pendingFrame = frame;
    if (_throttleTimer?.isActive ?? false) return;

    _throttleTimer = Timer(Duration(milliseconds: currentThrottleMs), () {
      final f = _pendingFrame;
      _pendingFrame = null;
      if (f != null && !_controller.isClosed) {
        lastFrame = f;
        _controller.add(f);
      }
    });
  }

  void emitImmediate(TelemetryFrame frame) {
    _throttleTimer?.cancel();
    _pendingFrame = null;
    lastFrame = frame;
    if (!_controller.isClosed) {
      _controller.add(frame);
    }
  }

  void addLog(LogLevel level, String component, String message) {
    final entry = LiveLogEntry(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      level: level,
      component: component,
      message: message,
    );
    _recent.add(entry);
    if (_recent.length > _maxRecentLogs) {
      _recent.removeRange(0, _recent.length - _maxRecentLogs);
    }
    if (!_logController.isClosed) {
      _logController.add(entry);
    }
  }

  /// Yeni akış öncesi eski günlükleri ve kareyi temizler.
  void reset() {
    _throttleTimer?.cancel();
    _pendingFrame = null;
    lastFrame = null;
    _recent.clear();
  }

  void dispose() {
    _throttleTimer?.cancel();
    _pendingFrame = null;
    _controller.close();
    _logController.close();
  }
}
