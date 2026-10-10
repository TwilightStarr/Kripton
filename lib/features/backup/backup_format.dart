// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import '../../core/crypto/crypto_exceptions.dart';
import '../../core/crypto/kdf_params.dart';

/// `.quanta` yedek biçimi v1 (ayrıntı: docs/DATA.md §9). Hepsi big-endian.
///
///   0   4  magic "QNTB"
///   4   1  formatVersion = 1
///   5   1  flags = 0 (v1'de sıfır olmalı)
///   6   8  createdAtMs
///   14  4  memoryKiB
///   18  4  iterations
///   22  1  parallelism
///   23  1  hashLength = 32
///   24  1  saltLength = 16
///   25  16 salt                          <- başlık = ilk 41 bayt
///   41  12 outerNonce
///   53  N  outerCiphertext               (AES-256-GCM, anahtar K_outer)
///   ..  16 outerTag
///   ..  32 mac = HMAC-SHA256(K_mac, başlık | outerNonce | outerCt | outerTag)
class BackupHeader {
  const BackupHeader({
    required this.formatVersion,
    required this.createdAtMs,
    required this.kdf,
    required this.salt,
  });

  static const List<int> magic = [0x51, 0x4E, 0x54, 0x42]; // "QNTB"
  static const int currentFormat = 1;
  static const int length = 41;
  static const int saltLength = 16;
  static const int outerNonceLength = 12;
  static const int tagLength = 16;
  static const int macLength = 32;
  static const int minFileLength =
      length + outerNonceLength + tagLength + macLength;

  final int formatVersion;
  final int createdAtMs;
  final KdfParams kdf;
  final Uint8List salt;

  Uint8List encode() {
    final b = ByteData(length);
    for (var i = 0; i < 4; i++) {
      b.setUint8(i, magic[i]);
    }
    b.setUint8(4, formatVersion);
    b.setUint8(5, 0);
    b.setUint64(6, createdAtMs);
    b.setUint32(14, kdf.memoryKiB);
    b.setUint32(18, kdf.iterations);
    b.setUint8(22, kdf.parallelism);
    b.setUint8(23, kdf.hashLength);
    b.setUint8(24, saltLength);
    final out = b.buffer.asUint8List();
    out.setRange(25, 41, salt);
    return out;
  }

  /// Yapıyı doğrular (parolasız). KDF POLİTİKASI burada uygulanmaz.
  static BackupHeader decode(Uint8List data) {
    const malformed = QuantaCryptoException(CryptoFailure.malformedData);
    if (data.length < minFileLength) throw malformed;
    for (var i = 0; i < 4; i++) {
      if (data[i] != magic[i]) throw malformed;
    }
    final v = data[4];
    if (v != currentFormat) {
      throw const QuantaCryptoException(CryptoFailure.unsupportedVersion);
    }
    if (data[5] != 0) throw malformed;
    final b = ByteData.sublistView(data, 0, length);
    if (b.getUint8(23) != 32 || b.getUint8(24) != saltLength) throw malformed;
    return BackupHeader(
      formatVersion: v,
      createdAtMs: b.getUint64(6),
      kdf: KdfParams(
        memoryKiB: b.getUint32(14),
        iterations: b.getUint32(18),
        parallelism: b.getUint8(22),
        hashLength: b.getUint8(23),
      ),
      salt: Uint8List.fromList(data.sublist(25, 41)),
    );
  }
}
