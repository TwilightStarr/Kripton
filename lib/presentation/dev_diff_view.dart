// Görev 7/19 (Geliştirme Modu v2): yerel satır bazlı birleşik diff + görünümü.
//
// Ağ yok, paket yok: LCS tabanlıdır. Ortak ön ek/son ek önce kırpılır; kalan ortası yalnızca
// [DevDiffLimits.maxCells] hücreyi aşmıyorsa LCS ile hesaplanır, aşarsa "kaba" diff (ortanın tümü
// silindi + tümü eklendi) üretilir ve belirtilir. Çıktı en çok [DevDiffLimits.maxOutputLines] satırdır;
// fazlası kesilir ve belirtilir. Görüntülenen her satır SecretMask'ten geçer.

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/secret_mask.dart';

/// Diff satır türü.
enum DevDiffKind { context, added, removed, skipped }

/// Tek diff satırı. [skipped] satırında [text] boştur, [skippedCount] değişmeyen satır sayısıdır.
class DevDiffLine {
  const DevDiffLine({
    required this.kind,
    this.text = '',
    this.oldNo,
    this.newNo,
    this.skippedCount = 0,
  });

  final DevDiffKind kind;
  final String text;
  final int? oldNo;
  final int? newNo;
  final int skippedCount;
}

/// Diff sınırları.
class DevDiffLimits {
  const DevDiffLimits({
    this.maxCells = 2000000,
    this.maxOutputLines = 1500,
    this.contextLines = 3,
    this.maxLineChars = 600,
  });

  /// Ortak ön/son ek kırpıldıktan sonra LCS tablosunun azami hücre sayısı (n*m).
  final int maxCells;

  /// Gösterilecek en çok satır (değişmeyen satırları özetleyen "atlandı" satırları dahil).
  final int maxOutputLines;

  /// Değişikliğin çevresinde gösterilen değişmeyen satır sayısı.
  final int contextLines;

  /// Çok uzun satır bu kadar karaktere kesilir.
  final int maxLineChars;
}

/// [computeLineDiff] sonucu.
class DevDiffResult {
  const DevDiffResult({
    required this.lines,
    required this.added,
    required this.removed,
    this.truncated = false,
    this.hiddenChangedLines = 0,
    this.coarse = false,
  });

  final List<DevDiffLine> lines;

  /// Toplam eklenen/silinen satır sayısı (kesilmiş kısım dahil).
  final int added;
  final int removed;

  /// Çıktı [DevDiffLimits.maxOutputLines] sınırında kesildi.
  final bool truncated;

  /// Kesilmeyle gizlenen değişen (eklenen+silinen) satır sayısı.
  final int hiddenChangedLines;

  /// Dosya çok büyük olduğu için ince LCS yerine kaba karşılaştırma yapıldı.
  final bool coarse;

  bool get identical => added == 0 && removed == 0;
}

List<String> _splitLines(String? s) {
  if (s == null || s.isEmpty) return const <String>[];
  final parts = s.split('\n');
  if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
  for (var i = 0; i < parts.length; i++) {
    final l = parts[i];
    if (l.endsWith('\r')) parts[i] = l.substring(0, l.length - 1);
  }
  return parts;
}

