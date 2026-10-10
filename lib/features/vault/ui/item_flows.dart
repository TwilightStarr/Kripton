// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/item_actions.dart';
import '../domain/item_summary.dart';
import 'item_edit_screen.dart';
import 'widgets/kind_picker_sheet.dart';

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// "Kayıt ekle": tür seç, sonra boş düzenleme ekranını aç.
Future<void> addItemFlow(BuildContext context) async {
  final kind = await showKindPicker(context);
  if (kind == null || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<bool>(builder: (_) => ItemEditScreen(kind: kind)),
  );
}

/// Kaydı çözüp düzenleme ekranını açar (ayrıntı ekranı Aşama 4'te gelecek).
Future<void> openItemFlow(
    BuildContext context, WidgetRef ref, ItemSummary s) async {
  try {
    final item = await ref.read(itemActionsProvider).read(s.id);
    if (!context.mounted) return;
    if (item == null) {
      _snack(context, 'Kayıt bulunamadı.');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => ItemEditScreen(kind: item.kind, existing: item),
      ),
    );
  } catch (_) {
    if (context.mounted) _snack(context, 'Kayıt açılamadı.');
  }
}

/// Çöp kutusundaki bir kayıt için: geri yükle / kalıcı sil.
Future<void> trashedItemFlow(
    BuildContext context, WidgetRef ref, ItemSummary s) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(s.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600)),
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('Geri yükle'),
            onTap: () => Navigator.of(ctx).pop('restore'),
          ),
          ListTile(
            leading: Icon(Icons.delete_forever,
                color: Theme.of(ctx).colorScheme.error),
            title: const Text('Kalıcı olarak sil'),
            onTap: () => Navigator.of(ctx).pop('delete'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final actions = ref.read(itemActionsProvider);
  try {
    if (choice == 'restore') {
      await actions.restore(s.id);
      if (context.mounted) _snack(context, 'Kayıt geri yüklendi.');
    } else if (await _confirmDestructive(
      context,
      title: 'Kalıcı olarak silinsin mi?',
      body: 'Kayıt güvenli biçimde ezilerek silinir ve geri getirilemez.',
      action: 'Kalıcı olarak sil',
    )) {
      await actions.deletePermanently(s.id);
      if (context.mounted) _snack(context, 'Kayıt kalıcı olarak silindi.');
    }
  } catch (_) {
    if (context.mounted) _snack(context, 'İşlem başarısız.');
  }
}

/// Çöp kutusunu boşalt (tüm kayıtlar kalıcı silinir).
Future<void> emptyTrashFlow(BuildContext context, WidgetRef ref) async {
  final ok = await _confirmDestructive(
    context,
    title: 'Çöp kutusu boşaltılsın mı?',
    body: 'Çöp kutusundaki TÜM kayıtlar güvenli biçimde ezilerek silinir ve '
        'geri getirilemez.',
    action: 'Çöp kutusunu boşalt',
  );
  if (!ok || !context.mounted) return;
  try {
    await ref.read(itemActionsProvider).emptyTrash();
    if (context.mounted) _snack(context, 'Çöp kutusu boşaltıldı.');
  } catch (_) {
    if (context.mounted) _snack(context, 'İşlem başarısız.');
  }
}

Future<bool> _confirmDestructive(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Vazgeç'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}
