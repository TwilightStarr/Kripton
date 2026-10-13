import 'chat_models.dart';
import 'entities.dart';

String applyTemplate(ChatTemplate t, String system, String user) {
  switch (t) {
    case ChatTemplate.chatml:
      return '<|im_start|>system\n$system<|im_end|>\n<|im_start|>user\n$user<|im_end|>\n<|im_start|>assistant\n';
    case ChatTemplate.llama3:
      return '<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n$system<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n$user<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n';
    case ChatTemplate.mistral:
      return '[INST] $system\n\n$user [/INST]';
    case ChatTemplate.phi3:
      return '<|system|>\n$system<|end|>\n<|user|>\n$user<|end|>\n<|assistant|>\n';
    case ChatTemplate.alpaca:
      return '$system\n\n### Instruction:\n$user\n\n### Response:\n';
    case ChatTemplate.deepseek:
      return '$system<｜User｜>$user<｜Assistant｜>';
  }
}

/// Çok turlu sohbet için tek bir konuşma turu.
class ChatTurn {
  const ChatTurn(this.role, this.text);

  final ChatRole role;
  final String text;
}

/// Çok turlu şablon: [system] + [turns] (eski → yeni; son tur kullanıcıdır) + asistan başlangıcı.
/// Tek turlu [applyTemplate] ile aynı biçimleri kullanır; yalnızca önceki turlar eklenir.
/// Not: [turns] kullanıcı turuyla BAŞLAMALIDIR (Mistral/Alpaca biçimleri bunu varsayar).
String applyChatTemplate(ChatTemplate t, String system, List<ChatTurn> turns) {
  final b = StringBuffer();
  bool isUser(ChatTurn x) => x.role == ChatRole.user;
  switch (t) {
    case ChatTemplate.chatml:
      b.write('<|im_start|>system\n$system<|im_end|>\n');
      for (final x in turns) {
        b.write('<|im_start|>${isUser(x) ? 'user' : 'assistant'}\n${x.text}<|im_end|>\n');
      }
      b.write('<|im_start|>assistant\n');
    case ChatTemplate.llama3:
      b.write('<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n$system<|eot_id|>');
      for (final x in turns) {
        b.write('<|start_header_id|>${isUser(x) ? 'user' : 'assistant'}<|end_header_id|>\n\n${x.text}<|eot_id|>');
      }
      b.write('<|start_header_id|>assistant<|end_header_id|>\n\n');
    case ChatTemplate.mistral:
      var first = true;
      for (final x in turns) {
        if (isUser(x)) {
          b.write(first ? '[INST] $system\n\n${x.text} [/INST]' : '[INST] ${x.text} [/INST]');
          first = false;
        } else {
          b.write(' ${x.text}</s>');
        }
      }
      if (first) b.write('[INST] $system [/INST]');
    case ChatTemplate.phi3:
      b.write('<|system|>\n$system<|end|>\n');
      for (final x in turns) {
        b.write('<|${isUser(x) ? 'user' : 'assistant'}|>\n${x.text}<|end|>\n');
      }
      b.write('<|assistant|>\n');
    case ChatTemplate.alpaca:
      b.write('$system\n\n');
      for (final x in turns) {
        b.write(isUser(x) ? '### Instruction:\n${x.text}\n\n' : '### Response:\n${x.text}\n\n');
      }
      b.write('### Response:\n');
    case ChatTemplate.deepseek:
      b.write(system);
      for (final x in turns) {
        b.write(isUser(x) ? '<｜User｜>${x.text}' : '<｜Assistant｜>${x.text}<｜end▁of▁sentence｜>');
      }
      b.write('<｜Assistant｜>');
  }
  return b.toString();
}
