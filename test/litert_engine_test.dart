import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/chatml_parser.dart';
import 'package:kripton_ai/data/litert_engine.dart';
import 'package:kripton_ai/data/litert_runtime.dart';
import 'package:kripton_ai/data/llm_engine.dart';
import 'package:kripton_ai/domain/entities.dart';
import 'package:kripton_ai/domain/inference_settings.dart';

const _prompt =
    '<|im_start|>system\nSen yardımcısın.<|im_end|>\n'
    '<|im_start|>user\nMerhaba<|im_end|>\n'
    '<|im_start|>assistant\nSelam!<|im_end|>\n'
    '<|im_start|>user\nNasılsın?<|im_end|>\n'
    '<|im_start|>assistant\n';

class FakeLiteRtRuntime implements LiteRtRuntime {
  FakeLiteRtRuntime({
    Set<LiteRtBackend>? failLoad,
    Set<LiteRtBackend>? failSend,
    this.tokens = const ['Mer', 'haba'],
    this.hang = false,
    Set<String>? supported,
  })  : failLoad = failLoad ?? <LiteRtBackend>{},
        failSend = failSend ?? <LiteRtBackend>{},
        supported = supported ?? <String>{...LiteRtSampling.names};

  final Set<LiteRtBackend> failLoad;
  final Set<LiteRtBackend> failSend;
  final List<String> tokens;
  final bool hang;
  final Set<String> supported;

  final List<String> events = [];
  LiteRtBackend? current;
  String? lastSystem;
  List<ChatMlMessage>? lastHistory;
  String? lastUser;
  LiteRtSampling? lastSampling;
  StreamController<String>? _hangC;

  Iterable<String> get loadsAndSends =>
      events.where((e) => e.startsWith('load:') || e.startsWith('send:'));

  @override
  Future<void> load(String path, LiteRtBackend backend, {required int contextTokens}) async {
    events.add('load:${backend.name}');
    if (failLoad.contains(backend)) throw StateError('sahte yükleme hatası (${backend.name})');
    current = backend;
  }

  @override
  Future<void> unload() async {
    events.add('unload');
    current = null;
  }

  @override
  Stream<String> send({
    String? system,
    required List<ChatMlMessage> history,
    required String user,
    required LiteRtSampling sampling,
    required int maxTokens,
  }) {
    events.add('send:${current?.name}');
    lastSystem = system;
    lastHistory = history;
    lastUser = user;
    lastSampling = sampling;
    if (failSend.contains(current)) {
      return Stream<String>.error(StateError('sahte üretim hatası'));
    }
    if (hang) {
      final c = StreamController<String>()..add('a');
      _hangC = c;
      return c.stream;
    }
    return Stream<String>.fromIterable(tokens);
  }

  @override
  Future<void> cancel() async {
    events.add('cancel');
    await _hangC?.close();
    _hangC = null;
  }

  @override
  Set<String> get supportedSampling => supported;

