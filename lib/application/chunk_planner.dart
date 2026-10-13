import 'dart:math';

/// Ajanların işlemesi için tek bir iş birimini (parçayı) temsil eder.
class WorkUnit {
  final String filePath;
  final int startLine; // 1-indeksli
  final int endLine; // 1-indeksli, dahil
  final String content;
  final int unitIndex; // 1-indeksli
  final int totalUnits;

  const WorkUnit({
    required this.filePath,
    required this.startLine,
    required this.endLine,
    required this.content,
    required this.unitIndex,
    required this.totalUnits,
  });

  /// UI ve log için durum satırı formatı:
  /// "Parça 3/12 · lib/main.dart satır 1-120"
  String get statusLine =>
      'Parça $unitIndex/$totalUnits · $filePath satır $startLine-$endLine';

  WorkUnit copyWith({
    String? filePath,
    int? startLine,
    int? endLine,
    String? content,
    int? unitIndex,
    int? totalUnits,
  }) {
    return WorkUnit(
      filePath: filePath ?? this.filePath,
      startLine: startLine ?? this.startLine,
      endLine: endLine ?? this.endLine,
      content: content ?? this.content,
      unitIndex: unitIndex ?? this.unitIndex,
      totalUnits: totalUnits ?? this.totalUnits,
    );
  }

  @override
  String toString() => statusLine;
}

