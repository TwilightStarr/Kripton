// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../security/constant_time.dart';
import '../security/secret_bytes.dart';
import 'bip39.dart';
import 'crypto_exceptions.dart';
import 'crypto_labels.dart';
import 'csprng.dart';
import 'hkdf.dart';
import 'kdf_params.dart';
import 'key_derivation.dart';
import 'record_cipher.dart';
import 'secret_key_codec.dart';
import 'vault_header.dart';
import 'vault_keys.dart';

/// Açma kimlik bilgileri. Sahibi çağıran: iş bitince [dispose] çağırın.
class UnlockCredentials {
  UnlockCredentials({required this.password, required this.secretKey, this.keyFile});

  final SecretBytes password; // UTF-8
  final SecretBytes secretKey; // 16 ham bayt
  final SecretBytes? keyFile;

  void dispose() {
    password.dispose();
    secretKey.dispose();
    keyFile?.dispose();
  }
}

/// Açık vault oturumu: yalnızca alt anahtarlar tutulur (VMK tutulmaz).
class VaultSession {
  VaultSession(this.keys, {Csprng? random})
      : cipher = RecordCipher(keys, random: random);
  final VaultKeys keys;
  final RecordCipher cipher;
  bool get isLocked => keys.isDisposed;
  void dispose() => keys.dispose();
}

class CreatedVault {
  CreatedVault({
    required this.header,
    required this.session,
    required this.secretKey,
    required this.recoveryWords,
  });
  final VaultHeader header;
  final VaultSession session;

  /// Kullanıcıya BİR KEZ gösterilir (SecretKeyCodec.format), sonra dispose edin.
  final SecretBytes secretKey;

  /// 24 kelime; boşsa kurtarma kapalı. Gösterip bırakın.
  final List<String> recoveryWords;
}

class _Unlocked {
  _Unlocked(this.vmk, this.keys);
  final Uint8List vmk;
  final VaultKeys keys;
  void zeroVmk() => vmk.fillRange(0, vmk.length, 0);
}

class VaultService {
  VaultService({
    required Bip39 bip39,
    KeyDerivation? kdf,
    Csprng? random,
    DateTime Function()? clock,
  })  : _bip39 = bip39,
        _kdf = kdf ?? KeyDerivation(),
        _random = random ?? Csprng(),
        _clock = clock ?? DateTime.now;

  static const int minPasswordLength = 12;
  static const int minKeyFileBytes = 64;

  final Bip39 _bip39;
  final KeyDerivation _kdf;
  final Csprng _random;
  final DateTime Function() _clock;
  final Xchacha20 _xchacha = Xchacha20.poly1305Aead();

  // ---------------------------------------------------------------- create

  Future<CreatedVault> createVault({
    required SecretBytes password,
    SecretBytes? keyFile,
    KdfParams? params,
    bool withRecovery = true,
  }) async {
    _checkPassword(password);
    _checkKeyFile(keyFile);
    final p = params ?? KdfParams.production;
    _kdf.policy.validate(p);

    final secretKey = SecretKeyCodec.generate(_random);
    final vmk = _random.bytes(32);
    Uint8List? entropy;
    try {
      var header = VaultHeader(
        formatVersion: VaultHeader.currentFormat,
        createdAtMs: _clock().millisecondsSinceEpoch,
        keyFileRequired: keyFile != null,
        kdf: p,
        salt: _random.bytes(VaultHeader.saltLength),
        wrappedVmk: Uint8List(VaultHeader.wrappedLength), // yer tutucu
        recoveryWrappedVmk:
            withRecovery ? Uint8List(VaultHeader.wrappedLength) : null,
        mac: Uint8List(VaultHeader.macLength),
      );

      final kek = await _kdf.deriveKek(
          password: password,
          secretKey: secretKey,
          keyFile: keyFile,
          salt: header.salt,
          params: p);
      final wrapped = await _wrapAndDispose(kek, vmk, _passwordWrapAad(header));
      header = header.copyWith(wrappedVmk: wrapped);

      var words = <String>[];
      if (withRecovery) {
        entropy = _random.bytes(32);
        words = await _bip39.entropyToMnemonic(entropy);
        final krec = await _recoveryKek(entropy);
        header = header.copyWith(
            recoveryWrappedVmk:
                await _wrapAndDispose(krec, vmk, _recoveryWrapAad()));
      }

      final keys = await VaultKeys.derive(vmk);
      header = header.copyWith(mac: await _mac(keys, header));
      return CreatedVault(
        header: header,
        session: VaultSession(keys, random: _random),
        secretKey: secretKey,
        recoveryWords: words,
      );
    } catch (_) {
      secretKey.dispose();
      rethrow;
    } finally {
      vmk.fillRange(0, vmk.length, 0);
      entropy?.fillRange(0, entropy.length, 0);
    }
  }

