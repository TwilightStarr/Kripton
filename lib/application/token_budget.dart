import 'dart:math' as math;

import '../domain/entities.dart';

/// Karakter/token oranı (token başına karakter). Türkçe ve kod, İngilizceden daha çok token üretir.
/// Değerler bilerek düşük (muhafazakâr) seçildi: token sayısı asla az tahmin edilmemeli; yanlışlıkla
/// bağlamı/batch'i aşmaktansa fazla kırpmak güvenlidir.
double charsPerToken(ChatTemplate t, String sample) {
  final (tr, code) = _kind(sample);
  final base = switch (t) {
    ChatTemplate.chatml || ChatTemplate.deepseek => (tr: 1.95, code: 2.4, en: 3.05), // Qwen ~152k sözlük (eski değerlerin ~%85'i)
    ChatTemplate.llama3 => (tr: 2.05, code: 2.4, en: 3.15), // 128k sözlük (~%85)
    ChatTemplate.mistral => (tr: 1.7, code: 2.2, en: 2.8), // 32k sözlük (~%85)
    ChatTemplate.phi3 || ChatTemplate.alpaca => (tr: 1.6, code: 2.0, en: 2.8), // 32k SP sözlük
  };
  if (code) return base.code;
  return tr ? base.tr : base.en;
}

(bool tr, bool code) _kind(String s) {
  if (s.isEmpty) return (false, false);
  final n = math.min(s.length, 4000);
  var nonAscii = 0, sym = 0;
  for (var i = 0; i < n; i++) {
    final c = s.codeUnitAt(i);
    if (c > 127) {
      nonAscii++;
    } else if (c == 0x7B || c == 0x7D || c == 0x3B || c == 0x28 || c == 0x29 || c == 0x3D || c == 0x3C || c == 0x3E) {
      sym++;
    }
  }
  return (nonAscii / n > 0.015, sym / n > 0.04);
}

/// Eklenti gerçek (senkron) tokenize sunarsa buraya bağlanır; bağlıysa tahmin yerine o kullanılır.
/// flutter_llama 1.1.2 tokenize açığa çıkarmıyor (çevrimdışı doğrulanamadı) => varsayılan null => tahmin.
int Function(String text)? nativeTokenCounter;

int estimateTokens(String s, ChatTemplate t) {
  if (s.isEmpty) return 0;
  final native = nativeTokenCounter;
  if (native != null) {
    try {
      return native(s);
    } catch (_) {
      // gerçek sayım başarısız: tahmine düş
    }
  }
  return (s.length / charsPerToken(t, s)).ceil();
}

class PromptBudget {
  PromptBudget._(this.ctx, this.limit, this.maxNew, this.thinkTokens, this.promptTokens, this.batchCap);

  /// Prompt token tahmini n_batch'in en çok bu oranı kadar olabilir (karakter/oran tahmini
  /// yaklaşık olduğundan ~%30 güvenlik payı).
  static const double batchShare = 0.70;

  /// Şablon uygulanmış son prompt için sert üst sınır oranı (son savunma; bkz. WorkflowRunner).
  static const double batchHardShare = 0.80;

  static int batchSoftCap(int batch) => (batch * batchShare).floor();

  static int batchHardCap(int batch) => (batch * batchHardShare).floor();

  final int ctx;
  final int limit; // ctx * %85
  final int maxNew; // cevap + (varsa) think bütçesi
  final int thinkTokens; // DeepSeek R1 <think> için ayrı pay (maxNew içinde)
  final int promptTokens; // prompt'a kalan (batch verildiyse en çok batch × batchShare)
  final int? batchCap; // batch × batchShare (batch verilmediyse null)

  /// Prompt'a ayrılabilir token (üretim payı ve batch sınırı düşülmüş). Üst katmanlar bunu kullanır.
  int get usablePromptTokens => promptTokens;

  /// Üretim payının <think> hariç, yalnızca kullanıcıya görünen cevap kısmı (token).
  int get answerTokens => maxNew - thinkTokens;

  /// Cevap payı bu değerin altındaysa kullanıcı uyarılır (ctx 2048 -> 512, 4096 -> 1024 uyarır; 8192 -> 2048 uyarmaz).
  static const int lowAnswerTokens = 1536;

  /// Prompt alanı bu değerin altındaysa kullanıcı uyarılır (WorkflowRunner'daki günlük uyarısıyla aynı eşik).
  static const int lowPromptTokens = 1000;

  /// Küçük bağlam uyarı metni; bütçe yeterliyse null. Akış başlamadan (ilk üretimden önce) gösterilir.
  String? get lowContextWarning {
    final lowAnswer = answerTokens < lowAnswerTokens;
    final lowPrompt = usablePromptTokens < lowPromptTokens;
    if (!lowAnswer && !lowPrompt) return null;
    final b = StringBuffer();
    if (lowAnswer) {
      b.write('Bu cihazda çıktı en fazla ~$answerTokens token (bağlam $ctx), uzun görevleri parçala.');
    }
    if (lowPrompt) {
      if (b.isNotEmpty) b.write(' ');
      b.write(
        'Ajanlara aktarılabilen girdi de ~$usablePromptTokens token ile sınırlı; '
        'uzun metinler parçalanır veya kısaltılır.',
      );
    }
    return b.toString();
  }

