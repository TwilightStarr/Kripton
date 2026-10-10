// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/vault_controller.dart';

/// Kasa oluşturulmuş ama Secret Key onaylanmadan uygulama kapanmış.
/// Kasa BOŞTUR. Kullanıcıya sorulur; hiçbir şey otomatik silinmez.
class SetupIncompleteScreen extends ConsumerWidget {
  const SetupIncompleteScreen({super.key});

  Future<void> _confirmDiscard(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kasa silinsin mi?'),
        content: const Text(
          'Önceki kurulumdan kalan boş kasa kalıcı olarak silinir ve yeni bir '
          'kasa oluşturmanız istenir.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sil ve baştan başla'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(vaultControllerProvider.notifier).discardIncompleteSetup();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Quanta')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 56, color: scheme.error),
                  const SizedBox(height: 12),
                  Text('Kurulum tamamlanmadı',
                      style: text.headlineSmall, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  const Text(
                    'Önceki kasa kurulumunda Secret Key onaylanmadan '
                    'uygulama kapandı. Kasa boş. Secret Key\'i bir yere '
                    'yazmadıysanız bu kasaya hiçbir zaman erişemezsiniz; '
                    'silip baştan başlamanız önerilir.',
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => _confirmDiscard(context, ref),
                    child: const Text('Sil ve baştan başla'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => ref
                        .read(vaultControllerProvider.notifier)
                        .keepIncompleteSetup(),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(64, 52)),
                    child: const Text('Kasayı olduğu gibi bırak'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
