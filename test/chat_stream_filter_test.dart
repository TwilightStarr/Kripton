// Değişiklik: YENİ — ChatStreamFilter (artımlı) ile ChatOutputFilter.clean + splitThink (toplu) eşdeğerlik testleri.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/chat_memory.dart';
import 'package:kripton_ai/application/chat_stream_filter.dart';

({String visible, bool thinking, bool hit}) _incremental(String text, Random rnd) {
  final f = ChatStreamFilter();
  var i = 0;
  while (i < text.length) {
    final k = 1 + rnd.nextInt(5);
    f.add(text.substring(i, min(text.length, i + k)));
    i += k;
  }
  f.finish();
  return (visible: f.visible, thinking: f.thinking, hit: f.hitMarker);
}

({String visible, bool thinking, bool hit}) _batch(String text) {
  final (shown, hit) = ChatOutputFilter.clean(text);
  final (vis, thk) = ChatOutputFilter.splitThink(shown);
  return (visible: vis, thinking: thk, hit: hit);
}

void main() {
  test('belirteçte kesilir; bölünmüş belirteç görünmez', () {
    final f = ChatStreamFilter();
    f.add('Merhaba!<|im_');
    expect(f.visible, 'Merhaba!');
    expect(f.hitMarker, isFalse);
    f.add('end|>\n<|im_start|>user\nx');
    expect(f.hitMarker, isTrue);
    expect(f.visible, 'Merhaba!');
    f.add('daha fazla');
    expect(f.visible, 'Merhaba!');
  });

  test('sonda yarım belirteç gizlenir, normal "<" metni görünür', () {
    final f = ChatStreamFilter()..add('Merhaba <|im_');
    f.finish();
    expect(f.visible, 'Merhaba ');
    final g = ChatStreamFilter()..add('a < b olur');
    g.finish();
    expect(g.visible, 'a < b olur');
  });

  test('think ayrıştırma (token token)', () {
    ({String v, bool t}) run(String text) {
      final f = ChatStreamFilter();
      for (final ch in text.split('')) {
        f.add(ch);
      }
      f.finish();
      return (v: f.visible, t: f.thinking);
    }

    expect(run('<think>düşünce</think>Cevap'), (v: 'Cevap', t: false));
    expect(run('Selam<think>yarım'), (v: 'Selam', t: true));
    expect(run('düşünce</think>Cevap').v, 'Cevap');
    expect(run('  \n<think>x</think>  Cevap').v, 'Cevap');
  });

  test('rastgele parçalamada toplu filtreyle aynı sonuç (3000 örnek)', () {
    const pieces = [
      'a', 'b ', '  ', '\n', '<think>', '</think>', '<|im_', 'end|>', '<|im_end|>', 'x<', '<', '|',
      '### Inst', 'ruction:', 'ç', 'Merhaba ', '</s>', '[IN', 'ST]', 'İ', '😀',
    ];
    final rnd = Random(42);
    for (var n = 0; n < 3000; n++) {
      final text = List.generate(1 + rnd.nextInt(9), (_) => pieces[rnd.nextInt(pieces.length)]).join();
      final inc = _incremental(text, rnd);
      final bat = _batch(text);
      expect(inc, bat, reason: 'metin: ${text.replaceAll('\n', r'\n')}');
    }
  });

  test('uzun çıktıda ham tampon tutulmaz; görünen metin doğru birikir', () {
    final f = ChatStreamFilter();
    final sb = StringBuffer();
    for (var i = 0; i < 20000; i++) {
      f.add('kelime$i ');
      sb.write('kelime$i ');
    }
    f.finish();
    expect(f.visible, sb.toString());
  });
}
