// SPDX-License-Identifier: Apache-2.0
import 'dart:math' as math;
import 'dart:typed_data';

/// Basit Bloom filter. Kriptografik DEĞİLDİR (FNV-1a + double hashing);
/// yalnızca yaygın-parola listesi üyelik ön-testi içindir, gizli veri hash'lemez.
class BloomFilter {
  BloomFilter._(this._m, this._k) : _bits = Uint8List((_m + 7) >> 3);

  factory BloomFilter.withCapacity(int n, {double falsePositiveRate = 0.001}) {
    final capacity = math.max(1, n);
    const ln2 = math.ln2;
    final m = math.max(
        64, (-capacity * math.log(falsePositiveRate) / (ln2 * ln2)).ceil());
    final k = ((m / capacity) * ln2).round().clamp(1, 16);
    return BloomFilter._(m, k);
  }

  final int _m;
  final int _k;
  final Uint8List _bits;

  static int _fnv(String s, int seed) {
    var h = seed;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  void add(String s) {
    final h1 = _fnv(s, 0x811C9DC5);
    final h2 = _fnv(s, 0x9747B28C) | 1;
    for (var i = 0; i < _k; i++) {
      final idx = (h1 + i * h2) % _m;
      _bits[idx >> 3] |= 1 << (idx & 7);
    }
  }

  bool mightContain(String s) {
    final h1 = _fnv(s, 0x811C9DC5);
    final h2 = _fnv(s, 0x9747B28C) | 1;
    for (var i = 0; i < _k; i++) {
      final idx = (h1 + i * h2) % _m;
      if ((_bits[idx >> 3] & (1 << (idx & 7))) == 0) return false;
    }
    return true;
  }
}
