// Flutter modu: projeyi GitHub'a (özel bir dala) gönderir, Actions üzerinde GERÇEK
// `flutter pub get` / `flutter analyze` / `flutter test` / `flutter build apk` çalıştırır ve
// araç çıktısını AYNEN (kırpmadan) geri okur. Yeni paket gerekmez (dart:io HttpClient).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'project_snapshot.dart';
import 'storage.dart';

/// Kullanıcının GitHub ayarları (cihazda `github_ci.json` olarak saklanır).
class GithubCiConfig {
  GithubCiConfig._();

  static final GithubCiConfig instance = GithubCiConfig._();

  static const String fileName = 'github_ci.json';

  /// Kişisel erişim anahtarı (PAT): classic için `repo` + `workflow`; fine-grained için
  /// Contents: RW, Actions: R, Workflows: RW.
  String token = '';

  /// `sahip/depo` (depoda en az bir commit olmalı).
  String repo = '';

  /// Kontrol commit'lerinin yazıldığı dal (her seferinde sıfırdan yazılır; main'e dokunulmaz).
  String branch = 'kripton-ci';

  bool runTests = true;
  bool buildApk = true;

  static final RegExp _repoRe = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');
  static final RegExp _branchRe = RegExp(r'^[A-Za-z0-9_./-]+$');

  bool get usable =>
      token.trim().isNotEmpty && _repoRe.hasMatch(repo.trim()) && _branchRe.hasMatch(branch.trim());

  Future<void> load([Storage? storage]) async {
    try {
      final raw = await (storage ?? Storage()).loadJson(fileName);
      if (raw is! Map) return;
      token = (raw['token'] as String?) ?? '';
      repo = (raw['repo'] as String?) ?? '';
      final b = (raw['branch'] as String?)?.trim() ?? '';
      branch = b.isEmpty ? 'kripton-ci' : b;
      runTests = raw['runTests'] != false;
      buildApk = raw['buildApk'] != false;
    } catch (_) {
      // Bozuk dosya: varsayılanlarla devam.
    }
  }

  Future<void> save([Storage? storage]) async {
    try {
      await (storage ?? Storage()).saveJson(fileName, {
        'v': 1,
        'token': token.trim(),
        'repo': repo.trim(),
        'branch': branch.trim(),
        'runTests': runTests,
        'buildApk': buildApk,
      });
    } catch (_) {
      // Yazılamazsa ayarlar yalnızca bu oturumda geçerli olur.
    }
  }
}

/// Araç çıktısından ayrıştırılmış tek bir sorun. [raw] araç çıktısının AYNEN kendisidir.
class CiDiagnostic {
  const CiDiagnostic({
    required this.path,
    required this.line,
    required this.column,
    required this.severity,
    required this.message,
    required this.raw,
    this.code = '',
  });

  /// Proje içi göreli yol (`lib/main.dart`); bilinmiyorsa boş.
  final String path;
  final int line;
  final int column;

  /// `error` veya `warning`.
  final String severity;
  final String message;
  final String code;

  /// Araç çıktısı, değiştirilmeden (devam satırları dahil).
  final String raw;

  @override
  String toString() => '$severity $path:$line:$column $message';
}

/// Bir Actions denemesinin sonucu.
class CiResult {
  const CiResult({
    required this.ok,
    required this.stage,
    this.diagnostics = const [],
    this.stageLog = '',
    this.runUrl = '',
    this.infoCount = 0,
  });

  /// Tüm aşamalar (pub get, analyze, test, build) başarılı mı?
  final bool ok;

  /// Başarısız olan aşama (`analyze`, `build`, `pub-get`, `test`, `setup`...).
  final String stage;
  final List<CiDiagnostic> diagnostics;

  /// Başarısız aşamanın TAM çıktısı (kırpılmamış).
  final String stageLog;
  final String runUrl;

  /// `flutter analyze` çıktısındaki bilgi (info) satırı sayısı (düzeltmeye gönderilmez).
  final int infoCount;
}

class _StageLog {
  _StageLog(this.name);

  final String name;
  int? exitCode;
  final List<String> lines = [];

  String get text => lines.join('\n');
}

/// GitHub Actions iş günlüğünü ayrıştırır. Saf fonksiyonlardır (ağ yok); testlenebilir.
class CiLogParser {
  const CiLogParser._();

