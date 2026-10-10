// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_exceptions.dart';
import 'crypto_labels.dart';
import 'csprng.dart';
import 'vault_keys.dart';

/// AAD üreticileri. Kayıt id + şema sürümü + alan adı bağlanır; blob başka
/// satıra/alana taşınırsa doğrulama başarısız olur. Katmanlar ayrı alanlardır.
abstract final class RecordAad {
  static Uint8List _build(String layer, int blobVersion, String recordId,
      int schemaVersion, String field) {
    if (schemaVersion < 0 || schemaVersion > 0xFFFF) {
      throw const QuantaCryptoException(CryptoFailure.invalidInput);
    }
    final b = BytesBuilder();
    void lp(List<int> x) {
      if (x.length > 0xFFFF) {
        throw const QuantaCryptoException(CryptoFailure.invalidInput);
      }
      b.addByte(x.length >> 8);
      b.addByte(x.length & 0xFF);
      b.add(x);
    }

    lp(utf8.encode(CryptoLabels.record));
    lp(utf8.encode(layer));
    b.addByte(blobVersion);
    lp(utf8.encode(recordId));
    b.addByte(schemaVersion >> 8);
    b.addByte(schemaVersion & 0xFF);
    lp(utf8.encode(field));
    return b.toBytes();
  }

  static Uint8List outer(
          {required int blobVersion,
          required String recordId,
          required int schemaVersion,
          required String field}) =>
      _build('outer', blobVersion, recordId, schemaVersion, field);

  static Uint8List inner(
          {required int blobVersion,
          required String recordId,
          required int schemaVersion,
          required String field}) =>
      _build('inner', blobVersion, recordId, schemaVersion, field);
}

/// Kaskad: padding -> XChaCha20-Poly1305 (K_inner) -> AES-256-GCM (K_outer).
///
/// Blob: [version(1) | nonceOuter(12) | ciphertextOuter | tagOuter(16)]
///   ciphertextOuter = [nonceInner(24) | ciphertextInner | tagInner(16)]
///   plaintextInner  = [len(4, BE) | payload | rastgele dolgu]  (256 bayt katı)
class RecordCipher {
  RecordCipher(this._keys, {Csprng? random}) : _random = random ?? Csprng();

  static const int blobVersion = 1;
  static const int padBlock = 256;
  static const int maxPayload = 16 * 1024 * 1024;
  static const int _outerNonce = 12, _innerNonce = 24, _tag = 16;

  /// Sabit yük (version + nonceOuter + tagOuter + nonceInner + tagInner)
  static const int overhead = 1 + _outerNonce + _tag + _innerNonce + _tag;

  final VaultKeys _keys;
  final Csprng _random;
  final AesGcm _aes = AesGcm.with256bits();
  final Xchacha20 _xchacha = Xchacha20.poly1305Aead();

  Uint8List _pad(Uint8List payload) {
    final total = ((4 + payload.length + padBlock - 1) ~/ padBlock) * padBlock;
    final buf = _random.bytes(total); // dolgu rastgele
    ByteData.sublistView(buf).setUint32(0, payload.length);
    buf.setRange(4, 4 + payload.length, payload);
    return buf;
  }

  Uint8List _unpad(Uint8List buf) {
    if (buf.length < 4 || buf.length % padBlock != 0) {
      throw const QuantaCryptoException(CryptoFailure.malformedData);
    }
    final len = ByteData.sublistView(buf).getUint32(0);
    if (len > buf.length - 4) {
      throw const QuantaCryptoException(CryptoFailure.malformedData);
    }
    return Uint8List.fromList(buf.sublist(4, 4 + len));
  }

