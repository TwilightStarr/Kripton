import 'dart:async';

import '../data/native_services.dart';
import '../data/default_data.dart' show modelCatalog;
import '../domain/entities.dart';
import '../domain/telemetry_entities.dart';
import 'thermal_governor.dart' show DeviceThermal;
import 'telemetry_service.dart';

/// Mevcut `RunCallbacks` olaylarını (ajan durumu, token, günlük) [TelemetryService] karelerine çevirir.
/// WorkflowRunner'a dokunmaz; AppController callback'lerinden beslenir.
class TelemetryBridge {
  TelemetryBridge(this.service);

  final TelemetryService service;

  static const int _maxLogs = 200;
  static const int _maxStream = 8000;

  List<StepExecutionState> _steps = [];
  final Map<String, int> _idx = {};
  final Map<String, Stopwatch> _watches = {};
  final List<LiveLogEntry> _logs = [];
  final StringBuffer _stream = StringBuffer();
  String _activeId = '';
  int _logSeq = 0;

  int _tokensTotal = 0;
  int _winTokens = 0;
  final Stopwatch _win = Stopwatch();
  double _tps = 0;

  int _ramMb = 0;
  int _maxRamMb = 0;
  ThermalStatus _thermal = ThermalStatus.normal;
  Timer? _sampler;
  bool _active = false;

  /// Sade mod: canlı akış metni, günlük ve sık kare yayını kapatılır (yalnızca sayaçlar tutulur).
  /// Adım durumları (onAgent) yine işlenir; tam arayüze dönülünce panel doğru durumu gösterir.
  bool lite = false;

  /// Akış başlarken adım listesini kurar ve donanım örneklemesini başlatır.
  void begin(Workflow wf, List<GgufModel> models) {
    _reset();
    service.reset();
    final agents = [...wf.agents]..sort((a, b) => a.order.compareTo(b.order));
    String modelName(String id) {
      for (final m in models.isEmpty ? modelCatalog : models) {
        if (m.id == id) return m.name;
      }
      return id;
    }

    _steps = [
      for (var i = 0; i < agents.length; i++)
        StepExecutionState(
          stepId: agents[i].id,
          stepIndex: i + 1,
          totalSteps: agents.length,
          status: StepStatus.idle,
          agentName: agents[i].name,
          targetModel: modelName(agents[i].modelId),
        ),
    ];
    for (var i = 0; i < _steps.length; i++) {
      _idx[_steps[i].stepId] = i;
    }
    _active = true;
    _win.start();
    _sampler = Timer.periodic(const Duration(seconds: 2), (_) => _sample());
    _sample();
    service.addLog(LogLevel.info, 'Telemetri', 'Akış başladı: ${wf.title} (${_steps.length} adım)');
    _emit(immediate: true);
  }

  void onAgent(String id, AgentStatus s, int loop) {
    final i = _idx[id];
    if (!_active || i == null) return;
    final cur = _steps[i];
    final sw = _watches.putIfAbsent(id, Stopwatch.new);
    StepStatus st;
    switch (s) {
      case AgentStatus.running:
      case AgentStatus.looping:
        st = StepStatus.running;
        _activeId = id;
        if (!sw.isRunning) sw.start();
      case AgentStatus.completed:
        st = StepStatus.completed;
        sw.stop();
      case AgentStatus.error:
        st = StepStatus.error;
        sw.stop();
      case AgentStatus.idle:
        st = StepStatus.idle;
        sw.stop();
    }
    _steps[i] = cur.copyWith(status: st, durationMs: sw.elapsedMilliseconds);
    _emit(immediate: true);
  }

  void onLive(String agentName) {
    if (!_active) return;
    _stream.clear();
    if (lite) return;
    _emit();
  }

