// Görev 4/10 (Geliştirme Modu v2): doğrulama kapıları, doğrulayıcı AI ayrıştırıcısı ve seçim politikası.
//
// Saf Dart; ağ ve UI yok. FAIL-CLOSED: [GuardVerdict.ok] yalnızca hiçbir kapı ihlal edilmediyse VE en az
// bir gerçek değişiklik üretildiyse true olur. İstisna dahil her belirsizlik RED demektir.
// Yama biçimi YENİ DEĞİL: mevcut `<<<<<<< DOSYA / ESKİ / ======= / >>>>>>> YENİ` (ve TAM) blokları.

import '../data/flutter_project_check.dart';
import '../data/project_snapshot.dart';
import '../data/secret_mask.dart';
import 'dev_mode.dart';
import 'workflow_runner.dart';

/// Kapı kodları (hata defteri ve ders listesi bu kodları kullanır).
class DevGate {
  const DevGate._();

  /// Doğrulayıcının kendi iç hatası (istisna) — fail-closed.
  static const String internal = 'G0';

  /// G1: çıktı biçimi geçerli (bloklar kapalı, ayrıştırılabilir, işaretler sızmamış).
  static const String format = 'G1';

  /// G2: yol var / kapsamda / yasak değil.
  static const String path = 'G2';

  /// G3: ESKİ blok dosyada BİREBİR ve TEK kez eşleşir.
  static const String match = 'G3';

  /// G4: değişiklik büyüklüğü (toplu silme, dosya boşaltma, aşırı büyük diff).
  static const String size = 'G4';

  /// G5: sözdizimi / regresyon sağlığı.
  static const String regression = 'G5';

  /// G6: yeni import'lar var olan pakete veya dosyaya işaret eder.
  static const String imports = 'G6';

  /// G7: dejenere / tekrar eden / boş çıktı.
  static const String degenerate = 'G7';

  /// G8: sır benzeri dize veya ilgisiz yere eklenmiş süreç/ağ çağrısı.
  static const String suspicious = 'G8';

  /// V1: doğrulayıcı AI açıkça RED dedi.
  static const String verifierRed = 'V1';

  /// V2: doğrulayıcı çıktısı ayrıştırılamadı / belirsiz (RED sayılır).
  static const String verifierUnparsable = 'V2';

  /// C1: yama CI'da (analyze/test/build) başarısız oldu.
  static const String ci = 'C1';

  static const List<String> all = [
    internal, format, path, match, size, regression, imports, degenerate, suspicious,
    verifierRed, verifierUnparsable, ci,
  ];

  /// Kısa Türkçe başlık.
  static String title(String code) => switch (code) {
    'G0' => 'iç hata',
    'G1' => 'çıktı biçimi',
    'G2' => 'yol/kapsam',
    'G3' => 'ESKİ blok eşleşmesi',
    'G4' => 'değişiklik büyüklüğü',
    'G5' => 'sözdizimi/regresyon',
    'G6' => 'import',
    'G7' => 'boş/tekrarlı çıktı',
    'G8' => 'şüpheli ekleme',
    'V1' => 'doğrulayıcı reddi',
    'V2' => 'doğrulayıcı biçimi',
    'C1' => 'CI hatası',
    _ => code,
  };

  /// Sonraki isteklere verilecek tek cümlelik ders.
  static String advice(String code) => switch (code) {
    'G0' => 'Çıktıyı sade tut ve yama biçimine tam uy.',
    'G1' => 'Yalnızca DOSYA/ESKİ/=======/YENİ bloklarını yaz, her bloğu kapat, açıklama ekleme.',
    'G2' => 'Yalnızca verilen koddaki dosya yollarını aynen kullan; .github, pubspec.lock ve gizli dosyalara dokunma.',
    'G3' => 'ESKİ bölümü koddan BİREBİR kopyala; dosyada tek yerde eşleşecek kadar uzun tut.',
    'G4' => 'Küçük ve odaklı yama yaz; toplu silme veya dosya boşaltma yapma.',
    'G5' => 'Parantezleri dengede tut; yeni derleme hatası getirme.',
    'G6' => 'Yalnızca var olan paket ve dosyaları import et; yeni paket ekleme.',
    'G7' => 'Boş veya tekrarlayan çıktı üretme; her yamayı yalnızca bir kez yaz.',
    'G8' => 'Gizli anahtar, süreç çalıştırma veya ağ çağrısı ekleme.',
    'V1' => 'Yalnızca bulgudaki sorunu çöz; ilgisiz değişiklik yapma.',
    'V2' => 'Doğrulayıcı: "KARAR: ONAY" veya "KARAR: RED" ve en çok 3 gerekçe satırı yaz.',
    'C1' => 'Yama CI\'da hata verdi; araç çıktısındaki hatayı birebir gider.',
    _ => 'Önceki hatayı tekrarlama.',
  };
}

/// Kapı eşikleri. Varsayılanlar küçük, odaklı yamalar için ayarlıdır.
class DevGuardLimits {
  const DevGuardLimits({
    this.maxPatches = 12,
    this.maxChangedFiles = 8,
    this.maxOutputChars = 200000,
    this.maxOldBlockLines = 80,
    this.maxDiffChars = 24000,
    this.maxNewFileChars = 40000,
    this.maxRemovedLinesPerFile = 80,
    this.minShrinkBaseChars = 400,
    this.minShrinkKeepRatio = 0.5,
    this.maxPathLength = 200,
  });

