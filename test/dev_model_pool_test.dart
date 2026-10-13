// Görev 5/19: DevModelPool testleri — keşif + sıralama (sahte servis), rol çakışmaması, cooldown / günlük kota /
// devre kesici, hepsi parktayken bekleme süresi, önbellek, güven puanı, sır maskeleme.
// Gerçek ağ yok; gerçek sır yok (sahte anahtarlar çalışma zamanında birleştirilir). Model adları SAHTEDİR.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/dev_ledger.dart';
import 'package:kripton_ai/application/dev_model_pool.dart';
import 'package:kripton_ai/data/cloud_engine.dart';
import 'package:kripton_ai/data/cloud_models.dart';
import 'package:kripton_ai/data/secret_mask.dart';

// ------------------------------------------------------------------ sahte servis

class _FakeService extends CloudModelService {
  _FakeService(this.catalog) : super();

  final Map<CloudProvider, List<CloudModelInfo>> catalog;

  /// `sağlayıcı:model` -> test sonucu (yoksa başarılı).
  final Map<String, CloudModelTestResult> tests = {};
  final Map<CloudProvider, CloudModelsResult> listFailures = {};
  final List<String> testCalls = [];
  final List<CloudProvider> listCalls = [];

  @override
  Future<CloudModelsResult> fetchModels(CloudProvider p, String apiKey) async {
    listCalls.add(p);
    final f = listFailures[p];
    if (f != null) return f;
    return CloudModelsResult(
      kind: CloudCheckKind.ok,
      message: 'tamam',
      models: catalog[p] ?? const [],
    );
  }

  @override
  Future<CloudModelTestResult> testModel(CloudProvider p, String apiKey, String model) async {
    final id = '${p.name}:$model';
    testCalls.add(id);
    return tests[id] ?? const CloudModelTestResult(kind: CloudCheckKind.ok, message: 'tamam', latencyMs: 120);
  }
}

Map<CloudProvider, List<CloudModelInfo>> _catalog() => {
      CloudProvider.gemini: const [
        CloudModelInfo('gemini-x-pro', contextTokens: 1048576),
        CloudModelInfo('gemini-x-flash', contextTokens: 1048576),
        CloudModelInfo('gemini-x-flash-lite', contextTokens: 1048576),
      ],
      CloudProvider.groq: const [
        CloudModelInfo('llama-x-70b-versatile', contextTokens: 131072),
        CloudModelInfo('qwen-x-coder-32b', contextTokens: 32768),
        CloudModelInfo('tiny-8b-instant', contextTokens: 8192),
      ],
      CloudProvider.openrouter: const [
        CloudModelInfo('meta/foo-70b:free', contextTokens: 131072),
        CloudModelInfo('vendor/bar-coder:free', contextTokens: 65536),
        CloudModelInfo('vendor/paid-model', contextTokens: 200000), // ücretli: elenmeli
        CloudModelInfo('google/baz-1b:free', contextTokens: 32768),
      ],
    };

String _fakeKey(CloudProvider p) => 'test-key-${p.name}-${'z' * 24}';

class _Rig {
  _Rig({
    Set<CloudProvider> keys = const {CloudProvider.gemini, CloudProvider.groq, CloudProvider.openrouter},
    Map<CloudProvider, List<CloudModelInfo>>? catalog,
    ModelTrust? trust,
    File? cache,
    DevPoolPolicy policy = const DevPoolPolicy(),
  }) {
    cfg = CloudConfig.isolated();
    for (final p in keys) {
      cfg.providers[p]!.apiKey = _fakeKey(p);
    }
    svc = _FakeService(catalog ?? _catalog());
    pool = DevModelPool(
      service: svc,
      config: cfg,
      policy: policy,
      trust: trust,
      cacheFile: cache,
      log: (String m, {String? modelId, bool warning = false}) => logs.add(m),
      now: () => now,
      sleep: (_) async {},
    );
  }

  late final CloudConfig cfg;
  late final _FakeService svc;
  late final DevModelPool pool;
  final List<String> logs = [];
  DateTime now = DateTime.utc(2026, 10, 11, 10);

  void advance(Duration d) => now = now.add(d);
}

PoolReport _limit(String id, Duration d) => PoolReport(modelId: id, kind: PoolOutcomeKind.rateLimit, retryAfter: d);

