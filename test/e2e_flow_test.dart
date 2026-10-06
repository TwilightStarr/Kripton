import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/app_controller.dart';
import 'package:kripton_ai/application/output_validator.dart';
import 'package:kripton_ai/application/token_budget.dart';
import 'package:kripton_ai/application/workflow_runner.dart';
import 'package:kripton_ai/domain/entities.dart';

import 'helpers.dart';

// ---- Sahte model çıktıları ----
// Görev: "Vulkan bellek yönetimi" -> anahtar kök: vulka / belle / yonet.
const _task = 'Vulkan bellek yönetimi hakkında çalışma hazırla';

/// Görev kelimelerini içeren, biçim sözleşmesine uyan çıktılar.
const _relevant = <OutputFormat, String>{
  OutputFormat.zip: '''
Dosya: lib/bellek.dart
```dart
// Vulkan bellek yönetimi
class BellekYoneticisi {
  void ayir() {}
}
```
''',
  OutputFormat.pptx: '''
## Vulkan bellek modeli
- Bellek türleri ve yığınlar
- Yönetim stratejileri
## Sonuç
- Alt ayırıcı kullanımı
- Ölçüm sonuçları
''',
  OutputFormat.pdf: '''
# Vulkan bellek yönetimi
## Özet
Vulkan uygulamalarında bellek yönetimi performansı belirler.
- Alt ayırıcı kullanımı
- Yığın seçimi
''',
  OutputFormat.docx: '''
# Vulkan bellek yönetimi raporu
## Giriş
Bu belge bellek yönetimi seçeneklerini özetler.
- Ayırıcı stratejileri
- Ölçüm yöntemi
''',
  OutputFormat.txt:
      'Vulkan bellek yönetimi notları: alt ayırıcı kullanımı, yığın seçimi ve ölçüm yöntemi kısaca özetlenmiştir.',
};

/// Biçim olarak GEÇERLİ ama göreve (Vulkan/bellek) tamamen ALAKASIZ çıktılar.
const _unrelated = <OutputFormat, String>{
  OutputFormat.zip: '''
Dosya: lib/tarif.dart
```dart
// kek tarifi
class Kek {
  void pisir() {}
}
```
''',
  OutputFormat.pptx: '''
## Yemek
- un ve şeker karıştırılır
- fırında pişirilir
## Servis
- sıcak servis edilir
- yanına çay verilir
''',
  OutputFormat.pdf: '''
# Kek tarifi
## Malzemeler
Un, şeker ve yumurta karıştırılır, fırında pişirilir.
- Bir paket kabartma tozu
- Yarım bardak süt
''',
  OutputFormat.docx: '''
# Kek tarifi
## Malzemeler
Un, şeker ve yumurta karıştırılır, fırında pişirilir.
- Bir paket kabartma tozu
- Yarım bardak süt
''',
};

const _generic =
    'Vulkan bellek yönetimi için ilk taslak: ayırıcı stratejileri, yığın seçimi ve ölçüm yöntemi listelendi.';

const _thinkClosed =
    '<think>Önce görevi düşünmem gerekiyor, adım adım çözümleyeyim ve sonra karar vereyim.</think>';
const _thinkOpen =
    '<think>Önce görevi düşünmem gerekiyor, adım adım çözümleyeyim ama bitiremedim';

const _contractMark = 'ÇIKTI BİÇİMİ SÖZLEŞMESİ';

/// Sözleşme eklenen (son/üretici) ajan için [producerOutput], diğerleri için ham taslak döner.
String Function(String, int) _byRole(String producerOutput) =>
    (prompt, call) => prompt.contains(_contractMark) ? producerOutput : _generic;

class _Run {
  final logs = <ExecutionLog>[];
  final outputs = <String, AgentOutput>{};
  final notices = <String>[];
  final events = <String>[]; // 'notice' / 'generate' sırası

