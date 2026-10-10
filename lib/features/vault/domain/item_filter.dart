// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';

import '../../../core/util/text_fold.dart';
import 'item_kind.dart';
import 'item_summary.dart';

enum TrashScope { active, trashed, all }

enum ItemSort { titleAsc, updatedDesc, createdDesc, lastUsedDesc }

@immutable
class ItemFilter {
  const ItemFilter({
    this.kinds,
    this.category,
    this.tag,
    this.favoritesOnly = false,
    this.trash = TrashScope.active,
    this.sort = ItemSort.titleAsc,
  });

  final Set<ItemKind>? kinds;
  final String? category;
  final String? tag;
  final bool favoritesOnly;
  final TrashScope trash;
  final ItemSort sort;

  bool matches(ItemSummary s) {
    switch (trash) {
      case TrashScope.active:
        if (s.isTrashed) return false;
      case TrashScope.trashed:
        if (!s.isTrashed) return false;
      case TrashScope.all:
        break;
    }
    if (kinds != null && !kinds!.contains(s.kind)) return false;
    if (favoritesOnly && !s.isFavorite) return false;
    if (category != null &&
        foldForSearch(s.category ?? '') != foldForSearch(category!)) {
      return false;
    }
    if (tag != null) {
      final t = foldForSearch(tag!);
      if (!s.tags.any((x) => foldForSearch(x) == t)) return false;
    }
    return true;
  }

  int compare(ItemSummary a, ItemSummary b) {
    int byTitle() =>
        foldForSearch(a.title).compareTo(foldForSearch(b.title));
    switch (sort) {
      case ItemSort.titleAsc:
        return byTitle();
      case ItemSort.updatedDesc:
        final c = b.updatedAt.compareTo(a.updatedAt);
        return c != 0 ? c : byTitle();
      case ItemSort.createdDesc:
        final c = b.createdAt.compareTo(a.createdAt);
        return c != 0 ? c : byTitle();
      case ItemSort.lastUsedDesc:
        final la = a.lastUsedAt?.millisecondsSinceEpoch ?? -1;
        final lb = b.lastUsedAt?.millisecondsSinceEpoch ?? -1;
        final c = lb.compareTo(la);
        return c != 0 ? c : byTitle();
    }
  }
}
