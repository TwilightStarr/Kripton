// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:drift/drift.dart';

/// Testlerde birçok bağımsız bellek içi veritabanı açılır; drift'in "birden çok
/// veritabanı" uyarısı burada yanıltıcıdır (her biri kendi yürütücüsünü kullanır).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  await testMain();
}
