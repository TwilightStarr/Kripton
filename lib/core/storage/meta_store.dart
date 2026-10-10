// SPDX-License-Identifier: Apache-2.0
import 'quanta_database.dart';

/// `meta` tablosu: küçük, hassas olmayan anahtar/değer çiftleri
/// (son VACUUM zamanı, silme sayacı, kör indeks bayrağı).
class MetaStore {
  MetaStore(this._db);
  final QuantaDatabase _db;

  static const lastVacuumMs = 'last_vacuum_ms';
  static const deletesSinceVacuum = 'deletes_since_vacuum';
  static const blindIndexEnabled = 'blind_index_enabled';

  Future<String?> get(String key) async {
    final rows =
        await _db.query('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.single.read<String>('value');
  }

  Future<void> set(String key, String value) async {
    await _db.exec(
        'INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)', [key, value]);
  }

  Future<int> getInt(String key, {int fallback = 0}) async =>
      int.tryParse(await get(key) ?? '') ?? fallback;

  Future<void> setInt(String key, int value) => set(key, value.toString());

  Future<int> increment(String key, [int by = 1]) async {
    final v = await getInt(key) + by;
    await setInt(key, v);
    return v;
  }
}
