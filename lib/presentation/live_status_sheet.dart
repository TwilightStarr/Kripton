// lib/presentation/live_status_sheet.dart
import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../domain/telemetry_entities.dart';
import '../application/telemetry_service.dart';

class MiniLiveBar extends StatelessWidget {
  final TelemetryFrame? frame;
  final VoidCallback onTap;

  const MiniLiveBar({Key? key, required this.frame, required this.onTap})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (frame == null || frame!.activeStep == null) return const SizedBox.shrink();

    final step = frame!.activeStep!;
    final tokS = frame!.metrics.tokensPerSecond.toStringAsFixed(1);

    return Positioned(
      bottom: 24,
      left: 16,
      right: 16,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: KColors.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: KColors.accent, width: 1.5),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 12, offset: Offset(0, 4)),
            ],
          ),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: KColors.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Adım ${step.stepIndex}/${step.totalSteps}: ${step.agentName}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    Text(
                      'Model: ${step.targetModel}',
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: KColors.bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$tokS tok/s',
                  style: TextStyle(color: KColors.green, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LiveTelemetrySheet extends StatefulWidget {
  final TelemetryService telemetryService;
  final VoidCallback onCancelWorkflow;

  const LiveTelemetrySheet({
    Key? key,
    required this.telemetryService,
    required this.onCancelWorkflow,
  }) : super(key: key);

  static void show(BuildContext context, TelemetryService service, VoidCallback onCancel) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: KColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: LiveTelemetrySheet(
          telemetryService: service,
          onCancelWorkflow: onCancel,
        ),
      ),
    );
  }

  @override
  State<LiveTelemetrySheet> createState() => _LiveTelemetrySheetState();
}

class _LiveTelemetrySheetState extends State<LiveTelemetrySheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TelemetryFrame>(
      stream: widget.telemetryService.telemetryStream,
      initialData: widget.telemetryService.lastFrame,
      builder: (context, snapshot) {
        final frame = snapshot.data;

        return Column(
          children: [
            // Sheet Header & Tabs
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: KColors.card)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Text(
                          'Canlı İzleme Paneli',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton.icon(
                            onPressed: widget.onCancelWorkflow,
                            icon: Icon(Icons.stop_circle_outlined, size: 18, color: KColors.red),
                            label: Text('İptal', style: TextStyle(color: KColors.red)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white70),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                    ],
                  ),
                  TabBar(
                    controller: _tabController,
                    indicatorColor: KColors.accent,
                    labelColor: KColors.accent,
                    unselectedLabelColor: Colors.white60,
                    isScrollable: true,
                    tabs: const [
                      Tab(text: 'Adım İlerlemesi'),
                      Tab(text: 'Canlı Log Konsolu'),
                      Tab(text: 'Ara Çıktı Akışı'),
                      Tab(text: 'Donanım & Bütçe'),
                    ],
                  ),
                ],
              ),
            ),
            // Tab Contents
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildStepProgressTab(frame),
                  _buildLogsTab(frame),
                  _buildIntermediateOutputsTab(frame),
                  _buildHardwareMonitorTab(frame),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStepProgressTab(TelemetryFrame? frame) {
    if (frame == null || frame.allSteps.isEmpty) {
      return const Center(child: Text('Aktif adım bulunamadı.', style: TextStyle(color: Colors.white54)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: frame.allSteps.length,
      itemBuilder: (context, index) {
        final s = frame.allSteps[index];
        Color color = Colors.grey;
        if (s.status == StepStatus.completed) color = KColors.green;
        if (s.status == StepStatus.running) color = KColors.accent;
        if (s.status == StepStatus.error) color = KColors.red;

        return Card(
          color: KColors.card,
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: CircleAvatar(backgroundColor: color.withOpacity(0.2), child: Icon(Icons.circle, color: color, size: 14)),
            title: Text('${s.stepIndex}. ${s.agentName}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            subtitle: Text('Model: ${s.targetModel} | Durum: ${s.status.name.toUpperCase()}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
            trailing: Text('${s.tokensGenerated} tok', style: const TextStyle(color: Colors.white70)),
          ),
        );
      },
    );
  }

  Widget _buildLogsTab(TelemetryFrame? frame) {
    final logs = frame?.recentLogs ?? [];
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: logs.length,
      itemBuilder: (context, index) {
        final log = logs[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '[${log.component}] ${log.message}',
            style: TextStyle(
              color: log.level == LogLevel.error ? Colors.redAccent : (log.level == LogLevel.warn ? Colors.amberAccent : Colors.white70),
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
        );
      },
    );
  }

  Widget _buildIntermediateOutputsTab(TelemetryFrame? frame) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        frame?.currentStreamingText.isEmpty ?? true
            ? 'Model henüz token üretmedi...'
            : frame!.currentStreamingText,
        style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
      ),
    );
  }

  Widget _buildHardwareMonitorTab(TelemetryFrame? frame) {
    final m = frame?.metrics;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _metricTile('Anlık Token Hızı', '${(m?.tokensPerSecond ?? 0).toStringAsFixed(1)} tok/s', Icons.speed),
        _metricTile('RAM Kullanımı', '${m?.ramUsageMB ?? 0} MB / ${m?.maxRamMB ?? 0} MB', Icons.memory),
        _metricTile('Termal Durum', m == null
              ? 'NORMAL'
              : '${m.thermalStatus.name.toUpperCase()}${m.temperatureCelsius > 0 ? ' (${m.temperatureCelsius.toStringAsFixed(1)}°C)' : ''}', Icons.thermostat),
        _metricTile('Telemetri Tamponlama (Throttling)', '${m?.throttleIntervalMs ?? 100} ms', Icons.timer),
      ],
    );
  }

  Widget _metricTile(String title, String value, IconData icon) {
    return Card(
      color: KColors.card,
      child: ListTile(
        leading: Icon(icon, color: KColors.accent),
        title: Text(title, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        trailing: Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
      ),
    );
  }
}
