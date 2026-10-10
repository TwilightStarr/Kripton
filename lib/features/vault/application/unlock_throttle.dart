// SPDX-License-Identifier: Apache-2.0
import 'dart:math' as math;

/// İstemci tarafı, YALNIZCA bilgi amaçlı bekleme.
///
/// Gerçek koruma Argon2id'dir (her deneme saniyeler sürer ve saldırgan zaten
/// uygulamayı atlayıp başlık dosyasına çevrimdışı saldırabilir). Bu sayaç
/// bellekte tutulur: uygulama yeniden başlatılınca sıfırlanır; amaç yalnızca
/// ekrandan art arda deneme yapmayı yavaşlatmaktır.
class UnlockThrottle {
  UnlockThrottle({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// Bu sayıdan sonra bekleme başlar (ilk iki yanlış deneme beklemesizdir).
  static const int freeAttempts = 2;
  static const Duration baseDelay = Duration(seconds: 5);
  static const Duration maxDelay = Duration(minutes: 5);

  int _failures = 0;
  DateTime? _until;

  int get failures => _failures;
  DateTime? get lockedUntil {
    final u = _until;
    return u != null && u.isAfter(_clock()) ? u : null;
  }

  Duration get remaining {
    final u = lockedUntil;
    return u == null ? Duration.zero : u.difference(_clock());
  }

  void recordFailure() {
    _failures++;
    final over = _failures - freeAttempts;
    if (over <= 0) return;
    final factor = 1 << math.min(over - 1, 6); // taşmayı önle
    final delay = baseDelay * factor;
    _until = _clock().add(delay > maxDelay ? maxDelay : delay);
  }

  void recordSuccess() {
    _failures = 0;
    _until = null;
  }
}
