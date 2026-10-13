import 'dart:math' as math;

import '../domain/chat_models.dart';
import '../domain/chat_template.dart';
import '../domain/entities.dart';
import 'token_budget.dart';

/// Türkçe harfleri ASCII'ye katlar ve küçültür (`İstanbul` → `istanbul`, `Çocuk` → `cocuk`).
String foldTr(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    switch (r) {
      case 0x130: // İ
      case 0x49: // I
      case 0x131: // ı
        b.write('i');
      case 0xC7: // Ç
      case 0xE7: // ç
        b.write('c');
      case 0x11E: // Ğ
      case 0x11F: // ğ
        b.write('g');
      case 0xD6: // Ö
      case 0xF6: // ö
        b.write('o');
      case 0x15E: // Ş
      case 0x15F: // ş
        b.write('s');
      case 0xDC: // Ü
      case 0xFC: // ü
      case 0xDB: // Û
      case 0xFB: // û
        b.write('u');
      case 0xC2: // Â
      case 0xE2: // â
        b.write('a');
      case 0xCE: // Î
      case 0xEE: // î
        b.write('i');
      case 0x307: // birleşik nokta
        break;
      default:
        b.write(String.fromCharCode(r).toLowerCase());
    }
  }
  return b.toString();
}

const _stop = {
  've', 'bir', 'bu', 'su', 'o', 'icin', 'ile', 'de', 'da', 'mi', 'mu', 'ne', 'ben', 'sen', 'biz', 'siz', 'ama',
  'gibi', 'daha', 'cok', 'en', 'her', 'ki', 'ya', 'ise', 'olan', 'var', 'yok', 'mı', 'nasil', 'neden', 'hangi',
  'bana', 'sana', 'beni', 'seni', 'benim', 'senin', 'bunu', 'sunu', 'onu', 'lutfen', 'evet', 'hayir', 'tamam',
  'the', 'and', 'is', 'to', 'of', 'a', 'in', 'it', 'you', 'me', 'my',
};

final _splitRe = RegExp(r'[^a-z0-9]+');

/// Arama için kök listesi: katla, böl, kısa/dolgu sözcükleri at, 5 harften uzunları 5'e kırp
/// (Türkçe ek çeşitliliğine kaba tolerans: `kitaplarım`, `kitabı` → `kitap`/`kitab` yakın kökler).
List<String> memoryTokens(String s) {
  final out = <String>[];
  for (final w in foldTr(s).split(_splitRe)) {
    if (w.length < 2 || _stop.contains(w)) continue;
    out.add(w.length > 5 ? w.substring(0, 5) : w);
  }
  return out;
}

class ScoredMemory {
  const ScoredMemory(this.item, this.score);

  final MemoryItem item;
  final double score;
}

class _Doc {
  _Doc(this.item, this.tf, this.len);

  final MemoryItem item;
  final Map<String, int> tf;
  final int len;
}

/// Profil parçaları, sabitlenmiş notlar ve eski mesajlar üzerinde çevrimdışı BM25 araması.
class MemoryIndex {
  final Map<String, _Doc> _docs = {};
  final Map<String, int> _df = {};
  int _totalLen = 0;

  int get size => _docs.length;

  void add(MemoryItem item) {
    if (_docs.containsKey(item.id)) return;
    final tf = <String, int>{};
    var len = 0;
    for (final t in memoryTokens(item.text)) {
      tf[t] = (tf[t] ?? 0) + 1;
      len++;
    }
    _docs[item.id] = _Doc(item, tf, len);
    _totalLen += len;
    for (final t in tf.keys) {
      _df[t] = (_df[t] ?? 0) + 1;
    }
  }

  void addAll(Iterable<MemoryItem> items) {
    for (final i in items) {
      add(i);
    }
  }

  void remove(String id) {
    final d = _docs.remove(id);
    if (d == null) return;
    _totalLen -= d.len;
    for (final t in d.tf.keys) {
      final n = (_df[t] ?? 1) - 1;
      if (n <= 0) {
        _df.remove(t);
      } else {
        _df[t] = n;
      }
    }
  }

  void removeGroup(String group) {
    final ids = [for (final d in _docs.values) if (d.item.group == group) d.item.id];
    for (final id in ids) {
      remove(id);
    }
  }

  /// [query] ile en ilgili [limit] parça (puan > 0). [exclude]: hariç tutulacak kimlikler.
  /// [kinds] doluysa yalnızca bu türler aranır.
  List<ScoredMemory> search(
    String query, {
    int limit = 6,
    Set<String> exclude = const {},
    Set<MemoryKind>? kinds,
  }) {
    final q = memoryTokens(query).toSet();
    if (q.isEmpty || _docs.isEmpty) return const [];
    final n = _docs.length;
    final avg = math.max(1.0, _totalLen / n);
    const k1 = 1.4;
    const b = 0.75;
    final out = <ScoredMemory>[];
    for (final d in _docs.values) {
      if (exclude.contains(d.item.id)) continue;
      if (kinds != null && !kinds.contains(d.item.kind)) continue;
      var score = 0.0;
      for (final t in q) {
        final f = d.tf[t];
        if (f == null) continue;
        final df = _df[t] ?? 1;
        final idf = math.log(1 + (n - df + 0.5) / (df + 0.5));
        score += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * d.len / avg));
      }
      if (score > 0) out.add(ScoredMemory(d.item, score));
    }
    out.sort((a, c) {
      final r = c.score.compareTo(a.score);
      return r != 0 ? r : c.item.ts.compareTo(a.item.ts);
    });
    return out.length > limit ? out.sublist(0, limit) : out;
  }
}