  final int maxPatches;
  final int maxChangedFiles;
  final int maxOutputChars;
  final int maxOldBlockLines;

  /// Tüm yamaların ESKİ + YENİ karakter toplamı.
  final int maxDiffChars;
  final int maxNewFileChars;
  final int maxRemovedLinesPerFile;

  /// Bir dosya bu uzunluğun üstündeyse ve değişiklikten sonra [minShrinkKeepRatio] oranının altına
  /// düşüyorsa (toplu silme) reddedilir.
  final int minShrinkBaseChars;
  final double minShrinkKeepRatio;
  final int maxPathLength;
}

/// Bir kapı ihlali. [detail] ve [path] SecretMask'ten geçirilir ve kısaltılır.
class GuardViolation {
  GuardViolation(this.code, String detail, {String path = '', this.patchIndex})
    : detail = _clip(SecretMask.redact(detail), 300),
      path = _clip(SecretMask.redact(path), 200);

  final String code;
  final String detail;
  final String path;

  /// Çıktıdaki 0 tabanlı yama sırası (biliniyorsa).
  final int? patchIndex;

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  @override
  String toString() => '$code${path.isEmpty ? '' : ' [$path]'}: $detail';
}

/// Uygulanan tek bir değişiklik parçası (doğrulayıcıya verilen diff bundan üretilir).
class GuardHunk {
  const GuardHunk({
    required this.path,
    required this.oldText,
    required this.newText,
    required this.isNewFile,
  });

  final String path;
  final String oldText;
  final String newText;
  final bool isNewFile;
}

/// Kapıların kararı. Yalnızca [DevGuard] üretebilir (özel kurucu); [ok] hesaplanır.
final class GuardVerdict {
  GuardVerdict._(
    List<GuardViolation> v,
    Map<String, String> c,
    List<GuardHunk> h,
    this.patchCount,
  ) : violations = List<GuardViolation>.unmodifiable(v),
      changes = v.isEmpty ? Map<String, String>.unmodifiable(c) : const <String, String>{},
      hunks = v.isEmpty ? List<GuardHunk>.unmodifiable(h) : const <GuardHunk>[];

  /// Boş ise kapılardan geçildi (yine de [ok] için değişiklik de gerekir).
  final List<GuardViolation> violations;

  /// Yalnızca [ok] iken dolu: yol → TAM yeni içerik. Depoya yazılacak olan TAM olarak budur.
  final Map<String, String> changes;
  final List<GuardHunk> hunks;

  /// Ayrıştırılan yama bloğu sayısı.
  final int patchCount;

  /// Fail-closed: ihlal yok VE en az bir gerçek değişiklik.
  bool get ok => violations.isEmpty && changes.isNotEmpty;

  Set<String> get gates => {for (final v in violations) v.code};

  List<String> get changedPaths => changes.keys.toList()..sort();

  String get summary => ok
      ? 'ONAY: ${changes.length} dosya değişti'
      : violations.isEmpty
      ? 'RED: değişiklik yok'
      : violations.map((e) => e.toString()).join(' | ');

  /// Doğrulayıcıya verilecek, uzunluğu sınırlı diff metni (maskelenmiş).
  String diffText({int maxChars = 6000}) {
    final b = StringBuffer();
    for (final h in hunks) {
      b.writeln('@@ ${h.path}${h.isNewFile ? ' (YENİ DOSYA)' : ''} @@');
      if (!h.isNewFile) {
        for (final l in h.oldText.split('\n')) {
          b.writeln('- $l');
        }
      }
      for (final l in h.newText.split('\n')) {
        b.writeln('+ $l');
      }
      b.writeln();
    }
    final s = SecretMask.redact(b.toString().trimRight());
    if (s.length <= maxChars) return s;
    return '${s.substring(0, maxChars)}\n… (diff kırpıldı: ${s.length - maxChars} karakter daha)';
  }
}

class _Suspect {
  const _Suspect(this.label, this.pattern, this.related);

  final String label;
  final RegExp pattern;

  /// Bulgu metninde geçerse eklemenin "ilgili" sayıldığı sözcükler.
  final RegExp related;
}

/// Yapay zekâ çıktısını depoya girmeden önce denetleyen kapılar.
class DevGuard {
  const DevGuard._();

  static final RegExp _openRe = RegExp(r'<<<<<<<\s*DOSYA:');
  static final RegExp _closeRe = RegExp(r'>>>>>>>\s*(?:YEN[İIi]|TAM)');
  static final RegExp _eskiRe = RegExp(r'<<<<<<<\s*ESK[İIi]');
  static final RegExp _markerLineRe = RegExp(r'^\s*(?:<{7}|>{7})|^\s*={7}\s*$', multiLine: true);
  static final RegExp _importRe = RegExp(
    r'''^\s*(?:import|export|part)\s+['"]([^'"\n]+)['"]''',
    multiLine: true,
  );
  static final RegExp _controlRe = RegExp(r'[\u0000-\u001f\u007f]');
  static final RegExp _badPathCharRe = RegExp(r'''[\s:*?"<>|~$`'\\]''');
  static final RegExp _longRunRe = RegExp(r'(.)\1{199,}', dotAll: true);

  static const Set<String> _sdkPackages = {'flutter', 'flutter_test', 'flutter_localizations'};