  /// Bağlam boyutuna göre dinamik bütçe (sabit 9000/5000/1536 yerine).
  /// Üretim payı ctx × %25, 512..2048: ctx 2048 → 512, 4096 → 1024 (kod parça parça üretilir), 8192 → 2048.
  /// [ctx] ve [batch] dışarıdan verilir (bellek planı belirler); bütçe kendisi seçim yapmaz.
  /// [shortAnswer]: debugger (STATUS satırı + kısa rapor) → 320 token.
  /// [batch]: modelin n_batch değeri. Eklenti prompt'u tek llama_decode ile işler; batch'i aşan
  /// prompt native abort üretir. Verilirse promptTokens = min(limit - maxNew, batch × batchShare); null ise
  /// yalnızca bağlam sınırı geçerlidir (eski davranış).
  factory PromptBudget.of(
    int ctx, {
    bool deepseek = false,
    bool shortAnswer = false,
    double share = 0.85,
    int? batch,
  }) {
    final limit = (ctx * share).floor();
    final int answer = shortAnswer ? 320 : (ctx * 0.25).round().clamp(512, 2048).toInt();
    // R1 önce düşünür: STATUS/cevap düşünce bitmeden gelmez, bu yüzden ayrı pay.
    final think = deepseek ? (shortAnswer ? 512 : math.min(1024, (ctx * 0.125).round())) : 0;
    final maxNew = math.min(answer + think, limit ~/ 2); // prompt'a en az yarı bütçe kalsın
    final byCtx = limit - maxNew;
    final cap = batch == null ? null : batchSoftCap(batch);
    final promptTokens = cap == null ? byCtx : math.min(byCtx, cap);
    return PromptBudget._(ctx, limit, maxNew, math.min(think, maxNew ~/ 2), promptTokens, cap);
  }

  /// Prompt için kullanılabilir karakter alanı ([usablePromptTokens] × karakter/token oranı,
  /// şablon ek yükü [overheadChars] düşülmüş; en az 200).
  int usablePromptChars(ChatTemplate template, String sample, {int overheadChars = 0}) =>
      math.max(200, (usablePromptTokens * charsPerToken(template, sample)).floor() - overheadChars);

  /// Eski ad; [usablePromptChars]'a yönlendirir.
  int promptChars(ChatTemplate t, String sample, int overheadChars) =>
      usablePromptChars(t, sample, overheadChars: overheadChars);

  /// Ek dosyalar için üst sınır: prompt alanının ~%45'i, 1500..24000 karakter.
  int attachChars(ChatTemplate t, String sample) =>
      (promptTokens * charsPerToken(t, sample) * 0.45).floor().clamp(1500, 24000).toInt();

  /// <think> bloğu için karakter üst sınırı.
  int thinkChars(ChatTemplate t) => (thinkTokens * charsPerToken(t, 'ç')).floor();
}

/// Bağlam [ctx] (ve varsa [batch]) için küçük bağlam uyarısı; sorun yoksa null.
/// [template] DeepSeek ise <think> payı cevap payından ayrı sayılır.
String? lowContextWarning(int ctx, {int? batch, ChatTemplate template = ChatTemplate.chatml}) =>
    PromptBudget.of(ctx, deepseek: template == ChatTemplate.deepseek, batch: batch).lowContextWarning;

/// Akış sırasında <think> ... </think> uzunluğunu izler (etiketler token sınırına bölünse bile).
class ThinkGuard {
  ThinkGuard(this.maxChars);

  final int maxChars;
  bool _inThink = false;
  int _thinkLen = 0;
  String _tail = ''; // yalnızca bölünmüş etiket tespiti için son 7 karakter

  bool get exceeded => maxChars > 0 && _thinkLen > maxChars;

  void add(String tok) {
    if (maxChars <= 0) return;
    final w = _tail + tok;
    final base = _tail.length; // w içinde yeni karakterler base'den başlar
    var i = 0;
    while (i < w.length) {
      if (!_inThink) {
        final o = w.indexOf('<think>', i);
        if (o < 0 || o + 7 <= base) break;
        _inThink = true;
        i = o + 7;
      } else {
        final c = w.indexOf('</think>', i);
        final end = c < 0 ? w.length : c;
        _thinkLen += math.max(0, end - math.max(i, base));
        if (c < 0) break;
        _inThink = false;
        i = c + 8;
      }
    }
    _tail = w.length > 7 ? w.substring(w.length - 7) : w;
  }
}
