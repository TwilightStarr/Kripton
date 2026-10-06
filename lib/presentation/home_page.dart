import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../application/app_controller.dart';
import '../application/settings_controller.dart';
import '../core/theme.dart';
import '../domain/entities.dart';
import 'agent_card.dart';
import 'cancel_dialog.dart';
import 'chat_page.dart';
import 'dev_mode_page.dart';
import 'flow_graph.dart';
import 'kripton_logo.dart';
import 'lite_run_view.dart';
import 'live_status.dart';
import 'live_status_sheet.dart';
import 'model_manager_page.dart';
import 'new_workflow_sheet.dart';
import 'project_task_sheet.dart';
import 'result_sheet.dart';
import 'speed_test_page.dart';
import 'theme_sheet.dart';

/// Kök ekran. Dinleyiciler (bildirim, sonuç ekranı) burada durur; böylece sade modda da çalışır.
/// Akış sürerken ve sade mod açıkken tam arayüz YERİNE [LiteRunView] gösterilir (tam ağaç bellekten atılır).
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<int>(appProvider.select((s) => s.noticeId), (_, __) {
      final m = ref.read(appProvider).notice;
      if (m != null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(m)));
      }
    });
    ref.listen<Artifact?>(appProvider.select((s) => s.artifact), (prev, next) {
      if (next != null && prev != next) showResultSheet(context);
    });
    // Akış hata ile bitince (doğrulama reddi dahil) sonuç ekranı açılır: hangi adımda ne olduğu görünür.
    ref.listen<bool>(appProvider.select((s) => s.failed), (prev, next) {
      if (next && prev != true) {
        final st = ref.read(appProvider);
        if (st.rejected != null || st.agentOutputs.isNotEmpty) showResultSheet(context);
      }
    });

    final (ready, lite) = ref.watch(
      appProvider.select((s) => (s.loaded && s.current != null, s.running && s.lite)),
    );
    if (!ready) {
      return Scaffold(body: Center(child: CircularProgressIndicator(color: KColors.accent)));
    }
    if (lite) return const LiteRunView();
    return const _FullHome();
  }
}

