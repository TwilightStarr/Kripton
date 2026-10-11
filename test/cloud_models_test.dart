// Değişiklik: yeni dosya. Bulut model servisi, model adı temizleme ve anahtar maskeleme testleri.
// Ağa çıkılmaz: dart:io HttpClient sahte bir istemciyle değiştirilir.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/cloud_engine.dart';
import 'package:kripton_ai/data/cloud_models.dart';
import 'package:kripton_ai/data/crash_guard.dart';
import 'package:kripton_ai/data/secret_mask.dart';

// ------------------------------------------------------------------ sahte HttpClient

class _Req {
  _Req(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;
}

class _Reply {
  const _Reply(this.status, this.body);

  final int status;
  final String body;
}

typedef _Handler = FutureOr<_Reply> Function(_Req req);

class _FakeHeaders implements HttpHeaders {
  final Map<String, String> map = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    map[name.toLowerCase()] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._method, this._uri, this._handler);

  final String _method;
  final Uri _uri;
  final _Handler _handler;
  final _FakeHeaders _headers = _FakeHeaders();
  final BytesBuilder _body = BytesBuilder();

  @override
  int contentLength = -1;

  @override
  HttpHeaders get headers => _headers;

  @override
  void add(List<int> data) => _body.add(data);

  @override
  Future<HttpClientResponse> close() async {
    final reply = await _handler(_Req(_method, _uri, _headers.map, utf8.decode(_body.toBytes())));
    return _FakeResponse(reply.status, reply.body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, String body) : _bytes = utf8.encode(body);

  final List<int> _bytes;

  @override
  final int statusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(_bytes).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements HttpClient {
  _FakeClient(this._handler);

  final _Handler _handler;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeRequest('GET', url, _handler);

  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _FakeRequest('POST', url, _handler);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ------------------------------------------------------------------ yardımcılar

const String _geminiKey = 'AIzaSyFAKE_test-key-1234567890ABCDEFGH';
const String _groqKey = 'gsk_FAKEtestkey1234567890abcdefghij';
const String _orKey = 'sk-or-v1-faketestkey1234567890abcdef';

/// İstekleri [log]'a yazan, yanıtı [handler] belirleyen servis.
CloudModelService _service(
  _Handler handler, {
  List<_Req>? log,
  Duration timeout = const Duration(seconds: 3),
}) {
  return CloudModelService(
    timeout: timeout,
    clientFactory: () => _FakeClient((req) {
      log?.add(req);
      return handler(req);
    }),
  );
}

_Reply _json(int status, Object body) => _Reply(status, jsonEncode(body));

Map<String, dynamic> _geminiList() => {
      'models': [
        {
          'name': 'models/gemini-2.5-pro',
          'displayName': 'Gemini 2.5 Pro',
          'inputTokenLimit': 1048576,
          'supportedGenerationMethods': ['generateContent', 'countTokens'],
        },
        {
          'name': 'models/gemini-2.5-flash',
          'displayName': 'Gemini 2.5 Flash',
          'supportedGenerationMethods': ['generateContent'],
        },
        {
          'name': 'models/text-embedding-004',
          'supportedGenerationMethods': ['embedContent'],
        },
        {
          'name': 'models/gemini-2.5-flash-preview-tts',
          'supportedGenerationMethods': ['generateContent'],
        },
        {
          'name': 'models/imagen-4.0-generate-001',
          'supportedGenerationMethods': ['predict'],
        },
      ],
    };

Map<String, dynamic> _groqList() => {
      'object': 'list',
      'data': [
        {'id': 'llama-3.3-70b-versatile', 'active': true, 'context_window': 131072},
        {'id': 'openai/gpt-oss-120b', 'active': true},
        {'id': 'whisper-large-v3', 'active': true},
        {'id': 'playai-tts', 'active': true},
        {'id': 'meta-llama/llama-guard-4-12b', 'active': true},
        {'id': 'eski-model', 'active': false},
      ],
    };

Map<String, dynamic> _orList() => {
      'data': [
        {
          'id': 'meta-llama/llama-3.3-70b-instruct:free',
          'name': 'Llama 3.3 70B',
          'context_length': 65536,
          'architecture': {
            'input_modalities': ['text'],
            'output_modalities': ['text'],
          },
        },
        {
          'id': 'google/gemini-2.5-flash-image',
          'architecture': {
            'output_modalities': ['image', 'text'],
          },
        },
        {
          'id': 'openai/text-embedding-3-small',
          'architecture': {
            'output_modalities': ['embeddings'],
          },
        },
        {
          'id': 'vendor/yalniz-gorsel',
          'architecture': {
            'output_modalities': ['image'],
          },
        },
      ],
    };

void main() {
  setUp(SecretMask.clear);

  group('modelleri getir', () {
    test('Gemini: geçerli anahtar; sohbet dışı modeller elenir, sıralı döner', () async {
      final log = <_Req>[];
      final r = await _service((req) => _json(200, _geminiList()), log: log)
          .fetchModels(CloudProvider.gemini, '  $_geminiKey  ');
      expect(r.ok, isTrue);
      expect(r.kind, CloudCheckKind.ok);
      expect(r.models.map((m) => m.id).toList(), ['gemini-2.5-flash', 'gemini-2.5-pro']);
      expect(r.filteredOut, 3);
      expect(r.models.last.contextTokens, 1048576);
      expect(log, hasLength(1));
      expect(log.single.method, 'GET');
      expect(log.single.uri.path, '/v1beta/models');
      expect(log.single.headers['x-goog-api-key'], _geminiKey);
      expect(log.single.uri.toString(), isNot(contains(_geminiKey)));
    });

    test('Gemini: sayfalı liste birleştirilir', () async {
      final log = <_Req>[];
      final r = await _service((req) {
        if (req.uri.queryParameters['pageToken'] == null) {
          return _json(200, {
            'models': [
              {'name': 'models/gemini-a', 'supportedGenerationMethods': ['generateContent']},
            ],
            'nextPageToken': 'sonraki',
          });
        }
        return _json(200, {
          'models': [
            {'name': 'models/gemini-b', 'supportedGenerationMethods': ['generateContent']},
          ],
        });
      }, log: log)
          .fetchModels(CloudProvider.gemini, _geminiKey);
      expect(r.ok, isTrue);
      expect(r.models.map((m) => m.id).toList(), ['gemini-a', 'gemini-b']);
      expect(log, hasLength(2));
      expect(log[1].uri.queryParameters['pageToken'], 'sonraki');
    });

    test('Groq: geçerli anahtar; whisper/tts/guard/pasif model elenir', () async {
      final log = <_Req>[];
      final r = await _service((req) => _json(200, _groqList()), log: log)
          .fetchModels(CloudProvider.groq, _groqKey);
      expect(r.ok, isTrue);
      expect(r.models.map((m) => m.id).toList(), ['llama-3.3-70b-versatile', 'openai/gpt-oss-120b']);
      expect(r.filteredOut, 4);
      expect(log.single.uri.path, '/openai/v1/models');
      expect(log.single.headers['authorization'], 'Bearer $_groqKey');
    });

    test('OpenRouter: önce /key ile anahtar sınanır, sonra metin modelleri alınır', () async {
      final log = <_Req>[];
      final r = await _service((req) {
        if (req.uri.path.endsWith('/key')) return _json(200, {'data': {'label': 'x'}});
        return _json(200, _orList());
      }, log: log)
          .fetchModels(CloudProvider.openrouter, _orKey);
      expect(r.ok, isTrue);
      expect(r.models.map((m) => m.id).toList(), ['meta-llama/llama-3.3-70b-instruct:free']);
      expect(r.filteredOut, 3);
      expect(log.map((q) => q.uri.path).toList(), ['/api/v1/key', '/api/v1/models']);
    });

    test('OpenRouter: /key 401 verirse liste istenmez', () async {
      final log = <_Req>[];
      final r = await _service((req) => _json(401, {'error': {'message': 'No auth credentials found'}}), log: log)
          .fetchModels(CloudProvider.openrouter, _orKey);
      expect(r.kind, CloudCheckKind.invalidKey);
      expect(log, hasLength(1));
    });

    test('401: anahtar geçersiz; hata gövdesi anahtarı yansıtsa bile mesajda anahtar yok', () async {
      final r = await _service(
        (req) => _json(401, {'error': {'message': 'Invalid API Key: $_groqKey'}}),
      ).fetchModels(CloudProvider.groq, _groqKey);
      expect(r.ok, isFalse);
      expect(r.kind, CloudCheckKind.invalidKey);
      expect(r.statusCode, 401);
      expect(r.message, contains('geçersiz'));
      expect(r.message, isNot(contains(_groqKey)));
      expect(r.suggestedModel, CloudProvider.groq.defaultModel);
      expect(r.models, isEmpty);
    });

    test('403 anahtar geçersiz sayılır; Gemini 400 API_KEY_INVALID de öyle', () async {
      final r403 = await _service((req) => _json(403, {'error': {'message': 'yasak'}}))
          .fetchModels(CloudProvider.groq, _groqKey);
      expect(r403.kind, CloudCheckKind.invalidKey);

      final r400 = await _service(
        (req) => _json(400, {
          'error': {
            'code': 400,
            'message': 'API key not valid. Please pass a valid API key.',
            'details': [
              {'reason': 'API_KEY_INVALID'},
            ],
          },
        }),
      ).fetchModels(CloudProvider.gemini, _geminiKey);
      expect(r400.kind, CloudCheckKind.invalidKey);
      expect(r400.suggestedModel, CloudProvider.gemini.defaultModel);
    });

    test('429: kota; varsayılan model önerilir', () async {
      final r = await _service((req) => _json(429, {'error': {'message': 'Rate limit'}}))
          .fetchModels(CloudProvider.gemini, _geminiKey);
      expect(r.kind, CloudCheckKind.quota);
      expect(r.statusCode, 429);
      expect(r.message, contains('kota'));
      expect(r.suggestedModel, 'gemini-2.5-flash');
    });

    test('boş liste: emptyList ve varsayılan model önerisi', () async {
      final r = await _service((req) => _json(200, {'data': <Object>[]}))
          .fetchModels(CloudProvider.groq, _groqKey);
      expect(r.kind, CloudCheckKind.emptyList);
      expect(r.models, isEmpty);
      expect(r.message, contains('boş'));
      expect(r.suggestedModel, CloudProvider.groq.defaultModel);
    });

    test('yalnızca sohbet dışı modeller gelirse de liste boş sayılır', () async {
      final r = await _service((req) => _json(200, {
            'data': [
              {'id': 'whisper-large-v3', 'active': true},
            ],
          })).fetchModels(CloudProvider.groq, _groqKey);
      expect(r.kind, CloudCheckKind.emptyList);
      expect(r.filteredOut, 1);
    });

    test('ağ hatası: network türü; anahtar yok, varsayılan model önerilir', () async {
      final r = await _service((req) => throw const SocketException('Failed host lookup'))
          .fetchModels(CloudProvider.openrouter, _orKey);
      expect(r.kind, CloudCheckKind.network);
      expect(r.message, contains('Ağ'));
      expect(r.message, isNot(contains(_orKey)));
      expect(r.suggestedModel, CloudProvider.openrouter.defaultModel);
    });

    test('zaman aşımı: timeout türü', () async {
      final never = Completer<_Reply>();
      final r = await _service(
        (req) => never.future,
        timeout: const Duration(milliseconds: 60),
      ).fetchModels(CloudProvider.groq, _groqKey);
      expect(r.kind, CloudCheckKind.timeout);
      expect(r.suggestedModel, CloudProvider.groq.defaultModel);
    });

    test('500 ve JSON olmayan yanıt: other türü', () async {
      final r500 = await _service((req) => const _Reply(503, 'Service Unavailable'))
          .fetchModels(CloudProvider.groq, _groqKey);
      expect(r500.kind, CloudCheckKind.other);
      expect(r500.statusCode, 503);

      final rBad = await _service((req) => const _Reply(200, '<html>giriş sayfası</html>'))
          .fetchModels(CloudProvider.groq, _groqKey);
      expect(rBad.kind, CloudCheckKind.other);
    });

    test('anahtar boşsa istek atılmaz', () async {
      final log = <_Req>[];
      final r = await _service((req) => _json(200, _groqList()), log: log)
          .fetchModels(CloudProvider.groq, '   ');
      expect(r.kind, CloudCheckKind.noKey);
      expect(r.suggestedModel, CloudProvider.groq.defaultModel);
      expect(log, isEmpty);
    });
  });

  group('model testi (1 token)', () {
    test('Gemini: generateContent, maxOutputTokens 1, 200 = çalışıyor', () async {
      final log = <_Req>[];
      final r = await _service((req) => _json(200, {'candidates': <Object>[]}), log: log)
          .testModel(CloudProvider.gemini, _geminiKey, 'gemini-2.5-flash');
      expect(r.ok, isTrue);
      expect(r.latencyMs, isNotNull);
      expect(log.single.method, 'POST');
      expect(log.single.uri.path, '/v1beta/models/gemini-2.5-flash:generateContent');
      final body = jsonDecode(log.single.body) as Map<String, dynamic>;
      expect((body['generationConfig'] as Map)['maxOutputTokens'], 1);
    });

    test('Groq: max_tokens 1; model adı temizlenerek gönderilir', () async {
      final log = <_Req>[];
      final r = await _service((req) => _json(200, {'choices': <Object>[]}), log: log)
          .testModel(CloudProvider.groq, _groqKey, '  LLaMA-3.3-70b-Versatile \n');
      expect(r.ok, isTrue);
      expect(log.single.uri.path, '/openai/v1/chat/completions');
      final body = jsonDecode(log.single.body) as Map<String, dynamic>;
      expect(body['model'], 'llama-3.3-70b-versatile');
      expect(body['max_tokens'], 1);
      expect(body['stream'], false);
    });

    test('boş model adı varsayılana döner', () async {
      final log = <_Req>[];
      await _service((req) => _json(200, {}), log: log).testModel(CloudProvider.openrouter, _orKey, '  ');
      final body = jsonDecode(log.single.body) as Map<String, dynamic>;
      expect(body['model'], CloudProvider.openrouter.defaultModel);
    });

    test('404 model yok, 401 anahtar, 429 kota, ağ hatası', () async {
      Future<CloudModelTestResult> run(_Handler h) =>
          _service(h).testModel(CloudProvider.groq, _groqKey, 'x-model');

      final r404 = await run((req) => _json(404, {'error': {'message': 'model not found'}}));
      expect(r404.kind, CloudCheckKind.notFound);
      expect(r404.ok, isFalse);

      final r401 = await run((req) => _json(401, {'error': {'message': 'Invalid API Key $_groqKey'}}));
      expect(r401.kind, CloudCheckKind.invalidKey);
      expect(r401.message, isNot(contains(_groqKey)));

      final r429 = await run((req) => _json(429, {'error': {'message': 'limit'}}));
      expect(r429.kind, CloudCheckKind.quota);

      final rNet = await run((req) => throw const SocketException('unreachable'));
      expect(rNet.kind, CloudCheckKind.network);

      final r400 = await run((req) => _json(400, {'error': {'message': 'bad param'}}));
      expect(r400.kind, CloudCheckKind.other);
      expect(r400.message, contains('400'));
    });

    test('anahtar boşsa istek atılmaz', () async {
      final log = <_Req>[];
      final r = await _service((req) => _json(200, {}), log: log).testModel(CloudProvider.groq, '', 'm');
      expect(r.kind, CloudCheckKind.noKey);
      expect(log, isEmpty);
    });
  });

  group('normalizeModelName', () {
    test('boşluk, satır sonu, tırnak ve models/ öneki temizlenir; küçük harfe iner', () {
      expect(normalizeModelName('  Gemini-2.5-Flash \n'), 'gemini-2.5-flash');
      expect(normalizeModelName('gemini 2.5 flash'), 'gemini2.5flash');
      expect(normalizeModelName('"models/Gemini-2.5-Pro"'), 'gemini-2.5-pro');
      expect(normalizeModelName('llama 3.3​'), 'llama3.3');
      expect(normalizeModelName('   '), '');
      expect(normalizeModelName(''), '');
    });

    test('bilinen liste varsa listedeki yazım korunur', () {
      expect(
        normalizeModelName(' META-llama/Llama-X ', known: const ['Meta-Llama/Llama-X', 'baska']),
        'Meta-Llama/Llama-X',
      );
      expect(normalizeModelName('YOK-model', known: const ['baska']), 'yok-model');
    });
  });

  group('SecretMask', () {
    test('kayıtlı anahtar ve bilinen kalıplar maskelenir', () {
      SecretMask.register('ozel-kalip-disi-anahtar-123');
      final text = 'a ozel-kalip-disi-anahtar-123 b $_geminiKey c $_groqKey d $_orKey '
          'Authorization: Bearer abc.def-123 e api_key=hunter2hunter2 f x-goog-api-key: zzzzzzzzzz';
      final out = SecretMask.redact(text);
      for (final secret in [
        'ozel-kalip-disi-anahtar-123',
        _geminiKey,
        _groqKey,
        _orKey,
        'abc.def-123',
        'hunter2hunter2',
        'zzzzzzzzzz',
      ]) {
        expect(out, isNot(contains(secret)), reason: secret);
      }
      expect(out, contains(SecretMask.placeholder));
    });

    test('anahtar içermeyen metin değişmez; display kısaltır', () {
      expect(SecretMask.redact('Model yanıt verdi (412 ms)'), 'Model yanıt verdi (412 ms)');
      expect(SecretMask.redact(''), '');
      expect(SecretMask.display(_geminiKey), 'AIza…GH');
      expect(SecretMask.display('kisa'), SecretMask.placeholder);
      expect(SecretMask.display(_geminiKey), isNot(contains('1234567890')));
    });

    test('CrashGuard günlüğü anahtarı düz metin yazmaz', () async {
      final dir = Directory.systemTemp.createTempSync('kripton_log_');
      try {
        await CrashGuard.init(dir: dir);
        SecretMask.register(_geminiKey);
        CrashGuard.log('Bulut hata', 'Gemini: reddedildi $_geminiKey / Bearer $_groqKey', StackTrace.current);
        final raw = File('${dir.path}/crash.log').readAsStringSync();
        expect(raw, contains('Bulut hata'));
        expect(raw, isNot(contains(_geminiKey)));
        expect(raw, isNot(contains(_groqKey)));
        expect(await CrashGuard.readLog(), isNot(contains(_geminiKey)));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('CloudProviderConfig.toString anahtarı göstermez', () {
      final c = CloudProviderConfig(apiKey: _geminiKey, model: 'm');
      expect(c.toString(), isNot(contains(_geminiKey)));
    });
  });
}
