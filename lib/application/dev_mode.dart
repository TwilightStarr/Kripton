import '../data/flutter_project_check.dart';
import '../data/project_snapshot.dart';
import 'workflow_runner.dart';

/// Kullanıcının girebileceği en yüksek tur sayısı (yerel modeller yavaştır; sonsuz döngü olmasın).
const kDevMaxRounds = 30;

/// "Tüm projeyi gez" modunda üst güvenlik sınırı (parça sayısı büyük projelerde 30'u aşar).
const kDevMaxStepsCoverAll = 400;

/// Geliştirme Modu girdileri: ZIP, tur sayısı ve hangi AI'ların çalışacağı.
class DevModeConfig {
  const DevModeConfig({
    required this.zipPath,
    required this.rounds,
    required this.analystModelId,
    required this.fixerModelId,
    this.coverAll = false,
    this.autonomous = false,
    this.goal = '',
    this.maxDuration = const Duration(hours: 24),
    this.startedAtMs,
    this.deadlineMs,
    this.resumeRound = 0,
    this.resumeFixed = 0,
    this.resumeStablePasses = 0,
    this.resumeImproving = false,
    this.flutterCi = false,
  });

  /// Flutter modu: GitHub Actions üzerinde GERÇEK `flutter analyze` / test / derleme çalıştırılır; araç
  /// çıktısı kırpılmadan 2. AI'ya verilir. Otonom modda proje kararlı sayılmadan önce temiz geçmelidir.
  final bool flutterCi;

  /// true ise (24 saate kadar) otonom çalışır: tur sayısı yok sayılır; hata kalmayana kadar
  /// projeyi tekrar tekrar gezer, hatalarda bekleyip yeniden dener, her turdan sonra kontrol
  /// noktası yazar (süreç ölse bile kaldığı yerden devam edilebilir).
  final bool autonomous;

  /// Otonom modda, proje kararlı olduktan sonra uygulanacak geliştirme hedefi (boş olabilir).
  final String goal;

  /// Otonom oturumun en uzun süresi (en çok 24 saat).
  final Duration maxDuration;

  /// Devam ettirilen oturumun özgün başlangıç/bitiş zamanı (ms); yoksa şimdiden hesaplanır.
  final int? startedAtMs;
  final int? deadlineMs;

  /// Devam ettirilen oturumdan taşınan sayaçlar.
  final int resumeRound;
  final int resumeFixed;
  final int resumeStablePasses;
  final bool resumeImproving;

  /// true ise [rounds] yok sayılır: bağlama sığan parçalar, projedeki her kaynak dosya baştan sona
  /// bir kez incelenene kadar (en çok [kDevMaxStepsCoverAll] adım) otomatik sürer. Her adım yine
  /// tek bir parçadır; böylece küçük bağlamlı modeller de TÜM projeyi görmüş olur.
  final bool coverAll;

  /// Geliştirilecek proje ZIP'i.
  final String zipPath;

  /// Kaç tur yapılacağı (1..[kDevMaxRounds]).
  final int rounds;

  /// 1. AI: hataları bulan model.
  final String analystModelId;

  /// 2. AI: bulunan hataları düzelten model.
  final String fixerModelId;
}

enum DevRoundStatus {
  /// Hata bulundu ve en az bir yama uygulandı.
  fixed,

  /// 1. AI bu parçada hata bulamadı.
  clean,

  /// Hata bulundu ama hiçbir yama uygulanamadı/doğrulanamadı.
  noPatch,

  /// Model çıktı üretemedi (hata).
  failed,
}

/// Bir turun kullanıcıya gösterilen sonucu.
class DevRoundResult {
  const DevRoundResult({
    required this.round,
    required this.status,
    this.reviewed = const [],
    this.findings = 0,
    this.changedFiles = const [],
    this.report = '',
    this.notes = const [],
  });

  final int round;
  final DevRoundStatus status;

  /// İncelenen parçalar (ör. `lib/main.dart:1-80`).
  final List<String> reviewed;
  final int findings;
  final List<String> changedFiles;

  /// 1. AI'nın ham raporu.
  final String report;

