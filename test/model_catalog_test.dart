import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/model_fit.dart';
import 'package:kripton_ai/data/default_data.dart';
import 'package:kripton_ai/data/gguf_meta.dart';
import 'package:kripton_ai/domain/entities.dart';

GgufModel byId(String id) => modelCatalog.firstWhere((m) => m.id == id);

void main() {
  const gib = 1024 * 1024 * 1024;
  final urlPattern = RegExp(r'^https://huggingface\.co/[\w.-]+/[\w.-]+/resolve/main/[\w.-]+\.gguf$');

  group('katalog biçimi', () {
    test('her URL Hugging Face resolve/main/*.gguf biçiminde', () {
      for (final m in modelCatalog) {
        expect(urlPattern.hasMatch(m.url), isTrue, reason: '${m.id}: ${m.url}');
        expect(m.fileName.endsWith('.gguf'), isTrue, reason: m.id);
      }
    });

    test('id ve fileName benzersiz; mevcut modeller korunmuş; ilk girdi değişmemiş', () {
      expect({for (final m in modelCatalog) m.id}.length, modelCatalog.length);
      expect({for (final m in modelCatalog) m.fileName}.length, modelCatalog.length);
      expect(modelCatalog.first.id, 'qwen-2.5-coder-7b-q4km'); // test yardımcıları buna dayanır
      for (final id in const [
        'qwen-2.5-coder-7b-q4km',
        'deepseek-r1-distill-7b-q4km',
        'mistral-7b-instruct-v03-q5km',
        'llama-3.2-3b-q4km',
        'qwen-2.5-coder-7b-q5km',
        'phi-3.5-mini-3.8b-q4km',
      ]) {
        expect(modelCatalog.any((m) => m.id == id), isTrue, reason: id);
      }
    });

    test('yeni hafif modeller: Hugging Face\'te doğrulanan depo/dosya adları ve chatml şablonu', () {
      const expected = {
        'qwen-2.5-coder-3b-q4km': 'bartowski/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf',
        'qwen-2.5-coder-1.5b-q4km': 'bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf',
        'qwen-2.5-coder-7b-iq4xs': 'bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-IQ4_XS.gguf',
      };
      expected.forEach((id, path) {
        final m = byId(id);
        expect(m.url, 'https://huggingface.co/$path');
        expect(m.fileName, path.split('/').last);
        expect(m.template, ChatTemplate.chatml);
      });
    });

    test('7B IQ4_XS açıklaması RAM kazancının küçük olduğunu söyler', () {
      expect(byId('qwen-2.5-coder-7b-iq4xs').quality, contains('küçüktür'));
    });
  });

  group('ramGb türetimi (GGUF metadata hesabı)', () {
    // Bağımsız hesap: dosya + 2*katman*(embd*kvHead/head)*2 bayt/token * 4096 + 0.5 GB.
    double expected(int bytes, int layers, int embd, int heads, int kvHeads) =>
        (bytes + 2 * layers * ((embd * kvHeads) ~/ heads) * 2 * 4096 + 500000000) / 1e9;

    test('3B / 1.5B / 7B IQ4_XS değerleri formülden gelir', () {
      expect(byId('qwen-2.5-coder-3b-q4km').ramGb, closeTo(expected(1930000000, 36, 2048, 16, 2), 1e-9));
      expect(byId('qwen-2.5-coder-1.5b-q4km').ramGb, closeTo(expected(986000000, 28, 1536, 12, 2), 1e-9));
      expect(byId('qwen-2.5-coder-7b-iq4xs').ramGb, closeTo(expected(4220000000, 28, 3584, 28, 4), 1e-9));
      expect(byId('qwen-2.5-coder-3b-q4km').ramGb, closeTo(2.581, 0.001));
      expect(byId('qwen-2.5-coder-1.5b-q4km').ramGb, closeTo(1.603, 0.001));
      expect(byId('qwen-2.5-coder-7b-iq4xs').ramGb, closeTo(4.955, 0.001));
    });

    test('sizeGb de catalogBytes\'tan türetilir; withCache bunu korur', () {
      final m = byId('qwen-2.5-coder-3b-q4km');
      expect(m.sizeGb, closeTo(1.93, 1e-9));
      final cached = m.withCache('/tmp/x.gguf', 'h', sizeBytes: 1931234567);
      expect(cached.ramGb, m.ramGb);
      expect(cached.sizeGb, m.sizeGb);
      expect(cached.arch, same(m.arch));
      expect(cached.isCached, isTrue);
    });

    test('GgufArch.kvBytesPerToken, GgufMeta ile aynı formülü kullanır', () {
      for (final id in const ['qwen-2.5-coder-3b-q4km', 'qwen-2.5-coder-1.5b-q4km', 'qwen-2.5-coder-7b-iq4xs']) {
        final a = byId(id).arch!;
        final meta = GgufMeta(
          architecture: 'qwen2',
          blockCount: a.blockCount,
          embeddingLength: a.embeddingLength,
          attentionHeadCount: a.attentionHeadCount,
          attentionHeadCountKv: a.attentionHeadCountKv,
          contextLength: 32768,
          feedForwardLength: a.feedForwardLength,
        );
        expect(a.kvBytesPerToken, meta.kvBytesPerToken, reason: id);
      }
    });

    test('estimateRamGb: dosya + KV(ctx) + 0.5 GB', () {
      expect(estimateRamGb(fileBytes: 1000000000, kvBytesPerToken: 1000, ctx: 1000), closeTo(1.501, 1e-9));
    });

    test('eski girdiler elle yazılan ramGb\'yi korur', () {
      expect(modelCatalog.first.ramGb, 4.8);
      expect(modelCatalog.first.sizeGb, 4.1);
    });
  });

  group('rozet mantığı (memoryPlan)', () {
    ModelFit fit(String id, int total) => modelFit(byId(id), totalBytes: total);

    test('3 GB cihaz: yalnız 1.5B sınırda, diğerleri sığmaz', () {
      expect(fit('qwen-2.5-coder-1.5b-q4km', 3000000000), ModelFit.borderline);
      expect(fit('qwen-2.5-coder-3b-q4km', 3000000000), ModelFit.tooBig);
      expect(fit('qwen-2.5-coder-7b-iq4xs', 3000000000), ModelFit.tooBig);
      expect(fit('qwen-2.5-coder-7b-q4km', 3000000000), ModelFit.tooBig);
    });

    test('7 GB cihaz: 1.5B ve 3B uygun, 7B sığmaz', () {
      expect(fit('qwen-2.5-coder-1.5b-q4km', 7000000000), ModelFit.fits);
      expect(fit('qwen-2.5-coder-3b-q4km', 7000000000), ModelFit.fits);
      expect(fit('qwen-2.5-coder-7b-iq4xs', 7000000000), ModelFit.tooBig);
      expect(fit('qwen-2.5-coder-7b-q4km', 7000000000), ModelFit.tooBig);
    });

    test('12 GB cihaz: 7B Q4_K_M ve IQ4_XS uygun', () {
      expect(fit('qwen-2.5-coder-7b-q4km', 12000000000), ModelFit.fits);
      expect(fit('qwen-2.5-coder-7b-iq4xs', 12000000000), ModelFit.fits);
    });

    test('16 GiB cihaz: katalogdaki her model uygun', () {
      for (final m in modelCatalog) {
        expect(modelFit(m, totalBytes: 16 * gib), ModelFit.fits, reason: m.id);
      }
    });

    test('küçük ctx\'e düşmek gerekiyorsa "uygun" değil "sınırda"', () {
      // 4 GB cihazda 3B ancak ctx 3072 ile yeşil olur.
      expect(fit('qwen-2.5-coder-3b-q4km', 4000000000), ModelFit.borderline);
    });

    test('uygunluk RAM arttıkça asla kötüleşmez', () {
      for (final m in modelCatalog) {
        var prev = ModelFit.tooBig.index;
        for (final total in [2, 3, 4, 6, 8, 12, 16].map((g) => g * 1000000000)) {
          final cur = modelFit(m, totalBytes: total).index;
          // enum sırası: fits(0) < borderline(1) < tooBig(2); düşük indeks = daha iyi
          expect(cur <= prev, isTrue, reason: '${m.id} @ $total');
          prev = cur;
        }
      }
    });

    test('etiketler', () {
      expect(modelFitLabel(ModelFit.fits), 'Bu cihaza uygun');
      expect(modelFitLabel(ModelFit.borderline), 'Sınırda');
      expect(modelFitLabel(ModelFit.tooBig), 'Sığmaz');
    });
  });

  group('cihaza göre varsayılan akış modeli', () {
    test('RAM bilinmiyorsa eski varsayılanlar', () {
      final p = pickDefaultModels(modelCatalog, null);
      expect(p.primaryId, 'qwen-2.5-coder-7b-q4km');
      expect(p.reviewerId, 'deepseek-r1-distill-7b-q4km');
    });

    test('16 GiB: Qwen 7B + DeepSeek', () {
      final p = pickDefaultModels(modelCatalog, 16 * gib);
      expect(p.primaryId, 'qwen-2.5-coder-7b-q4km');
      expect(p.reviewerId, 'deepseek-r1-distill-7b-q4km');
    });

    test('12 GB: Qwen 7B; DeepSeek uygun olmadığından gözden geçirici de Qwen', () {
      final p = pickDefaultModels(modelCatalog, 12000000000);
      expect(p.primaryId, 'qwen-2.5-coder-7b-q4km');
      expect(p.reviewerId, p.primaryId);
    });

    test('7 GB: 3B', () {
      final p = pickDefaultModels(modelCatalog, 7000000000);
      expect(p.primaryId, 'qwen-2.5-coder-3b-q4km');
      expect(p.reviewerId, p.primaryId);
    });

    test('3 GB: hiçbiri uygun değil -> en küçük (1.5B)', () {
      final p = pickDefaultModels(modelCatalog, 3000000000);
      expect(p.primaryId, 'qwen-2.5-coder-1.5b-q4km');
      expect(p.reviewerId, p.primaryId);
    });

    test('seçilen kimlikler katalogda var; defaultWorkflows/starterAgents bunları kullanır', () {
      final p = pickDefaultModels(modelCatalog, 7000000000);
      final ids = {for (final m in modelCatalog) m.id};
      expect(ids.contains(p.primaryId) && ids.contains(p.reviewerId), isTrue);
      final wfs = defaultWorkflows(primaryId: p.primaryId, reviewerId: p.reviewerId);
      expect({for (final w in wfs) for (final a in w.agents) a.modelId}, {p.primaryId});
      final agents = starterAgents('x', OutputFormat.pdf, primaryId: p.primaryId, reviewerId: p.reviewerId);
      expect({for (final a in agents) a.modelId}, {p.primaryId});
      // parametresiz çağrı eski davranış
      expect(
        {for (final w in defaultWorkflows()) for (final a in w.agents) a.modelId},
        {'qwen-2.5-coder-7b-q4km', 'deepseek-r1-distill-7b-q4km'},
      );
    });
  });
}
