// SPDX-License-Identifier: Apache-2.0
import '../../../core/storage/storage_exceptions.dart';
import '../domain/item_data.dart';
import '../domain/item_kind.dart';
import '../domain/item_summary.dart';
import '../domain/vault_item.dart';

/// `items` tablosunun düz sütunları (şifresiz metadata).
typedef ItemColumns = ({
  int kindCode,
  bool favorite,
  int createdAt,
  int updatedAt,
  int? lastUsedAt,
  int? trashedAt,
});

String _str(Object? v) => v is String ? v : '';
List<String> _strList(Object? v) =>
    v is List ? [for (final e in v) if (e is String) e] : const <String>[];

/// Kayıt <-> JSON dönüşümleri. Bu JSON biçimi şifreli blob'ların VE yedek
/// dosyasının içeriğidir; alan adları sürümlüdür (`v`), geriye uyumlu tutulur.
abstract final class ItemCodec {
  static const int version = 1;

  static DateTime dt(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
  static DateTime? dtN(int? ms) => ms == null ? null : dt(ms);

  // ------------------------------------------------------------- summary

  static Map<String, Object?> summaryJson(VaultItem i) => {
        'v': version,
        'title': i.title,
        'category': i.category,
        'tags': i.tags,
        'color': i.colorValue,
        'sub': i.data.subtitle,
        'urls': i.data.urls,
        'totp': i.data.hasTotp,
      };

  static ItemSummary summaryFrom({
    required String id,
    required Map<String, Object?> json,
    required ItemColumns cols,
  }) {
    try {
      return ItemSummary(
        id: id,
        kind: ItemKind.fromCode(cols.kindCode),
        title: _str(json['title']),
        subtitle: _str(json['sub']),
        urls: _strList(json['urls']),
        tags: _strList(json['tags']),
        category: json['category'] is String ? json['category']! as String : null,
        colorValue: json['color'] is int ? json['color']! as int : null,
        hasTotp: json['totp'] == true,
        isFavorite: cols.favorite,
        createdAt: dt(cols.createdAt),
        updatedAt: dt(cols.updatedAt),
        lastUsedAt: dtN(cols.lastUsedAt),
        trashedAt: dtN(cols.trashedAt),
      );
    } on TypeError {
      throw const QuantaStorageException(StorageFailure.corrupted);
    }
  }

  /// Çözmeden, yazılan kayıttan doğrudan özet üretir (indeks güncellemesi için).
  static ItemSummary summaryOfItem(VaultItem i) => ItemSummary(
        id: i.id,
        kind: i.kind,
        title: i.title,
        subtitle: i.data.subtitle,
        urls: i.data.urls,
        tags: i.tags,
        category: i.category,
        colorValue: i.colorValue,
        hasTotp: i.data.hasTotp,
        isFavorite: i.isFavorite,
        createdAt: i.createdAt,
        updatedAt: i.updatedAt,
        lastUsedAt: i.lastUsedAt,
        trashedAt: i.trashedAt,
      );

  // ------------------------------------------------------------- payload

  static Map<String, Object?> payloadJson(VaultItem i) => {
        'v': version,
        'kind': i.kind.wireName,
        'title': i.title,
        'category': i.category,
        'tags': i.tags,
        'color': i.colorValue,
        'notes': i.notes,
        'custom': [for (final f in i.customFields) f.toJson()],
        'secretChangedAt': i.secretChangedAt?.millisecondsSinceEpoch,
        'data': i.data.toJson(),
      };

  static VaultItem itemFrom({
    required String id,
    required Map<String, Object?> json,
    required ItemColumns cols,
  }) {
    try {
      final kind = ItemKind.fromCode(cols.kindCode);
      if (json['kind'] != kind.wireName) {
        throw const QuantaStorageException(StorageFailure.corrupted);
      }
      final data = json['data'];
      if (data is! Map<String, Object?>) {
        throw const QuantaStorageException(StorageFailure.corrupted);
      }
      final custom = json['custom'];
      return VaultItem(
        id: id,
        title: _str(json['title']),
        data: ItemData.fromJson(kind, data),
        category: json['category'] is String ? json['category']! as String : null,
        isFavorite: cols.favorite,
        tags: _strList(json['tags']),
        colorValue: json['color'] is int ? json['color']! as int : null,
        notes: _str(json['notes']),
        customFields: custom is List
            ? [
                for (final e in custom)
                  if (e is Map<String, Object?>) CustomField.fromJson(e)
              ]
            : const [],
        createdAt: dt(cols.createdAt),
        updatedAt: dt(cols.updatedAt),
        lastUsedAt: dtN(cols.lastUsedAt),
        trashedAt: dtN(cols.trashedAt),
        secretChangedAt: json['secretChangedAt'] is int
            ? dt(json['secretChangedAt']! as int)
            : null,
      );
    } on TypeError {
      throw const QuantaStorageException(StorageFailure.corrupted);
    }
  }

  // -------------------------------------------------------------- yedek

  /// Yedekte kayıt = payload JSON + düz sütunlar.
  static Map<String, Object?> backupJson(VaultItem i) => {
        ...payloadJson(i),
        'id': i.id,
        'favorite': i.isFavorite,
        'createdAt': i.createdAt.millisecondsSinceEpoch,
        'updatedAt': i.updatedAt.millisecondsSinceEpoch,
        'lastUsedAt': i.lastUsedAt?.millisecondsSinceEpoch,
        'trashedAt': i.trashedAt?.millisecondsSinceEpoch,
      };

  static VaultItem itemFromBackup(Map<String, Object?> j) {
    final id = j['id'];
    final kindWire = j['kind'];
    final created = j['createdAt'];
    final updated = j['updatedAt'];
    if (id is! String ||
        id.isEmpty ||
        kindWire is! String ||
        created is! int ||
        updated is! int) {
      throw const QuantaStorageException(StorageFailure.corrupted);
    }
    final last = j['lastUsedAt'];
    final trashed = j['trashedAt'];
    return itemFrom(
      id: id,
      json: j,
      cols: (
        kindCode: ItemKind.fromWire(kindWire).code,
        favorite: j['favorite'] == true,
        createdAt: created,
        updatedAt: updated,
        lastUsedAt: last is int ? last : null,
        trashedAt: trashed is int ? trashed : null,
      ),
    );
  }
}
