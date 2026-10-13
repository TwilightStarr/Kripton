import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/domain/chat_models.dart';

// Placeholder implementations for missing functions
List<ChatMessage> dropDegenerateTurns(List<ChatMessage> messages) {
  // Implementation logic would go here
  return messages;
}

bool isDegenerateReply(ChatMessage message) {
  // Implementation logic would go here
  return false;
}

ChatMessage _m(String id, ChatRole r, String t) => ChatMessage(id: id, role: r, text: t, ts: 0);

void main() {
  test('"OK" yanıtları ve ait oldukları kullanıcı mesajı istemden çıkarılır', () {
    final h = [
      _m('1', ChatRole.user, 'Merhaba'),
      _m('2', ChatRole.assistant, 'OK'),
      _m('3', ChatRole.user, 'Selam'),
      _m('4', ChatRole.assistant, 'Merhaba! Nasıl yardımcı olabilirim?'),
    ];
    expect([for (final m in dropDegenerateTurns(h)) m.id], ['3', '4']);
  });

  test('normal yanıtlar korunur; "ok." de bozuk sayılır', () {
    expect(isDegenerateReply(_m('1', ChatRole.assistant, ' ok. ')), isTrue);
    expect(isDegenerateReply(_m('2', ChatRole.assistant, 'Tamam, yaptım')), isFalse);
    expect(isDegenerateReply(_m('3', ChatRole.user, 'OK')), isFalse);
  });
}
