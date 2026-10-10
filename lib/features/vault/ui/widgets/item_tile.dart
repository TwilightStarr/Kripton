// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../../domain/item_summary.dart';
import '../item_kind_ui.dart';

/// Liste satırı. Yalnızca özet alanlarını gösterir (parola/CVV/not gövdesi yok).
class ItemTile extends StatelessWidget {
  const ItemTile({super.key, required this.item, this.onTap});

  final ItemSummary item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      minVerticalPadding: 8,
      leading: CircleAvatar(
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        child: Icon(kindIcon(item.kind), semanticLabel: kindLabel(item.kind)),
      ),
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: item.subtitle.isEmpty
          ? null
          : Text(item.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: (item.isFavorite || item.hasTotp)
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.hasTotp)
                  const Icon(Icons.timer_outlined,
                      size: 20, semanticLabel: 'Tek kullanımlık kod var'),
                if (item.isFavorite)
                  const Icon(Icons.star, size: 20, semanticLabel: 'Favori'),
              ],
            )
          : null,
      onTap: onTap,
    );
  }
}
