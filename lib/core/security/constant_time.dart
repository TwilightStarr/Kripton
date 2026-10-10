// SPDX-License-Identifier: Apache-2.0
/// Sabit zamanlı eşitlik. Uzunluk farkı public kabul edilir.
bool constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
