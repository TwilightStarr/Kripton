// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'item_filter.dart';
import 'item_summary.dart';
import 'vault_item.dart';
import 'vault_records.dart';

/// Kör indeks alanları (isteğe bağlı; bkz. docs/DATA.md §7).
enum BlindField {
  username(1),
  host(2),
  title(3),
  tag(4);

  const BlindField(this.code);
  final int code;
}

/// Kasa deposu.
///
/// KİLİT SÖZLEŞMESİ: Tüm metotlar yalnızca kilit AÇIKKEN çalışır. Kilitliyken
/// (oturum anahtarları sıfırlanmış ya da depo kapatılmışsa) `Future` döndüren
/// metotlar [StateError] ile başarısız `Future` verir; `Stream` döndüren metotlar
/// çağrı anında [StateError] fırlatır. Açık akışlar kilitlenince kapanır.
abstract interface class VaultRepository {
  // --- CRUD
  Future<VaultItem> create(ItemDraft draft);
  Future<VaultItem?> read(String id);

  /// Kimlik, tür, oluşturma/son kullanım/çöp zamanı DEPODAKİNDEN korunur;
  /// birincil sır değiştiyse eski değer parola geçmişine (son 10) eklenir.
  Future<VaultItem> update(VaultItem item);

  /// KALICI güvenli silme (rastgele veriyle ez + sil). Çöp kutusu için [trash].
  Future<void> delete(String id);

  // --- çöp kutusu
  Future<void> trash(String id);
  Future<void> restore(String id);

  /// 30 günü dolan çöp kayıtlarını güvenli siler; silinen sayıyı döndürür.
  Future<int> purgeExpiredTrash();
  Future<int> emptyTrash();

  // --- hafif güncellemeler
  Future<void> markUsed(String id);
  Future<void> setFavorite(String id, bool value);

  // --- listeleme / arama (bellek içi indeks)
  Future<List<ItemSummary>> list([ItemFilter filter = const ItemFilter()]);
  Future<List<ItemSummary>> search(String query,
      {ItemFilter filter = const ItemFilter()});

  /// Kör indeks açıkken tam eşleşme (HMAC); kapalıysa
  /// `QuantaStorageException(unsupported)`.
  Future<List<ItemSummary>> findByExact(BlindField field, String term);
  Future<bool> isBlindIndexEnabled();
  Future<void> setBlindIndexEnabled(bool enabled);

  // --- reaktif okuma
  Stream<List<ItemSummary>> watchList([ItemFilter filter = const ItemFilter()]);
  Stream<VaultItem?> watch(String id);

  /// Tüm kayıtları tek tek çözerek akıtır (denetim/dışa aktarım).
  Stream<VaultItem> readAll({bool includeTrashed = false});

  // --- parola geçmişi / ekler
  Future<List<PasswordHistoryEntry>> passwordHistory(String itemId);
  Future<AttachmentInfo> addAttachment(
      String itemId, String name, Uint8List bytes);
  Future<List<AttachmentInfo>> listAttachments(String itemId);
  Future<AttachmentData?> readAttachment(String attachmentId);
  Future<void> deleteAttachment(String attachmentId);

  // --- yedek / geri yükleme
  Stream<VaultItemSnapshot> exportSnapshots();
  Future<ImportDisposition> restoreSnapshot(
      VaultItemSnapshot snapshot, ConflictPolicy policy);

  /// Okunamayan (bozuk/yanlış anahtarlı) kayıt kimlikleri; açılışta toplanır.
  List<String> get unreadableIds;

  /// Bellek indeksini sıfırlar, akışları kapatır. DB'yi KAPATMAZ (sahibi kapatır).
  Future<void> close();
}
