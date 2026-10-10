// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `flutter create` sonrası android/ klasörü varsa ana manifestte INTERNET
/// izni OLMAMALI. (Debug/profile manifestleri hot-reload için bu izni
/// ekler; release APK'yı ayrıca `aapt dump permissions` ile doğrulayın.)
void main() {
  final f = File('android/app/src/main/AndroidManifest.xml');
  test('ana AndroidManifest.xml INTERNET izni içermez',
      skip: f.existsSync() ? false : 'android/ henüz oluşturulmadı', () {
    expect(f.readAsStringSync(), isNot(contains('android.permission.INTERNET')));
  });
}
