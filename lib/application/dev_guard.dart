// lib/application/dev_guard.dart
import '../data/flutter_project_check.dart';
import '../data/project_snapshot.dart';
import '../data/secret_mask.dart';
import 'dev_mode.dart';
import 'workflow_runner.dart';

// Değişiklik: Kimi çıktısı projeye yerleştirildi; G5/G6 taban anlık görüntüyle, \b ve replaceFirst düzeltmeleri.
/// Doğrulama ihlali: tek bir kapının tek gerekçesi. [detail] her zaman redact edilmiştir.
class GuardViolation {
  const GuardViolation({required this.gate, required this.detail, this.path = ''});

  /// Kapı kodu: G1..G8.
  final String gate;
  final String path;
  final String detail;

  @override
  String toString() => '[$gate] ${path.isEmpty ? '' : '$path: '}$detail';
}

/// Doğrulama kararı. [violations] boşsa geçer (ok). Hiçbir geçersiz çıktı ok döndüremez (fail-closed).
class GuardVerdict {
  const GuardVerdict(this.violations);

  final List<GuardViolation> violations;

  bool get ok => violations.isEmpty;
}

typedef GuardRecorder = void Function(GuardViolation violation);

/// Kapı kodlarının kısa Türkçe açıklamaları (hata defteri dersleri ve raporlar için).
const kGateDescriptions = <String, String>{
  'G1': 'Çıktı biçimi geçersiz',
  'G2': 'Kapsam dışı veya yasak dosya',
  'G3': 'ESKİ blok birebir ve tek kez eşleşmedi',
  'G4': 'Toplu silme / aşırı büyük değişiklik',
  'G5': 'Sözdizimi veya regresyon kötüleşti',
  'G6': 'Çözülemeyen import / paket',
  'G7': 'Dejenere, tekrarlı veya boş çıktı',
  'G8': 'Sır benzeri dize veya şüpheli çağrı eklendi',
};

/// Geliştirme Modu v2 doğrulama kapıları. AI saçmalarsa kod ASLA geçemez.
class DevGuard {
  const DevGuard._();

  static const int maxPatches = 12;
  static const int maxDiffChars = 64 * 1024;
  static const int maxResultFileChars = 400 * 1024;

  static const _forbiddenExact = {'pubspec.lock'};
  static const _forbiddenPrefixes = ['.git/', '.github/'];

  // Not: sondaki \b kaldırıldı; "HttpClient()" gibi "(" ile biten kalıplar \b ile hiç eşleşmiyordu.
  static final RegExp _suspicious = RegExp(
    r'\b(?:Process\.(?:start|run)|HttpClient\s*\(|Socket\.connect|eval\s*\(|child_process|Runtime\.getRuntime)',
  );

  /// Üretilen çıktıyı tüm kapılardan geçirir. [record] verilirse her ihlal kaydedilir (DevLedger).
  static GuardVerdict check(
    ProjectSnapshot snap,
    DevRoundPlan plan,
    String rawOutput, {
    GuardRecorder? record,
  }) =>
      checkFiles(files: snap.text, scope: plan.paths, rawOutput: rawOutput, record: record, base: snap);

