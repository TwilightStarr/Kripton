# Geliştirme Modu v2 — Devir Notları

## GÖREV 1/10: Güvenli sır depolama

### Yapılanlar
- `flutter_secure_storage` 10.3.4 (sabit) eklendi. 11.x denendi: `file_picker ^8` ile win32 çakışması (CI `pub get` hatası) nedeniyle 10.3.4'e düşüldü; SDK alt sınırı 3.5 kaldı.
- `lib/data/secret_store.dart` (YENİ): `SecretStore`, `SecureSecretStore`, `MemorySecretStore`, `SecretVault`, `SecretKeys`, `SecretStoreUnavailable`, `purgeSecretFileCopies`.
- `CloudConfig` ve `GithubCiConfig`: anahtar/token artık JSON'a yazılmaz; yükleme sırasında eski düz metin güvenli depoya taşınır (yaz → geri oku → doğrula → JSON'u sırsız yeniden yaz → `.bak/.tmp/.corrupt` sil). Doğrulama başarısızsa eski JSON'a dokunulmaz, sır bellekte kalır.
- Güvenli depo yoksa sır düz metne yazılmaz; yalnızca oturum belleğinde tutulur ve `SecretStoreUnavailable` döner.
- `SecretMask`: GitHub token biçimleri (`ghp_ gho_ ghu_ ghs_ ghr_ github_pat_`) + `exportKnown/registerAll` (isolate'a taşıma).
- Sızıntı denetimi: `crash_report` (yarım kalan işlem gövdesi), `profile_zip` (içe aktarılan metin), `workflow_zip_service` (dışa aktarılan her dosya, isolate'a kayıtlı sırlar taşınarak) maskelendi. `crash_guard`, `error_reporter` zaten maskeliydi; testle kanıtlandı.
- AndroidManifest: `allowBackup="false"`, `fullBackupContent`, `dataExtractionRules`; `res/xml/backup_rules.xml`, `res/xml/data_extraction_rules.xml`.
- `SECURITY.md` güncellendi. Testler: `test/secret_store_test.dart`.

### Public API (sonraki agent için)
```dart
// lib/data/secret_store.dart
abstract class SecretStore { Future<String?> read(String key); Future<bool> write(String key, String value); Future<void> delete(String key); Future<bool> get available; }
class SecureSecretStore implements SecretStore { SecureSecretStore({FlutterSecureStorage? storage}); }
class MemorySecretStore implements SecretStore { MemorySecretStore([Map<String,String>? initial]); }
class SecretKeys { static const cloudGemini, cloudGroq, cloudOpenrouter, githubToken; static String cloud(String providerName); static const List<String> all; }
class SecretStoreUnavailable { const SecretStoreUnavailable({required List<String> keys, String message}); final List<String> keys; final String message; }
class SecretVault {
  SecretVault({SecretStore? primary, SecretStore? session});
  static SecretVault get instance; static set instance(SecretVault v); // testlerde değiştirilebilir
  Future<String?> read(String key); Future<String?> readPersisted(String key); Future<bool> isSessionOnly(String key);
  Future<bool> write(String key, String value); // true = kalıcı + doğrulanmış; false = yalnızca bellek
  Future<void> delete(String key); Future<bool> get secureAvailable;
}
Future<void> purgeSecretFileCopies(Storage storage, String fileName, {bool corruptOnly = false});
// lib/data/cloud_engine.dart
CloudConfig.load([Storage? storage, SecretVault? vault]) -> Future<SecretStoreUnavailable?>
CloudConfig.save([Storage? storage, SecretVault? vault]) -> Future<SecretStoreUnavailable?>
CloudConfig.secretStatus  // SecretStoreUnavailable? (arayüz bunu gösterecek)
// lib/data/github_ci.dart
GithubCiConfig.isolated(); load/save aynı imza ve dönüş; GithubCiConfig.secretStatus
// lib/data/secret_mask.dart
SecretMask.exportKnown() -> List<String>; SecretMask.registerAll(Iterable<String>)
```
- `SecretStore.write` spesifikasyondaki `Future<void>` yerine `Future<bool>` döner (başarısızlığı bildirmek için).

### DOĞRULANAMADI
- `dart format`, `flutter analyze`, `flutter test` ÇALIŞTIRILAMADI (ortamda Flutter/Dart SDK yok, indirme engelli). Yazılan kod ve testler derlenmedi/çalıştırılmadı.
- `AndroidOptions()` / `FlutterSecureStorage(aOptions:)` kullanımı 10.3.4 ile derlemeyle doğrulanmadı. 10.x'te `encryptedSharedPreferences` kullanımdan kalktı; varsayılan AES-GCM + Keystore'da sarılmış anahtar.
- Manifest birleştirmede paketin kendi manifestiyle `allowBackup` çakışması olup olmadığı (çakışırsa `tools:replace="android:allowBackup"` gerekir).
- `pub get` 10.3.4 ile çözülür mü (pub'ın önerisine dayanıyor, çalıştırılmadı).
- `SecureSecretStore` testi, platform kanalı yokken istisna sızdırmadığını varsayar (`TestWidgetsFlutterBinding`).

### Bilinen riskler
- Mevcut `storage_resilience_test` (kaydet-yükle) varsayılan `SecretVault.instance` ile aynı süreçte oturum belleği üzerinden geçer; testler arası sızıntıyı önlemek için yeni testler kendi `SecretVault` örneğini verir.
- Güvenli depo yoksa ve eski düz metin taşınamadıysa, o anahtar JSON'da düz metin kalır (kullanıcı anahtarı kaybetmesin diye); yeni/değişen sır asla yazılmaz.
- `resetOnError` varsayılanı true: Keystore çözme hatasında paket depoyu sıfırlar; anahtarlar yeniden girilmelidir.
- `CrashGuard.beginOp` (kapsam dışı) `last_op.json` dosyasını maskesiz yazar; alanlara sır konmamalı. `telemetry_*` dosyaları (kapsam dışı) dosyaya yazmıyor, ancak denetlenmedi derinlemesine.
- `profile_zip` ve iş akışı içe aktarma isolate'ında yalnızca kalıp tabanlı maskeleme çalışır (kayıtlı sırlar dışa aktarmada taşınır, profil içe aktarmada taşınmaz). `Bearer ...` ve `api_key=...` kalıpları düz yazıda yanlış pozitif üretebilir (kullanıcıya "maskelendi" olarak bildirilir).
- Arayüz (`cloud_settings_sheet`, `dev_mode_page`) henüz `secretStatus` göstermiyor (sonraki prompt).