  RunCallbacks get cb => RunCallbacks(
    status: (_) {},
    log: logs.add,
    token: (_) {},
    live: (_) {},
    agent: (_, __, ___) {},
    agentOutput: (o) => outputs[o.agentId] = o,
    notice: (m) {
      notices.add(m);
      events.add('notice');
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final models = [cachedModel()];

  WorkflowRunner runner(FakeEngine e, FakeFiles f) =>
      WorkflowRunner(e, f, FakeStorage([], '/tmp/x'));

  Workflow flow(OutputFormat f, {int agents = 2, String task = _task}) =>
      testWorkflow(agents: agents).copyWith(targetFormat: f, task: task);

  group('küçük bağlam uyarısı (saf bütçe mantığı)', () {
    test('ctx 2048 / 4096 uyarır ve çıktı sınırını söyler; 8192 uyarmaz', () {
      final w2 = lowContextWarning(2048);
      expect(w2, isNotNull);
      expect(w2, contains('en fazla ~512 token'));
      expect(w2, contains('uzun görevleri parçala'));
      expect(lowContextWarning(4096), contains('~1024 token'));
      expect(lowContextWarning(8192), isNull);
    });

    test('eşik: cevap payı 1536 token ve üstü uyarmaz', () {
      expect(lowContextWarning(6144), isNull); // 6144 × %25 = 1536
      expect(lowContextWarning(6000), contains('~1500 token'));
    });

    test('küçük batch prompt alanını daraltır -> prompt uyarısı da eklenir', () {
      final w = lowContextWarning(8192, batch: 256);
      expect(w, isNotNull);
      expect(w, isNot(contains('çıktı en fazla'))); // cevap payı yeterli (2048)
      expect(w, contains('Ajanlara aktarılabilen girdi'));
    });

    test('DeepSeek: <think> payı cevap payından ayrı sayılır', () {
      final b = PromptBudget.of(4096, deepseek: true);
      expect(b.answerTokens, b.maxNew - b.thinkTokens);
      expect(lowContextWarning(4096, template: ChatTemplate.deepseek), contains('~${b.answerTokens} token'));
    });
  });

  group('küçük bağlam uyarısı (akışta)', () {
    test('ctx 2048: uyarı İLK üretimden önce verilir, günlüğe de yazılır', () async {
      final run = _Run();
      final engine = FakeEngine(
        ctx: 2048,
        responder: (p, c) {
          run.events.add('generate');
          return _relevant[OutputFormat.pptx]!;
        },
      );
      await runner(engine, FakeFiles()).run(flow(OutputFormat.pptx, agents: 1), models, run.cb, CancelToken());
      expect(run.notices, hasLength(1));
      expect(run.notices.single, contains('en fazla ~512 token'));
      expect(run.events.first, 'notice');
      expect(run.events.indexOf('notice'), lessThan(run.events.indexOf('generate')));
      expect(
        run.logs.any((l) => l.type == LogType.warning && l.message.contains('uzun görevleri parçala')),
        isTrue,
      );
    });

    test('ctx 8192 veya bilinmiyor (null): uyarı yok', () async {
      for (final ctx in <int?>[8192, null]) {
        final run = _Run();
        final engine = FakeEngine(ctx: ctx, responder: (p, c) => _relevant[OutputFormat.pptx]!);
        await runner(engine, FakeFiles()).run(flow(OutputFormat.pptx, agents: 1), models, run.cb, CancelToken());
        expect(run.notices, isEmpty, reason: 'ctx=$ctx');
      }
    });
  });

  group('uçtan uca: görev kelimeleri geçen akış her biçimde başarılı', () {
    for (final f in OutputFormat.values) {
      test('${f.name}: iki ajanlı akış, sözleşme yalnızca son ajana eklenir, dosya üretilir', () async {
        final run = _Run();
        final files = FakeFiles();
        // TXT'de sözleşme yoktur; bu yüzden rol yerine çağrı sırasına bakılır: 1. ajan taslak, 2. ajan nihai çıktı.
        final engine = FakeEngine(ctx: 8192, responder: (p, c) => c == 1 ? _generic : _relevant[f]!);
        final art = await runner(engine, files).run(flow(f), models, run.cb, CancelToken());

        expect(art.format, f);
        expect(files.builds, 1);
        expect(files.lastContent, _relevant[f]!.trim());
        expect(engine.generateCalls, 2, reason: 'doğrulama geçtiği için düzeltme turu yok');
        expect(engine.prompts.first, isNot(contains(_contractMark)));
        expect(engine.prompts.last, f == OutputFormat.txt ? isNot(contains(_contractMark)) : contains(_contractMark));

        // Ajan çıktıları bölümü için veri: iki ajan tamam; TXT dışında doğrulayıcı da tamam.
        expect(run.outputs['a1']!.status, AgentOutputStatus.ok);
        expect(run.outputs['a2']!.status, AgentOutputStatus.ok);
        expect(run.outputs['a2']!.chars, _relevant[f]!.trim().length);
        if (f == OutputFormat.txt) {
          expect(run.outputs.containsKey(AgentOutput.validatorId), isFalse);
        } else {
          expect(run.outputs[AgentOutput.validatorId]!.status, AgentOutputStatus.ok);
        }
      });
    }
  });

  group('uçtan uca: alakasız sahte çıktı doğrulayıcıya takılır', () {
    for (final f in _unrelated.keys) {
      test('${f.name}: biçim geçerli ama görevle ilgisiz -> dosya yok, ilgisizlik raporlanır', () async {
        final run = _Run();
        final files = FakeFiles();
        final engine = FakeEngine(ctx: 8192, responder: _byRole(_unrelated[f]!));
        // Önkoşul: çıktı biçim olarak geçerli; takılma nedeni yalnızca ilgisizlik olmalı.
        final pre = OutputValidator.validate(format: f, task: _task, output: _unrelated[f]!);
        expect(pre.problems.any((p) => p.contains('ilgisiz')), isTrue);
        expect(pre.problems.where((p) => !p.contains('ilgisiz')), isEmpty, reason: pre.summary);

        Object? error;
        try {
          await runner(engine, files).run(flow(f), models, run.cb, CancelToken());
        } catch (e) {
          error = e;
        }
        expect(error, isA<OutputValidationException>());
        final ex = error as OutputValidationException;
        expect(ex.problems.any((p) => p.contains('ilgisiz')), isTrue);
        expect(ex.content, _unrelated[f]!.trim());
        expect(files.builds, 0);
        expect(engine.generateCalls, 3, reason: '2 ajan + üretici için tek düzeltme turu');
        expect(engine.prompts.last, contains('DÜZELTME TALİMATI'));

        final v = run.outputs[AgentOutput.validatorId]!;
        expect(v.status, AgentOutputStatus.failed);
        expect(v.note, contains('ilgisiz'));
        expect(run.outputs['a2']!.status, AgentOutputStatus.failed, reason: 'sorun a2 adımında işaretlenir');
        expect(run.outputs['a1']!.status, AgentOutputStatus.ok);
      });
    }

    test('ilk çıktı alakasız, düzeltme turunda ilgili çıktı gelirse akış başarılı olur', () async {
      final run = _Run();
      final files = FakeFiles();
      final engine = FakeEngine(
        ctx: 8192,
        responder: (p, c) => !p.contains(_contractMark)
            ? _generic
            : (p.contains('DÜZELTME TALİMATI') ? _relevant[OutputFormat.pptx]! : _unrelated[OutputFormat.pptx]!),
      );
      await runner(engine, files).run(flow(OutputFormat.pptx), models, run.cb, CancelToken());
      expect(files.builds, 1);
      expect(files.lastContent, _relevant[OutputFormat.pptx]!.trim());
      expect(run.outputs['a2']!.status, AgentOutputStatus.corrected);
      expect(run.outputs[AgentOutput.validatorId]!.status, AgentOutputStatus.ok);
    });
  });

  group('uçtan uca: think-only çıktı', () {
    for (final think in [_thinkClosed, _thinkOpen]) {
      test('yalnızca <think> (${think == _thinkClosed ? 'kapalı' : 'kesilmiş'}): hata verir, bir kez yeniden denenir, dosya üretilmez', () async {
        final run = _Run();
        final files = FakeFiles();
        final engine = FakeEngine(ctx: 8192, responder: (p, c) => think);
        Object? error;
        try {
          await runner(engine, files).run(flow(OutputFormat.pptx, agents: 1), models, run.cb, CancelToken());
        } catch (e) {
          error = e;
        }
        expect(error, isA<StateError>());
        expect(error.toString(), contains('iki denemede de geçerli çıktı üretemedi'));
        expect(error.toString(), contains('Model yalnızca düşünce üretti'));
        expect(engine.generateCalls, 2, reason: 'ilk deneme + tek yeniden deneme');
        expect(files.builds, 0);
        expect(
          run.logs.any((l) => l.type == LogType.warning && l.message.contains('Bir kez yeniden deneniyor')),
          isTrue,
        );
        // Sonuç ekranı verisi: sorun hangi ajanda, ne olduğu.
        final o = run.outputs['a1']!;
        expect(o.status, AgentOutputStatus.failed);
        expect(o.note, contains('düşünce'));
        expect(o.chars, 0);
      });
    }

    test('doğrulayıcının düzeltme turunda think-only gelirse dosya yine üretilmez; ilk çıktı saklanır', () async {
      const bad = 'Bu çıktı slayt biçiminde değil, Vulkan bellek yönetimi hakkında düz paragraf olarak yazılmış bir metindir.';
      final run = _Run();
      final files = FakeFiles();
      final engine = FakeEngine(ctx: 8192, responder: (p, c) => c == 1 ? bad : _thinkClosed);
      Object? error;
      try {
        await runner(engine, files).run(flow(OutputFormat.pptx, agents: 1), models, run.cb, CancelToken());
      } catch (e) {
        error = e;
      }
      expect(error, isA<OutputValidationException>());
      expect((error as OutputValidationException).content, bad);
      expect(engine.generateCalls, 3, reason: 'ilk üretim + düzeltme turunda 2 deneme');
      expect(files.builds, 0);
      expect(run.logs.any((l) => l.message.contains('Düzeltme denemesi başarısız')), isTrue);
      expect(run.outputs[AgentOutput.validatorId]!.status, AgentOutputStatus.failed);
      final a1 = run.outputs['a1']!;
      expect(a1.status, AgentOutputStatus.failed);
      expect(a1.note, contains('Düzeltme denemesi başarısız'));
      expect(a1.preview, bad, reason: 'kullanıcı \"yine de indir\" için ilk çıktıyı görebilir');
    });

    test('<think> bloğu + geçerli içerik: düşünce atılır, içerik doğrulanıp dosyaya gider', () async {
      final files = FakeFiles();
      final engine = FakeEngine(ctx: 8192, responder: (p, c) => '$_thinkClosed\n${_relevant[OutputFormat.pptx]!}');
      await runner(engine, files).run(flow(OutputFormat.pptx, agents: 1), models, _Run().cb, CancelToken());
      expect(files.builds, 1);
      expect(files.lastContent, _relevant[OutputFormat.pptx]!.trim());
      expect(files.lastContent, isNot(contains('<think>')));
      expect(engine.generateCalls, 1);
    });
  });

  group('AppController: arayüz durumu (sahte motor)', () {
    late FakeEngine engine;
    late FakeFiles files;
    late ProviderContainer container;

    Future<AppController> setUp0(FakeEngine e, Workflow wf) async {
      engine = e;
      files = FakeFiles();
      final model = await File('${Directory.systemTemp.path}/kripton_fake_model.gguf').writeAsString('x');
      container = ProviderContainer(overrides: [
        engineProvider.overrideWithValue(engine),
        fileServiceProvider.overrideWithValue(files),
        storageProvider.overrideWithValue(FakeStorage([wf], model.path)),
      ]);
      addTearDown(container.dispose);
      container.read(appProvider);
      await waitFor(() => container.read(appProvider).loaded);
      return container.read(appProvider.notifier);
    }

    AppState st() => container.read(appProvider);

    test('başarılı akış: küçük bağlam uyarısı state\'te, ajan çıktıları ve doğrulayıcı listelenir', () async {
      final c = await setUp0(
        FakeEngine(ctx: 4096, responder: _byRole(_relevant[OutputFormat.pptx]!)),
        flow(OutputFormat.pptx),
      );
      await c.start().timeout(const Duration(seconds: 5));
      final s = st();
      expect(s.failed, isFalse);
      expect(s.artifact, isNotNull);
      expect(s.contextWarning, contains('~1024 token'));
      expect(s.agentOutputs.map((o) => o.agentId), containsAll(['a1', 'a2', AgentOutput.validatorId]));
      expect(s.agentOutputs.every((o) => o.status == AgentOutputStatus.ok), isTrue);
    });

    test('doğrulama reddi: rejected + hata detayı + ajan çıktıları; "yine de indir" dosyayı üretir', () async {
      final c = await setUp0(
        FakeEngine(ctx: 8192, responder: _byRole(_unrelated[OutputFormat.pptx]!)),
        flow(OutputFormat.pptx),
      );
      await c.start().timeout(const Duration(seconds: 5));
      var s = st();
      expect(s.failed, isTrue);
      expect(s.artifact, isNull);
      expect(s.rejected, isNotNull);
      expect(s.rejected!.problems.any((p) => p.contains('ilgisiz')), isTrue);
      expect(s.status, contains('Yine de indir'));
      expect(s.agentOutputs.firstWhere((o) => o.isValidator).status, AgentOutputStatus.failed);
      expect(s.agentOutputs.firstWhere((o) => o.agentId == 'a2').status, AgentOutputStatus.failed);
      expect(files.builds, 0);

      await c.downloadAnyway();
      s = st();
      expect(files.builds, 1);
      expect(files.lastContent, _unrelated[OutputFormat.pptx]!.trim());
      expect(s.artifact, isNotNull);
      expect(s.rejected, isNull);
      expect(s.failed, isFalse);
      expect(s.agentOutputs, isNotEmpty, reason: 'ajan çıktıları indirme sonrası da görünür kalır');
    });

    test('think-only: akış hatayla biter, rejected yok, sorun a1 adımında görünür', () async {
      final c = await setUp0(
        FakeEngine(ctx: 8192, responder: (p, c) => _thinkClosed),
        flow(OutputFormat.pptx, agents: 1),
      );
      await c.start().timeout(const Duration(seconds: 5));
      final s = st();
      expect(s.failed, isTrue);
      expect(s.rejected, isNull);
      expect(s.artifact, isNull);
      expect(s.status, contains('Model yalnızca düşünce üretti'));
      final o = s.agentOutputs.single;
      expect(o.agentId, 'a1');
      expect(o.status, AgentOutputStatus.failed);
      expect(files.builds, 0);
    });

    test('yeni akış önceki ajan çıktılarını ve bağlam uyarısını temizler', () async {
      final c = await setUp0(
        FakeEngine(ctx: 2048, responder: (p, c) => _thinkClosed),
        flow(OutputFormat.pptx, agents: 1),
      );
      await c.start().timeout(const Duration(seconds: 5));
      expect(st().agentOutputs.single.status, AgentOutputStatus.failed);
      expect(st().contextWarning, contains('~512 token'));

      engine
        ..ctx = 8192
        ..responder = (p, c) => _relevant[OutputFormat.pptx]!;
      await c.start().timeout(const Duration(seconds: 5));
      final s = st();
      expect(s.failed, isFalse);
      expect(s.contextWarning, isNull);
      expect(s.agentOutputs.every((o) => o.status == AgentOutputStatus.ok), isTrue);
      expect(s.artifact, isNotNull);
    });
  });
}
