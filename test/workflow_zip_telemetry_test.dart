import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/telemetry_service.dart';
import 'package:kripton_ai/application/workflow_package_mapper.dart';
import 'package:kripton_ai/data/default_data.dart';
import 'package:kripton_ai/data/workflow_zip_service.dart';
import 'package:kripton_ai/domain/entities.dart';
import 'package:kripton_ai/domain/telemetry_entities.dart';

Uint8List _zip(Map<String, String> files) {
  final a = Archive();
  files.forEach((name, text) {
    final b = utf8.encode(text);
    a.addFile(ArchiveFile(name, b.length, b));
  });
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

Map<String, String> _minimal({String prefix = ''}) => {
      '${prefix}workflow.json': jsonEncode({
        'workflow_id': 'w1',
        'title': 'Deneme',
        'steps': [
          {
            'step_id': 's1',
            'step_index': 1,
            'agent_name': 'Üretici',
            'target_model_family': 'Qwen',
            'prompt_files': {
              'system_prompt': 'prompts/s1.txt',
              'user_template': 'prompts/u1.txt',
            },
            'config_file': 'configs/c1.json',
            'input_mapping': {'q': r'$user_query'},
          },
          {
            'step_id': 's2',
            'step_index': 2,
            'agent_name': 'Denetçi',
            'target_model_family': 'DeepSeek',
            'agent_mode': 'debugger',
            'prompt_files': {
              'system_prompt': 'prompts/s2.txt',
              'user_template': 'prompts/u2.txt',
            },
            'config_file': 'configs/c2.json',
            'input_mapping': {'prev': r'$s1.output'},
          },
        ],
      }),
      '${prefix}prompts/s1.txt': 'Sistem 1',
      '${prefix}prompts/u1.txt': 'Görev: {{q}}',
      '${prefix}configs/c1.json': '{"temperature":0.2}',
      '${prefix}prompts/s2.txt': 'Sistem 2',
      '${prefix}prompts/u2.txt': 'İncele: {{prev}}',
      '${prefix}configs/c2.json': '{}',
    };

void main() {
  group('WorkflowZipService', () {
    test('geçerli paket okunur', () async {
      final pkg = await WorkflowZipService.parseZipBytes(_zip(_minimal()));
      expect(pkg.manifest.title, 'Deneme');
      expect(pkg.steps.length, 2);
      expect(pkg.steps[0].config.temperature, 0.2);
      expect(pkg.steps[1].manifest.agentMode, 'debugger');
    });

    test('tek üst klasör altındaki paket okunur', () async {
      final pkg = await WorkflowZipService.parseZipBytes(_zip(_minimal(prefix: 'paket/')));
      expect(pkg.steps.length, 2);
    });

    test('workflow.json yoksa açıklayıcı hata', () async {
      expect(
        () => WorkflowZipService.parseZipBytes(_zip({'x.txt': 'a'})),
        throwsA(isA<ZipValidationException>()),
      );
    });

    test('eksik prompt dosyası hata verir', () async {
      final f = _minimal()..remove('prompts/u2.txt');
      expect(
        () => WorkflowZipService.parseZipBytes(_zip(f)),
        throwsA(isA<ZipValidationException>()),
      );
    });

    test('yol geçişi (..) reddedilir', () async {
      final f = _minimal()..['../kotu.txt'] = 'x';
      expect(
        () => WorkflowZipService.parseZipBytes(_zip(f)),
        throwsA(isA<ZipValidationException>()),
      );
    });

    test('ZIP olmayan veri hata verir', () async {
      expect(
        () => WorkflowZipService.parseZipBytes(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<ZipValidationException>()),
      );
    });
  });

  group('WorkflowPackageMapper', () {
    test('içe aktarım: aile eşleşir, yer tutucular çözülür, mod okunur', () async {
      final pkg = await WorkflowZipService.parseZipBytes(_zip(_minimal()));
      final wf = WorkflowPackageMapper.toWorkflow(pkg, catalog: modelCatalog, nowMs: 1);
      expect(wf.id, 'wf-1');
      expect(wf.agents.length, 2);
      expect(wf.agents[0].userPrompt, contains('KULLANICI GÖREVİ'));
      expect(wf.agents[0].userPrompt, isNot(contains('{{')));
      expect(wf.agents[1].userPrompt, contains('önceki ajanın çıktısı'));
      expect(wf.agents[1].mode, AgentMode.debugger);
      expect(
        modelCatalog.firstWhere((m) => m.id == wf.agents[1].modelId).family,
        'DeepSeek',
      );
    });

    test('dışa aktar → içe aktar gidiş-dönüş', () async {
      final src = WorkflowPackageMapper.toWorkflow(
        await WorkflowZipService.parseZipBytes(_zip(_minimal())),
        catalog: modelCatalog,
        nowMs: 5,
      );
      final bytes = await WorkflowZipService.exportWorkflowToZip(
        WorkflowPackageMapper.fromWorkflow(src, modelCatalog),
      );
      final back = WorkflowPackageMapper.toWorkflow(
        await WorkflowZipService.parseZipBytes(bytes),
        catalog: modelCatalog,
        nowMs: 6,
      );
      expect(back.title, src.title);
      expect(back.agents.length, src.agents.length);
      for (var i = 0; i < src.agents.length; i++) {
        expect(back.agents[i].name, src.agents[i].name);
        expect(back.agents[i].systemPrompt, src.agents[i].systemPrompt);
        expect(back.agents[i].mode, src.agents[i].mode);
      }
    });
  });

  group('TelemetryService', () {
    TelemetryFrame frame(int tokens) => TelemetryFrame(
          timestamp: DateTime.now(),
          activeStep: null,
          allSteps: const [],
          currentStreamingText: '',
          metrics: PerformanceMetrics(
            tokensPerSecond: 1,
            ramUsageMB: 0,
            maxRamMB: 0,
            vramUsageMB: 0,
            maxVramMB: 0,
            thermalStatus: ThermalStatus.normal,
            temperatureCelsius: 0,
            throttleIntervalMs: 100,
            totalTokensBudget: 0,
            tokensConsumed: tokens,
          ),
          recentLogs: const [],
        );

    test('emitThrottled ardışık kareleri birleştirir, sonuncuyu yayınlar', () async {
      final s = TelemetryService();
      final got = <int>[];
      final sub = s.telemetryStream.listen((f) => got.add(f.metrics.tokensConsumed));
      for (var i = 1; i <= 20; i++) {
        s.emitThrottled(frame(i));
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(got, [20]);
      await sub.cancel();
      s.dispose();
    });

    test('emitImmediate bekleyen kareyi iptal eder; lastFrame saklanır', () async {
      final s = TelemetryService();
      final got = <int>[];
      final sub = s.telemetryStream.listen((f) => got.add(f.metrics.tokensConsumed));
      s.emitThrottled(frame(1));
      s.emitImmediate(frame(2));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(got, [2]);
      expect(s.lastFrame?.metrics.tokensConsumed, 2);
      await sub.cancel();
      s.dispose();
    });

    test('günlük geçmişi 200 kayıtla sınırlanır', () {
      final s = TelemetryService();
      for (var i = 0; i < 250; i++) {
        s.addLog(LogLevel.info, 'T', 'm$i');
      }
      expect(s.recentLogs.length, 200);
      expect(s.recentLogs.last.message, 'm249');
      s.dispose();
    });
  });
}
