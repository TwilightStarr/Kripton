import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/app_controller.dart' show engineProvider;
import 'package:kripton_ai/application/chat_controller.dart';
import 'package:kripton_ai/application/engine_lock.dart';
import 'package:kripton_ai/application/settings_controller.dart';
import 'package:kripton_ai/data/chat_store.dart';
import 'package:kripton_ai/domain/chat_models.dart';
import 'package:kripton_ai/domain/entities.dart';
import 'package:kripton_ai/domain/start_screen.dart';

import 'helpers.dart';

GgufModel _model(String id, {ChatTemplate t = ChatTemplate.chatml, String? path = '/tmp/x.gguf'}) => GgufModel(
  id: id,
  name: 'Test $id',
  family: 'qwen',
  parameters: '1B',
  quantization: 'Q4',
  sizeGb: 1,
  ramGb: 2,
  tokensPerSec: '10',
  quality: '',
  url: '',
  fileName: '$id.gguf',
  template: t,
  localPath: path,
  sizeBytes: 1,
);

Uint8List _zip(Map<String, String> files) {
  final a = Archive();
  files.forEach((k, v) {
    final d = utf8.encode(v);
    a.addFile(ArchiveFile(k, d.length, d));
  });
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? dirOrNull;
  Directory get dir => dirOrNull!;
  set dir(Directory d) => dirOrNull = d;
  late FakeEngine engine;
  ProviderContainer? containerOrNull;
  ProviderContainer get container => containerOrNull!;
  set container(ProviderContainer c) => containerOrNull = c;

  Future<ChatController> boot({
    FakeEngine? e,
    bool workflowBusy = false,
    List<ChatMessage> seed = const [],
    List<GgufModel>? models,
  }) async {
    dir = Directory.systemTemp.createTempSync('kripton_chatc_');
    final store = ChatStore(root: dir);
    for (final m in seed) {
      await store.append(m);
    }
    engine = e ?? FakeEngine(ctx: 4096, responder: (p, c) => 'Tamam, anladım.');
    container = ProviderContainer(
      overrides: [
        engineProvider.overrideWithValue(engine),
        chatStoreProvider.overrideWithValue(store),
        chatModelsProvider.overrideWithValue(models ?? [_model('m1')]),
        chatModelsLoadedProvider.overrideWithValue(true),
        workflowBusyProvider.overrideWithValue(workflowBusy),
        chatDefaultModelIdProvider.overrideWithValue('m1'),
      ],
    );
    final c = container.read(chatProvider.notifier);
    for (var i = 0; i < 200 && !container.read(chatProvider).loaded; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(chatProvider).loaded, isTrue);
    return c;
  }

  tearDown(() {
    containerOrNull?.dispose();
    containerOrNull = null;
    final d = dirOrNull;
    if (d != null && d.existsSync()) d.deleteSync(recursive: true);
    dirOrNull = null;
  });

  ChatMessage seedMsg(String id, ChatRole r, String t, int ts) => ChatMessage(id: id, role: r, text: t, ts: ts);

  test('soru ve yanıt kalıcı kaydedilir; yeniden açılınca geçmiş gelir', () async {
    final c = await boot();
    await c.send('Merhaba Kripton');
    final s = container.read(chatProvider);
    expect(s.messages.map((m) => m.role), [ChatRole.user, ChatRole.assistant]);
    expect(s.messages.last.text, 'Tamam, anladım.');
    expect(s.generating, isFalse);
    expect(container.read(chatBusyProvider), isFalse);
    expect(engine.prompts.single, contains('Merhaba Kripton'));

    final saved = await ChatStore(root: dir).loadMessages();
    expect(saved.map((m) => m.text), ['Merhaba Kripton', 'Tamam, anladım.']);
    expect(saved.last.modelId, 'm1');

    // Yeni bir kapsayıcı (uygulama yeniden açıldı): geçmiş silinmemiş olmalı.
    container.dispose();
    container = ProviderContainer(
      overrides: [
        engineProvider.overrideWithValue(engine),
        chatStoreProvider.overrideWithValue(ChatStore(root: dir)),
        chatModelsProvider.overrideWithValue([_model('m1')]),
        chatModelsLoadedProvider.overrideWithValue(true),
        workflowBusyProvider.overrideWithValue(false),
        chatDefaultModelIdProvider.overrideWithValue('m1'),
      ],
    );
    container.read(chatProvider);
    for (var i = 0; i < 200 && !container.read(chatProvider).loaded; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(chatProvider).messages.length, 2);
    expect(container.read(chatProvider).totalMessages, 2);
  });

  test('model önceki konuşmayı aynı oturumda görür (çok turlu istem)', () async {
    final c = await boot();
    await c.send('Adım Ali');
    await c.send('Adım neydi?');
    expect(engine.prompts.last, contains('Adım Ali'));
    expect(engine.prompts.last, contains('Tamam, anladım.'));
    expect(engine.prompts.last, contains('Adım neydi?'));
  });

  test('çok eski bir konuşma, geçmiş penceresinden çıksa da aranıp hatırlatılır', () async {
    final seed = <ChatMessage>[
      seedMsg('old1', ChatRole.user, 'Geçen yıl Kapadokya\'da balon turuna çıktım', 1000),
      seedMsg('old2', ChatRole.assistant, 'Harika bir deneyim olmuş!', 1001),
      for (var i = 0; i < 40; i++)
        seedMsg('f$i', i.isEven ? ChatRole.user : ChatRole.assistant, 'sıradan dolgu mesajı numara $i', 2000 + i),
    ];
    final c = await boot(seed: seed);
    await c.send('Kapadokya gezim nasıldı hatırlıyor musun?');
    final p = engine.prompts.single;
    expect(p, contains('balon turuna'));
    expect(container.read(chatProvider).lastRecalled, greaterThan(0));
  });

  test('profil ZIP\'i yüklenince sorularda kullanılır; kaldırılınca kullanılmaz', () async {
    final c = await boot();
    await c.importProfileBytes(
      _zip({'ben/hakkimda.md': 'Adım Ali. Kedimin adı Pamuk. Ankara\'da yaşıyorum.'}),
      'ben.zip',
    );
    var s = container.read(chatProvider);
    expect(s.sources.single.name, 'ben.zip');
    expect(s.importing, isFalse);

    await c.send('Kedimin adı ne?');
    expect(engine.prompts.last, contains('Pamuk'));

    // Aynı adlı ZIP tekrar yüklenirse çoğalmaz.
    await c.importProfileBytes(_zip({'ben/hakkimda.md': 'Adım Ali. Kedimin adı Pamuk.'}), 'ben.zip');
    expect(container.read(chatProvider).sources.length, 1);

    await c.removeSource(container.read(chatProvider).sources.single.id);
    s = container.read(chatProvider);
    expect(s.sources, isEmpty);
    await c.send('Kedimin adı ne?');
    expect(engine.prompts.last.contains('Ankara'), isFalse);

    // Profil diskte de kalıcı: bozuk ZIP bildirim verir, durumu bozmaz.
    await c.importProfileBytes(Uint8List.fromList([1, 2, 3]), 'bozuk.zip');
    expect(container.read(chatProvider).notice, contains('ZIP'));
    expect(container.read(chatProvider).sources, isEmpty);
  });

  test('sabit not her yanıtta modele verilir ve diske yazılır', () async {
    final c = await boot();
    await c.addPin('Her zaman kısa cevap ver');
    await c.send('Merhaba');
    expect(engine.prompts.single, contains('Her zaman kısa cevap ver'));
    expect((await ChatStore(root: dir).loadMemory()).pins.single.text, 'Her zaman kısa cevap ver');
    await c.removePin(container.read(chatProvider).pins.single.id);
    await c.send('Tekrar');
    expect(engine.prompts.last.contains('Her zaman kısa cevap ver'), isFalse);
  });

  test('model kendi turunu bitirip yeni tur uydurursa kesilir', () async {
    final c = await boot(
      e: FakeEngine(ctx: 4096, responder: (p, c) => 'Merhaba!<|im_end|>\n<|im_start|>user\nsahte soru'),
    );
    await c.send('Selam');
    expect(container.read(chatProvider).messages.last.text, 'Merhaba!');
  });

  test('think blokları kaydedilen yanıta girmez', () async {
    final c = await boot(
      e: FakeEngine(ctx: 4096, responder: (p, c) => '<think>önce düşüneyim</think>Cevap burada.'),
    );
    await c.send('Soru');
    expect(container.read(chatProvider).messages.last.text, 'Cevap burada.');
  });

  test('üretim hatasında soru kayıtlı kalır, tekrar dene yalnızca yanıtı üretir', () async {
    final c = await boot(e: FakeEngine(ctx: 4096, failOnCall: 1, responder: (p, c) => 'Şimdi oldu.'));
    await c.send('Bir şey sor');
    var s = container.read(chatProvider);
    expect(s.error, isNotNull);
    expect(s.messages.map((m) => m.role), [ChatRole.user]);
    expect(s.generating, isFalse);
    expect(container.read(chatBusyProvider), isFalse);

    await c.retry();
    s = container.read(chatProvider);
    expect(s.error, isNull);
    expect(s.messages.map((m) => m.role), [ChatRole.user, ChatRole.assistant]);
    expect(s.messages.last.text, 'Şimdi oldu.');
    expect(s.messages.where((m) => m.role == ChatRole.user).length, 1);
  });

  test('durdur: üretim sürerken meşgul bayrağı açık, durdurunca yarım yanıt kayıtlı', () async {
    final c = await boot(e: FakeEngine(ctx: 4096, tokens: const ['Merhaba'], hangOnCall: 1));
    final fut = c.send('Uzun bir şey anlat');
    for (var i = 0; i < 200 && container.read(chatProvider).draft.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(chatProvider).generating, isTrue);
    expect(container.read(chatBusyProvider), isTrue);
    await c.stop();
    await fut;
    final s = container.read(chatProvider);
    expect(s.generating, isFalse);
    expect(container.read(chatBusyProvider), isFalse);
    expect(s.messages.last.role, ChatRole.assistant);
    expect(s.messages.last.text, startsWith('Merhaba'));
    expect(s.messages.last.text, contains('[durduruldu]'));
  });

  test('AI akışı çalışırken sohbet başlamaz ve mesaj kaydedilmez', () async {
    final c = await boot(workflowBusy: true);
    await c.send('Merhaba');
    expect(engine.generateCalls, 0);
    expect(container.read(chatProvider).messages, isEmpty);
    expect(container.read(chatProvider).notice, isNotNull);
  });

  test('indirilmiş model yoksa gönderilmez', () async {
    final c = await boot(models: [_model('m1', path: null)]);
    await c.send('Merhaba');
    expect(engine.generateCalls, 0);
    expect(container.read(chatProvider).messages, isEmpty);
  });

  test('model seçimi: kullanıcı seçimi > varsayılan > ilk indirilmiş (R1 olmayan)', () {
    final a = _model('a', t: ChatTemplate.deepseek);
    final b = _model('b');
    final n = _model('n', path: null);
    expect(resolveChatModel([a, b, n], 'a', 'b')?.id, 'a');
    expect(resolveChatModel([a, b, n], 'yok', 'b')?.id, 'b');
    expect(resolveChatModel([a, b, n], null, null)?.id, 'b');
    expect(resolveChatModel([a, n], null, null)?.id, 'a');
    expect(resolveChatModel([n], 'n', 'n'), isNull);
  });

  test('açılış ekranı ayarı kalıcı JSON\'a yazılır ve geri okunur', () {
    const s = AppSettings(startScreen: StartScreen.chat, chatModelId: 'm1');
    final back = AppSettings.fromJson(s.toJson());
    expect(back.startScreen, StartScreen.chat);
    expect(back.chatModelId, 'm1');
    expect(AppSettings.fromJson({}).startScreen, StartScreen.flow);
    expect(AppSettings.fromJson({'startScreen': 'bilinmeyen'}).startScreen, StartScreen.flow);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(settingsProvider.notifier).setStartScreen(StartScreen.dev);
    expect(c.read(settingsProvider).startScreen, StartScreen.dev);
  });
}
