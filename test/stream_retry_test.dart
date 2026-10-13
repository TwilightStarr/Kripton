// Değişiklik: YENİ — akış bırakma/yeniden deneme testleri (5 dk, yeni model, günlük "Akış bırakıldı"/"Akış hatası", yedek bilgi bayrağı).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/crash_guard.dart';
import 'package:kripton_ai/data/llm_engine.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('kripton_stream_');
    await CrashGuard.init(dir: tmp);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  LlamaEngine engineWith(FakeBackend b, DateTime Function() clock) =>
      LlamaEngine(backend: b, retryDelay: const Duration(milliseconds: 1), clock: clock);

  test('akış bırakılınca 5 dk dolmadan denenmez, dolunca yeniden denenir ve düzelirse bayrak kapanır', () async {
    var now = DateTime(2026, 10, 7, 12);
    final b = FakeBackend(streamError: noEventSink());
    final e = engineWith(b, () => now);

    await e.generate('p').toList();
    expect(e.streamingUnsupported, isTrue);
    expect(b.streamCalls, 2);
    expect(e.streamFallback.value, isTrue, reason: 'yedek yol: arayüz bilgi satırı göstermeli');

    final log = await CrashGuard.readLog();
    expect(log, contains('Akış hatası'));
    expect(log, contains('Akış bırakıldı'));
    expect(log, contains('NO_EVENT_SINK'));
    expect(log, contains('Event channel not initialized'));

    now = now.add(const Duration(minutes: 4));
    await e.generate('p').toList();
    expect(b.streamCalls, 2, reason: '5 dk dolmadı: akış denenmez');
    expect(e.streamingUnsupported, isTrue);

    now = now.add(const Duration(minutes: 2));
    b.streamError = null;
    final out = (await e.generate('p').toList()).join();
    expect(out, 'abc');
    expect(b.streamCalls, 3, reason: '5 dk doldu: akış yeniden denendi');
    expect(e.streamingUnsupported, isFalse);
    expect(e.streamFallback.value, isFalse);
  });

  test('süre dolunca akış yine hata verirse yeniden bırakılır ve süre yeniden başlar', () async {
    var now = DateTime(2026, 10, 7, 12);
    final b = FakeBackend(streamError: noEventSink());
    final e = engineWith(b, () => now);
    await e.generate('p').toList();
    expect(b.streamCalls, 2);

    now = now.add(const Duration(minutes: 5));
    await e.generate('p').toList();
    expect(b.streamCalls, 4, reason: 'yeniden deneme: ilk deneme + 1 tekrar');
    expect(e.streamingUnsupported, isTrue);

    now = now.add(const Duration(minutes: 1));
    await e.generate('p').toList();
    expect(b.streamCalls, 4, reason: 'süre yeniden başladı');
  });

  test('yeni model yüklenince akış hemen yeniden denenir', () async {
    final b = FakeBackend(streamError: noEventSink());
    final e = engineWith(b, () => DateTime(2026, 10, 7, 12));
    final m1 = fakeGguf(tmp);
    final m2 = File('${tmp.path}/m2.gguf')..writeAsBytesSync([0x47, 0x47, 0x55, 0x46, 0, 0]);

    await e.ensureLoaded(m1.path);
    await e.generate('p').toList();
    expect(e.streamingUnsupported, isTrue);
    expect(b.streamCalls, 2);

    b.streamError = null;
    await e.ensureLoaded(m2.path);
    expect(e.streamingUnsupported, isFalse);
    final out = (await e.generate('p').toList()).join();
    expect(out, 'abc');
    expect(b.streamCalls, 3);
    expect(e.streamFallback.value, isFalse);
    expect(await CrashGuard.readLog(), contains('Akış yeniden deneniyor'));
  });

  test('MissingPluginException: akış bırakılır, kod + mesaj günlüğe yazılır', () async {
    final b = FakeBackend(streamError: MissingPluginException('No implementation found'));
    final e = engineWith(b, () => DateTime(2026, 10, 7, 12));
    final out = (await e.generate('p').toList()).join();
    expect(out, startsWith('merhaba dünya'));
    expect(e.streamingUnsupported, isTrue);
    final log = await CrashGuard.readLog();
    expect(log, contains('Akış bırakıldı'));
    expect(log, contains('MissingPluginException'));
    expect(log, contains('No implementation found'));
  });

  test('akış sağlıklıysa yedek bayrağı hiç açılmaz', () async {
    final b = FakeBackend();
    final e = engineWith(b, () => DateTime(2026, 10, 7, 12));
    var everTrue = false;
    e.streamFallback.addListener(() {
      if (e.streamFallback.value) everTrue = true;
    });
    await e.generate('p').toList();
    expect(everTrue, isFalse);
    expect(e.streamFallback.value, isFalse);
  });
}