  /// [check]'in saf çekirdeği: dosya içerikleri + kapsam + ham model çıktısı.
  static GuardVerdict checkFiles({
    required Map<String, String> files,
    required Set<String> scope,
    required String rawOutput,
    GuardRecorder? record,
    ProjectSnapshot? base,
  }) {
    // G5/G6 denetimi pubspec'i görebilsin diye tüm dosya kümesi taban anlık görüntü olarak verilir.
    final baseSnap = base ?? ProjectSnapshot(name: 'guard', text: files);
    final v = <GuardViolation>[];
    void add(String gate, String detail, [String path = '']) {
      final viol = GuardViolation(gate: gate, path: path, detail: SecretMask.redact(detail));
      v.add(viol);
      record?.call(viol);
    }

    final text = rawOutput.trim();

    // G7: boş çıktı (fail-closed: erken RED).
    if (text.isEmpty) {
      add('G7', 'Boş çıktı.');
      return GuardVerdict(v);
    }

    // G7: dejenere / sınırsız tekrar.
    final deg = degenerateProblem(text);
    if (deg != null) {
      add('G7', deg);
      return GuardVerdict(v);
    }

    // G1: çıktı biçimi geçerli mi?
    List<PatchBlock> patches;
    try {
      patches = WorkflowRunner.parsePatches(text);
    } catch (e) {
      add('G1', 'Yama ayrıştırılamadı: $e');
      return GuardVerdict(v);
    }
    if (patches.isEmpty) {
      add('G1', 'Yama bloğu bulunamadı; ESKİ/YENİ biçimi bekleniyor.');
      return GuardVerdict(v);
    }
    if (patches.length > maxPatches) {
      add('G4', 'Tek çıktıda ${patches.length} yama var (en çok $maxPatches).');
    }

    final ws = <String, String>{
      for (final p in scope)
        if (files[p] != null) p: files[p]!,
    };
    var totalAdded = 0;

    for (final raw in patches) {
      final p = _withPath(raw, DevReport.normalizePath(raw.filePath));
      final path = p.filePath;

      // G2: yol var / kapsamda / yasak değil.
      final pWhy = pathProblem(path, files, scope, isNew: p.isNewFile);
      if (pWhy != null) {
        add('G2', pWhy, path);
        continue;
      }

      final beforeContent = files[path]!;
      String afterContent;
      if (!p.isNewFile) {
        // G3: ESKİ blok birebir ve tek kez eşleşir.
        final m = matchProblem(beforeContent, p.oldCode ?? '');
        if (m != null) {
          add('G3', m, path);
          continue;
        }
        // G4: şüpheli büyük silme.
        final old = p.oldCode!;
        if (old.length > 400 && p.newCode.trim().length * 5 < old.trim().length) {
          add('G4', 'Şüpheli büyük silme (ESKİ ${old.trim().length} karakter, YENİ çok kısa).', path);
        }
        final at = beforeContent.indexOf(old); // G3 tek eşleşmeyi garanti etti
        afterContent = beforeContent.substring(0, at) + p.newCode + beforeContent.substring(at + old.length);
      } else {
        afterContent = p.newCode;
      }
      ws[path] = afterContent;
      totalAdded += p.newCode.length;

      // G8: sır benzeri dize / şüpheli çağrı ekleme (yalnızca gerçekten eklenen satırlarda).
      for (final line in p.newCode.split('\n')) {
        final t = line.trim();
        if (t.isEmpty || beforeContent.contains(line)) continue;
        if (SecretMask.redact(line) != line) {
          add('G8', 'Sır benzeri dize eklenmiş satır.', path);
        }
        // Dosyada zaten aynı türde çağrı varsa yeni eklenen sayılmaz (mevcut kalıp serbest).
        if (_suspicious.hasMatch(t) && !_suspicious.hasMatch(beforeContent)) {
          add('G8', 'Şüpheli sistem/ağrı çağrısı eklenmiş satır: $t', path);
        }
      }
    }

    // G4: toplam diff boyutu.
    if (totalAdded > maxDiffChars) {
      add('G4', 'Tek turda $totalAdded karakter ekleniyor (sınır $maxDiffChars).');
    }

    // G5/G6: uygulanmış hâli üzerinden sözdizimi + import/regresyon denetimi.
    for (final e in ws.entries) {
      final before = files[e.key];
      if (before == null || before == e.value) continue;
      final path = e.key;
      final after = e.value;
      if (after.trim().isEmpty) {
        add('G4', 'Dosya boşaltıldı.', path);
        continue;
      }
      if (after.length > maxResultFileChars) {
        add('G4', 'Sonuç dosyası ${after.length} karakter (sınır $maxResultFileChars).', path);
        continue;
      }
      if (path.endsWith('.dart')) {
        final bBal = dartBalanceProblem(before);
        final aBal = dartBalanceProblem(after);
        if (aBal != null && aBal != bBal) {
          add('G5', 'Parantez/sözdizimi bozuldu: $aBal', path);
        }
        final bChk = FlutterProjectKit.check({path: before}, base: baseSnap);
        final aChk = FlutterProjectKit.check({path: after}, base: baseSnap);
        if (aChk.length > bChk.length) {
          final oldMsgs = bChk.map((x) => x.message).toSet();
          for (final pr in aChk) {
            if (oldMsgs.contains(pr.message)) continue;
            final msg = pr.message;
            if (msg.contains('import') || msg.contains('paket') || msg.contains('Import')) {
              add('G6', msg, path);
            } else {
              add('G5', msg, path);
            }
          }
        }
      }
      if (path == 'pubspec.yaml') {
        final ok = RegExp(r'^name:\s*\S+', multiLine: true).hasMatch(after) &&
            RegExp(r'^dependencies:', multiLine: true).hasMatch(after);
        if (!ok) add('G5', 'pubspec.yaml bozuldu (name/dependencies yok).', path);
      }
    }

    return GuardVerdict(v);
  }

