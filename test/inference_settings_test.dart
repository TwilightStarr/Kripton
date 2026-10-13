import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/workflow_package_mapper.dart';
import 'package:kripton_ai/application/workflow_runner.dart';
import 'package:kripton_ai/data/file_service.dart';
import 'package:kripton_ai/domain/entities.dart';
import 'package:kripton_ai/domain/inference_settings.dart';
import 'package:kripton_ai/domain/workflow_package_schema.dart';

import 'helpers.dart';

/// generate() anındaki örnekleme ayarlarını ve maxTokens'ı kaydeden sahte motor.
class _CapEngine extends FakeEngine {
  _CapEngine({super.ctx, super.responder});

  final List<InferenceSettings> seen = [];
  final List<int> maxTokensSeen = [];

  @override
  Stream<String> generate(String prompt, {int maxTokens = 1536}) {
    seen.add(SamplingScope.current);
    maxTokensSeen.add(maxTokens);
    return super.generate(prompt, maxTokens: maxTokens);
  }
}

void main() {
  group('InferenceSettings', () {
    test('varsayılanlar eski sabit değerlerdir ve JSON\'a yazılmaz', () {
      const d = InferenceSettings();
      expect(d.temperature, 0.4);
      expect(d.topP, 0.9);
      expect(d.topK, 40);
      expect(d.repeatPenalty, 1.1);
      expect(d.maxTokens, isNull);
      expect(d.isDefault, isTrue);
      final a = AgentConfig(
        id: 'a',
        order: 1,
        name: 'A',
        mode: AgentMode.generator,
        modelId: 'm',
        systemPrompt: 's',
        userPrompt: 'u',
      );
      expect(a.toJson().containsKey('inference'), isFalse);
      expect(AgentConfig.fromJson(a.toJson()).inference, d);
    });

    test('özel ayarlar JSON gidiş-dönüşünde korunur; eski kayıt varsayılanla açılır', () {
      const c = InferenceSettings(temperature: 0.1, topP: 0.8, topK: 20, repeatPenalty: 1.2, maxTokens: 512);
      final a = AgentConfig(
        id: 'a',
        order: 1,
        name: 'A',
        mode: AgentMode.debugger,
        modelId: 'm',
        systemPrompt: 's',
        userPrompt: 'u',
        inference: c,
      );
      expect(AgentConfig.fromJson(a.toJson()).inference, c);
      final old = a.toJson()..remove('inference');
      expect(AgentConfig.fromJson(old).inference.isDefault, isTrue);
    });

    test('clamped: bozuk değerler geçerli aralığa çekilir', () {
      final c = const InferenceSettings(
        temperature: 9,
        topP: 0,
        topK: 0,
        repeatPenalty: 0.2,
        maxTokens: 5,
      ).clamped();
      expect(c.temperature, 2.0);
      expect(c.topP, 0.05);
      expect(c.topK, 1);
      expect(c.repeatPenalty, 1.0);
      expect(c.maxTokens, 32);
      expect(const InferenceSettings(maxTokens: 0).clamped().maxTokens, isNull);
    });

    test('copyWith(clearMaxTokens) otomatiğe döner', () {
      final c = const InferenceSettings(maxTokens: 512).copyWith(clearMaxTokens: true);
      expect(c.maxTokens, isNull);
    });
  });

  group('Paket eşlemesi', () {
    test('eski sabit paket değerleri "ayarsız" sayılır (1024 sınırı dayatılmaz)', () {
      expect(WorkflowPackageMapper.inferenceFrom(WorkflowStepInferenceConfig()).isDefault, isTrue);
    });

    test('özel değerler içe aktarılır; max_tokens 0 = otomatik; dışa aktarım geri yazar', () {
      final s = WorkflowPackageMapper.inferenceFrom(
        WorkflowStepInferenceConfig(temperature: 0.2, topP: 0.8, maxTokens: 0, repeatPenalty: 1.15),
      );
      expect(s.temperature, 0.2);
      expect(s.topP, 0.8);
      expect(s.repeatPenalty, 1.15);
      expect(s.maxTokens, isNull);
      final cfg = WorkflowPackageMapper.configFrom(const InferenceSettings(temperature: 0.3, maxTokens: 700));
      expect(cfg.temperature, 0.3);
      expect(cfg.maxTokens, 700);
      expect(WorkflowPackageMapper.configFrom(const InferenceSettings()).maxTokens, 0);
    });
  });

  group('WorkflowRunner çıkarım ayarları', () {
    final models = [cachedModel()];
    RunCallbacks cb() => RunCallbacks(
      status: (_) {},
      log: (_) {},
      token: (_) {},
      live: (_) {},
      agent: (_, __, ___) {},
    );

    test('ajanın ayarları üretim anında native katmana verilir ve sonra sıfırlanır', () async {
      const custom = InferenceSettings(temperature: 0.15, topP: 0.7, repeatPenalty: 1.25);
      final wf = testWorkflow(agents: 1);
      final withInf = wf.copyWith(
        agents: [for (final a in wf.agents) a.copyWith(inference: custom)],
      );
      final engine = _CapEngine(ctx: 8192);
      await WorkflowRunner(engine, FakeFiles(), FakeStorage([], '/tmp/x')).run(
        withInf,
        models,
        cb(),
        CancelToken(),
      );
      expect(engine.seen, isNotEmpty);
      expect(engine.seen.first.temperature, 0.15);
      expect(engine.seen.first.topP, 0.7);
      expect(engine.seen.first.repeatPenalty, 1.25);
      expect(SamplingScope.current.isDefault, isTrue, reason: 'üretim bitince varsayılana dönmeli');
    });

    test('azami token sınırı bağlam bütçesini yalnızca düşürür', () async {
      final wf = testWorkflow(agents: 1);
      Future<int> maxFor(InferenceSettings inf) async {
        final w = wf.copyWith(agents: [for (final a in wf.agents) a.copyWith(inference: inf)]);
        final engine = _CapEngine(ctx: 8192);
        await WorkflowRunner(engine, FakeFiles(), FakeStorage([], '/tmp/x')).run(
          w,
          models,
          cb(),
          CancelToken(),
        );
        return engine.maxTokensSeen.first;
      }

      final auto = await maxFor(const InferenceSettings());
      final capped = await maxFor(const InferenceSettings(maxTokens: 256));
      final huge = await maxFor(const InferenceSettings(maxTokens: 8192));
      expect(capped, 256);
      expect(capped, lessThan(auto));
      expect(huge, lessThanOrEqualTo(auto), reason: 'kullanıcı sınırı bütçeyi aşamaz');
    });
  });
}
