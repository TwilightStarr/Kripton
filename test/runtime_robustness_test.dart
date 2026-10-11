import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/app_controller.dart';
import 'package:kripton_ai/application/workflow_runner.dart';
import 'package:kripton_ai/domain/entities.dart';

import 'helpers.dart';

const String _defaultText =
    'Merhaba dünya. Bu sahte çıktı, ajan kabul kapısının gerektirdiği uzunlukta bir test metnidir.';

class _Rec {
  final logs = <ExecutionLog>[];
  final tokens = StringBuffer();
  int tokenCalls = 0;
  bool throwOnFirstToken = false;
  bool _thrown = false;

  RunCallbacks get cb => RunCallbacks(
        status: (_) {},
        log: logs.add,
        token: (t) {
          tokenCalls++;
          if (throwOnFirstToken && !_thrown) {
            _thrown = true;
            throw StateError('arayüz callback hatası');
          }
          tokens.write(t);
        },
        live: (_) {},
        agent: (_, __, ___) {},
      );
}

class _BrokenRegistryStorage extends FakeStorage {
  _BrokenRegistryStorage(super.workflows, super.modelFile);

  @override
  Future<Map<String, Map<String, String>>> loadRegistry() async => throw StateError('kayıt bozuk');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final models = [cachedModel()];

  group('CancelToken.wait', () {
    test('süre dolunca döner; iptalde bekleyenler anında uyanır; zamanlayıcı/uyuyan birikmez', () async {
      final ct = CancelToken();
      final sw = Stopwatch()..start();
      await ct.wait(const Duration(milliseconds: 50));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(40));
      expect(ct.pendingWaits, 0);

      final f = ct.wait(const Duration(seconds: 30));
      final g = ct.wait(const Duration(seconds: 30));
      expect(ct.pendingWaits, 2);
      ct.cancel();
      await Future.wait([f, g]).timeout(const Duration(seconds: 1));
      expect(ct.pendingWaits, 0);
      await ct.wait(const Duration(seconds: 30)).timeout(const Duration(seconds: 1)); // zaten iptal
    });

    test('çok sayıda ardışık bekleme sonrasında bekleyen kayıt kalmaz', () async {
      final ct = CancelToken();
      for (var i = 0; i < 200; i++) {
        await ct.wait(const Duration(milliseconds: 1));
      }
      expect(ct.pendingWaits, 0);
    });
  });

  group('WorkflowRunner', () {
    test('takılan üretim (olay gelmez) bekçi tarafından kesilir, yeniden denenir ve akış tamamlanır', () async {
      final engine = FakeEngine(hangOnCall: 1);
      final files = FakeFiles();
      final rec = _Rec();
      final runner = WorkflowRunner(engine, files, FakeStorage([], '/tmp/x'))
        ..streamIdleTimeout = const Duration(milliseconds: 200);
      await runner
          .run(testWorkflow(agents: 1), models, rec.cb, CancelToken())
          .timeout(const Duration(seconds: 10));
      expect(engine.generateCalls, 2, reason: 'ilk deneme takıldı, ikincisi başarılı');
      expect(engine.stopCalls, greaterThanOrEqualTo(1));
      expect(files.lastContent, _defaultText);
      expect(rec.logs.any((l) => l.message.contains('boyunca çıktı vermedi')), isTrue);
    });

    test('bekçi kapalıyken (Duration.zero) takılan üretim yalnızca iptalle çıkar', () async {
      final engine = FakeEngine(hangOnCall: 1);
      final rec = _Rec();
      final ct = CancelToken();
      final runner = WorkflowRunner(engine, FakeFiles(), FakeStorage([], '/tmp/x'))
        ..streamIdleTimeout = Duration.zero;
      final f = runner.run(testWorkflow(agents: 1), models, rec.cb, ct);
      final result = expectLater(f, throwsA(isA<CancelledException>()));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(engine.generateCalls, 1);
      ct.cancel();
      await result.timeout(const Duration(seconds: 3));
    });

    test('token callback istisnası yakalanmamış hataya dönüşmez; deneme yenilenir', () async {
      final zoneErrors = <Object>[];
      final finished = Completer<void>();
      final rec = _Rec()..throwOnFirstToken = true;
      final files = FakeFiles();
      runZonedGuarded(() async {
        try {
          await WorkflowRunner(FakeEngine(), files, FakeStorage([], '/tmp/x'))
              .run(testWorkflow(agents: 1), models, rec.cb, CancelToken());
        } finally {
          finished.complete();
        }
      }, (e, st) => zoneErrors.add(e));
      await finished.future.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(zoneErrors, isEmpty);
      expect(files.lastContent, _defaultText);
      expect(rec.tokenCalls, greaterThanOrEqualTo(2));
    });
  });

  group('AppController', () {
    Future<ProviderContainer> make(FakeEngine engine, {FakeStorage? storage}) async {
      final model = await File('${Directory.systemTemp.path}/kripton_fake_model.gguf').writeAsString('x');
      return ProviderContainer(overrides: [
        engineProvider.overrideWithValue(engine),
        fileServiceProvider.overrideWithValue(FakeFiles()),
        storageProvider.overrideWithValue(storage ?? FakeStorage([testWorkflow()], model.path)),
      ]);
    }

    test('açılışta depolama hatası: arayüz yüklemede takılmaz, varsayılan akışlarla açılır', () async {
      final model = await File('${Directory.systemTemp.path}/kripton_fake_model.gguf').writeAsString('x');
      final container = await make(
        FakeEngine(),
        storage: _BrokenRegistryStorage([testWorkflow()], model.path),
      );
      addTearDown(container.dispose);
      container.read(appProvider);
      await waitFor(() => container.read(appProvider).loaded);
      final s = container.read(appProvider);
      expect(s.workflows, isNotEmpty);
      expect(s.models, isNotEmpty);
      expect(s.notice, contains('varsayılan'));
    });

    test('çalışırken dispose: yakalanmamış istisna yok, başlat Future\'ı tamamlanır', () async {
      final engine = FakeEngine(hangOnCall: 1);
      final container = await make(engine);
      container.read(appProvider);
      await waitFor(() => container.read(appProvider).loaded);
      final c = container.read(appProvider.notifier);

      final zoneErrors = <Object>[];
      final finished = Completer<void>();
      runZonedGuarded(() async {
        final run = c.start();
        await waitFor(() => engine.generateCalls == 1);
        container.dispose();
        await run.timeout(const Duration(seconds: 5));
        finished.complete();
      }, (e, st) {
        zoneErrors.add(e);
        if (!finished.isCompleted) finished.complete();
      });
      await finished.future.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(zoneErrors, isEmpty);
    });
  });
}
