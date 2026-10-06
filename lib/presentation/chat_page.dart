import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../application/chat_controller.dart';
import '../core/theme.dart';
import '../domain/chat_models.dart';
import '../domain/entities.dart';
import 'chat_memory_sheet.dart';
import 'dev_mode_page.dart';
import 'home_page.dart';
import 'model_manager_page.dart';
import 'theme_sheet.dart';

/// Sohbet modu: diğer modlardan bağımsız, çevrimdışı bir model ile kalıcı hafızalı konuşma.
///
/// * Kullanıcının kendisi hakkında yazdığı ZIP, aranabilir hafızaya eklenir (Hafıza düğmesi).
/// * Her mesaj (soru ve yanıt) diske yazılır ve silinmez; sonraki sohbetlerde ilgili olanlar modele hatırlatılır.
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const ChatPage());

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _snack(String m) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final s = ref.read(chatProvider);
    if (s.generating || !s.loaded) return;
    if (ref.read(workflowBusyProvider)) {
      _snack('Bir AI akışı çalışıyor; bitince sohbete dönebilirsin.');
      return;
    }
    if (ref.read(chatModelProvider) == null) {
      _snack('Sohbet için önce bir model indir.');
      return;
    }
    _input.clear();
    await ref.read(chatProvider.notifier).send(text);
  }

  void _goFlow() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      nav.push(MaterialPageRoute<void>(builder: (_) => const HomePage()));
    }
  }

  Future<void> _pickModel() async {
    final s = ref.read(chatProvider);
    if (s.generating) {
      _snack('Yanıt üretilirken model değiştirilemez.');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ModelPickerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(chatProvider);
    final c = ref.read(chatProvider.notifier);
    final model = ref.watch(chatModelProvider);
    final modelsLoaded = ref.watch(chatModelsLoadedProvider);
    final wfBusy = ref.watch(workflowBusyProvider);

    ref.listen<int>(chatProvider.select((x) => x.noticeId), (_, __) {
      final m = ref.read(chatProvider).notice;
      if (m != null) _snack(m);
    });

    final msgs = s.messages;
    final live = s.generating;
    final count = msgs.length + (live ? 1 : 0) + (s.hasOlder ? 1 : 0);
    final chunks = s.sources.fold<int>(0, (a, x) => a + x.chunks.length);
    final lastIsUser = msgs.isNotEmpty && msgs.last.role == ChatRole.user;
    final canRetry = !live && s.error != null && lastIsUser;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(KRadius.sm),
          onTap: _pickModel,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Sohbet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, height: 1.1)),
                Text(
                  model == null ? (modelsLoaded ? 'Model yok · seçmek için dokun' : 'Modeller yükleniyor…') : '${model.name} ▾',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: KColors.muted),
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Hafıza',
            onPressed: () => showChatMemorySheet(context),
            icon: Badge(
              label: Text('${s.sources.length + s.pins.length}'),
              isLabelVisible: s.sources.isNotEmpty || s.pins.isNotEmpty,
              child: const Icon(Icons.psychology_outlined),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Daha fazla',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) async {
              switch (v) {
                case 'model':
                  await _pickModel();
                case 'models':
                  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ModelManagerPage()));
                case 'look':
                  await showAppearanceSheet(context);
                case 'export':
                  final path = await c.exportHistory();
                  if (path != null) await OpenFilex.open(path);
                case 'flow':
                  _goFlow();
                case 'dev':
                  await Navigator.of(context).push(DevModePage.route());
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'model', child: Text('Model seç')),
              PopupMenuItem(value: 'models', child: Text('Model yöneticisi')),
              PopupMenuItem(value: 'look', child: Text('Görünüm ve açılış ekranı')),
              PopupMenuItem(value: 'export', child: Text('Geçmişi dışa aktar')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'flow', child: Text('AI Akışı moduna geç')),
              PopupMenuItem(value: 'dev', child: Text('Geliştirme Moduna geç')),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (s.loaded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
              child: Row(
                children: [
                  Icon(Icons.history, size: 14, color: KColors.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${s.totalMessages} mesaj kayıtlı · $chunks profil parçası · ${s.pins.length} sabit not',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: KColors.muted),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: !s.loaded
                ? Center(child: CircularProgressIndicator(color: KColors.accent))
                : (msgs.isEmpty && !live)
                    ? _EmptyChat(hasModel: model != null, hasProfile: s.sources.isNotEmpty)
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                        itemCount: count,
                        itemBuilder: (_, i) {
                          if (live && i == 0) {
                            return _LiveBubble(text: s.draft, phase: s.phase, recalled: s.lastRecalled);
                          }
                          final j = i - (live ? 1 : 0);
                          if (j == msgs.length) {
                            return Center(
                              child: TextButton.icon(
                                onPressed: c.loadOlder,
                                icon: const Icon(Icons.expand_less, size: 18),
                                label: const Text('Eski mesajları göster'),
                              ),
                            );
                          }
                          final m = msgs[msgs.length - 1 - j];
                          return _Bubble(
                            key: ValueKey(m.id),
                            message: m,
                            onLongPress: () => _messageMenu(m),
                          );
                        },
                      ),
          ),
          if (wfBusy)
            _Banner(
              color: KColors.amber,
              icon: Icons.hourglass_top,
              text: 'Bir AI akışı çalışıyor; model meşgul. Bitince yazabilirsin.',
            ),
          if (s.loaded && modelsLoaded && model == null)
            _Banner(
              color: KColors.amber,
              icon: Icons.memory,
              text: 'Sohbet için indirilmiş bir model gerekli.',
              action: 'Model indir',
              onAction: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ModelManagerPage())),
            ),
          if (s.error != null)
            _Banner(
              color: KColors.red,
              icon: Icons.error_outline,
              text: s.error!,
              action: canRetry ? 'Tekrar dene' : null,
              onAction: canRetry ? c.retry : null,
              onClose: c.clearError,
            ),
          _InputBar(
            controller: _input,
            focus: _focus,
            generating: live,
            enabled: s.loaded,
            onSend: _send,
            onStop: c.stop,
          ),
        ],
      ),
    );
  }

  Future<void> _messageMenu(ChatMessage m) async {
    final c = ref.read(chatProvider.notifier);
    final act = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Kopyala'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: const Text('Kalıcı hafızaya sabitle'),
              subtitle: const Text('Her yanıtta modele hatırlatılır'),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
          ],
        ),
      ),
    );
    if (act == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.text));
      if (mounted) _snack('Kopyalandı');
    } else if (act == 'pin') {
      await c.addPin(m.text);
      if (mounted) _snack('Sabit notlara eklendi');
    }
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.hasModel, required this.hasProfile});

  final bool hasModel;
  final bool hasProfile;

  Widget _step(IconData icon, String title, String sub, bool done) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(done ? Icons.check_circle : icon, size: 20, color: done ? KColors.green : KColors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: KColors.text)),
                  Text(sub, style: TextStyle(fontSize: 12.5, height: 1.35, color: KColors.muted)),
                ],
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 24),
        Icon(Icons.forum_outlined, size: 44, color: KColors.accent),
        const SizedBox(height: 14),
        Center(
          child: Text('Çevrimdışı sohbet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: KColors.text)),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            'Her şey cihazında kalır. Yazdıkların kaydedilir, silinmez ve sonraki sohbetlerde hatırlanır.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.4, color: KColors.muted),
          ),
        ),
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: kCardDecoration(),
          child: Column(
            children: [
              _step(Icons.memory, '1. Model', 'Model yöneticisinden bir model indir, üstteki başlıktan seç.', hasModel),
              _step(
                Icons.folder_zip_outlined,
                '2. Kendini tanıt (isteğe bağlı)',
                'Hafıza düğmesinden kendin hakkında yazdığın bir ZIP yükle (.txt, .md, .docx…).',
                hasProfile,
              ),
              _step(Icons.chat_bubble_outline, '3. Sor', 'Aşağıya yaz; model hafızandan yararlanarak yanıtlar.', false),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({super.key, required this.message, required this.onLongPress});

  final ChatMessage message;
  final VoidCallback onLongPress;

  String _time(int ts) {
    final t = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? '${two(t.hour)}:${two(t.minute)}' : '${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final mine = message.role == ChatRole.user;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.86),
          decoration: BoxDecoration(
            color: mine ? KColors.accentSoft : KColors.card,
            borderRadius: BorderRadius.circular(KRadius.md),
            border: Border.all(color: mine ? KColors.accent.withOpacity(0.35) : KColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message.text, style: TextStyle(fontSize: 14.5, height: 1.4, color: KColors.text)),
              const SizedBox(height: 4),
              Text(_time(message.ts), style: TextStyle(fontSize: 10.5, color: KColors.muted)),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveBubble extends StatelessWidget {
  const _LiveBubble({required this.text, required this.phase, required this.recalled});

  final String text;
  final String phase;
  final int recalled;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.86),
        decoration: BoxDecoration(
          color: KColors.card,
          borderRadius: BorderRadius.circular(KRadius.md),
          border: Border.all(color: KColors.accent.withOpacity(0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (text.isNotEmpty) Text(text, style: TextStyle(fontSize: 14.5, height: 1.4, color: KColors.text)),
            if (text.isNotEmpty) const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: KColors.accent),
                ),
                const SizedBox(width: 8),
                Text(
                  recalled > 0 && text.isEmpty ? '$phase · $recalled hafıza parçası' : phase,
                  style: TextStyle(fontSize: 11.5, color: KColors.muted),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
    this.onClose,
  });

  final Color color;
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(KRadius.sm),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.35, color: KColors.text))),
          if (action != null && onAction != null) TextButton(onPressed: onAction, child: Text(action!)),
          if (onClose != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: Icon(Icons.close, size: 18, color: KColors.muted),
            ),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focus,
    required this.generating,
    required this.enabled,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool generating;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focus,
                enabled: enabled,
                minLines: 1,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(fontSize: 14.5),
                decoration: const InputDecoration(hintText: 'Bir şey yaz veya sor…'),
              ),
            ),
            const SizedBox(width: 8),
            generating
                ? IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: KColors.red, foregroundColor: Colors.white),
                    tooltip: 'Durdur',
                    onPressed: onStop,
                    icon: const Icon(Icons.stop_rounded),
                  )
                : IconButton.filled(
                    tooltip: 'Gönder',
                    onPressed: enabled ? onSend : null,
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
          ],
        ),
      ),
    );
  }
}