  static final RegExp _ts = RegExp(r'^\uFEFF?\d{4}-\d\d-\d\dT[\d:.]+Z ?');
  static final RegExp _ansi = RegExp('\u001B\\[[0-9;?]*[A-Za-z]');
  static final RegExp _begin = RegExp(r'^##KRIPTON-BEGIN:(\S+)\s*$');
  static final RegExp _end = RegExp(r'^##KRIPTON-END:(\S+):(\d+)\s*$');

  // "   error • The method 'x' isn't defined • lib/a.dart:12:5 • undefined_method"
  static final RegExp _analyze = RegExp(
    r'^\s*(error|warning|info)\s+\u2022\s+(.*)\s+\u2022\s+([^\s:]+):(\d+):(\d+)\s+\u2022\s+(\S+)\s*$',
  );

  // "lib/a.dart:12:5: Error: Undefined name 'x'."
  static final RegExp _compile = RegExp(
    r'^((?:lib|test|integration_test|bin|tool)/[^\s:]+\.dart):(\d+):(\d+): (Error|Warning)(?:: )?(.*)$',
  );

  static final RegExp _testFile = RegExp(r'(test/[A-Za-z0-9_./-]+_test\.dart)');
  static final RegExp _pkgFrame = RegExp(r'package:[A-Za-z0-9_]+/([A-Za-z0-9_./-]+\.dart):(\d+):(\d+)');

  /// Zaman damgası ve ANSI renk kodlarını atar; satır içeriğine dokunmaz.
  static String cleanLine(String line) {
    var s = line.replaceAll('\r', '');
    s = s.replaceFirst(_ts, '');
    s = s.replaceAll(_ansi, '');
    return s;
  }

  static List<_StageLog> _stages(String log) {
    final out = <_StageLog>[];
    _StageLog? cur;
    for (final rawLine in log.split('\n')) {
      final line = cleanLine(rawLine);
      final b = _begin.firstMatch(line);
      if (b != null) {
        cur = _StageLog(b.group(1)!);
        out.add(cur);
        continue;
      }
      final e = _end.firstMatch(line);
      if (e != null) {
        if (cur != null && cur.name == e.group(1)) {
          cur.exitCode = int.tryParse(e.group(2)!) ?? 1;
          cur = null;
        }
        continue;
      }
      cur?.lines.add(line);
    }
    return out;
  }

  /// [log]: iş günlüğünün tamamı. Başarısız ilk aşama sonucu döner.
  static CiResult parseJobLog(String log, {String runUrl = ''}) {
    final stages = _stages(log);
    _StageLog? failed;
    for (final s in stages) {
      if (s.exitCode == null || s.exitCode != 0) {
        failed = s;
        break;
      }
    }
    if (failed == null) {
      // İşaretçi yok ya da hepsi başarılı ama iş başarısız: kurulum aşaması (checkout/Flutter kurulumu).
      return CiResult(
        ok: stages.isNotEmpty && stages.every((s) => s.exitCode == 0),
        stage: 'setup',
        stageLog: log,
        runUrl: runUrl,
      );
    }
    final text = failed.text;
    final parsed = parseStage(failed.name, failed.lines);
    return CiResult(
      ok: false,
      stage: failed.name,
      diagnostics: parsed.diagnostics,
      stageLog: text,
      runUrl: runUrl,
      infoCount: parsed.infoCount,
    );
  }