  /// Reddedilen/geri alınan yamalar ve diğer notlar.
  final List<String> notes;
}

/// Geliştirme Modu'nun ekranda görünen ilerlemesi.
class DevProgress {
  const DevProgress({
    this.active = false,
    this.total = 0,
    this.round = 0,
    this.phase = '',
    this.zipPath,
    this.sourceName = '',
    this.results = const [],
    this.autonomous = false,
    this.deadlineMs = 0,
    this.stablePasses = 0,
    this.improving = false,
    this.fixedTotal = 0,
  });

  /// Otonom (24 saatlik) oturum mu?
  final bool autonomous;

  /// Otonom oturumun bitiş zamanı (ms, epoch).
  final int deadlineMs;
  final int stablePasses;
  final bool improving;

  /// Oturum boyunca (devam ettirilenler dahil) düzeltme yapılan tur sayısı.
  final int fixedTotal;

  final bool active;
  final int total;
  final int round;

  /// Şu anki aşama: `1. AI analiz ediyor`, `2. AI düzeltiyor`, ...
  final String phase;

  /// Şimdiye kadarki en güncel proje ZIP'i (tur başarıyla değişiklik ürettiyse).
  final String? zipPath;
  final String sourceName;
  final List<DevRoundResult> results;

  int get fixedRounds => results.where((r) => r.status == DevRoundStatus.fixed).length;

  DevProgress copyWith({
    bool? active,
    int? total,
    int? round,
    String? phase,
    String? zipPath,
    String? sourceName,
    List<DevRoundResult>? results,
    int? stablePasses,
    bool? improving,
    int? fixedTotal,
  }) => DevProgress(
    active: active ?? this.active,
    total: total ?? this.total,
    round: round ?? this.round,
    phase: phase ?? this.phase,
    zipPath: zipPath ?? this.zipPath,
    sourceName: sourceName ?? this.sourceName,
    results: results ?? this.results,
    autonomous: autonomous,
    deadlineMs: deadlineMs,
    stablePasses: stablePasses ?? this.stablePasses,
    improving: improving ?? this.improving,
    fixedTotal: fixedTotal ?? this.fixedTotal,
  );
}

/// Bir dosyanın modele gösterilen bölümü.
class DevSegment {
  const DevSegment({
    required this.path,
    required this.startLine,
    required this.endLine,
    required this.totalLines,
    required this.text,
  });

  final String path;

  /// 0 tabanlı, başlangıç dahil.
  final int startLine;

  /// 0 tabanlı, bitiş hariç.
  final int endLine;
  final int totalLines;
  final String text;

  /// İnsan okunur etiket (1 tabanlı satır numaraları).
  String get label => '$path:${startLine + 1}-$endLine';
}

/// Bir turda incelenecek kod parçaları.
class DevRoundPlan {
  const DevRoundPlan(this.segments);

  final List<DevSegment> segments;

  Set<String> get paths => {for (final s in segments) s.path};

  List<String> get labels => [for (final s in segments) s.label];

  /// Modele verilen kod bloğu (yol + satır aralığı + ham kod).
  String get codeBlock {
    final b = StringBuffer();
    for (final s in segments) {
      b
        ..writeln('Dosya: ${s.path} (satır ${s.startLine + 1}-${s.endLine} / ${s.totalLines})')
        ..writeln('```')
        ..writeln(s.text)
        ..writeln('```')
        ..writeln();
    }
    return b.toString();
  }
}

/// Projeyi tur tur, modelin bağlamına sığan parçalara bölerek gezer.
///
/// Yerel modellerin bağlamı küçüktür; bütün proje tek seferde verilemez. Planlayıcı dosyaları
/// sırayla (pubspec → main → lib → test) küçük parçalar hâlinde sunar; düzeltme yapılan parça
/// bir kez daha denetlenir (doğrulama), sonra ilerlenir. Hepsi bitince başa sarar.
class DevPlanner {
  final Map<String, int> _cursor = {};
  final Map<String, int> _rechecked = {};

  /// Proje baştan sona kaç kez tamamen gezildi (her başa sarışta 1 artar).
  int passes = 0;

