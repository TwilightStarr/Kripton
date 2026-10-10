// SPDX-License-Identifier: Apache-2.0
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/crypto/crypto_exceptions.dart';
import 'package:quanta/core/crypto/csprng.dart';
import 'package:quanta/core/crypto/record_cipher.dart';
import 'package:quanta/core/crypto/vault_keys.dart';

Matcher failsWith(CryptoFailure k) => throwsA(
    isA<QuantaCryptoException>().having((e) => e.kind, 'kind', k));

void main() {
  late VaultKeys keys;
  late RecordCipher cipher;

  setUp(() async {
    keys = await VaultKeys.derive(Csprng().bytes(32));
    cipher = RecordCipher(keys);
  });
  tearDown(() => keys.dispose());

  Future<Uint8List> seal(Uint8List p,
          {String id = 'rec-1', int schema = 1, String field = 'payload'}) =>
      cipher.seal(
          payload: p, recordId: id, schemaVersion: schema, field: field);
  Future<Uint8List> open(Uint8List b,
          {String id = 'rec-1', int schema = 1, String field = 'payload'}) =>
      cipher.open(
          blob: b, recordId: id, schemaVersion: schema, field: field);

  test('round-trip', () async {
    final p = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
    expect(await open(await seal(p)), p);
  });

  test('JSON round-trip', () async {
    final blob = await cipher.sealJson(
        json: {'u': 'a@b.c', 'p': 'şifre-✓', 'n': 3},
        recordId: 'r',
        schemaVersion: 1,
        field: 'j');
    final j = await cipher.openJson(
        blob: blob, recordId: 'r', schemaVersion: 1, field: 'j');
    expect(j, {'u': 'a@b.c', 'p': 'şifre-✓', 'n': 3});
  });

  test('boş payload ve 256 bayt katı dolgu', () async {
    for (final len in [0, 1, 251, 252, 253, 508, 1000]) {
      final blob = await seal(Uint8List(len));
      expect((blob.length - RecordCipher.overhead) % 256, 0, reason: '$len');
      expect(blob.length >= RecordCipher.overhead + len + 4, isTrue);
      expect((await open(blob)).length, len);
    }
  });

  test('aynı düz metin iki kez farklı blob üretir', () async {
    final p = Uint8List(10);
    expect(await seal(p), isNot(await seal(p)));
  });

  test('blob biçimi: version | nonceOuter | ct | tag', () async {
    final blob = await seal(Uint8List(5));
    expect(blob[0], RecordCipher.blobVersion);
    expect(blob.length, RecordCipher.overhead + 256);
  });

  test('çift katman: iç katman dış katmandan bağımsız doğrular', () async {
    final p = Uint8List.fromList(List.filled(40, 7));
    final blob = await seal(p);
    final aes = AesGcm.with256bits();
    final aadO = RecordAad.outer(
        blobVersion: 1, recordId: 'rec-1', schemaVersion: 1, field: 'payload');
    final outerKey = SecretKey(keys.outer.copyBytes());
    final box = SecretBox(blob.sublist(13, blob.length - 16),
        nonce: blob.sublist(1, 13), mac: Mac(blob.sublist(blob.length - 16)));
    final inner = Uint8List.fromList(
        await aes.decrypt(box, secretKey: outerKey, aad: aadO));
    // iç blob: nonce(24) | ct | tag(16) -> ct içinde tek bit boz
    inner[30] ^= 1;
    final nonce = List<int>.filled(12, 9);
    final re = await aes.encrypt(inner,
        secretKey: outerKey, nonce: nonce, aad: aadO);
    final forged = Uint8List.fromList(
        [1, ...nonce, ...re.cipherText, ...re.mac.bytes]);
    // Dış katman geçerli, iç katman reddetmeli
    expect(open(forged), failsWith(CryptoFailure.authenticationFailed));
  });

  test('her bayttaki tek bit bozulması tespit edilir (version hariç)', () async {
    final blob = await seal(Uint8List.fromList(List.filled(100, 1)));
    for (var i = 1; i < blob.length; i++) {
      final t = Uint8List.fromList(blob)..[i] ^= 0x01;
      await expectLater(open(t), failsWith(CryptoFailure.authenticationFailed),
          reason: 'bayt $i');
    }
    final v = Uint8List.fromList(blob)..[0] ^= 1;
    await expectLater(open(v), failsWith(CryptoFailure.unsupportedVersion));
  });

  test('kesilmiş / uzatılmış blob reddedilir', () async {
    final blob = await seal(Uint8List(10));
    await expectLater(open(Uint8List.sublistView(blob, 0, blob.length - 1)),
        failsWith(CryptoFailure.malformedData));
    await expectLater(open(Uint8List.fromList([...blob, 0])),
        failsWith(CryptoFailure.malformedData));
    await expectLater(open(Uint8List(0)), failsWith(CryptoFailure.malformedData));
  });

  test('AAD uyuşmazlığı: başka id / şema / alan reddedilir', () async {
    final blob = await seal(Uint8List(20));
    await expectLater(open(blob, id: 'rec-2'), failsWith(CryptoFailure.authenticationFailed));
    await expectLater(open(blob, schema: 2), failsWith(CryptoFailure.authenticationFailed));
    await expectLater(open(blob, field: 'notes'), failsWith(CryptoFailure.authenticationFailed));
    expect((await open(blob)).length, 20);
  });

  test('yanlış anahtar reddedilir', () async {
    final blob = await seal(Uint8List(20));
    final other = await VaultKeys.derive(Csprng().bytes(32));
    final c2 = RecordCipher(other);
    await expectLater(
        c2.open(blob: blob, recordId: 'rec-1', schemaVersion: 1, field: 'payload'),
        failsWith(CryptoFailure.authenticationFailed));
    other.dispose();
  });

  test('nonce benzersizliği: 10.000 şifrelemede çakışma yok', () async {
    final outer = <String>{};
    final inner = <String>{};
    final p = Uint8List(8);
    for (var i = 0; i < 10000; i++) {
      final blob = await seal(p, id: 'r$i');
      outer.add(blob.sublist(1, 13).join(','));
      // iç nonce'u görmek için dış katmanı çöz
      final aes = AesGcm.with256bits();
      final aadO = RecordAad.outer(
          blobVersion: 1, recordId: 'r$i', schemaVersion: 1, field: 'payload');
      final box = SecretBox(blob.sublist(13, blob.length - 16),
          nonce: blob.sublist(1, 13), mac: Mac(blob.sublist(blob.length - 16)));
      final ib = await aes.decrypt(box,
          secretKey: SecretKey(keys.outer.copyBytes()), aad: aadO);
      inner.add(ib.sublist(0, 24).join(','));
    }
    expect(outer.length, 10000);
    expect(inner.length, 10000);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('property: rastgele boyut/id/alan round-trip + rastgele bozulma', () async {
    const seed = 20260708;
    final rnd = Random(seed);
    for (var n = 0; n < 150; n++) {
      final len = rnd.nextInt(5000);
      final payload =
          Uint8List.fromList(List.generate(len, (_) => rnd.nextInt(256)));
      final id = 'id-${rnd.nextInt(1 << 30)}';
      final schema = rnd.nextInt(65536);
      final field = 'f${rnd.nextInt(1000)}';
      final blob = await seal(payload, id: id, schema: schema, field: field);
      final msg = 'seed=$seed n=$n len=$len';
      expect(await open(blob, id: id, schema: schema, field: field), payload,
          reason: msg);
      final t = Uint8List.fromList(blob)..[1 + rnd.nextInt(blob.length - 1)] ^= 1 << rnd.nextInt(8);
      await expectLater(open(t, id: id, schema: schema, field: field),
          failsWith(CryptoFailure.authenticationFailed),
          reason: msg);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('alt anahtarlar birbirinden farklı ve 32 bayt', () {
    final all = [keys.outer, keys.inner, keys.index, keys.backup, keys.header]
        .map((k) => k.copyBytes().join(','))
        .toSet();
    expect(all.length, 5);
  });

  test('searchToken belirlenimli ve anahtara bağlı', () async {
    final a = await keys.searchToken(' GitHub ');
    expect(a, await keys.searchToken('github'));
    final other = await VaultKeys.derive(Csprng().bytes(32));
    expect(await other.searchToken('github'), isNot(a));
    other.dispose();
  });
}
