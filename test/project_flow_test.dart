import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/workflow_runner.dart';
import 'package:kripton_ai/data/project_snapshot.dart';
import 'package:kripton_ai/domain/entities.dart';

import 'helpers.dart';

const _task = 'Vulkan bellek yönetimi hakkında çalışma hazırla';

const _plan =
    'Plan: lib/bellek.dart dosyasını ekle ve Vulkan bellek yönetimi sınıfını yaz. '
    'Başka dosyalara dokunma, mevcut yapıyı koru.';

const _zipOut = '''
Dosya: lib/bellek.dart
```dart
// Vulkan bellek yönetimi
class BellekYoneticisi {
  void ayir() {}
}
```
''';

RunCallbacks _cb() => RunCallbacks(
  status: (_) {},
  log: (_) {},
  token: (_) {},
  live: (_) {},
  agent: (_, __, ___) {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final models = [cachedModel()];

  final base = ProjectSnapshot(
    name: 'Demo',
    text: {
      'pubspec.yaml': 'name: demo\nversion: 1.0.0+1\n\ndependencies:\n  flutter:\n    sdk: flutter\n',
      'lib/main.dart': "import 'package:flutter/material.dart';\nvoid main() {}\n",
    },
  );

  test('taban proje: özet ajan istemine girer, doğrulama geçer, dosya servisine taban iletilir', () async {
    final dir = await Directory.systemTemp.createTemp('kripton_base');
    final zipPath = '${dir.path}/demo.zip';
    await File(zipPath).writeAsBytes(base.toZipBytes(topFolder: 'Demo'));
    final engine = FakeEngine(ctx: 8192, responder: (p, c) => c == 1 ? _plan : _zipOut);
    final files = FakeFiles();
    final wf = testWorkflow(agents: 2).copyWith(
      targetFormat: OutputFormat.zip,
      task: _task,
      baseProject: zipPath,
    );

    await WorkflowRunner(engine, files, FakeStorage([], '/tmp/x')).run(wf, models, _cb(), CancelToken());

    expect(engine.prompts.first, contains('PROJE_OZETI.md'));
    expect(engine.prompts.first, contains('lib/main.dart'));
    expect(files.builds, 1);
    expect(files.lastBase, isNotNull);
    expect(files.lastBase!.name, 'Demo');
    expect(files.lastTask, _task);
    // Taban projede olmayan, modelin yazdığı dosya doğrulamadan geçip içerikte durur.
    expect(files.lastContent, contains('lib/bellek.dart'));
  });

  test('taban proje okunamazsa Türkçe bir hata fırlar', () async {
    final engine = FakeEngine(ctx: 8192, responder: (p, c) => _zipOut);
    final wf = testWorkflow(agents: 1).copyWith(
      targetFormat: OutputFormat.zip,
      task: _task,
      baseProject: '/yok/boyle/bir/dosya.zip',
    );
    expect(
      () => WorkflowRunner(engine, FakeFiles(), FakeStorage([], '/tmp/x')).run(wf, models, _cb(), CancelToken()),
      throwsA(isA<StateError>()),
    );
  });

  test('taban proje yokken istem değişmez (PROJE_OZETI.md eklenmez)', () async {
    final engine = FakeEngine(ctx: 8192, responder: (p, c) => c == 1 ? _plan : _zipOut);
    final files = FakeFiles();
    final wf = testWorkflow(agents: 2).copyWith(targetFormat: OutputFormat.zip, task: _task);
    await WorkflowRunner(engine, files, FakeStorage([], '/tmp/x')).run(wf, models, _cb(), CancelToken());
    expect(engine.prompts.any((p) => p.contains('PROJE_OZETI.md')), isFalse);
    expect(files.lastBase, isNull);
  });

  test('Workflow.baseProject JSON gidiş-dönüşte korunur; eski kayıtlarda null', () {
    final wf = testWorkflow().copyWith(baseProject: 'asset:self');
    expect(Workflow.fromJson(wf.toJson()).baseProject, 'asset:self');
    expect(Workflow.fromJson(testWorkflow().toJson()).baseProject, isNull);
  });
}