  /// Bir aşamanın satırlarından sorunları çıkarır.
  static ({List<CiDiagnostic> diagnostics, int infoCount}) parseStage(String stage, List<String> lines) {
    final out = <CiDiagnostic>[];
    final seen = <String>{};
    var infos = 0;

    void add(CiDiagnostic d) {
      final key = '${d.severity}|${d.path}|${d.line}|${d.column}|${d.message}';
      if (seen.add(key)) out.add(d);
    }

    if (stage == 'pub-get' || stage == 'create' || stage == 'prebuild') {
      final text = lines.join('\n').trim();
      if (stage == 'pub-get' && text.isNotEmpty) {
        add(CiDiagnostic(
          path: 'pubspec.yaml',
          line: 1,
          column: 1,
          severity: 'error',
          message: 'flutter pub get başarısız',
          raw: text,
        ));
      }
      return (diagnostics: out, infoCount: 0);
    }

    if (stage == 'test') {
      final text = lines.join('\n').trim();
      if (text.isEmpty) return (diagnostics: out, infoCount: 0);
      var path = '';
      var line = 1;
      final tf = _testFile.firstMatch(text);
      if (tf != null) {
        path = tf.group(1)!;
      } else {
        final pf = _pkgFrame.firstMatch(text);
        if (pf != null) {
          path = 'lib/${pf.group(1)}';
          line = int.tryParse(pf.group(2)!) ?? 1;
        }
      }
      if (path.isNotEmpty) {
        add(CiDiagnostic(
          path: path,
          line: line,
          column: 1,
          severity: 'error',
          message: 'flutter test başarısız',
          raw: text,
        ));
      }
      return (diagnostics: out, infoCount: 0);
    }

    // analyze + build
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final a = _analyze.firstMatch(l);
      if (a != null) {
        final sev = a.group(1)!;
        if (sev == 'info') {
          infos++;
          continue;
        }
        add(CiDiagnostic(
          path: a.group(3)!,
          line: int.tryParse(a.group(4)!) ?? 1,
          column: int.tryParse(a.group(5)!) ?? 1,
          severity: sev,
          message: a.group(2)!.trim(),
          code: a.group(6)!,
          raw: l.trimRight(),
        ));
        continue;
      }
      final c = _compile.firstMatch(l);
      if (c != null) {
        final buf = StringBuffer(l.trimRight());
        var j = i + 1;
        while (j < lines.length && lines[j].trim().isNotEmpty && _compile.firstMatch(lines[j]) == null) {
          buf.write('\n${lines[j].trimRight()}');
          j++;
        }
        i = j - 1;
        add(CiDiagnostic(
          path: c.group(1)!,
          line: int.tryParse(c.group(2)!) ?? 1,
          column: int.tryParse(c.group(3)!) ?? 1,
          severity: c.group(4) == 'Warning' ? 'warning' : 'error',
          message: c.group(5)!.trim(),
          raw: buf.toString(),
        ));
      }
    }
    return (diagnostics: out, infoCount: infos);
  }
}

/// GitHub API hatası.
class CiHttpException implements Exception {
  CiHttpException(this.status, this.message, {this.retryAfter});

  final int status;
  final String message;
  final Duration? retryAfter;

  /// Yeniden denemenin işe yaramayacağı hatalar (yanlış anahtar/depo/yetki).
  bool get permanent => status == 401 || status == 404 || status == 409 || (status == 403 && retryAfter == null);

  @override
  String toString() => 'GitHub HTTP $status: $message';
}

/// İptal edildi.
class CiCancelledException implements Exception {
  const CiCancelledException();
}

/// Actions çalışması başlamadı / iptal edildi gibi, yeniden denenebilir durumlar.
class CiTransientException implements Exception {
  CiTransientException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// GitHub Actions ile gerçek Flutter denetimi.
class GithubCi {
  GithubCi(this.cfg);

  final GithubCiConfig cfg;
  final Map<String, String> _blobCache = {};

  static const String workflowPath = '.github/workflows/kripton-flutter-check.yml';

  static final RegExp _scriptExt = RegExp(r'\.(sh)$');

  /// Actions iş akışı. İşaretçiler (`##KRIPTON-...`) günlükten aşama çıktısını ayırmak içindir.
  static String workflowYaml({required bool runTests, required bool buildApk}) =>
      _workflowTemplate
          .replaceAll('__TEST__', runTests ? '1' : '0')
          .replaceAll('__BUILD__', buildApk ? '1' : '0');