/// [before] (null = dosya yoktu) ile [after] (null = dosya silindi) arasındaki satır diff'i.
/// Saf ve eşzamanlıdır; en kötü durumda ~[DevDiffLimits.maxCells] hücrelik tablo kurar.
DevDiffResult computeLineDiff(
  String? before,
  String? after, {
  DevDiffLimits limits = const DevDiffLimits(),
}) {
  final a = _splitLines(before);
  final b = _splitLines(after);

  var pre = 0;
  while (pre < a.length && pre < b.length && a[pre] == b[pre]) {
    pre++;
  }
  var suf = 0;
  while (suf < a.length - pre && suf < b.length - pre && a[a.length - 1 - suf] == b[b.length - 1 - suf]) {
    suf++;
  }
  final midA = a.length - pre - suf;
  final midB = b.length - pre - suf;

  // Düz işlem listesi: 0 = aynı, 1 = eklendi, 2 = silindi (indeksler a/b üzerinde).
  final kinds = <int>[];
  final aIdx = <int>[];
  final bIdx = <int>[];
  void op(int k, int ai, int bi) {
    kinds.add(k);
    aIdx.add(ai);
    bIdx.add(bi);
  }

  for (var i = 0; i < pre; i++) {
    op(0, i, i);
  }

  var coarse = false;
  if (midA == 0) {
    for (var j = 0; j < midB; j++) {
      op(1, -1, pre + j);
    }
  } else if (midB == 0) {
    for (var i = 0; i < midA; i++) {
      op(2, pre + i, -1);
    }
  } else if (midA * midB <= limits.maxCells) {
    final w = midB + 1;
    // dp[i][j] = a[pre+i..] ile b[pre+j..] arasındaki LCS uzunluğu.
    final dp = List<int>.filled((midA + 1) * w, 0);
    for (var i = midA - 1; i >= 0; i--) {
      final ai = a[pre + i];
      for (var j = midB - 1; j >= 0; j--) {
        if (ai == b[pre + j]) {
          dp[i * w + j] = dp[(i + 1) * w + j + 1] + 1;
        } else {
          final down = dp[(i + 1) * w + j];
          final right = dp[i * w + j + 1];
          dp[i * w + j] = down >= right ? down : right;
        }
      }
    }
    var i = 0;
    var j = 0;
    while (i < midA && j < midB) {
      if (a[pre + i] == b[pre + j]) {
        op(0, pre + i, pre + j);
        i++;
        j++;
      } else if (dp[(i + 1) * w + j] >= dp[i * w + j + 1]) {
        op(2, pre + i, -1);
        i++;
      } else {
        op(1, -1, pre + j);
        j++;
      }
    }
    while (i < midA) {
      op(2, pre + i, -1);
      i++;
    }
    while (j < midB) {
      op(1, -1, pre + j);
      j++;
    }
  } else {
    coarse = true;
    for (var i = 0; i < midA; i++) {
      op(2, pre + i, -1);
    }
    for (var j = 0; j < midB; j++) {
      op(1, -1, pre + j);
    }
  }

  for (var s = 0; s < suf; s++) {
    op(0, a.length - suf + s, b.length - suf + s);
  }

  var added = 0;
  var removed = 0;
  for (final k in kinds) {
    if (k == 1) added++;
    if (k == 2) removed++;
  }
  if (added == 0 && removed == 0) {
    return const DevDiffResult(lines: <DevDiffLine>[], added: 0, removed: 0);
  }

  // Değişikliğin çevresindeki bağlamı işaretle.
  final n = kinds.length;
  final keep = List<bool>.filled(n, false);
  final c = limits.contextLines < 0 ? 0 : limits.contextLines;
  for (var i = 0; i < n; i++) {
    if (kinds[i] == 0) continue;
    final lo = i - c < 0 ? 0 : i - c;
    final hi = i + c >= n ? n - 1 : i + c;
    for (var k = lo; k <= hi; k++) {
      keep[k] = true;
    }
  }

  String clip(String s) {
    final t = s.length > limits.maxLineChars ? '${s.substring(0, limits.maxLineChars)}…' : s;
    return SecretMask.redact(t);
  }

  final out = <DevDiffLine>[];
  var oldNo = 0;
  var newNo = 0;
  var skipRun = 0;
  var truncated = false;
  var hidden = 0;

  void flushSkip() {
    if (skipRun > 0) {
      out.add(DevDiffLine(kind: DevDiffKind.skipped, skippedCount: skipRun));
      skipRun = 0;
    }
  }

  for (var i = 0; i < n; i++) {
    final k = kinds[i];
    if (k != 1) oldNo++;
    if (k != 2) newNo++;
    if (truncated) {
      if (k != 0) hidden++;
      continue;
    }
    if (!keep[i]) {
      skipRun++;
      continue;
    }
    flushSkip();
    if (out.length >= limits.maxOutputLines) {
      truncated = true;
      if (k != 0) hidden++;
      continue;
    }
    switch (k) {
      case 0:
        out.add(DevDiffLine(kind: DevDiffKind.context, text: clip(a[aIdx[i]]), oldNo: oldNo, newNo: newNo));
      case 1:
        out.add(DevDiffLine(kind: DevDiffKind.added, text: clip(b[bIdx[i]]), newNo: newNo));
      default:
        out.add(DevDiffLine(kind: DevDiffKind.removed, text: clip(a[aIdx[i]]), oldNo: oldNo));
    }
  }
  if (!truncated) flushSkip();

  return DevDiffResult(
    lines: List<DevDiffLine>.unmodifiable(out),
    added: added,
    removed: removed,
    truncated: truncated,
    hiddenChangedLines: hidden,
    coarse: coarse,
  );
}

