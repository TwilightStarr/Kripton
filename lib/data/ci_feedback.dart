// Değişiklik (Görev 3/10): yeni dosya. CI sonucunu (CiResult) AI'ya verilecek Türkçe metne çevirir,
// kararlı hata imzası üretir ve orkestratörün karar verdiği CiOutcome tiplerini tanımlar.
// Not: github_ci.dart ile döngüsel import vardır (CiResult <-> CiOutcome); Dart'ta geçerlidir.
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'github_ci.dart';

/// Kod hatası OLMAYAN (altyapı/ortam/yetki) sorunların nedeni. Bunlar ASLA AI'ya "düzelt" diye verilmez.
enum CiInfraReason {
  /// Depoda Actions kapalı.
  actionsDisabled,

  /// push tetiklemedi ve workflow_dispatch çalışmadı (iş akışı varsayılan dalda yok olabilir).
  workflowMissing,

  /// Çalışma açılmadı ya da kuyrukta runner beklenirken süre doldu.
  runnerNotStarted,

  /// Toplam bekleme ya da iş zaman aşımı.
  timeout,

  /// Token/yetki/depo bulunamadı (401/403/404).
  auth,

  /// Hız sınırı çok uzun sürecek.
  rateLimit,

  /// Ağ kopması süre dolana dek sürdü.
  network,

  /// Checkout/Java/Flutter kurulum adımı başarısız (Kripton aşamaları hiç başlamadı).
  setupFailed,

  /// Aşama başladı ama bitiş işaretçisi yok (runner kaybı/öldürme).
  stageInterrupted,

  /// Çalışma başlatılamadı (startup_failure: geçersiz iş akışı, faturalandırma vb.).
  startupFailure,

  /// İş günlüğü indirilemedi.
  logsUnavailable,

  /// Diğer.
  other,
}

/// Orkestratörün karar verdiği sonuç. `switch` ile kapsamlı işlenebilir.
sealed class CiOutcome {
  const CiOutcome({this.runUrl = '', this.sha = '', this.runId});

  final String runUrl;

  /// Denetlenen commit.
  final String sha;
  final int? runId;
}

/// Tüm aşamalar başarılı.
final class CiSuccess extends CiOutcome {
  const CiSuccess({super.runUrl, super.sha, super.runId, this.result});

  final CiResult? result;
}

/// Kod hatası: aşama kendi çıkış işaretçisiyle başarısız bitti. [feedback] AI'ya verilecek metin,
/// [signature] aynı hatanın tekrarını anlamak içindir.
final class CiFailure extends CiOutcome {
  const CiFailure({
    required this.signature,
    required this.feedback,
    required this.result,
    this.rawLogPath,
    super.runUrl,
    super.sha,
    super.runId,
  });

  final CiFailureSignature signature;
  final String feedback;
  final CiResult result;

  /// Maskelenmiş ham günlüğün diskteki yolu (kaydedilemediyse null).
  final String? rawLogPath;
}

/// Altyapı sorunu: kod hatası DEĞİL. AI'ya kod düzeltmesi yaptırılmaz; bekle/yeniden dene/kullanıcıya bildir.
final class CiInfraError extends CiOutcome {
  const CiInfraError({
    required this.reason,
    required this.message,
    this.rawLogPath,
    super.runUrl,
    super.sha,
    super.runId,
  });

  final CiInfraReason reason;

  /// Kullanıcıya gösterilebilir, maskelenmiş Türkçe açıklama.
  final String message;
  final String? rawLogPath;
}

/// Kullanıcı iptal etti ya da çalışma GitHub tarafında iptal edildi.
final class CiCancelled extends CiOutcome {
  const CiCancelled({this.message = '', super.runUrl, super.sha, super.runId});

  final String message;
}

