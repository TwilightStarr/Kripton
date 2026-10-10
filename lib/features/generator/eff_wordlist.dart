// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/services.dart';

/// EFF büyük diceware listesi (7776 sözcük). Satır biçimi: "11111\tabacus".
/// `tool/fetch_assets.sh` ile indirilir.
class EffWordlist {
  EffWordlist(List<String> words) : words = List.unmodifiable(words) {
    if (words.length != size || words.toSet().length != size) {
      throw ArgumentError('wordlist must contain $size unique words');
    }
  }

  static const int size = 7776;
  static const assetPath = 'assets/wordlists/eff_large_wordlist.txt';

  final List<String> words;

  static EffWordlist parse(String text) {
    final words = <String>[];
    for (final line in const LineSplitter().convert(text)) {
      final t = line.trim();
      if (t.isEmpty) continue;
      words.add(t.split(RegExp(r'\s+')).last.toLowerCase());
    }
    return EffWordlist(words);
  }

  static Future<EffWordlist> loadFromAssets({AssetBundle? bundle}) async =>
      parse(await (bundle ?? rootBundle).loadString(assetPath));
}
