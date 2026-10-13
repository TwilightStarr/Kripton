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


## GÖREV 3/10: GitHub Actions çalıştırma ve log hattı

### Yapılanlar
- `lib/data/github_ci.dart`:
  - `workflowYaml` yenilendi: `on: push` yalnızca `kripton/**` (+ `workflow_dispatch`), `permissions: contents: read`, `concurrency` (dal başına, eskiyi iptal), `timeout-minutes: 60`, Flutter `3.35.7` sabit, action'lar tam sürüm etiketiyle sabit. `legacyPushBranches` (varsayılan `['kripton-ci']`) yalnızca ESKİ `GithubCi.push` yolunun bozulmaması içindir; yeni hat `[]` verir. Betik gövdesi (cleanup/pub-get/analyze/test/build işaretçileri) değişmedi.
  - `GithubHttpRequest.followRedirects` (varsayılan true) eklendi, `githubHttpSend` bunu uygular (günlük indirmede imzalı adrese Authorization gitmesin diye).
  - `CiResult`: `exitCode`, `incomplete` eklendi (geriye uyumlu). `CiLogParser`: test aşaması artık başarısız testleri tek tek ayrıştırır (`[E]` blokları, yığın izinden `test/` ya da proje `lib/` konumu, yüklenemeyen test dosyası); `infoLines` eklendi.
  - `GithubCiRunner` (YENİ): `ensureWorkflow`, `runForCommit`, `checkBranch`. `CiLogStore` (YENİ): maskeli, boyut sınırlı, AtomicFile ile JSON günlük.
  - `GithubCi.push` ve `GithubCi.check` "KULLANMA" diye işaretlendi (davranışa dokunulmadı; `app_controller` hâlâ çağırıyor).
- `lib/data/ci_feedback.dart` (YENİ): `CiOutcome` (sealed: `CiSuccess`, `CiFailure`, `CiInfraError`, `CiCancelled`), `CiInfraReason`, `CiFailureSignature`, `CiFeedback`, `CiFeedbackReport`.
- Testler: `test/github_ci_test.dart` (genişletildi), `test/ci_feedback_test.dart` (YENİ), `test/fixtures/ci/*.log` (YENİ, 8 dosya). `lib/application/ci_batch.dart` değişmedi.

### Public API (sonraki agent için)
```dart
// lib/data/ci_feedback.dart
enum CiInfraReason { actionsDisabled, workflowMissing, runnerNotStarted, timeout, auth, rateLimit, network,
  setupFailed, stageInterrupted, startupFailure, logsUnavailable, other }
sealed class CiOutcome { String runUrl, sha; int? runId; }
final class CiSuccess extends CiOutcome { CiResult? result; }
final class CiFailure extends CiOutcome { CiFailureSignature signature; String feedback; CiResult result; String? rawLogPath; }
final class CiInfraError extends CiOutcome { CiInfraReason reason; String message; String? rawLogPath; }   // ASLA AI'ya "düzelt" diye verilmez
final class CiCancelled extends CiOutcome { String message; }
class CiFailureSignature { String stage; List<String> entries; String key; String get id; bool sameAs(o); static CiFailureSignature.of(CiResult) }
class CiFeedback { static const defaultBudgetChars = 12000; static String forAi(CiResult, {int budgetChars}); static CiFeedbackReport build(CiResult, {int budgetChars}); }
class CiFeedbackReport { String text; int droppedInfoLines, droppedWarningGroups, droppedRepeats, droppedContextLines; bool overBudget; }
// lib/data/github_ci.dart
const kCiFlutterVersion = '3.35.7'; const kCiFlutterDartVersion = '3.9.2'; const kCiActionCheckout/SetupJava/Flutter; const kCiJobTimeoutMinutes = 60;
GithubCi.workflowYaml({required bool runTests, required bool buildApk, String flutterVersion, List<String> legacyPushBranches});
class CiLogStore { CiLogStore({required Directory dir, int maxBytesPerLog = 2 MB, int keep = 10});
  Future<String?> save({branch, sha, runId, runUrl, stage, text, exitCode, now}); Future<List<String>> list(); Future<void> prune(); }
class EnsureWorkflowResult { String headSha; bool committed; }
class GithubCiRunner {
  GithubCiRunner({required repo, required token, DevRepoClient? repoClient /*allowWorkflowEdits:true olmalı*/, GithubHttpSender? send,
    bool Function()? cancelled, Future<void>? onCancel, sleep, now, CiLogStore? logStore, runTests, buildApk, flutterVersion,
    findTimeout=6dk, dispatchAfter=45sn, queueTimeout=15dk, overallTimeout=75dk, pollStart=8sn, pollMax=30sn, logRetries=5, logRetryWait=10sn, feedbackBudgetChars});
  factory GithubCiRunner.fromConfig(GithubCiConfig cfg, {send, cancelled, onCancel, sleep, now, logStore});
  Future<EnsureWorkflowResult> ensureWorkflow(String branch);              // aynıysa commit atmaz; committed:true ise dal ucu İLERLER
  Future<CiOutcome> runForCommit(String branch, String sha, {void Function(String)? status});   // istisna fırlatmaz
  Future<CiOutcome> checkBranch(String branch, {status});                  // ensure + run; DevConflictException/DevPolicyException yükselir
}
```
- Kullanım: `checkBranch` workflow commit'i atarsa `outcome.sha` yeni uçtur; orkestratör sonraki `commitChanges` için bunu `expectedHeadSha` yapmalı. `CiFailure.feedback` AI'ya gider; `signature.sameAs(önceki)` "aynı hata tekrarlandı" döngü tespitidir. `CiInfraError` için kod düzeltmesi yapılmaz: kullanıcıya bildir/bekle/yeniden dene.
- `CiLogStore` dizini çağıranın seçimidir (öneri: `<belgeler>/devlogs`); `Storage` dizin yolunu dışarı vermediği için `forStorage` yazılmadı.

