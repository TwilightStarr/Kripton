// Değişiklik (Görev 2/10): yeni dosya. Gerçek commit geçmişiyle, yalnızca "kripton/" dallarında çalışan
// GitHub depo katmanı. Varsayılan dala asla doğrudan yazılmaz; force güncelleme yoktur.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'github_ci.dart';
import 'project_snapshot.dart';
import 'secret_mask.dart';

/// AI'ın yazabildiği tüm dalların ön eki.
const String kWorkBranchPrefix = 'kripton/';

/// [DevRepoClient.createWorkBranch] ile açılan dalların zorunlu ön eki.
const String kWorkBranchNamePrefix = 'kripton/dev-';

/// İş akışı klasörü; yazma yalnızca `allowWorkflowEdits: true` ile.
const String kWorkflowDir = '.github/workflows/';

const int kDefaultMaxFilesPerCommit = 200;
const int kDefaultMaxBytesPerCommit = 4 * 1024 * 1024;

/// Hata mesajlarına eklenen token izin ipucu.
const String kTokenPermissionHint = 'Fine-grained token için gereken izinler: Contents (Read/Write), '
    'Actions (Read/Write), Pull requests (Read/Write), Metadata (Read); .github/workflows dosyası '
    'değişecekse ayrıca Workflows (Read/Write). Classic token için: repo (+ workflow).';

/// Depo katmanının kendi hataları.
class DevRepoException implements Exception {
  const DevRepoException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Güvenlik değişmezlerinden birine aykırı istek (ağa hiçbir yazma gitmeden reddedilir).
class DevPolicyException extends DevRepoException {
  const DevPolicyException(super.message);
}

/// Dal ucu beklenen commit değil (başka biri/başka oturum ilerletmiş).
class DevConflictException extends DevRepoException {
  DevConflictException({required this.branch, required this.expectedSha, this.actualSha})
      : super('Sürüm çakışması: "$branch" dalının ucu beklenen commit ($expectedSha) değil'
            '${actualSha == null ? '' : ' (şu an: $actualSha)'}. Dalı yeniden yükleyip değişikliği yeniden uygula.');

  final String branch;
  final String expectedSha;
  final String? actualSha;
}

/// [DevRepoClient.verifyAccess] başarısızlık kodları.
enum RepoAccessCode { tokenGecersiz, depoBulunamadi, yazmaYetkisiYok, arsivlenmis, actionsKapali, hizSiniri }

class RepoAccessIssue {
  const RepoAccessIssue(this.code, this.message);

  final RepoAccessCode code;

  /// Türkçe, düzeltme ipucu içerir.
  final String message;

  @override
  String toString() => '${code.name}: $message';
}

class RepoAccessReport {
  const RepoAccessReport({
    required this.issues,
    this.warnings = const <String>[],
    this.login,
    this.scopes,
    this.isPrivate,
    this.archived,
    this.defaultBranch,
    this.canPush,
    this.actionsEnabled,
  });

  final List<RepoAccessIssue> issues;
  final List<String> warnings;
  final String? login;

  /// Classic token için `X-OAuth-Scopes`; fine-grained token'da null.
  final List<String>? scopes;
  final bool? isPrivate;
  final bool? archived;
  final String? defaultBranch;
  final bool? canPush;

  /// null = okunamadı (token'da Actions izni yok olabilir).
  final bool? actionsEnabled;

  bool get ok => issues.isEmpty;

  bool has(RepoAccessCode c) => issues.any((i) => i.code == c);

  String get summary => ok ? 'Erişim tamam.' : issues.map((i) => i.message).join('\n');
}

/// Çalışma dalı bilgisi.
class WorkBranch {
  const WorkBranch({
    required this.name,
    required this.headSha,
    required this.baseBranch,
    required this.baseSha,
    required this.resumed,
  });

  final String name;

  /// Dalın şu anki ucu (resume ise mevcut uç; yeni ise baseSha).
  final String headSha;
  final String baseBranch;
  final String baseSha;

  /// Dal zaten vardı ve kaldığı yerden devam ediliyor.
  final bool resumed;
}

class PullRequestInfo {
  const PullRequestInfo({
    required this.number,
    required this.htmlUrl,
    required this.state,
    required this.headRef,
    required this.baseRef,
    required this.headSha,
    this.existing = false,
  });

  final int number;
  final String htmlUrl;
  final String state;
  final String headRef;
  final String baseRef;
  final String headSha;

  /// Aynı dal için açık PR zaten vardı.
  final bool existing;
}

/// [DevRepoClient.loadSnapshot] sayaçları.
class RepoLoadStats {
  RepoLoadStats({required this.headSha, required this.treeSha});

  final String headSha;
  final String treeSha;
  int filesRead = 0;

  /// Metin olmayan uzantılı (ya da NUL baytlı) dosyalar.
  int skippedBinary = 0;

  /// [kMaxTextFileBytes] üstü dosyalar.
  int skippedTooLarge = 0;

  /// [kMaxProjectFiles] sınırını aşan dosyalar.
  int skippedOverLimit = 0;

  /// `.git`, `build`, `.dart_tool`... klasörleri.
  int skippedExcluded = 0;

  /// Sembolik bağ / alt modül.
  int skippedSpecial = 0;
  int blobsDownloaded = 0;
  int blobsFromCache = 0;

  /// Özyinelemeli ağaç kırpıldı; klasör klasör tamamlandı.
  bool truncatedTree = false;

  /// Aynı commit için önbellekten döndü.
  bool fromCache = false;

  RepoLoadStats _copy({required bool fromCache}) => RepoLoadStats(headSha: headSha, treeSha: treeSha)
    ..filesRead = filesRead
    ..skippedBinary = skippedBinary
    ..skippedTooLarge = skippedTooLarge
    ..skippedOverLimit = skippedOverLimit
    ..skippedExcluded = skippedExcluded
    ..skippedSpecial = skippedSpecial
    ..blobsDownloaded = 0
    ..blobsFromCache = 0
    ..truncatedTree = truncatedTree
    ..fromCache = fromCache;

