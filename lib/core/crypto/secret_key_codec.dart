// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../security/constant_time.dart';
import '../security/secret_bytes.dart';
import 'crypto_exceptions.dart';
import 'crypto_labels.dart';
import 'csprng.dart';

/// Secret Key: 128-bit rastgele değer.
/// Biçim: QNTA-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX
///   26 karakter veri (128 bit + 2 sıfır dolgu biti) + 4 karakter sağlama (20 bit)
///   = 30 karakter, 5 grup. Alfabe 32 simge: 0/1/I/O yok (karışmasın).
/// Sağlama yalnızca yazım hatasını yakalar; güvenlik özelliği DEĞİLDİR.
abstract final class SecretKeyCodec {
  static const prefix = 'QNTA';
  static const _alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

  static SecretBytes generate(Csprng random) => SecretBytes(random.bytes(16));

  static String _base32(List<int> bytes) {
    var buffer = 0, bits = 0;
    final sb = StringBuffer();
    for (final b in bytes) {
      buffer = (buffer << 8) | b;
      bits += 8;
      while (bits >= 5) {
        sb.write(_alphabet[(buffer >> (bits - 5)) & 31]);
        bits -= 5;
      }
      buffer &= (1 << bits) - 1;
    }
    if (bits > 0) sb.write(_alphabet[(buffer << (5 - bits)) & 31]);
    return sb.toString();
  }

  static Uint8List? _decode(String chars) {
    var buffer = 0, bits = 0;
    final out = <int>[];
    for (final ch in chars.split('')) {
      final v = _alphabet.indexOf(ch);
      if (v < 0) return null;
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        out.add((buffer >> (bits - 8)) & 0xFF);
        bits -= 8;
        buffer &= (1 << bits) - 1;
      }
    }
    if (out.length != 16 || bits != 2 || buffer != 0) return null;
    return Uint8List.fromList(out);
  }

  static Future<String> _check(List<int> raw) async {
    final h = await Sha256().hash([...utf8.encode(CryptoLabels.secretKeyCheck), ...raw]);
    return _base32(h.bytes.sublist(0, 3)).substring(0, 4);
  }

  /// Kullanıcıya bir kez gösterilecek biçim. (Dönen String Dart'ta
  /// sıfırlanamaz; ekrandan çıkınca referansı bırakın.)
  static Future<String> format(SecretBytes key) async {
    final raw = key.copyBytes();
    try {
      final body = _base32(raw) + await _check(raw);
      final groups = [for (var i = 0; i < 30; i += 6) body.substring(i, i + 6)];
      return '$prefix-${groups.join('-')}';
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
  }

  static Future<SecretBytes> parse(String input) async {
    const bad = QuantaCryptoException(CryptoFailure.invalidInput);
    final s = input.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (!s.startsWith(prefix) || s.length != prefix.length + 30) throw bad;
    final body = s.substring(prefix.length);
    final raw = _decode(body.substring(0, 26));
    if (raw == null) throw bad;
    final expected = await _check(raw);
    if (!constantTimeEquals(utf8.encode(expected), utf8.encode(body.substring(26)))) {
      raw.fillRange(0, raw.length, 0);
      throw bad;
    }
    return SecretBytes(raw);
  }
}
