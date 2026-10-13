import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/perf_log.dart';
import 'package:kripton_ai/application/thermal_governor.dart';
import 'package:kripton_ai/application/token_budget.dart';
import 'package:kripton_ai/domain/entities.dart';

void main() {
  test('bütçe contextSize ile ölçeklenir ve %85 sınırını aşmaz', () {
    for (final ctx in [2048, 4096, 8192]) {
      final b = PromptBudget.of(ctx);
      expect(b.maxNew + b.promptTokens, lessThanOrEqualTo((ctx * 0.85).floor()));
      expect(b.maxNew, lessThanOrEqualTo(b.limit ~/ 2));
    }
    expect(PromptBudget.of(8192).maxNew, greaterThan(PromptBudget.of(2048).maxNew));
  });

  test('batch verilince promptTokens batch × %70 ile sınırlanır', () {
    final b = PromptBudget.of(8192, batch: 1024);
    expect(b.promptTokens, lessThanOrEqualTo(716));
    expect(b.promptTokens, 716);
    expect(b.batchCap, 716);
    expect(PromptBudget.of(4096, batch: 1024).promptTokens, 716);
    expect(PromptBudget.of(4096, batch: 256).promptTokens, 179);
    expect(PromptBudget.of(2048, batch: 128).promptTokens, 89);
    // batch bağlam sınırından büyükse bağlam sınırı geçerli kalır
    final big = PromptBudget.of(2048, batch: 4096);
    expect(big.promptTokens, big.limit - big.maxNew);
    // maxNew etkilenmez
    expect(b.maxNew, PromptBudget.of(8192).maxNew);
  });

  test('batch null iken eski değerler değişmez', () {
    expect(PromptBudget.of(4096).promptTokens, 1945);
    expect(PromptBudget.of(8192).promptTokens, 4915);
    expect(PromptBudget.of(4096).batchCap, isNull);
    expect(PromptBudget.of(4096, batch: null).promptTokens, PromptBudget.of(4096).promptTokens);
  });

  test('promptChars/attachChars batch ile küçülür; alt ve üst sınırlar korunur', () {
    const t = ChatTemplate.chatml;
    final free = PromptBudget.of(8192);
    final capped = PromptBudget.of(8192, batch: 1024);
    expect(capped.promptChars(t, 'abc', 80), lessThan(free.promptChars(t, 'abc', 80)));
    expect(capped.promptChars(t, 'abc', 80), (716 * charsPerToken(t, 'abc')).floor() - 80);
    expect(capped.attachChars(t, 'abc'), lessThan(free.attachChars(t, 'abc')));
    expect(free.attachChars(t, 'abc'), (4915 * charsPerToken(t, 'abc') * 0.45).floor()); // batch yok
    expect(free.attachChars(t, 'abc'), lessThanOrEqualTo(24000));
    // çok küçük batch: promptChars en az 200, attachChars en az 1500
    final tiny = PromptBudget.of(2048, batch: 16);
    expect(tiny.promptChars(t, 'abc', 500), 200);
    expect(tiny.attachChars(t, 'abc'), 1500);
  });

  test('debugger kısa yanıt, R1 ayrı think payı alır', () {
    final d = PromptBudget.of(4096, shortAnswer: true);
    expect(d.maxNew, 320);
    final r1 = PromptBudget.of(4096, deepseek: true, shortAnswer: true);
    expect(r1.thinkTokens, greaterThan(0));
    expect(r1.maxNew, greaterThan(320));
  });

  test('batchShare 0.70, batchHardShare 0.80', () {
    expect(PromptBudget.batchShare, 0.70);
    expect(PromptBudget.batchHardShare, 0.80);
    expect(PromptBudget.batchSoftCap(1024), 716);
    expect(PromptBudget.batchHardCap(1024), 819);
    expect(PromptBudget.batchHardCap(256), 204);
  });

  test('ctx 4096: üretim payı ~1024, kalan prompt\'a ayrılır; usablePrompt* dışarıya açık', () {
    final b = PromptBudget.of(4096);
    expect(b.maxNew, 1024);
    expect(b.usablePromptTokens, b.limit - 1024);
    expect(b.usablePromptTokens, b.promptTokens);
    expect(PromptBudget.of(2048).maxNew, 512);
    expect(PromptBudget.of(8192).maxNew, 2048);
    // batch ve ctx dışarıdan gelir: batch küçükse kullanılabilir prompt batch payıyla sınırlanır
    expect(PromptBudget.of(4096, batch: 512).usablePromptTokens, PromptBudget.batchSoftCap(512));
    const t = ChatTemplate.phi3;
    expect(b.usablePromptChars(t, 'abc'), (b.usablePromptTokens * charsPerToken(t, 'abc')).floor());
    expect(b.usablePromptChars(t, 'abc', overheadChars: 100), (b.usablePromptTokens * charsPerToken(t, 'abc')).floor() - 100);
    expect(b.promptChars(t, 'abc', 100), b.usablePromptChars(t, 'abc', overheadChars: 100));
  });

  test('charsPerToken: phi3/alpaca 1.6/2.0/2.8, diğerleri ~%15 düşük ve token asla az tahmin edilmez', () {
    const tr = 'Şöyle bir çalışma: öğrenci güzel bir cümle yazdı ve içeriği değiştirdi';
    const code = 'void main() { final a = (1 + 2); print(a); if (a > 2) { return; } }';
    const en = 'hello world this is a plain english sentence for testing';
    for (final t in [ChatTemplate.phi3, ChatTemplate.alpaca]) {
      expect(charsPerToken(t, tr), 1.6);
      expect(charsPerToken(t, code), 2.0);
      expect(charsPerToken(t, en), 2.8);
    }
    const old = {
      ChatTemplate.chatml: (2.3, 2.8, 3.6),
      ChatTemplate.deepseek: (2.3, 2.8, 3.6),
      ChatTemplate.llama3: (2.4, 2.8, 3.7),
      ChatTemplate.mistral: (2.0, 2.6, 3.3),
    };
    for (final e in old.entries) {
      final (otr, ocode, oen) = e.value;
      for (final (sample, o) in [(tr, otr), (code, ocode), (en, oen)]) {
        final now = charsPerToken(e.key, sample);
        expect(now, lessThan(o), reason: '${e.key}');
        expect(now / o, closeTo(0.85, 0.02), reason: '${e.key}');
      }
    }
  });

  test('nativeTokenCounter varsa tahmin yerine o kullanılır; hata verirse tahmine düşer', () {
    addTearDown(() => nativeTokenCounter = null);
    const s = 'hello world';
    final est = estimateTokens(s, ChatTemplate.chatml);
    nativeTokenCounter = (_) => 42;
    expect(estimateTokens(s, ChatTemplate.chatml), 42);
    nativeTokenCounter = (_) => throw StateError('x');
    expect(estimateTokens(s, ChatTemplate.chatml), est);
    nativeTokenCounter = null;
    expect(estimateTokens(s, ChatTemplate.chatml), est);
  });

  test('Türkçe ve kod İngilizceden daha çok token sayılır', () {
    const en = 'hello world this is a plain english sentence for testing';
    const tr = 'Şöyle bir çalışma: öğrenci güzel bir cümle yazdı ve içeriği değiştirdi';
    expect(estimateTokens(tr, ChatTemplate.chatml) / tr.length, greaterThan(estimateTokens(en, ChatTemplate.chatml) / en.length));
  });

  test('ThinkGuard bölünmüş etiketlerde de sayar ve eşiği aşınca bildirir', () {
    final g = ThinkGuard(20);
    for (final t in ['<thi', 'nk>', 'abcdefghij', 'klmnopqrst', 'uvw']) {
      g.add(t);
    }
    expect(g.exceeded, isTrue);
    final g2 = ThinkGuard(20)..add('<think>kısa</think>cevap uzun uzun uzun uzun uzun');
    expect(g2.exceeded, isFalse);
  });

  test('termal: tok/s %70 altına düşünce 8→6→4, geri yükselme yavaş', () {
    final gov = ThermalGovernor(cooldown: const Duration(seconds: 1), recoverHold: const Duration(seconds: 30));
    var t = DateTime(2026, 1, 1);
    for (var i = 0; i < 12; i++) {
      expect(gov.onSample(20, t), isNull);
      t = t.add(const Duration(seconds: 3));
    }
    expect(gov.baseline, isNotNull);
    expect(gov.onSample(10, t), 6);
    t = t.add(const Duration(seconds: 3));
    expect(gov.onSample(6, t), 4);
    t = t.add(const Duration(seconds: 3));
    expect(gov.onSample(1, t), isNull); // alt basamak yok
    // iyileşme: hemen değil, recoverHold sonrası tek basamak
    final base = gov.baseline!;
    int? r;
    for (var i = 0; i < 4 && r == null; i++) {
      t = t.add(const Duration(seconds: 10));
      r = gov.onSample(base, t);
    }
    expect(r, 6);
  });

  test('RAM: 8192 yalnızca pay yeterliyse', () {
    expect(RamPolicy.pickContext(modelMb: 4200, availMb: 9000), 8192);
    expect(RamPolicy.pickContext(modelMb: 4200, availMb: 6000), isNot(8192));
  });
}
