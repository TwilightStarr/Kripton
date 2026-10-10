// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/security/password_strength.dart';
import 'package:quanta/features/vault/application/password_policy.dart';
import 'package:quanta/features/vault/application/unlock_throttle.dart';

PasswordReport report({
  required int score,
  int length = 16,
  bool common = false,
}) =>
    PasswordReport(
      guessesLog10: 0,
      score: score,
      weaknesses: const {},
      isCommon: common,
      length: length,
    );

void main() {
  group('judgePassword', () {
    test('kısa, ortak veya çok zayıf -> engellenir', () {
      expect(judgePassword(report(score: 4, length: 8)),
          PasswordVerdict.blocked);
      expect(judgePassword(report(score: 4, common: true)),
          PasswordVerdict.blocked);
      expect(judgePassword(report(score: 1)), PasswordVerdict.blocked);
      expect(judgePassword(report(score: 0)), PasswordVerdict.blocked);
    });

    test('skor 2 -> uyarı + onay', () {
      expect(judgePassword(report(score: 2)), PasswordVerdict.weak);
    });

    test('skor >= 3 ve uzun -> tamam', () {
      expect(judgePassword(report(score: 3)), PasswordVerdict.ok);
      expect(judgePassword(report(score: 4)), PasswordVerdict.ok);
    });
  });

  group('UnlockThrottle', () {
    late DateTime now;
    late UnlockThrottle t;
    setUp(() {
      now = DateTime.utc(2026, 1, 1);
      t = UnlockThrottle(clock: () => now);
    });

    test('ilk iki hata beklemesiz', () {
      t.recordFailure();
      t.recordFailure();
      expect(t.remaining, Duration.zero);
      expect(t.lockedUntil, isNull);
    });

    test('sonraki hatalarda bekleme katlanır ve sınırlanır', () {
      t.recordFailure();
      t.recordFailure();
      t.recordFailure();
      expect(t.remaining, const Duration(seconds: 5));
      now = now.add(const Duration(seconds: 6));
      expect(t.remaining, Duration.zero);
      t.recordFailure();
      expect(t.remaining, const Duration(seconds: 10));
      for (var i = 0; i < 20; i++) {
        t.recordFailure();
      }
      expect(t.remaining, UnlockThrottle.maxDelay);
    });

    test('başarı sayacı sıfırlar', () {
      for (var i = 0; i < 5; i++) {
        t.recordFailure();
      }
      t.recordSuccess();
      expect(t.failures, 0);
      expect(t.remaining, Duration.zero);
    });
  });
}
