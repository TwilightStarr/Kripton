// SPDX-License-Identifier: Apache-2.0
import 'dart:math' as math;

import 'common_passwords.dart';

enum Weakness {
  tooShort,
  commonPassword,
  containsCommonWord,
  keyboardPattern,
  repeats,
  sequence,
  date,
  lowVariety,
  userInput,
}

class PasswordReport {
  const PasswordReport({
    required this.guessesLog10,
    required this.score,
    required this.weaknesses,
    required this.isCommon,
    required this.length,
  });

  /// log10(tahmini tahmin sayısı)
  final double guessesLog10;

  /// 0..4 (zxcvbn eşikleri: <1e3, <1e6, <1e8, <1e10, >=1e10)
  final int score;
  final Set<Weakness> weaknesses;
  final bool isCommon;
  final int length;

  /// Çevrimdışı yavaş-hash (≈1e4 tahmin/sn) saldırganı için log10(saniye).
  double get offlineSlowHashSecondsLog10 => guessesLog10 - 4;

  bool get acceptable => length >= 12 && score >= 3 && !isCommon;
}

class _Match {
  const _Match(this.i, this.j, this.log10, this.weakness);
  final int i;
  final int j;
  final double log10;
  final Weakness weakness;
}

class _Back {
  const _Back(this.prev, this.match);
  final int prev;
  final _Match? match;
}

/// zxcvbn'den esinlenmiş, bağımlılıksız entropi tahmincisi:
/// sözlük (+l33t, ters), klavye deseni, tekrar, ardışık dizi, tarih, kaba kuvvet;
/// en ucuz bölümleme dinamik programlama ile bulunur.
class PasswordStrengthEstimator {
  PasswordStrengthEstimator(this.common);

  final CommonPasswordList common;

  static const int _maxAnalyzed = 128;
  static const int _maxWordLen = 32;

  static const _rows = <String>[
    '1234567890',
    'qwertyuiop',
    'asdfghjkl',
    'zxcvbnm',
    'qwertyuıopğü',
    'asdfghjklşi',
    'zxcvbnmöç',
  ];

  static const _leet = <String, String>{
    '4': 'a', '@': 'a', '8': 'b', '3': 'e', '1': 'l', '!': 'i',
    '0': 'o', r'$': 's', '5': 's', '7': 't', '+': 't',
  };

  static double _l10(num x) => math.log(x) / math.ln10;

  static int _cardOf(Iterable<String> chars) {
    var c = 0;
    var lo = false, up = false, di = false, sy = false, ot = false;
    for (final ch in chars) {
      final u = ch.codeUnitAt(0);
      if (u > 127) {
        ot = true;
      } else if (u >= 97 && u <= 122) {
        lo = true;
      } else if (u >= 65 && u <= 90) {
        up = true;
      } else if (u >= 48 && u <= 57) {
        di = true;
      } else {
        sy = true;
      }
    }
    if (lo) c += 26;
    if (up) c += 26;
    if (di) c += 10;
    if (sy) c += 33;
    if (ot) c += 100;
    return math.max(c, 10);
  }

