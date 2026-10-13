import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/llm_engine.dart';

import 'helpers.dart';

Future<File> _file(Directory d, String name, List<int> bytes) async =>
    File('${d.path}/$name').writeAsBytes(bytes);

void main() {
  late Directory dir;
  setUp(
    () async => dir = await Directory.systemTemp.createTemp('kripton_safety'),
  );
  tearDown(() => dir.delete(recursive: true));

  final good = [0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4];

  test('bozuk GGUF reddedilir, geçerli kabul edilir', () async {
    final ok = await _file(dir, 'ok.gguf', good);
    await validateModelFile(ok.path, expectedBytes: 8);

    final bad = await _file(dir, 'bad.gguf', [0, 1, 2, 3, 4, 5, 6, 7]);
    await expectLater(
      validateModelFile(bad.path),
      throwsA(isA<ModelFileException>()),
    );
    await expectLater(
      validateModelFile(ok.path, expectedBytes: 99),
      throwsA(isA<ModelFileException>()),
    );
    final part = await _file(dir, 'm.gguf.part', good);
    await expectLater(
      validateModelFile(part.path),
      throwsA(isA<ModelFileException>()),
    );
    await expectLater(
      validateModelFile('${dir.path}/yok.gguf'),
      throwsA(isA<ModelFileException>()),
    );
  });

  test('LlamaEngine bozuk dosyada backend.load çağırmaz', () async {
    final bad = await _file(dir, 'bad.gguf', [9, 9, 9, 9, 9]);
    final b = FakeBackend();
    final e = LlamaEngine(backend: b);
    await expectLater(
      e.ensureLoaded(bad.path),
      throwsA(isA<ModelFileException>()),
    );
    expect(b.loadCalls, 0);
  });

  test(
    'RAM yardımcıları eski metadata fallback tablosunu ve /proc ayrıştırmasını korur',
    () async {
      const mb = 1024 * 1024;
      expect(fallbackKvBytesPerToken(2 * 1024 * mb), 128 * 1024);
      expect(fallbackKvBytesPerToken(4 * 1024 * mb), 256 * 1024);
      expect(fallbackKvBytesPerToken(5 * 1024 * mb), 384 * 1024);
      expect(fallbackKvBytesPerToken(7 * 1024 * mb), 512 * 1024);
      expect(LlamaTuning.resolveThreads(8), 6);
      LlamaTuning.threadsOverride = 8;
      expect(LlamaTuning.resolveThreads(8), 8);
      LlamaTuning.threadsOverride = 0;
      expect(
        parseMemAvailableBytes('MemTotal: 1 kB\nMemAvailable:   2048 kB\n'),
        2048 * 1024,
      );

      final f = await _file(dir, 'ok.gguf', good);
      final backend = FlutterLlamaBackend(
        memAvailable: () async => 1024,
        totalMemory: () async => 1024,
      );
      await expectLater(
        backend.load(f.path),
        throwsA(isA<InsufficientMemoryException>()),
      );
    },
  );
}
