import '../data/github_ci.dart';
import '../data/project_snapshot.dart';
import 'dev_mode.dart';

/// 2. AI'ya tek seferde verilecek iş: bir dosyadaki kod penceresi + o pencereye ait araç çıktısı.
class CiBatch {
  const CiBatch({
    required this.plan,
    required this.toolOutput,
    required this.count,
    required this.path,
    this.partLabel,
  });

  /// Kod penceresi (tek parça). [DevPatcher] yalnızca bu dosyaya yama uygular.
  final DevRoundPlan plan;

  /// Araç çıktısı: AYNEN, hiçbir satırı kırpılmadan.
  final String toolOutput;

  /// Bu gruptaki sorun sayısı.
  final int count;
  final String path;

  /// Çok uzun tek bir çıktı bölündüyse "parça 2/3" gibi etiket.
  final String? partLabel;
}

/// [CiBatcher.plan] sonucu.
class CiPlan {
  const CiPlan({required this.batches, required this.unmatched});

  final List<CiBatch> batches;

  /// Projede bulunmayan bir dosyaya işaret eden sorunlar (çıktıları aynen günlüğe yazılır).
  final List<CiDiagnostic> unmatched;
}

/// Araç çıktısını modelin bağlamına sığacak gruplara böler. HİÇBİR sorun veya satır atılmaz:
/// sığmayan çıktı birden çok gruba (parçaya) bölünür.
class CiBatcher {
  const CiBatcher._();

  /// [budget]: kod penceresi için karakter sınırı ([WorkflowRunner.devChunkChars]); araç çıktısı için
  /// bunun %80'i kullanılır.
  static CiPlan plan(
    ProjectSnapshot snap,
    List<CiDiagnostic> diags, {
    required int budget,
    int contextBefore = 20,
  }) {
    final codeBudget = budget < 800 ? 800 : budget;
    final outBudget = (codeBudget * 0.8).floor();
    final byPath = <String, List<CiDiagnostic>>{};
    final unmatched = <CiDiagnostic>[];
    for (final d in diags) {
      final body = snap.text[d.path];
      if (d.path.isEmpty || body == null || body.trim().isEmpty) {
        unmatched.add(d);
        continue;
      }
      byPath.putIfAbsent(d.path, () => []).add(d);
    }
    final batches = <CiBatch>[];
    for (final e in byPath.entries) {
      final lines = snap.text[e.key]!.split('\n');
      final list = [...e.value]..sort((a, b) => a.line.compareTo(b.line));
      var i = 0;
      while (i < list.length) {
        final first = list[i];
        var errIdx = first.line - 1;
        if (errIdx < 0) errIdx = 0;
        if (errIdx >= lines.length) errIdx = lines.length - 1;
        var start = errIdx - contextBefore;
        if (start < 0) start = 0;
        var end = start;
        var used = 0;
        while (end < lines.length) {
          final add = lines[end].length + 1;
          if (used + add > codeBudget && end > errIdx) break;
          used += add;
          end++;
        }
        if (end <= errIdx) end = errIdx + 1;
        final seg = DevSegment(
          path: e.key,
          startLine: start,
          endLine: end,
          totalLines: lines.length,
          text: lines.sublist(start, end).join('\n'),
        );
        final plan = DevRoundPlan([seg]);

        // Tek sorunun çıktısı tek başına sınırı aşıyorsa satır satır parçalara bölünür.
        if (first.raw.length > outBudget) {
          final parts = splitLines(first.raw, outBudget);
          for (var k = 0; k < parts.length; k++) {
            batches.add(
              CiBatch(
                plan: plan,
                toolOutput: parts[k],
                count: 1,
                path: e.key,
                partLabel: 'parça ${k + 1}/${parts.length}',
              ),
            );
          }
          i++;
          continue;
        }

        final take = <CiDiagnostic>[first];
        var outLen = first.raw.length;
        var j = i + 1;
        while (j < list.length) {
          final d = list[j];
          final idx = d.line - 1;
          if (idx < start || idx >= end) break;
          if (d.raw.length > outBudget) break;
          if (outLen + 2 + d.raw.length > outBudget) break;
          take.add(d);
          outLen += 2 + d.raw.length;
          j++;
        }
        batches.add(
          CiBatch(
            plan: plan,
            toolOutput: take.map((d) => d.raw).join('\n\n'),
            count: take.length,
            path: e.key,
          ),
        );
        i = j;
      }
    }
    return CiPlan(batches: batches, unmatched: unmatched);
  }

  /// [text]'i en çok [max] karakterlik parçalara SATIR sınırlarında böler; hiçbir karakter atılmaz.
  /// Tek satır [max]'tan uzunsa o satır [max] uzunluğunda dilimlenir (yine kayıpsız).
  static List<String> splitLines(String text, int max) {
    final out = <String>[];
    final b = StringBuffer();
    var len = 0;
    void flush() {
      if (len > 0) out.add(b.toString());
      b.clear();
      len = 0;
    }

    for (final line in text.split('\n')) {
      var rest = line;
      while (rest.length > max) {
        flush();
        out.add(rest.substring(0, max));
        rest = rest.substring(max);
      }
      final add = rest.length + 1;
      if (len > 0 && len + add > max) flush();
      if (len > 0) b.write('\n');
      b.write(rest);
      len += add;
    }
    flush();
    return out.isEmpty ? [''] : out;
  }
}
