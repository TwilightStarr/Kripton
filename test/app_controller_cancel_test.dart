import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/app_controller.dart';
import 'package:kripton_ai/domain/entities.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeEngine engine;
  late FakeFiles files;
  late ProviderContainer container;

  Future<AppController> setUp0(FakeEngine e) async {
    engine = e;
    files = FakeFiles();
    final model = await File('${Directory.systemTemp.path}/kripton_fake_model.gguf').writeAsString('x');
    container = ProviderContainer(overrides: [
      engineProvider.overrideWithValue(engine),
      fileServiceProvider.overrideWithValue(files),
      storageProvider.overrideWithValue(FakeStorage([testWorkflow()], model.path)),
    ]);
    addTearDown(container.dispose);
    container.read(appProvider);
    await waitFor(() => container.read(appProvider).loaded);
    return container.read(appProvider.notifier);
  }

  AgentStatus st(String id) =>
      container.read(appProvider).current!.agents.firstWhere((a) => a.id == id).status;

  test('6) iptal: artifact yok, çalışan düğüm idle, tamamlanan completed, günlük satırı var', () async {
    final c = await setUp0(FakeEngine(hangOnCall: 2));
    final run = c.start();
    await waitFor(() => engine.generateCalls == 2 && st('a2') == AgentStatus.running);
    await Future<void>.delayed(const Duration(milliseconds: 60)); // kısmi token gelsin
    c.cancel();
    expect(container.read(appProvider).cancelling, isTrue);
    await run.timeout(const Duration(seconds: 3));

    final s = container.read(appProvider);
    expect(s.running, isFalse);
    expect(s.cancelling, isFalse);
    expect(s.artifact, isNull);
    expect(files.builds, 0);
    expect(st('a1'), AgentStatus.completed);
    expect(st('a2'), AgentStatus.idle);
    expect(s.status, 'İşlem kullanıcı tarafından iptal edildi.');
    expect(s.logs.where((l) => l.message.startsWith('Akış iptal edildi')).length, 1);
    expect(s.logs.any((l) => l.message.contains('2. AI adımında')), isTrue);
    expect(container.read(liveTokensProvider), isNotEmpty, reason: 'kısmi çıktı silinmez');
    expect(engine.stopCalls, greaterThanOrEqualTo(1));
  });

  test('5b) cancel() iki kez güvenli; iptalden hemen sonra yeni run başlatılabilir', () async {
    final c = await setUp0(FakeEngine(hangOnCall: 1));
    final run = c.start();
    await waitFor(() => engine.generateCalls == 1);
    c.cancel();
    c.cancel(); // ikinci basış yok sayılır
    await run.timeout(const Duration(seconds: 3));
    expect(container.read(appProvider).logs.where((l) => l.message.startsWith('Akış iptal edildi')).length, 1);

    engine.hangOnCall = null;
    await c.start().timeout(const Duration(seconds: 5));
    final s = container.read(appProvider);
    expect(s.artifact, isNotNull);
    expect(s.running, isFalse);
    expect(files.builds, 1);
    expect(st('a1'), AgentStatus.completed);
    expect(st('a2'), AgentStatus.completed);
  });

  test('cancel() çalışmıyorsa hiçbir şey yapmaz', () async {
    final c = await setUp0(FakeEngine());
    c.cancel();
    final s = container.read(appProvider);
    expect(s.cancelling, isFalse);
    expect(s.status, '');
  });

  test('A4) üretim hatası: düğüm error olur, günlükte hata satırı, failed=true, yeniden başlatılabilir', () async {
    final c = await setUp0(FakeEngine(failOnCall: 1));
    await c.start().timeout(const Duration(seconds: 3));
    var s = container.read(appProvider);
    expect(s.running, isFalse);
    expect(s.failed, isTrue);
    expect(st('a1'), AgentStatus.error);
    expect(s.logs.where((l) => l.type == LogType.error).length, 1);

    engine.failOnCall = null;
    await c.start().timeout(const Duration(seconds: 5));
    s = container.read(appProvider);
    expect(s.failed, isFalse);
    expect(s.artifact, isNotNull);
  });
}