  /// G2 çekirdeği: yol geçerliyse null, değilse Türkçe neden.
  static String? pathProblem(
    String path,
    Map<String, String> files,
    Set<String> scope, {
    required bool isNew,
  }) {
    if (path.isEmpty) return 'Boş dosya yolu.';
    if (path.contains('..')) return 'Yol ".." içeriyor.';
    if (path.startsWith('/') || path.startsWith('\\')) return 'Mutlak yol reddedildi.';
    if (path.contains('\\')) return 'Yol ayraçları "/" olmalı.';
    if (path.split('/').any((s) => s.startsWith('.'))) return 'Gizli/yasak dosya veya dizin.';
    if (_forbiddenExact.contains(path)) return 'Yasak dosya: $path.';
    for (final pre in _forbiddenPrefixes) {
      if (path == pre.substring(0, pre.length - 1) || path.startsWith(pre)) {
        return 'Yasak konum: $pre.';
      }
    }
    if (isNew) {
      if (files.containsKey(path)) return 'Var olan dosya yeni-dosya bloğuyla verilemez.';
      if (!(path.startsWith('lib/') || path.startsWith('test/')) || !path.endsWith('.dart')) {
        return 'Yeni dosya yalnızca lib/ veya test/ altında .dart olabilir.';
      }
      return null;
    }
    if (!files.containsKey(path)) return 'Dosya projede yok (uydurma yol).';
    if (!scope.contains(path)) return 'Bu turun kapsamı dışında.';
    return null;
  }

  /// G3 çekirdeği: [old] bloğu [content] içinde birebir ve tek kez mi?
  static String? matchProblem(String content, String old) {
    if (old.trim().isEmpty) return 'ESKİ blok boş.';
    var count = 0;
    var idx = 0;
    while (count < 2) {
      final i = content.indexOf(old, idx);
      if (i < 0) break;
      count++;
      idx = i + 1;
    }
    if (count == 0) return 'ESKİ blok dosyada birebir eşleşmedi.';
    if (count > 1) return 'ESKİ blok dosyada $count kez eşleşti; tek eşleşme olmalı.';
    return null;
  }

  /// G7 çekirdeği: dejenere/tekrarlı çıktı varsa kısa açıklama, yoksa null.
  static String? degenerateProblem(String text) {
    if (text.length < 20 && !text.contains('<<<<<<<')) return 'Çıktı çok kısa.';
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.length < 8) return null;
    final counts = <String, int>{};
    for (final l in lines) {
      final t = l.trim();
      counts[t] = (counts[t] ?? 0) + 1;
    }
    var maxRepeat = 0;
    for (final c in counts.values) {
      if (c > maxRepeat) maxRepeat = c;
    }
    if (maxRepeat >= 12) return 'Aynı satır $maxRepeat kez tekrarlanmış (dejenere çıktı).';
    if (counts.length / lines.length < 0.2) {
      return 'Çıktı neredeyse tamamen tekrar eden içerik.';
    }
    return null;
  }

  static PatchBlock _withPath(PatchBlock p, String path) => path == p.filePath
      ? p
      : PatchBlock(
          filePath: path,
          isNewFile: p.isNewFile,
          oldCode: p.oldCode,
          newCode: p.newCode,
          rawBlock: p.rawBlock,
        );
}