  static const String _workflowTemplate = r'''
name: Kripton Flutter Check
on:
  push:
  workflow_dispatch:
permissions:
  contents: read
env:
  FLUTTER_SUPPRESS_ANALYTICS: 'true'
  KRIPTON_TEST: '__TEST__'
  KRIPTON_BUILD: '__BUILD__'
jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - name: Kripton kontrol
        shell: bash
        run: |
          set +e
          stage() {
            local name="$1"; shift
            printf '##KRIPTON-%s:%s\n' BEGIN "$name"
            "$@" 2>&1
            local code=$?
            printf '\n##KRIPTON-%s:%s:%s\n' END "$name" "$code"
            return $code
          }
          # `flutter create` projede test/widget_test.dart yoksa MyApp'e bağlı varsayılan bir şablon
          # üretir; bizim projede MyApp olmadığından analyze "The name 'MyApp' isn't a class" ile düşer.
          # YALNIZCA bu varsayılan şablon silinir: dosya MyApp'e atıf yapmıyorsa ya da projede
          # `class MyApp` varsa (kullanıcının kendi testi) dokunulmaz. Dönüş: 0 = silindi, 1 = silinmedi.
          # "quiet" verilirse silinmediğinde bir şey yazmaz (analyze çıktısı kirlenmesin).
          prune_default_widget_test() {
            local f=test/widget_test.dart
            if [ ! -f "$f" ]; then
              [ "$1" = quiet ] || echo "[Kripton] $f yok; temizlenecek varsayılan test bulunmadı."
              return 1
            fi
            if ! grep -qw 'MyApp' "$f"; then
              [ "$1" = quiet ] || echo "[Kripton] $f MyApp'e atıf yapmıyor; dokunulmadı."
              return 1
            fi
            if grep -rqE 'class[[:space:]]+MyApp([^A-Za-z0-9_]|$)' lib 2>/dev/null; then
              [ "$1" = quiet ] || echo "[Kripton] $f korundu: projede MyApp sınıfı var."
              return 1
            fi
            rm -f "$f" || return 1
            echo "[Kripton] $f SİLİNDİ: flutter create varsayılan şablonu (MyApp'e bağlı) ve projede MyApp sınıfı yok."
            return 0
          }
          cleanup_default_test() {
            prune_default_widget_test
            return 0
          }
          # analyze düşerse ve neden o varsayılan test ise: dosyayı sil, analyze'ı BİR kez yeniden çalıştır.
          # İlk denemenin çıktısı satır başına ön ek konarak saklanır (ayrıştırıcı onu sorun saymaz).
          run_analyze() {
            local out code
            out=$(mktemp)
            flutter analyze --no-fatal-infos > "$out" 2>&1
            code=$?
            if [ "$code" -ne 0 ] && prune_default_widget_test quiet; then
              echo "[Kripton] analyze başarısız: hata varsayılan test/widget_test.dart dosyasındandı; dosya silindi, analyze bir kez yeniden çalıştırılıyor."
              sed 's/^/[ilk deneme] /' "$out"
              rm -f "$out"
              flutter analyze --no-fatal-infos 2>&1
              return $?
            fi
            cat "$out"
            rm -f "$out"
            return $code
          }
          if [ -f tool/ci_prebuild.sh ]; then stage prebuild bash tool/ci_prebuild.sh || exit 1; fi
          if [ ! -d android ]; then
            NAME=$(grep -m1 '^name:' pubspec.yaml | awk '{print $2}' | tr -d '\r')
            stage create flutter create --project-name "$NAME" --org com.kripton --platforms android . || exit 1
          fi
          stage cleanup cleanup_default_test
          stage pub-get flutter pub get || exit 1
          stage analyze run_analyze || exit 1
          if [ -d test ] && [ "$KRIPTON_TEST" = "1" ]; then stage test flutter test || exit 1; fi
          if [ "$KRIPTON_BUILD" = "1" ]; then stage build flutter build apk --debug || exit 1; fi
          exit 0
''';

  // ---- HTTP ----

  Uri _api(String path, [Map<String, String>? query]) =>
      Uri.https('api.github.com', '/repos/${cfg.repo.trim()}$path', query);

