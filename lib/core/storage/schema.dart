// SPDX-License-Identifier: Apache-2.0
/// Sürümlü şema. DDL burada, düz SQL olarak tutulur (denetlenebilirlik için);
/// sıfırdan kurulum = v1 + v2 + ... adımlarının sırayla çalıştırılması, yani
/// yükseltilmiş bir veritabanı ile yeni kurulan veritabanı AYNI DDL'e sahiptir
/// (migration testi bunu `sqlite_master` karşılaştırmasıyla doğrular).
///
/// v1: items, password_history, attachments, meta
/// v2: blind_index (isteğe bağlı kör indeks) + items(trashed_at) indeksi
abstract final class Schema {
  static const int current = 2;

  /// Blob AAD'sindeki "payload şema" sürümü. DB şema sürümünden BAĞIMSIZDIR:
  /// DB migration'ı blob'ları yeniden şifrelemeyi gerektirmez. Her satır kendi
  /// `payload_schema` değerini taşır; eski satırlar okunurken (lazy) yükseltilir.
  static const int payloadSchema = 1;

  static const int maxPasswordHistory = 10;
  static const int maxAttachmentBytes = 1024 * 1024; // 1 MiB
  static const Duration trashRetention = Duration(days: 30);

  static List<String> createStatements(int version) => [
        for (var v = 1; v <= version; v++) ...stepStatements(v),
      ];

  /// (v-1) -> v için gereken ifadeler.
  static List<String> stepStatements(int version) {
    switch (version) {
      case 1:
        return const [
          '''CREATE TABLE items (
  id TEXT NOT NULL PRIMARY KEY,
  kind INTEGER NOT NULL,
  is_favorite INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_used_at INTEGER,
  trashed_at INTEGER,
  payload_schema INTEGER NOT NULL,
  summary_blob BLOB NOT NULL,
  payload_blob BLOB NOT NULL
)''',
          '''CREATE TABLE password_history (
  id TEXT NOT NULL PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  changed_at INTEGER NOT NULL,
  payload_schema INTEGER NOT NULL,
  blob BLOB NOT NULL
)''',
          'CREATE INDEX idx_history_item ON password_history(item_id, changed_at)',
          '''CREATE TABLE attachments (
  id TEXT NOT NULL PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  size INTEGER NOT NULL,
  payload_schema INTEGER NOT NULL,
  name_blob BLOB NOT NULL,
  data_blob BLOB NOT NULL
)''',
          'CREATE INDEX idx_attachments_item ON attachments(item_id)',
          '''CREATE TABLE meta (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)''',
        ];
      case 2:
        return const [
          '''CREATE TABLE blind_index (
  item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  field INTEGER NOT NULL,
  token BLOB NOT NULL,
  PRIMARY KEY (item_id, field, token)
)''',
          'CREATE INDEX idx_blind_lookup ON blind_index(field, token)',
          'CREATE INDEX idx_items_trashed ON items(trashed_at)',
        ];
      default:
        throw ArgumentError.value(version, 'version', 'unknown schema version');
    }
  }
}
