import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../core/theme.dart';
import '../domain/entities.dart';
import 'cancel_dialog.dart';
import 'result_sheet.dart';

class LiveStatusBar extends ConsumerWidget {
  const LiveStatusBar({super.key, this.showLite = true});

  /// Çalışırken "Sade moda geç" düğmesini göster (Geliştirme Modu sayfasında kapalı).
  final bool showLite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Yalnızca çubuğun gösterdiği alanları izle: günlük/ajan durumu değişince yeniden çizilmesin.
    final (status, running, hasArtifact, cancelling, hasRejected) = ref.watch(
      appProvider.select(
        (s) => (
          s.status,
          s.running,
          s.artifact != null,
          s.cancelling,
          s.rejected != null,
        ),
      ),
    );
    final visible = status.isNotEmpty || running || hasArtifact;
    return AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, 1.2),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Material(
            color: KColors.card,
            elevation: 6,
            shadowColor: Colors.black54,
            borderRadius: BorderRadius.circular(KRadius.lg),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(KRadius.lg),
                border: Border.all(color: KColors.accent.withOpacity(0.55), width: 1.2),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  // Dönen gösterge kendi katmanında: çubuğun geri kalanı her karede yeniden boyanmaz.
                  RepaintBoundary(
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: KColors.accentSoft,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: KColors.accent.withOpacity(0.4),
                        ),
                      ),
                      child: running
                          ? Padding(
                              padding: EdgeInsets.all(7),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: KColors.accent,
                              ),
                            )
                          : Icon(
                              hasArtifact ? Icons.check : Icons.bolt,
                              size: 17,
                              color: hasArtifact
                                  ? KColors.green
                                  : KColors.accent,
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      status.isEmpty ? 'Hazır' : status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  if (running)
                    IconButton(
                      tooltip: 'İptal Et',
                      onPressed: cancelling
                          ? null
                          : () => confirmAndCancel(context, ref),
                      icon: Icon(
                        Icons.cancel_outlined,
                        color: KColors.red,
                      ),
                    ),
                  if (running && showLite)
                    IconButton(
                      tooltip: 'Sade moda geç (daha az RAM)',
                      onPressed: () =>
                          ref.read(appProvider.notifier).setLite(true),
                      icon: Icon(Icons.eco_outlined, color: KColors.green),
                    ),
                  IconButton(
                    tooltip: 'Canlı sekme',
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => const LiveSheet(),
                    ),
                    icon: Icon(Icons.menu, color: KColors.accent),
                  ),
                  if (hasRejected && !running)
                    IconButton(
                      tooltip: 'Yine de indir',
                      onPressed: () =>
                          ref.read(appProvider.notifier).downloadAnyway(),
                      icon: Icon(
                        Icons.download_for_offline_outlined,
                        color: KColors.amber,
                      ),
                    ),
                  if (hasArtifact && !running)
                    IconButton(
                      tooltip: 'Sonuç',
                      onPressed: () => showResultSheet(context),
                      icon: Icon(Icons.folder_open, color: KColors.green),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }
}

