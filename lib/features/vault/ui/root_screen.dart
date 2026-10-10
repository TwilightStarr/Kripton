// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/vault_controller.dart';
import 'create_vault_screen.dart';
import 'home_screen.dart';
import 'lock_screen.dart';
import 'reveal_screen.dart';
import 'setup_incomplete_screen.dart';

/// Kök ekran: kasa durumuna göre kasa oluştur / kilit / (Secret Key gösterimi)
/// / açık kasa.
class RootScreen extends ConsumerWidget {
  const RootScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(vaultControllerProvider);
    switch (s.phase) {
      case VaultPhase.loading:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case VaultPhase.error:
        return Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Kasa durumu okunamadı.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () =>
                          ref.read(vaultControllerProvider.notifier).reload(),
                      child: const Text('Tekrar dene'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      case VaultPhase.noVault:
        return const CreateVaultScreen();
      case VaultPhase.setupIncomplete:
        return const SetupIncompleteScreen();
      case VaultPhase.locked:
        return const LockScreen();
      case VaultPhase.unlocked:
        final reveal = s.reveal;
        return reveal == null
            ? const HomeScreen()
            : RevealScreen(secrets: reveal);
    }
  }
}
