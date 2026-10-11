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


## GÖREV 2/10: GitHub depo katmanı (DevRepoClient)

### Yapılanlar
- `lib/data/github_repo.dart` (YENİ): `DevRepoClient` — verifyAccess, createWorkBranch, loadSnapshot(+WithInfo), commitChanges (base_tree + parent, force:false), revertTo (yeni commit, geçmiş silinmez), openPullRequest, mergePullRequest (yalnızca onayla).
- `lib/data/github_ci.dart`: yalnızca EKLEME (silinen satır 0): `GithubHttpRequest`, `GithubHttpResponse`, `GithubHttpSender`, `githubHttpSend`, `githubRetryAfterFrom`. `GithubCi.push` ve geri kalanına dokunulmadı.
- `test/github_repo_test.dart` (YENİ): bellekte sahte GitHub (ref/commit/iç içe ağaç/blob/PR); gerçek ağ yok.
- Güvenlik değişmezleri kodda: yazma yalnızca `kripton/` dallarına ve default_branch'e asla (varsayılan dal `kripton/` ile başlasa bile); `force` yalnızca `false` gönderilir; `.github/workflows` yazımı `allowWorkflowEdits` olmadan reddedilir; `..`, mutlak yol, `\`, sürücü harfi, `.git`, kontrol karakteri reddedilir; tek committe en çok 200 dosya / 4 MB; commit içeriğinde kayıtlı sır varsa commit reddedilir; commit/PR metinleri `SecretMask.redact`'ten geçer; hata gövdeleri maskelenir.

### Public API (sonraki agent için)
```dart
// lib/data/github_repo.dart
const kWorkBranchPrefix = 'kripton/'; const kWorkBranchNamePrefix = 'kripton/dev-'; const kTokenPermissionHint;
class DevRepoException implements Exception { String message; }
class DevPolicyException extends DevRepoException {}           // güvenlik kuralı ihlali (ağa yazma gitmeden)
class DevConflictException extends DevRepoException { String branch, expectedSha; String? actualSha; }
enum RepoAccessCode { tokenGecersiz, depoBulunamadi, yazmaYetkisiYok, arsivlenmis, actionsKapali, hizSiniri }
class RepoAccessReport { List<RepoAccessIssue> issues; List<String> warnings; String? login; List<String>? scopes;
  bool? isPrivate, archived, canPush, actionsEnabled; String? defaultBranch; bool get ok; bool has(RepoAccessCode); String get summary; }
class RepoAccessIssue { RepoAccessCode code; String message; }
class WorkBranch { String name, headSha, baseBranch, baseSha; bool resumed; }
class RepoLoadResult { ProjectSnapshot snapshot; String headSha; RepoLoadStats stats; }
class RepoLoadStats { int filesRead, skippedBinary, skippedTooLarge, skippedOverLimit, skippedExcluded, skippedSpecial, blobsDownloaded, blobsFromCache; bool truncatedTree, fromCache; }
class PullRequestInfo { int number; String htmlUrl, state, headRef, baseRef, headSha; bool existing; }
class DevRepoClient {
  DevRepoClient({required String repo, required String token, GithubHttpSender? send, bool allowWorkflowEdits = false,
    int maxFilesPerCommit = 200, int maxBytesPerCommit = 4 MB, int maxRetries = 3, int maxRateLimitRetries = 3,
    Duration maxRateLimitWait = 10 dk, int blobConcurrency = 6, Future<void> Function(Duration)? sleep,
    bool Function()? cancelled, Future<void>? onCancel, DateTime Function()? now});
  factory DevRepoClient.fromConfig(GithubCiConfig cfg, {send, allowWorkflowEdits, sleep, cancelled, onCancel, now});
  static String normalizePath(String raw);                      // DevPolicyException fırlatır
  Future<RepoAccessReport> verifyAccess();
  Future<WorkBranch> createWorkBranch(String baseBranch, {String? name});
  Future<ProjectSnapshot> loadSnapshot(String branch);
  Future<RepoLoadResult> loadSnapshotWithInfo(String branch);   // headSha -> commitChanges.expectedHeadSha
  Future<String> commitChanges(String branch, String expectedHeadSha, Map<String,String?> changes, String message);
  Future<String> revertTo(String branch, String targetSha, String message, {String? expectedHeadSha});
  Future<PullRequestInfo> openPullRequest(String head, String base, String title, String body, {bool draft = false});
  Future<bool> mergePullRequest(int number, {required bool confirmed, required String expectedHeadSha, String method = 'merge'});
}
// lib/data/github_ci.dart
typedef GithubHttpSender = Future<GithubHttpResponse> Function(GithubHttpRequest request);
Future<GithubHttpResponse> githubHttpSend(GithubHttpRequest r); Duration? githubRetryAfterFrom({...});
```
- Kullanım: `loadSnapshotWithInfo` -> `headSha`; her `commitChanges` çağrısından dönen SHA bir sonrakinin `expectedHeadSha`'sıdır. `DevConflictException` gelirse dalı yeniden yükle.
- İstisnalar: ağ/5xx tükenince `CiTransientException`/`CiHttpException`; iptalde `CiCancelledException`; hız sınırı çok uzunsa `CiHttpException(retryAfter: dolu)`.

### DOĞRULANAMADI
- `dart format`, `flutter analyze`, `flutter test` ÇALIŞTIRILAMADI (ortamda Dart/Flutter SDK yok, ağ kapalı). Kod ve testler derlenmedi/çalıştırılmadı; yalnızca elle gözden geçirildi.
- Gerçek GitHub davranışı (sahte sunucu varsayımları): `git/ref/heads/{dal}` ETag/304, `compare/{a}...{b}` status değerleri (`ahead`/`identical`), `git/trees` `sha: null` ile silme, boş blob (`content:'' base64`), `/actions/permissions` yetki yanıtları, PR 422 "zaten var" ayrımı.
- Fine-grained token'da `permissions.push` alanının her zaman dolu geldiği varsayıldı (yoksa yazmaYetkisiYok raporlanır).

### Bilinen riskler
- `mergePullRequest` varsayılan dalı değiştirebilen TEK yoldur (ref güncellemesi değil, GitHub PR birleştirmesi); `confirmed: true` + güncel uç SHA + `kripton/` baş dal + aynı depo şartı vardır. Arayüz bunu yalnızca kullanıcı onayıyla çağırmalı.
- `loadSnapshot` ikili ve >400 KB dosyaları atlar; dönen `ProjectSnapshot.binary` boştur (ZIP dışa aktarımı ikilileri içermez).
- `.sh` dışındaki mevcut çalıştırılabilir dosyalar içerik değişince 100644 moduna düşer.
- `project_snapshot.dart`'taki `_skipDirs`/uzantı mantığı özel olduğundan `github_repo.dart` içinde kopyalandı (dosyaya dokunulmadı); biri değişirse diğeri de güncellenmeli.
- Yeniden deneme jitter'sizdir (deterministik: 0,5/1/2 sn). POST pulls/merge ağ hatasında yeniden denenmez (çift işlem riski).
- Commit içeriğinde yalnızca KAYITLI sırlar aranır (kalıp tabanlı arama kodda yanlış pozitif üretirdi).
- Kapsam dışı: `GithubCi.push` hâlâ force + ebeveynsiz commit kullanıyor (istendiği gibi dokunulmadı); sonraki görevde dev modu bu yoldan çıkarılmalı.
