// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/services.dart';

import 'bloom_filter.dart';

/// Yaygın parola listesi: Bloom filter hızlı negatif yol, sıra (rank) tablosu
/// pozitifleri doğrular ve tahmin sayısı için rank verir.
class CommonPasswordList {
  CommonPasswordList._(this._bloom, this._rank);

  static const assetPath = 'assets/wordlists/common_passwords_10k.txt';

  factory CommonPasswordList.fromLines(Iterable<String> lines) {
    final ranks = <String, int>{};
    var r = 0;
    for (final raw in lines) {
      final w = raw.trim().toLowerCase();
      if (w.isEmpty || ranks.containsKey(w)) continue;
      ranks[w] = ++r;
    }
    final bloom = BloomFilter.withCapacity(ranks.length);
    for (final w in ranks.keys) {
      bloom.add(w);
    }
    return CommonPasswordList._(bloom, ranks);
  }

  static Future<CommonPasswordList> loadFromAssets({AssetBundle? bundle}) async {
    final text = await (bundle ?? rootBundle).loadString(assetPath);
    return CommonPasswordList.fromLines(const LineSplitter().convert(text));
  }

  final BloomFilter _bloom;
  final Map<String, int> _rank;

  /// 1 tabanlı sıra; listede yoksa 0. [lower] küçük harfli olmalı.
  int rankOf(String lower) {
    if (!_bloom.mightContain(lower)) return 0;
    return _rank[lower] ?? 0;
  }
}
