import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import '../data/file_service.dart';
import '../data/llm_engine.dart';
import '../data/project_snapshot.dart';
import '../data/project_source.dart';
import '../data/storage.dart';
import '../domain/chat_template.dart';
import '../domain/entities.dart';
import '../domain/inference_settings.dart';
import 'chunk_planner.dart';
import 'output_validator.dart';
import 'perf_log.dart';
import 'thermal_governor.dart';
import 'token_budget.dart';

class CancelToken {
  final Completer<void> _done = Completer<void>();

  bool get cancelled => _done.isCompleted;

  /// İptal anında tamamlanır; bekleyen işlemler `Future.any` ile bunu dinler.
  Future<void> get onCancel => _done.future;

  /// İdempotent: ikinci ve sonraki çağrılar etkisizdir.
  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}

class CancelledException implements Exception {
  const CancelledException();
}

class RunCallbacks {
  final void Function(String) status;
  final void Function(ExecutionLog) log;
  final void Function(String) token;
  final void Function(String agentName) live;
  final void Function(String agentId, AgentStatus status, int loop) agent;
  final void Function(String message)? transfer;

  /// Bir ajanın (veya doğrulayıcının) çıktı özeti hazır olduğunda çağrılır. Aynı `agentId` ile
  /// tekrar çağrılırsa önceki kayıt değiştirilir (ör. doğrulama sonrası düzeltilmiş çıktı).
  final void Function(AgentOutput output)? agentOutput;

  /// Kullanıcıya gösterilecek akış öncesi uyarı (ör. küçük bağlam).
  final void Function(String message)? notice;

  const RunCallbacks({
    required this.status,
    required this.log,
    required this.token,
    required this.live,
    required this.agent,
    this.transfer,
    this.agentOutput,
    this.notice,
  });
}

// Bütçeler artık sabit değil: PromptBudget (token_budget.dart) contextSize'a ve modele göre hesaplar.
// Sabit 9000 karakter / 5000 ek / 1536 token yerine; karakter/token oranı şablona ve dile (Türkçe/kod) göre kalibre.
const _ctxShare = 0.85; // prompt + maxTokens, contextSize'ın en çok %85'i
const _bigText = 200000; // bu uzunluktan büyük metin kırpma Isolate'ta yapılır
// Salt kozmetik durum geçişleri (veri/IO beklemesi yok): 400/350/350 ms -> 80/60/60 ms.
// Ajan geçişi başına ~580 ms, çalıştırma başına ~320 ms kazanç; iptal yine anında (Future.any).
const _pauseStart = 80;
const _pauseStep = 60;
final _thinkRe = RegExp(r'<think>.*?</think>', dotAll: true);
final _thinkTagRe = RegExp(r'</?think>', caseSensitive: false);
final _errRe = RegExp(r'\[STATUS:\s*ERROR\]', caseSensitive: false);
final _okRe = RegExp(r'\[STATUS:\s*SUCCESS\]', caseSensitive: false);
final _statusOnlyLineRe = RegExp(
  r'^\s*\[STATUS:[^\]]+\]\s*$',
  multiLine: true,
  caseSensitive: false,
);

bool _isEmptyModelAnswer(Object error) =>
    error.toString().contains('Model yalnızca düşünce üretti') ||
    error.toString().contains('Model boş çıktı üretti');

/// Model çıktısından çözümlenen yama bloğu.
class PatchBlock {
  final String filePath;
  final bool isNewFile;
  final String? oldCode;
  final String newCode;
  final String rawBlock;

  const PatchBlock({
    required this.filePath,
    required this.isNewFile,
    this.oldCode,
    required this.newCode,
    required this.rawBlock,
  });
}

/// Yama uygulama sonucu.
class PatchApplyResult {
  final bool success;
  final PatchBlock patch;
  final String? error;

  const PatchApplyResult({
    required this.success,
    required this.patch,
    this.error,
  });
}