  /// Denetlenecek dosya mı? (Yalnızca kaynak: lib/ ve test/ altındaki Dart + pubspec.)
  static bool eligible(String path) =>
      path == 'pubspec.yaml' ||
      ((path.startsWith('lib/') || path.startsWith('test/')) && path.endsWith('.dart'));

  static int _rank(String p) => p == 'pubspec.yaml'
      ? 0
      : p == 'lib/main.dart'
      ? 1
      : p.startsWith('lib/')
      ? 2
      : 3;

  /// [snap] üzerinde bir sonraki incelenecek parçaları seçer; denetlenecek içerik yoksa null.
  /// [snap]'teki denetlenecek toplam karakter ve [chunkChars] ile gereken adım sayısının tahmini
  /// (düzeltilen parçaların yeniden denetimi için %25 pay dahil). En az 1.
  static int estimateSteps(ProjectSnapshot snap, {required int chunkChars}) {
    var chars = 0;
    for (final e in snap.text.entries) {
      if (eligible(e.key)) chars += e.value.length;
    }
    final per = chunkChars < 800 ? 800 : chunkChars;
    final base = (chars / per).ceil();
    final v = (base * 1.25).ceil();
    return v < 1 ? 1 : v;
  }

  /// [wrap] false ise her şey bir kez incelendiğinde başa sarmak yerine null döner
  /// ("tüm projeyi gez" modu bitişi).
  DevRoundPlan? plan(ProjectSnapshot snap, {required int chunkChars, bool wrap = true}) {
    final order = snap.text.keys.where(eligible).toList()
      ..sort((a, b) {
        final c = _rank(a).compareTo(_rank(b));
        return c != 0 ? c : a.compareTo(b);
      });
    final budget = chunkChars < 800 ? 800 : chunkChars;
    for (var pass = 0; pass < 2; pass++) {
      final segs = <DevSegment>[];
      var room = budget;
      for (final p in order) {
        final body = snap.text[p]!;
        if (body.trim().isEmpty) continue;
        final lines = body.split('\n');
        final start = _cursor[p] ?? 0;
        if (start >= lines.length) continue;
        if (segs.length >= 3 || (segs.isNotEmpty && room < 700)) break;
        final seg = _cut(p, lines, start, room);
        segs.add(seg);
        room -= seg.text.length;
        // Dosya bitmediyse bu tur yalnızca bu dosya (parça sınırı bütçeyle belirlendi).
        if (seg.endLine < lines.length) break;
      }
      if (segs.isNotEmpty) return DevRoundPlan(segs);
      if (!wrap) return null;
      // Her şey incelendi: başa sar ve ikinci geçişi dene.
      _cursor.clear();
      _rechecked.clear();
      passes++;
    }
    return null;
  }

  static DevSegment _cut(String path, List<String> lines, int start, int budget) {
    var end = start;
    var used = 0;
    while (end < lines.length) {
      final add = lines[end].length + 1;
      if (used + add > budget && end > start) break;
      used += add;
      end++;
    }
    if (end < lines.length) {
      // Fonksiyonu ortadan kesmemek için son 25 satırda boş satır ara.
      for (var i = end; i > start + 1 && i > end - 25; i--) {
        if (lines[i - 1].trim().isEmpty) {
          end = i;
          break;
        }
      }
    }
    return DevSegment(
      path: path,
      startLine: start,
      endLine: end,
      totalLines: lines.length,
      text: lines.sublist(start, end).join('\n'),
    );
  }

  /// Turdan sonra imleci ilerletir. [changedPaths] içindeki dosyaların parçası bir kez daha
  /// denetlenir (düzeltme yeni hata getirmiş olabilir); ikinci denetimden sonra ilerlenir.
  void advance(DevRoundPlan plan, {Set<String> changedPaths = const {}}) {
    for (final s in plan.segments) {
      final key = '${s.path}:${s.startLine}';
      if (changedPaths.contains(s.path) && (_rechecked[key] ?? 0) < 1) {
        _rechecked[key] = (_rechecked[key] ?? 0) + 1;
        continue;
      }
      _rechecked.remove(key);
      _cursor[s.path] = s.endLine;
    }
  }
}

