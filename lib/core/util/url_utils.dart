// SPDX-License-Identifier: Apache-2.0
/// URL'den karşılaştırılabilir ana makine adı: şema yoksa https varsayılır,
/// küçük harf, baştaki "www." atılır. Ayrıştırılamazsa null.
String? hostOf(String url) {
  final t = url.trim();
  if (t.isEmpty) return null;
  final withScheme = t.contains('://') ? t : 'https://$t';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty) return null;
  var h = uri.host.toLowerCase();
  if (h.startsWith('www.')) h = h.substring(4);
  return h;
}
