// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// [list]'i yerinde sıfırlar. Liste değiştirilemezse (unmodifiable) `false` döner.
bool wipeList(List<int> list) {
  try {
    list.fillRange(0, list.length, 0);
    return true;
  } on UnsupportedError {
    return false;
  }
}

/// `cryptography` paketinin döndürdüğü anahtardan baytları ayrı bir
/// [Uint8List]'e kopyalar ve paketin nesnesindeki bayt dizisini sıfırlar.
/// Böylece türetilmiş anahtarın paket nesnesinde (GC'ye kadar) kalan ikinci
/// bir kopyası bırakılmaz. Dönen tamponu sıfırlamak çağıranın görevidir;
/// [key] bu çağrıdan sonra kullanılmamalıdır.
Future<Uint8List> extractAndWipe(SecretKey key) async {
  final raw = await key.extractBytes();
  final out = Uint8List.fromList(raw);
  wipeList(raw);
  return out;
}