class _ModelPickerSheet extends ConsumerWidget {
  const _ModelPickerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(chatModelsProvider);
    final current = ref.watch(chatModelProvider);
    final cached = [for (final m in models) if (m.isCached) m];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Sohbet modeli', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: KColors.text)),
            const SizedBox(height: 4),
            Text(
              'İndirilmiş modellerden birini seç. Seçim hatırlanır; geçmiş ve hafıza her modelde aynıdır.',
              style: TextStyle(fontSize: 12.5, height: 1.35, color: KColors.muted),
            ),
            const SizedBox(height: 12),
            if (cached.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('İndirilmiş model yok.', style: TextStyle(color: KColors.muted)),
              ),
            for (final m in cached)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: kCardDecoration(),
                child: ListTile(
                  onTap: () {
                    ref.read(chatProvider.notifier).selectModel(m.id);
                    Navigator.pop(context);
                  },
                  leading: Icon(
                    m.id == current?.id ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: m.id == current?.id ? KColors.accent : KColors.muted,
                  ),
                  title: Text(m.name, style: TextStyle(fontWeight: FontWeight.w700, color: KColors.text)),
                  subtitle: Text(
                    [
                      '${m.parameters} · ${m.quantization}',
                      if (m.template == ChatTemplate.deepseek) 'akıl yürütme modeli: yavaş, önce düşünür',
                    ].join('\n'),
                    style: TextStyle(fontSize: 12, color: KColors.muted),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ModelManagerPage()));
                },
                icon: const Icon(Icons.memory, size: 18),
                label: const Text('Model yöneticisi'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
