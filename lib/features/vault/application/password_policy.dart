// SPDX-License-Identifier: Apache-2.0
import '../../../core/crypto/vault_service.dart';
import '../../../core/security/password_strength.dart';

/// Yeni ana parola için karar.
enum PasswordVerdict {
  /// Kasa oluşturmayı ENGELLER (kısa, ortak parola veya çok zayıf).
  blocked,

  /// Net uyarı + açık onay (onay kutusu) gerekir.
  weak,

  /// Kabul edilebilir.
  ok,
}

/// Kural: uzunluk < [VaultService.minPasswordLength] veya ortak parola veya
/// skor < 2 -> engelle; skor 2 ya da [PasswordReport.acceptable] değilse -> uyar.
PasswordVerdict judgePassword(PasswordReport r) {
  if (r.length < VaultService.minPasswordLength || r.isCommon || r.score < 2) {
    return PasswordVerdict.blocked;
  }
  return r.acceptable ? PasswordVerdict.ok : PasswordVerdict.weak;
}

/// Zayıflık türlerinin Türkçe açıklamaları (kullanıcıya gösterilir).
String describeWeakness(Weakness w) => switch (w) {
      Weakness.tooShort => 'Çok kısa',
      Weakness.commonPassword => 'Çok yaygın bir parola',
      Weakness.containsCommonWord => 'Yaygın bir sözcük içeriyor',
      Weakness.keyboardPattern => 'Klavye deseni içeriyor',
      Weakness.repeats => 'Tekrarlar içeriyor',
      Weakness.sequence => 'Ardışık karakterler içeriyor',
      Weakness.date => 'Tarih benzeri bir bölüm içeriyor',
      Weakness.lowVariety => 'Karakter çeşitliliği düşük',
      Weakness.userInput => 'Tahmin edilebilir kişisel bilgi',
    };
