// SPDX-License-Identifier: Apache-2.0
import '../crypto/csprng.dart';
import '../crypto/hex.dart';

/// RFC 4122 sürüm 4 UUID (CSPRNG ile). Kimlikler gizli değildir ama AAD'ye girer.
String newUuidV4(Csprng rng) {
  final b = rng.bytes(16);
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  final h = toHex(b);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}