class _FullHome extends ConsumerWidget {
  const _FullHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appProvider);
    final c = ref.read(appProvider.notifier);
    final liteOnStart = ref.watch(settingsProvider.select((x) => x.liteOnStart));
    final wf = s.current;
    if (wf == null) return const SizedBox.shrink();
    final agents = [...wf.agents]..sort((a, b) => a.order.compareTo(b.order));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        toolbarHeight: 62,
        title: Row(
          children: [
            const KriptonLogo(size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Kripton', maxLines: 1, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, height: 1.1)),
                  Text('Yapay Zekâ Agent', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: KColors.muted)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (s.running)
            IconButton(
              tooltip: 'Canlı izleme paneli',
              onPressed: () => LiveTelemetrySheet.show(
                context,
                ref.read(telemetryServiceProvider),
                () => confirmAndCancel(context, ref),
              ),
              icon: const Icon(Icons.monitor_heart_outlined),
            ),
          IconButton(
            tooltip: 'Sohbet modu',
            onPressed: () => Navigator.of(context).push(ChatPage.route()),
            icon: const Icon(Icons.forum_outlined),
          ),
          IconButton(
            tooltip: 'Görünüm, sade mod ve açılış ekranı',
            onPressed: () => showAppearanceSheet(context),
            icon: const Icon(Icons.palette_outlined),
          ),
          IconButton(
            tooltip: 'Model yöneticisi',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ModelManagerPage())),
            icon: Badge(
              label: Text('${s.cachedCount}'),
              isLabelVisible: s.cachedCount > 0,
              child: const Icon(Icons.memory),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Daha fazla',
            enabled: !s.running,
            icon: const Icon(Icons.more_vert),
            onSelected: (v) async {
              switch (v) {
                case 'import':
                  await c.pickAndImportWorkflowZip();
                case 'export':
                  final path = await c.exportWorkflowZip();
                  if (path != null) await OpenFilex.open(path);
                case 'new_flutter':
                  await showProjectTaskSheet(context, ProjectMode.newFlutter);
                case 'self':
                  await showProjectTaskSheet(context, ProjectMode.selfImprove);
                case 'open_project':
                  await showProjectTaskSheet(context, ProjectMode.openProject);
                case 'speed':
                  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SpeedTestPage()));
                case 'dev_mode':
                  _openDevMode(context);
                case 'chat':
                  await Navigator.of(context).push(ChatPage.route());
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'import', child: Text("ZIP'ten akış yükle")),
              PopupMenuItem(value: 'export', child: Text('Akışı ZIP olarak indir')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'new_flutter', child: Text('Yeni Flutter projesi (ZIP)')),
              PopupMenuItem(value: 'self', child: Text('Kripton kendini geliştirsin')),
              PopupMenuItem(value: 'open_project', child: Text("Proje ZIP'i seç ve geliştir")),
              PopupMenuDivider(),
              PopupMenuItem(value: 'chat', child: Text('Sohbet modu')),
              PopupMenuItem(value: 'speed', child: Text('Hız testi')),
              PopupMenuItem(value: 'dev_mode', child: Text('Geliştirme Modu (← kaydır)')),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      // Ana ekranda sola kaydırma → Geliştirme Modu. Dikey kaydırma (ListView) ile çakışmaz;
      // yalnızca yeterince hızlı yatay hareket sayılır.
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity;
          if (v != null && v < -400) _openDevMode(context);
        },
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 140),
              children: [
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: KColors.accentSoft,
                    foregroundColor: KColors.accent,
                    minimumSize: const Size.fromHeight(46),
                  ),
                  onPressed: s.running
                      ? null
                      : () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => const NewWorkflowSheet(),
                          ),
                  icon: const Icon(Icons.add),
                  label: const Text('Yeni AI Akışı Ekle'),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: kCardDecoration(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(color: s.running ? KColors.green : KColors.accent, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 8),
                          Text('AKTİF AKIŞ', style: TextStyle(fontSize: 10.5, color: KColors.muted, fontWeight: FontWeight.w800, letterSpacing: 0.9)),
                          const Spacer(),
                          PopupMenuButton<OutputFormat>(
                            enabled: !s.running,
                            onSelected: c.setFormat,
                            itemBuilder: (_) => [
                              for (final f in OutputFormat.values) PopupMenuItem(value: f, child: Text(f.modeLabel)),
                            ],
                            child: Chip(
                              visualDensity: VisualDensity.compact,
                              label: Text('${wf.targetFormat.modeLabel} ▾'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: s.currentId,
                        isExpanded: true,
                        dropdownColor: KColors.card,
                        borderRadius: BorderRadius.circular(KRadius.md),
                        style: TextStyle(fontSize: 14, color: KColors.text, fontWeight: FontWeight.w700),
                        items: [
                          for (final w in s.workflows)
                            DropdownMenuItem(value: w.id, child: Text(w.title, overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: s.running
                            ? null
                            : (v) {
                                if (v != null) c.selectWorkflow(v);
                              },
                      ),
                      const SizedBox(height: 10),
                      Text('${wf.agents.length} Ajan · ${wf.description}', style: TextStyle(color: KColors.muted, fontSize: 12.5, height: 1.4)),
                      const SizedBox(height: 14),
                      _TaskBox(key: ValueKey(wf.id), initial: wf.task, enabled: !s.running, onChanged: c.setTask),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: s.running ? null : c.addAgent,
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Ajan Ekle'),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: 'Akışı klonla',
                            onPressed: s.running ? null : c.duplicateWorkflow,
                            icon: const Icon(Icons.copy, size: 18),
                          ),
                          if (s.workflows.length > 1)
                            IconButton(
                              tooltip: 'Akışı sil',
                              onPressed: s.running ? null : c.deleteWorkflow,
                              icon: Icon(Icons.delete_outline, size: 20, color: KColors.red),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Sade mod: akış başlayınca (veya sürerken açılırsa hemen) hafif ekrana geçilir.
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                        decoration: BoxDecoration(
                          color: KColors.green.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(KRadius.md),
                          border: Border.all(color: KColors.green.withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.eco_outlined, size: 18, color: KColors.green),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Sade mod', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: KColors.text)),
                                  Text('Çalışırken hafif ekran · daha az RAM', style: TextStyle(fontSize: 11.5, color: KColors.muted)),
                                ],
                              ),
                            ),
                            Switch(
                              value: liteOnStart,
                              onChanged: (v) {
                                ref.read(settingsProvider.notifier).setLiteOnStart(v);
                                if (s.running) c.setLite(v);
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: s.running
                            ? FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: KColors.red,
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size.fromHeight(52),
                                  disabledBackgroundColor: KColors.red.withOpacity(0.35),
                                  disabledForegroundColor: Colors.white70,
                                ),
                                onPressed: s.cancelling ? null : () => confirmAndCancel(context, ref),
                                icon: s.cancelling
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                                      )
                                    : const Icon(Icons.cancel_outlined),
                                label: Text(s.cancelling ? 'İptal ediliyor…' : 'İptal Et'),
                              )
                            : FilledButton.icon(
                                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                                onPressed: c.start,
                                icon: Icon(s.failed ? Icons.refresh : Icons.play_arrow_rounded),
                                label: Text(s.failed ? 'Yeniden Dene' : 'AI Akışını Başlat'),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                RepaintBoundary(child: FlowGraph(workflow: wf, selectedId: s.selectedAgentId, onSelect: c.selectAgent)),
                const SizedBox(height: 12),
                if (s.contextWarning != null) ...[
                  _ContextWarningBanner(message: s.contextWarning!),
                  const SizedBox(height: 12),
                ],
                const _InfoPanel(),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: Text('SIRALI AJAN HATTI', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.9, color: KColors.text)),
                    ),
                    Text('1. AI → 2. AI', style: TextStyle(fontSize: 11, color: KColors.muted)),
                  ],
                ),
                const SizedBox(height: 10),
                for (var i = 0; i < agents.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: AgentCard(
                      key: ValueKey(agents[i].id),
                      agent: agents[i],
                      isFirst: i == 0,
                      isLast: i == agents.length - 1,
                    ),
                  ),
              ],
            ),
            const Positioned(left: 0, right: 0, bottom: 0, child: LiveStatusBar()),
          ],
        ),
      ),
    );
  }

  void _openDevMode(BuildContext context) => Navigator.of(context).push(DevModePage.route());
}