/// Aynı hatayı tanıyan kararlı özet: aşama + sıralı (önem, kod/ileti, dosya) çiftleri ve sayıları.
/// SATIR/SÜTUN NUMARASI İÇERMEZ; böylece dosyada satırlar kaysa da aynı hata aynı imzayı verir.
class CiFailureSignature {
  CiFailureSignature._(this.stage, List<String> entries)
      : entries = List<String>.unmodifiable(entries),
        key = '$stage|${entries.join(';')}';

  /// [r] başarısız bir sonuç olmalı.
  factory CiFailureSignature.of(CiResult r) {
    final counts = <String, int>{};
    for (final d in r.diagnostics) {
      final what = d.code.isNotEmpty ? d.code : _normalizeMessage(d.message);
      final k = '${d.severity}:$what@${d.path}';
      counts[k] = (counts[k] ?? 0) + 1;
    }
    final entries = <String>[];
    if (counts.isEmpty) {
      entries.add('exit:${r.exitCode ?? '-'}');
      entries.add('tail:${_lastLineShape(r.stageLog)}');
    } else {
      final keys = counts.keys.toList()..sort();
      for (final k in keys) {
        entries.add('$k x${counts[k]}');
      }
    }
    return CiFailureSignature._(r.stage, entries);
  }

  final String stage;
  final List<String> entries;

  /// Karşılaştırma anahtarı.
  final String key;

  /// Kısa, kararlı kimlik (günlük/olay kaydı için).
  String get id => sha1.convert(utf8.encode(key)).toString().substring(0, 12);

  bool sameAs(CiFailureSignature other) => key == other.key;