class LiveSheet extends ConsumerWidget {
  const LiveSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref.watch(appProvider.select((s) => s.liveAgent));
    final running = ref.watch(appProvider.select((s) => s.running));
    final cancelling = ref.watch(appProvider.select((s) => s.cancelling));
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.68,
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            // Sürükleme tutamacı artık tema (showDragHandle) tarafından çiziliyor.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  Icon(
                    running ? Icons.memory : Icons.terminal,
                    size: 18,
                    color: KColors.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      agent.isEmpty ? 'Canlı Çıkarım' : agent,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (running)
                    IconButton(
                      tooltip: 'İptal Et',
                      onPressed: cancelling
                          ? null
                          : () => confirmAndCancel(context, ref),
                      icon: Icon(
                        Icons.cancel_outlined,
                        size: 20,
                        color: KColors.red,
                      ),
                    ),
                  IconButton(
                    tooltip: 'Ajanlara giden tam promptlar',
                    onPressed: () => _showPromptViewer(context, ref),
                    icon: const Icon(Icons.visibility_outlined, size: 19),
                  ),
                  IconButton(
                    tooltip: 'Kopyala',
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: ref.read(liveTokensProvider)),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Kopyalandı.')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy, size: 18),
                  ),
                ],
              ),
            ),
            const TabBar(
              tabs: [
                Tab(text: 'Canlı Token Akışı'),
                Tab(text: 'Günlük'),
              ],
            ),
            const Expanded(
              child: TabBarView(
                children: [
                  RepaintBoundary(child: _TokenView()),
                  RepaintBoundary(child: _LogView()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showPromptViewer(BuildContext context, WidgetRef ref) {
  final agents = [...?ref.read(appProvider).current?.agents]
    ..sort((a, b) => a.order.compareTo(b.order));
  final prompts = ref.read(runnerProvider).promptSnapshots;
  var selectedId = agents
      .firstWhere(
        (a) => prompts.containsKey(a.id),
        orElse: () => agents.isEmpty
            ? const AgentConfig(
                id: '',
                order: 0,
                name: 'Ajan',
                mode: AgentMode.generator,
                modelId: '',
                systemPrompt: '',
                userPrompt: '',
              )
            : agents.first,
      )
      .id;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => StatefulBuilder(
      builder: (context, setState) {
        final value =
            prompts[selectedId] ?? 'Bu ajan için henüz prompt kaydedilmedi.';
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.82,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Ajanlara giden tam prompt',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Promptu kopyala',
                      onPressed: value.isEmpty
                          ? null
                          : () => Clipboard.setData(ClipboardData(text: value)),
                      icon: const Icon(Icons.copy, size: 18),
                    ),
                  ],
                ),
                if (agents.any((a) => prompts.containsKey(a.id)))
                  DropdownButtonFormField<String>(
                    value: agents.any((a) => a.id == selectedId)
                        ? selectedId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Ajan'),
                    items: [
                      for (final a in agents.where(
                        (a) => prompts.containsKey(a.id),
                      ))
                        DropdownMenuItem(
                          value: a.id,
                          child: Text(a.name, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (id) {
                      if (id != null) setState(() => selectedId = id);
                    },
                  )
                else
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Henüz prompt gönderilmedi.',
                      style: TextStyle(color: KColors.muted),
                    ),
                  ),
                const SizedBox(height: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: _tokenBox,
                    child: SingleChildScrollView(
                      child: SelectableText(value, style: _tokenStyle),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

BoxDecoration get _tokenBox => BoxDecoration(
  color: KColors.codeBg,
  borderRadius: BorderRadius.circular(10),
  border: Border.all(color: KColors.border),
);
TextStyle get _tokenStyle => TextStyle(
  fontFamily: 'monospace',
  fontSize: 12,
  color: KColors.green,
  height: 1.4,
);

class _TokenView extends ConsumerStatefulWidget {
  const _TokenView();

  @override
  ConsumerState<_TokenView> createState() => _TokenViewState();
}

class _TokenViewState extends ConsumerState<_TokenView> {
  final ScrollController _sc = ScrollController();
  // Üretim sürerken yalnızca son kısım çizilir (30K karakterlik metni 25 kez/sn yeniden yerleştirmek pahalı);
  // bittiğinde tam metin seçilebilir olarak gösterilir. Kopyala düğmesi her zaman tam metni alır.
  static const _liveTail = 6000;

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = ref.watch(appProvider.select((s) => s.running));
    final t = ref.watch(liveTokensProvider);
    var shown = t;
    if (running && t.length > _liveTail) {
      var cut = t.length - _liveTail;
      final u = t.codeUnitAt(cut);
      if (u >= 0xDC00 && u <= 0xDFFF) cut++; // vekil çiftin ortasından kesme
      shown = '…${t.substring(cut)}';
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_sc.hasClients) _sc.jumpTo(_sc.position.maxScrollExtent);
    });
    // Sık güncellenen metin kendi katmanında boyanır; çevresi yeniden çizilmez.
    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(12),
        width: double.infinity,
        decoration: _tokenBox,
        child: SingleChildScrollView(
          controller: _sc,
          child: running
              ? Text(
                  shown.isEmpty ? 'Token akışı bekleniyor...' : shown,
                  style: _tokenStyle,
                )
              : SelectableText(
                  shown.isEmpty ? 'Token akışı bekleniyor...' : shown,
                  style: _tokenStyle,
                ),
        ),
      ),
    );
  }
}

class _LogView extends ConsumerWidget {
  const _LogView();

  Color _c(LogType t) => switch (t) {
    LogType.info => KColors.muted,
    LogType.loop => KColors.amber,
    LogType.success => KColors.green,
    LogType.warning => KColors.amber,
    LogType.error => KColors.red,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(appProvider.select((s) => s.logs));
    if (logs.isEmpty) {
      return Center(
        child: Text('Henüz kayıt yok.', style: TextStyle(color: KColors.muted)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: logs.length,
      itemBuilder: (_, i) {
        final l = logs[logs.length - 1 - i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${l.time}  ',
                  style: TextStyle(color: KColors.muted),
                ),
                TextSpan(
                  text: '${l.agentName}: ',
                  style: TextStyle(color: KColors.accent),
                ),
                TextSpan(
                  text: l.message,
                  style: TextStyle(color: _c(l.type)),
                ),
              ],
            ),
            style: const TextStyle(
              fontSize: 11.5,
              fontFamily: 'monospace',
              height: 1.35,
            ),
          ),
        );
      },
    );
  }
}
