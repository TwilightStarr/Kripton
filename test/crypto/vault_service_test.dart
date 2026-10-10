// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/crypto/bip39.dart';
import 'package:quanta/core/crypto/crypto_exceptions.dart';
import 'package:quanta/core/crypto/csprng.dart';
import 'package:quanta/core/crypto/kdf_params.dart';
import 'package:quanta/core/crypto/secret_key_codec.dart';
import 'package:quanta/core/crypto/vault_header.dart';
import 'package:quanta/core/crypto/vault_service.dart';
import 'package:quanta/core/security/constant_time.dart';
import 'package:quanta/core/security/secret_bytes.dart';

import '../helpers.dart';

Matcher failsWith(CryptoFailure k) => throwsA(
    isA<QuantaCryptoException>().having((e) => e.kind, 'kind', k));

void main() {
  late VaultService svc;
  setUp(() => svc = makeService());

  Future<CreatedVault> create({SecretBytes? keyFile, bool recovery = true}) =>
      svc.createVault(
          password: sb(goodPassword),
          keyFile: keyFile,
          params: testKdf,
          withRecovery: recovery);

  UnlockCredentials creds(CreatedVault c,
          {String password = goodPassword,
          SecretBytes? keyFile,
          SecretBytes? secretKey}) =>
      UnlockCredentials(
          password: sb(password),
          secretKey: secretKey ?? SecretBytes.copyOf(c.secretKey.copyBytes()),
          keyFile: keyFile);

  Future<Uint8List> sealSample(VaultSession s) => s.cipher.seal(
      payload: Uint8List.fromList([1, 2, 3, 4, 5]),
      recordId: 'rec',
      schemaVersion: 1,
      field: 'payload');
  Future<Uint8List> openSample(VaultSession s, Uint8List b) => s.cipher.open(
      blob: b, recordId: 'rec', schemaVersion: 1, field: 'payload');

  test('oluştur -> kilitle -> aç, veri korunur', () async {
    final c = await create();
    final blob = await sealSample(c.session);
    c.session.dispose();
    expect(c.session.isLocked, isTrue);
    final s = await svc.unlock(c.header, creds(c));
    expect(await openSample(s, blob), [1, 2, 3, 4, 5]);
  });

  test('yanlış parola reddedilir', () async {
    final c = await create();
    await expectLater(svc.unlock(c.header, creds(c, password: 'wrong wrong wrong')),
        failsWith(CryptoFailure.authenticationFailed));
  });

  test('yanlış Secret Key reddedilir (hata türü yanlış parolayla AYNI)', () async {
    final c = await create();
    final wrong = SecretKeyCodec.generate(Csprng());
    await expectLater(svc.unlock(c.header, creds(c, secretKey: wrong)),
        failsWith(CryptoFailure.authenticationFailed));
  });

  test('key file: doğru açar; yanlış/eksik/fazla reddedilir', () async {
    final kf = svc.generateKeyFile();
    final c = await create(keyFile: kf);
    final s = await svc.unlock(
        c.header, creds(c, keyFile: SecretBytes.copyOf(kf.copyBytes())));
    expect(s.isLocked, isFalse);

    final wrongKf = svc.generateKeyFile();
    await expectLater(svc.unlock(c.header, creds(c, keyFile: wrongKf)),
        failsWith(CryptoFailure.authenticationFailed));
    await expectLater(svc.unlock(c.header, creds(c)),
        failsWith(CryptoFailure.invalidInput));

    final c2 = await create();
    await expectLater(
        svc.unlock(c2.header, creds(c2, keyFile: svc.generateKeyFile())),
        failsWith(CryptoFailure.invalidInput));
  });

  test('kısa parola ve kısa key file reddedilir', () async {
    await expectLater(
        svc.createVault(password: sb('short'), params: testKdf),
        failsWith(CryptoFailure.invalidInput));
    await expectLater(
        svc.createVault(
            password: sb(goodPassword),
            keyFile: SecretBytes(Uint8List(10)),
            params: testKdf),
        failsWith(CryptoFailure.invalidInput));
  });

  test('ana parola değişimi: eski veri açılır, eski parola artık çalışmaz',
      () async {
    final c = await create();
    final blob = await sealSample(c.session);
    final oldSalt = c.header.salt;

    final next = UnlockCredentials(
        password: sb('yeni-parola-çok-güçlü-123'),
        secretKey: SecretBytes.copyOf(c.secretKey.copyBytes()));
    final h2 = await svc.changeCredentials(
        header: c.header, current: creds(c), next: next);

    expect(constantTimeEquals(h2.salt, oldSalt), isFalse);
    final s = await svc.unlock(h2, next);
    expect(await openSample(s, blob), [1, 2, 3, 4, 5]); // yeniden şifreleme yok
    await expectLater(svc.unlock(h2, creds(c)),
        failsWith(CryptoFailure.authenticationFailed));
  });

  test('kurtarma ifadesiyle açma', () async {
    final c = await create();
    expect(c.recoveryWords.length, 24);
    final blob = await sealSample(c.session);
    final s = await svc.unlockWithRecovery(c.header, c.recoveryWords);
    expect(await openSample(s, blob), [1, 2, 3, 4, 5]);
  });

  test('yanlış / bozuk kurtarma ifadesi reddedilir', () async {
    final c = await create();
    final bad = List<String>.of(c.recoveryWords);
    // son kelimenin sağlama bitini boz (entropi aynı, sağlama farklı)
    final idx = testWords.indexOf(bad.last);
    bad[23] = testWords[idx ^ 1];
    await expectLater(svc.unlockWithRecovery(c.header, bad),
        failsWith(CryptoFailure.recoveryInvalid));
    // geçerli ama başka bir ifade
    final other = await create();
    await expectLater(svc.unlockWithRecovery(c.header, other.recoveryWords),
        failsWith(CryptoFailure.authenticationFailed));
    // kurtarmasız vault
    final nr = await create(recovery: false);
    expect(nr.recoveryWords, isEmpty);
    await expectLater(svc.unlockWithRecovery(nr.header, c.recoveryWords),
        failsWith(CryptoFailure.recoveryInvalid));
  });

  test('parola unutuldu: kurtarma ile sıfırla, eski veri açılır', () async {
    final c = await create();
    final blob = await sealSample(c.session);
    final next = UnlockCredentials(
        password: sb('sıfırlanmış-parola-987654'),
        secretKey: SecretBytes.copyOf(c.secretKey.copyBytes()));
    final h2 = await svc.resetWithRecovery(
        header: c.header, words: c.recoveryWords, next: next);
    final s = await svc.unlock(h2, next);
    expect(await openSample(s, blob), [1, 2, 3, 4, 5]);
    // kurtarma ifadesi parola değişiminden sonra da geçerli kalır
    final s2 = await svc.unlockWithRecovery(h2, c.recoveryWords);
    expect(await openSample(s2, blob), [1, 2, 3, 4, 5]);
  });

  test('KDF downgrade: politika altı parametreler reddedilir', () async {
    final c = await create(); // zayıf (test) parametrelerle üretildi
    final prod = makeService(policy: KdfPolicy.production);
    await expectLater(prod.unlock(c.header, creds(c)),
        failsWith(CryptoFailure.weakParameters));
    await expectLater(
        prod.createVault(password: sb(goodPassword), params: testKdf),
        failsWith(CryptoFailure.weakParameters));
  });

  test('KDF parametre kurcalama: izin verilen aralıkta bile tespit edilir',
      () async {
    final c = await create();
    final tampered = c.header.copyWith(
        kdf: const KdfParams(memoryKiB: 512, iterations: 1, parallelism: 1));
    await expectLater(svc.unlock(tampered, creds(c)),
        failsWith(CryptoFailure.authenticationFailed));
  });

  test('MAC/AAD kapsamı: createdAt (AAD) ve kurtarma sarmalı (MAC) değişikliği reddedilir',
      () async {
    final c = await create();
    // createdAt, parola sarmalının AAD'sine (coreBytes) girer: sarma açılırken düşer.
    await expectLater(
        svc.unlock(c.header.copyWith(createdAtMs: c.header.createdAtMs + 1), creds(c)),
        failsWith(CryptoFailure.authenticationFailed));
    // Kurtarma sarmalı parola sarmalının AAD'sinde YOKTUR: yalnızca başlık MAC'i yakalar.
    final rw = Uint8List.fromList(c.header.recoveryWrappedVmk!)..[0] ^= 1;
    await expectLater(
        svc.unlock(c.header.copyWith(recoveryWrappedVmk: rw), creds(c)),
        failsWith(CryptoFailure.headerTampered));
  });

  test('başlıktaki HER bayttaki tek bit bozulması reddedilir', () async {
    final c = await create();
    final enc = c.header.encode();
    final cr = creds(c);
    for (var i = 0; i < enc.length; i++) {
      final t = Uint8List.fromList(enc)..[i] ^= 0x01;
      await expectLater(
        () async => svc.unlock(VaultHeader.decode(t), cr),
        throwsA(isA<QuantaCryptoException>()),
        reason: 'bayt $i',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('başlık encode/decode round-trip ve sıkı ayrıştırma', () async {
    final c = await create();
    final enc = c.header.encode();
    final d = VaultHeader.decode(enc);
    expect(d.encode(), enc);
    expect(d.kdf, testKdf);
    expect(d.hasRecovery, isTrue);
    expect(() => VaultHeader.decode(Uint8List.sublistView(enc, 0, enc.length - 1)),
        throwsA(isA<QuantaCryptoException>()));
    expect(() => VaultHeader.decode(Uint8List.fromList([...enc, 0])),
        throwsA(isA<QuantaCryptoException>()));
    final nr = await create(recovery: false);
    expect(VaultHeader.decode(nr.header.encode()).hasRecovery, isFalse);
  });

  test('rehash: zayıf parametreler artırılır, eski veri açılır', () async {
    final c = await create();
    final blob = await sealSample(c.session);
    const target = KdfParams(memoryKiB: 512, iterations: 2, parallelism: 1);
    final cr = creds(c);
    final h2 = await svc.rehashIfNeeded(
        header: c.header, credentials: cr, target: target);
    expect(h2, isNotNull);
    expect(h2!.kdf.isAtLeast(target), isTrue);
    final s = await svc.unlock(h2, cr);
    expect(await openSample(s, blob), [1, 2, 3, 4, 5]);
    expect(await svc.rehashIfNeeded(header: h2, credentials: cr, target: target),
        isNull);
  });

  test('Secret Key biçimi, ayrıştırma ve yazım hatası tespiti', () async {
    final k = SecretKeyCodec.generate(Csprng());
    final s = await SecretKeyCodec.format(k);
    expect(RegExp(r'^QNTA(-[2-9A-HJ-NP-Z]{6}){5}$').hasMatch(s), isTrue, reason: s);
    final back = await SecretKeyCodec.parse(s.toLowerCase().replaceAll('-', ' '));
    expect(constantTimeEquals(back.copyBytes(), k.copyBytes()), isTrue);
    // her sembol konumunda tek karakter değişimi yakalanmalı
    final chars = s.split('');
    for (var i = 5; i < chars.length; i++) {
      if (chars[i] == '-') continue;
      final t = List<String>.of(chars);
      t[i] = t[i] == '2' ? '3' : '2';
      await expectLater(SecretKeyCodec.parse(t.join()),
          failsWith(CryptoFailure.invalidInput),
          reason: 'konum $i');
    }
    await expectLater(SecretKeyCodec.parse('QNTA-123'), failsWith(CryptoFailure.invalidInput));
  });

  test('BIP39: round-trip, sağlama, uzunluk, bilinmeyen kelime', () async {
    final bip = Bip39(testWords);
    final rnd = Csprng();
    for (var n = 0; n < 50; n++) {
      final e = rnd.bytes(32);
      final words = await bip.entropyToMnemonic(e);
      expect(words.length, 24);
      expect(await bip.mnemonicToEntropy(words), e);
    }
    final words = await bip.entropyToMnemonic(rnd.bytes(32));
    final bad = List<String>.of(words);
    bad[23] = testWords[testWords.indexOf(bad[23]) ^ 1];
    await expectLater(bip.mnemonicToEntropy(bad), failsWith(CryptoFailure.recoveryInvalid));
    await expectLater(bip.mnemonicToEntropy(words.sublist(0, 23)), failsWith(CryptoFailure.recoveryInvalid));
    await expectLater(bip.mnemonicToEntropy([...words.sublist(0, 23), 'nonexistent']), failsWith(CryptoFailure.recoveryInvalid));
    expect(() => Bip39(testWords.sublist(0, 2047)), throwsArgumentError);
  });

  test('SecretBytes: dispose sıfırlar, toString içerik yazmaz', () {
    final raw = Uint8List.fromList([1, 2, 3, 4]);
    final s = SecretBytes(raw);
    expect(s.toString(), isNot(contains('1')));
    expect(s.toString(), 'SecretBytes(<redacted>)');
    s.dispose();
    expect(raw, [0, 0, 0, 0]);
    expect(s.isDisposed, isTrue);
    expect(() => s.length, throwsStateError);
  });

  test('sabit zamanlı karşılaştırma doğruluğu', () {
    expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
    expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
    expect(constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
    expect(constantTimeEquals([], []), isTrue);
  });

  test('exception metinleri hassas veri içermez', () async {
    final c = await create();
    try {
      await svc.unlock(c.header, creds(c, password: 'wrong wrong wrong'));
      fail('should throw');
    } on QuantaCryptoException catch (e) {
      expect(e.toString(), 'QuantaCryptoException(authenticationFailed)');
    }
  });
}
