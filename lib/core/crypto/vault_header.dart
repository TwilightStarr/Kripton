// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'crypto_exceptions.dart';
import 'kdf_params.dart';

/// Vault başlığı (v1). Kanonik, sabit-uzunluklu ikili biçim (hepsi big-endian):
///
///   magic "QNTA"(4) | format(1) | flags(1) | createdAtMs(8)
///   | memKiB(4) | iterations(4) | parallelism(1) | hashLen(1)
///   | saltLen(1)=16 | salt(16)
///   | wrappedVmk(72)                      = nonce24 | ct32 | tag16
///   | recoveryWrappedVmk(72)  [flags&2]
///   | mac(32)                             = HMAC-SHA256(K_header, yukarıdakilerin tamamı)
///
/// flags: bit0 = key file gerekli, bit1 = kurtarma sarmalı var.
@immutable
class VaultHeader {
  const VaultHeader({
    required this.formatVersion,
    required this.createdAtMs,
    required this.keyFileRequired,
    required this.kdf,
    required this.salt,
    required this.wrappedVmk,
    required this.recoveryWrappedVmk,
    required this.mac,
  });

  static const List<int> magic = [0x51, 0x4E, 0x54, 0x41]; // "QNTA"
  static const int currentFormat = 1;
  static const int saltLength = 16;
  static const int wrappedLength = 24 + 32 + 16;
  static const int macLength = 32;

  final int formatVersion;
  final int createdAtMs;
  final bool keyFileRequired;
  final KdfParams kdf;
  final Uint8List salt;
  final Uint8List wrappedVmk;
  final Uint8List? recoveryWrappedVmk;
  final Uint8List mac;

  bool get hasRecovery => recoveryWrappedVmk != null;
  int get _flags => (keyFileRequired ? 1 : 0) | (hasRecovery ? 2 : 0);

  VaultHeader copyWith({
    int? createdAtMs,
    bool? keyFileRequired,
    KdfParams? kdf,
    Uint8List? salt,
    Uint8List? wrappedVmk,
    Uint8List? recoveryWrappedVmk,
    Uint8List? mac,
  }) =>
      VaultHeader(
        formatVersion: formatVersion,
        createdAtMs: createdAtMs ?? this.createdAtMs,
        keyFileRequired: keyFileRequired ?? this.keyFileRequired,
        kdf: kdf ?? this.kdf,
        salt: salt ?? this.salt,
        wrappedVmk: wrappedVmk ?? this.wrappedVmk,
        recoveryWrappedVmk: recoveryWrappedVmk ?? this.recoveryWrappedVmk,
        mac: mac ?? this.mac,
      );

  /// KEK ile sarmanın AAD'sine giren değişken alanlar (parametreler + salt + bayraklar).
  Uint8List coreBytes() {
    final b = BytesBuilder(copy: false)
      ..add(magic)
      ..addByte(formatVersion)
      ..addByte(_flags);
    final t = ByteData(8)..setUint64(0, createdAtMs);
    b.add(t.buffer.asUint8List());
    final k = ByteData(10)
      ..setUint32(0, kdf.memoryKiB)
      ..setUint32(4, kdf.iterations)
      ..setUint8(8, kdf.parallelism)
      ..setUint8(9, kdf.hashLength);
    b.add(k.buffer.asUint8List());
    b.addByte(salt.length);
    b.add(salt);
    return b.toBytes();
  }

  /// MAC'in kapsadığı baytlar (MAC hariç her şey).
  Uint8List macInput() {
    final b = BytesBuilder(copy: false)
      ..add(coreBytes())
      ..add(wrappedVmk);
    final r = recoveryWrappedVmk;
    if (r != null) b.add(r);
    return b.toBytes();
  }

  Uint8List encode() =>
      (BytesBuilder(copy: false)..add(macInput())..add(mac)).toBytes();

  static VaultHeader decode(Uint8List data) {
    const malformed = QuantaCryptoException(CryptoFailure.malformedData);
    var pos = 0;
    Uint8List take(int n) {
      if (n < 0 || pos + n > data.length) throw malformed;
      final out = Uint8List.fromList(data.sublist(pos, pos + n));
      pos += n;
      return out;
    }

    final m = take(4);
    for (var i = 0; i < 4; i++) {
      if (m[i] != magic[i]) throw malformed;
    }
    final version = take(1)[0];
    if (version != currentFormat) {
      throw const QuantaCryptoException(CryptoFailure.unsupportedVersion);
    }
    final flags = take(1)[0];
    if ((flags & ~3) != 0) throw malformed;
    final createdAt = ByteData.sublistView(take(8)).getUint64(0);
    final kb = ByteData.sublistView(take(10));
    final params = KdfParams(
      memoryKiB: kb.getUint32(0),
      iterations: kb.getUint32(4),
      parallelism: kb.getUint8(8),
      hashLength: kb.getUint8(9),
    );
    if (take(1)[0] != saltLength) throw malformed;
    final salt = take(saltLength);
    final wrapped = take(wrappedLength);
    final recovery = (flags & 2) != 0 ? take(wrappedLength) : null;
    final mac = take(macLength);
    if (pos != data.length) throw malformed; // fazladan bayt yok
    return VaultHeader(
      formatVersion: version,
      createdAtMs: createdAt,
      keyFileRequired: (flags & 1) != 0,
      kdf: params,
      salt: salt,
      wrappedVmk: wrapped,
      recoveryWrappedVmk: recovery,
      mac: mac,
    );
  }
}
