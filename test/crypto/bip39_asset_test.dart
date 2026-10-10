// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/crypto/bip39.dart';
import 'package:quanta/core/crypto/hex.dart';

/// Gerçek BIP39 listesi assets/wordlists/ içinde varsa çalışır
/// (tool/fetch_assets.sh ile indirin). Yoksa atlanır.
void main() {
  final f = File(Bip39.assetPath);
  final present = f.existsSync();

  test('asset SHA-256 ve resmi BIP39 test vektörleri',
      skip: present ? false : 'önce tool/fetch_assets.sh çalıştırın', () async {
    final bytes = f.readAsBytesSync();
    expect(toHex((await Sha256().hash(bytes)).bytes), Bip39.expectedSha256Hex);
    final bip = Bip39(
        String.fromCharCodes(bytes).split('\n').where((w) => w.trim().isNotEmpty).map((w) => w.trim()).toList());
    expect((await bip.entropyToMnemonic(Uint8List.fromList(List.filled(32, 0)))).join(' '),
        '${List.filled(23, 'abandon').join(' ')} art');
    expect((await bip.entropyToMnemonic(Uint8List.fromList(List.filled(32, 0xff)))).join(' '),
        '${List.filled(23, 'zoo').join(' ')} vote');
  });
}
