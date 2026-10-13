import '../data/flutter_project_check.dart';
import '../data/project_snapshot.dart';
import 'dev_mode.dart';

/// Otonom mod için varsayılan ve en yüksek süre: 24 saat.
const Duration kAutopilotMaxDuration = Duration(hours: 24);

/// Otonom modda adım sayısı için üst güvenlik sınırı (24 saatte bile sonsuz döngü olmasın).
const int kAutopilotMaxSteps = 20000;

/// Art arda bu kadar başarısız turdan sonra otonom mod pes eder (her hatadan sonra geri çekilme beklenir).
const int kAutopilotMaxFailStreak = 8;

/// Projenin kararlı sayılması için ardışık kaç TEMİZ tam geçiş gerektiği.
const int kAutopilotStablePasses = 2;

/// Kontrol noktası dosya adı (documents/ altında).
const String kAutopilotFile = 'autopilot.json';

/// Otonom oturumun diske yazılan durumu. Süreç öldürülse bile (bellek yetersizliği, sistem,
/// yeniden başlatma) uygulama açılınca KALDIĞI yerden devam edilebilir.
class AutopilotCheckpoint {
  const AutopilotCheckpoint({
    required this.zipPath,
    required this.analystModelId,
    required this.fixerModelId,
    required this.startedAtMs,
    required this.deadlineMs,
    this.goal = '',
    this.round = 0,
    this.fixedTotal = 0,
    this.stablePasses = 0,
    this.improving = false,
    this.updatedAtMs = 0,
    this.flutterCi = false,
  });

  /// Şu ana kadarki en güncel proje ZIP'i.
  final String zipPath;
  final String analystModelId;
  final String fixerModelId;
  final int startedAtMs;
  final int deadlineMs;

  /// Kullanıcının hedefi (boşsa yalnızca hata düzeltilir).
  final String goal;
  final int round;
  final int fixedTotal;
  final int stablePasses;

  /// Hata kalmadıktan sonra hedef doğrultusunda geliştirme aşamasında mı?
  final bool improving;
  final int updatedAtMs;

  /// Flutter modu (GitHub Actions denetimi) açık mıydı?
  final bool flutterCi;

  Duration remaining(DateTime now) {
    final left = deadlineMs - now.millisecondsSinceEpoch;
    return Duration(milliseconds: left < 0 ? 0 : left);
  }

  bool expired(DateTime now) => now.millisecondsSinceEpoch >= deadlineMs;

  AutopilotCheckpoint copyWith({
    String? zipPath,
    int? round,
    int? fixedTotal,
    int? stablePasses,
    bool? improving,
    int? updatedAtMs,
  }) => AutopilotCheckpoint(
    zipPath: zipPath ?? this.zipPath,
    analystModelId: analystModelId,
    fixerModelId: fixerModelId,
    startedAtMs: startedAtMs,
    deadlineMs: deadlineMs,
    goal: goal,
    round: round ?? this.round,
    fixedTotal: fixedTotal ?? this.fixedTotal,
    stablePasses: stablePasses ?? this.stablePasses,
    improving: improving ?? this.improving,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    flutterCi: flutterCi,
  );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'zipPath': zipPath,
    'analystModelId': analystModelId,
    'fixerModelId': fixerModelId,
    'startedAtMs': startedAtMs,
    'deadlineMs': deadlineMs,
    'goal': goal,
    'round': round,
    'fixedTotal': fixedTotal,
    'stablePasses': stablePasses,
    'improving': improving,
    'updatedAtMs': updatedAtMs,
    'flutterCi': flutterCi,
  };

  /// Bozuk/eksik veride null döner (kontrol noktası yok sayılır).
  static AutopilotCheckpoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final zip = m['zipPath'];
    final a = m['analystModelId'];
    final f = m['fixerModelId'];
    final started = (m['startedAtMs'] as num?)?.toInt();
    final deadline = (m['deadlineMs'] as num?)?.toInt();
    if (zip is! String || zip.isEmpty) return null;
    if (a is! String || f is! String || started == null || deadline == null) return null;
    int i(String k) => (m[k] as num?)?.toInt() ?? 0;
    return AutopilotCheckpoint(
      zipPath: zip,
      analystModelId: a,
      fixerModelId: f,
      startedAtMs: started,
      deadlineMs: deadline,
      goal: (m['goal'] as String?) ?? '',
      round: i('round'),
      fixedTotal: i('fixedTotal'),
      stablePasses: i('stablePasses'),
      improving: m['improving'] == true,
      updatedAtMs: i('updatedAtMs'),
      flutterCi: m['flutterCi'] == true,
    );
  }
}