  // ---------------------------------------------------------------- unlock

  Future<VaultSession> unlock(
      VaultHeader header, UnlockCredentials credentials) async {
    final u = await _unlockVmk(header, credentials);
    u.zeroVmk();
    return VaultSession(u.keys, random: _random);
  }

  Future<VaultSession> unlockWithRecovery(
      VaultHeader header, List<String> words) async {
    final u = await _unlockVmkWithRecovery(header, words);
    u.zeroVmk();
    return VaultSession(u.keys, random: _random);
  }

  // ------------------------------------------------- rewrap (parola/rehash)

  /// Ana parola / Secret Key / key file değişimi veya KDF parametre artırımı.
  /// Yalnızca KEK yeniden türetilir, VMK yeniden sarılır; veri yeniden şifrelenmez.
  /// Eski kimlik bilgileriyle yeniden doğrulama gerekir (VMK oturumda tutulmaz).
  Future<VaultHeader> changeCredentials({
    required VaultHeader header,
    required UnlockCredentials current,
    required UnlockCredentials next,
    KdfParams? newParams,
  }) async {
    final u = await _unlockVmk(header, current);
    try {
      return await _rewrap(header, u, next, newParams ?? header.kdf);
    } finally {
      u.zeroVmk();
      u.keys.dispose();
    }
  }

  /// Parola unutulduysa: kurtarma ifadesiyle aç, yeni kimlik bilgileriyle yeniden sar.
  Future<VaultHeader> resetWithRecovery({
    required VaultHeader header,
    required List<String> words,
    required UnlockCredentials next,
    KdfParams? newParams,
  }) async {
    final u = await _unlockVmkWithRecovery(header, words);
    try {
      return await _rewrap(header, u, next, newParams ?? header.kdf);
    } finally {
      u.zeroVmk();
      u.keys.dispose();
    }
  }

  /// Başlıktaki KDF parametreleri [target]'tan zayıfsa artırır; değilse null.
  Future<VaultHeader?> rehashIfNeeded({
    required VaultHeader header,
    required UnlockCredentials credentials,
    required KdfParams target,
  }) async {
    if (header.kdf.isAtLeast(target)) return null;
    final stronger = KdfParams(
      memoryKiB: header.kdf.memoryKiB > target.memoryKiB
          ? header.kdf.memoryKiB
          : target.memoryKiB,
      iterations: header.kdf.iterations > target.iterations
          ? header.kdf.iterations
          : target.iterations,
      parallelism: header.kdf.parallelism > target.parallelism
          ? header.kdf.parallelism
          : target.parallelism,
    );
    return changeCredentials(
        header: header,
        current: credentials,
        next: credentials,
        newParams: stronger);
  }

  // --------------------------------------------------------------- internals

  Future<VaultHeader> _rewrap(VaultHeader header, _Unlocked u,
      UnlockCredentials next, KdfParams params) async {
    _checkPassword(next.password);
    _checkKeyFile(next.keyFile);
    _kdf.policy.validate(params);

    var h = header.copyWith(
      kdf: params,
      salt: _random.bytes(VaultHeader.saltLength), // her seferinde yeni salt
      keyFileRequired: next.keyFile != null,
    );
    final kek = await _kdf.deriveKek(
        password: next.password,
        secretKey: next.secretKey,
        keyFile: next.keyFile,
        salt: h.salt,
        params: params);
    h = h.copyWith(
        wrappedVmk: await _wrapAndDispose(kek, u.vmk, _passwordWrapAad(h)));
    return h.copyWith(mac: await _mac(u.keys, h));
  }

  void _checkHeaderBasics(VaultHeader h) {
    if (h.formatVersion != VaultHeader.currentFormat) {
      throw const QuantaCryptoException(CryptoFailure.unsupportedVersion);
    }
    if (h.salt.length != VaultHeader.saltLength ||
        h.wrappedVmk.length != VaultHeader.wrappedLength ||
        h.mac.length != VaultHeader.macLength ||
        (h.recoveryWrappedVmk != null &&
            h.recoveryWrappedVmk!.length != VaultHeader.wrappedLength)) {
      throw const QuantaCryptoException(CryptoFailure.malformedData);
    }
  }

  Future<_Unlocked> _unlockVmk(
      VaultHeader header, UnlockCredentials creds) async {
    _checkHeaderBasics(header);
    _kdf.policy.validate(header.kdf); // downgrade + DoS savunması, KDF'den ÖNCE
    if (header.keyFileRequired != (creds.keyFile != null)) {
      throw const QuantaCryptoException(CryptoFailure.invalidInput);
    }
    final kek = await _kdf.deriveKek(
        password: creds.password,
        secretKey: creds.secretKey,
        keyFile: creds.keyFile,
        salt: header.salt,
        params: header.kdf);
    final vmk = await _unwrapAndDispose(
        kek, header.wrappedVmk, _passwordWrapAad(header));
    return _finishUnlock(header, vmk);
  }

