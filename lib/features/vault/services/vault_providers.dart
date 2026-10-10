// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'vault_manager.dart';

/// Uygulama başlangıcında `ProviderScope(overrides: [...])` ile sağlanır
/// (dizin `path_provider` ile alınır; bu aşamada UI/bootstrap yok).
final vaultManagerProvider = Provider<VaultManager>(
  (ref) => throw UnimplementedError('vaultManagerProvider override edilmeli'),
);
