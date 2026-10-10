// SPDX-License-Identifier: Apache-2.0
/// Depolama hata türleri. Kripto katmanındaki gibi mesaj taşımaz; hiçbir hassas
/// veri exception'a girmez.
enum StorageFailure {
  /// SQLCipher anahtarı veritabanıyla eşleşmiyor (veya dosya veritabanı değil).
  keyMismatch,

  /// Kayıt/blob çözülemedi veya beklenmeyen yapıda.
  corrupted,

  /// Veritabanı bu uygulamadan daha yeni bir şema sürümünde.
  newerSchema,
  notFound,
  invalidInput,
  limitExceeded,

  /// Beklenen güvenlik özelliği yok (ör. SQLCipher yüklenmemiş) veya kapalı özellik.
  unsupported,
}

class QuantaStorageException implements Exception {
  const QuantaStorageException(this.kind);
  final StorageFailure kind;

  @override
  String toString() => 'QuantaStorageException(${kind.name})';
}
