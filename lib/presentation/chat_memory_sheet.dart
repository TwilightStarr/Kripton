import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/chat_controller.dart';
import '../core/theme.dart';
import '../domain/chat_models.dart';

/// Sohbet hafızası: yüklenen "kendim hakkında" ZIP'leri, sabit notlar ve kayıt sayıları.
Future<void> showChatMemorySheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ChatMemorySheet(),
    );

String _date(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.day)}.${two(t.month)}.${t.year}';
}

class _ChatMemorySheet extends ConsumerStatefulWidget {
  const _ChatMemorySheet();

  @override
  ConsumerState<_ChatMemorySheet> createState() => _ChatMemorySheetState();
}

class _ChatMemorySheetState extends ConsumerState<_ChatMemorySheet> {
  final _pin = TextEditingController();

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _confirmRemoveSource(ProfileSource src) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Profil kaynağı kaldırılsın mı?'),
        content: Text(
          '"${src.name}" hafızadan çıkarılır; model artık bu ZIP\'teki bilgilere erişemez. '
          'Sohbet geçmişin etkilenmez.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Kaldır')),
        ],
      ),
    );
    if (ok == true) await ref.read(chatProvider.notifier).removeSource(src.id);
  }

  Future<void> _addPin() async {
    final t = _pin.text.trim();
    if (t.isEmpty) return;
    _pin.clear();
    await ref.read(chatProvider.notifier).addPin(t);
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: KColors.text)),
      );

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(chatProvider);
    final c = ref.read(chatProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Hafıza', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: KColors.text)),
              const SizedBox(height: 4),
              Text(
                'Yazdıkların ve yanıtlar cihazında kalıcı saklanır ve silinmez. Her soruda, ilgili profil parçaları ve '
                'eski konuşmalar aranıp modele hatırlatılır (model bağlamı küçük olduğu için hepsi birden verilmez).',
                style: TextStyle(fontSize: 12.5, height: 1.4, color: KColors.muted),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: kCardDecoration(),
                child: Row(
                  children: [
                    Icon(Icons.history, color: KColors.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${s.totalMessages} mesaj kayıtlı',
                        style: TextStyle(fontWeight: FontWeight.w700, color: KColors.text),
                      ),
                    ),
                  ],
                ),
              ),
              _title('KENDİM HAKKINDA'),
              if (s.sources.isEmpty)
                Text(
                  'Henüz ZIP yüklenmedi. Kendin hakkında yazdığın .txt, .md, .json, .csv, .html veya .docx dosyalarını '
                  'ZIP yapıp yükle.',
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: KColors.muted),
                ),
              for (final src in s.sources)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: kCardDecoration(),
                  child: ListTile(
                    leading: Icon(Icons.folder_zip_outlined, color: KColors.accent),
                    title: Text(src.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: KColors.text)),
                    subtitle: Text(
                      '${src.fileCount} dosya · ${src.chunks.length} parça · ${_date(src.importedAt)}',
                      style: TextStyle(fontSize: 12, color: KColors.muted),
                    ),
                    trailing: IconButton(
                      tooltip: 'Kaldır',
                      onPressed: () => _confirmRemoveSource(src),
                      icon: Icon(Icons.delete_outline, color: KColors.red),
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: KColors.accentSoft,
                  foregroundColor: KColors.accent,
                  minimumSize: const Size.fromHeight(46),
                ),
                onPressed: s.importing ? null : c.pickAndImportProfileZip,
                icon: s.importing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload_file),
                label: Text(s.importing ? 'ZIP okunuyor…' : "ZIP yükle (aynı adlıysa güncellenir)"),
              ),
              _title('SABİT NOTLAR'),
              Text(
                'Her yanıtta modele verilir. Bir mesaja uzun basıp "Kalıcı hafızaya sabitle" ile de ekleyebilirsin.',
                style: TextStyle(fontSize: 12.5, height: 1.4, color: KColors.muted),
              ),
              const SizedBox(height: 8),
              for (final p in s.pins)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  decoration: kCardDecoration(),
                  child: Row(
                    children: [
                      Icon(Icons.push_pin_outlined, size: 18, color: KColors.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(p.text, maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, height: 1.35, color: KColors.text)),
                      ),
                      IconButton(
                        tooltip: 'Kaldır',
                        onPressed: () => c.removePin(p.id),
                        icon: Icon(Icons.close, size: 18, color: KColors.muted),
                      ),
                    ],
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pin,
                      minLines: 1,
                      maxLines: 3,
                      style: const TextStyle(fontSize: 14),
                      decoration: const InputDecoration(hintText: 'Örn. Adım Ali, İstanbul\'da yaşıyorum'),
                      onSubmitted: (_) => _addPin(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(tooltip: 'Ekle', onPressed: _addPin, icon: const Icon(Icons.add)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
