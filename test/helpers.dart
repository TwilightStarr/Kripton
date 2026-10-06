import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kripton_ai/data/default_data.dart';
import 'package:kripton_ai/data/file_service.dart';
import 'package:kripton_ai/data/llm_engine.dart';
import 'package:kripton_ai/data/project_snapshot.dart';
import 'package:kripton_ai/data/storage.dart';
import 'package:kripton_ai/domain/entities.dart';

/// Runner/controller testleri için sahte motor.
class FakeEngine implements LlmEngine {
  FakeEngine({
    this.tokens = const [
      'Merhaba dünya. Bu sahte çıktı, ajan kabul kapısının gerektirdiği uzunlukta bir test metnidir.',
    ],
    this.hangOnCall,
    this.failOnCall,
    this.loadGate,
    this.batchSize,
    this.responder,
    this.ctx,
  });

  List<String> tokens;

  /// Doluysa her generate çağrısının yanıtını (tek token) bu işlev üretir; fırlatırsa akış hata verir.
  /// Parametreler: son prompt ve 1 tabanlı çağrı sırası.
  String Function(String prompt, int call)? responder;

  /// Sahte bağlam penceresi (varsayılan null = bilinmiyor).
  int? ctx;

  /// Bu sıradaki (1 tabanlı) generate çağrısı tokenlardan sonra bitmez.
  int? hangOnCall;

  /// Bu sıradaki generate çağrısı hata verir.
  int? failOnCall;

  /// Doluysa ensureLoaded bu Completer tamamlanana dek bekler.
  Completer<void>? loadGate;

  /// Sahte n_batch (varsayılan null = bilinmiyor; batch sınırı uygulanmaz).
  @override
  int? batchSize;

  /// generate'e verilen prompt'lar (sırayla).
  final List<String> prompts = [];

  int generateCalls = 0;
  int stopCalls = 0;
  int loadCalls = 0;
  bool streamCancelled = false;
  String? _loaded;

  @override
  String? get loadedPath => _loaded;

  @override
  Future<void> ensureLoaded(String path, {int? expectedBytes}) async {
    loadCalls++;
    final g = loadGate;
    if (g != null) await g.future;
    _loaded = path;
  }

  @override
  Stream<String> generate(String prompt, {int maxTokens = 1536}) {
    final call = ++generateCalls;
    prompts.add(prompt);
    late final StreamController<String> c;
    var cancelled = false;
    c = StreamController<String>(
      onListen: () async {
        if (failOnCall == call) {
          c.addError(StateError('sahte üretim hatası'));
          await c.close();
          return;
        }
        final r = responder;
        var toks = tokens;
        if (r != null) {
          try {
            toks = [r(prompt, call)];
          } catch (e) {
            c.addError(e);
            await c.close();
            return;
          }
        }
        for (final t in toks) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          if (cancelled) return;
          c.add(t);
        }
        if (hangOnCall != call && !cancelled) await c.close();
      },
      onCancel: () {
        cancelled = true;
        streamCancelled = true;
      },
    );
    return c.stream;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<bool> waitNativeIdle(Duration timeout) async => true;

  @override
  int? get contextSize => ctx;
}

/// LlamaEngine testleri için sahte native katman.
class FakeBackend implements LlamaBackend {
  FakeBackend({
    this.streamTokens = const ['a', 'b', 'c'],
    this.streamError,
    this.errorAfterTokens = false,
    this.completeText =
        'merhaba dünya nasılsın. Bu sahte motor yanıtı kabul kapısının gerektirdiği uzunlukta bir test metnidir.',
    this.completeError,
    this.completeFailures = 0,
    this.downgradeOk = true,
    this.ctx = 2048,
    this.batch = 512,
    this.downgradedCtx = 2048,
    this.downgradedBatch = 256,
  });

  final List<String> streamTokens;
  final Object? streamError;

  /// true: önce [streamTokens] gelir, sonra [streamError] fırlatılır (kısmi çıktı).
  final bool errorAfterTokens;
  final String completeText;

  /// [completeFailures] kadar ilk complete() çağrısı bu hatayı fırlatır.
  final Object? completeError;
  final int completeFailures;
  final bool downgradeOk;
  final int downgradedCtx;
  final int downgradedBatch;