void main() {
  late Directory tmp;

  setUp(() {
    SecretMask.clear();
    tmp = Directory.systemTemp.createTempSync('devpool_test_');
  });

  tearDown(() {
    SecretMask.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('sezgiler', () {
    test('güç: gemini adındaki "mini" küçük sayılmaz; lite küçültür; parametre sayısı büyütür', () {
      final pro = ModelHeuristics.strength('gemini-x-pro');
      final flash = ModelHeuristics.strength('gemini-x-flash');
      final lite = ModelHeuristics.strength('gemini-x-flash-lite');
      expect(pro, greaterThan(flash));
      expect(flash, greaterThan(lite));
      expect(flash, greaterThan(2.9), reason: '"gemini" içindeki "mini" yanlış eşleşmemeli');
      expect(ModelHeuristics.strength('foo-70b'), greaterThan(ModelHeuristics.strength('foo-8b')));
      expect(ModelHeuristics.strength('foo-8b-instant'), lessThan(ModelHeuristics.strength('foo-8b')));
    });

    test('parametre sayısı: etkin-parametre eki (a22b) yok sayılır', () {
      expect(ModelHeuristics.paramsBillions('qwen-x-235b-a22b'), 235);
      expect(ModelHeuristics.paramsBillions('llama-x-70b-versatile'), 70);
      expect(ModelHeuristics.paramsBillions('gemini-x-flash'), isNull);
    });

    test('kod odaklılık: coder/code/flash artı verir', () {
      expect(ModelHeuristics.codeAffinity('qwen-x-coder-32b'), greaterThan(ModelHeuristics.codeAffinity('qwen-x-chat-32b')));
      expect(ModelHeuristics.codeAffinity('gemini-x-flash'), greaterThan(0));
      expect(ModelHeuristics.codeAffinity('gemini-x-flash-lite'), lessThan(ModelHeuristics.codeAffinity('gemini-x-flash')));
    });

    test('bağlam puanı artar ve sınırlıdır', () {
      expect(ModelHeuristics.contextScore(1048576), greaterThan(ModelHeuristics.contextScore(131072)));
      expect(ModelHeuristics.contextScore(null), 0);
      expect(ModelHeuristics.contextScore(1 << 40), lessThanOrEqualTo(7));
    });

    test('ücretsiz aday: OpenRouter yalnızca :free', () {
      expect(isFreeCandidate(CloudProvider.openrouter, 'a/b:free'), isTrue);
      expect(isFreeCandidate(CloudProvider.openrouter, 'a/b'), isFalse);
      expect(isFreeCandidate(CloudProvider.groq, 'x'), isTrue);
      expect(isFreeCandidate(CloudProvider.gemini, 'x'), isTrue);
    });

    test('havuz kimliği: sağlayıcı/model ayrıştırma; VerifierPolicy ile uyumlu biçim', () {
      final id = poolModelId(CloudProvider.openrouter, 'meta/foo-70b:free');
      expect(id, 'openrouter:meta/foo-70b:free');
      expect(poolProviderOf(id), CloudProvider.openrouter);
      expect(poolModelNameOf(id), 'meta/foo-70b:free');
      expect(poolProviderOf('yok:x'), isNull);
    });

    test('Retry-After ve günlük kota ayrıştırma', () {
      expect(parseCloudRetryAfter('', header: '12'), const Duration(seconds: 12));
      expect(parseCloudRetryAfter('{"retryDelay": "34s"}'), const Duration(seconds: 34));
      expect(parseCloudRetryAfter('Please try again in 1m3.2s.')!.inMilliseconds, inInclusiveRange(63200, 63201));
      expect(parseCloudRetryAfter('hiçbir şey'), isNull);
      expect(isDailyQuotaBody('Quota exceeded: GenerateRequestsPerDayPerProjectPerModel'), isTrue);
      expect(isDailyQuotaBody('Rate limit exceeded: free-models-per-day'), isTrue);
      expect(isDailyQuotaBody('limit: 0, model: x'), isTrue);
      expect(isDailyQuotaBody('too many requests per minute'), isFalse);
    });
  });

  group('keşif', () {
    test('yalnızca ücretsiz adaylar havuza girer; ücretli OpenRouter modeli elenir', () async {
      final r = _Rig();
      final d = await r.pool.discover();
      expect(d.providers, hasLength(3));
      expect(r.pool.modelById('openrouter:vendor/paid-model'), isNull);
      expect(r.pool.modelById('openrouter:meta/foo-70b:free'), isNotNull);
      expect(r.pool.modelById('gemini:gemini-x-pro'), isNotNull);
      expect(r.pool.size, 3 + 3 + 3);
      expect(r.svc.testCalls.any((c) => c.contains('paid-model')), isFalse);
    });

    test('anahtarı olmayan sağlayıcı listelenmez', () async {
      final r = _Rig(keys: {CloudProvider.groq});
      await r.pool.discover();
      expect(r.svc.listCalls, [CloudProvider.groq]);
      expect(r.pool.snapshot().every((s) => s.model.provider == CloudProvider.groq), isTrue);
    });

    test('devre dışı bırakılmış sağlayıcı (enabled=false) yok sayılır', () async {
      final r = _Rig();
      r.cfg.providers[CloudProvider.gemini]!.enabled = false;
      await r.pool.discover();
      expect(r.svc.listCalls, isNot(contains(CloudProvider.gemini)));
    });

    test('sağlık testi sınırları: sağlayıcı başına testsPerProvider / healthyTarget', () async {
      final r = _Rig(policy: const DevPoolPolicy(testsPerProvider: 2, healthyTarget: 5));
      await r.pool.discover();
      for (final p in CloudProvider.values) {
        expect(r.svc.testCalls.where((c) => c.startsWith('${p.name}:')).length, lessThanOrEqualTo(2));
      }
      final r2 = _Rig(policy: const DevPoolPolicy(testsPerProvider: 6, healthyTarget: 1));
      await r2.pool.discover();
      for (final p in CloudProvider.values) {
        expect(r2.svc.testCalls.where((c) => c.startsWith('${p.name}:')).length, 1);
      }
    });

    test('test sırası sezgiseldir: en güçlü aday önce test edilir', () async {
      final r = _Rig(policy: const DevPoolPolicy(testsPerProvider: 1, healthyTarget: 5));
      await r.pool.discover();
      expect(r.svc.testCalls.where((c) => c.startsWith('gemini:')).single, 'gemini:gemini-x-pro');
    });

    test('sağlıksız model sıralamada geri düşer, sağlıklı olan seçilir', () async {
      final r = _Rig(keys: {CloudProvider.gemini});
      r.svc.tests['gemini:gemini-x-pro'] = const CloudModelTestResult(kind: CloudCheckKind.other, message: 'bozuk');
      await r.pool.discover();
      final pick = r.pool.pick(DevRole.analyst);
      expect(pick.ok, isTrue);
      expect(pick.model!.model, isNot('gemini-x-pro'), reason: 'testten geçemeyen model dinlendirilir');
      final st = r.pool.snapshot().firstWhere((s) => s.model.model == 'gemini-x-pro');
      expect(st.health, PoolHealth.failed);
      expect(st.availability, PoolAvailability.cooldown);
    });

    test('test 429 (günlük, limit 0): aday kalır ama parkta; sağlıklı sayılmaz', () async {
      final r = _Rig(keys: {CloudProvider.gemini});
      r.svc.tests['gemini:gemini-x-pro'] = const CloudModelTestResult(
        kind: CloudCheckKind.quota,
        message: 'kota',
        statusCode: 429,
        dailyQuota: true,
      );
      await r.pool.discover();
      final st = r.pool.snapshot().firstWhere((s) => s.model.model == 'gemini-x-pro');
      expect(st.availability, PoolAvailability.parked);
      expect(st.until, DevModelPool.quotaResetAt(CloudProvider.gemini, r.now));
      expect(r.pool.pick(DevRole.analyst).model!.model, isNot('gemini-x-pro'));
    });

    test('test 404: model ölü işaretlenir, seçilmez', () async {
      final r = _Rig(keys: {CloudProvider.groq});
      r.svc.tests['groq:llama-x-70b-versatile'] = const CloudModelTestResult(kind: CloudCheckKind.notFound, message: '404');
      await r.pool.discover();
      final st = r.pool.snapshot().firstWhere((s) => s.model.model == 'llama-x-70b-versatile');
      expect(st.availability, PoolAvailability.dead);
      expect(r.pool.pick(DevRole.analyst).model!.model, isNot('llama-x-70b-versatile'));
    });

    test('geçersiz anahtar: sağlayıcı havuzdan çıkar ve engellenir; diğerleri sürer', () async {
      final r = _Rig();
      r.svc.listFailures[CloudProvider.groq] = const CloudModelsResult(kind: CloudCheckKind.invalidKey, message: 'geçersiz');
      final d = await r.pool.discover();
      expect(d.providers.firstWhere((x) => x.provider == CloudProvider.groq).kind, CloudCheckKind.invalidKey);
      expect(r.pool.snapshot().any((s) => s.model.provider == CloudProvider.groq), isFalse);
      expect(r.pool.assign().complete, isTrue);
    });

    test('anahtar test sırasında reddedilirse sağlayıcı düşer', () async {
      final r = _Rig(keys: {CloudProvider.groq, CloudProvider.gemini});
      r.svc.tests['groq:llama-x-70b-versatile'] = const CloudModelTestResult(kind: CloudCheckKind.invalidKey, message: '401');
      await r.pool.discover();
      expect(r.pool.snapshot().any((s) => s.model.provider == CloudProvider.groq), isFalse);
      expect(r.pool.pick(DevRole.fixer).model!.provider, CloudProvider.gemini);
    });

    test('liste alınamazsa (ağ) son-bilinen-iyi adaylar korunur', () async {
      final r = _Rig(keys: {CloudProvider.gemini});
      await r.pool.discover();
      final before = r.pool.size;
      r.svc.listFailures[CloudProvider.gemini] = const CloudModelsResult(kind: CloudCheckKind.network, message: 'ağ yok');
      final d = await r.pool.discover();
      expect(r.pool.size, before);
      expect(d.providers.single.fromCache, isTrue);
      expect(r.pool.pick(DevRole.analyst).ok, isTrue);
    });

    test('listeden kalkan (emekli) model havuzdan çıkar', () async {
      final r = _Rig(keys: {CloudProvider.gemini});
      await r.pool.discover();
      expect(r.pool.modelById('gemini:gemini-x-flash'), isNotNull);
      r.svc.catalog[CloudProvider.gemini] = const [CloudModelInfo('gemini-x-pro', contextTokens: 1048576)];
      await r.pool.discover();
      expect(r.pool.modelById('gemini:gemini-x-flash'), isNull);
      expect(r.pool.size, 1);
    });

    test('önbellek: aynı süreçte yeniden test yapılmaz, force ile yapılır, TTL sonrası yapılır', () async {
      final r = _Rig();
      await r.pool.discover();
      final first = r.svc.testCalls.length;
      expect(first, greaterThan(0));
      await r.pool.discover();
      expect(r.svc.testCalls.length, first, reason: 'taze son-bilinen-iyi sonuç yeniden test edilmez');
      await r.pool.discover(force: true);
      expect(r.svc.testCalls.length, greaterThan(first));
      final second = r.svc.testCalls.length;
      r.advance(const Duration(hours: 7));
      await r.pool.discover();
      expect(r.svc.testCalls.length, greaterThan(second));
    });

    test('önbellek dosyası: yeni örnek yükler, test etmez; dosyada sır yok', () async {
      final f = File('${tmp.path}/pool_cache.json');
      final r1 = _Rig(cache: f);
      await r1.pool.discover();
      expect(f.existsSync(), isTrue);
      final text = f.readAsStringSync();
      for (final p in CloudProvider.values) {
        expect(text.contains(_fakeKey(p)), isFalse);
      }
      final r2 = _Rig(cache: f);
      await r2.pool.load();
      expect(r2.pool.size, r1.pool.size);
      await r2.pool.discover();
      expect(r2.svc.testCalls, isEmpty, reason: 'son-bilinen-iyi önbellekten gelir');
      expect(r2.pool.assign().complete, isTrue);
    });

    test('bozuk önbellek dosyası çökme yaratmaz', () async {
      final f = File('${tmp.path}/pool_cache.json')..writeAsStringSync('{{{ bozuk');
      final r = _Rig(cache: f);
      await r.pool.load();
      expect(r.pool.size, 0);
      await r.pool.discover();
      expect(r.pool.size, greaterThan(0));
    });

    test('günlük kota parkı yeniden başlatmada korunur', () async {
      final f = File('${tmp.path}/pool_cache.json');
      final r1 = _Rig(cache: f, keys: {CloudProvider.groq}, catalog: {
        CloudProvider.groq: const [CloudModelInfo('only-x-70b', contextTokens: 131072)],
      });
      await r1.pool.discover();
      r1.pool.report(PoolReport(modelId: 'groq:only-x-70b', kind: PoolOutcomeKind.dailyQuota));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final r2 = _Rig(cache: f, keys: {CloudProvider.groq}, catalog: {
        CloudProvider.groq: const [CloudModelInfo('only-x-70b', contextTokens: 131072)],
      });
      await r2.pool.load();
      final pick = r2.pool.pick(DevRole.fixer);
      expect(pick.status, PoolPickStatus.wait);
      expect(pick.waitFor, greaterThan(const Duration(hours: 10)));
    });
  });

  group('rol ataması', () {
    test('KABUL: model seçmeden üç rol atanır; roller farklı modeller; doğrulayıcı farklı sağlayıcıdan', () async {
      final r = _Rig();
      await r.pool.discover();
      final a = r.pool.assign();
      expect(a.complete, isTrue);
      final ids = {a.analyst.model!.id, a.fixer.model!.id, a.verifier.model!.id};
      expect(ids, hasLength(3), reason: 'rol çakışması olmamalı');
      expect(a.verifier.model!.provider, isNot(a.fixer.model!.provider));
      // analist: bağlamı en büyük güçlü model
      expect(a.analyst.model!.contextTokens, 1048576);
      expect(a.analyst.model!.provider, CloudProvider.gemini);
      // düzeltici: kod odaklı
      expect(a.fixer.model!.model, contains('coder'));
      expect(a.singleModel, isFalse);
    });

    test('tek sağlayıcı: farklı modeller atanır ve uyarı üretilir', () async {
      final r = _Rig(keys: {CloudProvider.groq});
      await r.pool.discover();
      final a = r.pool.assign();
      expect(a.complete, isTrue);
      expect({a.analyst.model!.id, a.fixer.model!.id, a.verifier.model!.id}, hasLength(3));
      expect(a.warnings.any((w) => w.contains('Tek sağlayıcı')), isTrue);
    });

    test('tek model: üç rol aynı model + "ayrı istek ve ayrı sistem prompt" uyarısı', () async {
      final r = _Rig(keys: {CloudProvider.groq}, catalog: {
        CloudProvider.groq: const [CloudModelInfo('only-x-70b', contextTokens: 131072)],
      });
      await r.pool.discover();
      final a = r.pool.assign();
      expect(a.complete, isTrue);
      expect(a.singleModel, isTrue);
      expect(a.warnings.any((w) => w.contains('tek model') && w.contains('sistem prompt')), isTrue);
      expect(a.verifier.warnings, isNotEmpty);
    });

    test('iki sağlayıcı, iki model: doğrulayıcı düzelticiden farklı model', () async {
      final r = _Rig(keys: {CloudProvider.gemini, CloudProvider.groq}, catalog: {
        CloudProvider.gemini: const [CloudModelInfo('gemini-x-flash', contextTokens: 1048576)],
        CloudProvider.groq: const [CloudModelInfo('qwen-x-coder-32b', contextTokens: 32768)],
      });
      await r.pool.discover();
      final a = r.pool.assign();
      expect(a.fixer.model!.id, isNot(a.verifier.model!.id));
      expect(a.verifier.model!.provider, isNot(a.fixer.model!.provider));
    });

    test('hiç aday yok: PoolPickStatus.none', () {
      final r = _Rig(keys: {});
      final p = r.pool.pick(DevRole.analyst);
      expect(p.status, PoolPickStatus.none);
      expect(p.needsAttention, isTrue);
      expect(r.pool.assign().complete, isFalse);
    });

    test('exclude: dışlanan model asla verilmez', () async {
      final r = _Rig();
      await r.pool.discover();
      final first = r.pool.pick(DevRole.fixer).model!;
      final next = r.pool.pick(DevRole.fixer, exclude: {first.id}).model!;
      expect(next.id, isNot(first.id));
    });

    test('anahtarı silinen sağlayıcının önbellekteki adayları seçilmez', () async {
      final r = _Rig();
      await r.pool.discover();
      r.cfg.providers[CloudProvider.gemini]!.apiKey = '';
      for (final role in [DevRole.analyst, DevRole.fixer, DevRole.verifier]) {
        expect(r.pool.pick(role).model!.provider, isNot(CloudProvider.gemini));
      }
    });
  });

  group('durum makinesi', () {
    Future<_Rig> single() async {
      final r = _Rig(keys: {CloudProvider.groq}, catalog: {
        CloudProvider.groq: const [CloudModelInfo('only-x-70b', contextTokens: 131072)],
      });
      await r.pool.discover();
      return r;
    }

    const id = 'groq:only-x-70b';

    test('KABUL: biri düşünce diğeri devralır; süre dolunca geri döner', () async {
      final r = _Rig();
      await r.pool.discover();
      final a = r.pool.assign();
      final fixer = a.fixer.model!;
      r.pool.report(_limit(fixer.id, const Duration(seconds: 90)));
      final takeover = r.pool.pick(DevRole.fixer);
      expect(takeover.ok, isTrue);
      expect(takeover.model!.id, isNot(fixer.id));
      expect(r.pool.pick(DevRole.analyst).model!.id, a.analyst.model!.id, reason: 'diğer roller etkilenmez');
      r.advance(const Duration(seconds: 91));
      expect(r.pool.pick(DevRole.fixer).model!.id, fixer.id);
    });

    test('cooldown: Retry-After dolana kadar bekleme süresi döner (başarısız sayılmaz)', () async {
      final r = await single();
      r.pool.report(_limit(id, const Duration(seconds: 30)));
      final p = r.pool.pick(DevRole.fixer);
      expect(p.status, PoolPickStatus.wait);
      expect(p.waitFor, const Duration(seconds: 30));
      expect(p.needsAttention, isFalse);
      r.advance(const Duration(seconds: 29));
      expect(r.pool.pick(DevRole.fixer).status, PoolPickStatus.wait);
      r.advance(const Duration(seconds: 2));
      expect(r.pool.pick(DevRole.fixer).ok, isTrue);
      expect(r.pool.snapshot().single.consecutiveFailures, 0, reason: '429 devre kesiciye sayılmaz');
    });

    test('cooldown: ipucu yoksa üstel geri çekilme (en az 60 sn, tavanlı)', () async {
      final r = await single();
      r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.rateLimit));
      expect(r.pool.pick(DevRole.fixer).waitFor, const Duration(seconds: 60));
      r.advance(const Duration(seconds: 61));
      for (var i = 0; i < 8; i++) {
        r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.rateLimit));
        r.advance(const Duration(minutes: 20));
      }
      r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.rateLimit));
      expect(r.pool.pick(DevRole.fixer).waitFor, lessThanOrEqualTo(const DevPoolPolicy().rateLimitMax));
    });

    test('günlük kota: sıfırlanana kadar park; sıfırlanınca serbest', () async {
      final r = await single(); // 2026-10-11 10:00Z
      r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.dailyQuota));
      final p = r.pool.pick(DevRole.fixer);
      expect(p.status, PoolPickStatus.wait);
      expect(p.waitFor, const Duration(hours: 14), reason: 'groq 00:00 UTC sıfırlanır');
      final st = r.pool.snapshot().single;
      expect(st.availability, PoolAvailability.parked);
      expect(st.consecutiveFailures, 0);
      r.advance(const Duration(hours: 14, minutes: 1));
      expect(r.pool.pick(DevRole.fixer).ok, isTrue);
    });

    test('günlük kota: sağlayıcı sıfırlanma saatleri', () {
      final t = DateTime.utc(2026, 10, 11, 10);
      expect(DevModelPool.quotaResetAt(CloudProvider.groq, t), DateTime.utc(2026, 10, 12));
      expect(DevModelPool.quotaResetAt(CloudProvider.openrouter, t), DateTime.utc(2026, 10, 12));
      expect(DevModelPool.quotaResetAt(CloudProvider.gemini, t), DateTime.utc(2026, 10, 12, 7));
      expect(DevModelPool.quotaResetAt(CloudProvider.gemini, DateTime.utc(2026, 10, 11, 5)), DateTime.utc(2026, 10, 11, 7));
    });

    test('günlük kota: sunucu uzun bekleme bildirirse o süre esas alınır', () async {
      final r = await single();
      r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.dailyQuota, retryAfter: const Duration(minutes: 15)));
      expect(r.pool.pick(DevRole.fixer).waitFor, const Duration(minutes: 15));
    });

    test('OpenRouter günlük kotası hesap geneli: tüm :free adaylar park edilir', () async {
      final r = _Rig(keys: {CloudProvider.openrouter});
      await r.pool.discover();
      r.pool.report(PoolReport(modelId: 'openrouter:meta/foo-70b:free', kind: PoolOutcomeKind.dailyQuota));
      final p = r.pool.pick(DevRole.fixer);
      expect(p.status, PoolPickStatus.wait);
      expect(r.pool.snapshot().every((s) => s.availability == PoolAvailability.parked), isTrue);
    });

    test('Groq günlük kotası yalnızca o modeli parklar; diğeri devralır', () async {
      final r = _Rig(keys: {CloudProvider.groq});
      await r.pool.discover();
      final first = r.pool.pick(DevRole.analyst).model!;
      r.pool.report(PoolReport(modelId: first.id, kind: PoolOutcomeKind.dailyQuota));
      final next = r.pool.pick(DevRole.analyst);
      expect(next.ok, isTrue);
      expect(next.model!.id, isNot(first.id));
    });

    test('devre kesici: eşikte açılır, süre dolunca yarı-açık TEK deneme, başarıyla kapanır', () async {
      final r = await single();
      for (var i = 0; i < 3; i++) {
        r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.server));
        r.advance(const Duration(seconds: 21)); // transient cooldown (20 sn) geçsin
      }
      var st = r.pool.snapshot().single;
      expect(st.circuit, PoolCircuit.open);
      expect(st.availability, PoolAvailability.circuitOpen);
      final wait = r.pool.pick(DevRole.fixer);
      expect(wait.status, PoolPickStatus.wait);
      expect(wait.waitFor, lessThanOrEqualTo(const Duration(minutes: 2)));

      r.advance(const Duration(minutes: 2));
      final probe = r.pool.pick(DevRole.fixer);
      expect(probe.ok, isTrue, reason: 'yarı-açık: deneme isteği verilir');
      expect(r.pool.snapshot().single.circuit, PoolCircuit.halfOpen);
      expect(r.pool.pick(DevRole.fixer).status, PoolPickStatus.wait, reason: 'ikinci eşzamanlı deneme verilmez');

      r.pool.report(PoolReport.success(id));
      st = r.pool.snapshot().single;
      expect(st.circuit, PoolCircuit.closed);
      expect(st.consecutiveFailures, 0);
      expect(r.pool.pick(DevRole.fixer).ok, isTrue);
    });

    test('devre kesici: yarı-açık denemede hata devreyi iki katı süreyle yeniden açar', () async {
      final r = await single();
      for (var i = 0; i < 3; i++) {
        r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.timeout));
        r.advance(const Duration(seconds: 21));
      }
      r.advance(const Duration(minutes: 2));
      expect(r.pool.pick(DevRole.fixer).ok, isTrue); // deneme
      r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.network));
      final st = r.pool.snapshot().single;
      expect(st.circuit, PoolCircuit.open);
      final p = r.pool.pick(DevRole.fixer);
      expect(p.status, PoolPickStatus.wait);
      expect(p.waitFor, greaterThan(const Duration(minutes: 3)), reason: '4 dk (2 dk x 2)');
      expect(p.waitFor, lessThanOrEqualTo(const Duration(minutes: 4)));
    });

    test('yarı-açık deneme sonucu hiç gelmezse probeTimeout sonrası yeni deneme verilir', () async {
      final r = await single();
      for (var i = 0; i < 3; i++) {
        r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.server));
        r.advance(const Duration(seconds: 21));
      }
      r.advance(const Duration(minutes: 2));
      expect(r.pool.pick(DevRole.fixer).ok, isTrue);
      expect(r.pool.pick(DevRole.fixer).status, PoolPickStatus.wait);
      r.advance(const Duration(minutes: 3, seconds: 1));
      expect(r.pool.pick(DevRole.fixer).ok, isTrue);
    });

    test('başarı sayaçları sıfırlar: kesintili hatalar devreyi açmaz', () async {
      final r = await single();
      for (var i = 0; i < 6; i++) {
        r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.server));
        r.advance(const Duration(seconds: 21));
        r.pool.report(PoolReport.success(id));
      }
      expect(r.pool.snapshot().single.circuit, PoolCircuit.closed);
    });

    test('hepsi parkta: EN KISA bekleme süresi döner, sonra o model verilir', () async {
      final r = _Rig(keys: {CloudProvider.groq}, catalog: {
        CloudProvider.groq: const [
          CloudModelInfo('a-x-70b', contextTokens: 131072),
          CloudModelInfo('b-x-70b', contextTokens: 131072),
          CloudModelInfo('c-x-70b', contextTokens: 131072),
        ],
      });
      await r.pool.discover();
      r.pool.report(_limit('groq:a-x-70b', const Duration(seconds: 600)));
      r.pool.report(_limit('groq:b-x-70b', const Duration(seconds: 30)));
      r.pool.report(_limit('groq:c-x-70b', const Duration(seconds: 90)));
      for (final role in [DevRole.analyst, DevRole.fixer, DevRole.verifier]) {
        final p = r.pool.pick(role);
        expect(p.status, PoolPickStatus.wait);
        expect(p.waitFor, const Duration(seconds: 30));
        expect(p.model, isNull);
      }
      r.advance(const Duration(seconds: 31));
      expect(r.pool.pick(DevRole.fixer).model!.id, 'groq:b-x-70b');
    });

    test('bekleme süresi adayın GERÇEKTEN kullanılabilir olacağı ana göre hesaplanır (en geç biten engel)', () async {
      final r = await single();
      for (var i = 0; i < 3; i++) {
        r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.server));
        r.advance(const Duration(seconds: 21));
      }
      // cooldown (20 sn) çoktan bitti ama devre 2 dk açık: bekleme ~2 dk - 21 sn
      final w = r.pool.pick(DevRole.fixer).waitFor!;
      expect(w, greaterThan(const Duration(seconds: 90)));
    });

    test('auth: sağlayıcı park edilir ve kullanıcı ilgisi gerekir; başarı engeli kaldırır', () async {
      final r = await single();
      r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.auth));
      final p = r.pool.pick(DevRole.fixer);
      expect(p.status, PoolPickStatus.wait);
      expect(p.needsAttention, isTrue);
      expect(r.pool.snapshot().single.availability, PoolAvailability.blocked);
      r.advance(const Duration(hours: 3));
      expect(r.pool.pick(DevRole.fixer).ok, isTrue);
    });

    test('notFound: model ölü; yeniden keşifte listede yoksa havuzdan çıkar', () async {
      final r = _Rig(keys: {CloudProvider.groq});
      await r.pool.discover();
      r.pool.report(PoolReport(modelId: 'groq:qwen-x-coder-32b', kind: PoolOutcomeKind.notFound));
      expect(r.pool.snapshot().firstWhere((s) => s.model.model == 'qwen-x-coder-32b').availability, PoolAvailability.dead);
      expect(r.pool.pick(DevRole.fixer).model!.model, isNot('qwen-x-coder-32b'));
      r.svc.catalog[CloudProvider.groq] = const [CloudModelInfo('llama-x-70b-versatile', contextTokens: 131072)];
      await r.pool.discover();
      expect(r.pool.modelById('groq:qwen-x-coder-32b'), isNull);
    });

    test('badOutput ve tooLarge havuz durumunu değiştirmez; badRequest kısa dinlendirir', () async {
      final r = await single();
      r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.badOutput));
      r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.tooLarge));
      expect(r.pool.pick(DevRole.fixer).ok, isTrue);
      expect(r.pool.snapshot().single.consecutiveFailures, 0);
      r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.badRequest));
      expect(r.pool.pick(DevRole.fixer).waitFor, const Duration(seconds: 30));
    });

    test('bilinmeyen model kimliği: report false döner, istisna yok', () async {
      final r = await single();
      expect(r.pool.report(PoolReport(modelId: 'yok:yok', kind: PoolOutcomeKind.server)), isFalse);
      expect(r.pool.report(PoolReport.success(id)), isTrue);
    });

    test('hasUsable: bekleme sırasında false', () async {
      final r = await single();
      expect(r.pool.hasUsable, isTrue);
      r.pool.report(_limit(id, const Duration(seconds: 10)));
      expect(r.pool.hasUsable, isFalse);
    });

    test('invalidateProvider: adaylar ve engeller silinir', () async {
      final r = await single();
      r.pool.report(PoolReport(modelId: id, kind: PoolOutcomeKind.auth));
      r.pool.invalidateProvider(CloudProvider.groq);
      expect(r.pool.size, 0);
      await r.pool.discover();
      expect(r.pool.pick(DevRole.fixer).ok, isTrue);
    });
  });

  group('PoolReport sınıflandırma', () {
    test('HTTP durum kodlarından tür', () {
      PoolReport h(int s, [String body = '', String? ra]) =>
          PoolReport.fromHttp(modelId: 'groq:x', status: s, body: body, retryAfterHeader: ra);
      expect(h(429, 'too many requests').kind, PoolOutcomeKind.rateLimit);
      expect(h(429, 'GenerateRequestsPerDayPerProjectPerModel').kind, PoolOutcomeKind.dailyQuota);
      expect(h(429, 'x', '17').retryAfter, const Duration(seconds: 17));
      expect(h(429, '{"retryDelay": "34s"}').retryAfter, const Duration(seconds: 34));
      expect(h(401).kind, PoolOutcomeKind.auth);
      expect(h(403).kind, PoolOutcomeKind.auth);
      expect(h(404).kind, PoolOutcomeKind.notFound);
      expect(h(413).kind, PoolOutcomeKind.tooLarge);
      expect(h(400).kind, PoolOutcomeKind.badRequest);
      expect(h(408).kind, PoolOutcomeKind.timeout);
      expect(h(503).kind, PoolOutcomeKind.server);
      expect(h(418).kind, PoolOutcomeKind.other);
    });

    test('OpenRouter X-RateLimit-Reset (epoch ms) günlük sıfırlanma süresi olur', () {
      final now = DateTime.utc(2026, 10, 11, 10);
      final reset = now.add(const Duration(hours: 3)).millisecondsSinceEpoch;
      final r = PoolReport.fromHttp(
        modelId: 'openrouter:a/b:free',
        status: 429,
        body: '{"error":{"message":"Rate limit exceeded: free-models-per-day","metadata":{"headers":{"X-RateLimit-Reset":"$reset"}}}}',
        now: now,
      );
      expect(r.kind, PoolOutcomeKind.dailyQuota);
      expect(r.retryAfter, const Duration(hours: 3));
    });

    test('istisnalardan tür', () {
      expect(PoolReport.fromError('a:b', const SocketException('x')).kind, PoolOutcomeKind.network);
      expect(PoolReport.fromError('a:b', StateError('x')).kind, PoolOutcomeKind.other);
    });
  });

  group('güven puanı (ModelTrust)', () {
    test('güveni düşen (demote) model yalnızca başka seçenek yoksa seçilir', () async {
      final trust = ModelTrust();
      final r = _Rig(trust: trust);
      await r.pool.discover();
      final best = r.pool.pick(DevRole.fixer).model!;
      for (var i = 0; i < 6; i++) {
        trust.observe(best.id, rejected: true);
      }
      expect(trust.isDemoted(best.id), isTrue);
      final next = r.pool.pick(DevRole.fixer).model!;
      expect(next.id, isNot(best.id));
      // Yalnızca o model kaldıysa yine de verilir.
      final others = {for (final s in r.pool.snapshot()) if (s.model.id != best.id) s.model.id};
      expect(r.pool.pick(DevRole.fixer, exclude: others).model!.id, best.id);
    });

    test('ret oranı puanı kırar: güvenilir model öne geçer', () async {
      final trust = ModelTrust();
      final r = _Rig(trust: trust, keys: {CloudProvider.groq}, catalog: {
        CloudProvider.groq: const [
          CloudModelInfo('a-x-70b', contextTokens: 131072),
          CloudModelInfo('b-x-70b', contextTokens: 131072),
        ],
      });
      await r.pool.discover();
      final first = r.pool.pick(DevRole.analyst).model!;
      for (var i = 0; i < 3; i++) {
        trust.observe(first.id, rejected: true);
      }
      expect(r.pool.pick(DevRole.analyst).model!.id, isNot(first.id));
    });
  });

  group('sır güvenliği', () {
    test('günlük, rapor mesajı ve önbellekte anahtar bulunmaz', () async {
      final f = File('${tmp.path}/pool_cache.json');
      final r = _Rig(cache: f);
      for (final p in CloudProvider.values) {
        SecretMask.register(_fakeKey(p));
      }
      await r.pool.discover();
      final key = _fakeKey(CloudProvider.groq);
      final rep = PoolReport(modelId: 'groq:llama-x-70b-versatile', kind: PoolOutcomeKind.server, message: 'hata Bearer $key $key');
      expect(rep.message.contains(key), isFalse);
      r.pool.report(rep);
      r.pool.report(PoolReport(modelId: 'groq:llama-x-70b-versatile', kind: PoolOutcomeKind.auth, message: key));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final all = '${r.logs.join('\n')}\n${f.readAsStringSync()}\n${r.pool.snapshot().map((s) => s.model.id).join(',')}';
      for (final p in CloudProvider.values) {
        expect(all.contains(_fakeKey(p)), isFalse);
      }
    });
  });
}