  Future<Uint8List> seal({
    required Uint8List payload,
    required String recordId,
    required int schemaVersion,
    required String field,
  }) async {
    if (payload.length > maxPayload) {
      throw const QuantaCryptoException(CryptoFailure.invalidInput);
    }
    final aadInner = RecordAad.inner(
        blobVersion: blobVersion,
        recordId: recordId,
        schemaVersion: schemaVersion,
        field: field);
    final aadOuter = RecordAad.outer(
        blobVersion: blobVersion,
        recordId: recordId,
        schemaVersion: schemaVersion,
        field: field);

    final padded = _pad(payload);
    Uint8List? innerBlob;
    try {
      final nInner = _random.bytes(_innerNonce); // her seferinde yeni nonce
      final innerBox = await _xchacha.encrypt(
        padded,
        secretKey: _keys.inner.use((b) => SecretKeyData(b)),
        nonce: nInner,
        aad: aadInner,
      );
      innerBlob = (BytesBuilder(copy: false)
            ..add(nInner)
            ..add(innerBox.cipherText)
            ..add(innerBox.mac.bytes))
          .toBytes();

      final nOuter = _random.bytes(_outerNonce);
      final outerBox = await _aes.encrypt(
        innerBlob,
        secretKey: _keys.outer.use((b) => SecretKeyData(b)),
        nonce: nOuter,
        aad: aadOuter,
      );
      return (BytesBuilder(copy: false)
            ..addByte(blobVersion)
            ..add(nOuter)
            ..add(outerBox.cipherText)
            ..add(outerBox.mac.bytes))
          .toBytes();
    } finally {
      padded.fillRange(0, padded.length, 0);
      innerBlob?.fillRange(0, innerBlob.length, 0);
    }
  }

  /// Dönen tamponu sıfırlamak çağıranın görevidir.
  Future<Uint8List> open({
    required Uint8List blob,
    required String recordId,
    required int schemaVersion,
    required String field,
  }) async {
    if (blob.isEmpty) {
      throw const QuantaCryptoException(CryptoFailure.malformedData);
    }
    if (blob[0] != blobVersion) {
      throw const QuantaCryptoException(CryptoFailure.unsupportedVersion);
    }
    const minLen = overhead + padBlock;
    if (blob.length < minLen ||
        blob.length > overhead + 4 + maxPayload + padBlock ||
        (blob.length - overhead) % padBlock != 0) {
      throw const QuantaCryptoException(CryptoFailure.malformedData);
    }
    final aadInner = RecordAad.inner(
        blobVersion: blobVersion,
        recordId: recordId,
        schemaVersion: schemaVersion,
        field: field);
    final aadOuter = RecordAad.outer(
        blobVersion: blobVersion,
        recordId: recordId,
        schemaVersion: schemaVersion,
        field: field);

    Uint8List? innerBlob;
    Uint8List? padded;
    try {
      final outerBox = SecretBox(
        blob.sublist(1 + _outerNonce, blob.length - _tag),
        nonce: blob.sublist(1, 1 + _outerNonce),
        mac: Mac(blob.sublist(blob.length - _tag)),
      );
      try {
        innerBlob = Uint8List.fromList(await _aes.decrypt(
          outerBox,
          secretKey: _keys.outer.use((b) => SecretKeyData(b)),
          aad: aadOuter,
        ));
      } catch (_) {
        throw const QuantaCryptoException(CryptoFailure.authenticationFailed);
      }
      final innerBox = SecretBox(
        innerBlob.sublist(_innerNonce, innerBlob.length - _tag),
        nonce: innerBlob.sublist(0, _innerNonce),
        mac: Mac(innerBlob.sublist(innerBlob.length - _tag)),
      );
      try {
        padded = Uint8List.fromList(await _xchacha.decrypt(
          innerBox,
          secretKey: _keys.inner.use((b) => SecretKeyData(b)),
          aad: aadInner,
        ));
      } catch (_) {
        throw const QuantaCryptoException(CryptoFailure.authenticationFailed);
      }
      return _unpad(padded);
    } finally {
      innerBlob?.fillRange(0, innerBlob.length, 0);
      padded?.fillRange(0, padded.length, 0);
    }
  }

  /// Kolaylık: JSON payload. (Çözülmüş Map/String'ler Dart'ta sıfırlanamaz.)
  Future<Uint8List> sealJson({
    required Map<String, Object?> json,
    required String recordId,
    required int schemaVersion,
    required String field,
  }) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    return seal(
            payload: bytes,
            recordId: recordId,
            schemaVersion: schemaVersion,
            field: field)
        .whenComplete(() => bytes.fillRange(0, bytes.length, 0));
  }

  Future<Map<String, Object?>> openJson({
    required Uint8List blob,
    required String recordId,
    required int schemaVersion,
    required String field,
  }) async {
    final bytes = await open(
        blob: blob,
        recordId: recordId,
        schemaVersion: schemaVersion,
        field: field);
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, Object?>) {
        throw const QuantaCryptoException(CryptoFailure.malformedData);
      }
      return decoded;
    } on FormatException {
      throw const QuantaCryptoException(CryptoFailure.malformedData);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }
}
