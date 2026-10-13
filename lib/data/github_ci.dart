// Değişiklik (Görev 3/10): workflowYaml sabitlendi (push yalnızca kripton/**, concurrency, sabit Flutter/action sürümleri);
// GithubHttpRequest.followRedirects eklendi; CiResult'a exitCode/incomplete eklendi; CiLogParser test aşaması
// başarısız testleri tek tek ayrıştırır; yeni GithubCiRunner (ensureWorkflow + run bulma/yoklama/log indirme),
// CiLogStore (maskeli, boyut sınırlı ham log). push() ve GithubCi.check KULLANILMAYACAK (eski yol; davranışı değişmedi).
// Değişiklik (Görev 2/10): GithubHttpRequest/GithubHttpResponse/GithubHttpSender, githubHttpSend ve githubRetryAfterFrom paylaşıma eklendi (yalnızca ekleme; push() ve GithubCi'ye dokunulmadı).
// Flutter modu: projeyi GitHub'a (özel bir dala) gönderir, Actions üzerinde GERÇEK
// `flutter pub get` / `flutter analyze` / `flutter test` / `flutter build apk` çalıştırır ve
// araç çıktısını AYNEN (kırpmadan) geri okur. Yeni paket gerekmez (dart:io HttpClient).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as pth;

import 'atomic_file.dart';
import 'ci_feedback.dart';
import 'crash_guard.dart';
import 'github_repo.dart';
import 'project_snapshot.dart';
import 'secret_mask.dart';
import 'secret_store.dart';
import 'storage.dart';

/// Kullanıcının GitHub ayarları. Sır olmayan alanlar `github_ci.json` içinde, token güvenli depoda
/// ([SecretVault], anahtar adı `github.token`) saklanır.
class GithubCiConfig {
  GithubCiConfig._();

  /// Singleton olmayan, varsayılan değerli yeni örnek (testler ve yalıtılmış kullanım).
  GithubCiConfig.isolated();

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

  /// Güvenli depo kullanılamadığında doldurulur (arayüz gösterebilir); sorun yoksa null.
  SecretStoreUnavailable? secretStatus;

  /// Henüz güvenli depoya taşınamamış, eski JSON'da duran düz metin token.
  String _legacyPlain = '';

  /// Taşınamayan eski düz metin diskte kaldıysa: sonraki başarılı kayıtta `.bak`/`.corrupt` kopyaları silinir.
  bool _needsPurge = false;

  /// Ayarları yükler. Eski JSON'da düz metin token varsa güvenli depoya taşır: yaz → geri oku → aynı mı
  /// doğrula → ancak o zaman JSON'u sırsız yeniden yaz. Doğrulama başarısızsa eski JSON'a dokunulmaz ve
  /// token yalnızca oturum belleğinde tutulur. Güvenli depo kullanılamıyorsa [SecretStoreUnavailable] döner.
  Future<SecretStoreUnavailable?> load([Storage? storage, SecretVault? vault]) async {
    final st = storage ?? Storage();
    final v = vault ?? SecretVault.instance;
    var legacy = '';
    try {
      final raw = await st.loadJson(fileName);
      if (raw is Map) {
        final t = raw['token'];
        if (t is String && t.trim().isNotEmpty) {
          legacy = t.trim();
          SecretMask.register(legacy);
        }
        repo = (raw['repo'] as String?) ?? '';
        final b = (raw['branch'] as String?)?.trim() ?? '';
        branch = b.isEmpty ? 'kripton-ci' : b;
        runTests = raw['runTests'] != false;
        buildApk = raw['buildApk'] != false;
      }
    } catch (e, st2) {
      // Bozuk dosya: varsayılanlarla devam.
      CrashGuard.log('GitHub ayarları okunamadı', e, st2);
    }

    var failed = false;
    _legacyPlain = '';
    try {
      if (legacy.isEmpty) {
        token = ((await v.read(SecretKeys.githubToken)) ?? '').trim();
        if (token.isNotEmpty && await v.isSessionOnly(SecretKeys.githubToken)) failed = true;
      } else {
        final persisted = ((await v.readPersisted(SecretKeys.githubToken)) ?? '').trim();
        if (persisted.isNotEmpty) {
          // Zaten taşınmış; JSON'daki eski kopya (ör. .bak'tan dönen) yalnızca silinecek.
          token = ((await v.read(SecretKeys.githubToken)) ?? persisted).trim();
        } else {
          token = legacy;
          if (!await v.write(SecretKeys.githubToken, legacy)) {
            failed = true;
            _legacyPlain = legacy;
          }
        }
      }
    } catch (e, st2) {
      CrashGuard.log('GitHub token okunamadı', e, st2);
      failed = true;
      if (legacy.isNotEmpty) {
        token = legacy;
        _legacyPlain = legacy;
      }
    }
    SecretMask.register(token);

    if (legacy.isNotEmpty && _legacyPlain.isEmpty) {
      // Token güvenli depoda doğrulandı: JSON'u sırsız yeniden yaz, eski düz metin kopyaları sil.
      try {
        await _writeJson(st);
        await purgeSecretFileCopies(st, fileName);
      } catch (e, st2) {
        CrashGuard.log('GitHub ayarları sırsız yeniden yazılamadı', e, st2);
      }
    } else if (legacy.isEmpty) {
      await purgeSecretFileCopies(st, fileName, corruptOnly: true);
    }
    if (_legacyPlain.isNotEmpty) _needsPurge = true;
    secretStatus = failed ? const SecretStoreUnavailable(keys: [SecretKeys.githubToken]) : null;
    return secretStatus;
  }

  Future<void> _writeJson(Storage st) => st.saveJson(fileName, {
        'v': 2,
        // Yalnızca zaten diskte duran, taşınamamış ve değişmemiş eski token korunur (yeni düz metin yazılmaz).
        if (_legacyPlain.isNotEmpty && _legacyPlain == token.trim()) 'token': _legacyPlain,
        'repo': repo.trim(),
        'branch': branch.trim(),
        'runTests': runTests,
        'buildApk': buildApk,
      });

