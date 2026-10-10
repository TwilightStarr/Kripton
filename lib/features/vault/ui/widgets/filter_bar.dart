// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/item_list_controller.dart';
import '../../domain/item_kind.dart';
import '../item_kind_ui.dart';

/// Yatay kaydırmalı tür/favori çipleri.
class FilterBar extends ConsumerWidget {
  const FilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kinds = ref.watch(itemListProvider.select((s) => s.kinds));
    final favs = ref.watch(itemListProvider.select((s) => s.favoritesOnly));
    final ctl = ref.read(itemListProvider.notifier);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          FilterChip(
            avatar: const Icon(Icons.star_outline, size: 18),
            label: const Text('Favoriler'),
            selected: favs,
            onSelected: ctl.setFavoritesOnly,
          ),
          for (final k in ItemKind.values) ...[
            const SizedBox(width: 8),
            FilterChip(
              label: Text(kindLabel(k)),
              selected: kinds.contains(k),
              onSelected: (_) => ctl.toggleKind(k),
            ),
          ],
        ],
      ),
    );
  }
}
