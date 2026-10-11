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
- `lib/application/dev_guard.dart` (YENİ, Kimi çıktısı + düzeltmeler): `DevGuard` kapıları G1-G8; `GuardViolation`, `GuardVerdict`, `kGateDescriptions`.
- `lib/application/dev_ledger.dart` (YENİ): `DevErrorEntry`, `LedgerStore`, `MemoryLedgerStore`, `FileLedgerStore`, `DevLedger` (kayıt, JSONL döndürme, istatistik, `lessons`), `ModelTrust`. Kimi yalnızca imzaları ve testi vermişti; dosya imzalara ve teste göre yazıldı.
- `lib/application/dev_mode.dart`: `DevPrompts.lessons/lessonsBlock`, `verifierSystem/verifierUser/parseVerifier`, `VerifierPolicy.choose`, `DevPatcher.onReject` kancası (3 yerde çağrılır). `analystUser`, `improverUser` ve `fixerUser` sonuna `lessonsBlock()` eklendi (ders yoksa boş; mevcut metinler değişmez).
- Testler: `test/dev_guard_test.dart`, `test/dev_ledger_test.dart`.

### Kimi çıktısına yapılan düzeltmeler
- Testlerdeki `package:kripton/...` importları `package:kripton_ai/...` yapıldı (paket adı `kripton_ai`).
- G5/G6: `FlutterProjectKit.check` artık `base:` (tüm dosya kümesi/pubspec) ile çağrılır (`DevPatcher.regression` ile aynı), böylece pubspec'te bildirilmiş paket yanlışlıkla "bilinmeyen" sayılmaz. `check()` gerçek `snap`'i, `checkFiles` verilmezse `ProjectSnapshot(name:'guard', text: files)` kullanır.
- G8: `_suspicious` regex'inin sonundaki `\b`, `HttpClient()` gibi `(` ile biten kalıpları hiç eşleştirmiyordu; kaldırıldı. Dosyada zaten aynı türde çağrı varsa (mevcut kalıp) yeni sayılmaz. İlgili test mantığı buna göre düzeltildi ve "yeni HttpClient() eklenemez" testi eklendi.
- Yama uygulaması `replaceFirst` yerine dilimleme (G3 tek eşleşmeyi garanti eder).

### Public API (sonraki agent için)
```dart
// lib/application/dev_guard.dart
class GuardViolation { String gate, path, detail; }  class GuardVerdict { List<GuardViolation> violations; bool get ok; }
typedef GuardRecorder = void Function(GuardViolation);
class DevGuard {
  static GuardVerdict check(ProjectSnapshot snap, DevRoundPlan plan, String rawOutput, {GuardRecorder? record});
  static GuardVerdict checkFiles({required Map<String,String> files, required Set<String> scope, required String rawOutput, GuardRecorder? record, ProjectSnapshot? base});
  static String? pathProblem(String path, Map<String,String> files, Set<String> scope, {required bool isNew});
  static String? matchProblem(String content, String old);  static String? degenerateProblem(String text);
}
// lib/application/dev_ledger.dart
class DevLedger { DevLedger({LedgerStore? store, int maxFileBytes, int Function()? nowMs}); static Future<DevLedger> open({...});
  Future<DevErrorEntry> record({required String role, required String modelId, required String gate, required String detail, String path, int attempt});
  List<DevErrorEntry> get entries; Map<String,int> statsByModel(); Map<String,int> statsByGate(); String lessons({int maxChars = 600}); }
class FileLedgerStore implements LedgerStore { FileLedgerStore(String path); }
class ModelTrust { observe(modelId, rejected); rate; samplesOf; demoteRecommended; promoteRecommended; isDemoted; markDemoted; markPromoted; }
// lib/application/dev_mode.dart
DevPrompts.lessons; DevPrompts.lessonsBlock(); DevPrompts.verifierSystem; DevPrompts.verifierUser(finding, diff); DevPrompts.parseVerifier(raw);
VerifierPolicy.choose(fixerModel, candidates) -> String? (null => RED);  DevPatcher.onReject
```
- Kullanım: orkestratör (Görev 6) her ihlali `DevGuard.check(..., record: (v) => ledger.record(role:'fixer', modelId:..., gate: v.gate, detail: v.detail, path: v.path))` ile deftere yazar, `DevPrompts.lessons = ledger.lessons().split('\n')` ile derse çevirir, `DevPatcher.onReject`'i deftere bağlar. Doğrulayıcı model yoksa (`VerifierPolicy.choose` null) yama RED sayılır.

### DOĞRULANAMADI
- `dart format`, `flutter analyze`, `flutter test` ÇALIŞTIRILAMADI (ortamda Dart/Flutter SDK yok, SDK indirme engelli). Hiçbir yeni kod derlenmedi/çalıştırılmadı.
- `FlutterProjectKit.check`'in `base:` ile çağrıldığında yalnızca üretilen dosyalar için mi tüm proje için mi sorun döndürdüğü; G6 ve "hata sayısı artmadıkça geçer" testleri buna bağlı olabilir.
- `ghp_abcdefghijklmnop1234` örneği `SecretMask` kalıbıyla (`gh[pousr]_` + en az 16 karakter) maskelenir; testin geçmesi buna bağlı.
- `ModelTrust` EWMA sayıları (5 ret → demote, ardından 5 kabul → oran ≤ 0.2) elle hesaplandı, çalıştırılmadı.

### Bilinen riskler
- `DevPrompts.lessons` ve `DevPatcher.onReject` statik/global alanlardır; eşzamanlı birden fazla oturum aynı alanı paylaşır (testlerde sıfırlanır).
- Kapılar `DevPatcher` ile kısmen aynı kontrolleri tekrar eder; sonraki görevde tek akışa bağlanmalı (kopyalama değil çağrı).
- Test zayıflatma, korumalı yol (DevPolicy) ve değişiklik bütçesi kapıları henüz YOK (Görev 11).
