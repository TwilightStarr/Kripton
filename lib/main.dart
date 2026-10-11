import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/settings_controller.dart';
import 'core/theme.dart';
import 'data/storage.dart';
import 'data/crash_guard.dart';
import 'data/crash_report.dart';
import 'data/error_reporter.dart';
import 'data/native_services.dart';
import 'application/app_controller.dart' show appProvider;
import 'domain/start_screen.dart';
import 'presentation/chat_page.dart';
import 'presentation/dev_mode_page.dart';
import 'presentation/home_page.dart';

final navigatorKey = GlobalKey<NavigatorState>();

/// Tüm hata kanallarını (Flutter çerçevesi, platform, zone, isolate) tek raporlayıcıya bağlar.
/// Her hata önce crash.log'a yazılır; kullanıcıya anlaşılır Türkçe mesaj gösterilir.
void installErrorHandlers({bool isolateListener = true}) {
  FlutterError.onError = (details) {
    try {
      FlutterError.presentError(details);
    } catch (_) {}
    ErrorReporter.instance.report('FlutterError', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorReporter.instance.report('PlatformDispatcher', error, stack);
    return true; // işlendi: süreç düşmez
  };
  if (isolateListener) {
    try {
      Isolate.current.addErrorListener(
      RawReceivePort((dynamic pair) {
        final list = pair is List ? pair : const <dynamic>[];
        final err = list.isNotEmpty ? list.first : pair;
        final st = list.length > 1 ? StackTrace.fromString('${list.last}') : null;
        ErrorReporter.instance.report('Isolate', err ?? 'bilinmeyen isolate hatası', st);
      }).sendPort,
    );
    } catch (_) {}
  }
  if (kReleaseMode) {
    // Çizim sırasında oluşan hata kırmızı/gri kutu yerine anlaşılır bir yer tutucu gösterir.
    ErrorWidget.builder = (details) => const _FriendlyErrorBox();
  }
}

/// Açılış adımını korur: hata günlüğe yazılır, açılış sürer (null döner).
Future<T?> _guarded<T>(String what, Future<T> Function() f) async {
  try {
    return await f();
  } catch (e, st) {
    ErrorReporter.instance.report('Açılış: $what', e, st, false);
    return null;
  }
}

Future<void> main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      installErrorHandlers();
      try {
        await _bootstrap();
      } catch (e, st) {
        // Açılışın kendisi çökerse: boş ekran yerine anlaşılır hata ekranı.
        ErrorReporter.instance.report('Açılış', e, st, false);
        runApp(_FatalApp(describeError(e, st, 'Açılış')));
      }
    },
    (e, st) => ErrorReporter.instance.report('Zone', e, st),
  );
}

Future<void> _bootstrap() async {
  final prev = await _guarded('CrashGuard.init', () => CrashGuard.init());

  // Android'in gerçek çıkış nedeni (Android 11+). Yoksa null; o zaman neden "bilinmiyor" olur.
  final exit = await _guarded('ProcessExitInfo', () => ProcessExitInfo.lastSince(CrashGuard.exitSeenMs));
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
  if (wasLowMemoryKill || (prev != null && kind != CrashKind.none && kind != CrashKind.userStopped)) {
    CrashGuard.recordCrash(); // art arda çökmede yükleme profili küçülür
    if (wasLowMemoryKill) {
      CrashGuard.log(
        'LMK/SIGKILL tespit edildi',
        'Sonraki yüklemede memoryPlan içindeki bir sonraki küçük aday seçilecek.',
        null,
      );
    }
  }

  // Tema ilk karede doğru çıksın diye tercihler runApp'ten önce okunur (bozuk dosyada varsayılanlar).
  final settings = await _guarded('Ayarlar', () => AppSettings.load(Storage())) ?? const AppSettings();
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
    reasonName: wasLowMemoryKill && exit?.reasonName != 'LOW_MEMORY' ? 'SIGKILL' : exit?.reasonName,
    signal: signalFromTrace(exit?.trace),
    op: prev,
  );
  if (dlg != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _showCrashDialog(dlg));
  }
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

/// Hata ayrıntısı penceresi: anlaşılır mesaj üstte, teknik ayrıntı seçilebilir metin olarak altta.
void _showErrorDetail(UserError e) {
  final ctx = navigatorKey.currentState?.overlay?.context;
  if (ctx == null) return;
  final detail = e.detail.length > 6000 ? '${e.detail.substring(0, 6000)}…' : e.detail;
  showDialog<void>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: Text(e.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.message),
            const SizedBox(height: 12),
            const Text('Ayrıntı', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            SelectableText(detail, style: const TextStyle(fontSize: 12, fontFamily: 'DejaVuSansMono')),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: '${e.title}\n${e.message}\n\n$detail'));
            if (c.mounted) {
              ScaffoldMessenger.maybeOf(c)?.showSnackBar(
                const SnackBar(content: Text('Ayrıntı panoya kopyalandı')),
              );
            }
          },
          child: const Text('Kopyala'),
        ),
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Kapat')),
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
  int _shownErrorId = 0;

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
    ErrorReporter.instance.latest.addListener(_onUserError);
  }

  @override
  void dispose() {
    ErrorReporter.instance.latest.removeListener(_onUserError);
    _memoryNotifications?.cancel();
    super.dispose();
  }

  void _onUserError() {
    final e = ErrorReporter.instance.latest.value;
    if (e == null || e.id == _shownErrorId) return;
    _shownErrorId = e.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final ctx = navigatorKey.currentState?.overlay?.context;
        if (ctx == null) return;
        ScaffoldMessenger.maybeOf(ctx)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('${e.title}. ${e.message}'),
              duration: const Duration(seconds: 8),
              action: SnackBarAction(label: 'Ayrıntı', onPressed: () => _showErrorDetail(e)),
            ),
          );
      } catch (_) {}
    });
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

/// Çizim hatasında (yalnızca release) kırmızı/gri kutu yerine gösterilen sade yer tutucu.
class _FriendlyErrorBox extends StatelessWidget {
  const _FriendlyErrorBox();

  @override
  Widget build(BuildContext context) => const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Bu bölüm görüntülenemedi. Geri dönüp yeniden dene.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 14, decoration: TextDecoration.none),
            ),
          ),
        ),
      );
}

/// Açılış tamamen başarısız olursa gösterilen son çare ekran (Riverpod/tema gerektirmez).
class _FatalApp extends StatelessWidget {
  const _FatalApp(this.error);

  final UserError error;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(
                children: [
                  Text(error.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Uygulama başlatılamadı. Uygulamayı kapatıp yeniden açmayı dene.'),
                  const SizedBox(height: 8),
                  Text(error.message),
                  ExpansionTile(
                    title: const Text('Ayrıntı'),
                    children: [SelectableText(error.detail, style: const TextStyle(fontSize: 12))],
                  ),
                  FilledButton(
                    onPressed: () => Clipboard.setData(ClipboardData(text: '${error.title}\n${error.detail}')),
                    child: const Text('Ayrıntıyı kopyala'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
