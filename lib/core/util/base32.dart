// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

/// RFC 4648 Base32 (TOTP sırları için). Çözümlemede boşluk, '-' ve '=' yok sayılır,
/// büyük/küçük harf fark etmez.
abstract final class Base32 {
  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static String encode(List<int> bytes, {bool padding = false}) {
    final sb = StringBuffer();
    var buffer = 0, bits = 0;
    for (final b in bytes) {
      buffer = (buffer << 8) | (b & 0xFF);
      bits += 8;
      while (bits >= 5) {
        sb.write(_alphabet[(buffer >> (bits - 5)) & 31]);
        bits -= 5;
      }
      buffer &= (1 << bits) - 1;
    }
    if (bits > 0) sb.write(_alphabet[(buffer << (5 - bits)) & 31]);
    if (padding) {
      while (sb.length % 8 != 0) {
        sb.write('=');
      }
    }
    return sb.toString();
  }

  /// Geçersiz karakter / geçersiz uzunlukta [FormatException].
  static Uint8List decode(String input) {
    final clean = input.toUpperCase().replaceAll(RegExp(r'[\s\-=]'), '');
    if (clean.isEmpty) throw const FormatException('empty base32');
    final rem = clean.length % 8;
    if (rem == 1 || rem == 3 || rem == 6) {
      throw const FormatException('invalid base32 length');
    }
    final out = <int>[];
    var buffer = 0, bits = 0;
    for (var i = 0; i < clean.length; i++) {
      final v = _alphabet.indexOf(clean[i]);
      if (v < 0) throw const FormatException('invalid base32 character');
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        out.add((buffer >> (bits - 8)) & 0xFF);
        bits -= 8;
        buffer &= (1 << bits) - 1;
      }
    }
    return Uint8List.fromList(out);
  }
}
