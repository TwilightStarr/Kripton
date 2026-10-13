// Değişiklik: YENİ — TypewriterText widget testleri (fake zaman: grapheme bölünmez, dokununca atlar, disableAnimations/kapalı anında, Durdur, kelime modu, yedek yolda harf harf).

import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/domain/chat_type_mode.dart';
import 'package:kripton_ai/presentation/typewriter_text.dart';

const _style = TextStyle(fontSize: 14, color: Colors.black);

Widget _host(
  TypewriterController ctl, {
  required String text,
  bool done = false,
  ChatTypeMode mode = ChatTypeMode.letter,
  bool disableAnimations = false,
}) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
        child: TypewriterText(text: text, done: done, mode: mode, controller: ctl, style: _style),
      ),
    ),
  ),
);

String _plain(WidgetTester t) => t
    .widget<RichText>(find.descendant(of: find.byType(TypewriterText), matching: find.byType(RichText)))
    .text
    .toPlainText();

String _shown(WidgetTester t) => _plain(t).replaceAll('▍', '');

bool _hasCursor(WidgetTester t) => _plain(t).contains('▍');

void main() {
  const text = 'Merhaba dünya, nasılsın bugün?';

  testWidgets('harf harf ilerler, imleç görünür; üretim bitip tamamen gösterilince imleç kaybolur', (t) async {
    final ctl = TypewriterController();
    addTearDown(ctl.dispose);
    await t.pumpWidget(_host(ctl, text: text));
    expect(_shown(t), isEmpty);
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 100));
    final partial = _shown(t);
    expect(partial, isNotEmpty);
    expect(partial.length, lessThan(text.length));
    expect(text.startsWith(partial), isTrue);
    expect(_hasCursor(t), isTrue);

    // Üretim bitti: kalan metin ~1 sn içinde tamamlanır.
    await t.pumpWidget(_host(ctl, text: text, done: true));
    await t.pump(const Duration(milliseconds: 600));
    await t.pump(const Duration(milliseconds: 600));
    await t.pump();
    expect(_shown(t), text);
    expect(_hasCursor(t), isFalse);
    expect(t.binding.transientCallbackCount, 0, reason: 'bitince ticker durmalı');
  });

  testWidgets('hız uyarlanır: metin büyürken animasyon üretimin ~0,4 sn gerisinde kalır', (t) async {
    final ctl = TypewriterController();
    addTearDown(ctl.dispose);
    final long = List.filled(40, 'kelime').join(' '); // 279 karakter, hepsi bekliyor
    await t.pumpWidget(_host(ctl, text: long));
    await t.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 25; i++) {
      await t.pump(const Duration(milliseconds: 16)); // ~0,4 sn
    }
    final pending = long.length - _shown(t).length;
    // Taban hızda (40 kar/sn) 0,4 sn'de en çok ~16 karakter ilerlerdi; uyarlanır hız çok daha fazlasını gösterir.
    expect(_shown(t).length, greaterThan(100));
    expect(pending, lessThan(long.length - 100));
  });

  testWidgets('grapheme ortadan bölünmez (ç ş ğ ı İ, emoji, ZWJ dizisi)', (t) async {
    final ctl = TypewriterController();
    addTearDown(ctl.dispose);
    const full = 'çşğıİ 😀 👨\u200D👩\u200D👧 çalış 🇹🇷 e\u0301';
    await t.pumpWidget(_host(ctl, text: full, done: true));
    final lengths = <int>{};
    for (var i = 0; i < 200; i++) {
      await t.pump(const Duration(milliseconds: 16));
      final v = _shown(t);
      lengths.add(v.characters.length);
      expect(full.startsWith(v), isTrue, reason: 'görünen kısım metnin öneki olmalı: "$v"');
      expect(
        full.characters.take(v.characters.length).string,
        v,
        reason: 'grapheme ortadan bölündü: "$v"',
      );
      if (v == full) break;
    }
    expect(_shown(t), full);
    expect(lengths.length, greaterThan(5), reason: 'tek seferde değil, kademeli ilerlemeli');
  });

  testWidgets('dokununca animasyon atlanır ve tüm metin görünür', (t) async {
    final ctl = TypewriterController();
    addTearDown(ctl.dispose);
    await t.pumpWidget(_host(ctl, text: text));
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 50));
    expect(_shown(t).length, lessThan(text.length));
    await t.tap(find.byType(TypewriterText));
    await t.pump();
    expect(_shown(t), text);
    expect(ctl.skipped, isTrue);
    expect(_hasCursor(t), isFalse);
  });

  testWidgets('MediaQuery.disableAnimations: metin anında görünür, imleç yok', (t) async {
    final ctl = TypewriterController();
    addTearDown(ctl.dispose);
    await t.pumpWidget(_host(ctl, text: text, disableAnimations: true));
    expect(_shown(t), text);
    expect(_hasCursor(t), isFalse);
    expect(t.binding.transientCallbackCount, 0);
  });

  testWidgets('mod "kapalı": metin anında görünür; metin uzadıkça da anında', (t) async {
    final ctl = TypewriterController();
    addTearDown(ctl.dispose);
    await t.pumpWidget(_host(ctl, text: 'Merhaba', mode: ChatTypeMode.off));
    expect(_shown(t), 'Merhaba');
    await t.pumpWidget(_host(ctl, text: 'Merhaba dünya', mode: ChatTypeMode.off));
    expect(_shown(t), 'Merhaba dünya');
    expect(_hasCursor(t), isFalse);
  });

  testWidgets('Durdur: animasyon hemen durur, görünen kısım kalır', (t) async {
    final ctl = TypewriterController();
    addTearDown(ctl.dispose);
    await t.pumpWidget(_host(ctl, text: text));
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 100));
    final before = _shown(t);
    expect(before, isNotEmpty);
    ctl.freeze();
    await t.pump();
    await t.pump(const Duration(seconds: 2));
    expect(_shown(t), before);
    expect(ctl.visibleCodeUnits, before.length);
    expect(_hasCursor(t), isFalse);
    expect(t.binding.transientCallbackCount, 0, reason: 'ticker durmalı');
    // Durdurulduktan sonra gelen metin görünmez.
    await t.pumpWidget(_host(ctl, text: '$text Daha fazla metin.'));
    await t.pump(const Duration(seconds: 1));
    expect(_shown(t), before);
  });

  testWidgets('kelime modu yalnızca kelime sınırlarında ilerler', (t) async {
    final ctl = TypewriterController();
    addTearDown(ctl.dispose);
    const words = 'bir iki üç dört beş altı yedi sekiz';
    await t.pumpWidget(_host(ctl, text: words, done: true, mode: ChatTypeMode.word));
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      await t.pump(const Duration(milliseconds: 16));
      final v = _shown(t);
      seen.add(v);
      expect(words.startsWith(v), isTrue);
      expect(v.isEmpty || v.length == words.length || words[v.length] == ' ', isTrue, reason: 'kelime ortasında kesildi: "$v"');
      if (v == words) break;
    }
    expect(_shown(t), words);
    expect(seen.length, greaterThan(3));
  });

  testWidgets('kelime modu: üretim sürerken tamamlanmamış son kelime gösterilmez', (t) async {
    final ctl = TypewriterController();
    addTearDown(ctl.dispose);
    await t.pumpWidget(_host(ctl, text: 'merhaba dün', mode: ChatTypeMode.word));
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(_shown(t), 'merhaba'); // "dün" henüz tamamlanmadı (arkasından boşluk gelmedi)
    await t.pumpWidget(_host(ctl, text: 'merhaba dünya ', mode: ChatTypeMode.word));
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(_shown(t), 'merhaba dünya');
  });

  testWidgets('yedek yol: tüm metin bir anda gelse de harf harf ilerler ve ~1 sn içinde biter', (t) async {
    final ctl = TypewriterController();
    addTearDown(ctl.dispose);
    final full = List.filled(12, 'Yanıt hazır olunca yazılıyor.').join(' ');
    await t.pumpWidget(_host(ctl, text: full, done: true));
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 100));
    final early = _shown(t).length;
    expect(early, greaterThan(0));
    expect(early, lessThan(full.length), reason: 'tek seferde "tak" çıkmamalı');
    await t.pump(const Duration(milliseconds: 500));
    final mid = _shown(t).length;
    expect(mid, greaterThan(early));
    await t.pump(const Duration(milliseconds: 600));
    await t.pump();
    expect(_shown(t), full);
  });

  testWidgets('kalıcı balon canlı balonun kaldığı yerden sürer (animasyon baştan oynamaz)', (t) async {
    final ctl = TypewriterController();
    addTearDown(ctl.dispose);
    final full = List.filled(10, 'Merhaba dünya.').join(' ');
    await t.pumpWidget(_host(ctl, text: full.substring(0, 60)));
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 300));
    final reached = _shown(t).length;
    expect(reached, greaterThan(0));
    // Canlı balon kaldırılır, aynı denetleyiciyle yeni widget (kalıcı balon) takılır.
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(_host(ctl, text: full, done: true));
    expect(_shown(t).length, greaterThanOrEqualTo(reached), reason: 'geri sarmamalı / zıplamamalı');
  });
}
