// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bip39.dart';
import 'vault_service.dart';

final bip39Provider = FutureProvider<Bip39>((ref) => Bip39.loadFromAssets());

final vaultServiceProvider = FutureProvider<VaultService>((ref) async {
  final bip39 = await ref.watch(bip39Provider.future);
  return VaultService(bip39: bip39);
});

/// Açık oturum. lock() / yeni oturum atanması anahtarları sıfırlar.
class VaultSessionNotifier extends Notifier<VaultSession?> {
  @override
  VaultSession? build() {
    ref.onDispose(() => state?.dispose());
    return null;
  }

  void open(VaultSession session) {
    state?.dispose();
    state = session;
  }

  void lock() {
    state?.dispose();
    state = null;
  }
}

final vaultSessionProvider =
    NotifierProvider<VaultSessionNotifier, VaultSession?>(
        VaultSessionNotifier.new);
