import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/chat_store.dart';
import 'package:kripton_ai/domain/chat_models.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('kripton_chat_'));
  tearDown(() => dir.deleteSync(recursive: true));

  ChatMessage m(String id, ChatRole r, String t) => ChatMessage(id: id, role: r, text: t, ts: 1000, modelId: r == ChatRole.assistant ? 'q' : null);

  test('mesajlar sıraya eklenir ve yeniden açılınca aynen okunur', () async {
    final s = ChatStore(root: dir);
    await s.append(m('1', ChatRole.user, 'Merhaba\nçok satırlı "tırnak"'));
    await s.append(m('2', ChatRole.assistant, 'Selam'));
    final back = await ChatStore(root: dir).loadMessages();
    expect(back.map((e) => e.id), ['1', '2']);
    expect(back.first.text, 'Merhaba\nçok satırlı "tırnak"');
    expect(back.last.role, ChatRole.assistant);
    expect(back.last.modelId, 'q');
  });

  test('eşzamanlı eklemeler birbirine karışmaz', () async {
    final s = ChatStore(root: dir);
    await Future.wait([for (var i = 0; i < 30; i++) s.append(m('$i', ChatRole.user, 'metin $i'))]);
    final back = await s.loadMessages();
    expect(back.length, 30);
    expect({for (final e in back) e.id}.length, 30);
  });

  test('yarım yazılmış son satır yok sayılır, sonraki ekleme kurtarılır', () async {
    final s = ChatStore(root: dir);
    await s.append(m('1', ChatRole.user, 'a'));
    final f = File('${dir.path}/history.jsonl');
    await f.writeAsString('{"id":"x","role":"user","te', mode: FileMode.append, flush: true);
    expect((await ChatStore(root: dir).loadMessages()).map((e) => e.id), ['1']);
    await ChatStore(root: dir).append(m('2', ChatRole.user, 'b'));
    expect((await ChatStore(root: dir).loadMessages()).map((e) => e.id), ['1', '2']);
  });

  test('hafıza (profil + sabit not) gidiş-dönüş', () async {
    final s = ChatStore(root: dir);
    expect((await s.loadMemory()).sources, isEmpty);
    final data = MemoryData(
      sources: [
        const ProfileSource(
          id: 'src-1',
          name: 'ben.zip',
          importedAt: 5,
          fileCount: 1,
          chunks: [ProfileChunk('a.md', 'Adım Ali')],
        ),
      ],
      pins: const [PinnedNote(id: 'p1', text: 'Kedim Pamuk', ts: 7)],
    );
    await s.saveMemory(data);
    final back = await ChatStore(root: dir).loadMemory();
    expect(back.sources.single.chunks.single.text, 'Adım Ali');
    expect(back.pins.single.text, 'Kedim Pamuk');
  });

  test('bozuk memory.json boş hafıza döndürür', () async {
    File('${dir.path}/memory.json').writeAsStringSync('{bozuk');
    expect((await ChatStore(root: dir).loadMemory()).pins, isEmpty);
  });

  test('Markdown dışa aktarma tüm mesajları içerir', () async {
    final s = ChatStore(root: dir);
    final out = Directory('${dir.path}/out');
    final f = await s.exportMarkdown(out, [m('1', ChatRole.user, 'Soru?'), m('2', ChatRole.assistant, 'Cevap.')]);
    final text = f.readAsStringSync();
    expect(text, contains('Soru?'));
    expect(text, contains('Cevap.'));
    expect(text, contains('2 mesaj'));
  });
}