  /// Ayarları kaydeder: token güvenli depoya (yazıp doğrulayarak), geri kalanı JSON'a gider.
  /// Güvenli depo yazamazsa token yalnızca bellekte kalır ve [SecretStoreUnavailable] döner.
  Future<SecretStoreUnavailable?> save([Storage? storage, SecretVault? vault]) async {
    final st = storage ?? Storage();
    final v = vault ?? SecretVault.instance;
    final value = token.trim();
    SecretMask.register(value);
    var failed = false;
    try {
      if (value.isEmpty) {
        await v.delete(SecretKeys.githubToken);
        _legacyPlain = '';
      } else if (await v.write(SecretKeys.githubToken, value)) {
        _legacyPlain = '';
      } else {
        failed = true;
      }
    } catch (e, st2) {
      CrashGuard.log('GitHub token kaydedilemedi', e, st2);
      failed = true;
    }
    try {
      await _writeJson(st);
      if (_legacyPlain.isEmpty && _needsPurge) {
        await purgeSecretFileCopies(st, fileName);
        _needsPurge = false;
      }
    } catch (e, st2) {
      // Yazılamazsa ayarlar yalnızca bu oturumda geçerli olur.
      CrashGuard.log('GitHub ayarları yazılamadı', e, st2);
    }
    secretStatus = failed ? const SecretStoreUnavailable(keys: [SecretKeys.githubToken]) : null;
    return secretStatus;
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
    this.exitCode,
    this.incomplete = false,
  });

  /// Başarısız aşamanın çıkış kodu; aşama bitiş işaretçisi olmadan kesildiyse ([incomplete]) veya aşama
  /// bilinmiyorsa null.
  final int? exitCode;

  /// Aşama başladı ama `##KRIPTON-END` yazılmadı (runner kaybı, zaman aşımı, süreç öldürüldü): kod hatası DEĞİL,
  /// altyapı sorunudur.
  final bool incomplete;

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
      exitCode: failed.exitCode,
      incomplete: failed.exitCode == null,
    );
  }

  /// Aşama çıktısındaki `info` satırları (analyze), AYNEN. [parseStage] bunları sorun saymaz, yalnızca sayar.
  static List<String> infoLines(String stageLog) {
    final out = <String>[];
    for (final l in stageLog.split('\n')) {
      final a = _analyze.firstMatch(l);
      if (a != null && a.group(1) == 'info') out.add(l.trimRight());
    }
    return out;
  }

  // "00:02 +0 -1: test/a_test.dart: addition fails [E]"
  static final RegExp _testProgress = RegExp(r'^\d\d:\d\d(?::\d\d)? \+\d+(?: ~\d+)?(?: -\d+)?: (.*)$');
  static final RegExp _testStackFrame = RegExp(r'(?<![A-Za-z0-9_./-])(test/[A-Za-z0-9_./-]+\.dart)(?:\s+|:)(\d+):(\d+)');
  static final RegExp _pkgFrameAny = RegExp(r'package:([A-Za-z0-9_]+)/([A-Za-z0-9_./-]+\.dart)(?:\s+|:)(\d+):(\d+)');
  static const Set<String> _foreignPackages = <String>{
    'matcher',
    'flutter_test',
    'flutter',
    'test_api',
    'test_core',
    'test',
    'stack_trace',
    'async',
    'fake_async',
    'collection',
    'meta',
    'vector_math',
  };

  /// `flutter test` çıktısından başarısız testleri ([E] ile biten ilerleme satırı + devamı) tek tek çıkarır.
  /// Hiç [E] bloğu bulunamazsa boş döner (çağıran toplu davranışa düşer).
  static List<CiDiagnostic> _failedTests(List<String> lines) {
    final out = <CiDiagnostic>[];
    var i = 0;
    while (i < lines.length) {
      final m = _testProgress.firstMatch(lines[i]);
      if (m == null || !m.group(1)!.trimRight().endsWith('[E]')) {
        i++;
        continue;
      }
      var title = m.group(1)!.trimRight();
      title = title.substring(0, title.length - 3).trimRight();
      final block = <String>[lines[i].trimRight()];
      var j = i + 1;
      while (j < lines.length && _testProgress.firstMatch(lines[j]) == null) {
        block.add(lines[j].trimRight());
        j++;
      }
      i = j;
      while (block.length > 1 && block.last.trim().isEmpty) {
        block.removeLast();
      }
      final text = block.join('\n');
      var path = '';
      var line = 1;
      var col = 1;
      var message = 'test başarısız: $title';
      // 1) Test dosyası derlenemediyse ("loading ... [E]" + "test/a_test.dart:5:8: Error: ...").
      for (final l in block) {
        final c = _compile.firstMatch(l.trimLeft());
        if (c != null) {
          path = c.group(1)!;
          line = int.tryParse(c.group(2)!) ?? 1;
          col = int.tryParse(c.group(3)!) ?? 1;
          message = 'test dosyası yüklenemedi: ${c.group(5)!.trim()}';
          break;
        }
      }
      // 2) Yığın izindeki ilk test dosyası çerçevesi.
      if (path.isEmpty) {
        final tf = _testStackFrame.firstMatch(text);
        if (tf != null) {
          path = tf.group(1)!;
          line = int.tryParse(tf.group(2)!) ?? 1;
          col = int.tryParse(tf.group(3)!) ?? 1;
        }
      }
      // 3) Yığın izindeki ilk proje paketi çerçevesi (matcher/flutter_test vb. atlanır).
      if (path.isEmpty) {
        for (final f in _pkgFrameAny.allMatches(text)) {
          if (_foreignPackages.contains(f.group(1)!)) continue;
          path = 'lib/${f.group(2)}';
          line = int.tryParse(f.group(3)!) ?? 1;
          col = int.tryParse(f.group(4)!) ?? 1;
          break;
        }
      }
      // 4) Başlıktaki "test/x_test.dart: ..." / "loading test/x_test.dart".
      if (path.isEmpty) {
        final tf = _testFile.firstMatch(title);
        if (tf != null) path = tf.group(1)!;
      }
      out.add(CiDiagnostic(
        path: path,
        line: line,
        column: col,
        severity: 'error',
        message: message,
        raw: text,
      ));
    }
    return out;
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
      final failedTests = _failedTests(lines);
      if (failedTests.isNotEmpty) return (diagnostics: failedTests, infoCount: 0);
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

// ---- Paylaşılan HTTP yardımcıları (Görev 2/10: DevRepoClient burayı kullanır) ----

/// Ham HTTP isteği. Ağ katmanı testte sahte bir [GithubHttpSender] ile değiştirilebilir.
class GithubHttpRequest {
  const GithubHttpRequest({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.body,
    this.timeout = const Duration(seconds: 90),
    this.followRedirects = true,
  });

  /// false: 3xx yanıtı olduğu gibi (Location başlığıyla) döner. İş günlüğü indirmede imzalı adrese
  /// Authorization başlığı GÖNDERİLMESİN diye kullanılır (Görev 3/10).
  final bool followRedirects;

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int>? body;
  final Duration timeout;
}

/// Ham HTTP yanıtı; başlık adları küçük harfe çevrilir.
class GithubHttpResponse {
  GithubHttpResponse(this.status, this.body, {Map<String, String>? headers})
      : headers = <String, String>{
          for (final e in (headers ?? const <String, String>{}).entries) e.key.toLowerCase(): e.value,
        };

  final int status;
  final String body;
  final Map<String, String> headers;

  String? header(String name) => headers[name.toLowerCase()];
}

/// HTTP gönderici. 4xx/5xx için istisna ATMAZ; ağ hatalarında dart:io istisnası fırlatır.
typedef GithubHttpSender = Future<GithubHttpResponse> Function(GithubHttpRequest request);

/// Varsayılan gönderici (dart:io HttpClient; [GithubCi] ile aynı zaman aşımı ve User-Agent).
Future<GithubHttpResponse> githubHttpSend(GithubHttpRequest r) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final req = await client.openUrl(r.method, r.uri).timeout(r.timeout);
    req.followRedirects = r.followRedirects;
    req.headers.set(HttpHeaders.userAgentHeader, 'kripton-dev-mode');
    r.headers.forEach((k, v) => req.headers.set(k, v));
    final body = r.body;
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final resp = await req.close().timeout(r.timeout);
    final bytes = <int>[];
    await for (final chunk in resp) {
      bytes.addAll(chunk);
    }
    final headers = <String, String>{};
    resp.headers.forEach((name, values) {
      headers[name] = values.join(', ');
    });
    return GithubHttpResponse(resp.statusCode, utf8.decode(bytes, allowMalformed: true),
        headers: headers);
  } finally {
    client.close(force: true);
  }
}

