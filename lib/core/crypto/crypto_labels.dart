// SPDX-License-Identifier: Apache-2.0
/// Tüm HKDF "info" / AAD alan-ayırma etiketleri. Hepsi benzersiz ve sürümlü.
abstract final class CryptoLabels {
  static const outer = 'quanta/v1/outer';
  static const inner = 'quanta/v1/inner';
  static const index = 'quanta/v1/index';
  static const backup = 'quanta/v1/backup';
  static const header = 'quanta/v1/header';
  static const kdfInput = 'quanta/v1/kdf-input';
  static const recoveryKek = 'quanta/v1/recovery-kek';
  static const wrapVmk = 'quanta/v1/wrap-vmk';
  static const wrapVmkRecovery = 'quanta/v1/wrap-vmk-recovery';
  static const record = 'quanta/v1/record';
  static const secretKeyCheck = 'quanta/v1/secretkey-check';

  // --- Aşama 2 (veri katmanı) ---
  /// VMK'dan türetilen SQLCipher anahtarı.
  static const db = 'quanta/v1/db';
  static const backupOuter = 'quanta/v1/backup-outer';
  static const backupMac = 'quanta/v1/backup-mac';
  static const backupFile = 'quanta/v1/backup-file';
  static const backupInner = 'quanta/v1/backup-inner';
  static const auditReuse = 'quanta/v1/audit-reuse';
  static const blindIndex = 'quanta/v1/blind-index';
}
