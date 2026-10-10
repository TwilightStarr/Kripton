// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/crypto/hex.dart';
import 'package:quanta/core/crypto/hkdf.dart';
import 'package:quanta/core/crypto/kdf_params.dart';
import 'package:quanta/core/crypto/key_derivation.dart';

/// Test içi BAĞIMSIZ HChaCha20 (draft-irtf-cfrg-xchacha §2.2) — yalnızca
/// XChaCha20 çıktısını çapraz doğrulamak için; üretim kodunda KULLANILMAZ.
Uint8List hChaCha20(Uint8List key, Uint8List nonce16) {
  int rotl(int v, int c) => ((v << c) | (v >> (32 - c))) & 0xFFFFFFFF;
  final x = List<int>.filled(16, 0);
  x[0] = 0x61707865;
  x[1] = 0x3320646e;
  x[2] = 0x79622d32;
  x[3] = 0x6b206574;
  final kd = ByteData.sublistView(key);
  final nd = ByteData.sublistView(nonce16);
  for (var i = 0; i < 8; i++) {
    x[4 + i] = kd.getUint32(4 * i, Endian.little);
  }
  for (var i = 0; i < 4; i++) {
    x[12 + i] = nd.getUint32(4 * i, Endian.little);
  }
  void qr(int a, int b, int c, int d) {
    x[a] = (x[a] + x[b]) & 0xFFFFFFFF;
    x[d] = rotl(x[d] ^ x[a], 16);
    x[c] = (x[c] + x[d]) & 0xFFFFFFFF;
    x[b] = rotl(x[b] ^ x[c], 12);
    x[a] = (x[a] + x[b]) & 0xFFFFFFFF;
    x[d] = rotl(x[d] ^ x[a], 8);
    x[c] = (x[c] + x[d]) & 0xFFFFFFFF;
    x[b] = rotl(x[b] ^ x[c], 7);
  }

  for (var i = 0; i < 10; i++) {
    qr(0, 4, 8, 12);
    qr(1, 5, 9, 13);
    qr(2, 6, 10, 14);
    qr(3, 7, 11, 15);
    qr(0, 5, 10, 15);
    qr(1, 6, 11, 12);
    qr(2, 7, 8, 13);
    qr(3, 4, 9, 14);
  }
  final out = ByteData(32);
  for (var i = 0; i < 4; i++) {
    out.setUint32(4 * i, x[i], Endian.little);
    out.setUint32(16 + 4 * i, x[12 + i], Endian.little);
  }
  return out.buffer.asUint8List();
}

/// RFC 5869 §2'yi Hmac üzerinden bağımsız yeniden uygulayan referans.
Future<Uint8List> referenceHkdfSha512(
    List<int> ikm, List<int> salt, List<int> info, int length) async {
  final hmac = Hmac.sha512();
  final realSalt = salt.isEmpty ? List<int>.filled(64, 0) : salt;
  final prk = (await hmac.calculateMac(ikm,
          secretKey: SecretKey(realSalt)))
      .bytes;
  final out = <int>[];
  var t = <int>[];
  var i = 1;
  while (out.length < length) {
    t = (await hmac.calculateMac([...t, ...info, i],
            secretKey: SecretKey(prk)))
        .bytes;
    out.addAll(t);
    i++;
  }
  return Uint8List.fromList(out.sublist(0, length));
}

