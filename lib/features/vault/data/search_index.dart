// SPDX-License-Identifier: Apache-2.0
import '../../../core/util/text_fold.dart';
import '../domain/item_filter.dart';
import '../domain/item_summary.dart';

class _Entry {
  _Entry(this.summary)
      : title = foldForSearch(summary.title),
        rest = foldForSearch([
          summary.subtitle,
          summary.category ?? '',
          ...summary.urls,
          ...summary.tags,
        ].join('\u0001'));

  final ItemSummary summary;
  final String title;
  final String rest;
}

/// BELLEK İÇİ arama indeksi: kilit açılınca şifreli özetlerden kurulur,
/// kilitlenince [clear] ile bırakılır. Diske HİÇBİR ŞEY yazmaz.
///
/// Dürüst sınır: Dart `String`'leri sıfırlanamaz; [clear] referansları bırakır,
/// içeriğin bellekten silinmesi çöp toplayıcıya kalır.
class SearchIndex {
  final Map<String, _Entry> _entries = {};

  int get length => _entries.length;

  void put(ItemSummary s) => _entries[s.id] = _Entry(s);
  void remove(String id) => _entries.remove(id);
  ItemSummary? get(String id) => _entries[id]?.summary;
  void clear() => _entries.clear();

  List<ItemSummary> list(ItemFilter filter) {
    final out = [
      for (final e in _entries.values)
        if (filter.matches(e.summary)) e.summary
    ]..sort(filter.compare);
    return out;
  }

  /// Tüm sözcükler eşleşmeli (AND). Başlıkta önek > başlıkta içerme > diğer alanlar.
  List<ItemSummary> search(String query, ItemFilter filter) {
    final terms = foldForSearch(query)
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (terms.isEmpty) return list(filter);

    final scored = <(int, ItemSummary)>[];
    for (final e in _entries.values) {
      if (!filter.matches(e.summary)) continue;
      var score = 0;
      var ok = true;
      for (final t in terms) {
        if (e.title.startsWith(t)) {
          score += 4;
        } else if (e.title.contains(t)) {
          score += 3;
        } else if (e.rest.contains(t)) {
          score += 1;
        } else {
          ok = false;
          break;
        }
      }
      if (ok) scored.add((score, e.summary));
    }
    scored.sort((a, b) {
      final c = b.$1.compareTo(a.$1);
      return c != 0 ? c : filter.compare(a.$2, b.$2);
    });
    return [for (final s in scored) s.$2];
  }
}
