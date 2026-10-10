// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/security/bloom_filter.dart';
import 'package:quanta/core/security/common_passwords.dart';
import 'package:quanta/core/security/password_strength.dart';

void main() {
  final common = CommonPasswordList.fromLines(
      ['password', '123456', 'qwerty', 'letmein', 'dragon', 'monkey', 'sunshine', 'iloveyou']);
  final est = PasswordStrengthEstimator(common);

  test('Bloom filter: yanlış negatif yok, yanlış pozitif oranı düşük', () {
    final bf = BloomFilter.withCapacity(10000);
    for (var i = 0; i < 10000; i++) {
      bf.add('member-$i');
    }
    for (var i = 0; i < 10000; i++) {
      expect(bf.mightContain('member-$i'), isTrue);
    }
    var fp = 0;
    for (var i = 0; i < 20000; i++) {
      if (bf.mightContain('other-$i')) fp++;
    }
    expect(fp / 20000, lessThan(0.01));
  });

  test('yaygın parola listesi sıra verir, bilinmeyeni reddeder', () {
    expect(common.rankOf('password'), 1);
    expect(common.rankOf('letmein'), 4);
    expect(common.rankOf('zxq-not-there'), 0);
  });

  test('yaygın parola: skor 0 ve isCommon', () {
    final r = est.estimate('Password');
    expect(r.isCommon, isTrue);
    expect(r.score, 0);
    expect(r.acceptable, isFalse);
  });

  test('l33t sözlük eşleşmesi zayıf bulunur', () {
    final r = est.estimate('p@ssw0rd');
    expect(r.score, 0);
    expect(r.weaknesses, isNotEmpty);
  });

  test('klavye deseni', () {
    final r = est.estimate('qwertyuiop');
    expect(r.score, 0);
    expect(r.weaknesses, contains(Weakness.keyboardPattern));
  });

  test('tekrar', () {
    final r = est.estimate('aaaaaaaaaaaa');
    expect(r.score, 0);
    expect(r.weaknesses, contains(Weakness.repeats));
  });

  test('ardışık dizi', () {
    final r = est.estimate('abcdefghijkl');
    expect(r.score, 0);
    expect(r.weaknesses, contains(Weakness.sequence));
  });

  test('tarih deseni', () {
    final r = est.estimate('20240115');
    expect(r.score, lessThanOrEqualTo(1));
    expect(r.weaknesses, contains(Weakness.date));
  });

  test('kısa parola işaretlenir', () {
    expect(est.estimate('Ab3\$x').weaknesses, contains(Weakness.tooShort));
  });

  test('kullanıcı girdisi (ad vb.) sözlüğe eklenir', () {
    final withInput = est.estimate('mehmetali', userInputs: ['mehmet', 'ali']);
    final without = est.estimate('mehmetali');
    expect(withInput.guessesLog10, lessThan(without.guessesLog10));
    expect(withInput.weaknesses, contains(Weakness.userInput));
  });

  test('uzun rastgele parola yüksek skor ve kabul edilebilir', () {
    final r = est.estimate('j7\$Kq!9zVw#2Lm8pRt');
    expect(r.score, 4);
    expect(r.acceptable, isTrue);
  });

  test('boş ve çok uzun girdi çökmez', () {
    expect(est.estimate('').score, 0);
    expect(est.estimate('x7#' * 200).length, 600);
  });
}
