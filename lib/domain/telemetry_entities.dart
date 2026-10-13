// lib/domain/telemetry_entities.dart
import 'package:flutter/foundation.dart';

enum StepStatus { idle, running, completed, error }
enum ThermalStatus { normal, warm, critical }
enum LogLevel { info, warn, error }

@immutable
class StepExecutionState {
  final String stepId;
  final int stepIndex;
  final int totalSteps;
  final StepStatus status;
  final String agentName;
  final String targetModel;
  final int durationMs;
  final int tokensGenerated;
  final String? error;

  const StepExecutionState({
    required this.stepId,
    required this.stepIndex,
    required this.totalSteps,
    required this.status,
    required this.agentName,
    required this.targetModel,
    this.durationMs = 0,
    this.tokensGenerated = 0,
    this.error,
  });

  StepExecutionState copyWith({
    StepStatus? status,
    int? durationMs,
    int? tokensGenerated,
    String? error,
  }) {
    return StepExecutionState(
      stepId: stepId,
      stepIndex: stepIndex,
      totalSteps: totalSteps,
      status: status ?? this.status,
      agentName: agentName,
      targetModel: targetModel,
      durationMs: durationMs ?? this.durationMs,
      tokensGenerated: tokensGenerated ?? this.tokensGenerated,
      error: error ?? this.error,
    );
  }
}

@immutable
class LiveLogEntry {
  final String id;
  final DateTime timestamp;
  final LogLevel level;
  final String component;
  final String message;

  const LiveLogEntry({
    required this.id,
    required this.timestamp,
    required this.level,
    required this.component,
    required this.message,
  });
}

@immutable
class PerformanceMetrics {
  final double tokensPerSecond;
  final int ramUsageMB;
  final int maxRamMB;
  final int vramUsageMB;
  final int maxVramMB;
  final ThermalStatus thermalStatus;
  final double temperatureCelsius;
  final int throttleIntervalMs;
  final int totalTokensBudget;
  final int tokensConsumed;

  const PerformanceMetrics({
    required this.tokensPerSecond,
    required this.ramUsageMB,
    required this.maxRamMB,
    required this.vramUsageMB,
    required this.maxVramMB,
    required this.thermalStatus,
    required this.temperatureCelsius,
    required this.throttleIntervalMs,
    required this.totalTokensBudget,
    required this.tokensConsumed,
  });
}

@immutable
class IntermediateOutput {
  final String stepId;
  final int stepIndex;
  final String agentName;
  final String rawOutput;
  final bool isStreaming;
  final DateTime? completedAt;
  final Map<String, String>? inputPipedFromPrevious;

  const IntermediateOutput({
    required this.stepId,
    required this.stepIndex,
    required this.agentName,
    required this.rawOutput,
    required this.isStreaming,
    this.completedAt,
    this.inputPipedFromPrevious,
  });
}

@immutable
class TelemetryFrame {
  final DateTime timestamp;
  final StepExecutionState? activeStep;
  final List<StepExecutionState> allSteps;
  final String currentStreamingText;
  final PerformanceMetrics metrics;
  final List<LiveLogEntry> recentLogs;

  const TelemetryFrame({
    required this.timestamp,
    required this.activeStep,
    required this.allSteps,
    required this.currentStreamingText,
    required this.metrics,
    required this.recentLogs,
  });
}
