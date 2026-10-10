// SPDX-License-Identifier: Apache-2.0
import 'dart:math';
import 'dart:typed_data';

/// İşletim sistemi CSPRNG'sine ince sarmalayıcı (dart:math Random.secure()).
class Csprng {
  Csprng([Random? random]) : _random = random ?? Random.secure();
  final Random _random;

  Uint8List bytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }
}