  @override
  int? get contextSize => 4096;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String model;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kripton_litert');
    model = '${dir.path}/qwen.litertlm';
    File(model).writeAsBytesSync(List<int>.filled(64, 1));
  });

  tearDown(() {
    SamplingScope.reset();
    dir.deleteSync(recursive: true);
  });

  Future<LiteRtEngine> loaded(
    FakeLiteRtRuntime rt, {
    ChatTemplate template = ChatTemplate.chatml,
    List<LiteRtBackend>? order,
  }) async {
    final e = LiteRtEngine(
      runtime: rt,
      template: template,
      backendOrder: order ?? const [LiteRtBackend.npu, LiteRtBackend.gpu, LiteRtBackend.cpu],
    );
    await e.ensureLoaded(model);
    return e;
  }

  test('varsayılan backend sırası npu, gpu, cpu', () {
    expect(
      LiteRtEngine(runtime: FakeLiteRtRuntime()).backendOrder,
      [LiteRtBackend.npu, LiteRtBackend.gpu, LiteRtBackend.cpu],
    );
  });

  test('ilk backend yüklenirse etkin backend npu', () async {
    final rt = FakeLiteRtRuntime();
    final e = await loaded(rt);
    expect(e.activeBackend, LiteRtBackend.npu);
    expect(e.loadedPath, model);
    expect(e.contextSize, 4096);
    expect(e.batchSize, isNull);
  });

  test('yükleme: npu başarısız -> gpu başarısız -> cpu', () async {
    final rt = FakeLiteRtRuntime(failLoad: {LiteRtBackend.npu, LiteRtBackend.gpu});
    final e = await loaded(rt);
    expect(rt.loadsAndSends.toList(), ['load:npu', 'load:gpu', 'load:cpu']);
    expect(e.activeBackend, LiteRtBackend.cpu);
  });

  test('hiçbir backend yüklenemezse Türkçe hata + GGUF önerisi, uygulama çökmez', () async {
    final rt = FakeLiteRtRuntime(failLoad: {...LiteRtBackend.values});
    final e = LiteRtEngine(runtime: rt);
    await expectLater(
      e.ensureLoaded(model),
      throwsA(
        isA<GenerationFailedException>().having((x) => x.message, 'message', contains('GGUF')),
      ),
    );
    expect(e.loadedPath, isNull);
    expect(e.activeBackend, isNull);
  });

  test('ilk üretim: npu başarısız -> gpu ile yeniden yükleyip dener', () async {
    final rt = FakeLiteRtRuntime(failSend: {LiteRtBackend.npu});
    final e = await loaded(rt);
    final out = (await e.generate(_prompt).toList()).join();
    expect(out, 'Merhaba');
    expect(rt.loadsAndSends.toList(), ['load:npu', 'send:npu', 'load:gpu', 'send:gpu']);
    expect(e.activeBackend, LiteRtBackend.gpu);
  });

  test('ilk üretim: npu ve gpu başarısız -> cpu', () async {
    final rt = FakeLiteRtRuntime(failSend: {LiteRtBackend.npu, LiteRtBackend.gpu});
    final e = await loaded(rt);
    final out = (await e.generate(_prompt).toList()).join();
    expect(out, 'Merhaba');
    expect(
      rt.loadsAndSends.toList(),
      ['load:npu', 'send:npu', 'load:gpu', 'send:gpu', 'load:cpu', 'send:cpu'],
    );
    expect(e.activeBackend, LiteRtBackend.cpu);
  });

  test('tüm backendler üretimde başarısız: Türkçe hata + GGUF önerisi', () async {
    final rt = FakeLiteRtRuntime(failSend: {...LiteRtBackend.values});
    final e = await loaded(rt);
    await expectLater(
      e.generate(_prompt).toList(),
      throwsA(
        isA<GenerationFailedException>().having((x) => x.message, 'message', contains('GGUF')),
      ),
    );
  });

  test('backend bir kez çalıştıysa sonraki hata backend değiştirmez', () async {
    final rt = FakeLiteRtRuntime();
    final e = await loaded(rt);
    expect((await e.generate(_prompt).toList()).join(), 'Merhaba');
    rt.failSend.add(LiteRtBackend.npu);
    await expectLater(e.generate(_prompt).toList(), throwsA(isA<GenerationFailedException>()));
    expect(rt.events.where((x) => x == 'load:gpu'), isEmpty);
    expect(e.activeBackend, LiteRtBackend.npu);
  });

  test('özel backend sırası uygulanır', () async {
    final rt = FakeLiteRtRuntime(failLoad: {LiteRtBackend.cpu});
    final e = await loaded(rt, order: const [LiteRtBackend.cpu, LiteRtBackend.gpu]);
    expect(rt.loadsAndSends.toList(), ['load:cpu', 'load:gpu']);
    expect(e.activeBackend, LiteRtBackend.gpu);
  });

  test('ChatML mesajlara ayrılır; ham şablon pakete gitmez', () async {
    final rt = FakeLiteRtRuntime();
    final e = await loaded(rt);
    await e.generate(_prompt).toList();
    expect(rt.lastSystem, 'Sen yardımcısın.');
    expect(rt.lastHistory, [
      const ChatMlMessage(ChatMlRole.user, 'Merhaba'),
      const ChatMlMessage(ChatMlRole.assistant, 'Selam!'),
    ]);
    expect(rt.lastUser, 'Nasılsın?');
    expect(rt.lastUser, isNot(contains('<|im_start|>')));
  });

  test('bozuk (ChatML olmayan) istem: Türkçe hata, çalışma zamanı çağrılmaz', () async {
    final rt = FakeLiteRtRuntime();
    final e = await loaded(rt);
    await expectLater(
      e.generate('düz metin istem').toList(),
      throwsA(
        isA<GenerationFailedException>().having((x) => x.message, 'message', contains('ChatML')),
      ),
    );
    expect(rt.events.where((x) => x.startsWith('send:')), isEmpty);
  });

  test('ChatML dışı şablonda ensureLoaded anlaşılır Türkçe hata verir', () async {
    final rt = FakeLiteRtRuntime();
    final e = LiteRtEngine(runtime: rt, template: ChatTemplate.llama3);
    await expectLater(
      e.ensureLoaded(model),
      throwsA(
        isA<GenerationFailedException>().having((x) => x.message, 'message', contains('ChatML')),
      ),
    );
    expect(rt.events, isEmpty);
  });

  test('örnekleme ayarları çalışma zamanına iletilir; desteklenmeyenler çökertmez', () async {
    SamplingScope.current = const InferenceSettings(temperature: 0.7, topK: 20);
    final rt = FakeLiteRtRuntime(supported: <String>{});
    final e = await loaded(rt);
    await e.generate(_prompt).toList();
    expect(rt.lastSampling!.temperature, 0.7);
    expect(rt.lastSampling!.topK, 20);
  });

  test('eksik / boş model dosyası ModelFileException', () async {
    final e = LiteRtEngine(runtime: FakeLiteRtRuntime());
    await expectLater(e.ensureLoaded('${dir.path}/yok.litertlm'), throwsA(isA<ModelFileException>()));
    File('${dir.path}/bos.litertlm').writeAsBytesSync(const []);
    await expectLater(e.ensureLoaded('${dir.path}/bos.litertlm'), throwsA(isA<ModelFileException>()));
    await expectLater(e.ensureLoaded('${dir.path}/x.litertlm.part'), throwsA(isA<ModelFileException>()));
  });

  test('stop: üretimi bitirir, sonra native boşta', () async {
    final rt = FakeLiteRtRuntime(hang: true);
    final e = await loaded(rt);
    final got = <String>[];
    final done = Completer<void>();
    e.generate(_prompt).listen(got.add, onDone: done.complete);
    while (got.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await e.stop();
    await done.future.timeout(const Duration(seconds: 2));
    expect(got, ['a']);
    expect(await e.waitNativeIdle(const Duration(seconds: 1)), isTrue);
  });

  test('unload modeli boşaltır; aynı model yeniden yüklenebilir', () async {
    final rt = FakeLiteRtRuntime();
    final e = await loaded(rt);
    await e.unload();
    expect(e.loadedPath, isNull);
    expect(e.activeBackend, isNull);
    expect(e.contextSize, isNull);
    await e.ensureLoaded(model);
    expect(e.loadedPath, model);
  });
}
