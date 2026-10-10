// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/util/base32.dart';
import 'package:quanta/features/totp/totp.dart';

DateTime at(int s) => DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);

Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  // RFC 6238 Ek B (8 hane, 30 sn). Beklenen değerler bağımsız Python HMAC ile doğrulandı.
  final seeds = {
    TotpAlgorithm.sha1: ascii('12345678901234567890'),
    TotpAlgorithm.sha256: ascii('12345678901234567890123456789012'),
    TotpAlgorithm.sha512:
        ascii('1234567890123456789012345678901234567890123456789012345678901234'),
  };
  final vectors = <TotpAlgorithm, Map<int, String>>{
    TotpAlgorithm.sha1: {
      59: '94287082', 1111111109: '07081804', 1111111111: '14050471',
      1234567890: '89005924', 2000000000: '69279037', 20000000000: '65353130',
    },
    TotpAlgorithm.sha256: {
      59: '46119246', 1111111109: '68084774', 1111111111: '67062674',
      1234567890: '91819424', 2000000000: '90698825', 20000000000: '77737706',
    },
    TotpAlgorithm.sha512: {
      59: '90693936', 1111111109: '25091201', 1111111111: '99943326',
      1234567890: '93441116', 2000000000: '38618901', 20000000000: '47863826',
    },
  };

  group('RFC 6238 test vektörleri', () {
    for (final alg in TotpAlgorithm.values) {
      test(alg.wireName, () async {
        final cfg = TotpConfig(secret: seeds[alg]!, algorithm: alg, digits: 8);
        for (final e in vectors[alg]!.entries) {
          expect(await Totp.generateAt(cfg, at(e.key)), e.value,
              reason: '${alg.wireName} t=${e.key}');
        }
      });
    }

    test('6 hane ve 60 sn periyot', () async {
      final six = TotpConfig(secret: seeds[TotpAlgorithm.sha1]!);
      expect(await Totp.generateAt(six, at(59)), '287082');
      final p60 = TotpConfig(secret: seeds[TotpAlgorithm.sha1]!, digits: 8, period: 60);
      expect(await Totp.generateAt(p60, at(59)), '84755224');
      expect(await Totp.generateAt(p60, at(30)), '84755224'); // aynı pencere (sayaç 0)
      expect(await Totp.generateAt(p60, at(119)), '94287082'); // sayaç 1
      expect(await Totp.generateAt(p60, at(120)), '37359152');
    });

    test('kalan süre', () {
      expect(Totp.secondsRemaining(at(59), 30), 1);
      expect(Totp.secondsRemaining(at(60), 30), 30);
    });
  });

  group('Base32 (RFC 4648)', () {
    test('vektörler', () {
      expect(Base32.encode('foobar'.codeUnits, padding: true), 'MZXW6YTBOI======');
      expect(Base32.encode('f'.codeUnits, padding: true), 'MY======');
      expect(String.fromCharCodes(Base32.decode('mzxw6ytboi======')), 'foobar');
      expect(String.fromCharCodes(Base32.decode('MZXW 6YTB OI')), 'foobar');
    });
    test('gidiş-dönüş', () {
      for (var n = 1; n < 40; n++) {
        final b = Uint8List.fromList(List.generate(n, (i) => (i * 37 + n) % 256));
        expect(Base32.decode(Base32.encode(b)), b);
      }
    });
    test('geçersiz girdi', () {
      expect(() => Base32.decode('A1'), throwsFormatException);
      expect(() => Base32.decode(''), throwsFormatException);
      expect(() => Base32.decode('ABC'), throwsFormatException);
    });
  });

  group('otpauth URI', () {
    const secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
    test('tam parametreler', () {
      final c = TotpConfig.parseUri(
          'otpauth://totp/Example%3Aalice%40google.com?secret=$secret&issuer=Example&algorithm=SHA256&digits=8&period=60');
      expect(c.issuer, 'Example');
      expect(c.account, 'alice@google.com');
      expect(c.algorithm, TotpAlgorithm.sha256);
      expect(c.digits, 8);
      expect(c.period, 60);
      expect(c.secret, seeds[TotpAlgorithm.sha1]);
    });
    test('varsayılanlar ve etiket öneki', () {
      final c = TotpConfig.parseUri('otpauth://totp/ACME:john?secret=${secret.toLowerCase()}');
      expect(c.issuer, 'ACME');
      expect(c.account, 'john');
      expect(c.algorithm, TotpAlgorithm.sha1);
      expect(c.digits, 6);
      expect(c.period, 30);
    });
    test('toUri -> parseUri gidiş-dönüş', () {
      final c = TotpConfig.fromBase32(secret,
          algorithm: TotpAlgorithm.sha512, digits: 7, period: 60, issuer: 'A B', account: 'x@y.z');
      final d = TotpConfig.parseUri(c.toUri());
      expect(d.issuer, 'A B');
      expect(d.account, 'x@y.z');
      expect(d.algorithm, TotpAlgorithm.sha512);
      expect(d.digits, 7);
      expect(d.period, 60);
      expect(d.secret, c.secret);
    });
    test('geçersizler reddedilir', () {
      for (final bad in [
        'https://example.com',
        'otpauth://hotp/x?secret=$secret&counter=1',
        'otpauth://totp/x',
        'otpauth://totp/x?secret=$secret&digits=5',
        'otpauth://totp/x?secret=$secret&digits=9',
        'otpauth://totp/x?secret=$secret&period=45',
        'otpauth://totp/x?secret=$secret&algorithm=MD5',
        'otpauth://totp/x?secret=AAAA',
        'otpauth://totp/x?secret=!!!!',
      ]) {
        expect(() => TotpConfig.parseUri(bad), throwsFormatException, reason: bad);
      }
    });
  });

  test('QR içe aktarma arayüzü', () async {
    final ok = TotpQrImporter(_Scanner('otpauth://totp/a?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'));
    expect((await ok.importFromQr())!.account, 'a');
    expect(await TotpQrImporter(_Scanner(null)).importFromQr(), isNull);
    await expectLater(TotpQrImporter(_Scanner('merhaba')).importFromQr(), throwsFormatException);
  });
}

class _Scanner implements QrScanner {
  _Scanner(this.text);
  final String? text;
  @override
  Future<String?> scan() async => text;
}
