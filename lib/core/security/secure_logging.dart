// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/foundation.dart';

/// Release'te print/debugPrint kapalı; debug'da bile yalnızca hata TÜRÜ yazılır,
/// hiçbir zaman mesaj/stack içeriği yazılmaz.
void configureSecureLogging() {
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  FlutterError.onError = (FlutterErrorDetails details) {
    if (!kReleaseMode) {
      debugPrint('FlutterError: ${details.exception.runtimeType}');
    }
  };
}

/// Uygulamayı, yakalanmayan hataları ve print çağrılarını sessize alan bir
/// zone içinde çalıştırır.
void runGuarded(void Function() body) {
  runZonedGuarded<void>(
    body,
    (Object error, StackTrace stack) {
      if (!kReleaseMode) debugPrint('Unhandled: ${error.runtimeType}');
    },
    zoneSpecification: kReleaseMode
        ? ZoneSpecification(print: (self, parent, zone, line) {})
        : null,
  );
}