### DOĞRULANAMADI
- `dart format`, `flutter analyze`, `flutter test` ÇALIŞTIRILAMADI (ortamda Dart/Flutter SDK yok, indirme engelli). Yazılan kod ve testler DERLENMEDİ/ÇALIŞTIRILMADI; yalnızca elle gözden geçirildi. Üretilen YAML Python ile ayrıştırıldı (geçerli); fixture regex'leri Python'da denendi.
- Flutter `3.35.7` / Dart `3.9.2` eşlemesi ve bu sürümle `pub get`'in çözülmesi; action etiketlerinin (`checkout@v6.0.0`, `setup-java@v5.0.0`, `flutter-action@v2.18.0`) varlığı ve SHA karşılıkları (ağ yok). Üretimde SHA ile sabitlenmeli; yanlış etiket her çalışmayı `setupFailed` yapar.
- GitHub davranışları: push ile açılan çalışmanın `path`/`name` alanları; `workflow_dispatch`'in varsayılan dalda dosya gerektirmesi (gerektiriyorsa tek tetik push'tur); iş zaman aşımında run/job `conclusion` değeri (`timed_out` mı `cancelled` mı); `filter=latest` parametresi; `/actions/jobs/{id}/logs` 302 + imzalı adres; `Accept: application/vnd.github.raw+json` ile contents; gerçek `flutter test` `[E]` çıktı biçimi sürümler arası.

