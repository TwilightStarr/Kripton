import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'crash_guard.dart';
import 'llm_engine.dart';
import 'secret_mask.dart';

/// Kullanıcıya gösterilecek hata: anlaşılır başlık + mesaj; teknik ayrıntı ayrı tutulur.
class UserError {
  const UserError({required this.title, required this.message, required this.detail, this.id = 0});

  final String title;
  final String message;

  /// Teknik ayrıntı ("Ayrıntı" altında gösterilir); API anahtarları maskelenmiştir.
  final String detail;

  /// Her yeni gösterimde artar; dinleyiciler aynı hatayı iki kez göstermesin diye.
  final int id;

  UserError withId(int id) => UserError(title: title, message: message, detail: detail, id: id);
}

/// Teknik bir hatayı kullanıcıya anlaşılır Türkçe başlık/mesaja çevirir.
UserError describeError(Object error, [StackTrace? stack, String source = '']) {
  final detail = SecretMask.redact(
    '${source.isEmpty ? '' : '[$source] '}${error.runtimeType}: $error${stack == null ? '' : '\n$stack'}',
  );
  String title;
  String message;
  if (error is GenerationFailedException) {
    title = 'Üretim başarısız';
    message = SecretMask.redact(error.message);
  } else if (error is InsufficientMemoryException) {
    title = 'Bellek yetersiz';
    message = SecretMask.redact(error.message);
  } else if (error is ModelFileException) {
    title = 'Model dosyası geçersiz';
    message = 'Model dosyası eksik veya bozuk görünüyor. Model yöneticisinden yeniden indir.';
  } else if (error is SocketException ||
      error is TlsException ||
      error is HttpException ||
      error is TimeoutException) {
    title = 'Bağlantı sorunu';
    message = 'İnternet bağlantısı kurulamadı veya sunucu zamanında yanıt vermedi. '
        'Bağlantını kontrol edip yeniden dene.';
  } else if (error is FileSystemException) {
    final full = '${error.osError?.message ?? ''} ${error.message}'.toLowerCase();
    title = 'Dosya işlemi başarısız';
    message = full.contains('no space') || full.contains('space left')
        ? 'Depolama alanı dolu. Yer açıp yeniden dene.'
        : 'Bir dosya okunamadı veya yazılamadı. Depolama alanını ve dosya izinlerini kontrol et.';
  } else if (error is FormatException) {
    title = 'Veri okunamadı';
    message = 'Bir dosya veya sunucu yanıtı beklenen biçimde değil. İşlemi yeniden dene.';
  } else if (error is OutOfMemoryError) {
    title = 'Bellek yetersiz';
    message = 'Cihazın belleği doldu. Diğer uygulamaları kapat veya daha küçük bir model seç.';
  } else {
    title = 'Beklenmedik bir hata oluştu';
    message = 'Uygulama çalışmaya devam ediyor. Sorun sürerse "Ayrıntı"yı kopyalayıp paylaşabilirsin.';
  }
  return UserError(title: title, message: message, detail: detail);
}

/// Tüm hataların (Flutter, platform, zone, isolate, yakalanıp bildirilen) tek giriş noktası.
/// Her hata önce crash.log'a yazılır; sonra (hız sınırıyla) kullanıcıya Türkçe mesaj olarak sunulur.
/// [report] hiçbir koşulda istisna fırlatmaz.
class ErrorReporter {
  ErrorReporter({DateTime Function()? clock, this.minGap = const Duration(seconds: 8)})
      : _clock = clock ?? DateTime.now;

  static final ErrorReporter instance = ErrorReporter();

  final DateTime Function() _clock;

  /// Aynı hata bu süre içinde yeniden gösterilmez; farklı hatalar da bu süre aralıklıdır.
  final Duration minGap;

  /// Arayüz bunu dinler; yeni hata geldikçe değer değişir.
  final ValueNotifier<UserError?> latest = ValueNotifier<UserError?>(null);

  String _lastKey = '';
  DateTime? _lastShown;
  int _seq = 0;

  /// Günlüğe yazılan ama hız sınırı nedeniyle gösterilmeyen hata sayısı.
  int suppressed = 0;

  void report(String source, Object error, [StackTrace? stack, bool show = true]) {
    try {
      CrashGuard.log(source, error, stack);
    } catch (_) {}
    if (!show) return;
    try {
      final now = _clock();
      final u = describeError(error, stack, source);
      final key = '${u.title}|${u.message}';
      final last = _lastShown;
      if (last != null && now.difference(last) < minGap) {
        suppressed++;
        return;
      }
      if (key == _lastKey && last != null && now.difference(last) < minGap * 4) {
        suppressed++;
        return;
      }
      _lastKey = key;
      _lastShown = now;
      latest.value = u.withId(++_seq);
    } catch (_) {
      // Raporlama kendi hatasıyla uygulamayı düşürmez.
    }
  }
}