/// Hata sonrası bekleme süreleri: 30 sn, 1 dk, 2 dk, 4 dk, 8 dk, ardından en çok 10 dk.
Duration autopilotBackoff(int failStreak) {
  if (failStreak <= 0) return Duration.zero;
  final secs = 30 * (1 << (failStreak > 6 ? 6 : failStreak - 1));
  return Duration(seconds: secs > 600 ? 600 : secs);
}

/// Android termal durumu (0..6) için soğuma gerekli mi? 3 = SEVERE ve üstü.
bool autopilotNeedsCooldown(int? thermalStatus) => thermalStatus != null && thermalStatus >= 3;

/// "3 sa 12 dk" gibi kısa süre metni.
String autopilotDurationText(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h > 0) return '$h sa $m dk';
  if (m > 0) return '$m dk';
  return '${d.inSeconds} sn';
}

/// Tam geçişleri sayar ve projenin kararlı (yakınsamış) olup olmadığına karar verir.
class AutopilotConvergence {
  AutopilotConvergence({this.stablePasses = 0});

  int stablePasses;
  int _passSeen = 0;
  int _fixedInPass = 0;
  int _problemsInPass = 0;

  /// Bir tur sonucunu işler.
  void recordRound({required int fixed, required int deterministicProblems}) {
    _fixedInPass += fixed;
    _problemsInPass += deterministicProblems;
  }

  /// Planlayıcı başa sardıysa (yeni tam geçiş) geçişi değerlendirir. Yeni geçiş başladıysa true.
  bool onPass(int plannerPasses) {
    if (plannerPasses == _passSeen) return false;
    _passSeen = plannerPasses;
    if (_fixedInPass == 0 && _problemsInPass == 0) {
      stablePasses++;
    } else {
      stablePasses = 0;
    }
    _fixedInPass = 0;
    _problemsInPass = 0;
    return true;
  }

  bool get stable => stablePasses >= kAutopilotStablePasses;
}

/// Yerel (kesin) denetimin bulduğu sorunlardan 2. AI'ya verilecek bulgular üretir.
/// Model uydurmaz: derleme/çalışmayı bozan sorunlar [FlutterProjectKit] ile bulunur.
class AutopilotChecks {
  const AutopilotChecks._();

  /// [paths] içindeki .dart dosyalarını TÜM proje bağlamında denetler.
  static List<ProjectProblem> problemsFor(ProjectSnapshot snap, Set<String> paths) {
    final gen = <String, String>{
      for (final p in paths)
        if (p.endsWith('.dart') && snap.text[p] != null) p: snap.text[p]!,
    };
    if (gen.isEmpty) return const [];
    try {
      return FlutterProjectKit.check(gen, base: snap);
    } catch (_) {
      return const [];
    }
  }

  static List<DevFinding> toFindings(List<ProjectProblem> problems, {int max = 6}) {
    final out = <DevFinding>[];
    for (final p in problems) {
      if (out.length >= max) break;
      if (p.path.isEmpty) continue;
      out.add(
        DevFinding(
          p.path,
          'Dosya: ${p.path}\n'
          'Yer: (yerel denetim)\n'
          'Sorun: ${p.message}\n'
          'Düzeltme: Bu sorunu gider; çalışan kodu bozma.',
        ),
      );
    }
    return out;
  }
}
