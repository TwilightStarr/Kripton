import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/chunk_planner.dart';
import 'package:kripton_ai/application/token_budget.dart';
import 'package:kripton_ai/application/workflow_runner.dart';
import 'package:kripton_ai/data/llm_engine.dart';
import 'package:kripton_ai/domain/entities.dart';

import 'helpers.dart';

class _Rec {
  final statuses = <String>[];
  final tokens = StringBuffer();
  final agents = <String, AgentStatus>{};
  final transfers = <String>[];
  Completer<void>? firstToken;

  RunCallbacks get cb => RunCallbacks(
    status: statuses.add,
    log: (_) {},
    token: (t) {
      tokens.write(t);
      final f = firstToken;
      if (f != null && !f.isCompleted) f.complete();
    },
    live: (_) {},
    agent: (id, s, _) => agents[id] = s,
    transfer: transfers.add,
  );
}

WorkflowRunner _runner(LlmEngine e, FakeFiles f) =>
    WorkflowRunner(e, f, FakeStorage([], '/tmp/x'));

void main() {
  final models = [cachedModel()];

  test('1) normal akış: tokenlar sırayla toplanır', () async {
    final files = FakeFiles();
    final rec = _Rec();
    final art = await _runner(
      FakeEngine(),
      files,
    ).run(testWorkflow(agents: 1), models, rec.cb, CancelToken());
    expect(
      files.lastContent,
      'Merhaba dünya. Bu sahte çıktı, ajan kabul kapısının gerektirdiği uzunlukta bir test metnidir.',
    );
    expect(rec.tokens.toString(), files.lastContent);
    expect(art.filename, 'test.txt');
    expect(rec.agents['a1'], AgentStatus.completed);
  });

  test(
    '2) NO_EVENT_SINK: LlamaEngine akışsız moda düşer, düğüm takılmaz',
    () async {
      final engine = LlamaEngine(
        backend: FakeBackend(streamError: noEventSink()),
        retryDelay: const Duration(milliseconds: 1),
      );
      final files = FakeFiles();
      final rec = _Rec();
      await _runner(engine, files)
          .run(testWorkflow(agents: 1), models, rec.cb, CancelToken())
          .timeout(const Duration(seconds: 5));
      expect(
        files.lastContent,
        'merhaba dünya nasılsın. Bu sahte motor yanıtı kabul kapısının gerektirdiği uzunlukta bir test metnidir.',
      );
      expect(rec.agents['a1'], AgentStatus.completed);
      expect(engine.streamingUnsupported, isTrue);
    },
  );

  test(
    '3) üretim ortasında cancel: CancelledException, stop çağrılır, abonelik kapanır, token beklenmez',
    () async {
      final engine = FakeEngine(
        hangOnCall: 1,
      ); // tokenlardan sonra akış hiç bitmez
      final files = FakeFiles();
      final rec = _Rec()..firstToken = Completer<void>();
      final ct = CancelToken();
      final f = _runner(
        engine,
        files,
      ).run(testWorkflow(agents: 1), models, rec.cb, ct);
      final result = expectLater(f, throwsA(isA<CancelledException>()));
      await rec.firstToken!.future;
      ct.cancel();
      await result.timeout(const Duration(seconds: 2));
      expect(engine.stopCalls, greaterThanOrEqualTo(1));
      expect(engine.streamCancelled, isTrue);
      expect(files.builds, 0);
    },
  );

  test(
    '4) model yüklenirken cancel: yükleme bitince temiz çıkış, üretim başlamaz',
    () async {
      final gate = Completer<void>();
      final engine = FakeEngine(loadGate: gate);
      final ct = CancelToken();
      final f = _runner(
        engine,
        FakeFiles(),
      ).run(testWorkflow(agents: 1), models, _Rec().cb, ct);
      final result = expectLater(f, throwsA(isA<CancelledException>()));
      await waitFor(() => engine.loadCalls == 1);
      ct.cancel();
      gate.complete();
      await result;
      expect(engine.generateCalls, 0);
      expect(
        engine.loadedPath,
        isNotNull,
        reason: 'yükleme tamamlandı; durum tutarlı',
      );
    },
  );

  test('Ajanlar arası ALFA-123 aktarımı aynen korunur', () async {
    String valid(String lead) =>
        '$lead ${List.filled(18, 'sabit aktarım verisi').join(' ')}';
    final engine = FakeEngine(
      responder: (prompt, call) {
        if (call == 1) return valid('ALFA-123');
        if (call == 2)
          return valid(
            prompt.contains('ALFA-123')
                ? 'ALFA-123 ikinci ajan'
                : 'İŞARET KAYIP',
          );
        return valid('Üçüncü ajan tamamladı');
      },
    );
    await _runner(
      engine,
      FakeFiles(),
    ).run(testWorkflow(agents: 3), models, _Rec().cb, CancelToken());
    expect(engine.prompts, hasLength(3));
    expect(engine.prompts[1], contains('ALFA-123'));
    expect(engine.prompts[2], contains('ALFA-123'));
  });

  test(
    'uzun çıktı ChunkPlanner ile bölünür ve aktarım parçaları birleştirildiğinde kaynak aynıdır',
    () async {
      final source = List.generate(
        36,
        (i) =>
            'SEGMENT-${i.toString().padLeft(3, '0')}::${List.filled(35, 'kripton-veri').join('|')}',
      ).join('\n');
      final engine = FakeEngine(
        responder: (prompt, call) {
          if (call == 1) return source;
          if (prompt.contains('[AKTARIM NOTU:')) {
            return 'PARÇA-$call ${List.filled(8, 'tamamlandı').join(' ')}';
          }
          return 'Nihai çıktı ${List.filled(20, 'bütün parçalar işlendi').join(' ')}';
        },
      );
      final logs = <ExecutionLog>[];
      final liveTransfers = <String>[];
      final cb = RunCallbacks(
        status: (_) {},
        log: logs.add,
        token: (_) {},
        live: (_) {},
        agent: (_, __, ___) {},
        transfer: liveTransfers.add,
      );
      await _runner(
        engine,
        FakeFiles(),
      ).run(testWorkflow(agents: 3), models, cb, CancelToken());

      const marker = '\n\n--- [ÖNCEKİ AJAN ÇIKTISI / BAĞLAM] ---\n';
      final chunkPrompts = engine.prompts
          .where((p) => p.contains('[AKTARIM NOTU:'))
          .toList();
      expect(chunkPrompts.length, greaterThan(1));
      final received = chunkPrompts.map((p) {
        final start = p.indexOf(marker) + marker.length;
        final end = p.indexOf('<|im_end|>', start);
        return p.substring(start, end);
      }).join();
      expect(received, source);
      expect(
        logs.any((l) => l.message.contains('Önceki çıktı kırpılmadan')),
        isTrue,
      );
      expect(
        logs.any(
          (l) =>
              l.message.contains('ilk 200:') && l.message.contains('son 200:'),
        ),
        isTrue,
      );
      expect(
        liveTransfers.any(
          (message) =>
              message.contains('ilk 200:') && message.contains('son 200:'),
        ),
        isTrue,
      );
    },
  );

  test(
    'think-only çıktı _inferRetry ile bir kez denenir, sonra anlaşılır hatayla durur',
    () async {
      final engine = FakeEngine(
        responder: (_, __) =>
            '<think>yalnızca düşünce, kullanıcıya yanıt yok</think>',
      );
      await expectLater(
        _runner(
          engine,
          FakeFiles(),
        ).run(testWorkflow(agents: 1), models, _Rec().cb, CancelToken()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Model yalnızca düşünce üretti'),
          ),
        ),
      );
      expect(engine.generateCalls, 2);
    },
  );

  test('80 karakterden kısa aktarılabilir çıktı kabul edilmez', () async {
    final engine = FakeEngine(responder: (_, __) => 'Bu çok kısa.');
    await expectLater(
      _runner(
        engine,
        FakeFiles(),
      ).run(testWorkflow(agents: 1), models, _Rec().cb, CancelToken()),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('80 karakterden kısa'),
        ),
      ),
    );
    expect(engine.generateCalls, 2);
  });

  test(
    'status-only ajan çıktısı kabul edilmez ve yalnızca bir kez yeniden denenir',
    () async {
      final engine = FakeEngine(responder: (_, __) => '[STATUS: SUCCESS]');
      await expectLater(
        _runner(
          engine,
          FakeFiles(),
        ).run(testWorkflow(agents: 1), models, _Rec().cb, CancelToken()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('yalnızca [STATUS:...] satırı'),
          ),
        ),
      );
      expect(engine.generateCalls, 2);
    },
  );

  Workflow longInputWorkflow(String user, {String system = 'sistem'}) {
    final wf = testWorkflow(agents: 1);
    return wf.copyWith(
      agents: [
        wf.agents.first.copyWith(userPrompt: user, systemPrompt: system),
      ],
    );
  }

  test(
    '6) batch=256: çok uzun girdi kırpılır, üretime giden prompt tahmini batch × %80\'i aşmaz',
    () async {
      final tpl = models.first.template;
      final inputs = {
        'ingilizce': List.filled(4000, 'lorem ipsum dolor sit amet').join(' '),
        'türkçe': List.filled(
          4000,
          'Şöyle güzel bir çalışma: öğrenci içeriği değiştirdi',
        ).join(' '),
        'kod': List.filled(3000, 'if (a == b) { x = f(y); }').join('\n'),
      };
      for (final e in inputs.entries) {
        final engine = FakeEngine(batchSize: 256);
        final logs = <ExecutionLog>[];
        final cb = RunCallbacks(
          status: (_) {},
          log: logs.add,
          token: (_) {},
          live: (_) {},
          agent: (_, __, ___) {},
        );
        await _runner(
          engine,
          FakeFiles(),
        ).run(longInputWorkflow(e.value), models, cb, CancelToken());
        expect(engine.prompts, hasLength(1), reason: e.key);
        final prompt = engine.prompts.single;
        expect(
          prompt.length,
          lessThan(e.value.length),
          reason: '${e.key}: girdi kırpılmalı',
        );
        expect(
          estimateTokens(prompt, tpl),
          lessThanOrEqualTo(PromptBudget.batchHardCap(256)),
          reason: e.key,
        );
        expect(
          logs.any(
            (l) =>
                l.type == LogType.warning &&
                l.message.contains('batch 256 × %70'),
          ),
          isTrue,
          reason: '${e.key}: kırpma uyarısı batch sınırını içermeli',
        );
      }
    },
  );

  test(
    '7) batch null: eski davranış (yalnızca bağlam sınırı) — prompt batch payıyla kırpılmaz',
    () async {
      final engine = FakeEngine(); // batchSize null, contextSize null => 2048
      final input = List.filled(4000, 'lorem ipsum dolor sit amet').join(' ');
      await _runner(
        engine,
        FakeFiles(),
      ).run(longInputWorkflow(input), models, _Rec().cb, CancelToken());
      final tok = estimateTokens(engine.prompts.single, models.first.template);
      expect(tok, greaterThan(PromptBudget.batchHardCap(256)));
    },
  );

  test(
    '8) kırpmayla bile batch sınırına sığmıyorsa StateError, native\'e prompt gitmez',
    () async {
      final engine = FakeEngine(batchSize: 64);
      final longSystem = List.filled(400, 'sistem talimatı').join(' ');
      final f = _runner(engine, FakeFiles()).run(
        longInputWorkflow('görev', system: longSystem),
        models,
        _Rec().cb,
        CancelToken(),
      );
      await expectLater(
        f,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Prompt batch sınırını aşıyor'),
          ),
        ),
      );
      expect(engine.generateCalls, 0);
    },
  );

  // ---------------------------------------------------------------------------
  // ChunkPlanner
  // ---------------------------------------------------------------------------
  group('ChunkPlanner', () {
    test(
      'proje haritası: tek satırlık imza özeti ve en çok maxChars bütçe',
      () {
        final files = <String, String>{
          'lib/main.dart': '''
import 'package:flutter/material.dart';
import 'package:path/path.dart';

class App extends StatelessWidget {
  void run() {}
}

void main() {
  runApp(App());
}
''',
          'lib/service.dart': '''
import 'dart:async';

class NetworkService {
  Future<String> fetchData() async => 'data';
}
''',
        };
        final map = ChunkPlanner.buildProjectMap(files, maxChars: 2000);
        expect(map, contains('lib/main.dart'));
        expect(map, contains('classes: [App]'));
        expect(map, contains('funcs: [run, main]'));
        expect(map, contains('classes: [NetworkService]'));

        final logs = <String>[];
        final tight = ChunkPlanner.buildProjectMap(
          files,
          maxChars: 50,
          onLog: logs.add,
        );
        expect(tight.length, lessThanOrEqualTo(110));
        expect(tight, contains('[HARİTA KIRPILDI'));
        expect(logs, isNotEmpty);
      },
    );

    test('büyük dosya: örtüşme, satır sınırları, ardışık indeks', () {
      final b = StringBuffer();
      for (var i = 1; i <= 100; i++) {
        if (i % 20 == 0) {
          b
            ..writeln('void function$i() {')
            ..writeln('  print("func $i");')
            ..writeln('}');
        } else {
          b.writeln('final int var$i = $i;');
        }
      }
      final units = ChunkPlanner.planFileUnits(
        'lib/big.dart',
        b.toString(),
        300,
      );
      expect(units.length, greaterThan(1));
      for (var i = 0; i < units.length; i++) {
        expect(units[i].unitIndex, i + 1);
        expect(units[i].totalUnits, units.length);
        expect(units[i].endLine, greaterThanOrEqualTo(units[i].startLine));
        expect(units[i].content.length, lessThanOrEqualTo(300));
      }
      expect(
        units[1].startLine,
        lessThanOrEqualTo(units[0].endLine),
        reason: 'örtüşme',
      );
      expect(units.last.endLine, 110);
      expect(
        units.first.statusLine,
        startsWith('Parça 1/${units.length} · lib/big.dart satır 1-'),
      );
    });

    test(
      'tek satır bütçeyi aşarsa karakter sınırından bölünür ve loglanır',
      () {
        final logs = <String>[];
        final units = ChunkPlanner.planFileUnits(
          'lib/long.dart',
          'short 1\n${'A' * 250}\nshort 2',
          100,
          onLog: logs.add,
        );
        expect(logs.any((l) => l.contains('Tek satır bütçeyi aştı')), isTrue);
        expect(units.length, greaterThanOrEqualTo(3));
      },
    );

    test(
      'metin görevleri: başlıklara göre böl, önceki bölümlerin özetini ekle',
      () {
        const md = '''
# Bölüm 1: Giriş
Bu birinci bölümün ilk cümlesidir.
Bu birinci bölümün ikinci cümlesidir.
Bu birinci bölümün üçüncü cümlesidir.

# Bölüm 2: Gelişme
Bu ikinci bölüm içeriğidir.
Burada detaylar anlatılmaktadır.

# Bölüm 3: Sonuç
Bu sonuç bölümüdür.
''';
        final units = ChunkPlanner.planTextSections('doc.md', md, 150);
        expect(units.length, greaterThanOrEqualTo(2));
        final sec2 = units.firstWhere((u) => u.content.contains('Bölüm 2'));
        expect(sec2.content, contains('Önceki bölümlerin özeti'));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Yama ayrıştırma / uygulama
  // ---------------------------------------------------------------------------
  group('yama uygulama', () {
    test('TAM bloğu yeni dosya, ESKİ/YENİ birebir eşleşme', () {
      final ws = <String, String>{
        'lib/main.dart': 'void main() {\n  print("old");\n}\n',
      };
      final tam = WorkflowRunner.parsePatches('''
<<<<<<< DOSYA: lib/helper.dart
<<<<<<< TAM
class Helper {
  static int add(int a, int b) => a + b;
}
>>>>>>> YENİ
''');
      expect(tam, hasLength(1));
      expect(tam.single.isNewFile, isTrue);
      expect(WorkflowRunner.applyPatch(tam.single, ws).success, isTrue);
      expect(ws['lib/helper.dart'], startsWith('class Helper'));
      expect(
        ws['lib/helper.dart'],
        contains('  static int add'),
        reason: 'girinti korunur',
      );

      final exact = WorkflowRunner.parsePatches('''
<<<<<<< DOSYA: lib/main.dart
<<<<<<< ESKİ
  print("old");
=======
  print("new \$x");
>>>>>>> YENİ
''');
      expect(exact, hasLength(1));
      expect(WorkflowRunner.applyPatch(exact.single, ws).success, isTrue);
      expect(
        ws['lib/main.dart'],
        contains(r'print("new $x");'),
        reason: r'$ yorumlanmaz',
      );
    });

    test(
      'kapanış işareti eksik (kesilmiş) yanıt da ayrıştırılır; ASCII YENI kabul edilir',
      () {
        final truncated = WorkflowRunner.parsePatches(
          '<<<<<<< DOSYA: a.dart\n<<<<<<< ESKI\nx\n=======\ny\n',
        );
        expect(truncated, hasLength(1));
        expect(truncated.single.oldCode, 'x');
        expect(truncated.single.newCode, 'y');
        final ascii = WorkflowRunner.parsePatches(
          '<<<<<<< DOSYA: a.dart\n<<<<<<< ESKI\nx\n=======\ny\n>>>>>>> YENI\n',
        );
        expect(ascii.single.newCode, 'y');
        expect(WorkflowRunner.parsePatches('yama yok'), isEmpty);
      },
    );

    test('boşluk normalleştirilmiş eşleşme; boş ESKİ blok reddedilir', () {
      final ws = <String, String>{
        'lib/s.dart': '  void doWork()   {\n    int   val = 42;\n  }\n',
      };
      final p = WorkflowRunner.parsePatches('''
<<<<<<< DOSYA: lib/s.dart
<<<<<<< ESKİ
void doWork() {
  int val = 42;
}
=======
void doWork() {
  int val = 100;
}
>>>>>>> YENİ
''');
      expect(WorkflowRunner.applyPatch(p.single, ws).success, isTrue);
      expect(ws['lib/s.dart'], contains('100'));

      const empty = PatchBlock(
        filePath: 'lib/s.dart',
        isNewFile: false,
        oldCode: '',
        newCode: 'x',
        rawBlock: '',
      );
      expect(WorkflowRunner.applyPatch(empty, ws).success, isFalse);
    });

    test('uygulanamayan yama bir kez yeniden istenir, olmazsa atlanır', () async {
      final ws = <String, String>{'lib/calc.dart': 'int calculate() => 10;\n'};
      const bad = PatchBlock(
        filePath: 'lib/calc.dart',
        isNewFile: false,
        oldCode: 'int computeWrong() => 999;',
        newCode: 'int calculate() => 20;',
        rawBlock: '<<<<<<< DOSYA: lib/calc.dart ...',
      );
      final prompts = <String>[];
      final applied = await WorkflowRunner.applyPatchesWithRetry([bad], ws, (
        prompt,
      ) async {
        prompts.add(prompt);
        return '''
<<<<<<< DOSYA: lib/calc.dart
<<<<<<< ESKİ
int calculate() => 10;
=======
int calculate() => 20;
>>>>>>> YENİ
''';
      });
      expect(applied, hasLength(1));
      expect(ws['lib/calc.dart'], contains('=> 20'));
      expect(prompts, hasLength(1));
      expect(prompts.single, contains('uygulanamadı'));

      // Yeniden denenen yama da eşleşmezse: tam bir yeniden istek, sonra atlanır.
      final ws2 = <String, String>{'lib/calc.dart': 'int calculate() => 10;\n'};
      var calls = 0;
      final logs = <String>[];
      final none = await WorkflowRunner.applyPatchesWithRetry([bad], ws2, (
        _,
      ) async {
        calls++;
        return 'geçersiz yanıt';
      }, onLog: logs.add);
      expect(none, isEmpty);
      expect(calls, 1);
      expect(ws2['lib/calc.dart'], 'int calculate() => 10;\n');
      expect(logs.any((l) => l.contains('atlandı')), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Yerel statik denetim
  // ---------------------------------------------------------------------------
  group('LocalStaticChecker', () {
    test('parantez dengesi, kapanmamış dize, eksik import', () {
      const code = '''
import './missing_service.dart';

void main() {
  String text = "unclosed string;
  if (true) {
    print('hello');
  // süslü parantez eksik
}
''';
      final issues = LocalStaticChecker.checkFile('lib/main.dart', code, {
        'lib/main.dart',
      });
      expect(issues.any((i) => i.contains('Dengesiz süslü parantez')), isTrue);
      expect(issues.any((i) => i.contains('Kapanmamış dize')), isTrue);
      expect(
        issues.any((i) => i.contains('İçe aktarılan dosya projede yok')),
        isTrue,
      );
      final report = LocalStaticChecker.formatReport(issues);
      expect(report.split('\n').length, lessThanOrEqualTo(9));
      expect(report.length, lessThanOrEqualTo(600));
    });

    test('temiz kod: yorum/dize içindeki parantezler sayılmaz', () {
      const ok = '''
void main() {
  // ( bu yorumdaki parantez sayılmaz
  final s = 'a ) b } c';
  final r = r'\\';
  print(s + r);
}
''';
      expect(LocalStaticChecker.checkFile('a.dart', ok, <String>{}), isEmpty);
      expect(LocalStaticChecker.formatReport([]), contains('temiz'));
    });
  });

  // ---------------------------------------------------------------------------
  // Denetçi döngüsü (run üzerinden), parçalı denetim, N sınırı, bütçe uyarısı
  // ---------------------------------------------------------------------------
  group('denetçi döngüsü', () {
    Workflow genAudit({int loops = 2, OutputFormat fmt = OutputFormat.txt}) {
      final base = testWorkflow(agents: 2);
      return base.copyWith(
        targetFormat: fmt,
        agents: [
          base.agents[0],
          base.agents[1].copyWith(mode: AgentMode.debugger, maxLoops: loops),
        ],
      );
    }

    bool isAudit(String p) => p.contains('--- [DENETLENECEK ÇIKTI');
    bool isFix(String p) => p.contains('[TALİMAT]');

    test(
      'hata -> yama düzeltmesi -> yeniden denetim; talimat + rapor + parça korunur',
      () async {
        String? fixPrompt;
        final trailingComment = '// ${List.filled(90, 'x').join()}';
        final engine = FakeEngine(
          responder: (p, call) {
            if (isFix(p)) {
              fixPrompt = p;
              return '''
<<<<<<< DOSYA: çıktı
<<<<<<< ESKİ
int add(a, b) => a + b;
=======
int add(int a, int b) => a + b;
>>>>>>> YENİ
''';
            }
            if (isAudit(p)) {
              return p.contains('int add(int a, int b)')
                  ? '[STATUS: SUCCESS]'
                  : '[STATUS: ERROR] Eksik tipler';
            }
            return 'int add(a, b) => a + b;\n$trailingComment';
          },
        );
        final files = FakeFiles();
        await _runner(
          engine,
          files,
        ).run(genAudit(), models, _Rec().cb, CancelToken());
        expect(fixPrompt, isNotNull);
        expect(fixPrompt, contains('[TALİMAT]'));
        expect(fixPrompt, contains('[HATA RAPORU]'));
        expect(fixPrompt, contains('[HATALI PARÇA]'));
        expect(
          files.lastContent,
          'int add(int a, int b) => a + b;\n$trailingComment',
        );
      },
    );

    test('N sınırı: en çok N denetim ve N düzeltme (asla N+1 değil)', () async {
      var audits = 0, fixes = 0;
      final engine = FakeEngine(
        responder: (p, call) {
          if (isAudit(p)) {
            audits++;
            return '[STATUS: ERROR] Sözdizimi hatası';
          }
          if (isFix(p)) {
            fixes++;
            return 'Düzeltme oluşturulmadı. Bu, testte hata raporunun ve döngü sınırının korunması için kullanılan geçerli bir yanıttır.';
          }
          return 'void bad() {\n  // ${List.filled(90, 'x').join()}';
        },
      );
      final logs = <ExecutionLog>[];
      final cb = RunCallbacks(
        status: (_) {},
        log: logs.add,
        token: (_) {},
        live: (_) {},
        agent: (_, __, ___) {},
      );
      await _runner(
        engine,
        FakeFiles(),
      ).run(genAudit(loops: 3), models, cb, CancelToken());
      expect(audits, 3);
      expect(fixes, 3);
      expect(
        logs.any(
          (l) => l.message.contains('Denetim ve düzeltme sınırına ulaşıldı'),
        ),
        isTrue,
      );
    });

    test(
      'denetçi infer hata fırlatırsa akış ölmez, uyarı loglanır, çıktı korunur',
      () async {
        final engine = FakeEngine(
          responder: (p, call) {
            if (isAudit(p)) throw Exception('LLM Timeout');
            return 'void main() { /* ${List.filled(90, 'x').join()} */ }';
          },
        );
        final files = FakeFiles();
        final logs = <ExecutionLog>[];
        final cb = RunCallbacks(
          status: (_) {},
          log: logs.add,
          token: (_) {},
          live: (_) {},
          agent: (_, __, ___) {},
        );
        final art = await _runner(
          engine,
          files,
        ).run(genAudit(), models, cb, CancelToken());
        expect(art.filename, 'test.txt');
        expect(
          files.lastContent,
          'void main() { /* ${List.filled(90, 'x').join()} */ }',
        );
        expect(
          logs.any(
            (l) => l.message.contains('Denetçi çıkarımı sırasında hata oluştu'),
          ),
          isTrue,
        );
      },
    );

    test(
      'denetçi think-only çıktıyı bir kez yeniden dener, sonra akışı durdurur',
      () async {
        final engine = FakeEngine(
          responder: (prompt, _) {
            if (isAudit(prompt))
              return '<think>rapor yerine yalnızca düşünce</think>';
            return 'void main() { /* ${List.filled(90, 'x').join()} */ }';
          },
        );
        await expectLater(
          _runner(
            engine,
            FakeFiles(),
          ).run(genAudit(), models, _Rec().cb, CancelToken()),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Model yalnızca düşünce üretti'),
            ),
          ),
        );
        expect(engine.generateCalls, 3);
      },
    );

    test(
      'büyük çıktı kırpılmadan parça parça denetlenir; durum satırı "Parça i/n"',
      () async {
        final big = [
          for (var i = 1; i <= 600; i++)
            'satır numarası $i: lorem ipsum dolor sit amet',
        ].join('\n');
        final auditPrompts = <String>[];
        final engine = FakeEngine(
          responder: (p, call) {
            if (isAudit(p)) {
              auditPrompts.add(p);
              return '[STATUS: SUCCESS]';
            }
            return big;
          },
        );
        final rec = _Rec();
        final files = FakeFiles();
        await _runner(
          engine,
          files,
        ).run(genAudit(), models, rec.cb, CancelToken());
        expect(
          auditPrompts.length,
          greaterThan(1),
          reason: 'çıktı bütçeyi aşıyor: birden çok parça',
        );
        for (final p in auditPrompts) {
          expect(p.length, lessThan(big.length));
        }
        expect(
          rec.statuses.any(
            (s) => s.startsWith('Parça 1/') && s.contains('satır '),
          ),
          isTrue,
        );
        // Hiçbir parça kırpılmadı: son satır son parçalarda görünür, nihai çıktı bozulmadı.
        expect(
          auditPrompts.any((p) => p.contains('satır numarası 600:')),
          isTrue,
        );
        expect(auditPrompts.any((p) => p.contains('kısaltıldı')), isFalse);
        expect(files.lastContent, big);
      },
    );

    test(
      'yerel statik rapor yalnızca ZIP (kod) modunda ve yalnızca Dart bloklarında istemde yer alır',
      () async {
        final code =
            'Dosya: lib/a.dart\n```dart\nvoid a() { // ${List.filled(90, 'x').join()}\n```\n';
        final seen = <String>[];
        FakeEngine eng() => FakeEngine(
          responder: (p, call) {
            if (isAudit(p)) {
              seen.add(p);
              return '[STATUS: SUCCESS]';
            }
            return code;
          },
        );
        await _runner(eng(), FakeFiles()).run(
          genAudit(fmt: OutputFormat.zip),
          models,
          _Rec().cb,
          CancelToken(),
        );
        expect(seen.single, contains('YEREL STATİK DENETİM'));
        expect(seen.single, contains('Dengesiz süslü parantez'));
        seen.clear();
        await _runner(
          eng(),
          FakeFiles(),
        ).run(genAudit(), models, _Rec().cb, CancelToken());
        expect(seen.single, isNot(contains('YEREL STATİK DENETİM')));
      },
    );

    test(
      'usablePromptTokens < 1000 uyarısı çalıştırma başına tek kez loglanır',
      () async {
        final logs = <ExecutionLog>[];
        final cb = RunCallbacks(
          status: (_) {},
          log: logs.add,
          token: (_) {},
          live: (_) {},
          agent: (_, __, ___) {},
        );
        // batch 256 => promptTokens 179 (< 1000); iki üretici ajan => iki _infer çağrısı, tek uyarı.
        await _runner(
          FakeEngine(batchSize: 256),
          FakeFiles(),
        ).run(testWorkflow(agents: 2), models, cb, CancelToken());
        expect(
          logs.where((l) => l.message.contains('Bütçe düşük uyarısı')).length,
          1,
        );

        // Bol bütçe: uyarı yok.
        final logs2 = <ExecutionLog>[];
        final cb2 = RunCallbacks(
          status: (_) {},
          log: logs2.add,
          token: (_) {},
          live: (_) {},
          agent: (_, __, ___) {},
        );
        await _runner(
          FakeEngine(ctx: 8192),
          FakeFiles(),
        ).run(testWorkflow(agents: 1), models, cb2, CancelToken());
        expect(
          logs2.any((l) => l.message.contains('Bütçe düşük uyarısı')),
          isFalse,
        );
      },
    );
  });

  test('5a) CancelToken.cancel() idempotent', () async {
    final ct = CancelToken();
    ct.cancel();
    ct.cancel();
    expect(ct.cancelled, isTrue);
    await ct.onCancel;
  });
  group('kullanıcı görevi (task) tüm ajan promptlarına girer', () {
    const task = 'Vulkan destekli bir tampon yöneticisi yaz.';
    final block = taskBlock(task);

    Workflow threeAgents({List<AgentMode>? modes}) {
      final wf = testWorkflow(agents: 3);
      return wf.copyWith(
        task: task,
        agents: [
          for (var i = 0; i < wf.agents.length; i++)
            wf.agents[i].copyWith(
              mode: modes == null ? AgentMode.generator : modes[i],
            ),
        ],
      );
    }

    test(
      '7) 3 ajanlı akış: görev metni her ajanın yakalanan prompt\'unda geçer ve sistem metninin önündedir',
      () async {
        final engine = FakeEngine();
        await _runner(
          engine,
          FakeFiles(),
        ).run(threeAgents(), models, _Rec().cb, CancelToken());
        expect(engine.prompts, hasLength(3));
        for (final (i, p) in engine.prompts.indexed) {
          expect(
            p,
            contains(task),
            reason: '${i + 1}. ajan prompt\'unda görev yok',
          );
          expect(
            p,
            contains(block),
            reason: '${i + 1}. ajan: görev bloğu eksik',
          );
          expect(
            p.indexOf(task),
            lessThan(p.indexOf('sistem')),
            reason: '${i + 1}. ajan: görev EN BAŞTA olmalı',
          );
          // Blok hem sistem hem kullanıcı mesajının başında yer alır.
          expect(
            p.split(block).length - 1,
            2,
            reason:
                '${i + 1}. ajan: blok sistem ve kullanıcı mesajında birer kez olmalı',
          );
        }
      },
    );

    test('8) boş görevde blok eklenmez (geriye dönük uyumlu)', () async {
      final engine = FakeEngine();
      await _runner(
        engine,
        FakeFiles(),
      ).run(testWorkflow(agents: 2), models, _Rec().cb, CancelToken());
      for (final p in engine.prompts) {
        expect(p, isNot(contains('KULLANICI GÖREVİ')));
      }
    });

    test(
      '9) debugger döngüsü: denetim, düzeltme ve yama yeniden isteği promptlarında da görev vardır',
      () async {
        final engine = FakeEngine(
          responder: (prompt, call) {
            switch (call) {
              case 1:
                return 'kod üretim sonucu ${List.filled(20, 'sabit içerik').join(' ')}';
              case 2:
                return '[STATUS: ERROR] hata var';
              case 3:
                // Düzeltme: eşleşmeyen yama -> yeniden istek (call 4) tetiklenir.
                return '<<<<<<< DOSYA: çıktı\n<<<<<<< ESKİ\nolmayan kod\n=======\nyeni\n>>>>>>> YENİ';
              case 4:
                return 'yama yok';
              default:
                return 'Nihai aşama çıktısı ${List.filled(20, 'görev tamamlandı').join(' ')}';
            }
          },
        );
        final wf = threeAgents(
          modes: [AgentMode.generator, AgentMode.debugger, AgentMode.export],
        );
        final wf2 = wf.copyWith(
          agents: [
            wf.agents[0],
            wf.agents[1].copyWith(maxLoops: 2),
            wf.agents[2],
          ],
        );
        await _runner(
          engine,
          FakeFiles(),
        ).run(wf2, models, _Rec().cb, CancelToken());
        expect(engine.prompts.length, greaterThanOrEqualTo(5));
        expect(
          engine.prompts.any((p) => p.contains('[HATA RAPORU]')),
          isTrue,
          reason: 'düzeltme isteği üretilmeli',
        );
        expect(
          engine.prompts.any((p) => p.contains('güncel içeriği')),
          isTrue,
          reason: 'yama yeniden isteği üretilmeli',
        );
        expect(
          engine.prompts.any((p) => p.contains('DENETLENECEK ÇIKTI')),
          isTrue,
        );
        for (final (i, p) in engine.prompts.indexed) {
          expect(
            p,
            contains(block),
            reason: '${i + 1}. çağrı prompt\'unda görev bloğu yok',
          );
        }
      },
    );

    test(
      '10) bütçe aşımında görev bloğu korunur ve önceki çıktı kayıpsız parçalanır',
      () async {
        final longPrev = List.filled(
          4000,
          'önceki ajan çıktısı satırı',
        ).join(' ');
        final engine = FakeEngine(
          responder: (prompt, call) {
            if (call == 1) return longPrev;
            return 'Parça sonucu ${List.filled(12, 'içerik korundu').join(' ')}';
          },
        );
        await _runner(
          engine,
          FakeFiles(),
        ).run(threeAgents(), models, _Rec().cb, CancelToken());
        const marker = '\n\n--- [ÖNCEKİ AJAN ÇIKTISI / BAĞLAM] ---\n';
        final chunkPrompts = engine.prompts
            .where((p) => p.contains('[AKTARIM NOTU:'))
            .toList();
        expect(chunkPrompts.length, greaterThan(1));
        final received = chunkPrompts.map((p) {
          final start = p.indexOf(marker) + marker.length;
          final end = p.indexOf('<|im_end|>', start);
          expect(
            p.split(block).length - 1,
            2,
            reason: 'Görev her promptta korunmalı',
          );
          return p.substring(start, end);
        }).join();
        expect(received, longPrev);
        expect(
          chunkPrompts.any((p) => p.contains('[...kısaltıldı...]')),
          isFalse,
        );
      },
    );

    test(
      'dönüştürücü sistem kuralı bilgi eklemeyi ve değiştirmeyi yasaklar',
      () async {
        final base = threeAgents(
          modes: [
            AgentMode.generator,
            AgentMode.generator,
            AgentMode.converter,
          ],
        );
        final engine = FakeEngine();
        final runner = _runner(engine, FakeFiles());
        await runner.run(base, models, _Rec().cb, CancelToken());
        expect(engine.prompts, hasLength(3));
        expect(engine.prompts[2], contains('SİSTEM KURALI'));
        expect(engine.prompts[2], contains('DEĞİŞTİRME, EKLEME, ÖZETLEME'));
        expect(
          runner.promptSnapshots[base.agents.last.id],
          contains('DEĞİŞTİRME, EKLEME, ÖZETLEME'),
        );
      },
    );

    test(
      'isteğe bağlı converter atlanır ve önceki çıktı dosya motoruna aynen bırakılır',
      () async {
        final base = threeAgents(
          modes: [
            AgentMode.generator,
            AgentMode.generator,
            AgentMode.converter,
          ],
        );
        final wf = base.copyWith(
          agents: [
            ...base.agents.take(2),
            base.agents.last.copyWith(optional: true),
          ],
        );
        final engine = FakeEngine();
        final files = FakeFiles();
        final runner = _runner(engine, files);
        await runner.run(wf, models, _Rec().cb, CancelToken());
        expect(engine.prompts, hasLength(2));
        expect(
          files.lastContent,
          'Merhaba dünya. Bu sahte çıktı, ajan kabul kapısının gerektirdiği uzunlukta bir test metnidir.',
        );
        expect(
          runner.promptSnapshots[wf.agents.last.id],
          contains('İSTEĞE BAĞLI'),
        );
      },
    );
  });

  group('Workflow.task serileştirme', () {
    Map<String, dynamic> oldJson({String? task}) => {
      'id': 'w',
      'title': 'T',
      'description': 'Eski açıklama',
      if (task != null) 'task': task,
      'targetFormat': 'txt',
      'agents': <Object?>[],
      'createdAt': 1,
      'updatedAt': 2,
    };

    test('eski kayıtta task yoksa description kullanılır', () {
      expect(Workflow.fromJson(oldJson()).task, 'Eski açıklama');
    });

    test('description de yoksa boş metin', () {
      final j = oldJson()..remove('description');
      final w = Workflow.fromJson(j);
      expect(w.task, '');
      expect(w.description, '');
    });

    test('toJson/fromJson ve copyWith task alanını korur', () {
      final w = Workflow.fromJson(
        oldJson(task: 'Yeni görev'),
      ).copyWith(task: 'Değişti');
      expect(w.task, 'Değişti');
      expect(Workflow.fromJson(w.toJson()).task, 'Değişti');
      expect(w.copyWith(title: 'X').task, 'Değişti');
    });

    test('AgentConfig.optional kaydedilir; eski kayıtta false varsayılır', () {
      final optional = testWorkflow(
        agents: 1,
      ).agents.single.copyWith(optional: true);
      expect(AgentConfig.fromJson(optional.toJson()).optional, isTrue);
      final legacy = Map<String, dynamic>.from(optional.toJson())
        ..remove('optional');
      expect(AgentConfig.fromJson(legacy).optional, isFalse);
    });
  });
}