  @override
  String toString() => 'RepoLoadStats(head=$headSha, okunan=$filesRead, ikili=$skippedBinary, '
      'büyük=$skippedTooLarge, sınırAşan=$skippedOverLimit, dışlanan=$skippedExcluded, '
      'özel=$skippedSpecial, indirilen=$blobsDownloaded, önbellek=$blobsFromCache, '
      'kırpıldı=$truncatedTree, önbellekten=$fromCache)';
}

class RepoLoadResult {
  const RepoLoadResult(this.snapshot, this.headSha, this.stats);

  final ProjectSnapshot snapshot;

  /// Anlık görüntünün alındığı commit; [DevRepoClient.commitChanges] için `expectedHeadSha`.
  final String headSha;
  final RepoLoadStats stats;
}

class _TreeFile {
  const _TreeFile(this.path, this.sha, this.size, this.mode);

  final String path;
  final String sha;
  final int size;
  final String mode;
}

class _Etag {
  const _Etag(this.etag, this.body);

  final String etag;
  final String body;
}

class _Change {
  const _Change(this.path, this.content);

  final String path;
  final String? content;
}

/// GitHub depo katmanı. Token ve depo [GithubCiConfig]'ten ([DevRepoClient.fromConfig]) gelir.
///
/// Değişmezler (kodda zorlanır): yazma yalnızca `kripton/` dallarına ve asla default_branch'e;
/// zorla (force) ref güncellemesi hiçbir yerde yok; `.github/workflows/` yazımı yalnızca `allowWorkflowEdits`;
/// yollar normalize edilir; tek committe dosya/bayt üst sınırı.
class DevRepoClient {
  DevRepoClient({
    required String repo,
    required String token,
    GithubHttpSender? send,
    this.allowWorkflowEdits = false,
    this.maxFilesPerCommit = kDefaultMaxFilesPerCommit,
    this.maxBytesPerCommit = kDefaultMaxBytesPerCommit,
    this.maxRetries = 3,
    this.maxRateLimitRetries = 3,
    this.maxRateLimitWait = const Duration(minutes: 10),
    this.blobConcurrency = 6,
    Future<void> Function(Duration)? sleep,
    bool Function()? cancelled,
    Future<void>? onCancel,
    DateTime Function()? now,
  })  : repo = repo.trim(),
        _token = token.trim(),
        _send = send ?? githubHttpSend,
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _cancelled = cancelled ?? (() => false),
        _onCancel = onCancel,
        _now = now ?? DateTime.now {
    SecretMask.register(_token);
  }

  factory DevRepoClient.fromConfig(
    GithubCiConfig cfg, {
    GithubHttpSender? send,
    bool allowWorkflowEdits = false,
    Future<void> Function(Duration)? sleep,
    bool Function()? cancelled,
    Future<void>? onCancel,
    DateTime Function()? now,
  }) =>
      DevRepoClient(
        repo: cfg.repo,
        token: cfg.token,
        send: send,
        allowWorkflowEdits: allowWorkflowEdits,
        sleep: sleep,
        cancelled: cancelled,
        onCancel: onCancel,
        now: now,
      );

  /// `sahip/depo`.
  final String repo;
  final bool allowWorkflowEdits;
  final int maxFilesPerCommit;
  final int maxBytesPerCommit;

  /// Ağ/5xx hatalarında en fazla yeniden deneme (üstel geri çekilme: 0,5 sn, 1 sn, 2 sn...).
  final int maxRetries;
  final int maxRateLimitRetries;

  /// Bundan uzun hız sınırı beklemesi yapılmaz; [CiHttpException] (retryAfter dolu) fırlatılır.
  final Duration maxRateLimitWait;
  final int blobConcurrency;

  final String _token;
  final GithubHttpSender _send;
  final Future<void> Function(Duration) _sleep;
  final bool Function() _cancelled;
  final Future<void>? _onCancel;
  final DateTime Function() _now;

  static final RegExp _repoRe = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');
  static final RegExp _branchRe = RegExp(r'^[A-Za-z0-9_./-]+$');
  static final RegExp _shaRe = RegExp(r'^[0-9a-f]{40}$');
  static const Set<String> _skipDirs = <String>{'.git', '.dart_tool', 'build', '.idea', '.gradle', 'node_modules'};
  static const int _maxTreeDirs = 3000;
  static const int _maxCachedBodyChars = 256 * 1024;
  static const int _blobCacheLimitBytes = 24 * 1024 * 1024;

  String? _defaultBranchCache;
  int? _rlRemaining;
  DateTime? _rlReset;
  final Map<String, _Etag> _etags = <String, _Etag>{};
  final Map<String, String> _blobCache = <String, String>{};
  int _blobCacheBytes = 0;
  final Set<String> _skippedBlobs = <String>{};
  final Map<String, RepoLoadResult> _snapCache = <String, RepoLoadResult>{};

  // ---------------------------------------------------------------- yol / dal kuralları

  /// Depo içi yolu doğrular. `..`, `.`, boş parça, mutlak yol, `\`, sürücü harfi, kontrol karakteri ve
  /// `.git` parçası reddedilir. Kabul edilen yol olduğu gibi döner.
  static String normalizePath(String raw) {
    if (raw.trim().isEmpty) throw const DevPolicyException('Boş dosya yolu.');
    if (raw != raw.trim()) throw DevPolicyException('Yolun başında/sonunda boşluk olamaz: "$raw".');
    if (raw.length > 400) throw const DevPolicyException('Dosya yolu çok uzun (en çok 400 karakter).');
    if (raw.contains('\\')) throw DevPolicyException('Ters eğik çizgi (\\) içeren yol reddedildi: "$raw".');
    if (raw.startsWith('/')) throw DevPolicyException('Mutlak yol reddedildi: "$raw".');
    if (RegExp(r'^[A-Za-z]:').hasMatch(raw)) throw DevPolicyException('Sürücü harfli yol reddedildi: "$raw".');
    if (raw.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
      throw DevPolicyException('Kontrol karakteri içeren yol reddedildi: "$raw".');
    }
    for (final seg in raw.split('/')) {
      if (seg.isEmpty || seg == '.' || seg == '..') {
        throw DevPolicyException('Geçersiz yol parçası ("$seg") reddedildi: "$raw".');
      }
      if (seg.toLowerCase() == '.git') throw DevPolicyException('.git içine yazılamaz: "$raw".');
    }
    return raw;
  }