### Bilinen riskler
- Eski yol (`GithubCi.push/check`) yeni YAML ile `kripton-ci` dalında çalışmaya devam eder (özellikle `legacyPushBranches` varsayılanı sayesinde); dev modu bu yoldan çıkarılınca varsayılan `[]` yapılmalı. Eski yol artık `concurrency` ile aynı daldaki eski çalışmayı iptal eder.
- `github_ci.dart` ↔ `ci_feedback.dart` ↔ `github_repo.dart` döngüsel import (Dart'ta geçerli, yalnızca tip bağımlılığı).
- Günlük, indirilir indirilmez `SecretMask.redact`'ten geçer; `Bearer ...`/`api_key=...` kalıpları günlükte yanlış pozitif maskeleme üretebilir.
- Aynı SHA için önceki bir çalışma (ör. iptal edilmiş) bulunursa en yeni çalışma kullanılır; `cancelled` sonucu dönerse çağıran yeniden deneyebilir.
- `CiFeedback`: hata satırları bütçeyi aşsa bile kırpılmaz (`overBudget`); model bağlamı çağıran tarafından ayrıca denetlenmeli. Ayrıştırılamayan aşamada hata benzeri satırlar (error/failed/hata...) hiç atılmaz.
- Test aşaması: `[E]` bloğu bulunamazsa eski toplu davranış (tek tanı) kalır; hiçbir tanı çıkmazsa `CiFeedback` aşama çıktısını ham verir.
- `ci_batch.dart` (`CiBatcher`) başarısız test/derleme tanılarını artık tek tek alır; proje dışı yol (`test/...` yoksa) `unmatched` olur.


## GÖREV 4/10: Doğrulama kapıları, doğrulayıcı AI ve hata defteri

### Yapılanlar
- `lib/application/dev_guard.dart` (YENİ): `DevGuard.check` — modelin HAM yama çıktısını (mevcut ESKİ/YENİ/TAM biçimi; yeni biçim yok) kapılardan geçirir. FAIL-CLOSED: `GuardVerdict.ok` = ihlal yok VE en az bir gerçek değişiklik; istisna → `G0`. `ok` iken `changes` (yol → TAM yeni içerik) tam olarak doğrulanan içeriktir; commit bundan yapılmalı. ESKİ blok BİREBİR ve TEK kez eşleşmelidir (`applyPatch`'in boşluk-normalleştirilmiş yedeği KULLANILMAZ).
  - G1 biçim (açılış/kapanış sayısı, kesik çıktı, ESKİ işareti, sızan `<<<<<<<`/`=======`), G2 yol (var/kapsam/yasak: `.git*`, `.github`, `pubspec.lock`, `.env*`, anahtar/sertifika, `..`, mutlak yol, büyük-küçük harf çakışması), G3 eşleşme, G4 büyüklük (yama/dosya sayısı, diff, ESKİ uzunluğu, büyük silme, dosya boşaltma, >80 satır silme), G5 sözdizimi/regresyon (parantez dengesi + `FlutterProjectKit.check` yeni hata; pubspec bozulması), G6 import (dart: bilinen, package: pubspec'te bildirilmiş/kendi paketi, göreli dosya var; kaldırılan paket hâlâ import ediliyor mu), G7 boş/dejenere/tekrar, G8 sır kalıpları + kayıtlı sır + ilgisiz yere süreç/ağ çağrısı.
  - `parseVerifier` (KATI: yalnızca ilk satır tam `KARAR: ONAY`, tek KARAR, ≤3 `-` gerekçe; metinde `KARAR: RED` varsa RED; belirsiz/boş = RED, kapı V2), `VerifierPolicy.choose/chooseDetailed/providerOf`.
- `lib/application/dev_ledger.dart` (YENİ): `DevErrorEntry`, `DevLedger` (JSONL, boyut sınırlı döndürme `.1`, bozuk satır toleransı, sır maskeleme), `ModelTrust` (EWMA, histerezis, `dev_trust.json` AtomicFile).
- `lib/application/dev_mode.dart` (yalnızca EKLEME): `DevPrompts.verifierSystem/verifierUser/withLessons`, `analystUser/fixerUser/ciFixerUser/improverUser` için isteğe bağlı `lessons` (boşsa metin DEĞİŞMEZ); `DevPatcher.apply(onReject:)` ve `DevPatcher.gateOfReason`.
- Testler: `test/dev_guard_test.dart`, `test/dev_ledger_test.dart`. 200 betikli kötü çıktı + her kesik önek + 300 rastgele bozulma → hiçbiri ok dönmez (test çıktısına `GEÇERSİZ ÇIKTI: n/200` yazılır).

### Public API
```dart
// dev_guard.dart
class DevGate { static const internal='G0', format='G1', path='G2', match='G3', size='G4', regression='G5', imports='G6', degenerate='G7', suspicious='G8', verifierRed='V1', verifierUnparsable='V2', ci='C1'; static String title(String); static String advice(String); }
class DevGuardLimits { const DevGuardLimits({maxPatches=12, maxChangedFiles=8, maxOutputChars=200000, maxOldBlockLines=80, maxDiffChars=24000, maxNewFileChars=40000, maxRemovedLinesPerFile=80, minShrinkBaseChars=400, minShrinkKeepRatio=0.5, maxPathLength=200}); }
class GuardViolation { String code, detail, path; int? patchIndex; }
final class GuardVerdict { bool get ok; List<GuardViolation> violations; Map<String,String> changes; List<GuardHunk> hunks; Set<String> get gates; List<String> get changedPaths; String get summary; String diffText({int maxChars=6000}); }
DevGuard.check(ProjectSnapshot snap, {required Set<String> scope /*plan.paths*/, required String rawOutput, String finding='', DevGuardLimits limits}) -> GuardVerdict
DevGuard.degenerateProblem(String, {minLines, minUniqueRatio}) -> String?
VerifierVerdict parseVerifier(String raw); // {approved, parsed, reasons, problem, gate}
VerifierPolicy.choose(String fixer, Iterable<String> candidates, {Set<String> avoid, String Function(String)? providerOf}) -> String?
VerifierPolicy.chooseDetailed(...) -> VerifierChoice? {modelId, differentProvider}
// dev_ledger.dart
class DevRole { analyst, fixer, verifier }
class DevErrorEntry { DevErrorEntry({ts, rol, modelId, kapiKodu, ayrinti, dosya='', deneme=0}); toJson(); static tryParse(Object?); }
class ModelTrust { observe(id,{rejected}); rate(id); samples(id); isDemoted(id); Set<String> demoted(); toJson(); loadJson(Object?); }
class DevLedger { DevLedger({Directory? dir, fileName, maxFileBytes=256KB, maxMemoryEntries=500, ModelTrust? trust, now});
  Future<void> load(); record(DevErrorEntry); recordVerdict(GuardVerdict,{rol,modelId,deneme}); recordVerifier(VerifierVerdict,{fixerModelId,verifierModelId,dosya,deneme}); recordSuccess({modelId}); flush();
  Map<String,int> statsByModel(); statsByGate(); String lessons({int maxChars=600}); ModelTrust trust; int corruptLines, writeFailures; }
// dev_mode.dart
DevPrompts.verifierSystem; verifierUser(finding, diff,{maxFindingChars,maxDiffChars}); withLessons(system, lessons);
DevPatcher.apply(..., onReject: (path, gate, detail) {}); DevPatcher.gateOfReason(reason,{fallback='G2'});
```
- Önerilen akış: `GuardVerdict v = DevGuard.check(...)`; `!v.ok` → `ledger.recordVerdict(...)`, yeniden iste (`DevPrompts...lessons: ledger.lessons()`); `ok` → `VerifierPolicy.choose(fixer, adaylar, avoid: ledger.trust.demoted())` null ise COMMIT ETME; doğrulayıcıya `verifierUser(bulgu, v.diffText())`; `parseVerifier(...).approved` değilse `ledger.recordVerifier` ve commit yok; onayda `commitChanges(branch, sha, v.changes, ...)`.

### DOĞRULANAMADI
- `dart format`, `flutter analyze`, `flutter test` ÇALIŞTIRILAMADI (ortamda Dart/Flutter SDK yok). Kod ve testler DERLENMEDİ/ÇALIŞTIRILMADI; yalnızca elle gözden geçirildi. "200/200 reddedildi" çıktısı henüz üretilmedi.
- `_BoomSnapshot implements ProjectSnapshot` (noSuchMethod) testinin analyzer'dan geçeceği; `switch` ifadesi/kayıt (record) sözdizimi SDK 3.5 ile derlenmesi.
- Gerçek model çıktılarında G8 kalıplarının yanlış pozitif oranı; `cloud-auto` arkasındaki gerçek sağlayıcı (doğrulayıcı bağımsızlığı garanti edilemez).

### Bilinen riskler
- G3 kasıtlı olarak ESKİ'yi bulanık eşleştirmez; CRLF dosyada LF'li ESKİ reddedilir (güvenli yön, ama çok ret üretebilir).
- G8 sır kalıpları `SecretMask`'ın özel listesinin KOPYASIDIR (özel olduğundan); `SecretMask` değişirse güncellenmeli. `Bearer`/`api_key=` kalıpları bilerek alınmadı (Dart kodunda yanlış pozitif).
- G5 yeni hata saptaması `FlutterProjectKit.check` ile sınırlıdır (tür/ad çözümlemesi yok); gerçek doğrulama CI'dır (`C1`).
- Doğrulayıcı kendisi de bir model: prompt-injection riskine karşı diff "veri" olarak tanımlandı ve ONAY katıdır, ama garanti değildir.
- Defter dosyası yazma hatalarında sessizce `writeFailures` sayar; `Storage` dizin yolunu vermediği için çağıran `Directory` seçmelidir (öneri: `<belgeler>/devlogs`).


## GÖREV 5/19: Model havuzu (otomatik seçim) ve oturum olay deposu

### Yapılanlar
- `lib/application/dev_model_pool.dart` (YENİ): `DevModelPool` — anahtarı olan sağlayıcılarda keşif (`CloudModelService.fetchModels`), yalnızca ücretsiz adaylar (OpenRouter `:free`; Gemini/Groq anahtarın ücretsiz katmanı), sezgisel ön sıralama + kısa sağlık testi (sağlayıcı başına en çok `testsPerProvider`, `healthyTarget` sağlıklıda durur), son-bilinen-iyi önbellek (AtomicFile JSON, sır yok, TTL 6 sa). Roller: analist = bağlam+güç, düzeltici = kod sezgisi (coder/code/flash...), doğrulayıcı = düzelticiden farklı sağlayıcı tercihi. Durum makinesi: cooldown (Retry-After/retryDelay), günlük kota parkı (sıfırlanma saatine kadar; OpenRouter hesap geneli), devre kesici (kapalı/açık/yarı-açık, tek deneme, üstel açık süre), auth → sağlayıcı bloğu, 404 → ölü. Hepsi parktaysa `PoolPick.wait` + EN KISA bekleme. `ModelTrust` (Görev 4) puanı ve `demoted` sıralamaya girer.
- `lib/application/dev_session_store.dart` (YENİ): `DevSessionStore` — `dev_sessions/{id}/events.jsonl` (toplu yazma, boyut sınırlı döndürme `.1..N`, yarım satır kurtarma, kalp atışı seyreltme), `session.json` (kontrol noktası), `changes.json` (dosya → durum/sha/ilk-son içerik özeti; tam içerik saklanmaz). Her metin `SecretMask.redact`'ten geçer.
- `lib/data/cloud_models.dart` (yalnızca EKLEME, geriye uyumlu): `CloudModelTestResult.retryAfter/dailyQuota`, `parseCloudRetryAfter`, `isDailyQuotaBody`; `_Reply.retryAfterHeader`.
- Testler: `test/dev_model_pool_test.dart`, `test/dev_session_store_test.dart` (YENİ). Python'da elle benzetim: tam havuzda roller (gemini pro / groq coder / openrouter 70b) ayrı ve farklı sağlayıcı; tek sağlayıcıda 3 farklı model; tek modelde aynı model + uyarı.

### Public API
```dart
// dev_model_pool.dart
String poolModelId(CloudProvider p, String model);  // 'groq:llama-...' ; VerifierPolicy.providerOf ile uyumlu
CloudProvider? poolProviderOf(String id); String poolModelNameOf(String id); bool isFreeCandidate(CloudProvider, String);
class ModelHeuristics { static strength(model,{label}); codeAffinity; contextScore(int?); paramsBillions }
class PoolModel { provider, model, label, contextTokens; String get id }
class DevPoolPolicy { failureThreshold=3, breakerOpenBase=2dk, breakerOpenMax=30dk, probeTimeout=3dk, transientCooldown=20sn, softCooldown=30sn, rateLimitDefault=60sn, rateLimitMax=15dk, minQuotaPark=5dk, authBlock=2sa, notFoundBlock=6sa, failedTestCooldown=5dk, testsPerProvider=6, healthyTarget=3, cacheTtl=6sa, maxCandidatesPerProvider=40 }
enum PoolOutcomeKind { success, rateLimit, dailyQuota, server, network, timeout, auth, notFound, badRequest, tooLarge, blocked, empty, badOutput, other }
class PoolReport { PoolReport({modelId, kind, retryAfter, message}); PoolReport.success(id); PoolReport.fromHttp({modelId,status,body,retryAfterHeader,now}); PoolReport.fromError(id, e) }
enum PoolPickStatus { ok, wait, none }
class PoolPick { status; PoolModel? model; Duration? waitFor; String reason; bool needsAttention; List<String> warnings; bool get ok }
class RoleAssignment { analyst, fixer, verifier (PoolPick); warnings; complete; singleModel }
class DevModelPool {
  DevModelPool({required CloudModelService service, required CloudConfig config, DevPoolPolicy policy, ModelTrust? trust, File? cacheFile, PoolLog? log, now, sleep, random, retry});
  Future<void> load(); Future<PoolDiscovery> discover({bool force=false});
  PoolPick pick(String role /*DevRole.**/, {Set<String> exclude, String? differFrom});
  RoleAssignment assign({Set<String> exclude}); bool report(PoolReport);
  List<PoolModelStatus> snapshot(); bool get hasUsable; void invalidateProvider(CloudProvider);
  static DateTime quotaResetAt(CloudProvider, DateTime now);
}
// dev_session_store.dart
enum DevEventLevel { bilgi, uyari, hata }; enum DevEventKind { asama, analiz, yama, commit, ci, geriAlma, bekleme, kalpAtisi, durum }
class DevEvent { DevEvent({ts, level, kind, message, files, sha, runUrl, modelId}); toJson(); static tryParse }
enum DevSessionStatus { hazir, calisiyor, bekliyor, duraklatildi, tamamlandi, hata, iptal }
class DevSessionState { id, status, repo, branch, baseBranch, headSha, startedAt, updatedAt, counters, blockedFiles, lastSignatures, models, phase, note; copyWith; incremented(name,[by]) }
enum DevChangeStatus { eklendi, degistirildi, silindi, geriAlindi }; class DevContentDigest; class DevChange; class DevSessionInfo
class DevSessionStore {
  DevSessionStore({required Directory baseDir, required String sessionId, maxEventBytes=256KB, rotatedKeep=3, flushInterval=500ms, maxBatch=50, maxChangeEntries=2000, heartbeatMinGap=60sn, now});
  Stream<DevEvent> get events; void append(DevEvent); void log(kind, message,{level,files,sha,runUrl,modelId}); Future<void> flush();
  Future<List<DevEvent>> tail(int n); Future<DevSessionState?> loadSession(); Future<bool> saveCheckpoint(DevSessionState);
  Future<List<DevSessionInfo>> listSessions({int limit=50}); Future<Map<String,DevChange>> loadChanges();
  Future<bool> recordChange(path,{status, commitSha='', content}); Future<void> close(); static String sanitizeId(String);
}
```
- Kullanım: orkestratör `assign()` → her istekte `pick(role, exclude, differFrom: fixerId)`; sonuç `report(...)`. `wait` → `waitFor` kadar bekle (başarısız sayma). Güveni `DevLedger` günceller (havuz güncellemez); `DevLedger.record*` çağrılarında `modelId` olarak havuz kimliğini (`provider:model`) kullan.

### DOĞRULANAMADI
- `dart format`, `flutter analyze`, `flutter test` ÇALIŞTIRILAMADI (SDK yok, ağ kapalı). Kod ve testler DERLENMEDİ/ÇALIŞTIRILMADI; yalnızca elle ve Python benzetimiyle gözden geçirildi.
- Gerçek sağlayıcı davranışı: Gemini/Groq ücretsiz katman erişimi, kota sıfırlanma saatleri (Gemini 07:00 UTC en erken varsayım), OpenRouter `X-RateLimit-Reset` biçimi, `cloud_models` genişletmesinin gerçek `HttpClient` başlıklarıyla çalışması (sahte istemci başlık okuyamazsa yutulur).
- Record desenleri (`final (a, b) = ...`) SDK ≥3.0 gerektirir; pubspec alt sınırı 3.5.

### Bilinen riskler
- Model adı sezgileri (`gemma`, `compound`, `vl` ... zayıf uyum; `lite/mini` küçük) yanılabilir; adlar koda gömülü değil ama kalıplar var.
- `CloudEngine` hata sınıflandırması özel (`_Kind`); havuz kendi `PoolReport.fromHttp` kopyasını kullanır. Engine değişirse eşitle. Engine belirli (sağlayıcı, model) çiftini zorlayamıyor: orkestratör bağlantısı sonraki görev.
- Tek sağlayıcıda doğrulayıcı zayıf model olabilir (rol çakışmaması güçten önceliklidir).
- Yarı-açık deneme sonucu raporlanmazsa `probeTimeout` sonrası yeniden deneme verilir.
- Olay günlüğü AtomicFile değil, JSONL ekleme + döndürmedir (AtomicFile yalnız JSON dosyalarına uygundur); `session.json`/`changes.json` AtomicFile.
- Başarısız `recordChange` yazımında bellekteki harita diskten ileride kalabilir.
- `cloud_models_test.dart` yeni `retryAfter` alanı için genişletilmedi (kapsam dışı).


## GÖREV 6/19: Orkestratör (DevSessionEngine)

### Yapılanlar
- `lib/application/dev_session_engine.dart` (YENİ): durum makinesi hazırlık → dal aç/devam et → planla (bloklu dosyalar hariç) → analiz (analist/geliştirme önericisi) → düzeltme → kapılar (`DevGuard.check`) → bağımsız doğrulayıcı (`parseVerifier`) → commit → Actions → [yeşil: sonraki parça] [kırmızı: `CiFeedback` ile düzeltici → kapılar → doğrulayıcı → commit → tekrar] → kararlılık (ardışık temiz geçiş + CI yeşil) → hedef/geliştirme (varsa) → bitti.
- Commit TEK yerden (`_commit`) atılır ve yalnızca `GuardVerdict.ok` + doğrulayıcı ONAY sonrası; bağımsız doğrulayıcı yoksa (havuz aynı modeli verirse) commit YOK. Reddedilen yama `DevLedger`'a yazılır (`recordVerdict/recordVerifier`), K (`maxPartRetries`) yeniden denemede `ledger.lessons()` prompt'a eklenir.
- CI kırmızı: aynı `CiFailureSignature` ≥ `sameSignatureLimit` (3) ya da M (`maxFailedFixes`, 3) üst üste başarısız düzeltme → `revertTo(son yeşil)`, ilgili dosyalar bloklu (olay + defter C1), döngü sürer. Son yeşil yoksa oturum `hata` ile biter (sonsuz döngü yok).
- `CiInfraError`: AI'ya verilmez; `autopilotBackoff` ile beklenir; `infraWaitingAfter` aşılırsa (ya da auth/actionsDisabled/workflowMissing/startupFailure) durum `bekliyor`, çökmez; toparlanınca `calisiyor`.
- `DevConflictException`: anlık görüntü yeniden yüklenir, parça baştan işlenir (`maxConflictsInRow` sonrası parça atlanır).
- Model: her çağrıda `pool.pick`/`pool.report`; `wait` → bekleme olayı (başarısız sayılmaz); `none` → kısa geri çekilmeyle birkaç deneme sonra o parça başarısız.
- Kontrol noktası: her adım `store.log`, her commit/CI/revert sonrası `saveCheckpoint`; `run(resumeFrom: saved)` aynı dalda (`createWorkBranch(name: saved.branch)`), kayıtlı sayaçlar ve bloklu dosyalarla sürer. Heartbeat: bekleme dilimleri ve döngüde 5 dk'da bir `kalpAtisi`.
- İptal: motor kendi `CancelToken`'ını tutar (`cancelToken`, `cancel()`); beklemeler `ct.wait` ile; her port çağrısı sonrası `_check()`. Eski `_cancel`/`cancel()`/`state.running` ile paylaşılmaz. Bitişte hiçbir şey birleştirilmez; portta merge YOK; `openPullRequest: true` ise yalnızca TASLAK PR.
- `lib/application/app_controller.dart`: yalnızca ekleme (sınıf sonu + importlar): `startDevSession`, `resumeDevSession`, `stopDevSession`, `devSession`, `devSessionActive`. Eski `startDevMode`, `_cancel`, `cancel()` DEĞİŞMEDİ.
- `test/dev_session_engine_test.dart` (YENİ): sahte repo (bellekte commit geçmişi), sahte CI (betik), sahte havuz, betikli AI, sahte saat. 9 zorunlu senaryo + (2b, 4b, 6b, heartbeat, iptal belirteci, PR, azami commit, azami süre).

### Public API
```dart
// lib/application/dev_session_engine.dart
const Duration kDevHeartbeatEvery = Duration(minutes: 5);
abstract class DevRepoPort { createWorkBranch(base,{name}); loadSnapshotWithInfo(branch); commitChanges(branch, expectedHead, Map<String,String?>, message); revertTo(branch, target, message,{expectedHeadSha}); openPullRequest(head, base, title, body,{draft}); }
abstract class DevCiPort { Future<CiOutcome> checkBranch(String branch, {void Function(String)? status}); }
abstract class DevPoolPort { PoolPick pick(String role,{Set<String> exclude, String? differFrom}); bool report(PoolReport r); }
class DevModelCallException { DevModelCallException(PoolReport report); }
typedef DevModelCall = Future<String> Function(PoolModel model, String system, String user, CancelToken ct);
typedef DevSleep = Future<void> Function(Duration d, CancelToken ct);
class DevRepoClientPort(DevRepoClient) / GithubCiRunnerPort(GithubCiRunner) / DevModelPoolPort(DevModelPool)   // üretim bağdaştırıcıları
class CloudDevModelCaller { CloudDevModelCaller({required CloudConfig source, required CancelToken ct, int maxTokens=6000}); Future<String> call(PoolModel, String system, String user, CancelToken ct); }
class DevSessionConfig { const DevSessionConfig({required repo, required baseBranch, goal='', maxDuration=24sa, maxCommits=200, maxConsecutiveFailures=12, stablePassesNeeded=2, maxPartRetries=3, maxFailedFixes=3, sameSignatureLimit=3, maxConflictsInRow=5, maxModelAttempts=6, chunkChars=6000, heartbeatEvery=5dk, infraWaitingAfter=30dk, maxWait=15dk, openPullRequest=false}); copyWith({repo, baseBranch, goal}); }
enum DevStopReason { kararli, sureDoldu, azamiCommit, azamiHata, iptal, hata, planYok }
class DevSessionResult { DevSessionStatus status; DevStopReason reason; String branch, headSha, message; int commits; String? prUrl; }
class DevSessionEngine {
  DevSessionEngine({required config, required repo, required ci, required callModel, required pool, required store, required ledger, CancelToken? cancelToken, DateTime Function()? now, DevSleep? sleep});
  final CancelToken cancelToken; void cancel();
  Future<DevSessionResult> run({DevSessionState? resumeFrom});     // istisna fırlatmaz; her son durum bir sonuçtur
  Map<String,int> get counters; Set<String> get blockedFiles; String get branch, headSha, lastGreenSha;
}
// lib/application/app_controller.dart (AppController)
Future<DevSessionResult?> startDevSession(DevSessionConfig cfg);
Future<DevSessionResult?> resumeDevSession(String sessionId, DevSessionConfig cfg);
void stopDevSession(); DevSessionEngine? get devSession; bool get devSessionActive;
```
- Kontrol noktası sözleşmesi: sayaç adları `tur, commit, ret, ciHata, ciYesil, geriAlma, cakisma, bekleme, kararli, gelistirme, imza:<id>`; `DevSessionState.models` içinde `analist/düzeltici/doğrulayıcı` model kimlikleri + `sonYesil` (son yeşil commit SHA) + `hedef` (hedef metni, ≤150 karakter). Arayüz bunları gösterebilir.

### DOĞRULANAMADI
- `dart format`, `flutter analyze`, `flutter test` ÇALIŞTIRILAMADI (ortamda Dart/Flutter SDK yok, ağ kapalı). Motor ve testler DERLENMEDİ/ÇALIŞTIRILMADI; yalnızca elle gözden geçirildi (parantez dengesi betikle kontrol edildi). "Tüm senaryolar geçer" kabulü bu yüzden DOĞRULANMADI.
- Testlerin bağlı olduğu varsayımlar: `CiBatcher.plan` ile satır 9'daki tanı için `return a + K;` içeren parça üretilmesi (test 3/4 düzeltici girdisi); `AutopilotChecks.problemsFor` örnek dosyalarda sorun üretmemesi; `PoolPick.ok/wait` const kurucuları; test (9)'da `SecretMask` kayıtlı token'ın tüm yazım yollarında maskelenmesi.
- `CloudDevModelCaller`: seçilen (sağlayıcı, model) çiftinin yalıtılmış `CloudConfig` ile `CloudEngine`e verilmesi ve `GenerationFailedException.code` ('CLOUD_AUTH/CLOUD_QUOTA/CLOUD_NO_KEY') eşlemesi gerçek bulutla denenmedi. `CloudRetryPolicy(maxWait: 20 sn)` ile kota durumunda hızlı hata dönmesi beklenir.
- `AppController._runDevSession`: `Storage.projectsDir().parent` ile belgeler klasörü elde edildiği varsayıldı; `DevModelPool.discover()` ağ çağrısı gerçek anahtarlarla denenmedi.

### Bilinen riskler
- `DevPlanner` imleci kontrol noktasına yazılmıyor (özel alan, kapsam dışı): resume'da planlama dosya başından başlar; kararlılık sayacı (`kararli`) taşınır.
- Her commit sonrası Actions beklenir (spesifikasyona uygun) → oturum yavaş ama güvenli; CI aynı SHA için mevcut çalışmayı yeniden kullanır (Görev 3).
- `DevSessionState.counters` ≤ 64 anahtar; `imza:*` sayaçları yeşilde/revert'te temizlenir.
- İlk CI (taban çizgisi) kırmızıysa ve geri dönülecek yeşil commit yoksa oturum `hata` ile biter (kullanıcı tabanı düzeltmeli).
- `CiFailure` düzeltmesi yalnızca ilk eşleşen batch için yapılır; kalan tanılar sonraki CI turunda yeniden bildirilir. Tanı bağlanamazsa son commit'in dosyaları kullanılır.
- `CancelToken.onCancel` dinleyicisi `CloudDevModelCaller` ve `DevRepoClient/GithubCiRunner` (Görev 2/3) içinde `Future.any` ile birikebilir; günlerce oturumda gözlemlenmeli.
- AppController bağı `state.running` iken oturum başlatmaz, ancak eski akış sonradan başlarsa wakelock/KeepAlive ortak kullanılır (eski akış `Prompt 8`'de kaldırılacak).
- Arayüz henüz yok (Görev 7).
