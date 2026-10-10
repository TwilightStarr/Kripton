// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../security/key_material.dart';

/// HKDF-SHA512 (RFC 5869). Dönen tamponu sıfırlamak çağıranın görevidir.
Future<Uint8List> hkdfSha512({
  required List<int> ikm,
  List<int> salt = const <int>[],
  required List<int> info,
  required int length,
}) async {
  final hkdf = Hkdf(hmac: Hmac.sha512(), outputLength: length);
  final key = await hkdf.deriveKey(
    secretKey: SecretKeyData(ikm),
    // RFC 5869 §2.2: salt verilmezse HashLen sıfır bayt kullanılır (HMAC için sonuç aynıdır).
    // `cryptography` boş HMAC anahtarını reddeder, bu yüzden açıkça sıfırlarla doldururuz.
    nonce: salt.isEmpty ? Uint8List(64) : salt,
    info: info,
  );
  return extractAndWipe(key);
}
