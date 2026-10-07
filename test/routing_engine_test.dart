import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/litert_runtime.dart';
import 'package:kripton_ai/data/llm_engine.dart';
import 'package:kripton_ai/data/routing_engine.dart';

class _FakeEngine implements LlmEngine, UnloadableEngine, BackendReporter {
  _FakeEngine(this.name, this.log, {this.ctx, this.batch, this.backend, this.onLoad});

  final String name;
  final List<String> log;
  final int? ctx;
  final int? batch;
  final LiteRtBackend? backend;
  final void Function()? onLoad;
  String? _loaded;
  bool failUnload = false;

  @override
  String? get loadedPath => _loaded;

  @override
  LiteRtBackend? get activeBackend => _loaded == null ? null : backend;

  @override
  Future<void> ensureLoaded(String path, {int? expectedBytes}) async {
    log.add('$name:load');
    onLoad?.call();
    _loaded = path;
  }

  @override
  Future<void> unload() async {
    log.add('$name:unload');
    if (!failUnload) _loaded = null;
  }

  @override
  Stream<String> generate(String prompt, {int maxTokens = 1536}) {
    log.add('$name:generate');
    return Stream<String>.fromIterable([name]);
  }

  @override
  Future<void> stop() async => log.add('$name:stop');

  @override
  Future<void> dispose() async => log.add('$name:dispose');

  @override
  Future<bool> waitNativeIdle(Duration timeout) async => true;

  @override
  int? get contextSize => ctx;

  @override
  int? get batchSize => batch;
}

/// UnloadableEngine DEĞİL: yönlendirici dispose() ile boşaltmalı (LlamaEngine gibi).
class _PlainEngine implements LlmEngine {
  _PlainEngine(this.log);
  final List<String> log;
  String? _loaded;

  @override
  String? get loadedPath => _loaded;

  @override
  Future<void> ensureLoaded(String path, {int? expectedBytes}) async {
    log.add('plain:load');
    _loaded = path;
  }

  @override
  Stream<String> generate(String prompt, {int maxTokens = 1536}) => Stream<String>.value('plain');

  @override
  Future<void> stop() async => log.add('plain:stop');

  @override
  Future<void> dispose() async {
    log.add('plain:dispose');
    _loaded = null;
  }

  @override
  Future<bool> waitNativeIdle(Duration timeout) async => true;

  @override
  int? get contextSize => 1;

  @override
  int? get batchSize => 1;
}

