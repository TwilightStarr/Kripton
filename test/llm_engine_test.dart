import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/token_budget.dart';
import 'package:kripton_ai/data/llm_engine.dart';

import 'helpers.dart';

void main() {
  test('1) akış: tokenlar sırayla gelir', () async {
    final b = FakeBackend();
    final e = LlamaEngine(
      backend: b,
      retryDelay: const Duration(milliseconds: 1),
    );
    final out = await e.generate('p').toList();
    expect(out, ['a', 'b', 'c']);
    expect(b.streamCalls, 1);
    expect(b.completeCalls, 0);
    expect(e.streamingUnsupported, isFalse);
  });

  test(
    '2) NO_EVENT_SINK: bir kez yeniden dener, akışsız moda düşer, sonraki çağrılar doğrudan akışsız',
    () async {
      final b = FakeBackend(streamError: noEventSink());
      final e = LlamaEngine(
        backend: b,
        retryDelay: const Duration(milliseconds: 1),
      );

      final first = (await e.generate('p').toList()).join();
      expect(first, 'merhaba dünya nasılsın');
      expect(b.streamCalls, 2, reason: 'ilk deneme + 1 yeniden deneme');
      expect(b.stopCalls, greaterThanOrEqualTo(1));
      expect(b.completeCalls, 1);
      expect(e.streamingUnsupported, isTrue);

      final second = (await e.generate('p').toList()).join();
      expect(second, 'merhaba dünya nasılsın');
      expect(b.streamCalls, 2, reason: 'bayrak set: akış denenmez');
      expect(b.completeCalls, 2);
    },
  );

  test('NO_EVENT_SINK dışındaki PlatformException yutulmaz', () async {
    final b = FakeBackend(streamError: StateError('başka hata'));
    final e = LlamaEngine(
      backend: b,
      retryDelay: const Duration(milliseconds: 1),
    );
    await expectLater(e.generate('p').toList(), throwsA(isA<StateError>()));
    expect(b.completeCalls, 0);
  });

  group('GENERATION_FAILED kurtarma zinciri', () {
    Future<LlamaEngine> loadedEngine(FakeBackend b) async {
      final dir = Directory.systemTemp.createTempSync('kripton_gguf');
      addTearDown(() => dir.deleteSync(recursive: true));
      final e = LlamaEngine(
        backend: b,
        retryDelay: const Duration(milliseconds: 1),
      );
      await e.ensureLoaded(fakeGguf(dir).path);
      return e;
    }

    test(
      'a) akış GENERATION_FAILED verirse sessizleştirip akışsız complete() ile kurtarılır',
      () async {
        final b = FakeBackend(streamError: generationFailed());
        final e = LlamaEngine(
          backend: b,
          retryDelay: const Duration(milliseconds: 1),
        );
        final out = (await e.generate('p').toList()).join();
        expect(out, 'merhaba dünya nasılsın');
        expect(b.calls, ['stream', 'complete']);
        expect(
          b.stopCalls,
          greaterThanOrEqualTo(1),
          reason: 'complete öncesi _quiesceNative',
        );
        expect(b.downgradeCalls, 0);
        expect(
          e.streamingUnsupported,
          isFalse,
          reason: 'GENERATION_FAILED akışı kalıcı kapatmaz',
        );
      },
    );

    test(
      'b) complete() de başarısızsa: unload -> bir seviye düşük profil -> bir kez daha complete',
      () async {
        final b = FakeBackend(
          streamError: generationFailed(),
          completeError: generationFailed(),
          completeFailures: 1,
        );
        final e = await loadedEngine(b);
        final out = (await e.generate('p').toList()).join();
        expect(out, 'merhaba dünya nasılsın');
        expect(b.calls, [
          'stream',
          'complete',
          'unload',
          'downgrade',
          'complete',
        ]);
        expect(b.batchSize, 256, reason: 'düşük profil uygulandı');
        expect(
          e.loadedPath,
          isNotNull,
          reason: 'yeniden yükleme sonrası model yüklü sayılır',
        );
      },
    );

    test(
      'b) akışsız yoldaki (NO_EVENT_SINK sonrası) complete() GENERATION_FAILED de aynı zincire girer',
      () async {
        final b = FakeBackend(
          streamError: noEventSink(),
          completeError: generationFailed(),
          completeFailures: 1,
        );
        final e = await loadedEngine(b);
        final out = (await e.generate('p').toList()).join();
        expect(out, 'merhaba dünya nasılsın');
        expect(b.calls, [
          'stream',
          'stream',
          'complete',
          'unload',
          'downgrade',
          'complete',
        ]);
        expect(e.streamingUnsupported, isTrue);
      },
    );

    test('c) hepsi başarısızsa Türkçe, eyleme dönük hata fırlar', () async {
      final b = FakeBackend(
        streamError: generationFailed(),
        completeError: generationFailed(),
        completeFailures: 2,
      );
      final e = await loadedEngine(b);
      await expectLater(
        e.generate('p').toList(),
        throwsA(
          isA<GenerationFailedException>().having(
            (x) => x.message,
            'message',
            kGenerationFailedRetriedMessage,
          ),
        ),
      );
      expect(
        kGenerationFailedRetriedMessage,
        'Üretim başarısız. Daha küçük bağlamla yeniden denendi; sürerse daha küçük model seç.',
      );
      expect(b.completeCalls, 2);
      expect(b.downgradeCalls, 1);
    });

    test(
      'c) daha düşük profil yoksa yeniden deneme yapılmaz ve dürüst mesaj verilir',
      () async {
        final b = FakeBackend(
          streamError: generationFailed(),
          completeError: generationFailed(),
          completeFailures: 5,
          downgradeOk: false,
        );
        final e = await loadedEngine(b);
        await expectLater(
          e.generate('p').toList(),
          throwsA(
            isA<GenerationFailedException>().having(
              (x) => x.message,
              'message',
              kGenerationFailedNoRetryMessage,
            ),
          ),
        );
        expect(b.completeCalls, 1);
        expect(
          e.loadedPath,
          isNull,
          reason:
              'yeniden yükleme başarısız: sonraki ensureLoaded sıfırdan yükler',
        );
      },
    );

    test(
      'b) yeni batch\'e sığmayan prompt kısaltılır, maxTokens yeni ctx\'e göre sınırlanır',
      () async {
        final b = FakeBackend(
          streamError: generationFailed(),
          completeError: generationFailed(),
          completeFailures: 1,
        );
        final e = await loadedEngine(b);
        final prompt = List.filled(800, 'kelime').join(' ');
        await e.generate(prompt, maxTokens: 2000).toList();
        expect(b.completePrompts, hasLength(2));
        final retry = b.completePrompts.last;
        expect(retry.length, lessThan(prompt.length));
        expect(
          estimateTokens(retry, kEngineEstimateTemplate),
          lessThanOrEqualTo(PromptBudget.batchHardCap(256)),
        );
        expect(retry.startsWith('kelime'), isTrue);
        expect(b.completeMaxTokens.last, lessThan(2000));
      },
    );

    test(
      'token geldikten sonraki PlatformException kurtarılmaz (kısmi çıktı bozulmaz)',
      () async {
        final b = FakeBackend(
          streamError: generationFailed(),
          errorAfterTokens: true,
        );
        final e = LlamaEngine(
          backend: b,
          retryDelay: const Duration(milliseconds: 1),
        );
        final got = <String>[];
        await expectLater(
          e.generate('p').forEach(got.add),
          throwsA(
            isA<PlatformException>().having(
              (x) => x.code,
              'code',
              'GENERATION_FAILED',
            ),
          ),
        );
        expect(got, ['a', 'b', 'c']);
        expect(b.completeCalls, 0);
      },
    );
  });

  test(
    'downgradeProfile listede sıradaki adaya ilerler ve son adayda biter',
    () {
      const gb = 1024 * 1024 * 1024;
      final plan = memoryPlan(
        availableBytes: 20 * gb,
        totalBytes: 20 * gb,
        modelBytes: 2 * gb,
        kvPerToken: 1024,
        nFf: 4096,
      );
      final p0 = chooseLoadProfile(plan: plan, streak: 0, threads: 6);
      final p1 = downgradeProfile(p0, plan: plan, threads: 6)!;
      expect((p1.ctx, p1.batch, p1.threads, p1.level), (4096, 1024, 4, 1));
      final p2 = downgradeProfile(p1, plan: plan, threads: 6)!;
      expect((p2.ctx, p2.batch, p2.threads, p2.level), (4096, 512, 2, 2));
      final last = plan.candidates.length - 1;
      var current = p2;
      while (current.level < last) {
        current = downgradeProfile(current, plan: plan, threads: 6)!;
      }
      expect(downgradeProfile(current, plan: plan, threads: 6), isNull);
    },
  );

  test(
    'fitPromptToTokens: kısa prompt aynen kalır, uzun olanın başı ve sonu korunur',
    () {
      expect(fitPromptToTokens('kısa prompt', 100), 'kısa prompt');
      final long = 'BAŞ ${List.filled(3000, 'x').join(' ')} SON';
      final fit = fitPromptToTokens(long, 100);
      expect(
        estimateTokens(fit, kEngineEstimateTemplate),
        lessThanOrEqualTo(100),
      );
      expect(fit.startsWith('BAŞ'), isTrue);
      expect(fit.endsWith('SON'), isTrue);
      expect(fit.contains('[...]'), isTrue);
    },
  );
}