  static const Set<String> _dartLibs = {
    'async', 'collection', 'convert', 'core', 'developer', 'ffi', 'io', 'isolate', 'math',
    'typed_data', 'ui', 'html', 'js_interop', 'js_interop_unsafe', 'js_util', 'web_ui', 'nativewrappers',
  };

  static const Set<String> _forbiddenNames = {
    'pubspec.lock', 'key.properties', 'local.properties', 'google-services.json',
    'googleservice-info.plist', 'id_rsa', 'id_ed25519', 'id_ecdsa', 'secrets.json',
    'credentials.json', '.netrc', '.npmrc', 'keystore.properties',
  };

  static const List<String> _forbiddenExts = [
    '.pem', '.key', '.p12', '.pfx', '.jks', '.keystore', '.der', '.p8', '.mobileprovision',
  ];

  static final List<({String label, RegExp re})> _secretPatterns = [
    (label: 'Gemini anahtarı', re: RegExp(r'AIza[0-9A-Za-z_\-]{20,}')),
    (label: 'Groq anahtarı', re: RegExp(r'gsk_[0-9A-Za-z]{16,}')),
    (label: 'OpenRouter anahtarı', re: RegExp(r'sk-or-[0-9A-Za-z_\-]{8,}')),
    (label: 'API anahtarı (sk-)', re: RegExp(r'(?<![0-9A-Za-z])sk-[0-9A-Za-z_\-]{16,}')),
    (label: 'GitHub token', re: RegExp(r'github_pat_[0-9A-Za-z_]{16,}')),
    (label: 'GitHub token', re: RegExp(r'gh[pousr]_[0-9A-Za-z]{16,}')),
    (label: 'özel anahtar bloğu', re: RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----')),
    (
      label: 'sabit gizli değer',
      re: RegExp(
        r'''(?:password|passwd|secret|token|api[_-]?key|apikey)\w*["']?\s*[:=]\s*["'](?=[^"']*\d)(?=[^"']*[A-Za-z])[A-Za-z0-9_\-+=]{20,}["']''',
        caseSensitive: false,
      ),
    ),
  ];

  static final List<_Suspect> _suspects = [
    _Suspect(
      'süreç çalıştırma',
      RegExp(r'\bProcess\s*\.\s*(?:run|start|runSync)\b|\bIsolate\s*\.\s*spawnUri\b|dart:mirrors'),
      RegExp(r'süreç|process|komut|shell|çalıştır|exec', caseSensitive: false),
    ),
    _Suspect(
      'ağ erişimi',
      RegExp(
        r'\bHttpClient\s*\(|\bhttp\s*\.\s*(?:get|post|put|delete|patch|head|read|send)\s*\(|'
        r'\bSocket\s*\.\s*connect\b|\bWebSocket\s*\.\s*connect\b|\bRawSocket\b|\bHttpServer\b|\bDio\s*\(',
      ),
      RegExp(r'http|ağ\b|istek|network|api|sunucu|socket|bağlantı|indir|download', caseSensitive: false),
    ),
    _Suspect(
      'ortam değişkeni/dinamik çağrı',
      RegExp(r'\bPlatform\s*\.\s*environment\b|\bFunction\s*\.\s*apply\b'),
      RegExp(r'ortam|environment', caseSensitive: false),
    ),
  ];

  /// [rawOutput] (modelin ham yama çıktısı) üzerinde tüm kapıları çalıştırır.
  ///
  /// [scope]: bu turda değiştirilebilecek VAR OLAN dosyalar (`plan.paths`). Yeni dosyalar yalnızca
  /// lib/ veya test/ altında `.dart` olabilir. [finding]: analist bulgusu (şüpheli ekleme "ilgili"
  /// mi kararında kullanılır; boş olabilir). İstisna dahil her hata sonucu RED yapar.
  static GuardVerdict check(
    ProjectSnapshot snap, {
    required Set<String> scope,
    required String rawOutput,
    String finding = '',
    DevGuardLimits limits = const DevGuardLimits(),
  }) {
    try {
      return _check(snap, scope, rawOutput, finding, limits);
    } catch (e) {
      return GuardVerdict._(
        [GuardViolation(DevGate.internal, 'doğrulama sırasında iç hata (${e.runtimeType}); fail-closed')],
        const {},
        const [],
        0,
      );
    }
  }

  static GuardVerdict _check(
    ProjectSnapshot snap,
    Set<String> scope,
    String raw,
    String finding,
    DevGuardLimits lim,
  ) {
    final v = <GuardViolation>[];
    void add(String code, String detail, {String path = '', int? idx}) =>
        v.add(GuardViolation(code, detail, path: path, patchIndex: idx));
    GuardVerdict fail([int n = 0]) => GuardVerdict._(v, const {}, const [], n);

    // ---- G7 (çıktı düzeyi): boş / aşırı uzun / tekrar ----
    if (raw.trim().isEmpty) {
      add(DevGate.degenerate, 'boş çıktı');
      return fail();
    }
    if (raw.length > lim.maxOutputChars) {
      add(DevGate.degenerate, 'aşırı uzun çıktı (${raw.length} karakter)');
    }
    final deg = degenerateProblem(raw);
    if (deg != null) add(DevGate.degenerate, deg);

    // ---- G1: biçim ----
    final opens = _openRe.allMatches(raw).length;
    final closes = _closeRe.allMatches(raw).length;
    final patches = WorkflowRunner.parsePatches(raw);
    if (opens == 0) {
      add(DevGate.format, 'yama bloğu yok ("<<<<<<< DOSYA: yol" ile başlayan blok bulunamadı)');
      return fail(patches.length);
    }
    if (closes != opens) {
      add(
        DevGate.format,
        'bloklar kapatılmamış veya fazla kapanış var: $opens açılış, $closes kapanış (çıktı kesilmiş olabilir)',
      );
    }
    if (patches.length != opens) {
      add(DevGate.format, 'ayrıştırılamayan blok: $opens bloktan yalnızca ${patches.length} tanesi ayrıştırıldı');
    }
    if (patches.length > lim.maxPatches) {
      add(DevGate.size, 'çok fazla yama bloğu (${patches.length} > ${lim.maxPatches})');
    }
    final raws = <String>{};
    var dup = 0;
    for (final p in patches) {
      if (!raws.add(p.rawBlock.trim())) dup++;
    }
    if (dup > 0) add(DevGate.degenerate, 'aynı yama bloğu birden çok kez tekrarlanmış ($dup tekrar)');
    if (v.isNotEmpty) return fail(patches.length);

    // ---- Yama başına kapılar (G1/G2/G3/G4/G7) ve sıralı, BİREBİR uygulama ----
    final lowerPaths = <String>{for (final e in snap.paths) e.toLowerCase()};
    final ws = <String, String>{};
    final newFiles = <String>{};
    final poisoned = <String>{};
    final hunks = <GuardHunk>[];
    var diffChars = 0;
    for (var i = 0; i < patches.length; i++) {
      final p = patches[i];
      final path = DevReport.normalizePath(p.filePath);
      final pathProblem = _pathProblem(p.filePath, path, lim);
      if (pathProblem != null) {
        add(DevGate.path, pathProblem, path: path, idx: i);
        poisoned.add(path);
        continue;
      }
      if (poisoned.contains(path)) continue;
      if (_markerLineRe.hasMatch(p.newCode)) {
        add(DevGate.format, 'yeni kodda yama/çakışma işareti sızmış (<<<<<<<, =======, >>>>>>>)', path: path, idx: i);
        poisoned.add(path);
        continue;
      }
      if (p.newCode.length >= 300) {
        final d = degenerateProblem(p.newCode, minLines: 20, minUniqueRatio: 0.25);
        if (d != null) {
          add(DevGate.degenerate, 'yeni kod: $d', path: path, idx: i);
          poisoned.add(path);
          continue;
        }
      }

      if (p.isNewFile) {
        if (snap.has(path)) {
          add(DevGate.path, 'var olan dosya TAM bloğuyla değiştirilemez', path: path, idx: i);
        } else if (newFiles.contains(path)) {
          add(DevGate.path, 'aynı yeni dosya birden çok kez oluşturuluyor', path: path, idx: i);
        } else if (!(path.startsWith('lib/') || path.startsWith('test/')) || !path.endsWith('.dart')) {
          add(DevGate.path, 'yeni dosya yalnızca lib/ veya test/ altında .dart olabilir', path: path, idx: i);
        } else if (lowerPaths.contains(path.toLowerCase())) {
          add(DevGate.path, 'büyük/küçük harf farkıyla var olan bir dosyayla çakışıyor', path: path, idx: i);
        } else if (p.newCode.trim().isEmpty) {
          add(DevGate.format, 'boş dosya', path: path, idx: i);
        } else if (p.newCode.length > lim.maxNewFileChars) {
          add(DevGate.size, 'yeni dosya çok büyük (${p.newCode.length} karakter)', path: path, idx: i);
        } else {
          ws[path] = p.newCode;
          newFiles.add(path);
          lowerPaths.add(path.toLowerCase());
          diffChars += p.newCode.length;
          hunks.add(GuardHunk(path: path, oldText: '', newText: p.newCode, isNewFile: true));
          continue;
        }
        poisoned.add(path);
        continue;
      }

      // Var olan dosya: ESKİ/YENİ yaması.
      if (!snap.text.containsKey(path)) {
        add(DevGate.path, 'dosya projede yok veya metin dosyası değil', path: path, idx: i);
        poisoned.add(path);
        continue;
      }
      if (!scope.contains(path)) {
        add(DevGate.path, 'bu turun kapsamı dışında', path: path, idx: i);
        poisoned.add(path);
        continue;
      }
      if (!_eskiRe.hasMatch(p.rawBlock)) {
        add(DevGate.format, 'blokta "<<<<<<< ESKİ" işareti yok', path: path, idx: i);
        poisoned.add(path);
        continue;
      }
      final old = p.oldCode ?? '';
      if (old.trim().isEmpty) {
        add(DevGate.match, 'ESKİ blok boş', path: path, idx: i);
        poisoned.add(path);
        continue;
      }
      final cur = ws[path] ?? snap.text[path]!;
      final at = cur.indexOf(old);
      if (at < 0) {
        add(DevGate.match, 'ESKİ blok dosyada birebir eşleşmiyor', path: path, idx: i);
        poisoned.add(path);
        continue;
      }
      if (cur.indexOf(old, at + 1) >= 0) {
        add(DevGate.match, 'ESKİ blok dosyada birden çok yerde eşleşiyor (tek olmalı)', path: path, idx: i);
        poisoned.add(path);
        continue;
      }
      if (old.split('\n').length > lim.maxOldBlockLines) {
        add(DevGate.size, 'ESKİ blok çok uzun (> ${lim.maxOldBlockLines} satır)', path: path, idx: i);
        poisoned.add(path);
        continue;
      }
      if (old.length > 400 && p.newCode.trim().length * 5 < old.trim().length) {
        add(DevGate.size, 'şüpheli büyük silme', path: path, idx: i);
        poisoned.add(path);
        continue;
      }
      ws[path] = cur.substring(0, at) + p.newCode + cur.substring(at + old.length);
      diffChars += old.length + p.newCode.length;
      hunks.add(GuardHunk(path: path, oldText: old, newText: p.newCode, isNewFile: false));
    }

    final changed = <String, String>{};
    for (final e in ws.entries) {
      if (snap.text[e.key] != e.value) changed[e.key] = e.value;
    }
    if (changed.length > lim.maxChangedFiles) {
      add(DevGate.size, 'çok fazla dosya değişiyor (${changed.length} > ${lim.maxChangedFiles})');
    }
    if (diffChars > lim.maxDiffChars) {
      add(DevGate.size, 'diff çok büyük ($diffChars > ${lim.maxDiffChars} karakter)');
    }
    if (changed.isEmpty && v.isEmpty) {
      add(DevGate.format, 'yamalar hiçbir değişiklik üretmedi (boş işlem)');
    }

    // ---- Dosya düzeyi kapılar: G4, G5, G6, G8 ----
    for (final e in changed.entries) {
      _fileSize(snap, e.key, e.value, lim, add);
    }
    _g5(snap, changed, add);
    _g6(snap, changed, add);
    for (final e in changed.entries) {
      _g8(e.key, snap.text[e.key], e.value, finding, add);
    }

    if (v.isNotEmpty) return fail(patches.length);
    return GuardVerdict._(v, changed, hunks, patches.length);
  }

  // ---------------- G2 ----------------

  static String? _pathProblem(String rawPath, String path, DevGuardLimits lim) {
    final rawTrim = rawPath.trim();
    if (path.isEmpty) return 'boş yol';
    if (rawTrim.startsWith('/') || rawTrim.startsWith('\\') || RegExp(r'^[A-Za-z]:').hasMatch(rawTrim)) {
      return 'mutlak yol';
    }
    if (path.length > lim.maxPathLength) return 'yol çok uzun';
    if (path.contains('..')) return 'geçersiz yol (..)';
    if (_controlRe.hasMatch(path)) return 'yolda denetim karakteri var';
    if (_badPathCharRe.hasMatch(path)) return 'yolda geçersiz karakter var';
    final segs = path.split('/');
    for (final s in segs) {
      if (s.isEmpty || s == '.') return 'geçersiz yol parçası';
      final l = s.toLowerCase();
      if (l == '.git' || l == '.github' || l.startsWith('.git')) return 'yasak klasör/dosya (.git, .github)';
      if (l == '.dart_tool' || l == 'build') return 'üretilmiş klasör (build, .dart_tool)';
    }
    final name = segs.last.toLowerCase();
    if (_forbiddenNames.contains(name)) return 'yasak dosya ($name)';
    if (name == '.env' || name.startsWith('.env.')) return 'gizli dosya (.env)';
    for (final x in _forbiddenExts) {
      if (name.endsWith(x)) return 'gizli anahtar/sertifika dosyası ($x)';
    }
    return null;
  }

  // ---------------- G4 (dosya düzeyi) ----------------

  static void _fileSize(
    ProjectSnapshot snap,
    String path,
    String after,
    DevGuardLimits lim,
    void Function(String, String, {String path, int? idx}) add,
  ) {
    final before = snap.text[path];
    if (after.trim().isEmpty) {
      add(DevGate.size, 'dosya boşaldı', path: path);
      return;
    }
    if (before == null) return;
    if (before.length >= lim.minShrinkBaseChars && after.length < before.length * lim.minShrinkKeepRatio) {
      final pct = (100 - (after.length * 100 / before.length)).round();
      add(DevGate.size, 'dosya %$pct küçüldü (toplu silme şüphesi)', path: path);
    }
    final counts = <String, int>{};
    for (final l in after.split('\n')) {
      final t = l.trim();
      if (t.isEmpty) continue;
      counts[t] = (counts[t] ?? 0) + 1;
    }
    var removed = 0;
    for (final l in before.split('\n')) {
      final t = l.trim();
      if (t.isEmpty) continue;
      final c = counts[t] ?? 0;
      if (c > 0) {
        counts[t] = c - 1;
      } else {
        removed++;
      }
    }
    if (removed > lim.maxRemovedLinesPerFile) {
      add(DevGate.size, '$removed satır siliniyor (> ${lim.maxRemovedLinesPerFile}); toplu silme', path: path);
    }
  }

  // ---------------- G5 ----------------

  static void _g5(
    ProjectSnapshot snap,
    Map<String, String> changed,
    void Function(String, String, {String path, int? idx}) add,
  ) {
    final merged = ProjectSnapshot(
      name: snap.name,
      text: {...snap.text, ...changed},
      binary: snap.binary,
    );
    final dartAfter = <String, String>{
      for (final e in changed.entries)
        if (e.key.endsWith('.dart')) e.key: e.value,
    };
    final dartBefore = <String, String>{
      for (final e in dartAfter.entries)
        if (snap.text[e.key] != null) e.key: snap.text[e.key]!,
    };
    final now = dartAfter.isEmpty
        ? const <ProjectProblem>[]
        : FlutterProjectKit.check(dartAfter, base: merged);
    final was = dartBefore.isEmpty
        ? const <ProjectProblem>[]
        : FlutterProjectKit.check(dartBefore, base: snap);

    for (final e in dartAfter.entries) {
      final path = e.key;
      final before = snap.text[path];
      final balAfter = dartBalanceProblem(e.value);
      final balBefore = before == null ? null : dartBalanceProblem(before);
      if (balAfter != null && balBefore == null) {
        add(DevGate.regression, 'sözdizimi bozuldu: $balAfter', path: path);
      }
      // Denge mesajları satır numarası içerir; ayrı ele alındı, burada karşılaştırılmaz.
      bool keep(ProjectProblem pr) => pr.path == path && pr.message != balAfter && pr.message != balBefore;
      final nowMsgs = [for (final pr in now) if (keep(pr)) pr.message];
      final remaining = [for (final pr in was) if (keep(pr)) pr.message];
      final wasCount = remaining.length;
      final fresh = <String>[];
      for (final m in nowMsgs) {
        final idx = remaining.indexOf(m);
        if (idx >= 0) {
          remaining.removeAt(idx);
        } else {
          fresh.add(m);
        }
      }
      if (fresh.isNotEmpty) {
        add(
          DevGate.regression,
          'yeni hata: ${fresh.first} (hata sayısı $wasCount → ${nowMsgs.length})',
          path: path,
        );
      }
    }

    final pubAfter = changed['pubspec.yaml'];
    if (pubAfter != null) {
      final why = DevPatcher.regression(snap, 'pubspec.yaml', snap.text['pubspec.yaml'], pubAfter);
      if (why != null) add(DevGate.regression, why, path: 'pubspec.yaml');
    }
  }

  // ---------------- G6 ----------------

  static void _g6(
    ProjectSnapshot snap,
    Map<String, String> changed,
    void Function(String, String, {String path, int? idx}) add,
  ) {
    final mergedText = <String, String>{...snap.text, ...changed};
    final pub = mergedText['pubspec.yaml'];
    final own = pub == null
        ? null
        : RegExp(r'^name:\s*([A-Za-z0-9_]+)', multiLine: true).firstMatch(pub)?.group(1);
    final declared = _declaredDeps(pub);
    bool exists(String p) => mergedText.containsKey(p) || snap.binary.containsKey(p);

    for (final e in changed.entries) {
      final path = e.key;
      if (!path.endsWith('.dart')) continue;
      final before = snap.text[path];
      final beforeUris = before == null
          ? const <String>{}
          : {for (final m in _importRe.allMatches(before)) m.group(1)!};
      final seen = <String>{};
      for (final m in _importRe.allMatches(e.value)) {
        final uri = m.group(1)!;
        if (beforeUris.contains(uri) || !seen.add(uri)) continue;
        final problem = _importProblem(uri, path, own, declared, exists);
        if (problem != null) add(DevGate.imports, 'yeni import "$uri": $problem', path: path);
      }
    }

    final pubChanged = changed['pubspec.yaml'];
    if (pubChanged != null) {
      final removed = _declaredDeps(snap.text['pubspec.yaml']).difference(_declaredDeps(pubChanged))
        ..removeAll(_sdkPackages);
      for (final pkg in removed) {
        final needle = 'package:$pkg/';
        final user = mergedText.entries.where((e) => e.key.endsWith('.dart') && e.value.contains(needle));
        if (user.isNotEmpty) {
          add(
            DevGate.imports,
            'pubspec.yaml\'dan kaldırılan "$pkg" hâlâ import ediliyor (${user.first.key})',
            path: 'pubspec.yaml',
          );
        }
      }
    }
  }

  static String? _importProblem(
    String uri,
    String from,
    String? own,
    Set<String> declared,
    bool Function(String) exists,
  ) {
    if (uri.startsWith('dart:')) {
      final lib = uri.substring(5).split('/').first;
      return _dartLibs.contains(lib) ? null : 'bilinmeyen dart: kütüphanesi';
    }
    if (uri.startsWith('package:')) {
      final rest = uri.substring('package:'.length);
      final slash = rest.indexOf('/');
      if (slash <= 0) return 'geçersiz package: adresi';
      final pkg = rest.substring(0, slash);
      final inner = rest.substring(slash + 1);
      if (own != null && pkg == own) {
        return exists('lib/$inner') ? null : 'lib/$inner dosyası projede yok';
      }
      if (_sdkPackages.contains(pkg) || declared.contains(pkg)) return null;
      return '"$pkg" paketi pubspec.yaml içinde bildirilmemiş';
    }
    if (RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:').hasMatch(uri)) return 'desteklenmeyen adres türü';
    final dir = from.contains('/') ? from.substring(0, from.lastIndexOf('/')) : '';
    final target = _resolveRel(dir, uri);
    if (target == null) return 'proje kökünün dışına çıkıyor';
    return exists(target) ? null : '$target dosyası projede yok';
  }

  static String? _resolveRel(String dir, String rel) {
    final parts = <String>[...dir.split('/').where((e) => e.isNotEmpty)];
    for (final seg in rel.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isEmpty) return null;
        parts.removeLast();
      } else {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }

  static Set<String> _declaredDeps(String? pubspec) {
    final out = <String>{};
    if (pubspec == null) return out;
    var inBlock = false;
    for (final line in pubspec.split('\n')) {
      if (RegExp(r'^(dependencies|dev_dependencies|dependency_overrides)\s*:').hasMatch(line)) {
        inBlock = true;
        continue;
      }
      if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('\t') && !line.startsWith('#')) {
        inBlock = false;
        continue;
      }
      if (!inBlock) continue;
      final m = RegExp(r'^  ([A-Za-z0-9_]+)\s*:').firstMatch(line);
      if (m != null) out.add(m.group(1)!);
    }
    return out;
  }

  // ---------------- G7 ----------------

  /// Boş olmayan ama dejenere (aynı satırların/sözcüklerin sınırsız tekrarı) metni yakalar.
  /// Sorun yoksa null.
  static String? degenerateProblem(String t, {int minLines = 12, double minUniqueRatio = 0.3}) {
    final all = t.split('\n');
    final lines = <String>[
      for (final l in all)
        if (l.trim().length >= 8) l.trim(),
    ];
    if (lines.length >= minLines) {
      final uniq = lines.toSet().length;
      if (uniq / lines.length < minUniqueRatio) {
        return 'çıktı büyük ölçüde tekrar eden satırlardan oluşuyor (${lines.length} satırın $uniq tanesi farklı)';
      }
    }
    var run = 1;
    String? prev;
    for (final l in all) {
      final s = l.trim();
      if (s.length < 3) {
        run = 1;
        prev = null;
        continue;
      }
      if (s == prev) {
        run++;
        if (run >= 8) return 'aynı satır art arda $run kez tekrarlanmış';
      } else {
        run = 1;
        prev = s;
      }
    }
    final tokens = t.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (tokens.length >= 200) {
      final distinct = tokens.toSet().length;
      if (distinct / tokens.length < 0.05) {
        return 'sözcük çeşitliliği çok düşük ($distinct farklı / ${tokens.length} sözcük)';
      }
    }
    if (_longRunRe.hasMatch(t)) return 'aynı karakter 200+ kez art arda tekrarlanmış';
    return null;
  }

  // ---------------- G8 ----------------

  static List<String> _addedLines(String? before, String after) {
    final seen = <String>{
      if (before != null)
        for (final l in before.split('\n')) l.trim(),
    };
    final out = <String>[];
    for (final l in after.split('\n')) {
      final t = l.trim();
      if (t.isEmpty || seen.contains(t)) continue;
      out.add(t);
      if (out.length >= 3000) break;
    }
    return out;
  }

  static void _g8(
    String path,
    String? before,
    String after,
    String finding,
    void Function(String, String, {String path, int? idx}) add,
  ) {
    final added = _addedLines(before, after);
    if (added.isEmpty) return;
    final kinds = <String>{};
    for (final line in added) {
      for (final sp in _secretPatterns) {
        if (sp.re.hasMatch(line)) kinds.add(sp.label);
      }
    }
    for (final k in kinds) {
      add(DevGate.suspicious, 'sır benzeri dize eklendi ($k)', path: path);
    }
    for (final s in SecretMask.exportKnown()) {
      if (after.contains(s) && !(before?.contains(s) ?? false)) {
        add(DevGate.suspicious, 'kayıtlı bir sır koda ekleniyor', path: path);
        break;
      }
    }
    final addedText = added.join('\n');
    for (final s in _suspects) {
      if (!s.pattern.hasMatch(addedText)) continue;
      final alreadyUsed = before != null && s.pattern.hasMatch(before);
      final mentioned = finding.isNotEmpty && s.related.hasMatch(finding);
      if (alreadyUsed || mentioned) continue;
      add(
        DevGate.suspicious,
        '${s.label} ilgisiz bir yere eklenmiş (dosyada önceden yok, bulguda da geçmiyor)',
        path: path,
      );
    }
  }
}

// ======================= Doğrulayıcı (3. AI) =======================

/// Doğrulayıcı çıktısının ayrıştırılmış hâli. Yalnızca KATI biçimde ONAY ise [approved] true.
class VerifierVerdict {
  const VerifierVerdict({
    required this.approved,
    required this.parsed,
    this.reasons = const [],
    this.problem,
  });

