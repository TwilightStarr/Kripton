import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/cloud_engine.dart';
import 'package:kripton_ai/data/llm_engine.dart';

const String _prompt =
    '<|im_start|>system\nSistem<|im_end|>\n<|im_start|>user\nMerhaba<|im_end|>\n<|im_start|>assistant\n';

typedef _Handler = Future<void> Function(HttpRequest req);

/// Yerel sahte sağlayıcı sunucusu: yol başına sıralı yanıt senaryosu (son adım tekrarlanır).
class _Srv {
  late HttpServer server;
  final Map<String, List<_Handler>> script = {};
  final Map<String, int> hits = {};
  final Map<String, List<DateTime>> times = {};

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      final n = hits[path] = (hits[path] ?? 0) + 1;
      (times[path] ??= <DateTime>[]).add(DateTime.now());
      try {
        await req.drain<void>();
      } catch (_) {}
      final steps = script[path];
      try {
        if (steps == null || steps.isEmpty) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        await steps[n - 1 < steps.length ? n - 1 : steps.length - 1](req);
      } catch (_) {}
    });
  }

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> stop() => server.close(force: true);

  int hit(String path) => hits[path] ?? 0;
}

_Handler _status(int code, {Map<String, String> headers = const {}, String body = '{"error":{"message":"hata"}}'}) =>
    (req) async {
      req.response.statusCode = code;
      headers.forEach(req.response.headers.set);
      req.response.write(body);
      await req.response.close();
    };

_Handler _sse(List<String> datas, {bool done = true}) => (req) async {
      req.response.headers.contentType = ContentType('text', 'event-stream');
      for (final d in datas) {
        req.response.write('data: $d\n\n');
      }
      if (done) req.response.write('data: [DONE]\n\n');
      await req.response.close();
    };

_Handler _plain(String body) => (req) async {
      req.response.headers.contentType = ContentType('application', 'json');
      req.response.write(body);
      await req.response.close();
    };

String _oa(String t) => jsonEncode({
      'choices': [
        {
          'delta': {'content': t},
        },
      ],
    });

String _gm(String t) => jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': t},
            ],
          },
        },
      ],
    });

const CloudRetryPolicy _fast = CloudRetryPolicy(
  maxAttempts: 6,
  baseDelayMs: 40,
  maxDelayMs: 300,
  jitter: 0,
  minCooldownMs: 0,
  minWaitMs: 10,
  paceScale: 0,
  connectTimeout: Duration(seconds: 2),
  headersTimeout: Duration(seconds: 2),
  idleTimeout: Duration(milliseconds: 400),
  errorBodyTimeout: Duration(seconds: 1),
  maxStreamDuration: Duration(seconds: 5),
  researchAttempts: 3,
);

CloudConfig _cfg() {
  final c = CloudConfig.isolated();
  for (final e in c.providers.entries) {
    e.value.apiKey = 'test-key-${e.key.name}-123456';
  }
  return c;
}