  static String _normalizeMessage(String m) {
    final s = m.replaceAll(RegExp(r':\d+(?::\d+)?'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > 160 ? s.substring(0, 160) : s;
  }

  static String _lastLineShape(String log) {
    final lines = log.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return '';
    final s = lines.last.replaceAll(RegExp(r'\d+'), '#');
    return s.length > 120 ? s.substring(0, 120) : s;
  }

  @override
  bool operator ==(Object other) => other is CiFailureSignature && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'CiFailureSignature($id, $key)';
}

/// [CiFeedback.build] sonucu: metin + bütçe nedeniyle atılanların sayısı.
class CiFeedbackReport {
  const CiFeedbackReport({
    required this.text,
    this.droppedInfoLines = 0,
    this.droppedWarningGroups = 0,
    this.droppedRepeats = 0,
    this.droppedContextLines = 0,
    this.overBudget = false,
  });

  final String text;
  final int droppedInfoLines;
  final int droppedWarningGroups;
  final int droppedRepeats;
  final int droppedContextLines;

  /// Hata satırları tek başına bütçeyi aştı (hata satırları ASLA kırpılmaz).
  final bool overBudget;
}

class _Group {
  _Group(this.key);

  final String key;
  final List<CiDiagnostic> items = <CiDiagnostic>[];
  List<String> context = const <String>[];

  CiDiagnostic get first => items.first;
  bool get isError => first.severity == 'error';
}

/// CI sonucunu AI'ya verilecek metne çevirir.
class CiFeedback {
  const CiFeedback._();

  static const int defaultBudgetChars = 12000;

  static final RegExp _errorish = RegExp(
    r'(error|exception|failed|failure|fatal|hata|not found|cannot|could not|unable to)',
    caseSensitive: false,
  );

  static String forAi(CiResult r, {int budgetChars = defaultBudgetChars}) =>
      build(r, budgetChars: budgetChars).text;

  /// Bütçe aşılırsa sırayla: 1) info satırları, 2) uyarılar, 3) tekrarlar, 4) çevre satırları atılır.
  /// Hata (error) satırları ve ilk oluşumlarının ham çıktısı HİÇBİR koşulda kırpılmaz.
  static CiFeedbackReport build(CiResult r, {int budgetChars = defaultBudgetChars}) {
    if (r.ok) {
      return CiFeedbackReport(
        text: 'CI SONUCU: BAŞARILI${r.runUrl.isEmpty ? '' : '\nÇalışma: ${r.runUrl}'}',
      );
    }
    final groups = _groups(r.diagnostics);
    if (groups.isEmpty) return _unparsed(r, budgetChars);

    final lines = r.stageLog.split('\n');
    final rawSet = <String>{
      for (final d in r.diagnostics)
        for (final l in d.raw.split('\n'))
          if (l.trim().isNotEmpty) l.trimRight(),
    };
    for (final g in groups) {
      g.context = _context(lines, g.first, rawSet);
    }
    final infos = CiLogParser.infoLines(r.stageLog);
    final infoTotal = infos.length > r.infoCount ? infos.length : r.infoCount;
    var errs = 0;
    var warns = 0;
    for (final d in r.diagnostics) {
      if (d.severity == 'error') {
        errs++;
      } else {
        warns++;
      }
    }
    final byPath = <String, List<_Group>>{};
    for (final g in groups) {
      byPath.putIfAbsent(g.first.path, () => <_Group>[]).add(g);
    }
    final paths = byPath.keys.toList()..sort();

    CiFeedbackReport render(bool incInfo, bool incWarn, bool incRep, bool incCtx) {
      final b = StringBuffer();
      var dInfo = 0;
      var dWarn = 0;
      var dRep = 0;
      var dCtx = 0;
      b.writeln('CI SONUCU: BAŞARISIZ');
      b.writeln('Aşama: ${r.stage}${r.exitCode == null ? '' : ' (çıkış kodu ${r.exitCode})'}');
      if (r.runUrl.isNotEmpty) b.writeln('Çalışma: ${r.runUrl}');
      b.writeln('Özet: $errs hata, $warns uyarı, $infoTotal bilgi; ${paths.length} dosya, '
          '${groups.length} farklı sorun.');
      for (final path in paths) {
        final all = [...byPath[path]!]..sort((a, c) => a.first.line.compareTo(c.first.line));
        final visible = <_Group>[];
        for (final g in all) {
          if (g.isError || incWarn) {
            visible.add(g);
          } else {
            dWarn++;
          }
        }
        if (visible.isEmpty) continue;
        b.writeln();
        b.writeln('--- ${path.isEmpty ? '(dosya bilinmiyor)' : path} ---');
        for (final g in visible) {
          final f = g.first;
          b.writeln('[${f.severity == 'error' ? 'hata' : 'uyarı'}]'
              '${f.code.isEmpty ? '' : ' ${f.code}:'} ${f.message}');
          b.writeln('  konum: ${f.line}:${f.column}');
          b.writeln('  ham çıktı:');
          for (final l in f.raw.split('\n')) {
            b.writeln('    $l');
          }
          if (g.context.isNotEmpty) {
            if (incCtx) {
              b.writeln('  çevre satırlar:');
              for (final l in g.context) {
                b.writeln('    $l');
              }
            } else {
              dCtx += g.context.length;
            }
          }
          final rest = g.items.skip(1).toList();
          if (rest.isNotEmpty) {
            if (incRep) {
              for (final d in rest) {
                b.writeln('  tekrar: ${d.line}:${d.column}');
              }
            } else {
              dRep += rest.length;
              b.writeln('  (+${rest.length} tekrar)');
            }
          }
        }
      }
      if (infos.isNotEmpty) {
        if (incInfo) {
          b.writeln();
          b.writeln('--- bilgi satırları (${infos.length}) ---');
          for (final l in infos) {
            b.writeln(l);
          }
        } else {
          dInfo = infos.length;
        }
      }
      if (dInfo + dWarn + dRep + dCtx > 0) {
        final parts = <String>[
          if (dInfo > 0) '$dInfo bilgi satırı',
          if (dWarn > 0) '$dWarn uyarı',
          if (dRep > 0) '$dRep tekrar',
          if (dCtx > 0) '$dCtx çevre satırı',
        ];
        b.writeln();
        b.writeln('(bütçe nedeniyle atıldı: ${parts.join(', ')}; hata satırları eksiksizdir)');
      }
      final text = b.toString().trimRight();
      return CiFeedbackReport(
        text: text,
        droppedInfoLines: dInfo,
        droppedWarningGroups: dWarn,
        droppedRepeats: dRep,
        droppedContextLines: dCtx,
        overBudget: text.length > budgetChars,
      );
    }

    const steps = <List<bool>>[
      [true, true, true, true],
      [false, true, true, true],
      [false, false, true, true],
      [false, false, false, true],
      [false, false, false, false],
    ];
    late CiFeedbackReport last;
    for (final s in steps) {
      last = render(s[0], s[1], s[2], s[3]);
      if (!last.overBudget) return last;
    }
    return last;
  }

  static List<_Group> _groups(List<CiDiagnostic> diags) {
    final map = <String, _Group>{};
    for (final d in diags) {
      final k = '${d.severity}|${d.path}|${d.code}|${d.message}';
      map.putIfAbsent(k, () => _Group(k)).items.add(d);
    }
    return map.values.toList();
  }

  /// İlk oluşumun çevresindeki (başka bir sorunun parçası olmayan) ham log satırları.
  static List<String> _context(List<String> lines, CiDiagnostic d, Set<String> rawSet) {
    final rawLines = d.raw.split('\n');
    final first = rawLines.first.trimRight();
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trimRight() == first) {
        idx = i;
        break;
      }
    }
    if (idx < 0) return const <String>[];
    final out = <String>[];
    void take(int i) {
      if (i < 0 || i >= lines.length) return;
      final l = lines[i].trimRight();
      if (l.trim().isEmpty || rawSet.contains(l)) return;
      out.add(l);
    }

    take(idx - 2);
    take(idx - 1);
    take(idx + rawLines.length);
    take(idx + rawLines.length + 1);
    return out;
  }