  Future<_Unlocked> _unlockVmkWithRecovery(
      VaultHeader header, List<String> words) async {
    _checkHeaderBasics(header);
    final rw = header.recoveryWrappedVmk;
    if (rw == null) {
      throw const QuantaCryptoException(CryptoFailure.recoveryInvalid);
    }
    final entropy = await _bip39.mnemonicToEntropy(words);
    Uint8List vmk;
    try {
      final krec = await _recoveryKek(entropy);
      vmk = await _unwrapAndDispose(krec, rw, _recoveryWrapAad());
    } finally {
      entropy.fillRange(0, entropy.length, 0);
    }
    return _finishUnlock(header, vmk);
  }

  Future<_Unlocked> _finishUnlock(VaultHeader header, Uint8List vmk) async {
    final keys = await VaultKeys.derive(vmk);
    final expected = await _mac(keys, header);
    if (!constantTimeEquals(expected, header.mac)) {
      keys.dispose();
      vmk.fillRange(0, vmk.length, 0);
      throw const QuantaCryptoException(CryptoFailure.headerTampered);
    }
    return _Unlocked(vmk, keys);
  }

  Future<Uint8List> _mac(VaultKeys keys, VaultHeader header) async {
    final mac = await Hmac.sha256().calculateMac(
      header.macInput(),
      secretKey: keys.header.use((b) => SecretKeyData(b)),
    );
    return Uint8List.fromList(mac.bytes);
  }

  Future<SecretBytes> _recoveryKek(Uint8List entropy) async => SecretBytes(
      await hkdfSha512(
          ikm: entropy,
          info: utf8.encode(CryptoLabels.recoveryKek),
          length: 32));

  /// Parola sarmalının AAD'si: değişken alanlar (KDF parametreleri, salt,
  /// bayraklar) bağlanır; kurcalama KEK/etiket hatasıyla düşer.
  Uint8List _passwordWrapAad(VaultHeader h) => Uint8List.fromList(
      [...utf8.encode(CryptoLabels.wrapVmk), ...h.coreBytes()]);

  /// Kurtarma sarmalının AAD'si SABİT alanlardır (magic+sürüm): parola/KDF
  /// değişince kurtarma sarmalı yeniden yazılamaz (entropi elde yok).
  /// Bütünlüğü başlık MAC'i sağlar.
  Uint8List _recoveryWrapAad() => Uint8List.fromList([
        ...utf8.encode(CryptoLabels.wrapVmkRecovery),
        ...VaultHeader.magic,
        VaultHeader.currentFormat,
      ]);

  Future<Uint8List> _wrapAndDispose(
      SecretBytes key, Uint8List vmk, Uint8List aad) async {
    try {
      final nonce = _random.bytes(24);
      final box = await _xchacha.encrypt(vmk,
          secretKey: key.use((b) => SecretKeyData(b)), nonce: nonce, aad: aad);
      return (BytesBuilder(copy: false)
            ..add(nonce)
            ..add(box.cipherText)
            ..add(box.mac.bytes))
          .toBytes();
    } finally {
      key.dispose();
    }
  }

  Future<Uint8List> _unwrapAndDispose(
      SecretBytes key, Uint8List wrapped, Uint8List aad) async {
    try {
      final box = SecretBox(
        wrapped.sublist(24, wrapped.length - 16),
        nonce: wrapped.sublist(0, 24),
        mac: Mac(wrapped.sublist(wrapped.length - 16)),
      );
      return Uint8List.fromList(await _xchacha.decrypt(box,
          secretKey: key.use((b) => SecretKeyData(b)), aad: aad));
    } catch (_) {
      throw const QuantaCryptoException(CryptoFailure.authenticationFailed);
    } finally {
      key.dispose();
    }
  }

  void _checkPassword(SecretBytes password) {
    final raw = password.copyBytes();
    final int length;
    try {
      // Not: geçici Dart String'i bellekte sıfırlanamaz (README'ye bakın).
      length = utf8.decode(raw, allowMalformed: true).runes.length;
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
    if (length < minPasswordLength) {
      throw const QuantaCryptoException(CryptoFailure.invalidInput);
    }
  }

  void _checkKeyFile(SecretBytes? keyFile) {
    if (keyFile != null && keyFile.length < minKeyFileBytes) {
      throw const QuantaCryptoException(CryptoFailure.invalidInput);
    }
  }

  /// 64 bayt rastgele key file içeriği üretir (dosyaya yazmak UI/storage'ın işi).
  SecretBytes generateKeyFile() => SecretBytes(_random.bytes(64));
}
