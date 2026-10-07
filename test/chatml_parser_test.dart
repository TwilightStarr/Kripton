import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/chatml_parser.dart';

const _sys = '<|im_start|>system\nSen yardımcısın.<|im_end|>\n';
const _open = '<|im_start|>assistant\n';

String _u(String t) => '<|im_start|>user\n$t<|im_end|>\n';
String _a(String t) => '<|im_start|>assistant\n$t<|im_end|>\n';

void main() {
  test('system + user + açık assistant', () {
    final p = parseChatMl('$_sys${_u('Merhaba')}$_open');
    expect(p.system, 'Sen yardımcısın.');
    expect(p.turns, [const ChatMlMessage(ChatMlRole.user, 'Merhaba')]);
    expect(p.openAssistant, isTrue);
    expect(p.assistantPrefill, '');
    expect(p.messages.length, 2, reason: 'açık assistant turu mesajlara girmez');
  });

  test('çok turlu', () {
    final p = parseChatMl('$_sys${_u('a')}${_a('b')}${_u('c')}$_open');
    expect(p.system, 'Sen yardımcısın.');
    expect(p.turns, [
      const ChatMlMessage(ChatMlRole.user, 'a'),
      const ChatMlMessage(ChatMlRole.assistant, 'b'),
      const ChatMlMessage(ChatMlRole.user, 'c'),
    ]);
    expect(p.openAssistant, isTrue);
  });

  test('system yok: yalnızca user + açık assistant', () {
    final p = parseChatMl('${_u('x')}$_open');
    expect(p.system, isNull);
    expect(p.turns.single.text, 'x');
  });

  test('açık assistant yoksa openAssistant false', () {
    final p = parseChatMl(_u('x'));
    expect(p.openAssistant, isFalse);
  });

  test('satır sonu olmadan biten "<|im_start|>assistant" açık tur sayılır', () {
    final p = parseChatMl('${_u('x')}<|im_start|>assistant');
    expect(p.openAssistant, isTrue);
  });

  test('açık assistant turundaki ön-ek metin ayrı tutulur', () {
    final p = parseChatMl('${_u('x')}<|im_start|>assistant\nSelam');
    expect(p.openAssistant, isTrue);
    expect(p.assistantPrefill, 'Selam');
    expect(p.turns.length, 1);
  });

  test('çok satırlı içerik aynen korunur', () {
    final p = parseChatMl('${_u('satır1\nsatır2\n\n  girintili')}$_open');
    expect(p.turns.single.text, 'satır1\nsatır2\n\n  girintili');
  });

  group('bozuk girdi ChatMlFormatException fırlatır', () {
    final bad = <String, String>{
      'boş': '',
      'düz metin': 'merhaba dünya',
      'kapanmamış user': '<|im_start|>user\nmerhaba',
      'bilinmeyen rol': '<|im_start|>robot\nx<|im_end|>\n',
      'turlar arası metin': '${_u('a')}araya giren metin\n${_u('b')}',
      'baştaki metin': 'önce metin${_u('a')}',
      'son tur assistant (kapalı)': '${_u('a')}${_a('b')}',
      'iç içe tur': '<|im_start|>user\na<|im_start|>user\nb<|im_end|>',
      'system ilk değil': '${_u('a')}<|im_start|>system\ns<|im_end|>\n${_u('b')}',
      'yalnızca açık assistant': _open,
      'yalnızca system': '$_sys$_open',
    };
    bad.forEach((name, input) {
      test(name, () {
        expect(
          () => parseChatMl(input),
          throwsA(isA<ChatMlFormatException>()),
        );
      });
    });
  });
}