  /// true yalnızca "KARAR: ONAY" katı biçimde, belirsizlik olmadan okunduysa.
  final bool approved;

  /// false: çıktı ayrıştırılamadı/belirsizdi (RED sayılır, kapı V2).
  final bool parsed;
  final List<String> reasons;
  final String? problem;

  /// Reddedildiyse kapı kodu (V1 açık RED, V2 ayrıştırılamadı); onayda boş.
  String get gate => approved ? '' : (parsed ? DevGate.verifierRed : DevGate.verifierUnparsable);

  String get summary => approved
      ? 'ONAY'
      : parsed
      ? 'RED: ${reasons.join(' / ')}'
      : 'RED (ayrıştırılamadı: ${problem ?? 'belirsiz'})';
}

/// Doğrulayıcı AI çıktısını ayrıştırır. Boş, belirsiz, çelişkili veya biçime uymayan her şey RED'dir.
///
/// ONAY için: ilk boş olmayan satır tam olarak `KARAR: ONAY` (yalnızca çevresinde `*`/`` ` `` süsü olabilir),
/// metinde tek bir KARAR ifadesi, en çok 3 gerekçe satırı (her biri `-`, `•` veya `*` ile başlar).
/// RED için: metinde herhangi bir yerde `KARAR: RED` geçmesi yeter (güvenli yön).
VerifierVerdict parseVerifier(String raw) {
  final text = raw.replaceAll('\r\n', '\n').trim();
  VerifierVerdict unparsed(String why) => VerifierVerdict(approved: false, parsed: false, problem: why);
  if (text.isEmpty) return unparsed('boş çıktı');

  List<String> reasonsOf(List<String> rest) {
    final out = <String>[];
    for (final l in rest.take(3)) {
      final c = SecretMask.redact(l.replaceFirst(RegExp(r'^[\-•*\s]+'), '').trim());
      out.add(c.length > 200 ? '${c.substring(0, 200)}…' : c);
    }
    return out;
  }

  final lines = [for (final l in text.split('\n')) if (l.trim().isNotEmpty) l.trim()];
  final kararRe = RegExp(r'KARAR\s*:', caseSensitive: false);
  final redRe = RegExp(r'KARAR\s*:\s*[*`\s]*RED\b', caseSensitive: false);
  final onayRe = RegExp(r'KARAR\s*:\s*[*`\s]*ONAY\b', caseSensitive: false);

  if (redRe.hasMatch(text)) {
    final idx = lines.indexWhere((l) => redRe.hasMatch(l));
    final rest = [for (var i = 0; i < lines.length; i++) if (i != idx) lines[i]];
    return VerifierVerdict(approved: false, parsed: true, reasons: reasonsOf(rest));
  }
  if (text.length > 2000) return unparsed('çıktı çok uzun');
  if (kararRe.allMatches(text).length != 1 || !onayRe.hasMatch(text)) {
    return unparsed('KARAR satırı yok, çok sayıda veya geçersiz');
  }
  final first = lines.first.replaceAll(RegExp(r'^[*`\s]+|[*`\s]+$'), '');
  if (first != 'KARAR: ONAY') return unparsed('ilk satır tam olarak "KARAR: ONAY" değil');
  final rest = lines.sublist(1);
  if (rest.length > 3) return unparsed('3\'ten fazla gerekçe satırı');
  for (final l in rest) {
    if (!RegExp(r'^[\-•*]\s*\S').hasMatch(l)) return unparsed('gerekçe satırı "-" ile başlamıyor');
  }
  return VerifierVerdict(approved: true, parsed: true, reasons: reasonsOf(rest));
}

/// Doğrulayıcı seçimi: yamayı yazan modelden FARKLI model (tercihen farklı sağlayıcı).
class VerifierChoice {
  const VerifierChoice(this.modelId, {required this.differentProvider});

