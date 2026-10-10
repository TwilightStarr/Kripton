// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';

import 'item_data.dart';
import 'item_kind.dart';

enum CustomFieldType {
  text,
  hidden,
  url,
  date;

  static CustomFieldType fromWire(String s) {
    for (final v in values) {
      if (v.name == s) return v;
    }
    return CustomFieldType.text;
  }
}

@immutable
class CustomField {
  const CustomField(this.name, this.value, [this.type = CustomFieldType.text]);
  final String name;
  final String value;
  final CustomFieldType type;

  Map<String, Object?> toJson() => {'n': name, 'v': value, 't': type.name};

  static CustomField fromJson(Map<String, Object?> j) => CustomField(
        j['n'] is String ? j['n']! as String : '',
        j['v'] is String ? j['v']! as String : '',
        CustomFieldType.fromWire(j['t'] is String ? j['t']! as String : ''),
      );

  @override
  bool operator ==(Object other) =>
      other is CustomField &&
      other.name == name &&
      other.value == value &&
      other.type == type;

  @override
  int get hashCode => Object.hash(name, value, type);
}

/// Etiketleri kırpar, boşları atar, büyük/küçük harf duyarsız tekilleştirir.
List<String> normalizeTags(Iterable<String> tags) {
  final seen = <String>{};
  final out = <String>[];
  for (final t in tags) {
    final v = t.trim();
    if (v.isEmpty) continue;
    if (seen.add(v.toLowerCase())) out.add(v);
  }
  return out;
}

/// Henüz kaydedilmemiş kayıt (kimlik/zaman damgası depoda atanır).
@immutable
class ItemDraft {
  const ItemDraft({
    required this.title,
    required this.data,
    this.category,
    this.isFavorite = false,
    this.tags = const [],
    this.colorValue,
    this.notes = '',
    this.customFields = const [],
  });

  final String title;
  final ItemData data;
  final String? category;
  final bool isFavorite;
  final List<String> tags;

  /// ARGB (0xAARRGGBB).
  final int? colorValue;
  final String notes;
  final List<CustomField> customFields;

  ItemKind get kind => data.kind;
}

/// Tam, çözülmüş kayıt. Bellekte düz metin taşır: işiniz bitince referansı bırakın.
@immutable
class VaultItem {
  const VaultItem({
    required this.id,
    required this.title,
    required this.data,
    required this.createdAt,
    required this.updatedAt,
    this.category,
    this.isFavorite = false,
    this.tags = const [],
    this.colorValue,
    this.notes = '',
    this.customFields = const [],
    this.lastUsedAt,
    this.trashedAt,
    this.secretChangedAt,
  });

  final String id;
  final String title;
  final ItemData data;
  final String? category;
  final bool isFavorite;
  final List<String> tags;
  final int? colorValue;
  final String notes;
  final List<CustomField> customFields;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastUsedAt;

  /// Doluysa çöp kutusunda; 30 gün sonra kalıcı silinir.
  final DateTime? trashedAt;

  /// Birincil sırrın (parola/anahtar) en son değiştiği an (depo yönetir).
  final DateTime? secretChangedAt;

  ItemKind get kind => data.kind;
  bool get isTrashed => trashedAt != null;

  /// Boş bırakılmış zorunlu alanlar (başlık dâhil).
  List<String> get missingRequired =>
      [if (title.trim().isEmpty) 'title', ...data.missingRequired];

  static const Object _unset = Object();

  VaultItem copyWith({
    String? title,
    ItemData? data,
    Object? category = _unset,
    bool? isFavorite,
    List<String>? tags,
    Object? colorValue = _unset,
    String? notes,
    List<CustomField>? customFields,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? lastUsedAt = _unset,
    Object? trashedAt = _unset,
    Object? secretChangedAt = _unset,
  }) =>
      VaultItem(
        id: id,
        title: title ?? this.title,
        data: data ?? this.data,
        category:
            identical(category, _unset) ? this.category : category as String?,
        isFavorite: isFavorite ?? this.isFavorite,
        tags: tags ?? this.tags,
        colorValue: identical(colorValue, _unset)
            ? this.colorValue
            : colorValue as int?,
        notes: notes ?? this.notes,
        customFields: customFields ?? this.customFields,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        lastUsedAt: identical(lastUsedAt, _unset)
            ? this.lastUsedAt
            : lastUsedAt as DateTime?,
        trashedAt: identical(trashedAt, _unset)
            ? this.trashedAt
            : trashedAt as DateTime?,
        secretChangedAt: identical(secretChangedAt, _unset)
            ? this.secretChangedAt
            : secretChangedAt as DateTime?,
      );

  ItemDraft toDraft() => ItemDraft(
        title: title,
        data: data,
        category: category,
        isFavorite: isFavorite,
        tags: tags,
        colorValue: colorValue,
        notes: notes,
        customFields: customFields,
      );
}
