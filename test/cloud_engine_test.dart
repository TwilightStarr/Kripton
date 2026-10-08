// Değişiklik: yeni dosya. Bulut motoru: ağsız (çevrimdışı) çalışan birim testleri.
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/cloud_engine.dart';
import 'package:kripton_ai/data/llm_engine.dart';
import 'package:kripton_ai/data/routing_engine.dart';

const String _prompt =
    '<|im_start|>system\nSistem<|im_end|>\n<|im_start|>user\nMerhaba<|im_end|>\n<|im_start|>assistant\n';

void main() {
  test('isCloudPath yalnızca cloud: önekini tanır', () {
    expect(isCloudPath('cloud:auto'), isTrue);
    expect(isCloudPath('cloud:gemini'), isTrue);
    expect(isCloudPath('/data/models/x.gguf'), isFalse);
    expect(isCloudPath(null), isFalse);
  });

  test('engineKindForPath bulut yollarını bulut motoruna yönlendirir', () {
    expect(engineKindForPath('cloud:auto'), EngineKind.cloud);
    expect(engineKindForPath('/m/a.gguf'), EngineKind.llama);
    expect(engineKindForPath('/m/a.litertlm'), EngineKind.litert);
  });

  test('hibrit mod varsayılan açık; otomatik bulut modeli kimliği katalogda var', () {
    expect(CloudConfig.instance.hybrid, isTrue);
    expect(cloudModels().any((m) => m.id == kCloudAutoModelId), isTrue);
  });

  test('cloudModels: indirilmiş sayılır, kimlikler benzersizdir, şablon ChatML', () {
    final list = cloudModels();
    expect(list.map((m) => m.id).toSet().length, list.length);
    for (final m in list) {
      expect(m.isCached, isTrue);
      expect(isCloudPath(m.localPath), isTrue);
    }
  });

  test('anahtar yokken üretim anlaşılır hata verir (ağa çıkmadan)', () async {
    for (final c in CloudConfig.instance.providers.values) {
      c.apiKey = '';
    }
    final e = CloudEngine();
    await e.ensureLoaded('cloud:auto');
    expect(e.loadedPath, 'cloud:auto');
    expect(e.contextSize, kCloudContextTokens);
    await expectLater(
      e.generate(_prompt).toList(),
      throwsA(isA<GenerationFailedException>().having((x) => x.code, 'code', 'CLOUD_NO_KEY')),
    );
    expect(await e.waitNativeIdle(const Duration(seconds: 2)), isTrue);
  });

  test('bulut olmayan yol reddedilir; dispose sonrası yeniden kullanılabilir', () async {
    final e = CloudEngine();
    await expectLater(e.ensureLoaded('/x/y.gguf'), throwsA(isA<GenerationFailedException>()));
    await e.ensureLoaded('cloud:groq');
    await e.dispose();
    expect(e.loadedPath, isNull);
    await e.ensureLoaded('cloud:gemini');
    expect(e.loadedPath, 'cloud:gemini');
  });

  test('ChatML olmayan istem ayrıştırma hatası verir', () async {
    for (final c in CloudConfig.instance.providers.values) {
      c.apiKey = 'x';
    }
    final e = CloudEngine();
    await e.ensureLoaded('cloud:auto');
    await expectLater(
      e.generate('düz metin').toList(),
      throwsA(isA<GenerationFailedException>().having((x) => x.code, 'code', 'CLOUD_CHATML')),
    );
    for (final c in CloudConfig.instance.providers.values) {
      c.apiKey = '';
    }
  });
}
