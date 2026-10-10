// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/util/base32.dart';

enum TotpAlgorithm {
  sha1('SHA1'),
  sha256('SHA256'),
  sha512('SHA512');

  const TotpAlgorithm(this.wireName);
  final String wireName;

  Hmac get hmac => switch (this) {
        TotpAlgorithm.sha1 => Hmac.sha1(),
        TotpAlgorithm.sha256 => Hmac.sha256(),
        TotpAlgorithm.sha512 => Hmac.sha512(),
      };

  static TotpAlgorithm parse(String s) {
    final u = s.toUpperCase().replaceAll('-', '');
    for (final a in values) {
      if (a.wireName == u) return a;
    }
    throw FormatException('unsupported TOTP algorithm: $s');
  }
}

/// RFC 6238 yapılandırması. Desteklenen: SHA1/SHA256/SHA512, 6-8 hane, 30/60 sn.
class TotpConfig {
  TotpConfig({
    required this.secret,
    this.algorithm = TotpAlgorithm.sha1,
    this.digits = 6,
    this.period = 30,
    this.issuer = '',
    this.account = '',
  }) {
    if (secret.length < minSecretBytes) {
      throw const FormatException('TOTP secret too short');
    }
    if (digits < 6 || digits > 8) {
      throw const FormatException('digits must be 6..8');
    }
    if (!allowedPeriods.contains(period)) {
      throw const FormatException('period must be 30 or 60');
    }
  }

  static const int minSecretBytes = 10;
  static const Set<int> allowedPeriods = {30, 60};

  final Uint8List secret;
  final TotpAlgorithm algorithm;
  final int digits;
  final int period;
  final String issuer;
  final String account;

  factory TotpConfig.fromBase32(String base32Secret,
          {TotpAlgorithm algorithm = TotpAlgorithm.sha1,
          int digits = 6,
          int period = 30,
          String issuer = '',
          String account = ''}) =>
      TotpConfig(
          secret: Base32.decode(base32Secret),
          algorithm: algorithm,
          digits: digits,
          period: period,
          issuer: issuer,
          account: account);

  /// `otpauth://totp/Issuer:account?secret=...&issuer=...&algorithm=SHA1&digits=6&period=30`.
  /// HOTP ve geçersiz parametreler [FormatException] fırlatır.
  static TotpConfig parseUri(String input) {
    final Uri u;
    try {
      u = Uri.parse(input.trim());
    } on FormatException {
      throw const FormatException('invalid otpauth URI');
    }
    if (u.scheme.toLowerCase() != 'otpauth') {
      throw const FormatException('not an otpauth URI');
    }
    final type = u.host.toLowerCase();
    if (type != 'totp') {
      throw FormatException(
          type == 'hotp' ? 'HOTP is not supported' : 'unknown otpauth type');
    }
    final q = {
      for (final e in u.queryParameters.entries) e.key.toLowerCase(): e.value
    };
    final secret = q['secret'];
    if (secret == null || secret.isEmpty) {
      throw const FormatException('missing secret');
    }
    var label = u.path.startsWith('/') ? u.path.substring(1) : u.path;
    try {
      label = Uri.decodeComponent(label);
    } on ArgumentError {
      throw const FormatException('invalid label');
    }
    var issuer = '';
    var account = label.trim();
    final colon = label.indexOf(':');
    if (colon >= 0) {
      issuer = label.substring(0, colon).trim();
      account = label.substring(colon + 1).trim();
    }
    final qi = q['issuer'];
    if (qi != null && qi.isNotEmpty) issuer = qi;
    int intParam(String k, int def) {
      final v = q[k];
      if (v == null) return def;
      return int.tryParse(v) ?? (throw FormatException('invalid $k'));
    }

    return TotpConfig(
      secret: Base32.decode(secret),
      algorithm: TotpAlgorithm.parse(q['algorithm'] ?? 'SHA1'),
      digits: intParam('digits', 6),
      period: intParam('period', 30),
      issuer: issuer,
      account: account,
    );
  }

  String toUri() {
    final label = issuer.isEmpty
        ? Uri.encodeComponent(account)
        : '${Uri.encodeComponent(issuer)}:${Uri.encodeComponent(account)}';
    final params = [
      'secret=${Base32.encode(secret)}',
      if (issuer.isNotEmpty) 'issuer=${Uri.encodeComponent(issuer)}',
      'algorithm=${algorithm.wireName}',
      'digits=$digits',
      'period=$period',
    ];
    return 'otpauth://totp/$label?${params.join('&')}';
  }

  void dispose() => secret.fillRange(0, secret.length, 0);
}

abstract final class Totp {
  /// RFC 4226 HOTP (dinamik kesme dâhil).
  static Future<String> hotp(Uint8List key, int counter,
      {TotpAlgorithm algorithm = TotpAlgorithm.sha1, int digits = 6}) async {
    final msg = ByteData(8)..setUint64(0, counter);
    final mac = await algorithm.hmac
        .calculateMac(msg.buffer.asUint8List(), secretKey: SecretKeyData(key));
    final h = mac.bytes;
    final o = h[h.length - 1] & 0x0F;
    final bin = ((h[o] & 0x7F) << 24) |
        (h[o + 1] << 16) |
        (h[o + 2] << 8) |
        h[o + 3];
    var mod = 1;
    for (var i = 0; i < digits; i++) {
      mod *= 10;
    }
    return (bin % mod).toString().padLeft(digits, '0');
  }

  static int counterAt(DateTime t, int period) =>
      (t.toUtc().millisecondsSinceEpoch ~/ 1000) ~/ period;

  static Future<String> generateAt(TotpConfig c, DateTime time) => hotp(
      c.secret, counterAt(time, c.period),
      algorithm: c.algorithm, digits: c.digits);

  static int secondsRemaining(DateTime t, int period) =>
      period - ((t.toUtc().millisecondsSinceEpoch ~/ 1000) % period);
}

/// QR tarayıcı soyutlaması (kamera/UI sonraki aşamada uygular): QR'ın ham metnini döndürür.
abstract interface class QrScanner {
  Future<String?> scan();
}

class TotpQrImporter {
  TotpQrImporter(this._scanner);
  final QrScanner _scanner;

  /// Kullanıcı vazgeçerse null; geçersiz QR [FormatException].
  Future<TotpConfig?> importFromQr() async {
    final text = await _scanner.scan();
    return text == null ? null : TotpConfig.parseUri(text);
  }
}
