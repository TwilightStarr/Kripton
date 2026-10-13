import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../core/theme.dart';

/// Tüm "İptal Et" girişlerinin (ana buton, durum çubuğu, LiveSheet) ortak yolu.
/// Onay alınırsa AppController.cancel() çağrılır. Diyalog açıkken akış sürer;
/// akış kendiliğinden biterse diyalog kapanır.
Future<void> confirmAndCancel(BuildContext context, WidgetRef ref) async {
  final s = ref.read(appProvider);
  if (!s.running || s.cancelling) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => const _CancelDialog(),
  );
  if (ok == true) ref.read(appProvider.notifier).cancel();
}

class _CancelDialog extends ConsumerWidget {
  const _CancelDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<bool>(appProvider.select((s) => s.running), (_, running) {
      if (!running && (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).pop(false);
      }
    });
    return AlertDialog(
      backgroundColor: KColors.card,
      title: const Text('Akış iptal edilsin mi?'),
      content: const Text('Şu ana kadarki ilerleme kaybolur.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Vazgeç'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: KColors.red, foregroundColor: Colors.white),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('İptal Et'),
        ),
      ],
    );
  }
}
