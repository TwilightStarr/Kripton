// SPDX-License-Identifier: Apache-2.0
import 'dart:math';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/crypto/csprng.dart';
import 'package:quanta/core/util/secure_random.dart';
import 'package:quanta/features/generator/eff_wordlist.dart';
import 'package:quanta/features/generator/password_generator.dart';

/// Betimlenen "rastgele" kaynak: nextInt(256) çağrılarına sıradaki değeri verir.
class _Scripted implements Random {
  _Scripted(this.values);
  final List<int> values;
  int i = 0;
  @override
  int nextInt(int max) => values[i++];
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}

// Ki-kare üst-kuyruk kritik değerleri, p = 1e-6 (scipy ile hesaplandı): yanlış alarm ~1e-6.
const chi9 = 44.8, chi25 = 73.9, chi61 = 128.6, chi7775 = 8382.3;

double chiSquare(List<int> counts) {
  final n = counts.fold<int>(0, (a, b) => a + b);
  final e = n / counts.length;
  return counts.fold<double>(0, (a, c) => a + (c - e) * (c - e) / e);
}

final testList = EffWordlist(List.generate(7776, (i) => 'k${i.toString().padLeft(4, '0')}'));

void main() {
  group('SecureRandomInt (modulo bias yok)', () {
    test('sınırı aşan değerler reddedilir (rejection)', () {
      // max=3 -> limit = 2^32 - 1 = 4294967295. İlk 4 bayt 255,255,255,255 = reddedilmeli.
      final r = SecureRandomInt(Csprng(_Scripted([255, 255, 255, 255, 0, 0, 0, 7])));
      expect(r.nextInt(3), 7 % 3);
    });
    test('sınırın hemen altı kabul edilir', () {
      // 4294967294 = ff ff ff fe -> 4294967294 % 3 == 2
      final r = SecureRandomInt(Csprng(_Scripted([255, 255, 255, 254])));
      expect(r.nextInt(3), 2);
    });
    test('aralık denetimi', () {
      final r = SecureRandomInt();
      expect(() => r.nextInt(0), throwsRangeError);
      expect(r.nextInt(1), 0);
    });
    test('küçük aralıkta tekdüzelik (ki-kare)', () {
      final r = SecureRandomInt();
      final c = List.filled(10, 0);
      for (var i = 0; i < 100000; i++) {
        c[r.nextInt(10)]++;
      }
      expect(chiSquare(c), lessThan(chi9));
    });
    test('shuffle bir permütasyon üretir', () {
      final l = List.generate(50, (i) => i);
      SecureRandomInt().shuffle(l);
      expect([...l]..sort(), List.generate(50, (i) => i));
    });
  });

  group('rastgele parola', () {
    final g = PasswordGenerator();

    test('uzunluk sınırları', () {
      for (final bad in [7, 129, 0]) {
        expect(() => g.random(RandomPasswordOptions(length: bad)), throwsArgumentError);
      }
      expect(g.random(const RandomPasswordOptions(length: 8)).value.length, 8);
      expect(g.random(const RandomPasswordOptions(length: 128)).value.length, 128);
    });

    test('her sınıftan en az bir (kısa uzunlukta bile)', () {
      for (var i = 0; i < 500; i++) {
        final p = g.random(const RandomPasswordOptions(length: 8)).value;
        expect(RegExp('[a-z]').hasMatch(p), isTrue, reason: p);
        expect(RegExp('[A-Z]').hasMatch(p), isTrue, reason: p);
        expect(RegExp('[0-9]').hasMatch(p), isTrue, reason: p);
        expect(RegExp(r'[^a-zA-Z0-9]').hasMatch(p), isTrue, reason: p);
      }
    });

    test('sınıf seçimleri ve benzer karakter hariç tutma', () {
      for (var i = 0; i < 300; i++) {
        final p = g.random(const RandomPasswordOptions(
                length: 40, symbols: false, excludeAmbiguous: true)).value;
        expect(RegExp('[O0oIl1|]').hasMatch(p), isFalse, reason: p);
        expect(RegExp('[^a-zA-Z0-9]').hasMatch(p), isFalse);
      }
      final digitsOnly = g.random(const RandomPasswordOptions(
          lowercase: false, uppercase: false, symbols: false)).value;
      expect(RegExp(r'^\d+$').hasMatch(digitsOnly), isTrue);
      expect(() => g.random(const RandomPasswordOptions(
          lowercase: false, uppercase: false, digits: false, symbols: false)), throwsArgumentError);
    });

    test('özel sembol kümesi tekilleştirilir ve boşluk yok sayılır', () {
      final p = g.random(const RandomPasswordOptions(
              length: 64, lowercase: false, uppercase: false, digits: false, symbolChars: '!!!! @@')).value;
      expect(p.split('').toSet().difference({'!', '@'}), isEmpty);
    });

    test('istatistik: sınıf içi tekdüze (küçük harfler, ki-kare)', () {
      final c = List.filled(26, 0);
      for (var i = 0; i < 20000; i++) {
        for (final ch in g.random(const RandomPasswordOptions(length: 20)).value.codeUnits) {
          if (ch >= 97 && ch <= 122) c[ch - 97]++;
        }
      }
      expect(chiSquare(c), lessThan(chi25));
    });

    test('istatistik: kısıtsız havuzda tüm havuz tekdüze (62 karakter)', () {
      const alpha = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
      final c = List.filled(62, 0);
      for (var i = 0; i < 10000; i++) {
        final p = g.random(const RandomPasswordOptions(
                length: 32, symbols: false, requireEachClass: false)).value;
        for (final ch in p.split('')) {
          c[alpha.indexOf(ch)]++;
        }
      }
      expect(chiSquare(c), lessThan(chi61));
    });

    test('iki üretim farklıdır; entropi tahmini mantıklı', () {
      final a = g.random(), b = g.random();
      expect(a.value, isNot(b.value));
      expect(a.entropyBits, closeTo(20 * log(26 + 26 + 10 + RandomPasswordOptions.defaultSymbols.length) / ln2, 1e-9));
    });
  });

  group('diceware', () {
    final g = PasswordGenerator();
    test('liste doğrulaması', () {
      expect(() => EffWordlist(['a', 'b']), throwsArgumentError);
      expect(() => EffWordlist(List.filled(7776, 'x')), throwsArgumentError);
      expect(EffWordlist.parse(List.generate(7776, (i) => '${i + 11111}\tw$i').join('\n')).words.length, 7776);
    });
    test('seçenekler: sözcük sayısı, ayırıcı, büyük harf, sayı', () {
      final r = g.diceware(testList, const DicewareOptions(wordCount: 5, separator: '.', capitalize: true));
      final parts = r.value.split('.');
      expect(parts.length, 5);
      for (final w in parts) {
        expect(w[0], 'K');
      }
      expect(r.entropyBits, closeTo(5 * log(7776) / ln2, 1e-9));
      final n = g.diceware(testList, const DicewareOptions(wordCount: 4, separator: ' ', includeNumber: true));
      expect(RegExp(r'\d').allMatches(n.value.replaceAll(RegExp(r'k\d{4}'), '')).length, 1);
      expect(n.entropyBits, greaterThan(4 * log(7776) / ln2));
      expect(() => g.diceware(testList, const DicewareOptions(wordCount: 2)), throwsArgumentError);
    });
    test('istatistik: 7776 sözcüğün seçimi tekdüze', () {
      final c = List.filled(7776, 0);
      for (var i = 0; i < 40000; i++) {
        for (final w in g.diceware(testList, const DicewareOptions(wordCount: 5, separator: ' ')).value.split(' ')) {
          c[int.parse(w.substring(1))]++;
        }
      }
      expect(chiSquare(c), lessThan(chi7775));
    });
  });

  group('PIN', () {
    final g = PasswordGenerator();
    test('uzunluk ve yalnızca rakam', () {
      for (final len in [4, 6, 12]) {
        expect(RegExp('^\\d{$len}\$').hasMatch(g.pin(PinOptions(length: len)).value), isTrue);
      }
      expect(() => g.pin(const PinOptions(length: 3)), throwsArgumentError);
    });
    test('trivial PIN\'ler üretilmez', () {
      for (var i = 0; i < 20000; i++) {
        final p = g.pin(const PinOptions(length: 4)).value;
        expect(['0000', '1111', '1234', '4321', '1212', '9999', '0123'].contains(p), isFalse, reason: p);
      }
    });
    test('istatistik: rakamlar tekdüze (trivial filtresi kapalı)', () {
      final c = List.filled(10, 0);
      for (var i = 0; i < 50000; i++) {
        for (final d in g.pin(const PinOptions(length: 6, avoidTrivial: false)).value.split('')) {
          c[int.parse(d)]++;
        }
      }
      expect(chiSquare(c), lessThan(chi9));
    });
  });

  test('gerçek EFF listesi (assets varsa)', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    try {
      final l = await EffWordlist.loadFromAssets();
      expect(l.words.length, 7776);
    } on FlutterError {
      markTestSkipped('assets/wordlists/eff_large_wordlist.txt yok: tool/fetch_assets.sh');
    }
  });
}
