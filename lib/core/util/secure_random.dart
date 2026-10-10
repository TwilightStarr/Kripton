// SPDX-License-Identifier: Apache-2.0
import '../crypto/csprng.dart';

/// CSPRNG üzerinde modulo-bias'sız (rejection sampling) tamsayı ve karıştırma.
///
/// Kaynak her zaman [Csprng] (= `Random.secure()`); `dart:math` Random()
/// ASLA kullanılmaz. Testler yalnızca [Csprng]'ye sahte `Random` enjekte eder.
class SecureRandomInt {
  SecureRandomInt([Csprng? csprng]) : _rng = csprng ?? Csprng();
  final Csprng _rng;

  static const int _range = 0x100000000; // 2^32

  /// [0, max) aralığında tekdüze dağılımlı tamsayı. 1 <= max <= 2^32.
  int nextInt(int max) {
    if (max < 1 || max > _range) {
      throw RangeError.range(max, 1, _range, 'max');
    }
    if (max == 1) return 0;
    // [0, limit) aralığı max'a tam bölünür; limit..2^32 arası atılır (bias yok).
    final limit = _range - (_range % max);
    while (true) {
      final b = _rng.bytes(4);
      final v = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
      b.fillRange(0, 4, 0);
      if (v < limit) return v % max;
    }
  }

  /// Fisher–Yates; yerinde karıştırır.
  void shuffle<T>(List<T> list) {
    for (var i = list.length - 1; i > 0; i--) {
      final j = nextInt(i + 1);
      final t = list[i];
      list[i] = list[j];
      list[j] = t;
    }
  }

  T pick<T>(List<T> items) => items[nextInt(items.length)];
}
