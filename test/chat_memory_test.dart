import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/chat_memory.dart';
import 'package:kripton_ai/domain/chat_models.dart';
import 'package:kripton_ai/domain/chat_template.dart';
import 'package:kripton_ai/domain/entities.dart';

MemoryItem item(String id, String text, {MemoryKind kind = MemoryKind.message, int ts = 0, String group = 'chat'}) =>
    MemoryItem(id: id, kind: kind, text: text, ts: ts, group: group, label: kind == MemoryKind.profile ? 'hakkimda.md' : '');

ChatMessage msg(String id, ChatRole r, String text) => ChatMessage(id: id, role: r, text: text, ts: 1);

void main() {
  group('foldTr / memoryTokens', () {
    test('Türkçe harfleri katlar', () {
      expect(foldTr('İstanbul ÇOCUK Şeker ığdır'), 'istanbul cocuk seker igdir');
    });

    test('dolgu sözcükleri atılır, uzun sözcükler 5 harfe kırpılır', () {
      expect(memoryTokens('Ben kitaplarımı çok severim'), ['kitap', 'sever']);
    });
  });

  group('MemoryIndex', () {
    test('ilgili parçayı bulur; ek farkını tolere eder', () {
      final ix = MemoryIndex()
        ..add(item('a', 'Kedim Pamuk üç yaşında ve çok tembel'))
        ..add(item('b', 'Hafta sonu dağ yürüyüşüne gitmeyi severim'))
        ..add(item('c', 'Yazılım mühendisiyim, Flutter ile uygulama yazıyorum'));
      final r = ix.search('Kedimin adı neydi?');
      expect(r, isNotEmpty);
      expect(r.first.item.id, 'a');
      expect(ix.search('yürüyüş yapmak istiyorum').first.item.id, 'b');
    });

    test('eşleşme yoksa boş döner, exclude ve kinds uygulanır', () {
      final ix = MemoryIndex()
        ..add(item('a', 'Kedi Pamuk'))
        ..add(item('p', 'Kedi maması alacağım', kind: MemoryKind.profile, group: 's1'));
      expect(ix.search('uzay roketi'), isEmpty);
      expect(ix.search('kedi', exclude: {'a'}).map((e) => e.item.id), ['p']);
      expect(ix.search('kedi', kinds: {MemoryKind.message}).map((e) => e.item.id), ['a']);
    });

    test('removeGroup kaynağı tamamen çıkarır', () {
      final ix = MemoryIndex()
        ..add(item('p1', 'Bahçede domates yetiştiriyorum', kind: MemoryKind.profile, group: 's1'))
        ..add(item('p2', 'Domates salatası severim', kind: MemoryKind.profile, group: 's1'))
        ..add(item('m1', 'Domates fiyatları arttı', group: 'chat'));
      ix.removeGroup('s1');
      expect(ix.size, 1);
      expect(ix.search('domates').single.item.id, 'm1');
    });

    test('daha yeni mesaj eşit puanda öne geçer', () {
      final ix = MemoryIndex()
        ..add(item('old', 'toplantı notları', ts: 1))
        ..add(item('new', 'toplantı notları', ts: 2));
      expect(ix.search('toplantı').first.item.id, 'new');
    });
  });

  group('ChatOutputFilter', () {
    test('tur bitirme belirtecinden itibaren keser', () {
      final (t, hit) = ChatOutputFilter.clean('Merhaba!<|im_end|>\n<|im_start|>user\nx');
      expect(t, 'Merhaba!');
      expect(hit, isTrue);
    });

    test('sonda yarım kalan belirteci gizler', () {
      final (t, hit) = ChatOutputFilter.clean('Merhaba <|im_');
      expect(t, 'Merhaba ');
      expect(hit, isFalse);
      expect(ChatOutputFilter.clean('a < b olur').$1, 'a < b olur');
    });

    test('think bloklarını ayıklar', () {
      expect(ChatOutputFilter.splitThink('<think>düşünce</think>Cevap'), ('Cevap', false));
      expect(ChatOutputFilter.splitThink('Selam<think>yarım'), ('Selam', true));
      expect(ChatOutputFilter.splitThink('düşünce</think>Cevap').$1, 'Cevap');
    });
  });

  group('applyChatTemplate', () {
    final turns = [
      const ChatTurn(ChatRole.user, 'merhaba'),
      const ChatTurn(ChatRole.assistant, 'selam'),
      const ChatTurn(ChatRole.user, 'nasılsın'),
    ];

    test('her şablon son turdan sonra asistan başlangıcı koyar ve geçmişi içerir', () {
      for (final t in ChatTemplate.values) {
        final p = applyChatTemplate(t, 'SİSTEM', turns);
        expect(p, contains('SİSTEM'), reason: '$t');
        expect(p, contains('merhaba'), reason: '$t');
        expect(p, contains('selam'), reason: '$t');
        expect(p.indexOf('nasılsın'), greaterThan(p.indexOf('selam')), reason: '$t');
      }
    });

    test('chatml biçimi', () {
      final p = applyChatTemplate(ChatTemplate.chatml, 'S', turns);
      expect(p.startsWith('<|im_start|>system\nS<|im_end|>\n'), isTrue);
      expect(p.endsWith('<|im_start|>assistant\n'), isTrue);
    });

    test('tek turlu şablonla aynı başlangıcı üretir', () {
      final one = applyChatTemplate(ChatTemplate.chatml, 'S', [const ChatTurn(ChatRole.user, 'U')]);
      expect(one, applyTemplate(ChatTemplate.chatml, 'S', 'U'));
      final l3 = applyChatTemplate(ChatTemplate.llama3, 'S', [const ChatTurn(ChatRole.user, 'U')]);
      expect(l3, applyTemplate(ChatTemplate.llama3, 'S', 'U'));
    });
  });

  group('ChatPromptBuilder', () {
    final history = [
      msg('1', ChatRole.assistant, 'önceki yanıt'),
      msg('2', ChatRole.user, 'ilk soru'),
      msg('3', ChatRole.assistant, 'ilk cevap'),
    ];

    test('hafıza bölümleri ve geçmiş istemde yer alır; baştaki asistan turu atılır', () {
      final p = ChatPromptBuilder.build(
        template: ChatTemplate.chatml,
        charBudget: 6000,
        userText: 'Kedimin adı ne?',
        history: history,
        pins: [item('n1', 'Adım Ali', kind: MemoryKind.pin, group: 'pin')],
        core: [item('c1', 'Mühendisim.', kind: MemoryKind.profile, group: 's1')],
        recalled: [item('m9', 'Kedim Pamuk', ts: DateTime(2026, 9, 1).millisecondsSinceEpoch)],
        now: DateTime(2026, 10, 5),
      );
      expect(p.prompt, contains('Adım Ali'));
      expect(p.prompt, contains('Mühendisim.'));
      expect(p.prompt, contains('Kedim Pamuk'));
      expect(p.prompt, contains('2026-09-01'));
      expect(p.prompt, contains('Bugünün tarihi: 2026-10-05'));
      expect(p.prompt, contains('ilk soru'));
      expect(p.prompt, isNot(contains('önceki yanıt')));
      expect(p.historyTurns, 2);
      expect(p.prompt.endsWith('<|im_start|>assistant\n'), isTrue);
    });

    test('bütçe küçülünce istem küçülür ve kullanıcı mesajı korunur', () {
      final big = [for (var i = 0; i < 40; i++) msg('h$i', i.isEven ? ChatRole.user : ChatRole.assistant, 'mesaj $i ' * 40)];
      final small = ChatPromptBuilder.build(
        template: ChatTemplate.chatml,
        charBudget: 2500,
        userText: 'son soru',
        history: big,
      );
      final large = ChatPromptBuilder.build(
        template: ChatTemplate.chatml,
        charBudget: 9000,
        userText: 'son soru',
        history: big,
      );
      expect(small.prompt.length, lessThanOrEqualTo(2500));
      expect(small.prompt, contains('son soru'));
      expect(large.historyTurns, greaterThan(small.historyTurns));
    });

    test('çok uzun kullanıcı mesajı ortadan kısaltılır', () {
      final p = ChatPromptBuilder.build(
        template: ChatTemplate.chatml,
        charBudget: 3000,
        userText: 'a' * 20000,
        history: const [],
      );
      expect(p.userTrimmed, isTrue);
      expect(p.prompt.length, lessThanOrEqualTo(3200));
    });

    test('buildWithin token sınırına sığdırır', () {
      final big = [for (var i = 0; i < 30; i++) msg('h$i', i.isEven ? ChatRole.user : ChatRole.assistant, 'konuşma ${'x' * 300}')];
      final fit = ChatPromptBuilder.buildWithin(
        template: ChatTemplate.chatml,
        charBudget: 20000,
        maxPromptTokens: 700,
        userText: 'soru',
        history: big,
      );
      expect(fit.fits, isTrue);
    });
  });
}
