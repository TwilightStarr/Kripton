// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';

import 'item_kind.dart';

/// Liste/arama için hafif görünüm: parola, CVV, not gövdesi vb. İÇERMEZ.
/// Şifreli "summary" blob'undan + düz sütunlardan (tür, favori, zamanlar) oluşur.
@immutable
class ItemSummary {
  const ItemSummary({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.urls,
    required this.tags,
    required this.hasTotp,
    required this.isFavorite,
    required this.createdAt,
    required this.updatedAt,
    this.category,
    this.colorValue,
    this.lastUsedAt,
    this.trashedAt,
  });

  final String id;
  final ItemKind kind;
  final String title;
  final String subtitle;
  final List<String> urls;
  final List<String> tags;
  final String? category;
  final int? colorValue;
  final bool hasTotp;
  final bool isFavorite;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastUsedAt;
  final DateTime? trashedAt;

  bool get isTrashed => trashedAt != null;

  static const Object _unset = Object();

  ItemSummary copyWith({
    bool? isFavorite,
    Object? lastUsedAt = _unset,
    Object? trashedAt = _unset,
  }) =>
      ItemSummary(
        id: id,
        kind: kind,
        title: title,
        subtitle: subtitle,
        urls: urls,
        tags: tags,
        category: category,
        colorValue: colorValue,
        hasTotp: hasTotp,
        isFavorite: isFavorite ?? this.isFavorite,
        createdAt: createdAt,
        updatedAt: updatedAt,
        lastUsedAt: identical(lastUsedAt, _unset)
            ? this.lastUsedAt
            : lastUsedAt as DateTime?,
        trashedAt: identical(trashedAt, _unset)
            ? this.trashedAt
            : trashedAt as DateTime?,
      );
}
