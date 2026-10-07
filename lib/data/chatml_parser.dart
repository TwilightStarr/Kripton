// Değişiklik: yeni dosya. Saf (yan etkisiz) ChatML ayrıştırıcı; LiteRT-LM şablonu kendisi uyguladığı için
// Kripton'un şablonlanmış düz metni mesajlara ayrılır (çift şablon olmasın).

const String _kStart = '<|im_start|>';
const String _kEnd = '<|im_end|>';

enum ChatMlRole { system, user, assistant }

class ChatMlMessage {
  const ChatMlMessage(this.role, this.text);
  final ChatMlRole role;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is ChatMlMessage && other.role == role && other.text == text;

  @override
  int get hashCode => Object.hash(role, text);

  @override
  String toString() => '${role.name}: $text';
}

/// Girdi geçerli ChatML değil. [message] Türkçe ve kısa; kullanıcıya doğrudan gösterilebilir.
class ChatMlFormatException implements Exception {
  const ChatMlFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ChatMlParse {
  const ChatMlParse({
    required this.messages,
    this.openAssistant = false,
    this.assistantPrefill = '',
  });

  /// Kapanmış turlar (system dahil), sırayla. Sondaki açık asistan turu BURADA YOK.
  final List<ChatMlMessage> messages;

  /// Girdi `<|im_start|>assistant` ile (kapanmadan) bitiyor.
  final bool openAssistant;

  /// Açık asistan turunda önceden yazılmış metin (genelde boş).
  final String assistantPrefill;

  /// İlk tur system ise metni, yoksa null.
  String? get system => messages.isNotEmpty && messages.first.role == ChatMlRole.system
      ? messages.first.text
      : null;

  /// system hariç turlar; son tur her zaman kullanıcı turudur.
  List<ChatMlMessage> get turns => system == null ? messages : messages.sublist(1);
}

ChatMlRole _roleOf(String t) {
  switch (t.toLowerCase()) {
    case 'system':
      return ChatMlRole.system;
    case 'user':
      return ChatMlRole.user;
    case 'assistant':
      return ChatMlRole.assistant;
  }
  throw ChatMlFormatException('bilinmeyen rol: "$t"');
}

/// `<|im_start|>rol\nmetin<|im_end|>\n...` biçimini ayrıştırır. Sondaki açık asistan turu
/// (`<|im_start|>assistant\n`) mesaj listesine girmez; [ChatMlParse.openAssistant] true olur.
/// Bozuk girdide [ChatMlFormatException] fırlatır.
ChatMlParse parseChatMl(String prompt) {
  if (!prompt.contains(_kStart)) {
    throw const ChatMlFormatException('istemde <|im_start|> işareti yok (ChatML değil)');
  }
  final messages = <ChatMlMessage>[];
  var open = false;
  var prefill = '';
  var i = 0;
  while (true) {
    final s = prompt.indexOf(_kStart, i);
    if (s < 0) {
      if (prompt.substring(i).trim().isNotEmpty) {
        throw const ChatMlFormatException('son turdan sonra tur dışı metin var');
      }
      break;
    }
    if (prompt.substring(i, s).trim().isNotEmpty) {
      throw const ChatMlFormatException('turlar arasında tur dışı metin var');
    }
    final headStart = s + _kStart.length;
    final nl = prompt.indexOf('\n', headStart);
    final roleText =
        (nl < 0 ? prompt.substring(headStart) : prompt.substring(headStart, nl)).trim();
    final role = _roleOf(roleText);
    if (nl < 0) {
      // "<|im_start|>assistant" satır sonu olmadan bitti: açık asistan turu.
      if (role != ChatMlRole.assistant) {
        throw ChatMlFormatException('"$roleText" turu eksik: satır sonu yok');
      }
      open = true;
      break;
    }
    final bodyStart = nl + 1;
    final end = prompt.indexOf(_kEnd, bodyStart);
    final next = prompt.indexOf(_kStart, bodyStart);
    if (end < 0) {
      if (next >= 0) {
        throw ChatMlFormatException('"$roleText" turu <|im_end|> ile kapanmamış');
      }
      if (role != ChatMlRole.assistant) {
        throw ChatMlFormatException('açık tur yalnızca asistan turu olabilir ("$roleText")');
      }
      open = true;
      prefill = prompt.substring(bodyStart);
      break;
    }
    if (next >= 0 && next < end) {
      throw ChatMlFormatException('"$roleText" turu kapanmadan yeni tur başlıyor');
    }
    messages.add(ChatMlMessage(role, prompt.substring(bodyStart, end)));
    i = end + _kEnd.length;
  }

  for (var k = 1; k < messages.length; k++) {
    if (messages[k].role == ChatMlRole.system) {
      throw const ChatMlFormatException('system turu yalnızca ilk tur olabilir');
    }
  }
  final parse = ChatMlParse(
    messages: List.unmodifiable(messages),
    openAssistant: open,
    assistantPrefill: prefill.trim().isEmpty ? '' : prefill,
  );
  final turns = parse.turns;
  if (turns.isEmpty) {
    throw const ChatMlFormatException('istemde kullanıcı mesajı yok');
  }
  if (turns.last.role != ChatMlRole.user) {
    throw const ChatMlFormatException('son kapalı tur kullanıcı turu olmalı');
  }
  return parse;
}
