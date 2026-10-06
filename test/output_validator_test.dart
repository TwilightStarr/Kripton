import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/output_validator.dart';
import 'package:kripton_ai/application/workflow_runner.dart';
import 'package:kripton_ai/data/default_data.dart';
import 'package:kripton_ai/data/file_service.dart';
import 'package:kripton_ai/domain/entities.dart';

import 'helpers.dart';

const _zipOk = '''
Dosya: lib/buffer.dart
```dart
class NativeBufferManager {
  void alloc() {}
}
```
''';

const _pptxOk = '''
## Mimari
- Ajanlar sırayla çalışır
- Her ajan kendi modelini kullanır
## Bellek
- mmap ile model dosyası eşlenir
- RAM tüketimi izlenir
''';

const _docOk = '''
# Vulkan raporu
## Özet
Adreno üzerinde Vulkan çıkarım ölçümleri incelendi.
- Q4_K_M daha hızlı
- Q5_K_M daha kararlı
''';

void main() {
  group('OutputContract', () {
    test('TXT dışındaki her biçim için sözleşme metni var; TXT boş', () {
      for (final f in OutputFormat.values) {
        final text = OutputContract.instruction(f);
        expect(text.isEmpty, f == OutputFormat.txt, reason: f.name);
        expect(OutputContract.appliesTo(f), f != OutputFormat.txt);
      }
      expect(OutputContract.instruction(OutputFormat.zip), contains('Dosya:'));
      expect(OutputContract.instruction(OutputFormat.pptx), contains('## '));
    });
  });

  group('OutputValidator biçim', () {
    ValidationResult v(OutputFormat f, String out, {String task = ''}) =>
        OutputValidator.validate(format: f, task: task, output: out);

    test('TXT her zaman geçer', () {
      expect(v(OutputFormat.txt, 'x').ok, isTrue);
    });

    test('ZIP: kod bloğu + dosya yolu geçer; blok yok / yol yok / kapanmamış başarısız', () {
      expect(v(OutputFormat.zip, _zipOk).ok, isTrue);
      expect(v(OutputFormat.zip, 'Sadece açıklama, kod yok.').ok, isFalse);
      expect(
        v(OutputFormat.zip, '```dart\nvoid a() {}\n```').problems.join(),
        contains('dosya yolu'),
      );
      expect(
        v(OutputFormat.zip, 'Dosya: a.dart\n```dart\nvoid a() {}\n').problems.join(),
        contains('Kapanmamış'),
      );
    });

    test('PPTX: en az 2 slayt ve madde', () {
      expect(v(OutputFormat.pptx, _pptxOk).ok, isTrue);
      expect(v(OutputFormat.pptx, '## Tek\n- a\n- b').problems.join(), contains('En az 2 slayt'));
      expect(v(OutputFormat.pptx, 'Düz paragraf\nbaşka paragraf').ok, isFalse);
    });

    test('PDF/DOCX: markdown başlığı ve gövde', () {
      expect(v(OutputFormat.pdf, _docOk).ok, isTrue);
      expect(v(OutputFormat.docx, _docOk).ok, isTrue);
      expect(v(OutputFormat.pdf, 'Başlıksız tek satır.').ok, isFalse);
    });

    test('boş çıktı başarısız', () {
      expect(v(OutputFormat.pdf, '   ').problems, ['Çıktı boş.']);
    });

    test('tekrar eden satırlardan oluşan çıktı yakalanır', () {
      final junk = '# Başlık\n${List.filled(20, 'aynı satır tekrar ediyor').join('\n')}';
      expect(v(OutputFormat.pdf, junk).problems.join(), contains('tekrar eden'));
    });
  });

  group('OutputValidator görev ilgisi', () {
    test('anahtar kelimeler Türkçe ekler ve büyük/küçük harf farkına dayanıklı', () {
      const task = 'Adreno 730 üzerinde Vulkan performans analizi raporu hazırla.';
      final ok = OutputValidator.validate(
        format: OutputFormat.pdf,
        task: task,
        output: _docOk,
      );
      expect(ok.ok, isTrue, reason: ok.summary);
      expect(taskKeywords(task), containsAll(['adreno', 'vulkan', 'performans']));
    });

    test('altı boş slayt / bölüm (yarıda kesilmiş çıktı izi) reddedilir', () {
      final cut = OutputValidator.validate(
        format: OutputFormat.pptx,
        task: '',
        output: '## A\n- bir\n- iki\n## B',
      );
      expect(cut.ok, isFalse);
      expect(cut.summary, contains('boş slayt'));
      final doc = OutputValidator.validate(
        format: OutputFormat.pdf,
        task: '',
        output: '# Başlık\n## A\nBir paragraf burada yer alıyor.\n- madde\n## B',
      );
      expect(doc.ok, isFalse);
      expect(doc.summary, contains('İçeriği olmayan bölüm'));
      // ### alt başlığı olan bölüm boş sayılmaz.
      final sub = OutputValidator.validate(
        format: OutputFormat.pdf,
        task: '',
        output: '# Başlık\n## A\n### Alt\nİçerik burada.\n- madde',
      );
      expect(sub.ok, isTrue, reason: sub.summary);
    });

    test('görevle ilgisiz çıktı reddedilir', () {
      const task = 'Adreno 730 üzerinde Vulkan performans analizi raporu hazırla.';
      const off = '# Yemek tarifi\n## Malzemeler\n- un\n- şeker\n- yumurta\nKarıştırıp fırında pişirin.';
      final r = OutputValidator.validate(
        format: OutputFormat.pdf,
        task: task,
        output: off,
      );
      expect(r.ok, isFalse);
      expect(r.summary, contains('görevle ilgisiz'));
    });

    test('görev boşsa veya yalnızca dolgu sözcük içeriyorsa ilgi denetimi yapılmaz', () {
      expect(
        OutputValidator.validate(format: OutputFormat.pdf, task: '', output: _docOk).ok,
        isTrue,
      );
      expect(taskKeywords('bir ve ile'), isEmpty);
    });
  });

  group('namedFencePaths / "Dosya:" satırı', () {
    test('Dosya: etiketi, kalın yazı ve düz yol satırı tanınır', () {
      expect(namedFencePaths('Dosya: lib/a.dart\n```dart\nx\n```'), ['lib/a.dart']);
      expect(namedFencePaths('**Dosya: lib/b.dart**\n```dart\nx\n```'), ['lib/b.dart']);
      expect(namedFencePaths('lib/c.dart\n```dart\nx\n```'), ['lib/c.dart']);
      expect(namedFencePaths('Açıklama.\n```dart\nx\n```'), isEmpty);
    });
  });

  group('migrateReasoningRoles', () {
    test('hazır akışlarda R1 yalnızca debugger kalır; kullanıcı akışlarına dokunulmaz', () {
      const deep = 'deepseek-r1-distill-7b-q4km';
      const qwen = 'qwen-2.5-coder-7b-q4km';
      final old = defaultWorkflows().map((w) {
        // Eski kayıt: PDF/PPTX 1. ajanı R1.
        return w.copyWith(
          agents: [
            for (final a in w.agents)
              a.mode == AgentMode.generator ? a.copyWith(modelId: deep) : a,
          ],
        );
      }).toList();
      final custom = testWorkflow(agents: 1).copyWith(
        agents: [testWorkflow(agents: 1).agents.first.copyWith(modelId: deep)],
      );
      final out = migrateReasoningRoles([...old, custom], qwen)!;
      for (final w in out.take(3)) {
        for (final a in w.agents) {
          if (a.mode != AgentMode.debugger) expect(a.modelId, isNot(deep));
        }
      }
      expect(out.last.agents.first.modelId, deep);
      expect(migrateReasoningRoles(out, qwen), isNull);
    });
  });

  group('varsayılan model atamaları', () {
    test('hiçbir hazır akışta üretici (generator) R1 değildir; R1 yalnızca debugger', () {
      for (final w in defaultWorkflows()) {
        for (final a in w.agents) {
          if (a.modelId == 'deepseek-r1-distill-7b-q4km') {
            expect(a.mode, AgentMode.debugger, reason: '${w.id} ${a.name}');
          }
        }
      }
      for (final f in OutputFormat.values) {
        final agents = starterAgents('x', f);
        expect(agents.first.modelId, 'qwen-2.5-coder-7b-q4km');
        expect(
          agents.where((a) => a.mode != AgentMode.debugger).every((a) => a.modelId == 'qwen-2.5-coder-7b-q4km'),
          isTrue,
        );
      }
    });
  });

  group('WorkflowRunner sözleşme + doğrulama', () {
    final models = [cachedModel()];
    RunCallbacks cb() => RunCallbacks(
      status: (_) {},
      log: (_) {},
      token: (_) {},
      live: (_) {},
      agent: (_, __, ___) {},
    );

    Workflow pptx({String task = ''}) => testWorkflow(agents: 1).copyWith(
      targetFormat: OutputFormat.pptx,
      task: task,
    );

    test('sözleşme son (üretici) ajanın system prompt\'una eklenir', () async {
      final engine = FakeEngine(responder: (p, c) => _pptxOk);
      final files = FakeFiles();
      await WorkflowRunner(engine, files, FakeStorage([], '/tmp/x')).run(
        pptx(),
        models,
        cb(),
        CancelToken(),
      );
      expect(engine.prompts.single, contains('ÇIKTI BİÇİMİ SÖZLEŞMESİ: PPTX'));
      expect(files.builds, 1);
    });

    test('ilk çıktı geçersiz -> ajan düzeltme talimatıyla BİR kez yeniden çalışır -> dosya üretilir', () async {
      final engine = FakeEngine(
        responder: (p, c) => c == 1
            ? 'Bu çıktı slayt biçiminde değil, düz bir paragraf olarak yazılmış uzun bir metindir.'
            : _pptxOk,
      );
      final files = FakeFiles();
      await WorkflowRunner(engine, files, FakeStorage([], '/tmp/x')).run(
        pptx(),
        models,
        cb(),
        CancelToken(),
      );
      expect(engine.generateCalls, 2);
      expect(engine.prompts.last, contains('DÜZELTME TALİMATI'));
      expect(files.builds, 1);
      expect(files.lastContent, _pptxOk.trim());
    });

    test('farklı sorunlar sürerken ajan birden çok kez düzeltilir; 3. denemede geçerse dosya üretilir', () async {
      const plain =
          'Bu çıktı slayt biçiminde değil, düz bir paragraf olarak yazılmış uzun bir metindir.';
      const oneSlide =
          '## Tek slayt\n- Bu madde yeterince uzun bir açıklama metnidir\n- Bir madde daha burada yer alıyor';
      final engine = FakeEngine(
        responder: (p, c) => c == 1 ? plain : (c == 2 ? oneSlide : _pptxOk),
      );
      final files = FakeFiles();
      await WorkflowRunner(engine, files, FakeStorage([], '/tmp/x')).run(
        pptx(),
        models,
        cb(),
        CancelToken(),
      );
      expect(engine.generateCalls, 3, reason: 'ilk üretim + 2 düzeltme denemesi');
      expect(engine.prompts.last, contains('DÜZELTME TALİMATI'));
      expect(files.builds, 1);
      expect(files.lastContent, _pptxOk.trim());
    });

    test('correctionAttempts üst sınırı aşılmaz; hâlâ geçersizse istisna fırlar', () async {
      const plain =
          'Bu çıktı slayt biçiminde değil, düz bir paragraf olarak yazılmış uzun bir metindir.';
      const oneSlide =
          '## Tek slayt\n- Bu madde yeterince uzun bir açıklama metnidir\n- Bir madde daha burada yer alıyor';
      const oneBullet = '## Tek slayt\n- Yalnızca tek madde ve onun yeterince uzun açıklama metni burada';
      final engine = FakeEngine(
        responder: (p, c) => c == 1 ? plain : (c == 2 ? oneSlide : oneBullet),
      );
      final files = FakeFiles();
      final runner = WorkflowRunner(engine, files, FakeStorage([], '/tmp/x'))..correctionAttempts = 2;
      Object? error;
      try {
        await runner.run(pptx(), models, cb(), CancelToken());
      } catch (e) {
        error = e;
      }
      expect(error, isA<OutputValidationException>());
      expect(engine.generateCalls, 3, reason: 'ilk üretim + en çok 2 düzeltme');
      expect(files.builds, 0);
    });

    test('düzeltme de başarısız -> dosya üretilmez, OutputValidationException içerikle birlikte fırlar', () async {
      const bad =
          'Bu çıktı slayt biçiminde değil, düz bir paragraf olarak yazılmış uzun bir metindir.';
      final engine = FakeEngine(responder: (p, c) => bad);
      final files = FakeFiles();
      final runner = WorkflowRunner(engine, files, FakeStorage([], '/tmp/x'));
      Object? error;
      try {
        await runner.run(pptx(), models, cb(), CancelToken());
      } catch (e) {
        error = e;
      }
      expect(error, isA<OutputValidationException>());
      final ex = error as OutputValidationException;
      expect(ex.content, bad);
      expect(ex.problems, isNotEmpty);
      expect(engine.generateCalls, 2);
      expect(files.builds, 0);

      // "Yine de indir" altyapısı: doğrulamayı atlayarak dosya üretir.
      await runner.buildAnyway(format: ex.format, title: ex.title, content: ex.content);
      expect(files.builds, 1);
      expect(files.lastContent, bad);
    });

    test('görevle ilgisiz çıktı reddedilir; ilgili çıktı geçer', () async {
      final files = FakeFiles();
      final engine = FakeEngine(responder: (p, c) => _pptxOk);
      await WorkflowRunner(engine, files, FakeStorage([], '/tmp/x')).run(
        pptx(task: 'Ajan mimarisi ve mmap bellek yönetimi sunumu'),
        models,
        cb(),
        CancelToken(),
      );
      expect(files.builds, 1);

      final files2 = FakeFiles();
      final engine2 = FakeEngine(responder: (p, c) => _docOkAsSlides);
      await expectLater(
        WorkflowRunner(engine2, files2, FakeStorage([], '/tmp/x')).run(
          pptx(task: 'Kuantum fiziği ve nükleer füzyon sunumu'),
          models,
          cb(),
          CancelToken(),
        ),
        throwsA(isA<OutputValidationException>()),
      );
      expect(files2.builds, 0);
    });
  });
}

const _docOkAsSlides = '''
## Yemek
- un ve şeker karıştırılır
- fırında pişirilir
## Servis
- sıcak servis edilir
- yanına çay verilir
''';