  Future<(int, String)> _request(
    String method,
    Uri uri, {
    Object? body,
    bool auth = true,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.openUrl(method, uri).timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, 'kripton-dev-mode');
      if (auth) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${cfg.token.trim()}');
        req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
        req.headers.set('X-GitHub-Api-Version', '2022-11-28');
      }
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final resp = await req.close().timeout(timeout);
      final bb = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(timeout)) {
        bb.add(chunk);
      }
      final text = utf8.decode(bb.takeBytes(), allowMalformed: true);
      if (resp.statusCode >= 400) {
        Duration? retry;
        final remaining = resp.headers.value('x-ratelimit-remaining');
        final reset = int.tryParse(resp.headers.value('x-ratelimit-reset') ?? '');
        final ra = int.tryParse(resp.headers.value('retry-after') ?? '');
        if (ra != null) {
          retry = Duration(seconds: ra < 5 ? 5 : ra);
        } else if (remaining == '0' && reset != null) {
          final secs = reset - DateTime.now().millisecondsSinceEpoch ~/ 1000;
          retry = Duration(seconds: secs < 5 ? 5 : (secs > 3600 ? 3600 : secs));
        } else if (resp.statusCode == 429) {
          retry = const Duration(minutes: 1);
        }
        throw CiHttpException(resp.statusCode, text, retryAfter: retry);
      }
      return (resp.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _json(String method, Uri uri, {Object? body}) async {
    final (_, text) = await _request(method, uri, body: body);
    final v = jsonDecode(text);
    return v is Map<String, dynamic> ? v : <String, dynamic>{};
  }

  Future<void> _sleep(Duration d, bool Function() cancelled, Future<void> onCancel) async {
    await Future.any<void>([Future<void>.delayed(d), onCancel]);
    if (cancelled()) throw const CiCancelledException();
  }

  // ---- Gönderim ----

  Future<String> _blob(List<int> bytes) async {
    final key = sha1.convert(bytes).toString();
    final hit = _blobCache[key];
    if (hit != null) return hit;
    final j = await _json(
      'POST',
      _api('/git/blobs'),
      body: {'content': base64Encode(bytes), 'encoding': 'base64'},
    );
    final sha = j['sha'] as String?;
    if (sha == null) throw CiHttpException(500, 'blob yanıtında sha yok');
    _blobCache[key] = sha;
    return sha;
  }

  /// [snap]'i tek (ebeveynsiz) commit olarak [GithubCiConfig.branch] dalına yazar; commit sha'sını döner.
  Future<String> push(ProjectSnapshot snap) async {
    final tree = <Map<String, Object?>>[];
    for (final e in snap.text.entries) {
      final p = e.key;
      if (p.startsWith('.github/workflows/')) continue; // yalnızca bizim iş akışımız çalışsın
      final mode = _scriptExt.hasMatch(p) ? '100755' : '100644';
      if (e.value.isEmpty) {
        tree.add({'path': p, 'mode': mode, 'type': 'blob', 'sha': await _blob(const <int>[])});
      } else {
        tree.add({'path': p, 'mode': mode, 'type': 'blob', 'content': e.value});
      }
    }
    for (final e in snap.binary.entries) {
      if (e.key.startsWith('.github/workflows/')) continue;
      tree.add({'path': e.key, 'mode': '100644', 'type': 'blob', 'sha': await _blob(e.value)});
    }
    tree.add({
      'path': workflowPath,
      'mode': '100644',
      'type': 'blob',
      'content': workflowYaml(runTests: cfg.runTests, buildApk: cfg.buildApk),
    });

    final t = await _json('POST', _api('/git/trees'), body: {'tree': tree});
    final treeSha = t['sha'] as String?;
    if (treeSha == null) throw CiHttpException(500, 'tree yanıtında sha yok');
    final c = await _json(
      'POST',
      _api('/git/commits'),
      body: {
        'message': 'Kripton Flutter kontrolü ${DateTime.now().toUtc().toIso8601String()}',
        'tree': treeSha,
        'parents': <String>[],
      },
    );
    final sha = c['sha'] as String?;
    if (sha == null) throw CiHttpException(500, 'commit yanıtında sha yok');
    final branch = cfg.branch.trim();
    try {
      await _json('PATCH', _api('/git/refs/heads/$branch'), body: {'sha': sha, 'force': true});
    } on CiHttpException catch (e) {
      if (e.status != 404 && e.status != 422) rethrow;
      await _json('POST', _api('/git/refs'), body: {'ref': 'refs/heads/$branch', 'sha': sha});
    }
    return sha;
  }

  // ---- Bekleme ve günlük ----

  Future<String> _text(Uri uri) async {
    // İş günlüğü imzalı bir adrese yönlenir; imzalı adrese Authorization başlığı GÖNDERİLMEZ.
    final (code, text) = await _requestRaw(uri);
    if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
      final loc = text; // _requestRaw yönlendirmede Location'ı döner
      final (c2, body) = await _request('GET', Uri.parse(loc), auth: false, timeout: const Duration(minutes: 3));
      if (c2 >= 400) throw CiHttpException(c2, body);
      return body;
    }
    return text;
  }