/// Kod ve metin dosyalarını bütçe sınırlarına göre parçalara bölen planlayıcı.
class ChunkPlanner {
  static final RegExp _importRegex = RegExp(
    r'''^\s*import\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  static final RegExp _classRegex = RegExp(
    r'''^\s*(?:abstract\s+|sealed\s+|base\s+|interface\s+)?(?:class|enum|mixin|extension)\s+([A-Za-z0-9_]+)''',
    multiLine: true,
  );
  static final RegExp _funcRegex = RegExp(
    r'''^\s*(?:(?:static|final|const|late|Future<[^>]+>|Stream<[^>]+>|void|int|double|String|bool|[A-Z][A-Za-z0-9_]*)\s+)+([a-zA-Z0-9_]+)\s*\([^)]*\)\s*(?:async\s*)?(?:\{|=>)''',
    multiLine: true,
  );

  /// Bölme için aday sınır: class/enum/mixin/extension veya metot/fonksiyon başlangıcı.
  /// Parça bu satırdan ÖNCE biter, böylece yeni parça bir bildirimle başlar.
  static final RegExp _funcBoundaryRegex = RegExp(
    r'''^\s*(?:(?:abstract\s+|sealed\s+|base\s+|interface\s+)?(?:class|enum|mixin|extension)\b|(?:Future<[^>]+>|Stream<[^>]+>|void|int|double|String|bool|[A-Z][A-Za-z0-9_]*)\s+[a-zA-Z0-9_]+\s*\()''',
  );

  static const Set<String> _controlKeywords = {
    'if',
    'for',
    'while',
    'switch',
    'catch',
    'finally',
    'else',
    'return',
  };

  /// Proje haritası: dosya yolu, boyut ve regex ile tek satırlık imza özeti.
  /// Haritanın bütçe payı en çok %25 olarak sınırlandırılır ([maxChars]).
  static String buildProjectMap(
    Map<String, String> files, {
    int? maxChars,
    void Function(String message)? onLog,
  }) {
    if (files.isEmpty) {
      return '';
    }

    final lines = <String>[];
    int currentLength = 0;
    bool truncated = false;

    for (final entry in files.entries) {
      final path = entry.key;
      final content = entry.value;
      final sizeBytes = content.length;

      // Import listesi
      final imports = _importRegex
          .allMatches(content)
          .map((m) => m.group(1)!)
          .map((imp) {
            final parts = imp.split('/');
            return parts.length > 1 ? parts.last : imp;
          })
          .take(5)
          .toList();

      // Class listesi
      final classes = _classRegex
          .allMatches(content)
          .map((m) => m.group(1)!)
          .take(6)
          .toList();

      // Fonksiyon listesi
      final funcs = _funcRegex
          .allMatches(content)
          .map((m) => m.group(1)!)
          .where((f) => !_controlKeywords.contains(f))
          .take(8)
          .toList();

      final parts = <String>[];
      if (imports.isNotEmpty) {
        parts.add('imports: [${imports.join(', ')}]');
      }
      if (classes.isNotEmpty) {
        parts.add('classes: [${classes.join(', ')}]');
      }
      if (funcs.isNotEmpty) {
        parts.add('funcs: [${funcs.join(', ')}]');
      }

      final summary = parts.isEmpty ? 'empty/plain' : parts.join(' | ');
      final line = '$path ($sizeBytes B) -> $summary';

      if (maxChars != null && (currentLength + line.length + 1) > maxChars) {
        truncated = true;
        break;
      }

      lines.add(line);
      currentLength += line.length + 1;
    }

    if (truncated) {
      const truncationMarker = '... [HARİTA KIRPILDI: bütçe payı sınırı %25]';
      lines.add(truncationMarker);
      onLog?.call('Proje haritası %25 bütçe sınırına ulaştığı için kesildi.');
    }

    return lines.join('\n');
  }

  /// Dosyayı satır sınırlarından ve 10 satır örtüşmeyle iş birimlerine ayırır.
  /// Mümkünse fonksiyon/class sınırlarından böler, satır ortasından kesmez.
  /// Tek satır bütçeyi aşıyorsa karakter sınırından bölüp loglar.
  static List<WorkUnit> planFileUnits(
    String filePath,
    String content,
    int maxUnitChars, {
    int overlapLines = 10,
    void Function(String message)? onLog,
  }) {
    if (content.isEmpty) {
      return [
        WorkUnit(
          filePath: filePath,
          startLine: 1,
          endLine: 1,
          content: '',
          unitIndex: 1,
          totalUnits: 1,
        ),
      ];
    }

    // Dosya bütçeye sığıyorsa tek birim olarak döndür
    if (content.length <= maxUnitChars) {
      final lineCount = content.split('\n').length;
      return [
        WorkUnit(
          filePath: filePath,
          startLine: 1,
          endLine: max(1, lineCount),
          content: content.endsWith('\n')
              ? content.substring(0, content.length - 1)
              : content,
          unitIndex: 1,
          totalUnits: 1,
        ),
      ];
    }

    final cleanContent = content.endsWith('\n')
        ? content.substring(0, content.length - 1)
        : content;

    final rawLines = cleanContent.split('\n');
    final processedLines = <String>[];
    final lineSourceMap = <int>[];

    for (int i = 0; i < rawLines.length; i++) {
      final line = rawLines[i];
      final origLineNum = i + 1;

      if (line.length > maxUnitChars) {
        onLog?.call(
          'Tek satır bütçeyi aştı (${line.length} > $maxUnitChars), '
          'karakter sınırından bölündü: $filePath satır $origLineNum',
        );
        for (int c = 0; c < line.length; c += maxUnitChars) {
          final end = min(c + maxUnitChars, line.length);
          processedLines.add(line.substring(c, end));
          lineSourceMap.add(origLineNum);
        }
      } else {
        processedLines.add(line);
        lineSourceMap.add(origLineNum);
      }
    }

    final units = <WorkUnit>[];
    int currentLineIdx = 0;

    while (currentLineIdx < processedLines.length) {
      int endLineIdx = currentLineIdx;
      int accumulatedChars = 0;

      while (endLineIdx < processedLines.length) {
        final lineLen = processedLines[endLineIdx].length + 1;
        if (accumulatedChars + lineLen > maxUnitChars &&
            endLineIdx > currentLineIdx) {
          break;
        }
        accumulatedChars += lineLen;
        endLineIdx++;
      }

      // Sona gelinmediyse fonksiyon/class sınırına geriye doğru bak
      if (endLineIdx < processedLines.length) {
        int bestBoundary = -1;
        final searchLimit = max(currentLineIdx + overlapLines, endLineIdx - 15);
        for (int b = endLineIdx - 1; b >= searchLimit; b--) {
          if (_funcBoundaryRegex.hasMatch(processedLines[b])) {
            bestBoundary = b;
            break;
          }
        }
        if (bestBoundary > currentLineIdx) {
          endLineIdx = bestBoundary;
        }
      }

      final sliceLines = processedLines.sublist(currentLineIdx, endLineIdx);
      final chunkContent = sliceLines.join('\n');
      final startLine = lineSourceMap[currentLineIdx];
      final endLine = lineSourceMap[endLineIdx - 1];

      units.add(
        WorkUnit(
          filePath: filePath,
          startLine: startLine,
          endLine: endLine,
          content: chunkContent,
          unitIndex: units.length + 1,
          totalUnits: 0,
        ),
      );

      if (endLineIdx >= processedLines.length) {
        break;
      }

      // 10 satır örtüşmeyle bir sonraki birime başla
      // Örtüşme parçanın yarısını geçemez (küçük parçalarda neredeyse aynı parçaların üretilmesini önler).
      final span = endLineIdx - currentLineIdx;
      final effectiveOverlap = min(overlapLines, span ~/ 2);
      final nextLineIdx = max(
        currentLineIdx + 1,
        endLineIdx - effectiveOverlap,
      );
      currentLineIdx = nextLineIdx;
    }

    final total = units.length;
    return units.asMap().entries.map((e) {
      return e.value.copyWith(unitIndex: e.key + 1, totalUnits: total);
    }).toList();
  }

  /// Bitişik ajan aktarımı için parçalara böler: örtüşme yoktur ve tüm parçalar
  /// birleştirildiğinde [content] aynen elde edilir. Uzun satırlarda da karakter
  /// sınırları korunur; dosya analizindeki satır örtüşmesi burada kullanılmaz.
  static List<WorkUnit> planTransferUnits(
    String filePath,
    String content,
    int maxUnitChars,
  ) {
    if (maxUnitChars < 1) {
      throw ArgumentError.value(
        maxUnitChars,
        'maxUnitChars',
        'En az 1 olmalı.',
      );
    }
    if (content.length <= maxUnitChars) {
      final lines = content.split('\n').length;
      return [
        WorkUnit(
          filePath: filePath,
          startLine: 1,
          endLine: max(1, lines),
          content: content,
          unitIndex: 1,
          totalUnits: 1,
        ),
      ];
    }

    final chunks = <WorkUnit>[];
    var offset = 0;
    var line = 1;
    while (offset < content.length) {
      var end = min(offset + maxUnitChars, content.length);
      if (end < content.length) {
        final newline = content.lastIndexOf('\n', end - 1);
        if (newline >= offset) end = newline + 1;
      }
      if (end <= offset) end = min(offset + maxUnitChars, content.length);

      final chunk = content.substring(offset, end);
      final newlineCount = '\n'.allMatches(chunk).length;
      final endLine = max(
        line,
        line + newlineCount - (chunk.endsWith('\n') ? 1 : 0),
      );
      chunks.add(
        WorkUnit(
          filePath: filePath,
          startLine: line,
          endLine: endLine,
          content: chunk,
          unitIndex: chunks.length + 1,
          totalUnits: 0,
        ),
      );
      line += newlineCount;
      offset = end;
    }

    final total = chunks.length;
    return chunks.asMap().entries.map((entry) {
      return entry.value.copyWith(unitIndex: entry.key + 1, totalUnits: total);
    }).toList();
  }

  /// Metin görevleri (PDF/Word/PPTX): Markdown başlıklarına göre bölümler;
  /// her bölüme önceki bölümlerin 3 satırlık özetini ekler.
  static List<WorkUnit> planTextSections(
    String filePath,
    String markdownContent,
    int maxUnitChars, {
    int maxSummaryLines = 3,
    void Function(String message)? onLog,
  }) {
    if (markdownContent.length <= maxUnitChars) {
      final lineCount = markdownContent.split('\n').length;
      return [
        WorkUnit(
          filePath: filePath,
          startLine: 1,
          endLine: max(1, lineCount),
          content: markdownContent.endsWith('\n')
              ? markdownContent.substring(0, markdownContent.length - 1)
              : markdownContent,
          unitIndex: 1,
          totalUnits: 1,
        ),
      ];
    }

    final headingRegex = RegExp(r'''^(#{1,6}\s+.*)$''', multiLine: true);
    final matches = headingRegex.allMatches(markdownContent).toList();

    if (matches.isEmpty) {
      return planFileUnits(
        filePath,
        markdownContent,
        maxUnitChars,
        onLog: onLog,
      );
    }

    final rawSections = <String>[];
    int prevIndex = 0;

    for (int i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (m.start > prevIndex) {
        final sec = markdownContent.substring(prevIndex, m.start).trim();
        if (sec.isNotEmpty) {
          rawSections.add(sec);
        }
      }
      final nextStart = (i + 1 < matches.length)
          ? matches[i + 1].start
          : markdownContent.length;
      final sec = markdownContent.substring(m.start, nextStart).trim();
      if (sec.isNotEmpty) {
        rawSections.add(sec);
      }
      prevIndex = nextStart;
    }

    final units = <WorkUnit>[];
    final rollingSummaries = <String>[];
    int currentLine = 1;

    for (int i = 0; i < rawSections.length; i++) {
      final section = rawSections[i];
      String unitContent = section;

      if (i > 0 && rollingSummaries.isNotEmpty) {
        final summaryLines = rollingSummaries.take(maxSummaryLines).toList();
        final summaryBlock =
            '[Önceki bölümlerin özeti:\n${summaryLines.join('\n')}]\n\n';
        unitContent = summaryBlock + unitContent;
      }

      final sectionLines = unitContent.split('\n').length;
      if (unitContent.length > maxUnitChars) {
        final subUnits = planFileUnits(
          filePath,
          unitContent,
          maxUnitChars,
          onLog: onLog,
        );
        for (final sub in subUnits) {
          // Alt parça satırları bölüm başlangıcına göre ötelenir; örtüşme sayacı kaydırmaz.
          units.add(
            sub.copyWith(
              startLine: currentLine + sub.startLine - 1,
              endLine: currentLine + sub.endLine - 1,
            ),
          );
        }
      } else {
        units.add(
          WorkUnit(
            filePath: filePath,
            startLine: currentLine,
            endLine: currentLine + sectionLines - 1,
            content: unitContent,
            unitIndex: units.length + 1,
            totalUnits: 0,
          ),
        );
      }
      currentLine += sectionLines;

      final nonHeadingLines = section
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();
      if (nonHeadingLines.isNotEmpty) {
        rollingSummaries.insert(0, nonHeadingLines.first);
        if (rollingSummaries.length > maxSummaryLines) {
          rollingSummaries.removeLast();
        }
      }
    }

    final total = units.length;
    return units.asMap().entries.map((e) {
      return e.value.copyWith(unitIndex: e.key + 1, totalUnits: total);
    }).toList();
  }
}
