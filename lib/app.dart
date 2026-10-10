// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/vault/application/vault_controller.dart';
import 'features/vault/ui/auto_lock_scope.dart';
import 'features/vault/ui/root_screen.dart';

const _seed = Color(0xFF7C4DFF);

ThemeData _theme(Brightness brightness) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _seed,
        brightness: brightness,
      ),
      inputDecorationTheme:
          const InputDecorationTheme(border: OutlineInputBorder()),
      // Büyük dokunma hedefleri (≥ 48dp).
      materialTapTargetSize: MaterialTapTargetSize.padded,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(64, 52)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
      ),
    );

/// Uygulama kökü: tema (sistemi izler), Türkçe yerel ayar, otomatik kilit ve
/// kilitlenince açık rotaları kapatma.
class QuantaApp extends ConsumerStatefulWidget {
  const QuantaApp({super.key});

  @override
  ConsumerState<QuantaApp> createState() => _QuantaAppState();
}

class _QuantaAppState extends ConsumerState<QuantaApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    // Kilitlenince üstte açık kalmış ekran/diyalog (gizli veri gösterebilir)
    // varsa hepsini kapat; kullanıcı kilit ekranına döner.
    ref.listen<VaultState>(vaultControllerProvider, (prev, next) {
      if (prev?.phase == VaultPhase.unlocked &&
          next.phase != VaultPhase.unlocked) {
        _navigatorKey.currentState?.popUntil((r) => r.isFirst);
      }
    });
    return MaterialApp(
      title: 'Quanta',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      locale: const Locale('tr'),
      supportedLocales: const [Locale('tr')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) =>
          AutoLockScope(child: child ?? const SizedBox.shrink()),
      home: const RootScreen(),
    );
  }
}

/// Başlatma başarısız olursa (ör. varlık dosyaları eksik) gösterilir.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Quanta başlatılamadı. Uygulamayı yeniden yükleyin veya '
                'sürüm gerekli varlık dosyalarını içermiyorsa geliştiriciye '
                'bildirin.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
