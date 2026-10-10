// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import 'crypto_exceptions.dart';
import 'hex.dart';

/// Standart BIP39 İngilizce listesiyle 256-bit entropi <-> 24 kelime.
/// (PBKDF2 tohum üretimi YAPILMAZ: ifade doğrudan 256-bit anahtar malzemesidir.)
class Bip39 {
  Bip39(List<String> words)
      : _words = List<String>.unmodifiable(words),
        _index = {for (var i = 0; i < words.length; i++) words[i]: i} {
    if (words.length != 2048 || _index.length != 2048) {
      throw ArgumentError('wordlist must contain 2048 unique words');
    }
  }

  static const assetPath = 'assets/wordlists/bip39_english.txt';

  /// bitcoin/bips english.txt dosyasının SHA-256'sı (ham bayt).
  /// tool/fetch_assets.sh bu değeri indirme sırasında doğrular;
  /// uyuşmuyorsa değeri değiştirmeden önce kaynağı kontrol edin.
  static const expectedSha256Hex =
      '2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda';

  static Future<Bip39> loadFromAssets({AssetBundle? bundle}) async {
    final data = await (bundle ?? rootBundle).load(assetPath);
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final digest = await Sha256().hash(bytes);
    if (toHex(digest.bytes) != expectedSha256Hex) {
      throw const QuantaCryptoException(CryptoFailure.malformedData);
    }
    final words = const LineSplitter()
        .convert(utf8.decode(bytes))
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty)
        .toList();
    return Bip39(words);
  }

  final List<String> _words;
  final Map<String, int> _index;

  Future<List<String>> entropyToMnemonic(Uint8List entropy) async {
    if (entropy.length != 32) {
      throw const QuantaCryptoException(CryptoFailure.invalidInput);
    }
    final checksum = (await Sha256().hash(entropy)).bytes[0]; // 256/32 = 8 bit
    final all = Uint8List(33)
      ..setRange(0, 32, entropy)
      ..[32] = checksum;
    final out = <String>[];
    for (var i = 0; i < 24; i++) {
      var idx = 0;
      for (var b = 0; b < 11; b++) {
        final pos = i * 11 + b;
        idx = (idx << 1) | ((all[pos >> 3] >> (7 - (pos & 7))) & 1);
      }
      out.add(_words[idx]);
    }
    all.fillRange(0, all.length, 0);
    return out;
  }

  /// Geçersiz uzunluk / bilinmeyen kelime / sağlama hatası -> recoveryInvalid.
  Future<Uint8List> mnemonicToEntropy(List<String> words) async {
    const bad = QuantaCryptoException(CryptoFailure.recoveryInvalid);
    if (words.length != 24) throw bad;
    final all = Uint8List(33);
    for (var i = 0; i < 24; i++) {
      final idx = _index[words[i].trim().toLowerCase()];
      if (idx == null) {
        all.fillRange(0, all.length, 0);
        throw bad;
      }
      for (var b = 0; b < 11; b++) {
        if (((idx >> (10 - b)) & 1) == 1) {
          final pos = i * 11 + b;
          all[pos >> 3] |= 1 << (7 - (pos & 7));
        }
      }
    }
    final entropy = Uint8List.fromList(all.sublist(0, 32));
    final expected = (await Sha256().hash(entropy)).bytes[0];
    final ok = expected == all[32];
    all.fillRange(0, all.length, 0);
    if (!ok) {
      entropy.fillRange(0, entropy.length, 0);
      throw bad;
    }
    return entropy;
  }
}
