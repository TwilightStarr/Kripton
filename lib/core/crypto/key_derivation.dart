// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../security/key_material.dart';
import '../security/secret_bytes.dart';
import 'crypto_exceptions.dart';
import 'crypto_labels.dart';
import 'hkdf.dart';
import 'kdf_params.dart';

/// Argon2id çekirdeği (paketin saf-Dart uygulaması).
Future<Uint8List> argon2idDerive(
    Uint8List input, Uint8List salt, KdfParams p) async {
  final algorithm = Argon2id(
    parallelism: p.parallelism,
    memory: p.memoryKiB,
    iterations: p.iterations,
    hashLength: p.hashLength,
  );
  final key = await algorithm.deriveKey(
    secretKey: SecretKeyData(input),
    nonce: salt,
  );
  return extractAndWipe(key);
}

/// Argon2id'nin nerede çalışacağını soyutlar (ileride yerel/FFI uygulaması takılabilir).
abstract interface class Argon2Runner {
  Future<Uint8List> derive({
    required Uint8List input,
    required Uint8List salt,
    required KdfParams params,
  });
}

/// Aynı isolate'ta çalışır (testler / zaten arka plan isolate'ındaysanız).
class InlineArgon2Runner implements Argon2Runner {
  const InlineArgon2Runner();
  @override
  Future<Uint8List> derive({
    required Uint8List input,
    required Uint8List salt,
    required KdfParams params,
  }) =>
      argon2idDerive(input, salt, params);
}

/// UI isolate'ını kilitlememek için ayrı isolate'ta çalışır.
class IsolateArgon2Runner implements Argon2Runner {
  const IsolateArgon2Runner();
  @override
  Future<Uint8List> derive({
    required Uint8List input,
    required Uint8List salt,
    required KdfParams params,
  }) async {
    final i = Uint8List.fromList(input);
    final s = Uint8List.fromList(salt);
    try {
      return await Isolate.run(() async {
        try {
          return await argon2idDerive(i, s, params);
        } finally {
          i.fillRange(0, i.length, 0); // isolate içindeki kopya
        }
      });
    } finally {
      i.fillRange(0, i.length, 0);
    }
  }
}

/// (parola, Secret Key, [key file]) -> HKDF-SHA512 -> Argon2id -> KEK.
class KeyDerivation {
  KeyDerivation({Argon2Runner? runner, this.policy = KdfPolicy.production})
      : runner = runner ?? const IsolateArgon2Runner();

  final Argon2Runner runner;
  final KdfPolicy policy;

  Future<SecretBytes> deriveKek({
    required SecretBytes password,
    required SecretBytes secretKey,
    SecretBytes? keyFile,
    required Uint8List salt,
    required KdfParams params,
  }) async {
    policy.validate(params); // pahalı işten ÖNCE
    if (salt.length != 16 || secretKey.length != 16) {
      throw const QuantaCryptoException(CryptoFailure.invalidInput);
    }

    Uint8List? keyFileHash;
    if (keyFile != null) {
      final raw = keyFile.copyBytes();
      try {
        final digest = await Sha256().hash(raw);
        keyFileHash = Uint8List.fromList(digest.bytes);
        wipeList(digest.bytes);
      } finally {
        raw.fillRange(0, raw.length, 0);
      }
    }

    // Belirsizliği önlemek için etiket + uzunluk önekli birleştirme.
    final b = BytesBuilder(copy: false); // iç kopya bırakmaz
    void part(int tag, List<int> data) {
      b.addByte(tag);
      final len = ByteData(4)..setUint32(0, data.length);
      b.add(len.buffer.asUint8List());
      b.add(data);
    }

    password.use((p) => part(1, p));
    secretKey.use((s) => part(2, s));
    if (keyFileHash != null) part(3, keyFileHash);
    final ikm = b.toBytes();
    Uint8List? mixed;
    try {
      mixed = await hkdfSha512(
        ikm: ikm,
        salt: salt,
        info: utf8.encode(CryptoLabels.kdfInput),
        length: 64,
      );
      final kek =
          await runner.derive(input: mixed, salt: salt, params: params);
      return SecretBytes(kek);
    } finally {
      ikm.fillRange(0, ikm.length, 0);
      mixed?.fillRange(0, mixed.length, 0);
      keyFileHash?.fillRange(0, keyFileHash.length, 0);
    }
  }
}