  void onToken(String t) {
    if (!_active) return;
    _tokensTotal++;
    _winTokens++;
    if (lite) return; // metin biriktirme ve kare üretimi yok
    _stream.write(t);
    if (_stream.length > _maxStream) {
      final s = _stream.toString();
      _stream
        ..clear()
        ..write(s.substring(s.length - _maxStream ~/ 2));
    }
    final i = _idx[_activeId];
    if (i != null) {
      _steps[i] = _steps[i].copyWith(
        tokensGenerated: _steps[i].tokensGenerated + 1,
        durationMs: _watches[_activeId]?.elapsedMilliseconds,
      );
    }
    _emit();
  }

  void onLog(ExecutionLog l) {
    if (!_active || lite) return;
    service.addLog(
      switch (l.type) {
        LogType.error => LogLevel.error,
        LogType.warning => LogLevel.warn,
        _ => LogLevel.info,
      },
      l.agentName,
      l.message,
    );
  }

  /// Akış bitti/iptal edildi/hata verdi: örnekleyiciyi durdurur, son kareyi yayınlar.
  void end({bool failed = false, bool cancelled = false}) {
    if (!_active) return;
    for (final e in _watches.entries) {
      e.value.stop();
    }
    _sampler?.cancel();
    _sampler = null;
    service.addLog(
      failed ? LogLevel.error : (cancelled ? LogLevel.warn : LogLevel.info),
      'Telemetri',
      cancelled ? 'Akış iptal edildi.' : (failed ? 'Akış hatayla bitti.' : 'Akış tamamlandı.'),
    );
    _tps = 0;
    _emit(immediate: true);
    _active = false;
    _win.stop();
  }

  void _reset() {
    _sampler?.cancel();
    _sampler = null;
    _steps = [];
    _idx.clear();
    _watches.clear();
    _logs.clear();
    _stream.clear();
    _activeId = '';
    _tokensTotal = 0;
    _winTokens = 0;
    _win
      ..stop()
      ..reset();
    _tps = 0;
    _ramMb = 0;
    _maxRamMb = 0;
    _thermal = ThermalStatus.normal;
  }

  Future<void> _sample() async {
    try {
      final m = await MemInfoNative.current();
      _ramMb = ((m.appPssBytes ?? 0) / 1048576).round();
      _maxRamMb = ((m.totalBytes ?? 0) / 1048576).round();
    } catch (_) {}
    try {
      final t = await DeviceThermal.status();
      final next = t == null
          ? ThermalStatus.normal
          : (t >= 3 ? ThermalStatus.critical : (t >= 2 ? ThermalStatus.warm : ThermalStatus.normal));
      if (next != _thermal) {
        _thermal = next;
        service.onThermalStatusChanged(next);
      }
    } catch (_) {}
    if (_active) _emit();
  }

  void _refreshTps() {
    final ms = _win.elapsedMilliseconds;
    if (ms >= 1000) {
      _tps = _winTokens * 1000 / ms;
      _winTokens = 0;
      _win
        ..reset()
        ..start();
    }
  }

  void _emit({bool immediate = false}) {
    if (!_active && _steps.isEmpty) return;
    if (lite && !immediate) return; // sade modda yalnızca adım değişimi/bitişte kare üretilir
    _refreshTps();
    final i = _idx[_activeId];
    final frame = TelemetryFrame(
      timestamp: DateTime.now(),
      activeStep: i == null ? null : _steps[i],
      allSteps: List.unmodifiable(_steps),
      currentStreamingText: _stream.toString(),
      metrics: PerformanceMetrics(
        tokensPerSecond: _tps,
        ramUsageMB: _ramMb,
        maxRamMB: _maxRamMb,
        vramUsageMB: 0,
        maxVramMB: 0,
        thermalStatus: _thermal,
        temperatureCelsius: 0,
        throttleIntervalMs: service.currentThrottleMs,
        totalTokensBudget: 0,
        tokensConsumed: _tokensTotal,
      ),
      recentLogs: service.recentLogs,
    );
    if (immediate) {
      service.emitImmediate(frame);
    } else {
      service.emitThrottled(frame);
    }
  }
}