/// Modelin ürettiği ham metni sohbete uygun hâle getirir.
class ChatOutputFilter {
  const ChatOutputFilter._();

  /// Model kendi turunu bitirip yeni tur başlatırsa (veya özel belirteç sızdırırsa) bunlardan itibaren kesilir.
  static const markers = [
    '<|im_end|>',
    '<|im_start|>',
    '<|eot_id|>',
    '<|start_header_id|>',
    '<|end|>',
    '<|user|>',
    '<|endoftext|>',
    '</s>',
    '[INST]',
    '<｜end▁of▁sentence｜>',
    '<｜User｜>',
    '### Instruction:',
  ];

  /// (görünen metin, üretim durdurulmalı mı). Sonda yarım kalan belirteç (`<|im_`) gizlenir.
  static (String, bool) clean(String raw) {
    var cut = -1;
    for (final m in markers) {
      final i = raw.indexOf(m);
      if (i >= 0 && (cut < 0 || i < cut)) cut = i;
    }
    if (cut >= 0) return (raw.substring(0, cut), true);
    final from = raw.length > 24 ? raw.length - 24 : 0;
    for (var i = from; i < raw.length; i++) {
      final rest = raw.substring(i);
      for (final m in markers) {
        if (m.length > rest.length && m.startsWith(rest)) return (raw.substring(0, i), false);
      }
    }
    return (raw, false);
  }

  /// `<think>…</think>` bloklarını ayıklar. (cevap, hâlâ düşünüyor mu).
  static (String, bool) splitThink(String text) {
    var t = text;
    // Şablon "<think>" açılışını istemin içine koyduysa yalnızca kapanış gelir.
    final close = t.indexOf('</think>');
    if (close >= 0 && !t.substring(0, close).contains('<think>')) {
      t = t.substring(close + 8);
    }
    t = t.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
    final open = t.indexOf('<think>');
    if (open >= 0) return (t.substring(0, open).trimLeft(), true);
    return (t.trimLeft(), false);
  }
}

String _clip(String s, int max) {
  final t = s.trim();
  if (t.length <= max) return t;
  if (max <= 1) return '…';
  return '${t.substring(0, max - 1).trimRight()}…';
}