/// 1. AI'nın bulduğu tek bir sorun.
class DevFinding {
  const DevFinding(this.path, this.text);

  final String path;
  final String text;
}

/// 1. AI'nın raporu, ayrıştırılmış hâliyle.
class DevReport {
  const DevReport({required this.findings, required this.dropped, required this.raw});

  /// Kapsamdaki (bu turda gösterilen dosyalara ait) geçerli sorunlar.
  final List<DevFinding> findings;

  /// Var olmayan veya kapsam dışı dosyaya işaret ettiği için atılan sorun sayısı.
  final int dropped;
  final String raw;

  bool get hasFindings => findings.isNotEmpty;

  static final RegExp _fileLine = RegExp(
    r'''^[\s>*\-\[\]\d.)#]*\**\s*Dosya\s*\**\s*:\s*\**\s*[`'"]?([^\s`'"*|,;]+)''',
    multiLine: true,
  );

  /// Dosya yolundaki gürültüyü (başta `./`, sonda noktalama) temizler.
  static String normalizePath(String raw) {
    var p = raw.trim().replaceAll('\\', '/');
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    // `lib/main.dart:12` veya `lib/main.dart:12-20` biçimindeki satır eklerini at.
    p = p.replaceFirst(RegExp(r':\d+(?:-\d+)?$'), '');
    while (p.isNotEmpty && '.,;:)'.contains(p[p.length - 1]) && !p.endsWith('.dart')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /// [raw] metnindeki `Dosya: yol` bloklarını ayrıştırır. Yalnızca [scope] içindeki ve
  /// [snap]'te gerçekten var olan dosyalara ait sorunlar tutulur (uydurma yollar atılır).
  static DevReport parse(String raw, ProjectSnapshot snap, {required Set<String> scope}) {
    final ms = _fileLine.allMatches(raw).toList();
    final out = <DevFinding>[];
    var dropped = 0;
    for (var i = 0; i < ms.length; i++) {
      final m = ms[i];
      final end = i + 1 < ms.length ? ms[i + 1].start : raw.length;
      final path = normalizePath(m.group(1) ?? '');
      final block = raw.substring(m.start, end).trim();
      if (path.isEmpty || !snap.text.containsKey(path) || !scope.contains(path)) {
        dropped++;
        continue;
      }
      out.add(DevFinding(path, block));
    }
    return DevReport(findings: out, dropped: dropped, raw: raw);
  }

  /// 2. AI'ya verilecek, uzunluğu sınırlı sorun listesi.
  String forFixer({int maxItems = 6, int maxChars = 1800}) {
    final b = StringBuffer();
    var n = 0;
    for (final f in findings) {
      if (n >= maxItems) break;
      var t = f.text;
      if (t.length > 450) t = '${t.substring(0, 450)}…';
      if (b.length + t.length > maxChars) break;
      b
        ..writeln('[${n + 1}] $t')
        ..writeln();
      n++;
    }
    return b.toString().trim();
  }
}

/// 1. AI (analiz) ve 2. AI (düzeltme) için prompt'lar.
class DevPrompts {
  const DevPrompts._();

  static const String analystSystem =
      'Sen kıdemli bir Flutter/Dart kod denetçisisin. Kod YAZMA, düzeltme YAPMA; yalnızca verilen koddaki '
      'GERÇEK sorunları bul: derleme hataları, null-safety, eksik veya yanlış import, await/async hataları, '
      'dispose edilmeyen controller/stream, try/catch eksikliği, hata fırlatabilecek yerler, mantık hataları, '
      'tanımsız fonksiyon veya değişken kullanımı.\n'
      'Kurallar:\n'
      '- Kod bir dosyanın BİR BÖLÜMÜdür; başı veya sonu kesik olabilir, bunu hata sayma.\n'
      '- Emin olmadığın şeyi yazma, uydurma. Yalnızca verilen kodda gördüğün sorunları yaz.\n'
      '- Tam dosya yolunu aynen kullan (verilen "Dosya:" satırındaki gibi).\n'
      '- En çok 6 sorun, önem sırasıyla. Her sorun şu biçimde olsun:\n'
      'Dosya: yol\n'
      'Yer: sınıf veya fonksiyon adı\n'
      'Sorun: ne yanlış ve neden\n'
      'Düzeltme: kısaca ne yapılmalı\n'
      '- Sorun bulamazsan yalnızca şunu yaz: [SORUN YOK]';

  static const String fixerSystem =
      'Sen uzman bir Flutter/Dart geliştiricisisin (Dart 3, null-safety, Material 3). Sana bir hata raporu ve '
      'ilgili kod verilir. Yalnızca raporda yazan sorunları düzelt; çalışan kodu bozma, stili ve adları koru, '
      'başka değişiklik yapma.\n'
      'Kurallar:\n'
      '- Dosyayı baştan yazma. Yalnızca yama blokları üret.\n'
      '- ESKİ bölümü verilen koddan BİREBİR (boşluk ve girinti dahil) kopyala; kısa tut (en çok ~15 satır).\n'
      '- Var olan dosyalar için TAM bloğu kullanma.\n'
      '- Uydurma paket API\'si kullanma; kullanılmayan import bırakma.\n'
      '- Yama bloklarının dışında açıklama yazma.';

  /// Proje kararlı olduktan sonra (hata kalmadığında) hedef doğrultusunda geliştirme önerir.
  /// Çıktı biçimi hata raporuyla AYNIDIR; böylece 2. AI aynı yoldan yama üretir.
  static const String improverSystem =
      'Sen kıdemli bir Flutter/Dart geliştiricisisin. Kod YAZMA; verilen kod bölümüne bakıp KULLANICI '
      'HEDEFİNE hizmet eden TEK bir somut, küçük ve güvenli iyileştirmeyi veya eksik özelliği öner.\n'
      'Kurallar:\n'
      '- Kod bir dosyanın BİR BÖLÜMÜdür; başı veya sonu kesik olabilir.\n'
      '- Çalışan kodu bozma; paket ekleme; yalnızca verilen bölümde yapılabilecek değişiklik öner.\n'
      '- Bu bölümde hedefe katkı yapacak bir şey yoksa yalnızca şunu yaz: [SORUN YOK]\n'
      '- Tam dosya yolunu aynen kullan. Biçim:\n'
      'Dosya: yol\n'
      'Yer: sınıf veya fonksiyon adı\n'
      'Sorun: eksik olan veya iyileştirilecek şey\n'
      'Düzeltme: kısaca ne yapılmalı';

  static String improverUser(ProjectSnapshot snap, DevRoundPlan plan, int round, String goal) {
    final deps = _depLine(snap);
    return 'TUR $round. KULLANICI HEDEFİ: $goal\n\n'
        'Projedeki dosyalar (import kontrolü için): ${_fileList(snap)}\n'
        '${deps.isEmpty ? '' : '$deps\n'}\n'
        'KOD:\n${plan.codeBlock}';
  }

  static String _depLine(ProjectSnapshot snap) {
    final pub = snap.text['pubspec.yaml'];
    if (pub == null) return '';
    final lines = pub.split('\n');
    final deps = <String>[];
    var inDeps = false;
    for (final l in lines) {
      if (RegExp(r'^(dependencies|dev_dependencies)\s*:').hasMatch(l)) {
        inDeps = true;
        continue;
      }
      if (inDeps && RegExp(r'^\S').hasMatch(l)) inDeps = false;
      final m = RegExp(r'^  ([a-z0-9_]+)\s*:').firstMatch(l);
      if (inDeps && m != null) deps.add(m.group(1)!);
    }
    return deps.isEmpty ? '' : 'Bildirilen bağımlılıklar: ${deps.join(', ')}';
  }

  static String _fileList(ProjectSnapshot snap, {int maxChars = 900}) {
    final b = StringBuffer();
    for (final p in snap.paths) {
      if (!p.endsWith('.dart') && p != 'pubspec.yaml') continue;
      if (b.length + p.length + 2 > maxChars) {
        b.write('…');
        break;
      }
      b.write('$p, ');
    }
    return b.toString();
  }

  /// 1. AI'ya giden kullanıcı metni.
  static String analystUser(ProjectSnapshot snap, DevRoundPlan plan, int round, int total) {
    final deps = _depLine(snap);
    return 'TUR $round/$total. Aşağıdaki kod bölümünü denetle ve sorunları bildir.\n\n'
        'Projedeki dosyalar (import kontrolü için): ${_fileList(snap)}\n'
        '${deps.isEmpty ? '' : '$deps\n'}\n'
        'KOD:\n${plan.codeBlock}';
  }

  /// Flutter modu: gerçek araç çıktısı ([toolOutput], hiç kırpılmadan) ile 2. AI'ya giden metin.
  static String ciFixerUser(DevRoundPlan plan, String toolOutput, String stage, {String? partLabel}) =>
      'GitHub Actions üzerinde GERÇEK "$stage" aşaması BAŞARISIZ oldu. Aşağıdaki araç çıktısı hiç '
      'kırpılmadan, aynen verilmiştir${partLabel == null ? '' : ' ($partLabel; çıktı uzun olduğu için bölündü)'}. '
      'Yalnızca bu çıktıdaki hataları düzelt.\n\n'
      'ARAÇ ÇIKTISI:\n$toolOutput\n\n'
      'KOD:\n${plan.codeBlock}\n'
      '${WorkflowRunner.patchFormatInstruction}';

  /// 2. AI'ya giden kullanıcı metni.
  static String fixerUser(DevRoundPlan plan, DevReport report) =>
      'AŞAĞIDAKİ HATA RAPORUNDAKİ sorunları düzelt.\n\n'
      'RAPOR:\n${report.forFixer()}\n\n'
      'KOD:\n${plan.codeBlock}\n'
      '${WorkflowRunner.patchFormatInstruction}';
}

/// 2. AI'nın yamalarının sonucu.
class DevPatchOutcome {
  const DevPatchOutcome({
    required this.changed,
    required this.applied,
    required this.rejected,
    required this.notes,
  });

  /// Doğrulamadan geçen ve değişen dosyalar (yol → TAM yeni içerik).
  final Map<String, String> changed;
  final int applied;
  final int rejected;
  final List<String> notes;
}

/// Yamaları güvenle uygular: kapsam, boyut ve derleme-regresyon denetimi yapar.
class DevPatcher {
  const DevPatcher._();

  static PatchBlock _withPath(PatchBlock p, String path) => path == p.filePath
      ? p
      : PatchBlock(
          filePath: path,
          isNewFile: p.isNewFile,
          oldCode: p.oldCode,
          newCode: p.newCode,
          rawBlock: p.rawBlock,
        );

  /// Yamayı reddetme nedeni; kabul edilebilirse null.
  static String? rejectReason(
    ProjectSnapshot snap,
    Set<String> allowed,
    PatchBlock p,
  ) {
    final path = p.filePath;
    if (path.isEmpty || path.contains('..')) return 'geçersiz yol';
    if (p.isNewFile) {
      if (snap.has(path)) return 'var olan dosya TAM bloğuyla değiştirilemez';
      if (!(path.startsWith('lib/') || path.startsWith('test/')) || !path.endsWith('.dart')) {
        return 'yeni dosya yalnızca lib/ veya test/ altında .dart olabilir';
      }
      if (p.newCode.trim().isEmpty) return 'boş dosya';
      return null;
    }
    if (!allowed.contains(path)) return 'bu turun kapsamı dışında';
    final old = p.oldCode ?? '';
    if (old.trim().isEmpty) return 'ESKİ blok boş';
    if (old.length > 400 && p.newCode.trim().length * 5 < old.trim().length) {
      return 'şüpheli büyük silme';
    }
    return null;
  }

  static String _retryPrompt(PatchBlock p, DevRoundPlan plan, String? error) =>
      'Aşağıdaki yama, koda birebir uymadığı için uygulanamadı (${error ?? 'eşleşmedi'}):\n'
      '${p.rawBlock}\n\n'
      'Güncel kod:\n${plan.codeBlock}\n'
      'Yalnızca bu yamayı, ESKİ bölüm yukarıdaki koddan BİREBİR kopyalanacak şekilde yeniden yaz:\n'
      '<<<<<<< DOSYA: ${p.filePath}\n<<<<<<< ESKİ\n(koddaki mevcut satırlar)\n=======\n(yeni kod)\n>>>>>>> YENİ';

  /// [patches]'i [snap] üzerinde uygular. [reinfer] verilirse eşleşmeyen yama için BİR kez
  /// yeniden istenir. İptal ([CancelledException]) yutulmaz.
  static Future<DevPatchOutcome> apply({
    required ProjectSnapshot snap,
    required DevRoundPlan plan,
    required List<PatchBlock> patches,
    Future<String> Function(String prompt)? reinfer,
  }) async {
    final notes = <String>[];
    final allowed = plan.paths;
    final ws = <String, String>{
      for (final p in allowed)
        if (snap.text[p] != null) p: snap.text[p]!,
    };
    var applied = 0;
    var rejected = 0;
    for (final raw in patches.take(12)) {
      final patch = _withPath(raw, DevReport.normalizePath(raw.filePath));
      final why = rejectReason(snap, allowed, patch);
      if (why != null) {
        rejected++;
        notes.add('Reddedildi (${patch.filePath}): $why');
        continue;
      }
      var r = WorkflowRunner.applyPatch(patch, ws);
      if (!r.success && reinfer != null && !patch.isNewFile) {
        try {
          final out = await reinfer(_retryPrompt(patch, plan, r.error));
          for (final rp0 in WorkflowRunner.parsePatches(out)) {
            final rp = _withPath(rp0, DevReport.normalizePath(rp0.filePath));
            if (rp.filePath != patch.filePath || rp.isNewFile) continue;
            if (rejectReason(snap, allowed, rp) != null) continue;
            final rr = WorkflowRunner.applyPatch(rp, ws);
            if (rr.success) {
              r = rr;
              break;
            }
          }
        } on CancelledException {
          rethrow;
        } catch (_) {
          // Yeniden deneme başarısız: yama aşağıda atlanır.
        }
      }
      if (r.success) {
        applied++;
      } else {
        rejected++;
        notes.add('Uygulanamadı (${patch.filePath}): ${r.error ?? 'eşleşmedi'}');
      }
    }
    final changed = <String, String>{};
    for (final e in ws.entries) {
      final before = snap.text[e.key];
      if (before == e.value) continue;
      final problem = regression(snap, e.key, before, e.value);
      if (problem != null) {
        rejected++;
        notes.add('Geri alındı (${e.key}): $problem');
        continue;
      }
      changed[e.key] = e.value;
    }
    return DevPatchOutcome(
      changed: changed,
      applied: applied,
      rejected: rejected,
      notes: notes,
    );
  }

  /// Yama sonrası içeriğin ÖNCEKİNDEN daha kötü olup olmadığını denetler (sözdizimi dengesi,
  /// çözülemeyen import, bozulmuş pubspec). Sorun yoksa null.
  static String? regression(
    ProjectSnapshot snap,
    String path,
    String? before,
    String after,
  ) {
    if (after.trim().isEmpty) return 'dosya boşaldı';
    if (path.endsWith('.dart')) {
      final bal = dartBalanceProblem(after);
      if (bal != null && (before == null || dartBalanceProblem(before) == null)) {
        return bal;
      }
      final now = FlutterProjectKit.check({path: after}, base: snap);
      final was = before == null
          ? const <ProjectProblem>[]
          : FlutterProjectKit.check({path: before}, base: snap);
      if (now.length > was.length) {
        final old = was.map((e) => e.message).toSet();
        final fresh = now.firstWhere((e) => !old.contains(e.message), orElse: () => now.first);
        return fresh.message;
      }
    }
    if (path == 'pubspec.yaml') {
      final ok =
          RegExp(r'^name:\s*\S+', multiLine: true).hasMatch(after) &&
          RegExp(r'^dependencies:', multiLine: true).hasMatch(after);
      if (!ok) return 'pubspec.yaml bozuldu (name/dependencies yok)';
    }
    return null;
  }
}