  /// Ayrıştırılabilir hata yok: aşama çıktısı. Hata benzeri satırlar HİÇ atılmaz; kalan bütçe sondan doldurulur.
  static CiFeedbackReport _unparsed(CiResult r, int budget) {
    final head = StringBuffer()
      ..writeln('CI SONUCU: BAŞARISIZ')
      ..writeln('Aşama: ${r.stage}${r.exitCode == null ? '' : ' (çıkış kodu ${r.exitCode})'}');
    if (r.runUrl.isNotEmpty) head.writeln('Çalışma: ${r.runUrl}');
    head.writeln('Özet: dosya/satır bazlı hata ayrıştırılamadı; aşama çıktısı aşağıdadır.');
    head.writeln();
    final lines = r.stageLog.split('\n').map((l) => l.trimRight()).toList();
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    var remaining = budget - head.length;
    if (remaining < 400) remaining = 400;
    var total = 0;
    for (final l in lines) {
      total += l.length + 1;
    }
    final keep = <int>{};
    var dropped = 0;
    if (total <= remaining) {
      for (var i = 0; i < lines.length; i++) {
        keep.add(i);
      }
    } else {
      var used = 0;
      for (var i = 0; i < lines.length; i++) {
        if (_errorish.hasMatch(lines[i])) {
          keep.add(i);
          used += lines[i].length + 1;
        }
      }
      for (var i = lines.length - 1; i >= 0; i--) {
        if (keep.contains(i)) continue;
        final add = lines[i].length + 1;
        if (used + add > remaining) break;
        keep.add(i);
        used += add;
      }
      dropped = lines.length - keep.length;
    }
    final b = StringBuffer(head.toString());
    var gap = 0;
    for (var i = 0; i < lines.length; i++) {
      if (keep.contains(i)) {
        if (gap > 0) {
          b.writeln('[… $gap satır atıldı …]');
          gap = 0;
        }
        b.writeln(lines[i]);
      } else {
        gap++;
      }
    }
    if (gap > 0) b.writeln('[… $gap satır atıldı …]');
    final text = b.toString().trimRight();
    return CiFeedbackReport(
      text: text,
      droppedContextLines: dropped,
      overBudget: text.length > budget,
    );
  }
}