void main() {
  test('uzantıdan motor seçimi', () {
    expect(engineKindForPath('/m/a.gguf'), EngineKind.llama);
    expect(engineKindForPath('/m/A.GGUF'), EngineKind.llama);
    expect(engineKindForPath('/m/a.litertlm'), EngineKind.litert);
    expect(engineKindForPath('/m/a.task'), EngineKind.litert);
    expect(engineKindForPath('/m/a.bin'), EngineKind.llama, reason: 'bilinmeyen uzantı eski GGUF yolunda kalır');
  });

  test('uzantıya göre yönlendirir (.gguf -> llama, .litertlm/.task -> litert)', () async {
    final log = <String>[];
    final llama = _FakeEngine('llama', log);
    final litert = _FakeEngine('litert', log);
    final r = RoutingEngine(llama: llama, litert: litert);

    await r.ensureLoaded('/m/a.gguf');
    expect(r.activeEngineName, 'llama.cpp');
    expect(r.loadedPath, '/m/a.gguf');
    expect(llama.loadedPath, '/m/a.gguf');
    expect(litert.loadedPath, isNull);

    await r.ensureLoaded('/m/b.litertlm');
    expect(r.activeEngineName, 'LiteRT-LM');
    expect(litert.loadedPath, '/m/b.litertlm');

    await r.ensureLoaded('/m/c.gguf');
    expect(r.activeEngineName, 'llama.cpp');
    await r.ensureLoaded('/m/d.task');
    expect(r.activeEngineName, 'LiteRT-LM');
  });

  test('motor değişince ESKİ motor önce boşaltılır (ikisi aynı anda RAM\'de olmaz)', () async {
    final log = <String>[];
    late final _FakeEngine llama;
    String? llamaLoadedWhenLiteRtLoads = 'ölçülmedi';
    llama = _FakeEngine('llama', log);
    final litert = _FakeEngine('litert', log, onLoad: () => llamaLoadedWhenLiteRtLoads = llama.loadedPath);
    final r = RoutingEngine(llama: llama, litert: litert);

    await r.ensureLoaded('/m/a.gguf');
    await r.ensureLoaded('/m/b.litertlm');

    expect(log, ['llama:load', 'llama:stop', 'llama:unload', 'litert:load']);
    expect(llamaLoadedWhenLiteRtLoads, isNull);
    expect(llama.loadedPath, isNull);
  });

  test('aynı motor içinde model değişimi yönlendiriciden unload istemez', () async {
    final log = <String>[];
    final r = RoutingEngine(llama: _FakeEngine('llama', log), litert: _FakeEngine('litert', log));
    await r.ensureLoaded('/m/a.gguf');
    await r.ensureLoaded('/m/b.gguf');
    expect(log, ['llama:load', 'llama:load']);
  });

  test('UnloadableEngine olmayan eski motor dispose() ile boşaltılır', () async {
    final log = <String>[];
    final plain = _PlainEngine(log);
    final litert = _FakeEngine('litert', log);
    final r = RoutingEngine(llama: plain, litert: litert);
    await r.ensureLoaded('/m/a.gguf');
    await r.ensureLoaded('/m/b.litertlm');
    expect(log, ['plain:load', 'plain:stop', 'plain:dispose', 'litert:load']);
    expect(plain.loadedPath, isNull);
  });

  test('eski motor boşaltılamazsa yeni motor yüklenmez', () async {
    final log = <String>[];
    final llama = _FakeEngine('llama', log);
    final litert = _FakeEngine('litert', log);
    final r = RoutingEngine(llama: llama, litert: litert);
    await r.ensureLoaded('/m/a.gguf');
    llama.failUnload = true;
    await expectLater(r.ensureLoaded('/m/b.litertlm'), throwsA(isA<StateError>()));
    expect(litert.loadedPath, isNull);
    expect(log.where((e) => e == 'litert:load'), isEmpty);
  });

  test('generate / stop / contextSize / batchSize etkin motora yönlenir', () async {
    final log = <String>[];
    final llama = _FakeEngine('llama', log, ctx: 4096, batch: 512);
    final litert = _FakeEngine('litert', log, ctx: 8192, batch: null, backend: LiteRtBackend.gpu);
    final r = RoutingEngine(llama: llama, litert: litert);

    await r.ensureLoaded('/m/a.gguf');
    expect(await r.generate('p').toList(), ['llama']);
    expect(r.contextSize, 4096);
    expect(r.batchSize, 512);
    expect(r.activeBackend, isNull);

    await r.ensureLoaded('/m/b.litertlm');
    log.clear();
    expect(await r.generate('p').toList(), ['litert']);
    await r.stop();
    expect(log, ['litert:generate', 'litert:stop']);
    expect(r.contextSize, 8192);
    expect(r.batchSize, isNull);
    expect(r.activeBackend, LiteRtBackend.gpu);
    expect(await r.waitNativeIdle(const Duration(milliseconds: 10)), isTrue);
  });

  test('model yüklenmeden önce eski davranış: llama motoruna yönlenir', () async {
    final log = <String>[];
    final r = RoutingEngine(llama: _FakeEngine('llama', log, ctx: 2048), litert: _FakeEngine('litert', log));
    expect(r.activeEngineName, isNull);
    expect(r.loadedPath, isNull);
    expect(r.contextSize, 2048);
    await r.stop();
    expect(log, ['llama:stop']);
  });

  test('dispose iki motoru da kapatır', () async {
    final log = <String>[];
    final r = RoutingEngine(llama: _FakeEngine('llama', log), litert: _FakeEngine('litert', log));
    await r.dispose();
    expect(log.toSet(), {'llama:dispose', 'litert:dispose'});
  });
}
