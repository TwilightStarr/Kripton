// SPDX-License-Identifier: Apache-2.0
import 'meta_store.dart';
import 'quanta_database.dart';

/// "Güvenli silme": satır önce aynı uzunlukta rastgele veriyle EZİLİR, sonra silinir.
/// (`PRAGMA secure_delete=ON` bağlantı açılışında ayrıca açıktır; VACUUM'u
/// [MaintenanceService] periyodik çalıştırır.)
///
/// Çağıranın, çok adımlı silmeleri `db.transaction` içinde çalıştırması beklenir.
///
/// Dürüst sınırlar: SQLite sayfaları kopya-yazma (copy-on-write) ile yeniden
/// yazabilir; flash depolamada aşınma dengeleme eski blokları fiziksel olarak
/// bırakabilir. Bu nedenle bu katman, SQLCipher + alan bazlı kaskad şifrelemenin
/// ÜSTÜNE bir ek önlemdir; tek başına fiziksel silme garantisi DEĞİLDİR. Disk
/// üzerindeki her şey zaten şifreli metindir.
class SecureEraser {
  SecureEraser(this._db, this._meta);
  final QuantaDatabase _db;
  final MetaStore _meta;

  /// Kaydı ve tüm çocuk satırlarını (geçmiş, ekler, kör indeks) ezip siler.
  /// Kayıt yoksa false.
  Future<bool> eraseItem(String id) async {
    final exists =
        (await _db.query('SELECT 1 AS x FROM items WHERE id = ?', [id]))
            .isNotEmpty;
    if (!exists) return false;
    await _db.exec(
        'UPDATE items SET summary_blob = randomblob(length(summary_blob)), '
        'payload_blob = randomblob(length(payload_blob)) WHERE id = ?',
        [id]);
    await _db.exec(
        'UPDATE password_history SET blob = randomblob(length(blob)) '
        'WHERE item_id = ?',
        [id]);
    await _db.exec(
        'UPDATE attachments SET name_blob = randomblob(length(name_blob)), '
        'data_blob = randomblob(length(data_blob)) WHERE item_id = ?',
        [id]);
    await _db.exec(
        'UPDATE blind_index SET token = randomblob(length(token)) '
        'WHERE item_id = ?',
        [id]);
    await _db.exec('DELETE FROM password_history WHERE item_id = ?', [id]);
    await _db.exec('DELETE FROM attachments WHERE item_id = ?', [id]);
    await _db.exec('DELETE FROM blind_index WHERE item_id = ?', [id]);
    await _db.exec('DELETE FROM items WHERE id = ?', [id]);
    await _meta.increment(MetaStore.deletesSinceVacuum);
    return true;
  }

  Future<void> eraseHistoryRow(String historyId) async {
    await _db.exec(
        'UPDATE password_history SET blob = randomblob(length(blob)) '
        'WHERE id = ?',
        [historyId]);
    await _db.exec('DELETE FROM password_history WHERE id = ?', [historyId]);
    await _meta.increment(MetaStore.deletesSinceVacuum);
  }

  Future<bool> eraseAttachment(String attachmentId) async {
    final n = await _db.exec(
        'UPDATE attachments SET name_blob = randomblob(length(name_blob)), '
        'data_blob = randomblob(length(data_blob)) WHERE id = ?',
        [attachmentId]);
    if (n == 0) return false;
    await _db.exec('DELETE FROM attachments WHERE id = ?', [attachmentId]);
    await _meta.increment(MetaStore.deletesSinceVacuum);
    return true;
  }

  /// Tüm kör indeks satırlarını ezip siler (özellik kapatılırken / yeniden kurulurken).
  Future<void> eraseAllBlindIndex() async {
    await _db.exec('UPDATE blind_index SET token = randomblob(length(token))');
    await _db.exec('DELETE FROM blind_index');
  }

  Future<void> eraseBlindIndexOf(String itemId) async {
    await _db.exec(
        'UPDATE blind_index SET token = randomblob(length(token)) '
        'WHERE item_id = ?',
        [itemId]);
    await _db.exec('DELETE FROM blind_index WHERE item_id = ?', [itemId]);
  }
}