  static bool _isWorkflowPath(String p) {
    final l = p.toLowerCase();
    return l == '.github/workflows' || l.startsWith(kWorkflowDir);
  }

  static void _checkBranchSyntax(String b) {
    final bad = b.isEmpty ||
        b != b.trim() ||
        !_branchRe.hasMatch(b) ||
        b.contains('..') ||
        b.contains('//') ||
        b.startsWith('/') ||
        b.endsWith('/') ||
        b.endsWith('.') ||
        b.split('/').any((s) => s.isEmpty || s.startsWith('.') || s.endsWith('.lock'));
    if (bad) throw DevPolicyException('Geçersiz dal adı: "$b".');
  }

  /// Yazılabilir dal adı biçimi (ağsız): `kripton/` ile başlamalı.
  static void _assertWorkBranchName(String b) {
    _checkBranchSyntax(b);
    if (!b.startsWith(kWorkBranchPrefix) || b.length == kWorkBranchPrefix.length) {
      throw DevPolicyException('Yazma yalnızca "$kWorkBranchPrefix" ile başlayan dallara yapılır: "$b".');
    }
  }

  Future<void> _assertWritableBranch(String b) async {
    _assertWorkBranchName(b);
    final def = await _defaultBranch(); // alınamazsa istisna: "kanıtlayamıyorsan yazma"
    if (b.toLowerCase() == def.toLowerCase()) {
      throw DevPolicyException('Varsayılan dala ("$def") yazılamaz.');
    }
  }

  static void _assertSha(String sha, String what) {
    if (!_shaRe.hasMatch(sha)) throw DevPolicyException('$what geçerli bir 40 haneli commit SHA değil.');
  }

  static String _redactMessage(String s, {int max = 4000}) {
    final r = SecretMask.redact(s.trim());
    return r.length > max ? r.substring(0, max) : r;
  }

  // ---------------------------------------------------------------- HTTP

  Uri _api(String path, [Map<String, String>? query]) =>
      Uri.https('api.github.com', '/repos/$repo$path', query);

  Uri _root(String path) => Uri.https('api.github.com', path);

  void _checkCancelled() {
    if (_cancelled()) throw const CiCancelledException();
  }

  /// İptal edilebilir bekleme.
  Future<void> _wait(Duration d) async {
    _checkCancelled();
    final oc = _onCancel;
    await Future.any<void>(<Future<void>>[_sleep(d), if (oc != null) oc]);
    _checkCancelled();
  }

  Duration _backoff(int attempt) {
    final ms = 500 * (1 << attempt);
    return Duration(milliseconds: ms > 8000 ? 8000 : ms);
  }

  void _trackRate(GithubHttpResponse r) {
    final rem = int.tryParse(r.header('x-ratelimit-remaining') ?? '');
    final reset = int.tryParse(r.header('x-ratelimit-reset') ?? '');
    if (rem != null) _rlRemaining = rem;
    if (reset != null) _rlReset = DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true);
  }

  Future<void> _waitForRateWindow() async {
    final rem = _rlRemaining;
    final reset = _rlReset;
    if (rem == null || reset == null || rem > 0) return;
    final left = reset.difference(_now());
    if (left <= Duration.zero) {
      _rlRemaining = null;
      return;
    }
    final w = left + const Duration(seconds: 1);
    if (w > maxRateLimitWait) {
      throw CiHttpException(429, 'GitHub hız sınırına ulaşıldı; sıfırlanmaya ${w.inMinutes} dk var.',
          retryAfter: w);
    }
    await _wait(w);
    _rlRemaining = null;
  }

  Duration? _rateWait(GithubHttpResponse r) {
    final d = githubRetryAfterFrom(
      status: r.status,
      retryAfter: r.header('retry-after'),
      remaining: r.header('x-ratelimit-remaining'),
      reset: r.header('x-ratelimit-reset'),
      now: _now(),
    );
    if (d != null) return d;
    if (r.status == 403 && r.body.toLowerCase().contains('rate limit')) return const Duration(minutes: 1);
    return null;
  }

  String _errMsg(GithubHttpResponse r) {
    var text = r.body;
    try {
      final v = jsonDecode(r.body);
      if (v is Map && v['message'] is String) text = v['message'] as String;
    } catch (_) {
      // gövde JSON değil: ham metin
    }
    return _redactMessage(text, max: 400);
  }

