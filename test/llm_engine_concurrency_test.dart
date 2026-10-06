import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/llm_engine.dart';

import 'helpers.dart';

/// Üretim, stop çağrısından 40 ms SONRA native'de biter (gecikmeli stop).
class _SlowBackend implements LlamaBackend {
  bool busy = false;
  bool unloadWhileBusy = false;
  bool loadWhileBusy = false;
  int unloads = 0;
  StreamController<String>? _c;

  @override
  Future<bool> load(String path) async {
    if (busy) loadWhileBusy = true;
    return true;
  }

  @override
  Future<void> unload() async {
    if (busy) unloadWhileBusy = true;
    unloads++;
  }

  @override
  Future<bool> loadDowngraded(String path) async => false;

  @override
  Stream<String> stream(String prompt, int maxTokens) {
    busy = true;
    final c = StreamController<String>()..add('x');
    _c = c;
    return c.stream;
  }

  @override
  Future<String> complete(String prompt, int maxTokens) async => '';

  @override
  Future<void> stop() async {
    Future<void>.delayed(const Duration(milliseconds: 40), () {
      busy = false;
      _c?.close();
    });
  }

  @override
  Future<bool> waitIdle(Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (busy) {
      if (DateTime.now().isAfter(end)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return true;
  }

  @override
  int? get contextSize => 2048;

  @override
  int? get batchSize => 512;

  @override
  Future<bool> get underMemoryPressure async => false;

  @override
  Stream<int> get trimEvents => const Stream<int>.empty();
}

void main() {
  test(
    'eşzamanlı stop/unload: üretim sürerken unload çalışmaz, hepsi tamamlanır',
    () async {
      final dir = Directory.systemTemp.createTempSync('kripton_gguf');
      final model = File('${dir.path}/m.gguf')
        ..writeAsBytesSync([0x47, 0x47, 0x55, 0x46, 0, 0]);
      final b = _SlowBackend();
      final e = LlamaEngine(
        backend: b,
        retryDelay: const Duration(milliseconds: 1),
      );
      await e.ensureLoaded(model.path);

      final done = Completer<void>();
      e
          .generate('p')
          .listen((_) {}, onError: (Object _) {}, onDone: done.complete);
      await waitFor(() => b.busy);

      await Future.wait([e.stop(), e.dispose(), e.stop()]);
      await done.future.timeout(const Duration(seconds: 5));

      expect(
        b.unloadWhileBusy,
        isFalse,
        reason: 'üretim sürerken unload çağrılmamalı',
      );
      expect(b.unloads, 1);
      expect(b.busy, isFalse);
      expect(e.loadedPath, isNull);
      dir.deleteSync(recursive: true);
    },
  );
}