/// Birleşik diff görünümü: üstte özet, altında `ListView.builder`. Renk tek başına anlam taşımaz:
/// her satırın başında `+` / `−` işareti ve erişilebilirlik etiketi vardır.
class DevDiffView extends StatelessWidget {
  const DevDiffView({super.key, required this.diff, this.path = ''});

  final DevDiffResult diff;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Summary(diff: diff),
        const SizedBox(height: 6),
        Expanded(
          child: diff.identical
              ? Center(
                  child: Text(
                    'Fark yok (içerik aynı).',
                    style: TextStyle(fontSize: 12.5, color: KColors.muted),
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: KColors.codeBg,
                    borderRadius: BorderRadius.circular(KRadius.sm),
                    border: Border.all(color: KColors.border),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(KRadius.sm),
                    child: ListView.builder(
                      key: const ValueKey('dev-diff-list'),
                      itemCount: diff.lines.length + (diff.truncated ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i >= diff.lines.length) return _TruncatedRow(hidden: diff.hiddenChangedLines);
                        return _DiffRow(line: diff.lines[i]);
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.diff});

  final DevDiffResult diff;

  @override
  Widget build(BuildContext context) {
    final notes = <String>[
      if (diff.coarse) 'Dosya çok büyük: kaba karşılaştırma yapıldı.',
      if (diff.truncated) 'Diff çok büyük: ilk ${diff.lines.length} satır gösteriliyor.',
    ];
    return Semantics(
      container: true,
      label: '${diff.added} satır eklendi, ${diff.removed} satır silindi. ${notes.join(' ')}',
      child: ExcludeSemantics(
        child: Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '+${diff.added} eklendi',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: KColors.green),
            ),
            Text(
              '−${diff.removed} silindi',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: KColors.red),
            ),
            for (final n in notes) Text(n, style: TextStyle(fontSize: 12, color: KColors.amber)),
          ],
        ),
      ),
    );
  }
}

class _TruncatedRow extends StatelessWidget {
  const _TruncatedRow({required this.hidden});

  final int hidden;

  @override
  Widget build(BuildContext context) {
    final msg = hidden > 0 ? '… kesildi: $hidden değişen satır daha var' : '… kesildi';
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Text(msg, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: KColors.amber)),
    );
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.line});

  final DevDiffLine line;

  @override
  Widget build(BuildContext context) {
    if (line.kind == DevDiffKind.skipped) {
      return Semantics(
        label: '${line.skippedCount} değişmeyen satır atlandı',
        child: ExcludeSemantics(
          child: Container(
            color: KColors.card,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              '⋯ ${line.skippedCount} değişmeyen satır',
              style: TextStyle(fontSize: 11, color: KColors.muted, fontFamily: 'monospace'),
            ),
          ),
        ),
      );
    }
    final isAdd = line.kind == DevDiffKind.added;
    final isDel = line.kind == DevDiffKind.removed;
    final tint = isAdd ? KColors.green : (isDel ? KColors.red : null);
    final sign = isAdd ? '+' : (isDel ? '−' : ' ');
    final what = isAdd ? 'Eklendi' : (isDel ? 'Silindi' : 'Değişmedi');
    final no = line.newNo ?? line.oldNo;
    return Semantics(
      label: '$what${no == null ? '' : ', satır $no'}: ${line.text}',
      child: ExcludeSemantics(
        child: Container(
          color: tint?.withOpacity(0.14),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  line.oldNo?.toString() ?? '',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 10.5, color: KColors.muted, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 34,
                child: Text(
                  line.newNo?.toString() ?? '',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 10.5, color: KColors.muted, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 14,
                child: Text(
                  sign,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: tint ?? KColors.muted,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  line.text,
                  style: TextStyle(fontSize: 12, height: 1.3, color: KColors.text, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