  /// Tek istek: hız sınırı, yeniden deneme, ETag, iptal. [okStatuses] içindeki 4xx kodları çağırana döner.
  Future<GithubHttpResponse> _request(
    String method,
    Uri uri, {
    Object? body,
    bool idempotent = true,
    Set<int> okStatuses = const <int>{},
  }) async {
    final isGet = method == 'GET';
    final bytes = body == null ? null : utf8.encode(jsonEncode(body));
    var transientTries = 0;
    var rateTries = 0;
    while (true) {
      _checkCancelled();
      await _waitForRateWindow();
      final headers = <String, String>{
        'authorization': 'Bearer $_token',
        'accept': 'application/vnd.github+json',
        'x-github-api-version': '2022-11-28',
        if (bytes != null) 'content-type': 'application/json',
      };
      final key = uri.toString();
      final cached = isGet ? _etags[key] : null;
      if (cached != null) headers['if-none-match'] = cached.etag;

      GithubHttpResponse? resp;
      Object? netErr;
      try {
        resp = await _send(GithubHttpRequest(method: method, uri: uri, headers: headers, body: bytes));
      } on TimeoutException catch (e) {
        netErr = e;
      } on SocketException catch (e) {
        netErr = e;
      } on HttpException catch (e) {
        netErr = e;
      } on TlsException catch (e) {
        netErr = e;
      }
      if (netErr != null) {
        if (idempotent && transientTries < maxRetries) {
          await _wait(_backoff(transientTries++));
          continue;
        }
        throw CiTransientException(_redactMessage('GitHub bağlantı hatası: $netErr'));
      }
      final r = resp!;
      _trackRate(r);

      if (r.status == 304 && cached != null) {
        return GithubHttpResponse(200, cached.body, headers: r.headers);
      }
      if (r.status < 400) {
        final et = r.header('etag');
        if (isGet && et != null && r.body.length <= _maxCachedBodyChars) {
          if (_etags.length >= 300) _etags.remove(_etags.keys.first);
          _etags[key] = _Etag(et, r.body);
        }
        return r;
      }
      if (r.status == 403 || r.status == 429) {
        final wait = _rateWait(r);
        if (wait != null) {
          if (rateTries < maxRateLimitRetries && wait <= maxRateLimitWait) {
            rateTries++;
            await _wait(wait);
            continue;
          }
          throw CiHttpException(r.status, _errMsg(r), retryAfter: wait);
        }
      }
      if (r.status >= 500) {
        if (idempotent && transientTries < maxRetries) {
          await _wait(_backoff(transientTries++));
          continue;
        }
        throw CiHttpException(r.status, _errMsg(r));
      }
      if (okStatuses.contains(r.status)) return r;
      throw CiHttpException(r.status, _errMsg(r));
    }
  }