String _day(int ts) {
  final t = DateTime.fromMillisecondsSinceEpoch(ts);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

/// [ChatPromptBuilder.build] sonucu.
class ChatPrompt {
  const ChatPrompt({
    required this.prompt,
    required this.historyTurns,
    required this.recalled,
    required this.profileParts,
    required this.pinned,
    required this.userTrimmed,
  });

  final String prompt;
  final int historyTurns;
  final int recalled;
  final int profileParts;
  final int pinned;
  final bool userTrimmed;
}

/// Hafızadan (profil + sabit notlar + eski konuşmalar) ve son konuşmadan, bağlam bütçesine sığan bir istem kurar.
class ChatPromptBuilder {
  const ChatPromptBuilder._();

  static const persona =
      'Sen Kripton\'sun: kullanıcının telefonunda tamamen çevrimdışı çalışan kişisel bir yapay zekâ asistanısın. '
      'Türkçe, samimi ve net yanıt ver; gereksiz uzatma. Aşağıdaki bölümler kullanıcının kendi yazdığı kayıtlar ve '
      'önceki konuşmalarınızdır: yalnızca soruyla ilgiliyse kullan, orada olmayan bir şeyi uydurma. Bilmiyorsan bilmediğini söyle.';

  /// Geçmişteki tek mesajın istemde alabileceği en çok karakter.
  static const historyClip = 700;

  static const _turnOverhead = 40;

  /// [charBudget]: şablon ek yükü DAHİL toplam istem karakteri.
  /// [history]: kullanıcının yeni mesajı HARİÇ son mesajlar (eski → yeni).
  static ChatPrompt build({
    required ChatTemplate template,
    required int charBudget,
    required String userText,
    required List<ChatMessage> history,
    List<MemoryItem> pins = const [],
    List<MemoryItem> core = const [],
    List<MemoryItem> recalled = const [],
    DateTime? now,
  }) {
    final overhead = applyChatTemplate(template, '', const []).length + _turnOverhead;
    final date = _day((now ?? DateTime.now()).millisecondsSinceEpoch);
    final base = persona.length + 'Bugünün tarihi: $date'.length + 160;
    var avail = math.max(0, charBudget - overhead - base);

    var user = userText.trim();
    var trimmed = false;
    final maxUser = math.max(200, (avail * 0.45).floor());
    if (user.length > maxUser) {
      final head = (maxUser * 0.65).floor();
      final tail = maxUser - head - 5;
      user = '${user.substring(0, head).trimRight()} […] ${user.substring(user.length - math.max(0, tail)).trimLeft()}';
      trimmed = true;
    }
    avail = math.max(0, avail - user.length);

    final pinLines = _fill(
      pins,
      (avail * 0.15).floor(),
      (i) => '- ${_clip(i.text, 400)}',
    );
    final coreLines = _fill(
      core,
      (avail * 0.15).floor(),
      (i) => '- (${i.label}) ${_clip(i.text, kProfileClip)}',
    );
    final recalledLines = _fill(
      recalled,
      (avail * 0.30).floor(),
      (i) => switch (i.kind) {
        MemoryKind.profile => '- (${i.label}) ${_clip(i.text, kProfileClip)}',
        MemoryKind.pin => '- ${_clip(i.text, 400)}',
        MemoryKind.message =>
          '- [${_day(i.ts)}] ${i.role == ChatRole.user ? 'Kullanıcı' : 'Kripton'}: ${_clip(i.text, 400)}',
      },
    );
    final used = pinLines.chars + coreLines.chars + recalledLines.chars;
    final histBudget = math.max(0, avail - used);

    // Son konuşma: yeniden eskiye, bütçe bitene dek.
    final turns = <ChatTurn>[];
    var spent = 0;
    for (var i = history.length - 1; i >= 0; i--) {
      final m = history[i];
      final text = _clip(m.text, historyClip);
      final cost = text.length + _turnOverhead;
      if (spent + cost > histBudget) break;
      spent += cost;
      turns.add(ChatTurn(m.role, text));
    }
    var ordered = turns.reversed.toList();
    while (ordered.isNotEmpty && ordered.first.role != ChatRole.user) {
      ordered = ordered.sublist(1);
    }

    final sys = StringBuffer(persona)
      ..write('\nBugünün tarihi: $date');
    if (coreLines.lines.isNotEmpty) {
      sys
        ..write('\n\n## Kullanıcı hakkında (kendi yazdığı notlar)\n')
        ..write(coreLines.lines.join('\n'));
    }
    if (pinLines.lines.isNotEmpty) {
      sys
        ..write('\n\n## Kullanıcının sabitlediği notlar\n')
        ..write(pinLines.lines.join('\n'));
    }
    if (recalledLines.lines.isNotEmpty) {
      sys
        ..write('\n\n## Bu soruyla ilgili hatırladıkların\n')
        ..write(recalledLines.lines.join('\n'));
    }
    final prompt = applyChatTemplate(
      template,
      sys.toString(),
      [...ordered, ChatTurn(ChatRole.user, user)],
    );
    return ChatPrompt(
      prompt: prompt,
      historyTurns: ordered.length,
      recalled: recalledLines.lines.length,
      profileParts: coreLines.lines.length,
      pinned: pinLines.lines.length,
      userTrimmed: trimmed,
    );
  }

  /// İstemi token tahminiyle doğrular; sığmıyorsa bütçeyi %15 azaltarak yeniden kurar.
  /// Dönen sonuç yine sığmıyorsa [ChatPromptFit.fits] false olur (ör. tek mesaj aşırı büyük).
  static ChatPromptFit buildWithin({
    required ChatTemplate template,
    required int charBudget,
    required int maxPromptTokens,
    required String userText,
    required List<ChatMessage> history,
    List<MemoryItem> pins = const [],
    List<MemoryItem> core = const [],
    List<MemoryItem> recalled = const [],
    DateTime? now,
  }) {
    var budget = charBudget;
    late ChatPrompt p;
    for (var i = 0; i < 24; i++) {
      p = build(
        template: template,
        charBudget: budget,
        userText: userText,
        history: history,
        pins: pins,
        core: core,
        recalled: recalled,
        now: now,
      );
      if (estimateTokens(p.prompt, template) <= maxPromptTokens) return ChatPromptFit(p, true);
      budget = (budget * 0.85).floor();
      if (budget < 400) break;
    }
    return ChatPromptFit(p, estimateTokens(p.prompt, template) <= maxPromptTokens);
  }

  static _Filled _fill(List<MemoryItem> items, int budget, String Function(MemoryItem) fmt) {
    final lines = <String>[];
    var chars = 0;
    for (final i in items) {
      var line = fmt(i);
      final left = budget - chars;
      if (line.length + 1 > left) {
        if (left < 120) break;
        line = _clip(line, left - 1);
      }
      lines.add(line);
      chars += line.length + 1;
    }
    return _Filled(lines, chars);
  }
}

/// Profil parçasının istemde alabileceği en çok karakter.
const int kProfileClip = 800;

class _Filled {
  const _Filled(this.lines, this.chars);

  final List<String> lines;
  final int chars;
}

class ChatPromptFit {
  const ChatPromptFit(this.prompt, this.fits);

  final ChatPrompt prompt;
  final bool fits;
}