/// Parantez dengesi, kapanmamış string ve eksik import kontrollerini yapan yerel denetçi.
/// Dart sözdizimine göre yazıldı; DANIŞMAN niteliğindedir (hata kararını LLM verir).
class LocalStaticChecker {
  static final RegExp _importRe = RegExp(
    r'''^\s*import\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );

  static List<String> checkFile(
    String filePath,
    String content,
    Set<String> projectFiles,
  ) {
    final issues = <String>[];
    var paren = 0, brace = 0, bracket = 0;
    var inSingle = false,
        inDouble = false,
        inTripleSingle = false,
        inTripleDouble = false;
    var inLineComment = false, inBlockComment = false;
    var unclosedString = false;
    var raw = false; // r'...' : kaçış karakteri yok

    for (var i = 0; i < content.length; i++) {
      final ch = content[i];
      final next = i + 1 < content.length ? content[i + 1] : '';
      final next2 = i + 2 < content.length ? content[i + 2] : '';

      if (inLineComment) {
        if (ch == '\n') inLineComment = false;
        continue;
      }
      if (inBlockComment) {
        if (ch == '*' && next == '/') {
          inBlockComment = false;
          i++;
        }
        continue;
      }
      if (inTripleSingle) {
        if (ch == "'" && next == "'" && next2 == "'") {
          inTripleSingle = false;
          i += 2;
        }
        continue;
      }
      if (inTripleDouble) {
        if (ch == '"' && next == '"' && next2 == '"') {
          inTripleDouble = false;
          i += 2;
        }
        continue;
      }
      if (inSingle || inDouble) {
        if (ch == '\n') {
          // Tek satırlık dize satır sonunda kapanmalı: sonraki satırların sayımını bozmasın.
          unclosedString = true;
          inSingle = false;
          inDouble = false;
          continue;
        }
        if (ch == '\\' && !raw) {
          i++;
          continue;
        }
        if ((inSingle && ch == "'") || (inDouble && ch == '"')) {
          inSingle = false;
          inDouble = false;
        }
        continue;
      }

      if (ch == '/' && next == '/') {
        inLineComment = true;
        i++;
        continue;
      }
      if (ch == '/' && next == '*') {
        inBlockComment = true;
        i++;
        continue;
      }

      if (ch == "'" || ch == '"') {
        raw = i > 0 && content[i - 1] == 'r';
        if (ch == "'" && next == "'" && next2 == "'") {
          inTripleSingle = true;
          i += 2;
        } else if (ch == '"' && next == '"' && next2 == '"') {
          inTripleDouble = true;
          i += 2;
        } else if (ch == "'") {
          inSingle = true;
        } else {
          inDouble = true;
        }
        continue;
      }

      switch (ch) {
        case '(':
          paren++;
        case ')':
          paren--;
        case '{':
          brace++;
        case '}':
          brace--;
        case '[':
          bracket++;
        case ']':
          bracket--;
      }
    }

    if (paren != 0) issues.add('Dengesiz parantez () (fark: $paren)');
    if (brace != 0) issues.add('Dengesiz süslü parantez {} (fark: $brace)');
    if (bracket != 0)
      issues.add('Dengesiz köşeli parantez [] (fark: $bracket)');
    if (unclosedString ||
        inSingle ||
        inDouble ||
        inTripleSingle ||
        inTripleDouble) {
      issues.add('Kapanmamış dize (string literal)');
    }

    // Göreli import hedefi projede var mı? (Proje dosya listesi verilmediyse kontrol edilmez.)
    if (projectFiles.isNotEmpty) {
      for (final m in _importRe.allMatches(content)) {
        final imp = m.group(1)!;
        if (imp.startsWith('./') || imp.startsWith('../')) {
          final resolved = _resolveRelativePath(filePath, imp);
          if (!projectFiles.contains(resolved)) {
            issues.add('İçe aktarılan dosya projede yok: $imp ($resolved)');
          }
        }
      }
    }
    return issues;
  }

  static String _resolveRelativePath(String currentFile, String relativePath) {
    final parts = currentFile.split('/');
    if (parts.isNotEmpty) parts.removeLast();
    for (final p in relativePath.split('/')) {
      if (p == '.' || p.isEmpty) continue;
      if (p == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(p);
      }
    }
    return parts.join('/');
  }

  /// Raporu en çok 8 madde ve 600 karakterle sınırlandırır.
  static String formatReport(List<String> issues) {
    if (issues.isEmpty) return 'Yerel statik denetim temiz: Hata bulunamadı.';
    var report =
        'Yerel Statik Denetim Raporu:\n${issues.take(8).map((l) => '- $l').join('\n')}';
    if (report.length > 600) report = '${report.substring(0, 597)}...';
    return report;
  }
}

const _truncMark = '\n[...kısaltıldı...]\n';
const _prevMarker = '\n\n--- [ÖNCEKİ AJAN ÇIKTISI / BAĞLAM] ---\n';
const _taskHead = '--- [KULLANICI GÖREVİ (tüm ajanlar için bağlayıcı)] ---';
const _taskTail = '--- Bu görevden sapma. Konu dışına çıkma. ---';

/// Kullanıcı görevi bloğu (boş görevde boş metin). Prompt'un EN BAŞINA eklenir.
String taskBlock(String task) {
  final t = task.trim();
  return t.isEmpty ? '' : '$_taskHead\n$t\n$_taskTail';
}

String _fitSync(String s, int cap) {
  if (s.length <= cap) return s;
  final room = math.max(0, cap - _truncMark.length);
  final head = (room * 0.3).toInt();
  final tail = room - head;
  return '${s.substring(0, head)}$_truncMark${s.substring(s.length - tail)}';
}

/// [keep] (görev bloğu + ayırıcı) ile başlayan metinde görev bloğu ASLA kırpılmaz.
/// Kırpma sırası: önce "ÖNCEKİ AJAN ÇIKTISI" bölümü, o yetmezse görevden sonraki geri kalan metin.
/// Görev bloğu tek başına [cap]'i aşarsa blok korunur; bütçe aşımını çağıranın son savunması yakalar.
String _fitKeepSync(String s, int cap, String keep) {
  if (keep.isEmpty || !s.startsWith(keep)) return _fitSync(s, cap);
  if (s.length <= cap) return s;
  final rest = s.substring(keep.length);
  final room = cap - keep.length;
  if (room <= 0) return keep;
  final at = rest.indexOf(_prevMarker);
  if (at >= 0) {
    final head = rest.substring(0, at);
    final prev = rest.substring(at + _prevMarker.length);
    final prevRoom = room - head.length - _prevMarker.length;
    if (prevRoom >= 0) {
      if (prevRoom <= _truncMark.length)
        return '$keep$head'; // önceki çıktıdan geriye anlamlı pay kalmadı
      return '$keep$head$_prevMarker${_fitSync(prev, prevRoom)}';
    }
    return '$keep${_fitSync(head, room)}'; // önceki çıktı tamamen düştü; sabit kısım kısalır
  }
  return '$keep${_fitSync(rest, room)}';
}

class WorkflowRunner {
  WorkflowRunner(this._engine, this._files, this._storage);

  final LlmEngine _engine;
  final FileService _files;
  final Storage _storage;
  final Map<String, String> _prompts = {};
  String _task = ''; // çalışan akışın görevi (run() başında ayarlanır)
  final ThermalGovernor _gov = ThermalGovernor();
  int? _pendingThreads;
  int? _appliedThreads;
  bool _lowBudgetWarned = false;

  // Çıktı biçim sözleşmesi (run() başında ayarlanır): sözleşme, içerik üreten SON ajanın
  // system prompt'una eklenir; doğrulama başarısızsa [_correction] da eklenerek ajan bir kez yeniden çalışır.
  OutputFormat? _contractFormat;
  String? _contractAgentId;
  String _correction = '';

  /// Doğrulama başarısız olunca üretici ajanın en çok kaç kez yeniden çalıştırılacağı (>= 1).
  int correctionAttempts = kMaxCorrectionAttempts;

  // Geliştirilen mevcut proje (kendini geliştirme / proje düzenleme); yoksa null. run() başında yüklenir.
  ProjectSnapshot? _base;

  /// Exact model prompts used for each agent, including every transferred chunk.
  Map<String, String> get promptSnapshots => Map.unmodifiable(_prompts);

  /// Termal denetleyicinin son önerdiği thread sayısı (UI/hız testi için).
  int get threads => _appliedThreads ?? _gov.threads;

  void _check(CancelToken ct) {
    if (ct.cancelled) throw const CancelledException();
  }

  /// Bekleme sırasında iptal gelirse beklemeden çıkar.
  Future<void> _pause(int ms, CancelToken ct) async {
    await Future.any<void>([
      Future<void>.delayed(Duration(milliseconds: ms)),
      ct.onCancel,
    ]);
    _check(ct);
  }

  String _now() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  void _log(RunCallbacks cb, String who, String msg, LogType type) => cb.log(
    ExecutionLog(time: _now(), agentName: who, message: msg, type: type),
  );

  int _attachCap() => PromptBudget.of(
    _engine.contextSize ?? 4096,
    share: _ctxShare,
    batch: _engine.batchSize,
  ).attachChars(ChatTemplate.chatml, 'ç');

  String _attachText(AgentConfig a) {
    if (a.attachedFiles.isEmpty) return '';
    final per = _attachCap() ~/ a.attachedFiles.length;
    final b = StringBuffer();
    for (final f in a.attachedFiles) {
      final c = f.content.length > per
          ? f.content.substring(0, per)
          : f.content;
      b.write('Dosya: ${f.name}\nİçerik:\n$c\n\n');
    }
    return b.toString();
  }

  /// Görev bloğu + ayırıcı; görev boşsa boş metin.
  String get _taskPrefix {
    final b = taskBlock(_task);
    return b.isEmpty ? '' : '$b\n\n';
  }

  /// [s]'nin EN BAŞINA kullanıcı görevi bloğunu ekler.
  String _withTask(String s) => '$_taskPrefix$s';

  String _system(AgentConfig a, int index) {
    final att = _attachText(a);
    var base = a.systemPrompt;
    if (index == 0 && att.isNotEmpty) {
      base = '$base\n\n--- [GİRDİ DOSYALARI] ---\n$att';
    }
    if (a.mode == AgentMode.converter || a.mode == AgentMode.export) {
      base +=
          '\n\nSİSTEM KURALI: Önceki ajan çıktısındaki bilgiyi DEĞİŞTİRME, EKLEME, ÖZETLEME. Yalnızca biçimlendir. '
          'Kaynakta bulunmayan bilgi, örnek, açıklama veya sonuç üretme.';
    }
    final format = _contractFormat;
    if (format != null && a.id == _contractAgentId) {
      final contract = OutputContract.instruction(format, hasBase: _base != null);
      if (contract.isNotEmpty) base += '\n\n$contract';
      if (_correction.isNotEmpty) base += _correction;
    }
    return _withTask(base);
  }

  String _user(AgentConfig a, int index, String prev) {
    final b = StringBuffer(_taskPrefix)..write(a.userPrompt);
    if (index != 0) {
      final att = _attachText(a);
      if (att.isNotEmpty) b.write('\n\n--- [EK DOSYALAR] ---\n$att');
    }
    if (prev.isNotEmpty) b.write('$_prevMarker$prev');
    return b.toString();
  }

  Future<String> _fit(String s, int cap) async {
    if (s.length <= cap) return s;
    final keep = _taskPrefix; // görev bloğu kırpılmaz
    // Çok büyük metinlerde kopyalama/kırpma UI isolate'ını bloklamasın.
    if (s.length > _bigText)
      return Isolate.run(() => _fitKeepSync(s, cap, keep));
    return _fitKeepSync(s, cap, keep);
  }

  String _clean(String s) {
    var t = s.replaceAll(_thinkRe, '');
    final open = t.indexOf('<think>');
    if (open >= 0) t = t.substring(0, open);
    t = t.trim();
    if (t.isEmpty) {
      if (s.toLowerCase().contains('<think>'))
        throw StateError('Model yalnızca düşünce üretti');
      throw StateError('Model boş çıktı üretti');
    }
    final m = RegExp(
      r'^```(?:markdown|md)\s*\n(.*)\n```$',
      dotAll: true,
    ).firstMatch(t);
    return m != null ? m.group(1)!.trim() : t;
  }

  String? _invalidTransferOutput(String output) {
    final value = output.trim();
    if (value.isEmpty) return 'boş çıktı';
    if (value.length < 80) return '80 karakterden kısa çıktı (${value.length})';
    if (_thinkTagRe.hasMatch(value)) return '<think> etiketi içeriyor';
    if (value.replaceAll(_statusOnlyLineRe, '').trim().isEmpty)
      return 'yalnızca [STATUS:...] satırı';
    return null;
  }

  bool _isError(String report) {
    final e = _errRe.firstMatch(report);
    if (e == null) return false;
    final s = _okRe.firstMatch(report);
    return s == null || e.start < s.start;
  }

  Future<String> _infer(
    AgentConfig a,
    String system,
    String user,
    List<GgufModel> models,
    RunCallbacks cb,
    CancelToken ct, {
    bool short = false,
    bool capturePrompt = false,
  }) async {
    GgufModel? m;
    for (final x in models) {
      if (x.id == a.modelId) m = x;
    }
    if (m == null) throw StateError('Model bulunamadı: ${a.modelId}');
    if (!m.isCached) throw StateError('Model indirilmemiş: ${m.name}');
    cb.live(a.name);
    _check(ct);
    // Yükleme yarıda kesilmez (motor _loaded'ı yalnızca başarıyla biten yüklemede günceller);
    // bittiğinde iptal varsa temiz çıkılır.
    _applyThreads();
    final loadSw = Stopwatch()..start();
    try {
      await _engine.ensureLoaded(m.localPath!, expectedBytes: m.sizeBytes);
    } on ModelFileException {
      final reg = await _storage.loadRegistry();
      if (reg.remove(m.id) != null) await _storage.saveRegistry(reg);
      rethrow;
    }
    _check(ct);
    // Önceki (iptal edilmiş) native üretim sürüyorsa yeni üretim başlatılmaz.
    if (!await _engine.waitNativeIdle(const Duration(seconds: 8))) {
      throw StateError(
        'Önceki native üretim hâlâ sonlanmadı; yeni üretim başlatılmadı.',
      );
    }
    _check(ct);
    final loadMs = loadSw.elapsedMilliseconds;
    // Dinamik bütçe: prompt + maxTokens <= contextSize * %85; token tahmini şablona/dile göre kalibre.
    final ctx = _engine.contextSize ?? 2048;
    final tpl = m.template;
    final isR1 = tpl == ChatTemplate.deepseek;
    final batch = _engine
        .batchSize; // yüklemeden sonra okunur; null => yalnızca bağlam sınırı
    final bud = PromptBudget.of(
      ctx,
      deepseek: isR1,
      shortAnswer: short,
      share: _ctxShare,
      batch: batch,
    );
    // Kullanıcının azami token sınırı yalnızca bağlam bütçesini DÜŞÜREBİLİR, asla aşamaz.
    final userCap = a.inference.maxTokens;
    final maxNew = userCap == null
        ? bud.maxNew
        : math.min(bud.maxNew, math.max(32, userCap));
    if (!_lowBudgetWarned && bud.usablePromptTokens < 1000) {
      _lowBudgetWarned = true; // çalıştırma başına tek uyarı
      _log(
        cb,
        a.name,
        'Bütçe düşük uyarısı: usablePromptTokens = ${bud.usablePromptTokens} (< 1000)',
        LogType.warning,
      );
    }
    final room = bud.promptChars(
      tpl,
      system + user,
      applyTemplate(tpl, '', '').length,
    );
    final markerAt = user.indexOf(_prevMarker);
    final originalTransfer = markerAt < 0
        ? null
        : user.substring(markerAt + _prevMarker.length);
    final originalPromptChars = system.length + user.length;
    var sys = system;
    var usr = await _fit(user, room);
    if (sys.length + usr.length > room) {
      final before = estimateTokens(sys + usr, tpl);
      usr = await _fit(usr, math.max(200, room - sys.length));
      if (sys.length + usr.length > room)
        sys = await _fit(sys, math.max(200, room - usr.length));
      final after = estimateTokens(sys + usr, tpl);
      final batchNote = batch == null
          ? ''
          : ' / batch $batch × %${(PromptBudget.batchShare * 100).round()} (${bud.batchCap} token)';
      final lostChars = math.max(
        0,
        originalPromptChars - sys.length - usr.length,
      );
      _log(
        cb,
        a.name,
        'Prompt ~$before token + $maxNew üretim > bağlam $ctx × %85 (${bud.limit})$batchNote; kırpıldı (~$after token, $lostChars karakter kayıp).',
        LogType.warning,
      );
    }
    if (originalTransfer != null) {
      final marker = usr.indexOf(_prevMarker);
      final retained = marker < 0
          ? ''
          : usr.substring(marker + _prevMarker.length);
      if (retained != originalTransfer) {
        final lost = math.max(0, originalTransfer.length - retained.length);
        _log(
          cb,
          a.name,
          'UYARI: Önceki ajan aktarımı prompt bütçesine sığmadı; $lost karakter aktarılmayacaktı. Kırpılmış içerik modele gönderilmedi, akış durduruldu.',
          LogType.warning,
        );
        throw StateError(
          'Önceki ajan çıktısı bütçeye sığmadı; güvenli aktarım yapılamadı.',
        );
      }
    }
    var prompt = applyTemplate(tpl, sys, usr);
    if (batch != null) {
      // Son savunma: eklenti prompt'u tek llama_decode ile işler; batch'ten uzun prompt native'e gitmemeli.
      final hard = PromptBudget.batchHardCap(batch);
      var est = estimateTokens(prompt, tpl);
      if (est > hard) {
        final beforeChars = usr.length;
        final overhead =
            prompt.length - sys.length - usr.length; // şablon ek yükü
        final allowedUsr =
            (hard * charsPerToken(tpl, prompt)).floor() - overhead - sys.length;
        usr = await _fit(usr, math.max(0, allowedUsr));
        prompt = applyTemplate(tpl, sys, usr);
        final est2 = estimateTokens(prompt, tpl);
        final lostChars = math.max(0, beforeChars - usr.length);
        _log(
          cb,
          a.name,
          'Prompt ~$est token > batch $batch × %${(PromptBudget.batchHardShare * 100).round()} ($hard); '
          'kullanıcı metni kısaltıldı (~$est2 token, $lostChars karakter kayıp).',
          LogType.warning,
        );
        est = est2;
        if (est > hard) {
          _log(
            cb,
            a.name,
            'Prompt ~$est token hâlâ batch $batch × %${(PromptBudget.batchHardShare * 100).round()} ($hard) sınırını aşıyor; üretim başlatılmadı.',
            LogType.warning,
          );
          throw StateError('Prompt batch sınırını aşıyor');
        }
      }
    }
    if (originalTransfer != null) {
      final marker = usr.indexOf(_prevMarker);
      final retained = marker < 0
          ? ''
          : usr.substring(marker + _prevMarker.length);
      if (retained != originalTransfer) {
        final lost = math.max(0, originalTransfer.length - retained.length);
        _log(
          cb,
          a.name,
          'UYARI: Son batch sınırında aktarımın $lost karakteri sığmadı. Kırpılmış içerik modele gönderilmedi, akış durduruldu.',
          LogType.warning,
        );
        throw StateError(
          'Önceki ajan çıktısı batch sınırına sığmadı; güvenli aktarım yapılamadı.',
        );
      }
    }
    if (capturePrompt) {
      final previous = _prompts[a.id];
      _prompts[a.id] = previous == null || previous.isEmpty
          ? prompt
          : '$previous\n\n--- [SONRAKİ PARÇA / YENİ DENEME] ---\n$prompt';
    }
    final b = StringBuffer();
    final done = Completer<void>();
    final guard = ThinkGuard(isR1 ? bud.thinkChars(tpl) : 0);
    var thinkCut = false;
    var events = 0;
    var peakRam = MemInfo.rssMb();
    final genSw = Stopwatch()..start();
    int? firstMs;
    var winStart = DateTime.now();
    var winEvents = 0;
    final promptTok = estimateTokens(prompt, tpl);
    // Bu ajanın örnekleme ayarları native çağrıya gider (bitişte finally'de sıfırlanır).
    SamplingScope.current = a.inference.clamped();
    final sub = _engine
        .generate(prompt, maxTokens: maxNew)
        .listen(
          (t) {
            if (ct.cancelled || thinkCut) return;
            b.write(t);
            cb.token(t);
            events++;
            winEvents++;
            firstMs ??= genSw.elapsedMilliseconds;
            final now = DateTime.now();
            final dt = now.difference(winStart).inMilliseconds;
            if (dt >= 3000) {
              // 3 sn'lik pencerede tok/s -> termal denetleyici
              final r = _gov.onSample(winEvents * 1000 / dt, now);
              if (r != null) {
                _pendingThreads = r;
                _log(
                  cb,
                  a.name,
                  'Termal: tok/s düştü; sonraki yüklemede thread sayısı $r olacak.',
                  LogType.warning,
                );
              }
              winStart = now;
              winEvents = 0;
              peakRam = math.max(peakRam, MemInfo.rssMb());
              DeviceThermal.status().then((v) {
                if (v != null) _gov.osThermalStatus = v;
              });
            }
            if (isR1) {
              guard.add(t);
              if (guard.exceeded && !done.isCompleted) {
                // <think> ayrı bütçeyi aştı: üretimi kes, çıktı mevcut metinden temizlenir.
                thinkCut = true;
                _log(
                  cb,
                  a.name,
                  '<think> bloğu bütçeyi aştı (~${bud.thinkTokens} token); düşünme kesildi.',
                  LogType.warning,
                );
                _engine
                    .stop()
                    .timeout(const Duration(seconds: 2))
                    .catchError((Object _) {});
                done.complete();
              }
            }
          },
          onError: (Object e, StackTrace st) {
            if (!done.isCompleted) done.completeError(e, st);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
    try {
      // Token beklemeden: ya akış biter/hata verir ya da iptal anında çıkılır.
      await Future.any<void>([done.future, ct.onCancel]);
    } finally {
      try {
        await sub.cancel().timeout(const Duration(seconds: 1));
      } catch (_) {}
      SamplingScope.reset();
    }
    if (ct.cancelled) {
      try {
        await _engine.stop().timeout(const Duration(seconds: 2));
      } catch (_) {}
      throw const CancelledException();
    }
    final total = genSw.elapsedMilliseconds;
    final firstTok = firstMs ?? total;
    final genMs = math.max(1, total - firstTok);
    final tps = events > 1 ? (events - 1) * 1000 / genMs : 0.0;
    final prefill = firstTok > 0 ? promptTok * 1000 / firstTok : 0.0;
    peakRam = math.max(peakRam, MemInfo.rssMb());
    unawaited(
      PerfLog.instance.add(
        PerfSample(
          modelId: m.id,
          at: DateTime.now().millisecondsSinceEpoch,
          tokPerSec: tps,
          prefillTokPerSec: prefill,
          firstTokenMs: firstTok,
          loadMs: loadMs,
          peakRamMb: peakRam,
          threads: threads,
          contextSize: ctx,
          promptTokens: promptTok,
          genTokens: events,
        ),
      ),
    );
    return _clean(b.toString());
  }

  /// Termal denetleyicinin önerdiği thread sayısını, motor destekliyorsa uygular (yalnızca ajan sınırında).
  void _applyThreads() {
    final n = _pendingThreads;
    if (n == null || n == _appliedThreads) return;
    try {
      (_engine as dynamic).setThreads(
        n,
      ); // LlmEngine'de yoksa NoSuchMethodError yakalanır
      _appliedThreads = n;
    } catch (_) {
      _pendingThreads = null;
    }
  }

  // ---- Yama biçimi, ayrıştırma ve uygulama (statik; motor gerektirmez) ----

  static const String patchFormatInstruction = """
Kod değişikliklerini tam dosya yerine aşağıdaki yama bloğu biçiminde üret:
<<<<<<< DOSYA: yol
<<<<<<< ESKİ
(dosyadaki mevcut eski kod)
=======
(yeni kod)
>>>>>>> YENİ

Yeni oluşturulacak dosyalar için TAM bloğu kullan:
<<<<<<< DOSYA: yol
<<<<<<< TAM
(yeni dosyanın tam içeriği)
>>>>>>> YENİ
""";

  // Not: Dart'ta \Z yoktur (JS gibi düz 'Z' sayılır); metin sonu için (?![\s\S]) kullanılır.
  static final RegExp _patchBlockRe = RegExp(
    r'<<<<<<<\s*DOSYA:\s*([^\r\n]+)\r?\n([\s\S]*?)(?:>>>>>>>\s*(?:YEN[İIi]|TAM)|(?![\s\S]))',
  );
  static final RegExp _tamRe = RegExp(r'<<<<<<<\s*TAM');
  static final RegExp _eskiRe = RegExp(r'<<<<<<<\s*ESK[İIi]');

  /// Yanıttan yama bloklarını ayrıştırır.
  static List<PatchBlock> parsePatches(String response) {
    final patches = <PatchBlock>[];
    for (final m in _patchBlockRe.allMatches(response)) {
      final path = m.group(1)!.trim();
      final body = m.group(2) ?? '';
      final raw = m.group(0)!;

      final tam = _tamRe.firstMatch(body);
      if (tam != null) {
        patches.add(
          PatchBlock(
            filePath: path,
            isNewFile: true,
            newCode: _cleanPatch(body.substring(tam.end)),
            rawBlock: raw,
          ),
        );
        continue;
      }

      final eski = _eskiRe.firstMatch(body);
      final from = eski?.end ?? 0;
      final sep = body.indexOf('=======', from);
      if (sep == -1) continue; // ayrıştırılamayan blok atlanır
      patches.add(
        PatchBlock(
          filePath: path,
          isNewFile: false,
          oldCode: _cleanPatch(body.substring(from, sep)),
          newCode: _cleanPatch(body.substring(sep + 7)),
          rawBlock: raw,
        ),
      );
    }
    return patches;
  }

  /// Baştaki ve sondaki TEK satır sonunu atar (girinti korunur).
  static String _cleanPatch(String s) {
    if (s.startsWith('\r\n')) {
      s = s.substring(2);
    } else if (s.startsWith('\n')) {
      s = s.substring(1);
    }
    if (s.endsWith('\r\n')) {
      s = s.substring(0, s.length - 2);
    } else if (s.endsWith('\n')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Yamayı bellekteki çalışma alanına uygular: önce birebir, sonra boşluk normalleştirilmiş eşleşme.
  static PatchApplyResult applyPatch(
    PatchBlock patch,
    Map<String, String> workspace,
  ) {
    if (patch.isNewFile) {
      workspace[patch.filePath] = patch.newCode;
      return PatchApplyResult(success: true, patch: patch);
    }
    PatchApplyResult fail(String e) =>
        PatchApplyResult(success: false, patch: patch, error: e);

    final current = workspace[patch.filePath];
    if (current == null)
      return fail('Dosya çalışma alanında bulunamadı: ${patch.filePath}');
    final old = patch.oldCode ?? '';
    if (old.trim().isEmpty) return fail('Eski kod bloğu boş.');

    // 1. Birebir eşleşme (replaceFirst yerine dilimleme: yeni kodda '$' yorumlanmaz)
    final at = current.indexOf(old);
    if (at != -1) {
      workspace[patch.filePath] =
          current.substring(0, at) +
          patch.newCode +
          current.substring(at + old.length);
      return PatchApplyResult(success: true, patch: patch);
    }

    // 2. Boşluk normalleştirilmiş, satır bazlı eşleşme
    String norm(String x) => x.trim().replaceAll(RegExp(r'\s+'), ' ');
    final lines = current.split('\n');
    final normOld = old.split('\n').map(norm).toList();
    for (var i = 0; i <= lines.length - normOld.length; i++) {
      var ok = true;
      for (var j = 0; j < normOld.length; j++) {
        if (norm(lines[i + j]) != normOld[j]) {
          ok = false;
          break;
        }
      }
      if (ok) {
        lines.replaceRange(i, i + normOld.length, patch.newCode.split('\n'));
        workspace[patch.filePath] = lines.join('\n');
        return PatchApplyResult(success: true, patch: patch);
      }
    }
    return fail('Eski kod bloğu hedef dosyada eşleşmedi.');
  }

  /// Uygulanamayan yamayı BİR kez yeniden ister ([reinfer]); olmazsa loglayıp atlar.
  /// İptal ([CancelledException]) yutulmaz.
  static Future<List<PatchBlock>> applyPatchesWithRetry(
    List<PatchBlock> patches,
    Map<String, String> workspace,
    Future<String> Function(String prompt) reinfer, {
    void Function(String message)? onLog,
  }) async {
    final applied = <PatchBlock>[];
    for (final patch in patches) {
      final r = applyPatch(patch, workspace);
      if (r.success) {
        applied.add(patch);
        continue;
      }
      onLog?.call(
        'Yama uygulanamadı (${r.error}), yeniden isteniyor: ${patch.filePath}',
      );
      final prompt =
          """
Aşağıdaki yama bloğu güncel kod ile eşleşmediği için uygulanamadı:
${patch.rawBlock}

Dosyanın (${patch.filePath}) mevcut güncel içeriği:
${workspace[patch.filePath] ?? '(dosya mevcut değil)'}

Lütfen sadece bu yama bloğunu güncel koddaki satırlarla birebir eşleşecek şekilde düzeltip tekrar üret:
<<<<<<< DOSYA: ${patch.filePath}
<<<<<<< ESKİ
(dosyadaki mevcut kod)
=======
(yeni kod)
>>>>>>> YENİ
""";
      try {
        var ok = false;
        for (final rp in parsePatches(await reinfer(prompt))) {
          if (applyPatch(rp, workspace).success) {
            applied.add(rp);
            ok = true;
            onLog?.call('Yeniden denenen yama uygulandı: ${rp.filePath}');
            break;
          }
        }
        if (!ok)
          onLog?.call(
            'Yeniden denenen yama da uygulanamadı, atlandı: ${patch.filePath}',
          );
      } on CancelledException {
        rethrow;
      } catch (e) {
        if (_isEmptyModelAnswer(e)) rethrow;
        onLog?.call('Yama yeniden deneme sırasında hata: $e, atlandı.');
      }
    }
    return applied;
  }

  // ---- Denetçi döngüsü ----

  static const String _outKey = 'çıktı';
  static final RegExp _fenceRe = RegExp(
    r'```([^\n`]*)\n(.*?)```',
    dotAll: true,
  );

  /// Yalnızca Dart kod bloklarında yerel statik denetim (diğer diller/düzyazıda yanlış alarm verir).
  List<String> _localIssues(String out) {
    final issues = <String>[];
    for (final m in _fenceRe.allMatches(out)) {
      if (!(m.group(1) ?? '').toLowerCase().contains('dart')) continue;
      issues.addAll(
        LocalStaticChecker.checkFile(
          '$_outKey.dart',
          m.group(2) ?? '',
          const <String>{},
        ),
      );
    }
    return issues;
  }

  /// Denetçi çıkarımı: hata akışı öldürmez (iptal hariç); uyarı loglanır, null döner.
  Future<String?> _auditSafe(
    AgentConfig d,
    String system,
    String user,
    List<GgufModel> models,
    RunCallbacks cb,
    CancelToken ct,
  ) async {
    try {
      return await _inferRetry(
        d,
        system,
        user,
        models,
        cb,
        ct,
        short: true,
        capturePrompt: true,
      );
    } on CancelledException {
      rethrow;
    } catch (e) {
      if (_isEmptyModelAnswer(e)) rethrow;
      _log(
        cb,
        d.name,
        'Uyarı: Denetçi çıkarımı sırasında hata oluştu: $e. Akış devam ediyor.',
        LogType.warning,
      );
      return null;
    }
  }

  /// Üretici çıkarımı hata verirse bir kez yeniden dener (iptal hariç).
  Future<String> _inferRetry(
    AgentConfig a,
    String system,
    String user,
    List<GgufModel> models,
    RunCallbacks cb,
    CancelToken ct, {
    bool requireValidTransfer = false,
    bool capturePrompt = false,
    bool short = false,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final output = await _infer(
          a,
          system,
          user,
          models,
          cb,
          ct,
          short: short,
          capturePrompt: capturePrompt,
        );
        if (requireValidTransfer) {
          final invalid = _invalidTransferOutput(output);
          if (invalid != null)
            throw StateError('Ajan çıktısı kabul edilmedi: $invalid.');
        }
        return output;
      } on CancelledException {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt == 1) {
          _log(
            cb,
            a.name,
            'Ajan çıktısı/çıkarımı geçersiz: $e. Bir kez yeniden deneniyor.',
            LogType.warning,
          );
        }
      }
    }
    throw StateError(
      'Ajan "${a.name}" iki denemede de geçerli çıktı üretemedi: $lastError',
    );
  }

  int _transferChunkChars(
    AgentConfig a,
    String system,
    String userBase,
    List<GgufModel> models,
  ) {
    var tpl = ChatTemplate.chatml;
    for (final model in models) {
      if (model.id == a.modelId) tpl = model.template;
    }
    final budget = PromptBudget.of(
      _engine.contextSize ?? 2048,
      deepseek: tpl == ChatTemplate.deepseek,
      share: _ctxShare,
      batch: _engine.batchSize,
    );
    final overhead = applyTemplate(tpl, '', '').length;
    final room = budget.promptChars(tpl, 'ç', overhead);
    // Turkish is the conservative chars/token estimate; reserve room for separators,
    // transfer labels, and estimator error so _infer never has to trim the payload.
    return math.max(
      0,
      room - system.length - userBase.length - _prevMarker.length - 180,
    );
  }

  String _transferPreview(String value, {String? part}) {
    final first = value.substring(0, math.min(200, value.length));
    final last = value.substring(math.max(0, value.length - 200));
    return 'AKTARIM${part == null ? '' : ' ($part)'}: ${value.length} karakter; '
        'ilk 200: «$first»; son 200: «$last»';
  }

  void _recordTransfer(
    RunCallbacks cb,
    String from,
    String to,
    String content, {
    String? part,
  }) {
    final message = '$from → $to | ${_transferPreview(content, part: part)}';
    _log(cb, to, message, LogType.info);
    cb.transfer?.call(message);
  }

  Future<String> _summarizeOverflow(
    AgentConfig a,
    String previous,
    List<GgufModel> models,
    RunCallbacks cb,
    CancelToken ct,
    int targetLimit,
  ) async {
    const summarySystem =
        'Önceki ajan çıktısının parçaları verilecek. Yalnızca kaynakta bulunan bilgileri koruyan kısa bir özeti çıkar. '
        'Yeni bilgi ekleme, çıkarım yapma veya kaynakta olmayan ayrıntı üretme.';
    const summaryBase =
        'Aşağıdaki kaynak parçasının bilgi ve işaretlerini sadakatle özetle:';
    final summarySystemWithTask = _withTask(summarySystem);
    final summaryLimit = _transferChunkChars(
      a,
      summarySystemWithTask,
      summaryBase,
      models,
    );
    if (summaryLimit < 80) {
      throw StateError(
        'Aktarım parçalara ayrılamadı ve güvenli özet promptu için de yeterli bütçe yok.',
      );
    }

    var current = previous;
    for (var round = 1; round <= 3; round++) {
      final chunks = ChunkPlanner.planTransferUnits(
        'önceki-ajan-çıktısı',
        current,
        summaryLimit,
      );
      final summaries = <String>[];
      for (final unit in chunks) {
        _check(ct);
        final label = 'Özet $round · ${unit.statusLine}';
        _recordTransfer(
          cb,
          a.name,
          '${a.name} (özet adımı)',
          unit.content,
          part: label,
        );
        final summaryUser = '$summaryBase\n\n$_prevMarker${unit.content}';
        summaries.add(
          await _inferRetry(
            a,
            summarySystemWithTask,
            summaryUser,
            models,
            cb,
            ct,
            requireValidTransfer: true,
            capturePrompt: true,
          ),
        );
      }
      final reduced = summaries.join('\n\n');
      if (reduced.length <= targetLimit) return reduced;
      if (reduced.length >= current.length) {
        throw StateError(
          'Ara özet aktarım boyutunu küçültmedi; veri kaybını önlemek için akış durduruldu.',
        );
      }
      current = reduced;
    }
    if (current.length > targetLimit) {
      throw StateError(
        'Ara özet hedef ajanın prompt bütçesine sığmadı; akış durduruldu.',
      );
    }
    return current;
  }

  Future<String> _runAgentStage(
    List<AgentConfig> agents,
    int index,
    String previous,
    String previousAgentName,
    List<GgufModel> models,
    RunCallbacks cb,
    CancelToken ct,
  ) async {
    final a = agents[index];
    final system = _system(a, index);
    final userBase = _user(a, index, '');
    _prompts[a.id] = '';

    if (index == 0 || previous.isEmpty) {
      return _inferRetry(
        a,
        system,
        _user(a, index, previous),
        models,
        cb,
        ct,
        requireValidTransfer: true,
        capturePrompt: true,
      );
    }

    final from = previousAgentName.isEmpty
        ? agents[index - 1].name
        : previousAgentName;
    final maxChars = _transferChunkChars(a, system, userBase, models);
    _recordTransfer(cb, from, a.name, previous);
    if (previous.length <= maxChars) {
      return _inferRetry(
        a,
        system,
        _user(a, index, previous),
        models,
        cb,
        ct,
        requireValidTransfer: true,
        capturePrompt: true,
      );
    }

    if (maxChars < 80) {
      final compact = await _summarizeOverflow(
        a,
        previous,
        models,
        cb,
        ct,
        math.max(80, maxChars),
      );
      return _inferRetry(
        a,
        system,
        _user(a, index, compact),
        models,
        cb,
        ct,
        requireValidTransfer: true,
        capturePrompt: true,
      );
    }

    final units = ChunkPlanner.planTransferUnits(
      'önceki-ajan-çıktısı',
      previous,
      maxChars,
    );
    _log(
      cb,
      a.name,
      'Önceki çıktı kırpılmadan ${units.length} parçaya bölündü; her parça ayrı işlenecek.',
      LogType.info,
    );
    final outputs = <String>[];
    for (final unit in units) {
      _check(ct);
      cb.status('${unit.statusLine} · ${a.name} aktarılan parçayı işliyor...');
      _recordTransfer(cb, from, a.name, unit.content, part: unit.statusLine);
      final rawUser = _user(a, index, unit.content);
      final markerAt = rawUser.indexOf(_prevMarker);
      final chunkNote =
          '[AKTARIM NOTU: Bu, ${unit.unitIndex}/${unit.totalUnits} parçadan biridir. '
          'Yalnızca bu parçada bulunan içeriği işle; eksik parçaları tahmin etme.]';
      final user = markerAt < 0
          ? rawUser
          : '${rawUser.substring(0, markerAt)}$chunkNote\n\n${rawUser.substring(markerAt)}';
      outputs.add(
        await _inferRetry(
          a,
          system,
          user,
          models,
          cb,
          ct,
          requireValidTransfer: true,
          capturePrompt: true,
        ),
      );
    }
    return outputs.join('\n\n');
  }

  /// Denetim parçalarının karakter bütçesi: sabit kısımlar ([fixedChars]) düşüldükten sonra kalan alan.
  int _auditChunkChars(AgentConfig d, List<GgufModel> models, int fixedChars) {
    var tpl = ChatTemplate.chatml;
    for (final x in models) {
      if (x.id == d.modelId) tpl = x.template;
    }
    final bud = PromptBudget.of(
      _engine.contextSize ?? 2048,
      deepseek: tpl == ChatTemplate.deepseek,
      shortAnswer: true,
      share: _ctxShare,
      batch: _engine.batchSize,
    );
    final room = bud.promptChars(tpl, 'ç', applyTemplate(tpl, '', '').length);
    return math.max(400, room - fixedChars - 200);
  }

  /// Hata raporu: en çok 8 satır / 600 karakter (düzeltme isteminde kırpılmadan korunur).
  static String _boundedReport(String local, String ai) {
    final lines = '$local\n$ai'
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .take(8)
        .toList();
    final r = lines.join('\n');
    return r.length > 600 ? '${r.substring(0, 597)}...' : r;
  }

  /// Denetçi döngüsü:
  /// - En çok N denetim ve N düzeltme (asla N+1 değil); son düzeltmeden sonra yeniden denetim yoktur.
  /// - Çıktı kırpılmadan, bütçeye göre PARÇA PARÇA denetçiye sunulur.
  /// - Düzeltme yalnızca hatalı parça için YAMA bloğu olarak istenir ve çıktıya uygulanır.
  Future<String> _debugLoop(
    List<AgentConfig> agents,
    int i,
    String first,
    List<GgufModel> models,
    RunCallbacks cb,
    CancelToken ct, {
    bool codeMode = false,
  }) async {
    final d = agents[i];
    final g = agents[i - 1];
    final nMax = d.maxLoops < 1 ? 1 : d.maxLoops;
    const chunkNote =
        'Çıktı parça halinde sunulabilir; parçanın başı veya sonu eksik görünmesi hata değildir, yalnızca parça içindeki gerçek hataları bildir.';
    final dSystem =
        '${_withTask(d.systemPrompt)}\nYanıtının ilk satırı yalnızca [STATUS: ERROR] veya [STATUS: SUCCESS] olmalı. Hata varsa en fazla 8 satırda kısa rapor yaz; uzun açıklama yapma.';
    if (d.modelId != g.modelId) {
      // Üretici ve denetçi farklı model: her döngüde unload+load (4-5 GB). Tek model RAM'de tutulabilir
      // (eklenti tekil FlutterLlama.instance); aynı modeli seçmek yüklemeyi tamamen önler.
      _log(
        cb,
        d.name,
        'Uyarı: denetçi (${d.modelId}) ve üretici (${g.modelId}) farklı model; her döngüde yeniden yükleme olur. Aynı modeli seçmek hızlandırır.',
        LogType.warning,
      );
    }
    var out = first;
    for (var k = 1; k <= nMax; k++) {
      _check(ct);
      cb.agent(d.id, AgentStatus.looping, k);
      cb.status('${i + 1}. AI Hata Analizi Yapıyor... (Döngü: $k/$nMax)');
      _log(
        cb,
        d.name,
        'Hata denetimi icra ediliyor. Döngü k = $k, N = $nMax',
        LogType.loop,
      );

      final att = _attachText(d);
      final attPart = att.isEmpty ? '' : '\n\n--- [EK DOSYALAR] ---\n$att';
      final localIssues = codeMode ? _localIssues(out) : const <String>[];
      final localReport = localIssues.isEmpty
          ? ''
          : LocalStaticChecker.formatReport(localIssues);
      final localPart = localReport.isEmpty
          ? ''
          : '\n\n--- [YEREL STATİK DENETİM] ---\n$localReport';

      // Parçalama: çıktı bütçeye sığıyorsa tek parça (eski istemle aynı), sığmıyorsa satır sınırlarından bölünür.
      final fixed =
          dSystem.length +
          _taskPrefix.length +
          d.userPrompt.length +
          attPart.length +
          localPart.length +
          chunkNote.length +
          60;
      final chunkChars = _auditChunkChars(d, models, fixed);
      final units = ChunkPlanner.planFileUnits(
        _outKey,
        out,
        chunkChars,
        onLog: (m) => _log(cb, d.name, m, LogType.info),
      );
      final multi = units.length > 1;

      WorkUnit? faulty;
      var aiReport = '';
      var answered = 0;
      for (final unit in units) {
        _check(ct);
        if (multi) cb.status('${unit.statusLine} · Denetim (Döngü: $k/$nMax)');
        final body = multi ? unit.content : out;
        final head = multi
            ? '--- [DENETLENECEK ÇIKTI · ${unit.statusLine}] ---'
            : '--- [DENETLENECEK ÇIKTI] ---';
        final dUser =
            '$_taskPrefix${d.userPrompt}$attPart$localPart\n\n$head\n$body';
        final report = await _auditSafe(
          d,
          multi ? '$dSystem\n$chunkNote' : dSystem,
          dUser,
          models,
          cb,
          ct,
        );
        _check(ct);
        if (report == null)
          continue; // denetçi hata verdi: bu parça doğrulanamadı, akış sürer
        answered++;
        if (_isError(report)) {
          faulty = unit;
          aiReport = report;
          break;
        }
      }

      if (faulty == null) {
        if (answered == 0) {
          _log(
            cb,
            d.name,
            'Uyarı: denetçi hiçbir parçayı doğrulayamadı; çıktı denetlenmeden devrediliyor.',
            LogType.warning,
          );
        } else {
          _log(
            cb,
            d.name,
            '[STATUS: SUCCESS] Doğrulama onaylandı. Döngü sonlandırıldı.',
            LogType.success,
          );
        }
        break;
      }

      _log(
        cb,
        d.name,
        '[STATUS: ERROR] Hata raporu $i. AI\'a geri yönlendiriliyor (${faulty.statusLine}).',
        LogType.warning,
      );
      _check(ct);
      cb.agent(g.id, AgentStatus.running, 0);
      cb.status('$i. AI Hatayı Düzeltiyor... (Döngü: $k/$nMax)');
      final fixReport = _boundedReport(localReport, aiReport);
      final fixUser =
          '$_taskPrefix[TALİMAT]: Denetçi aşağıdaki hataları tespit etti. Yalnızca bu hatalı parçayı düzelten bir yama bloğu üret. '
          'DOSYA yolu olarak tam olarak "$_outKey" yaz.\n'
          '[ORİJİNAL GÖREV]: ${g.userPrompt}\n'
          '[HATA RAPORU]:\n$fixReport\n\n'
          '[HATALI PARÇA] (${faulty.filePath} satır ${faulty.startLine}-${faulty.endLine}):\n${faulty.content}\n\n'
          '$patchFormatInstruction';
      try {
        final fixResponse = await _inferRetry(
          g,
          _withTask(g.systemPrompt),
          fixUser,
          models,
          cb,
          ct,
          capturePrompt: true,
        );
        // Model yol olarak başka bir ad yazsa bile tek çalışma alanı dosyasına yönlendirilir.
        final patches = [
          for (final p in parsePatches(fixResponse))
            PatchBlock(
              filePath: _outKey,
              isNewFile: false,
              oldCode: p.oldCode,
              newCode: p.newCode,
              rawBlock: p.rawBlock,
            ),
        ].where((p) => p.oldCode != null).toList();
        if (patches.isEmpty) {
          _log(
            cb,
            g.name,
            'Düzeltme geçerli bir yama bloğu üretmedi; çıktı değişmedi.',
            LogType.warning,
          );
        } else {
          final ws = <String, String>{_outKey: out};
          await applyPatchesWithRetry(
            patches,
            ws,
            (prompt) => _inferRetry(
              g,
              _withTask(g.systemPrompt),
              _withTask(prompt),
              models,
              cb,
              ct,
              capturePrompt: true,
            ),
            onLog: (m) => _log(cb, g.name, m, LogType.info),
          );
          out = ws[_outKey]!;
        }
      } on CancelledException {
        rethrow;
      } catch (e) {
        if (_isEmptyModelAnswer(e)) rethrow;
        _log(
          cb,
          g.name,
          'Düzeltme çıkarımı sırasında hata: $e',
          LogType.warning,
        );
      }
      cb.agent(g.id, AgentStatus.completed, 0);
      if (k == nMax) {
        _log(
          cb,
          d.name,
          'Denetim ve düzeltme sınırına ulaşıldı ($nMax denetim, $nMax düzeltme). Akış sonraki ajana devrediliyor.',
          LogType.warning,
        );
      }
    }
    return out;
  }

  /// Çıktıyı üreten (sözleşmenin ekleneceği) ajan: sondan başlayarak, atlanmayan ve denetçi
  /// OLMAYAN ilk ajan. Denetçi metni yalnızca onaylar/yamalar; biçimi önceki ajan belirler.
  static int _producerIndex(List<AgentConfig> agents) {
    for (var i = agents.length - 1; i >= 0; i--) {
      final a = agents[i];
      if (a.optional) continue;
      if (a.mode == AgentMode.debugger && i > 0) continue;
      return i;
    }
    return -1;
  }

  /// Ajan çıktısını arayüze bildirir (kayıt `agentId` ile değiştirilir).
  void _emitOutput(
    RunCallbacks cb,
    AgentConfig a,
    int order,
    AgentOutputStatus status, {
    String content = '',
    String? note,
  }) => cb.agentOutput?.call(
    AgentOutput.of(
      agentId: a.id,
      order: order,
      name: a.name,
      role: a.mode.name.toUpperCase(),
      status: status,
      content: content,
      note: note,
    ),
  );

  void _emitValidator(
    RunCallbacks cb,
    int order,
    AgentOutputStatus status, {
    String content = '',
    String? note,
  }) => cb.agentOutput?.call(
    AgentOutput.of(
      agentId: AgentOutput.validatorId,
      order: order,
      name: 'Çıktı Doğrulayıcı',
      role: 'DOĞRULAYICI',
      status: status,
      content: content,
      note: note,
    ),
  );

  /// Hata mesajı kullanıcıya gösterilecek biçimde sadeleştirilir; think-only için açıklama eklenir.
  String _failureNote(Object e) {
    var t = e.toString().replaceFirst('Bad state: ', '');
    if (_isEmptyModelAnswer(e)) {
      t +=
          ' (Model yalnızca <think> düşüncesi üretti veya boş döndü; üretim payı düşünceyle tükenmiş olabilir. '
          'Bu ajan için Qwen modeli seçmeyi veya görevi parçalamayı dene.)';
    }
    return t;
  }

  /// Akış başlamadan önce: ilk (atlanmayan) ajanın modeli yüklenir ve bağlam/bütçe küçükse kullanıcıya
  /// uyarı gösterilir. Bağlam boyutu ancak model yüklenince bilindiği için ilk üretimden hemen önce yapılır.
  /// Yükleme hatası burada yutulur; aynı hata ilk ajanın çıkarımında zaten (kayıt temizliğiyle) raporlanır.
  Future<void> _preflight(
    List<AgentConfig> agents,
    List<GgufModel> models,
    RunCallbacks cb,
    CancelToken ct,
  ) async {
    AgentConfig? first;
    for (final a in agents) {
      if (!a.optional) {
        first = a;
        break;
      }
    }
    if (first == null) return;
    GgufModel? m;
    for (final x in models) {
      if (x.id == first.modelId) m = x;
    }
    if (m == null || !m.isCached) return;
    try {
      await _engine.ensureLoaded(m.localPath!, expectedBytes: m.sizeBytes);
    } catch (_) {
      return;
    }
    _check(ct);
    final ctx = _engine.contextSize;
    if (ctx == null) return;
    final warning = lowContextWarning(
      ctx,
      batch: _engine.batchSize,
      template: m.template,
    );
    if (warning == null) return;
    _log(cb, 'Sistem / Bağlam', warning, LogType.warning);
    cb.notice?.call(warning);
  }

  /// DeepSeek R1 gibi akıl yürütme modelleri yalnızca denetçi (debugger) olarak önerilir:
  /// üretici/dönüştürücü olarak <think> bütçesini aşıp anlamsız çıktı verebilir.
  void _warnIfReasoningModel(
    RunCallbacks cb,
    AgentConfig a,
    List<GgufModel> models,
  ) {
    if (a.mode == AgentMode.debugger) return;
    for (final m in models) {
      if (m.id == a.modelId && m.template == ChatTemplate.deepseek) {
        _log(
          cb,
          a.name,
          'Uyarı: ${m.name} akıl yürütme modelidir; üretici/dönüştürücü ajanda <think> bütçesini aşıp '
          'anlamsız çıktı verebilir. Bu ajan için bir Qwen modeli seçmeniz önerilir.',
          LogType.warning,
        );
        return;
      }
    }
  }

  /// Dosya üretilmeden önce nihai çıktıyı biçim sözleşmesine ve göreve karşı denetler.
  /// Başarısızsa içerik üreten son ajanı en çok [correctionAttempts] kez düzeltme talimatıyla yeniden
  /// çalıştırır (her deneme son denemenin sorunlarını bildirir; aynı sorunlar tekrarlanırsa erken durur);
  /// yine başarısızsa [OutputValidationException] fırlatır (dosya üretilmez, içerik istisnada saklanır).
  Future<String> _enforceContract(
    Workflow wf,
    List<AgentConfig> agents,
    int producerIdx,
    String producerInput,
    String producerFrom,
    String output,
    List<GgufModel> models,
    RunCallbacks cb,
    CancelToken ct,
  ) async {
    final format = wf.targetFormat;
    if (!OutputContract.appliesTo(format)) return output;
    const who = 'Çıktı Doğrulayıcı';
    cb.status('Çıktı ${format.product} biçim sözleşmesine göre doğrulanıyor...');
    final first = OutputValidator.validate(
      format: format,
      task: wf.task,
      output: output,
      base: _base,
    );
    final vOrder = agents.length + 1;
    if (first.ok) {
      _log(
        cb,
        who,
        'Biçim sözleşmesi ve görev uyumu doğrulandı (${format.name.toUpperCase()}).',
        LogType.success,
      );
      _emitValidator(
        cb,
        vOrder,
        AgentOutputStatus.ok,
        note: 'Biçim sözleşmesi ve görev uyumu doğrulandı.',
      );
      return output;
    }
    _log(cb, who, 'Doğrulama başarısız: ${first.summary}', LogType.warning);

    var best = output;
    var bestResult = first;
    var lastResult = first;
    String? retryError;
    var attemptsMade = 0;
    if (producerIdx >= 0) {
      final a = agents[producerIdx];
      final maxAttempts = correctionAttempts < 1 ? 1 : correctionAttempts;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        _check(ct);
        attemptsMade = attempt;
        cb.agent(a.id, AgentStatus.running, 0);
        cb.status(
          '${producerIdx + 1}. AI çıktıyı biçim sözleşmesine göre düzeltiyor ($attempt/$maxAttempts)...',
        );
        _log(
          cb,
          a.name,
          maxAttempts == 1
              ? 'Çıktı doğrulamadan geçemedi; içerik üreten son ajan düzeltme talimatıyla bir kez yeniden çalıştırılıyor.'
              : 'Çıktı doğrulamadan geçemedi; içerik üreten son ajan düzeltme talimatıyla yeniden çalıştırılıyor (deneme $attempt/$maxAttempts).',
          LogType.loop,
        );
        final firstPrompt = _prompts[a.id] ?? '';
        // Talimat, SON denemenin sorunlarını içerir (ajan güncel hatayı düzeltsin).
        _correction = OutputContract.correction(format, lastResult.problems);
        var stop = false;
        try {
          final retried = await _runAgentStage(
            agents,
            producerIdx,
            producerInput,
            producerFrom,
            models,
            cb,
            ct,
          );
          final second = OutputValidator.validate(
            format: format,
            task: wf.task,
            output: retried,
            base: _base,
          );
          if (second.ok) {
            final reviewedAfter = agents
                .skip(producerIdx + 1)
                .any((x) => !x.optional && x.mode == AgentMode.debugger);
            _log(
              cb,
              who,
              reviewedAfter
                  ? 'Düzeltilen çıktı doğrulandı (denetçi bu çıktıyı yeniden incelemedi).'
                  : 'Düzeltilen çıktı doğrulandı.',
              LogType.success,
            );
            _emitOutput(
              cb,
              a,
              producerIdx + 1,
              AgentOutputStatus.corrected,
              content: retried,
              note: attempt == 1
                  ? 'İlk çıktı doğrulamadan geçemedi (${first.summary}); düzeltme talimatıyla yeniden üretildi.'
                  : 'İlk çıktı doğrulamadan geçemedi (${first.summary}); $attempt. düzeltme denemesinde doğrulandı.',
            );
            _emitValidator(
              cb,
              vOrder,
              AgentOutputStatus.ok,
              note: attempt == 1
                  ? 'İlk çıktı geçersizdi; düzeltilen çıktı doğrulandı.'
                  : 'İlk çıktı geçersizdi; $attempt. düzeltme denemesinde doğrulandı.',
            );
            return retried;
          }
          _log(
            cb,
            who,
            'Düzeltme denemesi $attempt/$maxAttempts doğrulamadan geçemedi: ${second.summary}',
            LogType.warning,
          );
          if (second.problems.length <= bestResult.problems.length) {
            best = retried;
            bestResult = second;
          }
          // İlerleme yoksa (aynı sorunlar) kalan denemeler boşa model çalıştırır: dur.
          if (second.summary == lastResult.summary) {
            _log(
              cb,
              who,
              'Aynı sorunlar tekrarlandı; kalan düzeltme denemeleri atlandı.',
              LogType.warning,
            );
            stop = true;
          }
          lastResult = second;
        } on CancelledException {
          rethrow;
        } catch (e) {
          retryError = _failureNote(e);
          _log(cb, a.name, 'Düzeltme denemesi başarısız: $e', LogType.warning);
          stop = true;
        } finally {
          _correction = '';
          final retryPrompt = _prompts[a.id] ?? '';
          _prompts[a.id] = firstPrompt.isEmpty
              ? retryPrompt
              : '$firstPrompt\n\n--- [DÜZELTME DENEMESİ $attempt] ---\n$retryPrompt';
          cb.agent(a.id, AgentStatus.completed, 0);
        }
        if (stop) break;
      }
    }

    _log(
      cb,
      who,
      attemptsMade > 1
          ? '$attemptsMade düzeltme denemesinden sonra da geçersiz; dosya oluşturulmadı: ${bestResult.summary}'
          : 'Düzeltmeden sonra da geçersiz; dosya oluşturulmadı: ${bestResult.summary}',
      LogType.error,
    );
    if (producerIdx >= 0) {
      _emitOutput(
        cb,
        agents[producerIdx],
        producerIdx + 1,
        AgentOutputStatus.failed,
        content: best,
        note: retryError != null
            ? 'Düzeltme denemesi başarısız: $retryError'
            : attemptsMade > 1
            ? '$attemptsMade düzeltme denemesi yapıldı ama çıktı yine doğrulamadan geçemedi.'
            : 'Düzeltme talimatıyla yeniden çalıştırıldı ama çıktı yine doğrulamadan geçemedi.',
      );
    }
    _emitValidator(
      cb,
      vOrder,
      AgentOutputStatus.failed,
      content: best,
      note: bestResult.summary,
    );
    throw OutputValidationException(
      workflowId: wf.id,
      format: format,
      title: wf.title,
      content: best,
      problems: bestResult.problems,
    );
  }

  /// "Yine de indir": doğrulamayı atlayarak [content]'ten dosya üretir.
  Future<Artifact> buildAnyway({
    required OutputFormat format,
    required String title,
    required String content,
    String task = '',
    String? baseProject,
  }) async => _files.build(
    format: format,
    title: title,
    content: content,
    dir: await _storage.outputsDir(),
    task: task,
    base: baseProject == null ? null : await ProjectSource.load(baseProject),
  );

  /// Geliştirme Modu: bir turda modele gösterilecek kod parçasının yaklaşık karakter üst sınırı.
  /// Bağlam boyutu model yüklenince belli olur; bilinmiyorsa muhafazakâr (2048) varsayılır.
  /// Parça, hata raporu ve talimatlarla birlikte prompt'a sığmalıdır; bu yüzden ek bütçesinin %75'i alınır
  /// (ek bütçesi zaten prompt alanının ~%45'idir, yani parça prompt'un yaklaşık üçte biri olur).
  int devChunkChars() {
    final cap = PromptBudget.of(
      _engine.contextSize ?? 2048,
      share: _ctxShare,
      batch: _engine.batchSize,
    ).attachChars(ChatTemplate.chatml, 'ç');
    final v = (cap * 0.75).floor();
    return v < 1200 ? 1200 : (v > 6000 ? 6000 : v);
  }

  /// Geliştirme Modu: [agent]'ı verilen sistem/kullanıcı metniyle TEK seferlik çalıştırır
  /// (geçersiz çıktıda bir kez yeniden dener) ve temizlenmiş metni döner. Dosya üretmez,
  /// görev bloğu eklemez; ağır iş ([_infer]: model yükleme, bütçe, kırpma, iptal) mevcut yolu kullanır.
  Future<String> inferOnce({
    required AgentConfig agent,
    required String system,
    required String user,
    required List<GgufModel> models,
    required RunCallbacks cb,
    required CancelToken ct,
  }) {
    _task = ''; // görev bloğu yok: talimat prompt'un kendisinde
    _contractFormat = null;
    _contractAgentId = null;
    _correction = '';
    return _inferRetry(agent, system, user, models, cb, ct);
  }

  Future<Artifact> run(
    Workflow wf,
    List<GgufModel> models,
    RunCallbacks cb,
    CancelToken ct,
  ) async {
    var agents = [...wf.agents]..sort((a, b) => a.order.compareTo(b.order));
    _base = null;
    final baseRef = wf.baseProject;
    if (baseRef != null && baseRef.isNotEmpty) {
      cb.status('Geliştirilecek proje okunuyor...');
      _base = await ProjectSource.load(baseRef);
      _check(ct);
      // Proje özeti, üretici ajanlara EK DOSYA olarak verilir (kalıcı akış verisine yazılmaz).
      final digest = AttachedFile(
        id: 'project-digest',
        name: 'PROJE_OZETI.md',
        content: _base!.digest(wf.task),
        size: 0,
      );
      agents = [
        for (final a in agents)
          a.mode == AgentMode.generator && !a.optional
              ? a.copyWith(attachedFiles: [...a.attachedFiles, digest])
              : a,
      ];
    }
    _prompts.clear();
    _task = wf.task.trim();
    _gov.reset();
    _pendingThreads = null;
    _lowBudgetWarned = false;
    final producerIdx = _producerIndex(agents);
    _contractFormat = wf.targetFormat;
    _contractAgentId = producerIdx >= 0 ? agents[producerIdx].id : null;
    _correction = '';
    var producerInput = '';
    var producerFrom = '';
    final fileCount = agents.fold<int>(0, (s, a) => s + a.attachedFiles.length);
    cb.status('Zipten çıkarılıyor ve dosya verileri okunuyor...');
    _log(
      cb,
      'Sistem / I-O Motoru',
      fileCount > 0
          ? '$fileCount adet dosya/arşiv bellek içi tampona açıldı.'
          : 'Girdi verileri ve sistem bağlamı bellek tamponuna yüklendi.',
      LogType.info,
    );
    await _pause(_pauseStart, ct);
    await _preflight(agents, models, cb, ct);
    var prev = '';
    var prevAgentName = '';
    for (var i = 0; i < agents.length; i++) {
      _check(ct);
      final a = agents[i];
      final n = i + 1;
      if (a.optional) {
        _prompts[a.id] = '[BU AJAN İSTEĞE BAĞLI OLDUĞU İÇİN ATLANDI]';
        cb.agent(a.id, AgentStatus.completed, 0);
        _log(
          cb,
          a.name,
          'İsteğe bağlı ajan atlandı; içerik değişmeden nihai dosya motoruna aktarılacak.',
          LogType.info,
        );
        _emitOutput(
          cb,
          a,
          n,
          AgentOutputStatus.skipped,
          note: 'İsteğe bağlı ajan atlandı.',
        );
        continue;
      }
      if (i == producerIdx) {
        producerInput = prev;
        producerFrom = prevAgentName;
      }
      _warnIfReasoningModel(cb, a, models);
      cb.status(
        '$n. AI Çalışıyor... [=] butonuna tıklayarak canlı sekmeyi açabilirsin.',
      );
      cb.agent(a.id, AgentStatus.running, 0);
      _log(
        cb,
        a.name,
        'Çıkarım başlatıldı (Model: ${a.modelId}, Mod: ${a.mode.name.toUpperCase()})',
        LogType.info,
      );
      _prompts[a.id] = '';
      try {
        if (a.mode == AgentMode.debugger && i > 0) {
          prev = await _debugLoop(
            agents,
            i,
            prev,
            models,
            cb,
            ct,
            codeMode: wf.targetFormat == OutputFormat.zip,
          );
        } else {
          prev = await _runAgentStage(
            agents,
            i,
            prev,
            prevAgentName,
            models,
            cb,
            ct,
          );
        }
      } on CancelledException {
        rethrow;
      } catch (e) {
        // Sorunun hangi adımda çıktığı sonuç ekranında görünsün.
        _emitOutput(
          cb,
          a,
          n,
          AgentOutputStatus.failed,
          note: _failureNote(e),
        );
        rethrow;
      }
      _emitOutput(cb, a, n, AgentOutputStatus.ok, content: prev);
      prevAgentName = a.name;
      cb.agent(a.id, AgentStatus.completed, 0);
      if (i < agents.length - 1) {
        await _pause(_pauseStep, ct);
      }
    }
    _check(ct);
    prev = await _enforceContract(
      wf,
      agents,
      producerIdx,
      producerInput,
      producerFrom,
      prev,
      models,
      cb,
      ct,
    );
    _check(ct);
    cb.status('${agents.length}. AI ${wf.targetFormat.product} Oluşturuyor...');
    _log(
      cb,
      'Dosya Dönüştürme Motoru',
      'Yerel dönüştürücü tetiklendi (${wf.targetFormat.name.toUpperCase()}).',
      LogType.info,
    );
    final artifact = await _files.build(
      format: wf.targetFormat,
      title: wf.title,
      content: prev,
      dir: await _storage.outputsDir(),
      task: wf.task,
      base: _base,
    );
    if (ct.cancelled) {
      // Dosya, iptal basıldığı sırada tamamlandıysa sonuç sunulmaz: sil ve çık.
      try {
        await File(artifact.path).delete();
      } catch (_) {}
      throw const CancelledException();
    }
    cb.status('İşlem Tamamlandı. Dosya indirilmeye hazır.');
    _log(
      cb,
      'Sistem',
      'Nihai dosya hazırlandı: ${artifact.filename} (${artifact.sizeLabel})',
      LogType.success,
    );
    return artifact;
  }
}