  final String modelId;

  /// false: aynı sağlayıcının başka modeli seçildi (bağımsızlık daha zayıf).
  final bool differentProvider;
}

class VerifierPolicy {
  const VerifierPolicy._();

  /// Model kimliğinden sağlayıcıyı çıkarır (buluttaki `gemini`/`groq`/`openrouter`; yerel modeller kendi adıdır).
  /// `cloud-auto` bir yönlendiricidir: gerçek sağlayıcı bilinmez, 'auto' sayılır.
  static String providerOf(String id) {
    final s = id.trim().toLowerCase();
    if (s.isEmpty) return '';
    if (s == 'cloud-auto') return 'auto';
    final t = s.startsWith('cloud:') ? s.substring(6) : s;
    for (final n in const ['gemini', 'groq', 'openrouter']) {
      if (t == n || t.startsWith('$n:') || t.startsWith('$n/') || t.startsWith('$n-')) return n;
    }
    if (t.contains('gemini')) return 'gemini';
    if (t.endsWith(':free') || t.contains('/')) return 'openrouter';
    return t.split(RegExp(r'[:/]')).first;
  }

  /// [fixerModel]'den farklı bir doğrulayıcı seçer; uygun yoksa null (çağıran COMMIT ETMEMELİ).
  /// Sıra: farklı sağlayıcı > aynı sağlayıcının başka modeli; [avoid] (ör. güveni düşmüş modeller)
  /// yalnızca başka seçenek yoksa kullanılır. [providerOf] ile sağlayıcı çıkarımı değiştirilebilir.
  static VerifierChoice? chooseDetailed(
    String fixerModel,
    Iterable<String> candidates, {
    Set<String> avoid = const {},
    String Function(String)? providerOf,
  }) {
    final prov = providerOf ?? VerifierPolicy.providerOf;
    final fixer = fixerModel.trim().toLowerCase();
    final fixerProv = prov(fixerModel);
    final seen = <String>{};
    final avoidLower = {for (final a in avoid) a.trim().toLowerCase()};
    VerifierChoice? best;
    var bestScore = 1 << 30;
    for (final c in candidates) {
      final id = c.trim();
      final low = id.toLowerCase();
      if (id.isEmpty || low == fixer || !seen.add(low)) continue;
      final diff = prov(id) != fixerProv;
      final score = (diff ? 0 : 2) + (avoidLower.contains(low) ? 1 : 0);
      if (score < bestScore) {
        bestScore = score;
        best = VerifierChoice(id, differentProvider: diff);
      }
    }
    return best;
  }

  static String? choose(
    String fixerModel,
    Iterable<String> candidates, {
    Set<String> avoid = const {},
    String Function(String)? providerOf,
  }) => chooseDetailed(fixerModel, candidates, avoid: avoid, providerOf: providerOf)?.modelId;
}