  PasswordReport estimate(String password,
      {List<String> userInputs = const []}) {
    final all = password.runes.map(String.fromCharCode).toList();
    final totalLen = all.length;
    if (totalLen == 0) {
      return const PasswordReport(
          guessesLog10: 0,
          score: 0,
          weaknesses: {Weakness.tooShort},
          isCommon: false,
          length: 0);
    }
    final chars = totalLen > _maxAnalyzed ? all.sublist(0, _maxAnalyzed) : all;
    final n = chars.length;
    final lc = chars.map((c) => c.toLowerCase()).toList();
    final extra = <String, int>{
      for (var i = 0; i < userInputs.length; i++)
        userInputs[i].toLowerCase(): i + 1
    };

    final brutePerChar = _l10(_cardOf(chars));
    final classes = {
      for (final c in chars)
        () {
          final u = c.codeUnitAt(0);
          if (u > 127) return 4;
          if (u >= 97 && u <= 122) return 0;
          if (u >= 65 && u <= 90) return 1;
          if (u >= 48 && u <= 57) return 2;
          return 3;
        }()
    }.length;

    double bruteOf(String s) =>
        s.length * _l10(_cardOf(s.split('')));

    final matches = <_Match>[];

    // ---- sözlük
    double caseFactor(String orig) {
      var up = 0, lo = 0;
      for (final c in orig.split('')) {
        if (c != c.toLowerCase()) {
          up++;
        } else if (c != c.toUpperCase()) {
          lo++;
        }
      }
      if (up == 0) return 0;
      if (lo == 0) return _l10(2);
      if (up == 1 && orig[0] != orig[0].toLowerCase()) return _l10(2);
      return (math.min(up, lo) + 1) * _l10(2);
    }

    for (var i = 0; i < n; i++) {
      for (var j = i + 2; j < n && j - i < _maxWordLen; j++) {
        final sub = lc.sublist(i, j + 1).join();
        final orig = chars.sublist(i, j + 1).join();
        final whole = i == 0 && j == n - 1;
        final variants = <(String, bool, int)>[
          (sub, false, 0),
          (sub.split('').reversed.join(), true, 0),
        ];
        var leetCount = 0;
        final sb = StringBuffer();
        for (final c in sub.split('')) {
          final m = _leet[c];
          if (m != null) {
            sb.write(m);
            leetCount++;
          } else {
            sb.write(c);
          }
        }
        if (leetCount > 0) variants.add((sb.toString(), false, leetCount));
        for (final (word, reversed, subs) in variants) {
          final userRank = extra[word] ?? 0;
          final rank = userRank > 0 ? userRank : common.rankOf(word);
          if (rank <= 0) continue;
          final cost = _l10(rank) +
              caseFactor(orig) +
              (reversed ? _l10(2) : 0) +
              subs * _l10(2);
          matches.add(_Match(
              i,
              j,
              cost,
              userRank > 0
                  ? Weakness.userInput
                  : (whole
                      ? Weakness.commonPassword
                      : Weakness.containsCommonWord)));
        }
      }
    }

    // ---- klavye deseni
    for (var i = 0; i < n; i++) {
      if (lc[i].length != 1) continue;
      for (final row in _rows) {
        final p = row.indexOf(lc[i]);
        if (p < 0) continue;
        for (final dir in const [1, -1]) {
          var k = 1;
          while (i + k < n &&
              p + dir * k >= 0 &&
              p + dir * k < row.length &&
              row[p + dir * k] == lc[i + k]) {
            k++;
            if (k >= 3) {
              matches.add(_Match(
                  i, i + k - 1, _l10(80.0 * k), Weakness.keyboardPattern));
            }
          }
        }
      }
    }

    // ---- ardışık dizi (abc, 135, 975 ...)
    bool alnum(String c) {
      if (c.length != 1) return false;
      final u = c.codeUnitAt(0);
      return (u >= 97 && u <= 122) || (u >= 48 && u <= 57);
    }

    for (var i = 0; i + 2 < n; i++) {
      if (!alnum(lc[i]) || !alnum(lc[i + 1])) continue;
      final d = lc[i + 1].codeUnitAt(0) - lc[i].codeUnitAt(0);
      if (d == 0 || d.abs() > 5) continue;
      final isDigit = lc[i].codeUnitAt(0) <= 57;
      var k = 1;
      while (i + k < n &&
          alnum(lc[i + k]) &&
          lc[i + k].codeUnitAt(0) - lc[i + k - 1].codeUnitAt(0) == d) {
        k++;
        if (k >= 3) {
          matches.add(_Match(i, i + k - 1,
              _l10((isDigit ? 10.0 : 26.0) * 2 * k), Weakness.sequence));
        }
      }
    }

    // ---- tekrar (aaa, abcabc)
    for (var u = 1; u <= n ~/ 2; u++) {
      for (var i = 0; i + 2 * u <= n; i++) {
        final unit = chars.sublist(i, i + u).join();
        var k = 1;
        while (i + (k + 1) * u <= n &&
            chars.sublist(i + k * u, i + (k + 1) * u).join() == unit) {
          k++;
          matches.add(_Match(
              i, i + k * u - 1, bruteOf(unit) + _l10(k), Weakness.repeats));
        }
      }
    }

    // ---- tarih (yalnızca rakam)
    final digitsOnly = RegExp(r'^[0-9]+$');
    for (final len in const [4, 6, 8]) {
      for (var i = 0; i + len <= n; i++) {
        final s = chars.sublist(i, i + len).join();
        if (!digitsOnly.hasMatch(s)) continue;
        final cost = _dateCost(s);
        if (cost != null) {
          matches.add(_Match(i, i + len - 1, cost, Weakness.date));
        }
      }
    }

    // ---- DP: en ucuz bölümleme
    const inf = double.infinity;
    final opt = List.generate(n + 1, (_) => List<double>.filled(n + 2, inf));
    final back = List.generate(n + 1, (_) => List<_Back?>.filled(n + 2, null));
    opt[0][0] = 0;
    final byEnd = List.generate(n, (_) => <_Match>[]);
    for (final m in matches) {
      byEnd[m.j].add(m);
    }
    for (var k = 1; k <= n; k++) {
      for (final m in byEnd[k - 1]) {
        for (var l = 1; l <= n; l++) {
          final prev = opt[m.i][l - 1];
          if (prev == inf) continue;
          final c = prev + m.log10;
          if (c < opt[k][l]) {
            opt[k][l] = c;
            back[k][l] = _Back(m.i, m);
          }
        }
      }
      for (var i = 0; i < k; i++) {
        final bc = (k - i) * brutePerChar;
        for (var l = 1; l <= n; l++) {
          final prev = opt[i][l - 1];
          if (prev == inf) continue;
          final c = prev + bc;
          if (c < opt[k][l]) {
            opt[k][l] = c;
            back[k][l] = _Back(i, null);
          }
        }
      }
    }
    var best = inf;
    var bestL = 1;
    var fact = 0.0;
    for (var l = 1; l <= n; l++) {
      fact += _l10(l);
      final t = opt[n][l] + fact;
      if (t < best) {
        best = t;
        bestL = l;
      }
    }
    final weaknesses = <Weakness>{};
    var k = n;
    var l = bestL;
    while (k > 0 && l > 0) {
      final b = back[k][l]!;
      if (b.match != null) weaknesses.add(b.match!.weakness);
      k = b.prev;
      l--;
    }
    if (totalLen > _maxAnalyzed) {
      best += (totalLen - _maxAnalyzed) * brutePerChar;
    }

    final lowerAll = all.map((c) => c.toLowerCase()).join();
    final isCommon = common.rankOf(lowerAll) > 0;
    if (isCommon) weaknesses.add(Weakness.commonPassword);
    if (totalLen < 12) weaknesses.add(Weakness.tooShort);
    if (classes <= 1 && totalLen < 16) weaknesses.add(Weakness.lowVariety);

    var score = best < 3
        ? 0
        : best < 6
            ? 1
            : best < 8
                ? 2
                : best < 10
                    ? 3
                    : 4;
    if (isCommon) score = 0;
    return PasswordReport(
        guessesLog10: best,
        score: score,
        weaknesses: weaknesses,
        isCommon: isCommon,
        length: totalLen);
  }

  static double? _dateCost(String s) {
    bool dm(int d, int m) => d >= 1 && d <= 31 && m >= 1 && m <= 12;
    int v(int a, int b) => int.parse(s.substring(a, b));
    switch (s.length) {
      case 4:
        final y = int.parse(s);
        if (y >= 1900 && y <= 2039) return _l10(140);
        if (dm(v(0, 2), v(2, 4)) || dm(v(2, 4), v(0, 2))) return _l10(365);
        return null;
      case 6:
        if (dm(v(0, 2), v(2, 4)) ||
            dm(v(2, 4), v(0, 2)) ||
            dm(v(4, 6), v(2, 4))) {
          return _l10(365 * 100);
        }
        return null;
      case 8:
        final y1 = v(4, 8);
        final y2 = v(0, 4);
        if ((y1 >= 1900 &&
                y1 <= 2039 &&
                (dm(v(0, 2), v(2, 4)) || dm(v(2, 4), v(0, 2)))) ||
            (y2 >= 1900 && y2 <= 2039 && dm(v(6, 8), v(4, 6)))) {
          return _l10(365 * 140);
        }
        return null;
    }
    return null;
  }
}
