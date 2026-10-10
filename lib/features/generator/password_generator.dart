// SPDX-License-Identifier: Apache-2.0
import 'dart:math' as math;

import '../../core/util/secure_random.dart';
import 'eff_wordlist.dart';

class GeneratedPassword {
  const GeneratedPassword(this.value, this.entropyBits);
  final String value;

  /// Yaklaşık entropi (bit). Kısıtlı (her sınıftan en az bir) üretimde üst sınırdır.
  final double entropyBits;
}

class RandomPasswordOptions {
  const RandomPasswordOptions({
    this.length = 20,
    this.lowercase = true,
    this.uppercase = true,
    this.digits = true,
    this.symbols = true,
    this.excludeAmbiguous = false,
    this.symbolChars = defaultSymbols,
    this.requireEachClass = true,
  });

  static const defaultSymbols = r'!@#$%^&*()-_=+[]{};:,.?/';
  static const ambiguousChars = 'O0oIl1|';
  static const minLength = 8;
  static const maxLength = 128;

  final int length;
  final bool lowercase, uppercase, digits, symbols;
  final bool excludeAmbiguous;
  final String symbolChars;
  final bool requireEachClass;

  void validate() {
    if (length < minLength || length > maxLength) {
      throw ArgumentError.value(length, 'length', 'must be 8..128');
    }
    if (!(lowercase || uppercase || digits || symbols)) {
      throw ArgumentError('at least one character class required');
    }
  }
}

class DicewareOptions {
  const DicewareOptions({
    this.wordCount = 6,
    this.separator = '-',
    this.capitalize = false,
    this.includeNumber = false,
  });
  final int wordCount;
  final String separator;
  final bool capitalize;
  final bool includeNumber;
}

class PinOptions {
  const PinOptions({this.length = 6, this.avoidTrivial = true});
  final int length;
  final bool avoidTrivial;
}

/// Parola üreticisi. Rastgelelik YALNIZCA [SecureRandomInt] (CSPRNG, bias'sız).
class PasswordGenerator {
  PasswordGenerator([SecureRandomInt? random])
      : _r = random ?? SecureRandomInt();
  final SecureRandomInt _r;

  static const _lower = 'abcdefghijklmnopqrstuvwxyz';
  static const _upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const _digits = '0123456789';

  List<int> _pool(String chars, bool excludeAmbiguous) {
    final seen = <int>{};
    final out = <int>[];
    for (final r in chars.runes) {
      if (excludeAmbiguous &&
          RandomPasswordOptions.ambiguousChars.runes.contains(r)) {
        continue;
      }
      if (r <= 32 || r == 127) continue; // boşluk/kontrol karakteri yok
      if (seen.add(r)) out.add(r); // tekilleştir: yinelenen karakter bias yaratır
    }
    return out;
  }

  /// Her sınıftan en az bir karakter şartı REJECTION SAMPLING ile sağlanır:
  /// sonuç, kısıtı sağlayan dizeler üzerinde tekdüzedir (sınıf içi dağılım tam
  /// tekdüze; sınıflar arası oran kısıt nedeniyle hafifçe kayar).
  GeneratedPassword random([RandomPasswordOptions o = const RandomPasswordOptions()]) {
    o.validate();
    final pools = <List<int>>[
      if (o.lowercase) _pool(_lower, o.excludeAmbiguous),
      if (o.uppercase) _pool(_upper, o.excludeAmbiguous),
      if (o.digits) _pool(_digits, o.excludeAmbiguous),
      if (o.symbols) _pool(o.symbolChars, o.excludeAmbiguous),
    ];
    if (pools.any((p) => p.isEmpty)) {
      throw ArgumentError('a selected character class is empty');
    }
    final union = <int>{for (final p in pools) ...p}.toList();
    final sets = [for (final p in pools) p.toSet()];

    List<int>? result;
    for (var attempt = 0; attempt < 5000; attempt++) {
      final cand = [for (var i = 0; i < o.length; i++) union[_r.nextInt(union.length)]];
      if (!o.requireEachClass || sets.every((s) => cand.any(s.contains))) {
        result = cand;
        break;
      }
    }
    if (result == null) {
      // Yedek yol (pratikte erişilmez): her sınıftan birini koy, kalanı doldur, karıştır.
      result = [
        for (final p in pools) p[_r.nextInt(p.length)],
        for (var i = pools.length; i < o.length; i++) union[_r.nextInt(union.length)],
      ];
      _r.shuffle(result);
    }
    final bits = o.length * (math.log(union.length) / math.ln2);
    return GeneratedPassword(String.fromCharCodes(result), bits);
  }

  GeneratedPassword diceware(EffWordlist list,
      [DicewareOptions o = const DicewareOptions()]) {
    if (o.wordCount < 3 || o.wordCount > 20) {
      throw ArgumentError.value(o.wordCount, 'wordCount', 'must be 3..20');
    }
    final words = [
      for (var i = 0; i < o.wordCount; i++) list.words[_r.nextInt(list.words.length)]
    ];
    var bits = o.wordCount * (math.log(list.words.length) / math.ln2);
    if (o.capitalize) {
      for (var i = 0; i < words.length; i++) {
        final w = words[i];
        words[i] = w[0].toUpperCase() + w.substring(1);
      }
    }
    if (o.includeNumber) {
      final idx = _r.nextInt(words.length);
      words[idx] = '${words[idx]}${_r.nextInt(10)}';
      bits += math.log(10 * words.length) / math.ln2;
    }
    return GeneratedPassword(words.join(o.separator), bits);
  }

  static bool _trivialPin(String s) {
    if (s.split('').toSet().length == 1) return true;
    var asc = true, desc = true;
    for (var i = 1; i < s.length; i++) {
      final d = s.codeUnitAt(i) - s.codeUnitAt(i - 1);
      if (d != 1) asc = false;
      if (d != -1) desc = false;
    }
    if (asc || desc) return true;
    for (var u = 1; u <= s.length ~/ 2; u++) {
      if (s.length % u == 0 && s == s.substring(0, u) * (s.length ~/ u)) {
        return true; // 1212, 123123 ...
      }
    }
    return false;
  }

  GeneratedPassword pin([PinOptions o = const PinOptions()]) {
    if (o.length < 4 || o.length > 12) {
      throw ArgumentError.value(o.length, 'length', 'must be 4..12');
    }
    while (true) {
      final s = [for (var i = 0; i < o.length; i++) _r.nextInt(10)].join();
      if (o.avoidTrivial && _trivialPin(s)) continue;
      return GeneratedPassword(s, o.length * (math.log(10) / math.ln2));
    }
  }
}
