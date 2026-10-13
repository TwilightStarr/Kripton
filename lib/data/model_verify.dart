import 'dart:io';
import 'dart:typed_data';

/// İndirilen model dosyası doğrulanamadığında (boyut/başlık).
class ModelVerifyException implements Exception {
  const ModelVerifyException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// İndirmeden önce boş alan yetersizse.
class InsufficientStorageException implements Exception {
  const InsufficientStorageException({required this.requiredBytes, required this.freeBytes});
  final int requiredBytes;
  final int freeBytes;

  @override
  String toString() =>
      'Yetersiz depolama alanı: ${_gb(requiredBytes)} GB gerekli, ${_gb(freeBytes)} GB boş. '
      'Yer açıp yeniden deneyin.';
}

String _gb(int bytes) => (bytes / 1e9).toStringAsFixed(2);

/// İndirme sonrası dosya sistemi için bırakılan güvenlik payı.
const kStorageMarginBytes = 256 * 1024 * 1024;

/// [requiredBytes] = indirilecek KALAN bayt. [freeBytes] bilinmiyorsa (null) kontrol atlanır.
void ensureStorage({
  required int requiredBytes,
  required int? freeBytes,
  int marginBytes = kStorageMarginBytes,
}) {
  if (freeBytes == null || requiredBytes <= 0) return;
  if (freeBytes < requiredBytes + marginBytes) {
    throw InsufficientStorageException(requiredBytes: requiredBytes + marginBytes, freeBytes: freeBytes);
  }
}

/// Sunucunun bildirdiği toplam boyut, katalogdaki yaklaşık boyuttan çok farklıysa (ör. hata sayfası,
/// yanlış yönlendirme) hata verir. Katalog boyutu yuvarlandığından tolerans %5.
void checkExpectedSize({required int reportedBytes, int? catalogBytes, double tolerance = 0.05}) {
  if (reportedBytes <= 0) {
    throw const ModelVerifyException('Sunucu geçersiz dosya boyutu bildirdi');
  }
  if (catalogBytes == null) return;
  final diff = (reportedBytes - catalogBytes).abs();
  if (diff > catalogBytes * tolerance) {
    throw ModelVerifyException(
      'Sunucudaki dosya boyutu beklenenden farklı: $reportedBytes bayt (beklenen ≈ $catalogBytes)',
    );
  }
}

/// GGUF başlığı: "GGUF" + sürüm(u32, 2|3) + tensor_sayısı(u64) + metadata_sayısı(u64). Geçerliyse null,
/// değilse nedenini döndürür.
String? checkGgufHeader(Uint8List head) {
  if (head.length < 24) return 'başlık kısa (${head.length} bayt)';
  if (String.fromCharCodes(head.sublist(0, 4)) != 'GGUF') return 'GGUF sihirli baytı yok';
  final data = ByteData.sublistView(head);
  final version = data.getUint32(4, Endian.little);
  if (version != 2 && version != 3) return 'desteklenmeyen GGUF sürümü ($version)';
  final tensors = data.getUint64(8, Endian.little);
  final kvs = data.getUint64(16, Endian.little);
  const maxCount = 1000000;
  if (tensors <= 0 || tensors > maxCount) return 'geçersiz tensor sayısı ($tensors)';
  if (kvs <= 0 || kvs > maxCount) return 'geçersiz metadata sayısı ($kvs)';
  return null;
}

/// Dosya boyutu [expectedBytes] ile birebir eşit ve GGUF başlığı geçerli olmalı; değilse
/// [ModelVerifyException]. Dosyayı silmez (çağıran karar verir).
Future<void> verifyModelFile(File file, {required int expectedBytes}) async {
  final actual = await file.length();
  if (actual != expectedBytes) {
    throw ModelVerifyException('İndirme eksik/bozuk: $actual != $expectedBytes bayt');
  }
  final raf = await file.open();
  try {
    final head = await raf.read(24);
    final problem = checkGgufHeader(Uint8List.fromList(head));
    if (problem != null) {
      throw ModelVerifyException('Geçersiz model dosyası (GGUF başlığı: $problem); yeniden indirin');
    }
  } finally {
    await raf.close();
  }
}
