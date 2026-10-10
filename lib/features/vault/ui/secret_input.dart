// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../../core/security/secret_bytes.dart';

/// Alanın metnini hemen UTF-8 baytlarına çevirip [SecretBytes]'e alır ve
/// controller'ı temizler. Sahipliği çağıran alır: iş bitince `dispose()`.
///
/// Not: Dart `String`'i (controller metni, geçici `utf8.encode` girdisi)
/// sıfırlanamaz; bu işlem pencereyi azaltır, ortadan kaldırmaz (README).
SecretBytes takeSecretBytes(TextEditingController controller) {
  final bytes = Uint8List.fromList(utf8.encode(controller.text));
  controller.clear();
  return SecretBytes(bytes);
}