/// Hız sınırı bekleme süresi ([GithubCi] ile aynı kural): Retry-After, `x-ratelimit-remaining: 0` +
/// reset, ya da 429 için 1 dakika. Sınır işareti yoksa null.
Duration? githubRetryAfterFrom({
  required int status,
  String? retryAfter,
  String? remaining,
  String? reset,
  DateTime? now,
}) {
  final ra = int.tryParse(retryAfter ?? '');
  final rs = int.tryParse(reset ?? '');
  if (ra != null) return Duration(seconds: ra < 5 ? 5 : ra);
  if (remaining == '0' && rs != null) {
    final secs = rs - (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    return Duration(seconds: secs < 5 ? 5 : (secs > 3600 ? 3600 : secs));
  }
  if (status == 429) return const Duration(minutes: 1);
  return null;
}

/// İş akışında sabitlenen Flutter sürümü. `pubspec.yaml` `environment.sdk` alt sınırı (>=3.5.0) ile uyumlu olmalı:
/// Flutter 3.35.x, Dart 3.9.x ile gelir. DOĞRULANAMADI: sürüm bağımlılıklarla (pub get) hiç denenmedi.
const String kCiFlutterVersion = '3.35.7';

/// [kCiFlutterVersion]'ın içerdiği Dart sürümü (test, pubspec alt sınırıyla karşılaştırır).
const String kCiFlutterDartVersion = '3.9.2';

/// Sabitlenen action sürümleri (tam sürüm etiketi). DOĞRULANAMADI: etiketlerin varlığı ve SHA karşılıkları
/// ağ erişimi olmadığından denetlenemedi; üretimde `@<40 haneli sha>` ile değiştirilmesi önerilir.
const String kCiActionCheckout = 'actions/checkout@v6.0.0';
const String kCiActionSetupJava = 'actions/setup-java@v5.0.0';
const String kCiActionFlutter = 'subosito/flutter-action@v2.18.0';

/// İş akışı iş zaman aşımı (dakika).
const int kCiJobTimeoutMinutes = 60;

/// GitHub Actions ile gerçek Flutter denetimi (ESKİ YOL: yeni kod [GithubCiRunner] kullanmalı).
class GithubCi {
  GithubCi(this.cfg);

  final GithubCiConfig cfg;
  final Map<String, String> _blobCache = {};

  static const String workflowPath = '.github/workflows/kripton-flutter-check.yml';

  static final RegExp _scriptExt = RegExp(r'\.(sh)$');

  /// Actions iş akışı. İşaretçiler (`##KRIPTON-...`) günlükten aşama çıktısını ayırmak içindir.
  ///
  /// push yalnızca `kripton/**` dallarında tetiklenir; [legacyPushBranches] yalnızca eski [push] yolu içindir
  /// (varsayılan: eski `kripton-ci` dalı). Yeni hat ([GithubCiRunner.ensureWorkflow]) bunu boş verir.
  static String workflowYaml({
    required bool runTests,
    required bool buildApk,
    String flutterVersion = kCiFlutterVersion,
    List<String> legacyPushBranches = const <String>['kripton-ci'],
  }) =>
      _workflowTemplate
          .replaceAll('__PUSH_BRANCHES__', [
            "'kripton/**'",
            for (final b in legacyPushBranches) "'$b'",
          ].map((e) => '      - $e').join('\n'))
          .replaceAll('__CHECKOUT__', kCiActionCheckout)
          .replaceAll('__JAVA__', kCiActionSetupJava)
          .replaceAll('__FLUTTER_ACTION__', kCiActionFlutter)
          .replaceAll('__FLUTTER_VERSION__', flutterVersion)
          .replaceAll('__TIMEOUT__', '$kCiJobTimeoutMinutes')
          .replaceAll('__TEST__', runTests ? '1' : '0')
          .replaceAll('__BUILD__', buildApk ? '1' : '0');

  static const String _workflowTemplate = r'''
name: Kripton Flutter Check
on:
  push:
    branches:
__PUSH_BRANCHES__
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: kripton-flutter-check-${{ github.ref }}
  cancel-in-progress: true
env:
  FLUTTER_SUPPRESS_ANALYTICS: 'true'
  KRIPTON_TEST: '__TEST__'
  KRIPTON_BUILD: '__BUILD__'
jobs:
  check:
    runs-on: ubuntu-24.04
    timeout-minutes: __TIMEOUT__
    steps:
      - uses: __CHECKOUT__
      - uses: __JAVA__
        with:
          distribution: temurin
          java-version: '17'
      - uses: __FLUTTER_ACTION__
        with:
          channel: stable
          flutter-version: '__FLUTTER_VERSION__'
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
      final chunks = <int>[];
      await for (final chunk in resp.timeout(timeout)) {
        chunks.addAll(chunk);
      }
      final text = utf8.decode(chunks, allowMalformed: true);
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

  /// KULLANMA: eski yol (force + ebeveynsiz commit). Geliştirme Modu v2 bunun yerine [DevRepoClient.commitChanges]
  /// ve [GithubCiRunner] kullanır. Davranışı Görev 3/10'da değiştirilmedi.
  ///
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
      final bytes = <int>[];
      await for (final chunk in resp) {
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      if (resp.statusCode >= 400) throw CiHttpException(resp.statusCode, text);
      return (resp.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }

  /// KULLANMA: eski yol ([push] kullanır). Yeni kod [GithubCiRunner.runForCommit] kullanmalı.
  ///
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

// ================= Görev 3/10: çalıştırma ve log hattı =================

/// Maskelenmiş, boyut sınırlı ham CI günlüklerini `devlogs/` benzeri bir klasöre yazar (AtomicFile, JSON).
/// Metin diske yazılmadan ÖNCE [SecretMask.redact]'ten geçer (kırpma maskelemeden sonra yapılır).
class CiLogStore {
  CiLogStore({required this.dir, this.maxBytesPerLog = 2 * 1024 * 1024, this.keep = 10});

  /// Günlük klasörü (uygulama belgeler klasörü altındaki `devlogs` önerilir).
  final Directory dir;

  /// Bir günlüğün en çok UTF-8 bayt sayısı; aşılırsa SONU korunur, başı kırpılır.
  final int maxBytesPerLog;

  /// Saklanan en son günlük sayısı.
  final int keep;

  static final RegExp _nameRe = RegExp(r'^ci-\d{8}T\d{6}Z-\d+\.json$');

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _stamp(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}${_two(t.month)}${_two(t.day)}T${_two(t.hour)}${_two(t.minute)}${_two(t.second)}Z';

  /// Günlüğü yazar ve dosya yolunu döner; hiçbir koşulda istisna fırlatmaz (başarısızsa null).
  Future<String?> save({
    required String branch,
    required String sha,
    required int runId,
    required String runUrl,
    required String stage,
    required String text,
    int? exitCode,
    DateTime? now,
  }) async {
    try {
      var body = SecretMask.redact(text);
      final originalChars = body.length;
      var truncated = false;
      if (utf8.encode(body).length > maxBytesPerLog) {
        truncated = true;
        body = _tailByBytes(body, maxBytesPerLog);
      }
      final t = (now ?? DateTime.now()).toUtc();
      final path = pth.join(dir.path, 'ci-${_stamp(t)}-$runId.json');
      await AtomicFile.writeJson(path, <String, Object?>{
        'v': 1,
        'savedAt': t.toIso8601String(),
        'branch': SecretMask.redact(branch),
        'sha': sha,
        'runId': runId,
        'runUrl': SecretMask.redact(runUrl),
        'stage': stage,
        'exitCode': exitCode,
        'truncated': truncated,
        'originalChars': originalChars,
        'log': body,
      });
      await prune();
      return path;
    } catch (e, st) {
      CrashGuard.log('CI günlüğü yazılamadı', e, st);
      return null;
    }
  }

  /// Saklanan günlük dosyaları, en yenisi başta.
  Future<List<String>> list() async {
    try {
      if (!await dir.exists()) return <String>[];
      final names = <String>[];
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final n = pth.basename(e.path);
        if (_nameRe.hasMatch(n)) names.add(n);
      }
      names.sort((a, b) => b.compareTo(a));
      return names.map((n) => pth.join(dir.path, n)).toList();
    } catch (_) {
      return <String>[];
    }
  }

  /// [keep]'ten eski günlükleri siler.
  Future<void> prune() async {
    final all = await list();
    for (var i = keep; i < all.length; i++) {
      await AtomicFile.delete(all[i]);
    }
  }

  static String _tailByBytes(String s, int maxBytes) {
    final bytes = utf8.encode(s);
    if (bytes.length <= maxBytes) return s;
    var out = utf8.decode(bytes.sublist(bytes.length - maxBytes), allowMalformed: true);
    final nl = out.indexOf('\n');
    if (nl >= 0 && nl < 2000) out = out.substring(nl + 1);
    return '[… günlüğün başı bayt sınırı nedeniyle kırpıldı …]\n$out';
  }
}

/// [GithubCiRunner.ensureWorkflow] sonucu. [committed] true ise dal ucu İLERLEDİ: çağıran sonraki
/// `commitChanges` için [headSha]'yı `expectedHeadSha` olarak kullanmalı.
class EnsureWorkflowResult {
  const EnsureWorkflowResult({required this.headSha, required this.committed});

  final String headSha;
  final bool committed;
}

class _CiInfra implements Exception {
  _CiInfra(this.reason, this.message);

  final CiInfraReason reason;
  final String message;
}

class _RunRef {
  const _RunRef(this.id, this.url);

  final int id;
  final String url;
}

/// Çalışma dalındaki bir commit için Actions çalıştırır, bekler, günlüğü indirir, ayrıştırır ve [CiOutcome] döner.
/// Ağ yalnızca [GithubHttpSender] üzerinden gider (testte sahte). Hiçbir sır log/ileti/diske maskesiz yazılmaz.
class GithubCiRunner {
  GithubCiRunner({
    required String repo,
    required String token,
    DevRepoClient? repoClient,
    GithubHttpSender? send,
    bool Function()? cancelled,
    Future<void>? onCancel,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
    this.logStore,
    this.runTests = true,
    this.buildApk = true,
    this.flutterVersion = kCiFlutterVersion,
    this.findTimeout = const Duration(minutes: 6),
    this.dispatchAfter = const Duration(seconds: 45),
    this.queueTimeout = const Duration(minutes: 15),
    this.overallTimeout = const Duration(minutes: 75),
    this.pollStart = const Duration(seconds: 8),
    this.pollMax = const Duration(seconds: 30),
    this.logRetries = 5,
    this.logRetryWait = const Duration(seconds: 10),
    this.feedbackBudgetChars = CiFeedback.defaultBudgetChars,
  })  : repo = repo.trim(),
        _token = token.trim(),
        _send = send ?? githubHttpSend,
        _cancelled = cancelled ?? (() => false),
        _onCancel = onCancel,
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _now = now ?? DateTime.now {
    SecretMask.register(_token);
    _client = repoClient ??
        DevRepoClient(
          repo: this.repo,
          token: _token,
          send: _send,
          allowWorkflowEdits: true,
          sleep: _sleep,
          cancelled: _cancelled,
          onCancel: _onCancel,
          now: _now,
        );
  }

  factory GithubCiRunner.fromConfig(
    GithubCiConfig cfg, {
    GithubHttpSender? send,
    bool Function()? cancelled,
    Future<void>? onCancel,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
    CiLogStore? logStore,
  }) =>
      GithubCiRunner(
        repo: cfg.repo,
        token: cfg.token,
        send: send,
        cancelled: cancelled,
        onCancel: onCancel,
        sleep: sleep,
        now: now,
        logStore: logStore,
        runTests: cfg.runTests,
        buildApk: cfg.buildApk,
      );

  /// İş akışı dosya adı (workflow_dispatch ve çalışma süzgeci için).
  static const String workflowFile = 'kripton-flutter-check.yml';

  /// Iş akışının `name:` değeri.
  static const String workflowName = 'Kripton Flutter Check';

  final String repo;
  final String _token;
  final GithubHttpSender _send;
  final bool Function() _cancelled;
  final Future<void>? _onCancel;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;
  late final DevRepoClient _client;

  final CiLogStore? logStore;
  final bool runTests;
  final bool buildApk;
  final String flutterVersion;

  /// Push'un çalışma açmasını bekleme süresi (aşılırsa altyapı hatası).
  final Duration findTimeout;

  /// Bu süre sonunda çalışma yoksa workflow_dispatch ile tetiklenir.
  final Duration dispatchAfter;

  /// Çalışma kuyrukta bu kadar kalırsa (runner yok) altyapı hatası.
  final Duration queueTimeout;

  /// Çalışma başladıktan sonra toplam bekleme sınırı.
  final Duration overallTimeout;
  final Duration pollStart;
  final Duration pollMax;
  final int logRetries;
  final Duration logRetryWait;
  final int feedbackBudgetChars;

  /// Bu dalda olması gereken iş akışı metni (yalnızca kripton/** push'u).
  String get workflowYamlText => GithubCi.workflowYaml(
        runTests: runTests,
        buildApk: buildApk,
        flutterVersion: flutterVersion,
        legacyPushBranches: const <String>[],
      );

  // ---------------------------------------------------------------- HTTP

  Uri _api(String path, [Map<String, String>? query]) => Uri.https('api.github.com', '/repos/$repo$path', query);

  void _checkCancelled() {
    if (_cancelled()) throw const CiCancelledException();
  }

  Future<void> _wait(Duration d) async {
    _checkCancelled();
    final oc = _onCancel;
    await Future.any<void>(<Future<void>>[_sleep(d), if (oc != null) oc]);
    _checkCancelled();
  }

  static Duration _backoff(int fails) {
    final secs = 2 << (fails > 5 ? 5 : fails);
    return Duration(seconds: secs > 60 ? 60 : secs);
  }

  String _redact(String s, {int max = 400}) {
    final r = SecretMask.redact(s.trim());
    return r.length > max ? r.substring(0, max) : r;
  }

  String _errMsg(GithubHttpResponse r) {
    var text = r.body;
    try {
      final v = jsonDecode(r.body);
      if (v is Map && v['message'] is String) text = v['message'] as String;
    } catch (_) {
      // JSON değil: ham metin
    }
    return _redact(text);
  }

  /// Tek istek denemesi. Ağ/5xx -> [CiTransientException]; 4xx -> [CiHttpException] ([okStatuses] hariç).
  Future<GithubHttpResponse> _once(
    String method,
    Uri uri, {
    Object? body,
    bool auth = true,
    bool follow = true,
    bool checkCancel = true,
    Map<String, String>? extra,
    Duration timeout = const Duration(seconds: 90),
    Set<int> okStatuses = const <int>{},
  }) async {
    if (checkCancel) _checkCancelled();
    final bytes = body == null ? null : utf8.encode(jsonEncode(body));
    final headers = <String, String>{
      if (auth) ...<String, String>{
        'authorization': 'Bearer $_token',
        'accept': 'application/vnd.github+json',
        'x-github-api-version': '2022-11-28',
      },
      if (bytes != null) 'content-type': 'application/json',
      ...?extra,
    };
    GithubHttpResponse r;
    try {
      r = await _send(GithubHttpRequest(
        method: method,
        uri: uri,
        headers: headers,
        body: bytes,
        timeout: timeout,
        followRedirects: follow,
      ));
    } on TimeoutException catch (e) {
      throw CiTransientException(_redact('GitHub bağlantı zaman aşımı: $e'));
    } on SocketException catch (e) {
      throw CiTransientException(_redact('GitHub bağlantı hatası: $e'));
    } on HttpException catch (e) {
      throw CiTransientException(_redact('GitHub bağlantı hatası: $e'));
    } on TlsException catch (e) {
      throw CiTransientException(_redact('GitHub TLS hatası: $e'));
    }
    if (r.status >= 500) throw CiTransientException('GitHub HTTP ${r.status}');
    if (r.status >= 400 && !okStatuses.contains(r.status)) {
      var retry = githubRetryAfterFrom(
        status: r.status,
        retryAfter: r.header('retry-after'),
        remaining: r.header('x-ratelimit-remaining'),
        reset: r.header('x-ratelimit-reset'),
        now: _now(),
      );
      if (retry == null && r.status == 403 && r.body.toLowerCase().contains('rate limit')) {
        retry = const Duration(minutes: 1);
      }
      throw CiHttpException(r.status, _errMsg(r), retryAfter: retry);
    }
    return r;
  }

  /// [op]'u geçici hatalarda (ağ, 5xx, hız sınırı) geri çekilerek [deadline]'a dek yeniden dener.
  Future<T> _retry<T>(Future<T> Function() op, DateTime deadline) async {
    var fails = 0;
    while (true) {
      _checkCancelled();
      try {
        return await op();
      } on CiTransientException catch (e) {
        fails++;
        if (_now().isAfter(deadline)) {
          throw _CiInfra(CiInfraReason.network, 'GitHub\'a ulaşılamadı: ${e.message}');
        }
        await _wait(_backoff(fails));
      } on CiHttpException catch (e) {
        final ra = e.retryAfter;
        if (ra == null) rethrow;
        if (_now().add(ra).isAfter(deadline)) {
          throw _CiInfra(CiInfraReason.rateLimit,
              'GitHub hız sınırı: ~${ra.inSeconds} sn beklemek gerekiyor; süre yetmiyor.');
        }
        await _wait(ra);
      }
    }
  }

  Map<String, dynamic> _asMap(String body, String what) {
    try {
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {
      // aşağıda hata
    }
    throw CiTransientException('$what yanıtı beklenen biçimde değil.');
  }

  Future<Map<String, dynamic>> _getJson(String path, DateTime deadline, [Map<String, String>? query]) =>
      _retry(() async => _asMap((await _once('GET', _api(path, query))).body, path), deadline);

  static String? _str(Object? v) => v is String ? v : null;

  _CiInfra _mapHttp(CiHttpException e) {
    switch (e.status) {
      case 401:
        return _CiInfra(CiInfraReason.auth, 'GitHub token geçersiz ya da süresi dolmuş (401).');
      case 403:
        return _CiInfra(CiInfraReason.auth,
            'GitHub bu işleme izin vermedi (403): token\'da Actions (Read/Write) ve Contents izinlerini kontrol et. ${e.message}');
      case 404:
        return _CiInfra(CiInfraReason.auth,
            'GitHub kaynağı bulamadı (404): depo adı yanlış ya da token bu depoya erişemiyor. ${e.message}');
      default:
        return _CiInfra(CiInfraReason.other, 'GitHub HTTP ${e.status}: ${e.message}');
    }
  }

  // ---------------------------------------------------------------- iş akışı

  static String _normalizeYaml(String s) =>
      s.replaceAll('\r\n', '\n').split('\n').map((l) => l.trimRight()).join('\n').trimRight();

  /// [branch] dalında kontrol iş akışının güncel olmasını sağlar. Dosya zaten aynıysa commit ATILMAZ.
  /// Commit atılırsa dal ucu ilerler: dönen [EnsureWorkflowResult.headSha] yeni uçtur.
  /// Dal `kripton/` ile başlamalı ([DevRepoClient.commitChanges] zorlar); [DevConflictException] çağırana yükselir.
  Future<EnsureWorkflowResult> ensureWorkflow(String branch) async {
    if (!_client.allowWorkflowEdits) {
      throw const DevPolicyException('İş akışını yazmak için DevRepoClient allowWorkflowEdits:true olmalı.');
    }
    try {
      final deadline = _now().add(const Duration(minutes: 5));
      final ref = await _retry(() async {
        final r = await _once('GET', _api('/git/ref/heads/$branch'), okStatuses: const <int>{404});
        if (r.status == 404) throw DevRepoException('Dal bulunamadı: "$branch".');
        final o = _asMap(r.body, 'ref')['object'];
        final sha = o is Map ? _str(o['sha']) : null;
        if (sha == null) throw CiTransientException('ref yanıtında sha yok.');
        return sha;
      }, deadline);
      final current = await _retry(() async {
        final r = await _once(
          'GET',
          _api('/contents/${GithubCi.workflowPath}', <String, String>{'ref': branch}),
          extra: const <String, String>{'accept': 'application/vnd.github.raw+json'},
          okStatuses: const <int>{404},
        );
        return r.status == 404 ? null : r.body;
      }, deadline);
      final wanted = workflowYamlText;
      if (current != null && _normalizeYaml(current) == _normalizeYaml(wanted)) {
        return EnsureWorkflowResult(headSha: ref, committed: false);
      }
      final sha = await _client.commitChanges(
        branch,
        ref,
        <String, String?>{GithubCi.workflowPath: wanted},
        current == null ? 'Kripton: CI iş akışı eklendi' : 'Kripton: CI iş akışı güncellendi',
      );
      return EnsureWorkflowResult(headSha: sha, committed: true);
    } on _CiInfra catch (e) {
      throw DevRepoException(e.message);
    } on CiHttpException catch (e) {
      throw DevRepoException(_mapHttp(e).message);
    }
  }

  // ---------------------------------------------------------------- çalıştırma

  /// [ensureWorkflow] + [runForCommit]. Dal ucu ilerlediyse sonuçtaki `sha` yeni uçtur.
  Future<CiOutcome> checkBranch(String branch, {void Function(String status)? status}) async {
    try {
      final e = await ensureWorkflow(branch);
      return await runForCommit(branch, e.headSha, status: status);
    } on CiCancelledException {
      return const CiCancelled(message: 'İptal edildi.');
    } on CiTransientException catch (e) {
      return CiInfraError(reason: CiInfraReason.network, message: _redact(e.message));
    } on DevConflictException {
      rethrow; // dal ilerlemiş: çağıran dalı yeniden yüklemeli
    } on DevPolicyException {
      rethrow; // programlama/güvenlik kuralı hatası
    } on DevRepoException catch (e) {
      return CiInfraError(reason: CiInfraReason.other, message: _redact(e.message));
    }
  }

  /// [sha] commit'i için Actions çalışmasını bulur (yoksa tetikler), bitmesini bekler ve sonucu döner.
  /// İstisna fırlatmaz (programlama hataları hariç): her durum bir [CiOutcome]'dur.
  /// Altyapı sorunları ASLA [CiFailure] olmaz.
  Future<CiOutcome> runForCommit(String branch, String sha, {void Function(String status)? status}) async {
    void say(String s) => status?.call(s);
    final started = _now();
    final deadline = started.add(overallTimeout);
    int? runId;
    var runUrl = '';
    try {
      final ref = await _findRun(branch, sha, started, deadline, say);
      runId = ref.id;
      runUrl = ref.url;
      return await _awaitAndCollect(branch, sha, ref, deadline, say);
    } on CiCancelledException {
      if (runId != null) await _cancelRun(runId);
      return CiCancelled(message: 'İptal edildi.', runUrl: runUrl, sha: sha, runId: runId);
    } on _CiInfra catch (e) {
      if (runId != null && (e.reason == CiInfraReason.timeout || e.reason == CiInfraReason.runnerNotStarted)) {
        await _cancelRun(runId);
      }
      return CiInfraError(reason: e.reason, message: _redact(e.message, max: 1500), runUrl: runUrl, sha: sha, runId: runId);
    } on CiHttpException catch (e) {
      final m = _mapHttp(e);
      return CiInfraError(reason: m.reason, message: _redact(m.message, max: 1500), runUrl: runUrl, sha: sha, runId: runId);
    } on CiTransientException catch (e) {
      return CiInfraError(
          reason: CiInfraReason.network, message: _redact(e.message), runUrl: runUrl, sha: sha, runId: runId);
    }
  }

  Future<void> _cancelRun(int runId) async {
    try {
      await _once(
        'POST',
        _api('/actions/runs/$runId/cancel'),
        checkCancel: false,
        okStatuses: const <int>{409, 404, 403},
      );
    } catch (_) {
      // en iyi çaba
    }
  }

  _RunRef? _pickRun(Map<String, dynamic> json, String sha) {
    final runs = json['workflow_runs'];
    if (runs is! List) return null;
    _RunRef? best;
    for (final r in runs) {
      if (r is! Map) continue;
      if (r['head_sha'] != sha) continue;
      final path = _str(r['path']) ?? '';
      final name = _str(r['name']) ?? '';
      if (!path.contains(workflowFile) && name != workflowName) continue;
      final id = r['id'];
      if (id is! num) continue;
      if (best == null || id.toInt() > best.id) best = _RunRef(id.toInt(), _str(r['html_url']) ?? '');
    }
    return best;
  }

  Future<_RunRef> _findRun(
    String branch,
    String sha,
    DateTime started,
    DateTime deadline,
    void Function(String) say,
  ) async {
    var dispatched = false;
    String dispatchNote = '';
    while (true) {
      final j = await _getJson('/actions/runs', deadline, <String, String>{'head_sha': sha, 'per_page': '20'});
      final ref = _pickRun(j, sha);
      if (ref != null) return ref;
      final el = _now().difference(started);
      if (!dispatched && el >= dispatchAfter) {
        dispatched = true;
        say('GitHub: push çalışma açmadı; workflow_dispatch deneniyor…');
        dispatchNote = await _dispatch(branch, deadline);
      }
      if (el >= findTimeout) throw await _notStarted(dispatchNote);
      say('GitHub: Actions çalışması bekleniyor…');
      await _wait(pollStart);
    }
  }

  /// workflow_dispatch tetikler. 404/422 (iş akışı varsayılan dalda yok vb.) hata sayılmaz; açıklama döner.
  Future<String> _dispatch(String branch, DateTime deadline) async {
    final r = await _retry(
      () => _once(
        'POST',
        _api('/actions/workflows/$workflowFile/dispatches'),
        body: <String, Object?>{'ref': branch},
        okStatuses: const <int>{404, 422},
      ),
      deadline,
    );
    if (r.status == 404 || r.status == 422) {
      return 'workflow_dispatch reddedildi (HTTP ${r.status}: ${_errMsg(r)}). İş akışı varsayılan dalda yoksa '
          'dispatch çalışmaz; push tetiklemesi de çalışmadıysa depoda Actions kapalı olabilir.';
    }
    return '';
  }

  Future<_CiInfra> _notStarted(String dispatchNote) async {
    try {
      final r = await _once('GET', _api('/actions/permissions'), okStatuses: const <int>{403, 404});
      if (r.status == 200) {
        final j = _asMap(r.body, 'permissions');
        if (j['enabled'] == false) {
          return _CiInfra(CiInfraReason.actionsDisabled,
              'Bu depoda GitHub Actions kapalı. Depo Ayarları > Actions bölümünden açılmalı.');
        }
      }
    } on CiCancelledException {
      rethrow;
    } catch (_) {
      // sınıflandırma en iyi çaba
    }
    return _CiInfra(
      dispatchNote.isNotEmpty ? CiInfraReason.workflowMissing : CiInfraReason.runnerNotStarted,
      'Actions çalışması başlamadı (${findTimeout.inMinutes} dk). Token\'da "workflow"/Actions yetkisi var mı? '
      '$dispatchNote'.trim(),
    );
  }

  Future<CiOutcome> _awaitAndCollect(
    String branch,
    String sha,
    _RunRef ref,
    DateTime deadline,
    void Function(String) say,
  ) async {
    final runStarted = _now();
    var poll = pollStart;
    DateTime? queuedSince;
    String? conclusion;
    while (true) {
      if (_now().isAfter(deadline)) {
        throw _CiInfra(CiInfraReason.timeout, 'Actions çalışması ${overallTimeout.inMinutes} dakikada bitmedi.');
      }
      final j = await _getJson('/actions/runs/${ref.id}', deadline);
      final st = _str(j['status']);
      if (st == 'completed') {
        conclusion = _str(j['conclusion']);
        break;
      }
      if (st == 'queued' || st == 'waiting' || st == 'pending' || st == 'requested') {
        queuedSince ??= _now();
        if (_now().difference(queuedSince) > queueTimeout) {
          throw _CiInfra(CiInfraReason.runnerNotStarted,
              'Çalışma ${queueTimeout.inMinutes} dakikadır kuyrukta; runner atanmadı.');
        }
      } else {
        queuedSince = null;
      }
      final el = _now().difference(runStarted);
      say('GitHub: Actions çalışıyor (${el.inMinutes} dk ${el.inSeconds % 60} sn)…');
      await _wait(poll);
      final next = poll + const Duration(seconds: 4);
      poll = next > pollMax ? pollMax : next;
    }

    CiOutcome ok() => CiSuccess(runUrl: ref.url, sha: sha, runId: ref.id);
    switch (conclusion) {
      case 'success':
      case 'neutral':
        return ok();
      case 'timed_out':
        throw _CiInfra(CiInfraReason.timeout, 'Actions işi zaman aşımına uğradı (timeout-minutes).');
      case 'startup_failure':
        throw _CiInfra(CiInfraReason.startupFailure,
            'Actions çalışması başlatılamadı (startup_failure): iş akışı geçersiz olabilir ya da hesap/faturalandırma sorunu var.');
      case 'cancelled':
        {
          if (await _anyJobTimedOut(ref.id, deadline)) {
            throw _CiInfra(CiInfraReason.timeout, 'Actions işi zaman aşımına uğradı (timeout-minutes).');
          }
          return CiCancelled(
            message: 'Actions çalışması iptal edildi (aynı dala yeni commit/elle iptal olabilir).',
            runUrl: ref.url,
            sha: sha,
            runId: ref.id,
          );
        }
      case 'skipped':
      case 'stale':
        return CiCancelled(message: 'Actions çalışması atlandı ($conclusion).', runUrl: ref.url, sha: sha, runId: ref.id);
      case 'failure':
        say('GitHub: hata günlüğü indiriliyor…');
        return _collectFailure(branch, sha, ref, deadline);
      default:
        throw _CiInfra(CiInfraReason.other, 'Actions çalışması beklenmeyen sonuçla bitti: ${conclusion ?? 'bilinmiyor'}.');
    }
  }

  Future<List<Map<String, dynamic>>> _jobs(int runId, DateTime deadline) async {
    final j = await _getJson('/actions/runs/$runId/jobs', deadline, <String, String>{'per_page': '30', 'filter': 'latest'});
    final jobs = j['jobs'];
    return <Map<String, dynamic>>[
      if (jobs is List)
        for (final e in jobs)
          if (e is Map<String, dynamic>) e,
    ];
  }

  Future<bool> _anyJobTimedOut(int runId, DateTime deadline) async {
    final jobs = await _jobs(runId, deadline);
    for (final job in jobs) {
      if (job['conclusion'] == 'timed_out') return true;
      final steps = job['steps'];
      if (steps is List && steps.any((s) => s is Map && s['conclusion'] == 'timed_out')) return true;
    }
    return false;
  }

  Future<CiOutcome> _collectFailure(String branch, String sha, _RunRef ref, DateTime deadline) async {
    final jobs = await _jobs(ref.id, deadline);
    if (jobs.isEmpty) throw _CiInfra(CiInfraReason.other, 'Actions işi bulunamadı.');
    Map<String, dynamic> job = jobs.first;
    for (final j in jobs) {
      final c = j['conclusion'];
      if (c != 'success' && c != 'skipped') {
        job = j;
        break;
      }
    }
    if (job['conclusion'] == 'timed_out') {
      throw _CiInfra(CiInfraReason.timeout, 'Actions işi zaman aşımına uğradı (timeout-minutes).');
    }
    String? failedStep;
    final steps = job['steps'];
    if (steps is List) {
      for (final s in steps) {
        if (s is Map && s['conclusion'] == 'failure') {
          failedStep = _str(s['name']);
          break;
        }
      }
    }
    final jobId = job['id'];
    if (jobId is! num) throw _CiInfra(CiInfraReason.other, 'Actions iş kimliği okunamadı.');
    // Sırlar indirilir indirilmez maskelenir: ayrıştırma, AI metni ve diske yazım maskeli metinden yapılır.
    final log = SecretMask.redact(await _downloadLog(jobId.toInt(), deadline));
    final res = CiLogParser.parseJobLog(log, runUrl: ref.url);
    final raw = res.stageLog.isEmpty ? log : res.stageLog;

    Future<String?> store() async => logStore?.save(
          branch: branch,
          sha: sha,
          runId: ref.id,
          runUrl: ref.url,
          stage: res.stage,
          exitCode: res.exitCode,
          text: raw,
        );

    CiInfraError infra(CiInfraReason reason, String message, String? path) => CiInfraError(
          reason: reason,
          message: _redact('$message\n${_tail(log, 20)}', max: 2500),
          rawLogPath: path,
          runUrl: ref.url,
          sha: sha,
          runId: ref.id,
        );

    if (failedStep != null && failedStep != 'Kripton kontrol') {
      return infra(CiInfraReason.setupFailed, 'Kurulum adımı başarısız: "$failedStep" (kod hatası değil).', await store());
    }
    if (res.ok) {
      return infra(CiInfraReason.setupFailed,
          'Tüm Kripton aşamaları 0 ile bitti ama iş başarısız (kurulum/sonlandırma adımı).', await store());
    }
    if (res.stage == 'setup') {
      return infra(CiInfraReason.setupFailed, 'Kripton aşamaları hiç başlamadı (checkout/Flutter kurulumu).', await store());
    }
    if (res.incomplete) {
      return infra(CiInfraReason.stageInterrupted,
          '"${res.stage}" aşaması bitiş işaretçisi olmadan kesildi (runner kaybı/zaman aşımı).', await store());
    }
    return CiFailure(
      signature: CiFailureSignature.of(res),
      feedback: CiFeedback.forAi(res, budgetChars: feedbackBudgetChars),
      result: res,
      rawLogPath: await store(),
      runUrl: ref.url,
      sha: sha,
      runId: ref.id,
    );
  }

  static String _tail(String log, int n) {
    final lines = log.split('\n').map(CiLogParser.cleanLine).where((l) => l.trim().isNotEmpty).toList();
    final from = lines.length > n ? lines.length - n : 0;
    return lines.sublist(from).join('\n');
  }

  /// İş günlüğünü indirir. İmzalı adrese yönlenmede Authorization başlığı GÖNDERİLMEZ.
  Future<String> _downloadLog(int jobId, DateTime deadline) async {
    var tries = 0;
    var lastStatus = 0;
    while (true) {
      final r = await _retry(
        () => _once('GET', _api('/actions/jobs/$jobId/logs'), follow: false, okStatuses: const <int>{404, 410}),
        deadline,
      );
      lastStatus = r.status;
      if (r.status >= 300 && r.status < 400) {
        final uri = Uri.tryParse(r.header('location') ?? '');
        if (uri != null && uri.scheme == 'https') {
          final r2 = await _retry(
            () => _once('GET', uri, auth: false, timeout: const Duration(minutes: 3), okStatuses: const <int>{403, 404, 410}),
            deadline,
          );
          lastStatus = r2.status;
          if (r2.status >= 200 && r2.status < 300) return r2.body;
        }
      } else if (r.status >= 200 && r.status < 300) {
        return r.body;
      }
      tries++;
      if (tries > logRetries) {
        throw _CiInfra(CiInfraReason.logsUnavailable, 'İş günlüğü indirilemedi (HTTP $lastStatus).');
      }
      await _wait(logRetryWait);
    }
  }
}
