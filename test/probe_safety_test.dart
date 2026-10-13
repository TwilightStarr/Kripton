import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/llm_engine.dart';

void main() {
  test('probe prompt kelime sayısı <= batch ~/ 2 + 1 (batch aşılmaz)', () {
    for (final batch in [16, 128, 256, 512, 1024]) {
      final words = buildProbePrompt(batch).split(' ');
      expect(words.length <= batch ~/ 2 + 1, isTrue, reason: 'batch=$batch words=${words.length}');
      expect(words.every((w) => w == 'test'), isTrue);
    }
  });

  test('probe prompt: batch=128 için 64 kelime, çok küçük batch için en az 8', () {
    expect(buildProbePrompt(128).split(' ').length, 64);
    expect(buildProbePrompt(4).split(' ').length, 8);
  });
}
