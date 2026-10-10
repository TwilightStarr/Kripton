// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../core/crypto/crypto_labels.dart';
import '../../core/crypto/hex.dart';
import '../../core/crypto/vault_keys.dart';
import '../../core/security/password_strength.dart';
import '../vault/domain/item_data.dart';
import '../vault/domain/vault_item.dart';
import 'two_factor_directory.dart';

enum AuditIssueType {
  commonPassword, // bundle edilmiş yaygın-parola Bloom filtresinde
  weakPassword,
  reusedPassword,
  oldPassword,
  missingTotp,
  emptyFields,
}

enum AuditSeverity { low, medium, high, critical }

class AuditIssue {
  const AuditIssue(this.itemId, this.type, this.severity, this.penalty,
      [this.detail = '']);
  final String itemId;
  final AuditIssueType type;
  final AuditSeverity severity;
  final int penalty; // 0..100
  /// Parola/sır İÇERMEZ (ör. "3 kayıtta aynı parola").
  final String detail;
}

class AuditReport {
  const AuditReport({
    required this.issues,
    required this.totalItems,
    required this.score,
    required this.generatedAt,
  });
  final List<AuditIssue> issues;
  final int totalItems;

  /// 0..100; 100 = sorunsuz.
  final int score;
  final DateTime generatedAt;

  List<AuditIssue> ofType(AuditIssueType t) =>
      [for (final i in issues) if (i.type == t) i];
  int count(AuditIssueType t) => ofType(t).length;
}

/// Parolayı bellekte tutmadan yeniden kullanım tespiti için HMAC parmak izi.
class PasswordFingerprinter {
  PasswordFingerprinter(this._keys);
  final VaultKeys _keys;

  Future<String> of(String password) async {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode('${CryptoLabels.auditReuse}\u0000$password'),
      secretKey: _keys.index.use((b) => SecretKeyData(b)),
    );
    return toHex(mac.bytes);
  }
}

/// Çevrimdışı güvenlik denetimi. İnternet YOK.
///
/// Sızıntı kontrolü yalnızca bundle edilmiş yaygın-parola listesinin (Bloom
/// filtreli [CommonPasswordList]) üyeliğidir. NOT (ileride): isteğe bağlı HIBP
/// k-anonymity (SHA-1 ilk 5 hex ön eki) eklenebilir; bu aşamada EKLENMEDİ.
///
/// Skor: kayıt cezası = sorunların cezalarının toplamı (en fazla 100);
/// skor = 100 - ortalama(kayıt cezası), tüm (çöp dışı) kayıtlar üzerinden.
/// Cezalar: yaygın 100, zayıf 70 (skor<=1) / 40 (skor 2), tekrar 50, eski 25,
/// 2FA yok 10, boş alan 15.
class SecurityAuditor {
  SecurityAuditor(this._estimator, {TwoFactorDirectory? twoFactor})
      : _twoFactor = twoFactor ?? const TwoFactorDirectory();

  final PasswordStrengthEstimator _estimator;
  final TwoFactorDirectory _twoFactor;

  static const Duration oldAfter = Duration(days: 365);

  Future<AuditReport> run({
    required Stream<VaultItem> items,
    required PasswordFingerprinter fingerprints,
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    final issues = <AuditIssue>[];
    final byFingerprint = <String, List<String>>{};
    var total = 0;

    await for (final item in items) {
      if (item.isTrashed) continue;
      total++;
      final id = item.id;

      final missing = item.missingRequired;
      if (missing.isNotEmpty) {
        issues.add(AuditIssue(id, AuditIssueType.emptyFields,
            AuditSeverity.low, 15, missing.join(',')));
      }

      final secret = item.data.primarySecret ?? '';
      final checkPassword = secret.isNotEmpty &&
          !(item.data is WifiData &&
              (item.data as WifiData).security == WifiSecurity.open);
      if (checkPassword) {
        final report = _estimator.estimate(secret, userInputs: [
          item.title,
          item.data.subtitle,
        ]);
        if (report.isCommon) {
          issues.add(AuditIssue(id, AuditIssueType.commonPassword,
              AuditSeverity.critical, 100, 'yaygın parola listesinde'));
        } else if (report.score < 3) {
          issues.add(AuditIssue(
              id,
              AuditIssueType.weakPassword,
              report.score <= 1 ? AuditSeverity.high : AuditSeverity.medium,
              report.score <= 1 ? 70 : 40,
              'skor ${report.score}/4'));
        }
        (byFingerprint[await fingerprints.of(secret)] ??= []).add(id);

        final changed = item.secretChangedAt ?? item.createdAt;
        if (t.difference(changed) > oldAfter) {
          issues.add(AuditIssue(id, AuditIssueType.oldPassword,
              AuditSeverity.low, 25, '${t.difference(changed).inDays} gün'));
        }
      }

      final data = item.data;
      if (data is LoginData &&
          !data.hasTotp &&
          data.urls.any(_twoFactor.supports)) {
        issues.add(AuditIssue(id, AuditIssueType.missingTotp,
            AuditSeverity.low, 10, 'site 2FA destekliyor'));
      }
      await Future<void>.delayed(Duration.zero); // UI isolate'ını boğma
    }

    for (final ids in byFingerprint.values) {
      if (ids.length < 2) continue;
      for (final id in ids) {
        issues.add(AuditIssue(id, AuditIssueType.reusedPassword,
            AuditSeverity.high, 50, '${ids.length} kayıtta aynı parola'));
      }
    }

    final perItem = <String, int>{};
    for (final i in issues) {
      perItem[i.itemId] = (perItem[i.itemId] ?? 0) + i.penalty;
    }
    final penalty = perItem.values.fold<int>(0, (a, b) => a + (b > 100 ? 100 : b));
    final score =
        total == 0 ? 100 : (100 - (penalty / total).round()).clamp(0, 100);
    return AuditReport(
        issues: issues, totalItems: total, score: score, generatedAt: t);
  }
}