  Map<String, dynamic> _asMap(String body, String what) {
    try {
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {
      // aşağıda hata
    }
    throw CiHttpException(502, '$what yanıtı beklenen biçimde değil.');
  }

  Future<Map<String, dynamic>> _getJson(String path, [Map<String, String>? query]) async {
    final r = await _request('GET', _api(path, query));
    return _asMap(r.body, path);
  }

  String _shaOf(Object? v, String what) {
    if (v is String && _shaRe.hasMatch(v)) return v;
    throw CiHttpException(502, '$what yanıtında geçerli sha yok.');
  }

  Future<String> _defaultBranch() async {
    final hit = _defaultBranchCache;
    if (hit != null) return hit;
    final j = await _getJson('');
    final d = j['default_branch'];
    if (d is! String || d.isEmpty) throw CiHttpException(502, 'Depo yanıtında default_branch yok.');
    return _defaultBranchCache = d;
  }

  /// Dalın uç commit'i; dal yoksa null.
  Future<String?> _refSha(String branch) async {
    final r = await _request('GET', _api('/git/ref/heads/$branch'), okStatuses: const {404});
    if (r.status == 404) return null;
    final j = _asMap(r.body, 'ref');
    final o = j['object'];
    return _shaOf(o is Map ? o['sha'] : null, 'ref');
  }

  Future<String> _commitTree(String commitSha) async {
    final j = await _getJson('/git/commits/$commitSha');
    final t = j['tree'];
    return _shaOf(t is Map ? t['sha'] : null, 'commit');
  }

  Future<String> _createTree(String baseTree, List<Map<String, Object?>> entries) async {
    final r = await _request('POST', _api('/git/trees'), body: {'base_tree': baseTree, 'tree': entries});
    return _shaOf(_asMap(r.body, 'tree')['sha'], 'tree');
  }

  Future<String> _createCommit(String message, String tree, List<String> parents) async {
    final r = await _request(
      'POST',
      _api('/git/commits'),
      body: {'message': message, 'tree': tree, 'parents': parents},
    );
    return _shaOf(_asMap(r.body, 'commit')['sha'], 'commit');
  }

  /// Ref'i hızlı-ileri günceller; `force` her zaman false. Fast-forward değilse çakışma.
  Future<void> _moveRef(String branch, String newSha, String expectedParent) async {
    final r = await _request(
      'PATCH',
      _api('/git/refs/heads/$branch'),
      body: {'sha': newSha, 'force': false},
      okStatuses: const {409, 422},
    );
    if (r.status == 409 || r.status == 422) {
      final actual = await _refSha(branch);
      if (actual != null && actual != expectedParent) {
        throw DevConflictException(branch: branch, expectedSha: expectedParent, actualSha: actual);
      }
      throw CiHttpException(r.status, _errMsg(r));
    }
  }

  // ---------------------------------------------------------------- verifyAccess

  static bool _isRateLimit(CiHttpException e) => e.status == 429 || (e.status == 403 && e.retryAfter != null);

  RepoAccessIssue _rateIssue(CiHttpException e) {
    final secs = e.retryAfter?.inSeconds;
    return RepoAccessIssue(
      RepoAccessCode.hizSiniri,
      'GitHub API hız sınırına ulaşıldı. ${secs == null ? 'Biraz bekleyip' : '~$secs sn sonra'} yeniden dene; '
      'sık yoklamayı azalt. Kimlik doğrulamalı istek sınırı saatte 5000\'dir.',
    );
  }

  /// Token, depo, yazma yetkisi ve Actions durumunu sınar. Bilinen sorunlar istisna değil, rapordaki
  /// [RepoAccessIssue]'dur. Ağ kopması [CiTransientException] olarak yükselir.
  Future<RepoAccessReport> verifyAccess() async {
    final issues = <RepoAccessIssue>[];
    final warnings = <String>[];
    if (_token.isEmpty) {
      return RepoAccessReport(issues: [
        const RepoAccessIssue(
          RepoAccessCode.tokenGecersiz,
          'GitHub token girilmemiş. Ayarlardan bir token ekle. $kTokenPermissionHint',
        ),
      ]);
    }
    if (!_repoRe.hasMatch(repo)) {
      return RepoAccessReport(issues: [
        RepoAccessIssue(
          RepoAccessCode.depoBulunamadi,
          'Depo adı "sahip/depo" biçiminde olmalı (şu an: "$repo"). Ayarlardaki depo adını düzelt.',
        ),
      ]);
    }

    String? login;
    List<String>? scopes;
    try {
      final r = await _request('GET', _root('/user'));
      final j = _asMap(r.body, '/user');
      login = j['login'] as String?;
      final raw = r.header('x-oauth-scopes');
      if (raw != null) scopes = raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    } on CiHttpException catch (e) {
      if (_isRateLimit(e)) return RepoAccessReport(issues: [_rateIssue(e)]);
      if (e.status == 401 || e.status == 403) {
        return RepoAccessReport(issues: [
          RepoAccessIssue(
            RepoAccessCode.tokenGecersiz,
            'GitHub token geçersiz, süresi dolmuş ya da iptal edilmiş (HTTP ${e.status}). '
            'GitHub > Settings > Developer settings bölümünden yeni bir token oluşturup Ayarlar\'a gir. '
            '$kTokenPermissionHint',
          ),
        ]);
      }
      rethrow;
    }

    Map<String, dynamic> info = const <String, dynamic>{};
    try {
      info = await _getJson('');
    } on CiHttpException catch (e) {
      if (_isRateLimit(e)) return RepoAccessReport(issues: [_rateIssue(e)], login: login, scopes: scopes);
      if (e.status == 404) {
        return RepoAccessReport(login: login, scopes: scopes, issues: [
          RepoAccessIssue(
            RepoAccessCode.depoBulunamadi,
            '"$repo" deposu bulunamadı ya da token bu depoya erişemiyor (özel depolarda GitHub 404 döner). '
            'Depo adını kontrol et; fine-grained token\'da bu depoyu "Repository access" listesine ekle ve '
            'Metadata (Read) iznini ver. $kTokenPermissionHint',
          ),
        ]);
      }
      if (e.status == 401 || e.status == 403) {
        return RepoAccessReport(login: login, scopes: scopes, issues: [
          RepoAccessIssue(
            RepoAccessCode.yazmaYetkisiYok,
            'Token "$repo" deposuna erişemiyor (HTTP ${e.status}). Kuruluş depolarında token\'ı SAML SSO için '
            'yetkilendir ve depoya erişim ver. $kTokenPermissionHint',
          ),
        ]);
      }
      rethrow;
    }

    final isPrivate = info['private'] as bool?;
    final archived = info['archived'] as bool?;
    final def = info['default_branch'] as String?;
    final perms = info['permissions'];
    final canPush = perms is Map ? perms['push'] == true : false;
    if (def != null && def.isNotEmpty) _defaultBranchCache = def;

    if (archived == true) {
      issues.add(const RepoAccessIssue(
        RepoAccessCode.arsivlenmis,
        'Depo arşivlenmiş (salt okunur). Depo Settings > General > "Unarchive this repository" ile arşivden '
        'çıkar ya da başka bir depo seç.',
      ));
    }
    if (!canPush) {
      issues.add(RepoAccessIssue(
        RepoAccessCode.yazmaYetkisiYok,
        'Token bu depoya yazamıyor. Hesabın depoda yazma (Write) rolü olmalı ve token\'da Contents (Read/Write) '
        'izni verilmeli. $kTokenPermissionHint',
      ));
    }

    bool? actionsEnabled;
    try {
      final a = await _getJson('/actions/permissions');
      final e = a['enabled'];
      if (e is bool) actionsEnabled = e;
      if (actionsEnabled == false) {
        issues.add(const RepoAccessIssue(
          RepoAccessCode.actionsKapali,
          'Depoda GitHub Actions kapalı. Depo Settings > Actions > General bölümünden "Allow all actions and '
          'reusable workflows" seçeneğini aç; token\'da Actions (Read/Write) izni de gerekir.',
        ));
      }
    } on CiHttpException catch (e) {
      if (_isRateLimit(e)) {
        issues.add(_rateIssue(e));
      } else if (e.status == 401 || e.status == 403 || e.status == 404) {
        warnings.add('Actions durumu okunamadı (HTTP ${e.status}); token\'da Actions (Read) izni ve depo yönetici '
            'yetkisi gerekebilir. Actions\'ın açık olduğundan emin ol.');
      } else {
        rethrow;
      }
    }

    if (scopes != null && allowWorkflowEdits && !scopes.contains('workflow')) {
      warnings.add('Classic token\'da "workflow" kapsamı yok; .github/workflows dosyaları yazılamaz.');
    }
    return RepoAccessReport(
      issues: issues,
      warnings: warnings,
      login: login,
      scopes: scopes,
      isPrivate: isPrivate,
      archived: archived,
      defaultBranch: def,
      canPush: canPush,
      actionsEnabled: actionsEnabled,
    );
  }

  // ---------------------------------------------------------------- dal

  String _stamp() {
    final t = _now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// [baseBranch] ucundan yeni çalışma dalı açar. [name] verilmezse `kripton/dev-<tarih-saat>`.
  /// Ad `kripton/dev-` ile başlamak zorundadır. Dal varsa devam edilir (`resumed: true`).
  Future<WorkBranch> createWorkBranch(String baseBranch, {String? name}) async {
    final base = baseBranch.trim();
    _checkBranchSyntax(base);
    final branch = name ?? '$kWorkBranchNamePrefix${_stamp()}';
    if (!branch.startsWith(kWorkBranchNamePrefix) || branch.length == kWorkBranchNamePrefix.length) {
      throw DevPolicyException('Çalışma dalı adı "$kWorkBranchNamePrefix" ile başlamalı: "$branch".');
    }
    if (branch == base) throw const DevPolicyException('Çalışma dalı ile temel dal aynı olamaz.');
    await _assertWritableBranch(branch);

    final baseSha = await _refSha(base);
    if (baseSha == null) throw DevRepoException('Temel dal bulunamadı: "$base".');
    final existing = await _refSha(branch);
    if (existing != null) {
      return WorkBranch(name: branch, headSha: existing, baseBranch: base, baseSha: baseSha, resumed: true);
    }
    final r = await _request(
      'POST',
      _api('/git/refs'),
      body: {'ref': 'refs/heads/$branch', 'sha': baseSha},
      okStatuses: const {422},
    );
    if (r.status == 422) {
      final again = await _refSha(branch); // yarış: başka biri az önce açmış olabilir
      if (again != null) {
        return WorkBranch(name: branch, headSha: again, baseBranch: base, baseSha: baseSha, resumed: true);
      }
      throw CiHttpException(422, _errMsg(r));
    }
    return WorkBranch(name: branch, headSha: baseSha, baseBranch: base, baseSha: baseSha, resumed: false);
  }

  // ---------------------------------------------------------------- okuma

  static String _extOf(String path) {
    final name = path.split('/').last;
    final i = name.lastIndexOf('.');
    if (i < 0) return name.startsWith('.') ? name.substring(1).toLowerCase() : '';
    return name.substring(i + 1).toLowerCase();
  }

  /// Dalın ucundaki projeyi okur (yalnızca metin dosyaları; ikili/büyük dosyalar atlanıp sayılır).
  Future<ProjectSnapshot> loadSnapshot(String branch) async => (await loadSnapshotWithInfo(branch)).snapshot;

  /// [loadSnapshot] + uç commit SHA'sı ve sayaçlar.
  Future<RepoLoadResult> loadSnapshotWithInfo(String branch) async {
    _checkBranchSyntax(branch);
    final head = await _refSha(branch);
    if (head == null) throw DevRepoException('Dal bulunamadı: "$branch".');
    final hit = _snapCache[head];
    if (hit != null) {
      final src = hit.snapshot;
      return RepoLoadResult(
        ProjectSnapshot(name: src.name, text: <String, String>{...src.text}),
        head,
        hit.stats._copy(fromCache: true),
      );
    }
    final treeSha = await _commitTree(head);
    final stats = RepoLoadStats(headSha: head, treeSha: treeSha);

    final files = await _listTree(treeSha, stats);
    files.sort((a, b) => a.path.compareTo(b.path));
    final toRead = <_TreeFile>[];
    for (final f in files) {
      if (f.mode == '120000') {
        stats.skippedSpecial++;
      } else if (!kProjectTextExt.contains(_extOf(f.path))) {
        stats.skippedBinary++;
      } else if (f.size > kMaxTextFileBytes) {
        stats.skippedTooLarge++;
      } else if (toRead.length >= kMaxProjectFiles) {
        stats.skippedOverLimit++;
      } else {
        toRead.add(f);
      }
    }

    final texts = <String, String>{};
    var next = 0;
    var failed = false;
    Future<void> worker() async {
      while (!failed) {
        final i = next++;
        if (i >= toRead.length) return;
        final f = toRead[i];
        try {
          final text = await _textOf(f, stats);
          if (text != null) texts[f.path] = text;
        } catch (_) {
          failed = true;
          rethrow;
        }
      }
    }

    await Future.wait(List<Future<void>>.generate(blobConcurrency < 1 ? 1 : blobConcurrency, (_) => worker()));
    stats.filesRead = texts.length;

    final snap = ProjectSnapshot(name: repo.split('/').last, text: texts);
    if (_snapCache.length >= 3) _snapCache.remove(_snapCache.keys.first);
    _snapCache[head] = RepoLoadResult(
      ProjectSnapshot(name: snap.name, text: <String, String>{...texts}),
      head,
      stats,
    );
    return RepoLoadResult(snap, head, stats);
  }

  /// Dosyanın metni (önbellek → indirme). İkili/büyükse null döner ve sayaç artar.
  Future<String?> _textOf(_TreeFile f, RepoLoadStats stats) async {
    if (_skippedBlobs.contains(f.sha)) {
      stats.skippedBinary++;
      return null;
    }
    final cached = _blobCache[f.sha];
    if (cached != null) {
      stats.blobsFromCache++;
      return cached;
    }
    final bytes = await _fetchBlob(f.sha);
    stats.blobsDownloaded++;
    if (bytes.length > kMaxTextFileBytes) {
      _skippedBlobs.add(f.sha);
      stats.skippedTooLarge++;
      return null;
    }
    if (bytes.contains(0)) {
      _skippedBlobs.add(f.sha);
      stats.skippedBinary++;
      return null;
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    _putBlobCache(f.sha, text);
    return text;
  }

  void _putBlobCache(String sha, String text) {
    if (_blobCacheBytes + text.length > _blobCacheLimitBytes) {
      _blobCache.clear();
      _blobCacheBytes = 0;
    }
    _blobCache[sha] = text;
    _blobCacheBytes += text.length;
  }

  Future<List<int>> _fetchBlob(String sha) async {
    final j = await _getJson('/git/blobs/$sha');
    final c = j['content'];
    if (c is! String) throw CiHttpException(502, 'blob yanıtında içerik yok.');
    if (j['encoding'] == 'base64') {
      try {
        return base64.decode(c.replaceAll(RegExp(r'\s'), ''));
      } on FormatException {
        throw CiHttpException(502, 'blob base64 çözülemedi.');
      }
    }
    return utf8.encode(c);
  }

  /// Ağaçtaki tüm dosyalar. `truncated` gelirse klasör klasör tamamlanır.
  Future<List<_TreeFile>> _listTree(String treeSha, RepoLoadStats stats) async {
    final j = await _getJson('/git/trees/$treeSha', {'recursive': '1'});
    if (j['truncated'] == true) {
      stats.truncatedTree = true;
      return _walkTree(treeSha, stats);
    }
    final tree = j['tree'];
    if (tree is! List) throw CiHttpException(502, 'ağaç yanıtında tree listesi yok.');
    final out = <_TreeFile>[];
    for (final e in tree) {
      if (e is! Map) continue;
      final type = e['type'];
      if (type == 'tree') continue;
      final path = e['path'];
      if (path is! String) continue;
      _collect(path, e, out, stats);
    }
    return out;
  }

  void _collect(String path, Map<dynamic, dynamic> e, List<_TreeFile> out, RepoLoadStats stats) {
    final segs = path.split('/');
    if (segs.any(_skipDirs.contains)) {
      stats.skippedExcluded++;
      return;
    }
    try {
      normalizePath(path);
    } on DevPolicyException {
      stats.skippedSpecial++;
      return;
    }
    final sha = e['sha'];
    if (e['type'] != 'blob' || sha is! String || !_shaRe.hasMatch(sha)) {
      stats.skippedSpecial++; // alt modül (commit) vb.
      return;
    }
    final size = e['size'];
    out.add(_TreeFile(path, sha, size is num ? size.toInt() : 0, (e['mode'] as String?) ?? '100644'));
  }

  Future<List<_TreeFile>> _walkTree(String rootSha, RepoLoadStats stats) async {
    final out = <_TreeFile>[];
    final queue = <MapEntry<String, String>>[MapEntry<String, String>('', rootSha)];
    var dirs = 0;
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      if (++dirs > _maxTreeDirs) {
        throw const DevPolicyException('Depo çok fazla klasör içeriyor; ağaç okunamadı.');
      }
      final j = await _getJson('/git/trees/${cur.value}');
      if (j['truncated'] == true) {
        throw DevPolicyException('Klasör çok büyük, okunamadı: "${cur.key}".');
      }
      final tree = j['tree'];
      if (tree is! List) throw CiHttpException(502, 'ağaç yanıtında tree listesi yok.');
      for (final e in tree) {
        if (e is! Map) continue;
        final name = e['path'];
        if (name is! String) continue;
        if (e['type'] == 'tree') {
          final sha = e['sha'];
          if (_skipDirs.contains(name)) {
            stats.skippedExcluded++;
          } else if (sha is String && _shaRe.hasMatch(sha)) {
            queue.add(MapEntry<String, String>('${cur.key}$name/', sha));
          }
        } else {
          _collect('${cur.key}$name', e, out, stats);
        }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- yazma

  List<_Change> _planChanges(Map<String, String?> changes) {
    if (changes.isEmpty) throw const DevPolicyException('Commit için değişiklik yok.');
    if (changes.length > maxFilesPerCommit) {
      throw DevPolicyException('Tek committe en çok $maxFilesPerCommit dosya değişebilir (istenen: ${changes.length}).');
    }
    final known = SecretMask.exportKnown();
    final seen = <String>{};
    final out = <_Change>[];
    var bytes = 0;
    changes.forEach((raw, content) {
      final p = normalizePath(raw);
      if (!seen.add(p)) throw DevPolicyException('Aynı yol birden çok kez verildi: "$p".');
      if (_isWorkflowPath(p) && !allowWorkflowEdits) {
        throw DevPolicyException('"$p" bir iş akışı dosyası; değiştirmek için allowWorkflowEdits açık olmalı '
            've token\'da Workflows (Read/Write) izni bulunmalı.');
      }
      if (content != null) {
        bytes += utf8.encode(content).length;
        for (final s in known) {
          if (content.contains(s)) {
            throw DevPolicyException('"$p" içeriğinde kayıtlı bir sır (token/API anahtarı) var; commit reddedildi.');
          }
        }
      }
      out.add(_Change(p, content));
    });
    if (bytes > maxBytesPerCommit) {
      throw DevPolicyException('Tek committe en çok $maxBytesPerCommit bayt yazılabilir (istenen: $bytes).');
    }
    return out;
  }

  /// [changes] (yol -> yeni içerik; null = sil) ile [branch] üzerine, ebeveyni [expectedHeadSha] olan YENİ
  /// bir commit atar ve yeni SHA'yı döner. Dal ucu [expectedHeadSha] değilse [DevConflictException].
  Future<String> commitChanges(
    String branch,
    String expectedHeadSha,
    Map<String, String?> changes,
    String message,
  ) async {
    _assertWorkBranchName(branch);
    _assertSha(expectedHeadSha, 'expectedHeadSha');
    final plan = _planChanges(changes);
    final msg = _redactMessage(message);
    if (msg.isEmpty) throw const DevPolicyException('Commit mesajı boş olamaz.');
    await _assertWritableBranch(branch);

    final head = await _refSha(branch);
    if (head == null) throw DevRepoException('Dal bulunamadı: "$branch".');
    if (head != expectedHeadSha) {
      throw DevConflictException(branch: branch, expectedSha: expectedHeadSha, actualSha: head);
    }
    final baseTree = await _commitTree(head);
    final entries = <Map<String, Object?>>[];
    for (final c in plan) {
      final mode = c.path.endsWith('.sh') ? '100755' : '100644';
      final content = c.content;
      if (content == null) {
        entries.add({'path': c.path, 'mode': '100644', 'type': 'blob', 'sha': null});
      } else if (content.isEmpty) {
        final r = await _request('POST', _api('/git/blobs'), body: {'content': '', 'encoding': 'base64'});
        final sha = _shaOf(_asMap(r.body, 'blob')['sha'], 'blob');
        entries.add({'path': c.path, 'mode': mode, 'type': 'blob', 'sha': sha});
      } else {
        entries.add({'path': c.path, 'mode': mode, 'type': 'blob', 'content': content});
      }
    }
    final tree = await _createTree(baseTree, entries);
    final newSha = await _createCommit(msg, tree, <String>[head]);
    await _moveRef(branch, newSha, head);
    return newSha;
  }

  /// [targetSha] commit'inin ağacıyla [branch] ucuna YENİ bir commit ekler (geçmiş silinmez, force yok).
  /// [targetSha] bu dalın geçmişinde olmalıdır. Ağaç zaten aynıysa commit atmadan mevcut ucu döner.
  Future<String> revertTo(String branch, String targetSha, String message, {String? expectedHeadSha}) async {
    _assertWorkBranchName(branch);
    _assertSha(targetSha, 'targetSha');
    if (expectedHeadSha != null) _assertSha(expectedHeadSha, 'expectedHeadSha');
    final msg = _redactMessage(message);
    if (msg.isEmpty) throw const DevPolicyException('Commit mesajı boş olamaz.');
    await _assertWritableBranch(branch);

    final head = await _refSha(branch);
    if (head == null) throw DevRepoException('Dal bulunamadı: "$branch".');
    if (expectedHeadSha != null && head != expectedHeadSha) {
      throw DevConflictException(branch: branch, expectedSha: expectedHeadSha, actualSha: head);
    }
    if (targetSha == head) return head;

    String targetTree;
    try {
      targetTree = await _commitTree(targetSha);
    } on CiHttpException catch (e) {
      if (e.status == 404 || e.status == 422) {
        throw DevPolicyException('Hedef commit bulunamadı: $targetSha.');
      }
      rethrow;
    }
    final headTree = await _commitTree(head);
    if (targetTree == headTree) return head;

    final cmp = await _request(
      'GET',
      _api('/compare/$targetSha...$head', {'per_page': '1'}),
      okStatuses: const {404},
    );
    final status = cmp.status == 404 ? '' : (_asMap(cmp.body, 'compare')['status'] as String? ?? '');
    if (status != 'ahead' && status != 'identical') {
      throw DevPolicyException('Hedef commit ($targetSha) "$branch" dalının geçmişinde değil; geri dönülemez.');
    }
    final newSha = await _createCommit(msg, targetTree, <String>[head]);
    await _moveRef(branch, newSha, head);
    return newSha;
  }

  // ---------------------------------------------------------------- PR

  PullRequestInfo _pr(Map<String, dynamic> j, {bool existing = false}) {
    final head = j['head'];
    final base = j['base'];
    final n = j['number'];
    if (n is! num || head is! Map || base is! Map) throw CiHttpException(502, 'PR yanıtı beklenen biçimde değil.');
    return PullRequestInfo(
      number: n.toInt(),
      htmlUrl: (j['html_url'] as String?) ?? '',
      state: (j['state'] as String?) ?? 'open',
      headRef: (head['ref'] as String?) ?? '',
      baseRef: (base['ref'] as String?) ?? '',
      headSha: (head['sha'] as String?) ?? '',
      existing: existing,
    );
  }

  /// [head] (`kripton/...`) dalından [base]'e PR açar. Aynı dal için açık PR varsa onu döner.
  Future<PullRequestInfo> openPullRequest(
    String head,
    String base,
    String title,
    String body, {
    bool draft = false,
  }) async {
    _assertWorkBranchName(head);
    _checkBranchSyntax(base);
    if (head == base) throw const DevPolicyException('PR için baş ve temel dal aynı olamaz.');
    final t = _redactMessage(title, max: 250);
    if (t.isEmpty) throw const DevPolicyException('PR başlığı boş olamaz.');
    final r = await _request(
      'POST',
      _api('/pulls'),
      body: {'title': t, 'head': head, 'base': base, 'body': _redactMessage(body, max: 60000), 'draft': draft},
      idempotent: false,
      okStatuses: const {422},
    );
    if (r.status == 422) {
      final owner = repo.split('/').first;
      final list = await _request(
        'GET',
        _api('/pulls', {'head': '$owner:$head', 'base': base, 'state': 'open'}),
      );
      final v = jsonDecode(list.body);
      if (v is List && v.isNotEmpty && v.first is Map<String, dynamic>) {
        return _pr(v.first as Map<String, dynamic>, existing: true);
      }
      throw CiHttpException(422, _errMsg(r));
    }
    return _pr(_asMap(r.body, 'pulls'));
  }

  /// PR'ı birleştirir. YALNIZCA açıkça çağrılırsa: [confirmed] true, [expectedHeadSha] PR'ın şu anki ucu
  /// olmalı; baş dal bu depodaki bir `kripton/` dalı olmalı. Bu, varsayılan dalı değiştiren tek yoldur ve
  /// ref güncellemesi değil GitHub'ın PR birleştirmesidir (kullanıcı onayı gerektirir).
  Future<bool> mergePullRequest(
    int number, {
    required bool confirmed,
    required String expectedHeadSha,
    String method = 'merge',
  }) async {
    if (!confirmed) throw const DevPolicyException('PR birleştirme kullanıcı onayı olmadan yapılmaz.');
    _assertSha(expectedHeadSha, 'expectedHeadSha');
    if (method != 'merge' && method != 'squash' && method != 'rebase') {
      throw DevPolicyException('Geçersiz birleştirme yöntemi: "$method".');
    }
    final pr = await _getJson('/pulls/$number');
    final head = pr['head'];
    if (head is! Map) throw CiHttpException(502, 'PR yanıtı beklenen biçimde değil.');
    final ref = head['ref'];
    if (ref is! String || !ref.startsWith(kWorkBranchPrefix)) {
      throw DevPolicyException('Yalnızca "$kWorkBranchPrefix" dallarından gelen PR birleştirilir.');
    }
    final headRepo = head['repo'];
    final full = headRepo is Map ? headRepo['full_name'] : null;
    if (full is! String || full.toLowerCase() != repo.toLowerCase()) {
      throw const DevPolicyException('Başka depodan (fork) gelen PR birleştirilmez.');
    }
    if (pr['state'] != 'open' || pr['merged'] == true) {
      throw const DevPolicyException('PR açık değil ya da zaten birleştirilmiş.');
    }
    final actual = head['sha'];
    if (actual != expectedHeadSha) {
      throw DevConflictException(branch: ref, expectedSha: expectedHeadSha, actualSha: actual is String ? actual : null);
    }
    final r = await _request(
      'PUT',
      _api('/pulls/$number/merge'),
      body: {'sha': expectedHeadSha, 'merge_method': method},
      idempotent: false,
      okStatuses: const {405, 409},
    );
    if (r.status == 409) {
      throw DevConflictException(branch: ref, expectedSha: expectedHeadSha);
    }
    if (r.status == 405) throw DevPolicyException('PR şu an birleştirilemiyor: ${_errMsg(r)}');
    return _asMap(r.body, 'merge')['merged'] == true;
  }
}