  int ctx;
  int batch;
  int streamCalls = 0;
  int completeCalls = 0;
  int stopCalls = 0;
  int loadCalls = 0;
  int unloadCalls = 0;
  int downgradeCalls = 0;

  /// Çağrı sırası: stream / complete / unload / downgrade.
  final List<String> calls = [];
  final List<String> completePrompts = [];
  final List<int> completeMaxTokens = [];

  @override
  Future<bool> load(String path) async {
    loadCalls++;
    return true;
  }

  @override
  Future<void> unload() async {
    unloadCalls++;
    calls.add('unload');
  }

  @override
  Future<bool> loadDowngraded(String path) async {
    downgradeCalls++;
    calls.add('downgrade');
    if (!downgradeOk) return false;
    ctx = downgradedCtx;
    batch = downgradedBatch;
    return true;
  }

  @override
  Stream<String> stream(String prompt, int maxTokens) {
    streamCalls++;
    calls.add('stream');
    final err = streamError;
    if (err == null) return Stream<String>.fromIterable(streamTokens);
    if (!errorAfterTokens) return Stream<String>.error(err);
    return () async* {
      for (final t in streamTokens) {
        yield t;
      }
      throw err;
    }();
  }

  @override
  Future<String> complete(String prompt, int maxTokens) async {
    completeCalls++;
    calls.add('complete');
    completePrompts.add(prompt);
    completeMaxTokens.add(maxTokens);
    final err = completeError;
    if (err != null && completeCalls <= completeFailures) throw err;
    return completeText;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<bool> waitIdle(Duration timeout) async => true;

  @override
  int? get contextSize => ctx;

  @override
  int? get batchSize => batch;

  @override
  Future<bool> get underMemoryPressure async => false;

  @override
  Stream<int> get trimEvents => const Stream<int>.empty();
}

PlatformException noEventSink() => PlatformException(
  code: 'NO_EVENT_SINK',
  message: 'Event channel not initialized',
);

PlatformException generationFailed() => PlatformException(
  code: 'GENERATION_FAILED',
  message: 'Failed to generate response',
);

/// ensureLoaded'in geçerli saydığı en küçük sahte GGUF dosyası.
File fakeGguf(Directory dir) =>
    File('${dir.path}/m.gguf')
      ..writeAsBytesSync([0x47, 0x47, 0x55, 0x46, 0, 0]);

class FakeFiles extends FileService {
  int builds = 0;
  String? lastContent;
  String? lastTask;
  ProjectSnapshot? lastBase;

  @override
  Future<Artifact> build({
    required OutputFormat format,
    required String title,
    required String content,
    required Directory dir,
    String task = '',
    ProjectSnapshot? base,
  }) async {
    builds++;
    lastContent = content;
    lastTask = task;
    lastBase = base;
    return Artifact(
      format: format,
      filename: 'test.txt',
      path: '${dir.path}/test.txt',
      size: content.length,
      preview: content,
    );
  }
}

class FakeStorage extends Storage {
  FakeStorage(this.workflows, this.modelFile);

  final List<Workflow> workflows;
  final String modelFile;
  Directory? _out;

  @override
  Future<Directory> outputsDir() async =>
      _out ??= await Directory.systemTemp.createTemp('kripton_out');

  @override
  Future<Map<String, Map<String, String>>> loadRegistry() async => {
    modelCatalog.first.id: {'path': modelFile, 'sha256': 'x'},
  };

  @override
  Future<List<Workflow>?> loadWorkflows() async => workflows;

  @override
  Future<void> saveWorkflows(List<Workflow> list) async {}
}

GgufModel cachedModel() =>
    modelCatalog.first.withCache('/tmp/fake-model.gguf', 'x');

Workflow testWorkflow({int agents = 2}) => Workflow(
  id: 'wf-test',
  title: 'Test',
  description: 'Test akışı',
  targetFormat: OutputFormat.txt,
  agents: [
    for (var i = 1; i <= agents; i++)
      AgentConfig(
        id: 'a$i',
        order: i,
        name: '$i. AI',
        mode: AgentMode.generator,
        modelId: modelCatalog.first.id,
        systemPrompt: 'sistem',
        userPrompt: 'görev',
      ),
  ],
  createdAt: 0,
  updatedAt: 0,
);

Future<void> waitFor(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw StateError('waitFor zaman aşımı');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