void main() {
  group('HKDF', () {
    test('RFC 5869 Test Case 1 (HKDF-SHA256, paket uygulaması)', () async {
      final ikm = List<int>.filled(22, 0x0b);
      final salt = fromHex('000102030405060708090a0b0c');
      final info = fromHex('f0f1f2f3f4f5f6f7f8f9');
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 42);
      final okm =
          await hkdf.deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: info);
      expect(
          toHex(await okm.extractBytes()),
          '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
          '34007208d5b887185865');
    });

    test('hkdfSha512 == bağımsız RFC 5869 referansı', () async {
      for (final len in [32, 64, 100]) {
        final ikm = List<int>.generate(33, (i) => (i * 7 + len) & 0xFF);
        final salt = List<int>.generate(16, (i) => i);
        final info = utf8.encode('quanta/v1/test');
        expect(
          await hkdfSha512(ikm: ikm, salt: salt, info: info, length: len),
          await referenceHkdfSha512(ikm, salt, info, len),
        );
      }
      // boş salt
      expect(
        await hkdfSha512(ikm: [1, 2, 3], info: [9], length: 32),
        await referenceHkdfSha512([1, 2, 3], const [], [9], 32),
      );
    });

    test('farklı info -> bağımsız anahtarlar', () async {
      final ikm = List<int>.filled(32, 5);
      final a = await hkdfSha512(
          ikm: ikm, info: utf8.encode('quanta/v1/outer'), length: 32);
      final b = await hkdfSha512(
          ikm: ikm, info: utf8.encode('quanta/v1/inner'), length: 32);
      expect(a, isNot(b));
    });
  });

  group('AES-256-GCM', () {
    test('NIST GCM spec Test Case 14 (K=0^256, IV=0^96, P=0^128)', () async {
      final aes = AesGcm.with256bits();
      final box = await aes.encrypt(
        List<int>.filled(16, 0),
        secretKey: SecretKey(List<int>.filled(32, 0)),
        nonce: List<int>.filled(12, 0),
      );
      expect(toHex(box.cipherText), 'cea7403d4d606b6e074ec5d3baf39d18');
      expect(toHex(box.mac.bytes), 'd0d1c8a799996bf0265b98b5d48ab919');
    });
  });

  group('XChaCha20-Poly1305', () {
    test('HChaCha20 referansı taslak vektörünü üretir', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final nonce = fromHex('000000090000004a0000000031415927');
      expect(toHex(hChaCha20(key, nonce)),
          '82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc');
    });

    test('Xchacha20.poly1305Aead == ChaCha20-Poly1305(HChaCha20 alt anahtarı)',
        () async {
      final key = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final nonce = Uint8List.fromList(List.generate(24, (i) => 0xA0 + i));
      final aad = [1, 2, 3, 4];
      final pt = utf8.encode('Quanta kaskad şifreleme test düz metni');
      final x = await Xchacha20.poly1305Aead()
          .encrypt(pt, secretKey: SecretKey(key), nonce: nonce, aad: aad);
      final sub = hChaCha20(key, Uint8List.fromList(nonce.sublist(0, 16)));
      final c = await Chacha20.poly1305Aead().encrypt(pt,
          secretKey: SecretKey(sub),
          nonce: [0, 0, 0, 0, ...nonce.sublist(16)],
          aad: aad);
      expect(x.cipherText, c.cipherText);
      expect(x.mac.bytes, c.mac.bytes);
    });
  });

  group('Argon2id', () {
    // NOT: RFC 9106 vektörü "secret" ve "associated data" girdileri gerektirir;
    // `cryptography` paketinin Argon2id API'si bunları açmaz. Bu yüzden burada
    // belirlenimlilik ve parametre/girdi duyarlılığı doğrulanır. Üretimde
    // yerel (FFI) bir Argon2 takılırsa RFC 9106 vektörü eklenmelidir.
    const runner = InlineArgon2Runner();
    final input = Uint8List.fromList(List.generate(64, (i) => i));
    final salt = Uint8List.fromList(List.generate(16, (i) => 100 + i));

    test('belirlenimli, 32 bayt', () async {
      final a = await runner.derive(input: input, salt: salt, params: const KdfParams(memoryKiB: 256, iterations: 2, parallelism: 2));
      final b = await runner.derive(input: input, salt: salt, params: const KdfParams(memoryKiB: 256, iterations: 2, parallelism: 2));
      expect(a.length, 32);
      expect(a, b);
    });

    test('salt / girdi / bellek / iterasyon / paralellik çıktıyı değiştirir',
        () async {
      const base = KdfParams(memoryKiB: 256, iterations: 2, parallelism: 2);
      final ref = await runner.derive(input: input, salt: salt, params: base);
      final salt2 = Uint8List.fromList(salt)..[0] ^= 1;
      final in2 = Uint8List.fromList(input)..[0] ^= 1;
      expect(await runner.derive(input: input, salt: salt2, params: base), isNot(ref));
      expect(await runner.derive(input: in2, salt: salt, params: base), isNot(ref));
      expect(await runner.derive(input: input, salt: salt, params: const KdfParams(memoryKiB: 512, iterations: 2, parallelism: 2)), isNot(ref));
      expect(await runner.derive(input: input, salt: salt, params: const KdfParams(memoryKiB: 256, iterations: 3, parallelism: 2)), isNot(ref));
      expect(await runner.derive(input: input, salt: salt, params: const KdfParams(memoryKiB: 256, iterations: 2, parallelism: 1)), isNot(ref));
    });
  });
}