void main() {
  late _Srv srv;

  setUp(() async {
    HttpOverrides.global = null; // gerçek (yerel) HttpClient
    CloudEngine.resetCooldowns();
    srv = _Srv();
    await srv.start();
  });

  tearDown(() async {
    await srv.stop();
    CloudEngine.resetCooldowns();
  });

  CloudEngine engine({CloudRetryPolicy policy = _fast, CloudConfig? config}) => CloudEngine(
        config: config ?? _cfg(),
        policy: policy,
        endpoints: {
          CloudProvider.gemini: srv.uri('/gemini'),
          CloudProvider.groq: srv.uri('/groq'),
          CloudProvider.openrouter: srv.uri('/or'),
        },
      );

  Future<String> run(CloudEngine e, {String path = 'cloud:auto'}) async {
    await e.ensureLoaded(path);
    return (await e.generate(_prompt).toList()).join();
  }

  Future<GenerationFailedException> runFail(CloudEngine e, {String path = 'cloud:auto'}) async {
    try {
      await run(e, path: path);
    } on GenerationFailedException catch (x) {
      return x;
    }
    fail('Hata bekleniyordu');
  }

  test('üstel geri çekilme: n. ardışık başarısızlıkta süre ikiye katlanır, tavanlanır, sapma sınırlıdır', () {
    const p = CloudRetryPolicy(baseDelayMs: 100, maxDelayMs: 1000, jitter: 0);
    final r = math.Random(1);
    expect([for (var i = 1; i <= 6; i++) p.backoffMs(i, r)], [100, 200, 400, 800, 1000, 1000]);
    expect(p.backoffMs(500, r), 1000);
    const pj = CloudRetryPolicy(baseDelayMs: 1000, maxDelayMs: 100000, jitter: 0.2);
    for (var i = 0; i < 50; i++) {
      expect(pj.backoffMs(3, r), inInclusiveRange(3200, 4800));
    }
  });

  test('5xx sonrası geri çekilip yeniden dener ve başarır', () async {
    srv.script['/groq'] = [
      _status(503),
      _sse([_oa('Mer'), _oa('haba')]),
    ];
    expect(await run(engine(), path: 'cloud:groq'), 'Merhaba');
    expect(srv.hit('/groq'), 2);
  });

  test('geri çekilme gerçekten üstel: ardışık denemeler arası süre büyür', () async {
    const policy = CloudRetryPolicy(
      maxAttempts: 6,
      baseDelayMs: 100,
      maxDelayMs: 2000,
      jitter: 0,
      minCooldownMs: 0,
      minWaitMs: 10,
      paceScale: 0,
    );
    srv.script['/groq'] = [
      _status(503),
      _status(503),
      _status(503),
      _sse([_oa('tamam')]),
    ];
    expect(await run(engine(policy: policy), path: 'cloud:groq'), 'tamam');
    final t = srv.times['/groq']!;
    expect(t.length, 4);
    final g1 = t[1].difference(t[0]).inMilliseconds;
    final g2 = t[2].difference(t[1]).inMilliseconds;
    final g3 = t[3].difference(t[2]).inMilliseconds;
    expect(g1, greaterThanOrEqualTo(80));
    expect(g2, greaterThanOrEqualTo(180));
    expect(g3, greaterThanOrEqualTo(380));
    expect(g2, greaterThan(g1));
    expect(g3, greaterThan(g2));
  });

  test('429 Retry-After başlığına uyulur', () async {
    srv.script['/groq'] = [
      _status(429, headers: {'retry-after': '1'}),
      _sse([_oa('ok')]),
    ];
    expect(await run(engine(), path: 'cloud:groq'), 'ok');
    final t = srv.times['/groq']!;
    expect(t[1].difference(t[0]).inMilliseconds, greaterThanOrEqualTo(900));
  });

  test('sağlayıcı sırası düşme: ilk sağlayıcı 500 verince sıradaki yanıt verir', () async {
    srv.script['/gemini'] = [_status(500)];
    srv.script['/groq'] = [
      _sse([_oa('Selam')]),
    ];
    final e = engine();
    expect(await run(e), 'Selam');
    expect(srv.hit('/gemini'), 1);
    expect(e.lastProviderLabel, 'Groq');
  });

  test('boş veya yalnızca boşluktan oluşan yanıt hata sayılır ve sıradaki sağlayıcıya geçilir', () async {
    srv.script['/gemini'] = [
      _sse([_gm('   \n ')]),
    ];
    srv.script['/groq'] = [
      _sse([_oa('dolu')]),
    ];
    expect(await run(engine()), 'dolu');
    expect(srv.hit('/gemini'), 1);
  });

  test('bozuk/yarım SSE satırları atlanır, geçerli metin iletilir', () async {
    srv.script['/groq'] = [
      (req) async {
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.write('data: {bozuk\n\n');
        req.response.write(': yorum satırı\n\n');
        req.response.write('data: ${_oa('Tamam')}\n\n');
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      },
    ];
    expect(await run(engine(), path: 'cloud:groq'), 'Tamam');
  });

  test('200 durumlu düz JSON hata gövdesi sınıflandırılır ve yedek sağlayıcıya geçilir', () async {
    srv.script['/gemini'] = [_plain('{"error":{"code":503,"message":"yüklü"}}')];
    srv.script['/groq'] = [
      _sse([_oa('B')]),
    ];
    expect(await run(engine()), 'B');
    expect(srv.hit('/gemini'), 1);
  });

  test('akışsız (düz JSON) başarılı yanıt da okunur', () async {
    srv.script['/groq'] = [
      _plain('{"choices":[{"message":{"content":"Düz"}}]}'),
    ];
    expect(await run(engine(), path: 'cloud:groq'), 'Düz');
  });

  test('en çok deneme: sonsuz döngü yok, CLOUD_ATTEMPTS ile anlaşılır hata', () async {
    srv.script['/groq'] = [_status(503)];
    const policy = CloudRetryPolicy(
      maxAttempts: 3,
      baseDelayMs: 20,
      maxDelayMs: 50,
      jitter: 0,
      minCooldownMs: 0,
      minWaitMs: 5,
      paceScale: 0,
    );
    final err = await runFail(engine(policy: policy), path: 'cloud:groq');
    expect(err.code, 'CLOUD_ATTEMPTS');
    expect(srv.hit('/groq'), 3);
  });

  test('anahtar reddedilince (401) yeniden denenmez ve CLOUD_AUTH verilir', () async {
    srv.script['/gemini'] = [_status(401)];
    final err = await runFail(engine(), path: 'cloud:gemini');
    expect(err.code, 'CLOUD_AUTH');
    expect(srv.hit('/gemini'), 1);
  });

  test('akış sessiz kalırsa (boşta zaman aşımı) hata verir, takılı kalmaz', () async {
    srv.script['/gemini'] = [
      (req) async {
        req.response.headers.contentType = ContentType('text', 'event-stream');
        await req.response.flush();
        await Future<void>.delayed(const Duration(seconds: 3));
        await req.response.close();
      },
    ];
    const policy = CloudRetryPolicy(
      maxAttempts: 2,
      baseDelayMs: 20,
      maxDelayMs: 50,
      jitter: 0,
      minCooldownMs: 0,
      minWaitMs: 5,
      paceScale: 0,
      idleTimeout: Duration(milliseconds: 300),
    );
    final err = await runFail(engine(policy: policy), path: 'cloud:gemini').timeout(const Duration(seconds: 10));
    expect(err.code, 'CLOUD_ATTEMPTS');
    expect(srv.hit('/gemini'), 2);
  });

  test('metin iletildikten sonra bağlantı kopması CLOUD_MIDSTREAM olur (başka sağlayıcıyla karışmaz)', () async {
    srv.script['/groq'] = [
      (req) async {
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.write('data: ${_oa('Par')}\n\n');
        await req.response.flush();
        final s = await req.response.detachSocket(writeHeaders: false);
        s.destroy();
      },
    ];
    srv.script['/or'] = [
      _sse([_oa('KARIŞMAMALI')]),
    ];
    final got = <String>[];
    Object? err;
    final e = engine();
    await e.ensureLoaded('cloud:auto');
    try {
      await for (final t in e.generate(_prompt)) {
        got.add(t);
      }
    } on GenerationFailedException catch (x) {
      err = x;
    }
    expect(got.join(), 'Par');
    expect((err as GenerationFailedException).code, 'CLOUD_MIDSTREAM');
    expect(srv.hit('/or'), 0);
  });

  test('iptal: abonelik iptali bağlantıyı kapatır ve motor boşa çıkar', () async {
    srv.script['/groq'] = [
      (req) async {
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.write('data: ${_oa('ilk')}\n\n');
        await req.response.flush();
        await Future<void>.delayed(const Duration(seconds: 5));
        await req.response.close();
      },
    ];
    final e = engine();
    await e.ensureLoaded('cloud:groq');
    final got = <String>[];
    final sub = e.generate(_prompt).listen(got.add);
    final end = DateTime.now().add(const Duration(seconds: 3));
    while (got.isEmpty && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(got, ['ilk']);
    await sub.cancel();
    expect(await e.waitNativeIdle(const Duration(seconds: 2)), isTrue);
  });

  test('stop(): sürmekte olan üretim hatasız biter', () async {
    srv.script['/groq'] = [
      (req) async {
        req.response.headers.contentType = ContentType('text', 'event-stream');
        await req.response.flush();
        await Future<void>.delayed(const Duration(seconds: 5));
        await req.response.close();
      },
    ];
    final e = engine();
    await e.ensureLoaded('cloud:groq');
    final f = e.generate(_prompt).toList();
    final end = DateTime.now().add(const Duration(seconds: 3));
    while (srv.hit('/groq') == 0 && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await e.stop();
    expect(await f.timeout(const Duration(seconds: 3)), isEmpty);
    expect(await e.waitNativeIdle(const Duration(seconds: 2)), isTrue);
  });

  test('hata senaryosunda yakalanmamış (zone) istisna sızmaz', () async {
    srv.script['/groq'] = [_status(500)];
    const policy = CloudRetryPolicy(
      maxAttempts: 2,
      baseDelayMs: 10,
      maxDelayMs: 20,
      jitter: 0,
      minCooldownMs: 0,
      minWaitMs: 5,
      paceScale: 0,
    );
    final zoneErrors = <Object>[];
    final done = Completer<void>();
    runZonedGuarded(() async {
      try {
        await run(engine(policy: policy), path: 'cloud:groq');
      } on GenerationFailedException {
        // beklenen: kullanıcıya anlaşılır hata
      }
      done.complete();
    }, (e, st) => zoneErrors.add(e));
    await done.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(zoneErrors, isEmpty);
  });

  group('cloudResearch', () {
    const okBody =
        '{"candidates":[{"content":{"parts":[{"text":"Araştırma notu"}]},"groundingMetadata":{"groundingChunks":[{"web":{"title":"Kaynak A"}}]}}]}';

    Future<String?> research({CloudCancelToken? cancel, CloudConfig? config}) => cloudResearch(
          'hedef',
          cancel: cancel,
          policy: _fast,
          config: config ?? _cfg(),
          endpoint: srv.uri('/gemini'),
        );

    test('başarılı yanıt: not ve kaynaklar döner', () async {
      srv.script['/gemini'] = [_plain(okBody)];
      final r = await research();
      expect(r, contains('Araştırma notu'));
      expect(r, contains('Kaynak A'));
    });

    test('geçici hatada geri çekilip yeniden dener', () async {
      srv.script['/gemini'] = [_status(500), _status(503), _plain(okBody)];
      expect(await research(), contains('Araştırma notu'));
      expect(srv.hit('/gemini'), 3);
    });

    test('sürekli hata: istisna yok, null döner, deneme sayısı sınırlı', () async {
      srv.script['/gemini'] = [_status(500)];
      expect(await research(), isNull);
      expect(srv.hit('/gemini'), 3);
    });

    test('kalıcı hata (401) tek denemeden sonra null', () async {
      srv.script['/gemini'] = [_status(401)];
      expect(await research(), isNull);
      expect(srv.hit('/gemini'), 1);
    });

    test('bozuk JSON gövde: istisna sızmaz', () async {
      srv.script['/gemini'] = [_plain('{bozuk')];
      expect(await research(), isNull);
    });

    test('iptal: bekleyen araştırma hemen null ile biter', () async {
      srv.script['/gemini'] = [
        (req) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          await req.response.close();
        },
      ];
      final tok = CloudCancelToken();
      final f = research(cancel: tok);
      final end = DateTime.now().add(const Duration(seconds: 3));
      while (srv.hit('/gemini') == 0 && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      tok.cancel();
      expect(await f.timeout(const Duration(seconds: 3)), isNull);
    });

    test('anahtar yok / araştırma kapalı: ağa çıkmadan null', () async {
      final c = _cfg()..research = false;
      expect(await research(config: c), isNull);
      final d = CloudConfig.isolated();
      expect(await research(config: d), isNull);
      expect(srv.hit('/gemini'), 0);
    });
  });
}
