// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/crypto/bip39.dart';
import 'core/crypto/vault_service.dart';
import 'core/security/common_passwords.dart';
import 'core/security/password_strength.dart';
import 'core/security/secure_logging.dart';
import 'features/vault/application/password_providers.dart';
import 'features/vault/services/vault_manager.dart';
import 'features/vault/services/vault_providers.dart';

/// Güvenli başlatma: uygulama özel dizini -> VaultManager -> provider override.
void main() {
  runGuarded(_start);
}

Future<void> _start() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureSecureLogging();
  try {
    // Uygulamaya özel dizin (harici depolama değil; izin gerektirmez).
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final bip39 = await Bip39.loadFromAssets();
    final common = await CommonPasswordList.loadFromAssets();
    final manager = VaultManager(
      directory: dir,
      vaultService: VaultService(bip39: bip39),
    );
    runApp(
      ProviderScope(
        overrides: [
          vaultManagerProvider.overrideWithValue(manager),
          passwordEstimatorProvider
              .overrideWithValue(PasswordStrengthEstimator(common)),
        ],
        child: const QuantaApp(),
      ),
    );
  } catch (_) {
    runApp(const StartupErrorApp());
  }
}
