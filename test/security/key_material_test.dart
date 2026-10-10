// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/security/key_material.dart';

void main() {
  group('wipeList', () {
    test('değiştirilebilir listeyi sıfırlar', () {
      final l = Uint8List.fromList([1, 2, 3, 4]);
      expect(wipeList(l), isTrue);
      expect(l, everyElement(0));
    });

    test('değiştirilemez listede çökmez, false döner', () {
      final l = List<int>.unmodifiable([1, 2, 3]);
      expect(wipeList(l), isFalse);
      expect(l, [1, 2, 3]);
    });
  });

  group('extractAndWipe', () {
    test('doğru baytları ayrı bir kopya olarak verir', () async {
      final data = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final expected = Uint8List.fromList(data);
      final out = await extractAndWipe(SecretKeyData(data));
      expect(out, expected);
      expect(identical(out, data), isFalse);
    });

    test('dönen kopya bağımsızdır (sıfırlanması anahtarı etkilemez)', () async {
      final data = Uint8List.fromList([9, 8, 7, 6]);
      final out = await extractAndWipe(SecretKeyData(data));
      out.fillRange(0, out.length, 0);
      expect(out, everyElement(0));
    });
  });
}
