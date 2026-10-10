// SPDX-License-Identifier: Apache-2.0
/// Arama için katlama: küçük harf + Türkçe karakterleri ASCII karşılığına indirger
/// (İ/I/ı -> i, ş -> s, ğ -> g, ü -> u, ö -> o, ç -> c). Hem indeks hem sorgu aynı
/// fonksiyondan geçer, böylece "ISPARTA" ile "ısparta" ve "isparta" eşleşir.
const Map<String, String> _fold = {
  'İ': 'i', 'I': 'i', 'ı': 'i',
  'Ş': 's', 'ş': 's',
  'Ğ': 'g', 'ğ': 'g',
  'Ü': 'u', 'ü': 'u',
  'Ö': 'o', 'ö': 'o',
  'Ç': 'c', 'ç': 'c',
};

String foldForSearch(String input) {
  final sb = StringBuffer();
  for (final r in input.runes) {
    final ch = String.fromCharCode(r);
    sb.write(_fold[ch] ?? ch.toLowerCase());
  }
  return sb.toString();
}
