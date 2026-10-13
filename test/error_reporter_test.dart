import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/error_reporter.dart';
import 'package:kripton_ai/data/llm_engine.dart';
import 'package:kripton_ai/main.dart' show installErrorHandlers;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('describeError', () {
    test('ağ hataları anlaşılır Türkçe mesaja çevrilir', () {
      for (final e in <Object>[
        const SocketException('x'),
        TimeoutException('t'),
        const HttpException('h'),
      ]) {
        final u = describeError(e);
        expect(u.title, 'Bağlantı sorunu');
        expect(u.message, contains('İnternet'));
      }
    });

    test('depolama dolu ve genel dosya hataları ayırt edilir', () {
      final full = describeError(
        const FileSystemException('yazılamadı', '/x', OSError('No space left on device', 28)),
      );
      expect(full.message, contains('Depolama alanı dolu'));
      final other = describeError(const FileSystemException('okunamadı', '/x'));
      expect(other.title, 'Dosya işlemi başarısız');
    });

    test('uygulama istisnaları kendi mesajını taşır; bilinmeyen hata genel mesaj alır', () {
      expect(describeError(const GenerationFailedException('Özel mesaj', code: 'X')).message, 'Özel mesaj');
      expect(describeError(const FormatException('bozuk')).title, 'Veri okunamadı');
      final u = describeError(StateError('ham'));
      expect(u.title, 'Beklenmedik bir hata oluştu');
      expect(u.message, isNot(contains('StateError')), reason: 'teknik metin ana mesajda yok');
      expect(u.detail, contains('StateError'), reason: 'ayrıntı altında var');
    });

    test('ayrıntıdaki API anahtarları maskelenir', () {
      final u = describeError(StateError('anahtar AIzaSyA12345678901234567890 sızdı'));
      expect(u.detail, isNot(contains('AIzaSyA12345678901234567890')));
    });
  });

  group('ErrorReporter', () {
    test('hız sınırı: kısa sürede ikinci hata gösterilmez, süre dolunca gösterilir', () {
      var now = DateTime(2026, 1, 1, 12);
      final r = ErrorReporter(clock: () => now, minGap: const Duration(seconds: 8));
      r.report('A', StateError('bir'));
      expect(r.latest.value?.id, 1);
      r.report('B', const SocketException('iki'));
      expect(r.latest.value?.id, 1);
      expect(r.suppressed, 1);
      now = now.add(const Duration(seconds: 9));
      r.report('B', const SocketException('iki'));
      expect(r.latest.value?.id, 2);
      expect(r.latest.value?.title, 'Bağlantı sorunu');
    });

    test('show=false yalnızca günlüğe yazar; kullanıcıya gösterilmez', () {
      final r = ErrorReporter();
      r.report('Açılış', StateError('sessiz'), null, false);
      expect(r.latest.value, isNull);
    });

    test('report hiçbir koşulda istisna fırlatmaz', () {
      final r = ErrorReporter();
      expect(() => r.report('X', Object()), returnsNormally);
      expect(() => r.report('X', _BadToString()), returnsNormally);
    });
  });

  test('installErrorHandlers: FlutterError ve PlatformDispatcher hataları rapora düşer', () {
    final oldFlutter = FlutterError.onError;
    final oldPlatform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = oldFlutter;
      PlatformDispatcher.instance.onError = oldPlatform;
    });
    ErrorReporter.instance.latest.value = null;
    installErrorHandlers(isolateListener: false);
    FlutterError.reportError(FlutterErrorDetails(exception: StateError('çerçeve hatası')));
    final u = ErrorReporter.instance.latest.value;
    expect(u, isNotNull);
    expect(u!.detail, contains('[FlutterError]'));
    expect(u.detail, contains('çerçeve hatası'));
    expect(PlatformDispatcher.instance.onError!(StateError('platform'), StackTrace.current), isTrue);
  });
}

class _BadToString {
  @override
  String toString() => throw StateError('toString patladı');
}