/// Küçük bağlam uyarısı: akış başında görünür, yeni akış başlayana dek ana ekranda kalır.
class _ContextWarningBanner extends StatelessWidget {
  const _ContextWarningBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KColors.amber.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KColors.amber.withOpacity(0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.memory, size: 18, color: KColors.amber),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 12.5, height: 1.35))),
        ],
      ),
    );
  }
}

/// Değişmeyen cihaz bilgisi paneli: const olduğu için ana sayfa yeniden çizilince tekrar kurulmaz.
class _InfoPanel extends StatelessWidget {
  const _InfoPanel();

  static Widget _infoRow(String k, String v, Color c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: TextStyle(color: KColors.muted, fontSize: 11.5, fontFamily: 'monospace')),
            Flexible(
              child: Text(v, textAlign: TextAlign.right, style: TextStyle(color: c, fontSize: 11.5, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KColors.card.withOpacity(0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KColors.border),
      ),
      child: Column(
        children: [
          _infoRow('Hesaplama', 'CPU (GPU kapalı)', KColors.accent),
          _infoRow('Bellek Haritalama', 'mmap', KColors.green),
          _infoRow('Ekran Kilidi', 'WakelockPlus', KColors.accent),
          _infoRow('Isı İpucu', 'Uzun akışları şarjdayken çalıştır', KColors.amber),
        ],
      ),
    );
  }
}

/// Akışın görevi (Görev / İstek): düzenlenebilir kutu; her değişiklik [onChanged] ile kaydedilir.
/// Akış değişince `key` ile yeniden oluşturulur, böylece metin doğru akışa ait kalır.
class _TaskBox extends StatefulWidget {
  const _TaskBox({super.key, required this.initial, required this.enabled, required this.onChanged});

  final String initial;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  State<_TaskBox> createState() => _TaskBoxState();
}

class _TaskBoxState extends State<_TaskBox> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      enabled: widget.enabled,
      minLines: 2,
      maxLines: 6,
      keyboardType: TextInputType.multiline,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: 'Görev / İstek',
        alignLabelWithHint: true,
        helperText: 'Tüm ajanlara bağlayıcı görev olarak iletilir.',
        errorText: _c.text.trim().isEmpty ? 'Görev boş: ajanlar konudan bağımsız çalışır.' : null,
      ),
      onChanged: (v) {
        widget.onChanged(v);
        setState(() {});
      },
    );
  }
}
