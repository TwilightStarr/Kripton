import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/settings_controller.dart';
import 'core/theme.dart';
import 'data/storage.dart';
import 'data/crash_guard.dart';
import 'data/crash_report.dart';
import 'data/native_services.dart';
import 'application/app_controller.dart' show appProvider;
import 'domain/start_screen.dart';
import 'presentation/chat_page.dart';
import 'presentation/dev_mode_page.dart';
import 'presentation/home_page.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    final prev = await CrashGuard.init();

    // Android'in gerçek çıkış nedeni (Android 11+). Yoksa null; o zaman neden "bilinmiyor" olur.
    final exit = await ProcessExitInfo.lastSince(CrashGuard.exitSeenMs);
    if (exit != null) {
      CrashGuard.setExitSeen(exit.timestamp);
      CrashGuard.log(
        'Süreç çıkışı: ${exit.reasonName}',
        'neden=${exit.reason} açıklama=${exit.description} önem=${exit.importance} '
            'pssKb=${exit.pssKb} rssKb=${exit.rssKb}',
        null,
      );
      final trace = exit.trace;
      if (trace != null && trace.isNotEmpty) {
        CrashGuard.log('Tombstone (${exit.reasonName})', trace, null);
      }
    }

    final wasLowMemoryKill = isLowMemoryKill(
      reasonName: exit?.reasonName,
      status: exit?.status,
      trace: exit?.trace,
    );
    final kind = classifyExit(
      hadPendingOp: prev != null,
      reasonName: exit?.reasonName,
      lowMemoryKill: wasLowMemoryKill,
    );
    if (wasLowMemoryKill ||
        (prev != null &&
            kind != CrashKind.none &&
            kind != CrashKind.userStopped)) {
      CrashGuard.recordCrash(); // art arda çökmede yükleme profili küçülür
      if (wasLowMemoryKill) {
        CrashGuard.log(
          'LMK/SIGKILL tespit edildi',
          'Sonraki yüklemede memoryPlan içindeki bir sonraki küçük aday seçilecek.',
          null,
        );
      }
    }

    FlutterError.onError = (d) {
      FlutterError.presentError(d);
      CrashGuard.log('FlutterError', d.exception, d.stack);
    };
    PlatformDispatcher.instance.onError = (e, st) {
      CrashGuard.log('PlatformDispatcher', e, st);
      return true;
    };
    // Tema ilk karede doğru çıksın diye tercihler runApp'ten önce okunur.
    final settings = await AppSettings.load(Storage());
    KPalette.current = KPalette.byId(settings.themeId);
    runApp(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => SettingsController(settings)),
        ],
        child: const KriptonApp(),
      ),
    );

    final dlg = crashDialogFor(
      kind,
      reasonName: wasLowMemoryKill && exit?.reasonName != 'LOW_MEMORY'
          ? 'SIGKILL'
          : exit?.reasonName,
      signal: signalFromTrace(exit?.trace),
      op: prev,
    );
    if (dlg != null)
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showCrashDialog(dlg),
      );
  }, (e, st) => CrashGuard.log('Zone', e, st));
}

void _showCrashDialog(CrashDialog d) {
  final ctx = navigatorKey.currentState?.overlay?.context;
  if (ctx == null) return;
  showDialog<void>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: Text(d.title),
      content: Text(d.body),
      actions: [
        TextButton(
          onPressed: () async {
            final text = await CrashGuard.readLog();
            await Clipboard.setData(
              ClipboardData(text: text.isEmpty ? '(crash.log boş)' : text),
            );
            if (c.mounted) {
              ScaffoldMessenger.maybeOf(c)?.showSnackBar(
                const SnackBar(content: Text('crash.log panoya kopyalandı')),
              );
            }
          },
          child: const Text('Kopyala'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Tamam'),
        ),
      ],
    ),
  );
}

class KriptonApp extends ConsumerStatefulWidget {
  const KriptonApp({super.key});

  @override
  ConsumerState<KriptonApp> createState() => _KriptonAppState();
}

class _KriptonAppState extends ConsumerState<KriptonApp> {
  StreamSubscription<String>? _memoryNotifications;

  /// Açılış ekranı yalnızca açılışta okunur; ayar değişince çalışan uygulama başka ekrana atlamaz.
  late final Widget _home;

  @override
  void initState() {
    super.initState();
    _home = switch (ref.read(settingsProvider).startScreen) {
      StartScreen.flow => const HomePage(),
      StartScreen.chat => const _AppNotices(child: ChatPage()),
      StartScreen.dev => const _AppNotices(child: DevModePage()),
    };
    _memoryNotifications = MemInfoNative.notifications.listen((message) {
      final context = navigatorKey.currentState?.overlay?.context;
      if (context == null) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
      );
    });
  }

  @override
  void dispose() {
    _memoryNotifications?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Tema kimliği değişince MaterialApp yeni ThemeData ile kurulur; KColors okuyan
    // (çoğu const) widget'lar da bir sonraki karede toptan yeniden kurulur.
    ref.listen<String>(settingsProvider.select((s) => s.themeId), (_, __) {
      WidgetsBinding.instance.addPostFrameCallback((_) => kRebuildAll());
    });
    final themeId = ref.watch(settingsProvider.select((s) => s.themeId));
    final palette = KPalette.byId(themeId);
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Kripton Yapay Zekâ Agent',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(palette),
      themeAnimationDuration: Duration.zero,
      home: _home,
    );
  }
}

/// Ana ekran ([HomePage]) kökte değilken (Sohbet / Geliştirme açılışı) AppController bildirimlerini
/// (indirme hatası, uyarılar vb.) gösterir; HomePage kökteyken kendi dinleyicisi bunu yapar.
class _AppNotices extends ConsumerWidget {
  const _AppNotices({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<int>(appProvider.select((s) => s.noticeId), (_, __) {
      final m = ref.read(appProvider).notice;
      if (m != null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(m)));
      }
    });
    return child;
  }
}