  Future<(int, String)> _requestRaw(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 90));
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, 'kripton-dev-mode');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${cfg.token.trim()}');
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set('X-GitHub-Api-Version', '2022-11-28');
      final resp = await req.close().timeout(const Duration(seconds: 90));
      if (resp.isRedirect || (resp.statusCode >= 300 && resp.statusCode < 400)) {
        final loc = resp.headers.value('location') ?? '';
        await resp.drain<void>();
        return (resp.statusCode, loc);
      }
      final bb = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        bb.add(chunk);
      }
      final text = utf8.decode(bb.takeBytes(), allowMalformed: true);
      if (resp.statusCode >= 400) throw CiHttpException(resp.statusCode, text);
      return (resp.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }

  /// [snap]'i gönderir, Actions çalışmasını bekler ve sonucu döner.
  /// Ağ/hata durumunda istisna fırlatır; çağıran bekleyip yeniden dener.
  Future<CiResult> check(
    ProjectSnapshot snap, {
    required bool Function() cancelled,
    required Future<void> onCancel,
    void Function(String status)? status,
    Duration maxWait = const Duration(minutes: 75),
  }) async {
    void say(String s) => status?.call(s);
    say('GitHub: proje yükleniyor (${snap.fileCount} dosya)…');
    final sha = await push(snap);
    if (cancelled()) throw const CiCancelledException();

    say('GitHub: Actions çalışması bekleniyor…');
    int? runId;
    var runUrl = '';
    final findUntil = DateTime.now().add(const Duration(minutes: 6));
    while (runId == null) {
      if (DateTime.now().isAfter(findUntil)) {
        throw CiTransientException(
          'Actions çalışması başlamadı. Depoda Actions açık mı ve token\'da "workflow" yetkisi var mı?',
        );
      }
      await _sleep(const Duration(seconds: 6), cancelled, onCancel);
      final j = await _json('GET', _api('/actions/runs', {'head_sha': sha, 'per_page': '10'}));
      final runs = j['workflow_runs'];
      if (runs is List) {
        for (final r in runs) {
          if (r is Map && r['head_sha'] == sha) {
            runId = (r['id'] as num).toInt();
            runUrl = (r['html_url'] as String?) ?? '';
            break;
          }
        }
      }
    }

    final started = DateTime.now();
    var poll = 10;
    String? conclusion;
    while (true) {
      if (DateTime.now().difference(started) > maxWait) {
        throw CiTransientException('Actions çalışması ${maxWait.inMinutes} dakikada bitmedi.');
      }
      final j = await _json('GET', _api('/actions/runs/$runId'));
      final st = j['status'] as String?;
      if (st == 'completed') {
        conclusion = j['conclusion'] as String?;
        break;
      }
      final el = DateTime.now().difference(started);
      say('GitHub: Actions çalışıyor (${el.inMinutes} dk ${el.inSeconds % 60} sn)…');
      await _sleep(Duration(seconds: poll), cancelled, onCancel);
      if (poll < 30) poll += 5;
    }
    if (conclusion == 'cancelled' || conclusion == 'skipped' || conclusion == 'stale') {
      throw CiTransientException('Actions çalışması $conclusion olarak bitti.');
    }
    if (conclusion == 'success') {
      return CiResult(ok: true, stage: 'done', runUrl: runUrl);
    }

    say('GitHub: hata günlüğü indiriliyor…');
    final jobsJson = await _json('GET', _api('/actions/runs/$runId/jobs', {'per_page': '30'}));
    final jobs = jobsJson['jobs'];
    int? jobId;
    if (jobs is List) {
      for (final j in jobs) {
        if (j is Map && j['conclusion'] != 'success' && j['conclusion'] != 'skipped') {
          jobId = (j['id'] as num).toInt();
          break;
        }
      }
      if (jobId == null && jobs.isNotEmpty && jobs.first is Map) {
        jobId = ((jobs.first as Map)['id'] as num).toInt();
      }
    }
    if (jobId == null) throw CiTransientException('Actions işi bulunamadı.');
    final log = await _text(_api('/actions/jobs/$jobId/logs'));
    return CiLogParser.parseJobLog(log, runUrl: runUrl);
  }
}
