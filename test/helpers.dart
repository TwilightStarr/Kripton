// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:quanta/core/crypto/bip39.dart';
import 'package:quanta/core/crypto/kdf_params.dart';
import 'package:quanta/core/crypto/key_derivation.dart';
import 'package:quanta/core/crypto/vault_service.dart';
import 'package:quanta/core/security/secret_bytes.dart';

/// Testlerde kullanılan sentetik 2048 kelimelik liste (gerçek BIP39 listesi
/// assets içindedir; kodlama mantığı listeden bağımsızdır).
final List<String> testWords =
    List.generate(2048, (i) => 'w${i.toString().padLeft(4, '0')}');

/// Hızlı test parametreleri (KdfPolicy.testing içinde geçerli).
const testKdf = KdfParams(memoryKiB: 256, iterations: 1, parallelism: 1);

const goodPassword = 'correct horse battery staple';

VaultService makeService({KdfPolicy policy = KdfPolicy.testing}) =>
    VaultService(
      bip39: Bip39(testWords),
      kdf: KeyDerivation(runner: const InlineArgon2Runner(), policy: policy),
    );

SecretBytes sb(String s) => SecretBytes(Uint8List.fromList(utf8.encode(s)));
