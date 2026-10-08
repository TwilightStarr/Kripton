// Değişiklik: yeni dosya. Bulut motoru: Gemini -> Groq -> OpenRouter otomatik yedekli LlmEngine +
// Gemini Google Arama ile araştırma. Yeni paket gerekmez (dart:io HttpClient).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../domain/entities.dart';
import 'chatml_parser.dart';
import 'crash_guard.dart';
import 'llm_engine.dart';
import 'storage.dart';

/// Bulut modellerinin sahte "dosya yolu" öneki (örn. `cloud:auto`).
const String kCloudPathPrefix = 'cloud:';

/// Hibrit mod ve araştırma için kullanılan "otomatik bulut" modelinin kimliği.
const String kCloudAutoModelId = 'cloud-auto';

/// Bulut modelinin bağlam penceresi (token). Ücretsiz katman dakikalık token sınırlarına
/// takılmamak için bilinçli olarak mütevazı tutulur.
const int kCloudContextTokens = 24000;

/// Tüm sağlayıcılar kota beklerken tek bir üretimin en çok bekleyeceği süre.
const Duration kCloudMaxWait = Duration(minutes: 25);

/// Tek üretim için en çok sağlayıcı denemesi (sonsuz döngü koruması).
const int kCloudMaxAttempts = 14;

enum CloudProvider { gemini, groq, openrouter }

extension CloudProviderInfo on CloudProvider {
  String get label => switch (this) {
        CloudProvider.gemini => 'Gemini',
        CloudProvider.groq => 'Groq',
        CloudProvider.openrouter => 'OpenRouter',
      };

  /// Varsayılan model adı. Sağlayıcılar model adlarını değiştirebilir; Ayarlar'dan düzenlenebilir.
  String get defaultModel => switch (this) {
        CloudProvider.gemini => 'gemini-2.5-flash',
        CloudProvider.groq => 'llama-3.3-70b-versatile',
        CloudProvider.openrouter => 'meta-llama/llama-3.3-70b-instruct:free',
      };

  /// İstekler arası en kısa süre (ms): ücretsiz katman dakikalık istek sınırını aşmamak için.
  int get minGapMs => switch (this) {
        CloudProvider.gemini => 2500,
        CloudProvider.groq => 3000,
        CloudProvider.openrouter => 3500,
      };

  /// OpenAI uyumlu sağlayıcılarda üretim üst sınırı.
  int get maxOutputCap => switch (this) {
        CloudProvider.gemini => 60000,
        CloudProvider.groq => 8000,
        CloudProvider.openrouter => 8000,
      };

  String get keyHint => switch (this) {
        CloudProvider.gemini => 'aistudio.google.com → Get API key',
        CloudProvider.groq => 'console.groq.com → API Keys',
        CloudProvider.openrouter => 'openrouter.ai → Keys',
      };
}

CloudProvider? _providerById(String id) {
  for (final p in CloudProvider.values) {
    if (p.name == id) return p;
  }
  return null;
}

class CloudProviderConfig {
  CloudProviderConfig({this.apiKey = '', required this.model, this.enabled = true});

  String apiKey;
  String model;
  bool enabled;

  bool get usable => enabled && apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {'key': apiKey, 'model': model, 'enabled': enabled};
}

/// Kalıcı bulut ayarları (API anahtarları uygulamanın özel klasöründe `cloud_config.json` içinde durur).
class CloudConfig {
  CloudConfig._();

  static final CloudConfig instance = CloudConfig._();

  static const String fileName = 'cloud_config.json';

  final Map<CloudProvider, CloudProviderConfig> providers = {
    for (final p in CloudProvider.values) p: CloudProviderConfig(model: p.defaultModel),
  };

  /// Otomatik modda deneme sırası.
  List<CloudProvider> order = [CloudProvider.gemini, CloudProvider.groq, CloudProvider.openrouter];

  /// Otonom modda hedef için Gemini + Google Arama ile araştırma yapılsın mı?
  bool research = true;

  /// Hibrit: önce yerel modeller; takılınca ve en sonda bulut son doğrulaması (otonom mod).
  bool hybrid = true;

  bool get anyUsable => providers.values.any((c) => c.usable);

  Future<void> load([Storage? storage]) async {
    try {
      final raw = await (storage ?? Storage()).loadJson(fileName);
      if (raw is! Map) return;
      final prov = raw['providers'];
      if (prov is Map) {
        for (final p in CloudProvider.values) {
          final m = prov[p.name];
          if (m is! Map) continue;
          final c = providers[p]!;
          c.apiKey = (m['key'] as String?) ?? '';
          final model = (m['model'] as String?)?.trim() ?? '';
          c.model = model.isEmpty ? p.defaultModel : model;
          c.enabled = m['enabled'] != false;
        }
      }
      final ord = raw['order'];
      if (ord is List) {
        final parsed = <CloudProvider>[];
        for (final e in ord) {
          final p = e is String ? _providerById(e) : null;
          if (p != null && !parsed.contains(p)) parsed.add(p);
        }
        for (final p in CloudProvider.values) {
          if (!parsed.contains(p)) parsed.add(p);
        }
        order = parsed;
      }
      research = raw['research'] != false;
      hybrid = raw['hybrid'] != false;
    } catch (_) {
      // Bozuk dosya: varsayılanlarla devam.
    }
  }

  Future<void> save([Storage? storage]) async {
    try {
      await (storage ?? Storage()).saveJson(fileName, {
        'v': 1,
        'providers': {for (final e in providers.entries) e.key.name: e.value.toJson()},
        'order': [for (final p in order) p.name],
        'research': research,
        'hybrid': hybrid,
      });
    } catch (_) {}
    CloudEngine.resetCooldowns(); // anahtar/model değişti: bekleme süreleri sıfırlanır
  }
}

/// Yol bulut modeline mi ait?
bool isCloudPath(String? path) => path != null && path.startsWith(kCloudPathPrefix);

/// Uygulama modeli listesine eklenen bulut "modelleri" (indirme/silme gerektirmez).
List<GgufModel> cloudModels() => const [
      GgufModel(
        id: kCloudAutoModelId,
        name: 'Bulut: Otomatik (Gemini → Groq → OpenRouter)',
        family: 'Bulut',
        parameters: 'API',
        quantization: 'bulut',
        sizeGb: 0,
        ramGb: 0,
        tokensPerSec: 'ağa bağlı',
        quality: 'Kota dolunca sıradaki sağlayıcıya otomatik geçer',
        url: '',
        fileName: 'cloud-auto',
        template: ChatTemplate.chatml,
        localPath: 'cloud:auto',
      ),
      GgufModel(
        id: 'cloud-gemini',
        name: 'Bulut: Yalnızca Gemini',
        family: 'Bulut',
        parameters: 'API',
        quantization: 'bulut',
        sizeGb: 0,
        ramGb: 0,
        tokensPerSec: 'ağa bağlı',
        quality: 'Google AI Studio anahtarı',
        url: '',
        fileName: 'cloud-gemini',
        template: ChatTemplate.chatml,
        localPath: 'cloud:gemini',
      ),
      GgufModel(
        id: 'cloud-groq',
        name: 'Bulut: Yalnızca Groq',
        family: 'Bulut',
        parameters: 'API',
        quantization: 'bulut',
        sizeGb: 0,
        ramGb: 0,
        tokensPerSec: 'ağa bağlı',
        quality: 'Groq anahtarı',
        url: '',
        fileName: 'cloud-groq',
        template: ChatTemplate.chatml,
        localPath: 'cloud:groq',
      ),
      GgufModel(
        id: 'cloud-openrouter',
        name: 'Bulut: Yalnızca OpenRouter',
        family: 'Bulut',
        parameters: 'API',
        quantization: 'bulut',
        sizeGb: 0,
        ramGb: 0,
        tokensPerSec: 'ağa bağlı',
        quality: 'OpenRouter anahtarı',
        url: '',
        fileName: 'cloud-openrouter',
        template: ChatTemplate.chatml,
        localPath: 'cloud:openrouter',
      ),
    ];

/// Sağlayıcı hatası. [cooldownMs] bu sağlayıcının ne kadar süre denenmeyeceğini belirler.
class _CloudError implements Exception {
  _CloudError(this.message, this.cooldownMs, {this.emitted = 0});

  final String message;
  final int cooldownMs;
  final int emitted;

  @override
  String toString() => message;
}

class _CloudRun {
  bool cancelled = false;
  HttpClient? client;

  void cancel() {
    cancelled = true;
    final c = client;
    client = null;
    if (c != null) {
      try {
        c.close(force: true);
      } catch (_) {}
    }
  }
}

/// Bulut API'lerine bağlanan motor. `cloud:auto` -> ayarlardaki sıra; `cloud:gemini|groq|openrouter` -> yalnızca o sağlayıcı.
class CloudEngine implements LlmEngine {
  CloudEngine({CloudConfig? config}) : _config = config ?? CloudConfig.instance;

  final CloudConfig _config;

  /// Sağlayıcı -> bu zamana (ms, epoch) kadar denenmez. Motor örnekleri arasında paylaşılır.
  static final Map<CloudProvider, int> _cool = {};
  static final Map<CloudProvider, int> _nextCallMs = {};

  static void resetCooldowns() {
    _cool.clear();
  }

  String? _loaded;
  _CloudRun? _activeRun;
  int _active = 0;
  Completer<void> _idle = Completer<void>()..complete();

  /// Son başarılı üretimi yapan sağlayıcı (arayüz/günlük için).
  String? lastProviderLabel;

  @override
  String? get loadedPath => _loaded;

  @override
  int? get contextSize => _loaded == null ? null : kCloudContextTokens;

  @override
  int? get batchSize => null;

  @override
  Future<void> ensureLoaded(String path, {int? expectedBytes}) async {
    if (!isCloudPath(path)) {
      throw GenerationFailedException('Geçersiz bulut modeli yolu: $path', code: 'CLOUD_PATH');
    }
    _loaded = path;
  }

  @override
  Future<bool> waitNativeIdle(Duration timeout) async {
    if (_active == 0) return true;
    try {
      await _idle.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  void _enter() {
    if (_active++ == 0) _idle = Completer<void>();
  }

  void _exit() {
    if (--_active <= 0) {
      _active = 0;
      if (!_idle.isCompleted) _idle.complete();
    }
  }

  @override
  Future<void> stop() async {
    _activeRun?.cancel();
  }

  @override
  Future<void> dispose() async {
    _activeRun?.cancel();
    _loaded = null; // yeniden kullanılabilir (RoutingEngine boşaltma sözleşmesi)
  }

  List<CloudProvider> _orderFor(String path) {
    final id = path.substring(kCloudPathPrefix.length);
    final single = _providerById(id);
    if (single != null) return [single];
    return List<CloudProvider>.of(_config.order);
  }

  @override
  Stream<String> generate(String prompt, {int maxTokens = 1536}) {
    final run = _CloudRun();
    late StreamController<String> c;
    c = StreamController<String>(
      onListen: () {
        _enter();
        _activeRun = run;
        unawaited(_drive(run, c, prompt, maxTokens));
      },
      onCancel: () {
        run.cancel();
      },
    );
    return c.stream;
  }

  Future<void> _drive(_CloudRun run, StreamController<String> c, String prompt, int maxTokens) async {
    try {
      final path = _loaded;
      if (path == null) throw StateError('Bulut modeli seçilmedi.');
      final ChatMlParse parsed;
      try {
        parsed = parseChatMl(prompt);
      } on ChatMlFormatException catch (e) {
        throw GenerationFailedException(
          'Bulut için istem ChatML olarak ayrıştırılamadı: ${e.message}',
          code: 'CLOUD_CHATML',
        );
      }
      if (parsed.turns.isEmpty) {
        throw const GenerationFailedException('Bulut isteğinde kullanıcı mesajı yok.', code: 'CLOUD_EMPTY_PROMPT');
      }
      await _withFailover(run, c, parsed, maxTokens, _orderFor(path));
    } catch (e, st) {
      CrashGuard.log('Bulut üretim', e.toString(), st);
      if (!run.cancelled && !c.isClosed) {
        c.addError(
          e is GenerationFailedException
              ? e
              : GenerationFailedException('Bulut üretimi başarısız: $e', code: 'CLOUD_GENERATE'),
          st,
        );
      }
    } finally {
      if (identical(_activeRun, run)) _activeRun = null;
      run.client = null;
      _exit();
      if (!c.isClosed) {
        try {
          await c.close();
        } catch (_) {}
      }
    }
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  Future<void> _sleep(_CloudRun run, int ms) async {
    var left = ms;
    while (left > 0 && !run.cancelled) {
      final step = math.min(left, 1000);
      await Future<void>.delayed(Duration(milliseconds: step));
      left -= step;
    }
  }

  Future<void> _withFailover(
    _CloudRun run,
    StreamController<String> c,
    ChatMlParse p,
    int maxTokens,
    List<CloudProvider> order,
  ) async {
    final startedAt = _nowMs();
    final errors = <String>[];
    var attempts = 0;
    while (true) {
      if (run.cancelled) return;
      final now = _nowMs();
      CloudProvider? pick;
      for (final pr in order) {
        final cfg = _config.providers[pr]!;
        if (!cfg.usable) continue;
        if ((_cool[pr] ?? 0) <= now) {
          pick = pr;
          break;
        }
      }
      if (pick == null) {
        final usable = [for (final pr in order) if (_config.providers[pr]!.usable) pr];
        if (usable.isEmpty) {
          throw const GenerationFailedException(
            'Hiçbir bulut sağlayıcı için API anahtarı girilmemiş. Geliştirme Modu → Bulut ayarları bölümünden anahtar ekle.',
            code: 'CLOUD_NO_KEY',
          );
        }
        var soonest = _cool[usable.first] ?? 0;
        for (final pr in usable) {
          soonest = math.min(soonest, _cool[pr] ?? 0);
        }
        final waitMs = math.max(500, soonest - now);
        if (now - startedAt + waitMs > kCloudMaxWait.inMilliseconds) {
          throw GenerationFailedException(
            'Tüm bulut sağlayıcıların kotası dolu görünüyor (${errors.isEmpty ? 'bilgi yok' : errors.last}). '
            'Daha sonra yeniden dene veya başka bir sağlayıcı anahtarı ekle.',
            code: 'CLOUD_QUOTA',
          );
        }
        CrashGuard.log('Bulut', 'Tüm sağlayıcılar beklemede; ${(waitMs / 1000).ceil()} sn bekleniyor', null);
        await _sleep(run, waitMs);
        continue;
      }
      if (++attempts > kCloudMaxAttempts) {
        throw GenerationFailedException(
          'Bulut üretimi $kCloudMaxAttempts denemede başarısız: ${errors.isEmpty ? 'bilinmeyen hata' : errors.last}',
          code: 'CLOUD_ATTEMPTS',
        );
      }
      try {
        await _call(run, c, pick, p, maxTokens);
        if (run.cancelled) return;
        if (lastProviderLabel != pick.label) {
          CrashGuard.log('Bulut', 'Sağlayıcı: ${pick.label} (${_config.providers[pick]!.model})', null);
        }
        lastProviderLabel = pick.label;
        return;
      } on _CloudError catch (e) {
        if (run.cancelled) return;
        _cool[pick] = _nowMs() + math.max(15000, e.cooldownMs);
        errors.add('${pick.label}: ${e.message}');
        CrashGuard.log('Bulut hata', '${pick.label}: ${e.message}', null);
        if (e.emitted > 0) {
          // Metin kısmen iletildi: başka sağlayıcıyla sürdürmek çıktıyı bozar; üst katman yeniden dener.
          throw GenerationFailedException(
            'Bulut akışı yarıda kesildi (${pick.label}): ${e.message}',
            code: 'CLOUD_MIDSTREAM',
          );
        }
      } on SocketException catch (e) {
        if (run.cancelled) return;
        _cool[pick] = _nowMs() + 30000;
        errors.add('${pick.label}: ağ hatası (${e.message})');
      } on TimeoutException {
        if (run.cancelled) return;
        _cool[pick] = _nowMs() + 30000;
        errors.add('${pick.label}: zaman aşımı');
      } on HandshakeException catch (e) {
        if (run.cancelled) return;
        _cool[pick] = _nowMs() + 60000;
        errors.add('${pick.label}: TLS hatası (${e.message})');
      } on HttpException catch (e) {
        if (run.cancelled) return;
        _cool[pick] = _nowMs() + 30000;
        errors.add('${pick.label}: HTTP hatası (${e.message})');
      }
    }
  }

  /// Sağlayıcı istekleri arasında asgari aralık (ücretsiz katman dakikalık istek sınırı).
  Future<void> _pace(_CloudRun run, CloudProvider pr) async {
    final now = _nowMs();
    final at = _nextCallMs[pr] ?? 0;
    _nextCallMs[pr] = math.max(now, at) + pr.minGapMs;
    if (at > now) await _sleep(run, at - now);
  }

  Future<void> _call(
    _CloudRun run,
    StreamController<String> c,
    CloudProvider pr,
    ChatMlParse p,
    int maxTokens,
  ) async {
    final cfg = _config.providers[pr]!;
    await _pace(run, pr);
    if (run.cancelled) return;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    run.client = client;
    try {
      final req = pr == CloudProvider.gemini
          ? await _geminiRequest(client, cfg, p, maxTokens)
          : await _openAiRequest(client, pr, cfg, p, maxTokens);
      final res = await req.close().timeout(const Duration(seconds: 120));
      if (res.statusCode != 200) {
        final body = await utf8.decoder.bind(res).join().timeout(const Duration(seconds: 20));
        throw _errorFor(pr, res.statusCode, body, res.headers);
      }
      var emitted = 0;
      final lines = res.transform(utf8.decoder).transform(const LineSplitter());
      try {
        await for (final line in lines.timeout(const Duration(seconds: 120))) {
          if (run.cancelled) return;
          final data = _sseData(line);
          if (data == null) continue;
          if (data == '[DONE]') break;
          Object? j;
          try {
            j = jsonDecode(data);
          } catch (_) {
            continue; // bozuk/yarım satır
          }
          if (j is! Map) continue;
          if (j['error'] != null) {
            throw _errorFor(pr, _errCode(j['error']), jsonEncode(j), null, emitted: emitted);
          }
          final text = pr == CloudProvider.gemini ? _geminiText(j) : _openAiText(j);
          if (text.isNotEmpty) {
            emitted += text.length;
            if (!run.cancelled) c.add(text);
          } else if (pr == CloudProvider.gemini) {
            final block = _geminiBlock(j);
            if (block != null) throw _CloudError(block, 20000, emitted: emitted);
          }
        }
      } on TimeoutException {
        throw _CloudError('akış zaman aşımı', 30000, emitted: emitted);
      } on SocketException catch (e) {
        if (run.cancelled) return;
        throw _CloudError('bağlantı koptu (${e.message})', 30000, emitted: emitted);
      } on HttpException catch (e) {
        if (run.cancelled) return;
        throw _CloudError('bağlantı koptu (${e.message})', 30000, emitted: emitted);
      }
      if (emitted == 0) throw _CloudError('boş yanıt', 20000);
    } finally {
      run.client = null;
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  static String? _sseData(String line) {
    if (!line.startsWith('data:')) return null; // yorum (": ...") ve boş satırlar
    final d = line.substring(5).trim();
    return d.isEmpty ? null : d;
  }

  static int _errCode(Object? err) {
    if (err is Map) {
      final c = err['code'];
      if (c is num) return c.toInt();
      if (c is String) return int.tryParse(c) ?? 500;
    }
    return 500;
  }

  Future<HttpClientRequest> _geminiRequest(
    HttpClient client,
    CloudProviderConfig cfg,
    ChatMlParse p,
    int maxTokens,
  ) async {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/${cfg.model.trim()}:streamGenerateContent?alt=sse',
    );
    final body = <String, dynamic>{
      'contents': [
        for (final t in p.turns)
          {
            'role': t.role == ChatMlRole.assistant ? 'model' : 'user',
            'parts': [
              {'text': t.text},
            ],
          },
      ],
      'generationConfig': {
        'maxOutputTokens': math.min(CloudProvider.gemini.maxOutputCap, maxTokens + 4096),
        'temperature': 0.2,
      },
    };
    final sys = p.system;
    if (sys != null && sys.trim().isNotEmpty) {
      body['systemInstruction'] = {
        'parts': [
          {'text': sys},
        ],
      };
    }
    return _post(client, uri, {'x-goog-api-key': cfg.apiKey.trim()}, body);
  }

  Future<HttpClientRequest> _openAiRequest(
    HttpClient client,
    CloudProvider pr,
    CloudProviderConfig cfg,
    ChatMlParse p,
    int maxTokens,
  ) async {
    final uri = Uri.parse(
      pr == CloudProvider.groq
          ? 'https://api.groq.com/openai/v1/chat/completions'
          : 'https://openrouter.ai/api/v1/chat/completions',
    );
    final body = <String, dynamic>{
      'model': cfg.model.trim(),
      'stream': true,
      'temperature': 0.2,
      'max_tokens': math.min(pr.maxOutputCap, maxTokens),
      'messages': [
        for (final m in p.messages) {'role': m.role.name, 'content': m.text},
      ],
    };
    final headers = <String, String>{'Authorization': 'Bearer ${cfg.apiKey.trim()}'};
    if (pr == CloudProvider.openrouter) {
      headers['X-Title'] = 'Kripton';
    }
    return _post(client, uri, headers, body);
  }

  Future<HttpClientRequest> _post(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body,
  ) async {
    final req = await client.postUrl(uri).timeout(const Duration(seconds: 30));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    headers.forEach(req.headers.set);
    final bytes = utf8.encode(jsonEncode(body));
    req.contentLength = bytes.length;
    req.add(bytes);
    return req;
  }

  static String _geminiText(Map j) {
    final cands = j['candidates'];
    if (cands is! List || cands.isEmpty) return '';
    final first = cands.first;
    if (first is! Map) return '';
    final content = first['content'];
    if (content is! Map) return '';
    final parts = content['parts'];
    if (parts is! List) return '';
    final b = StringBuffer();
    for (final part in parts) {
      if (part is! Map) continue;
      if (part['thought'] == true) continue; // düşünce özetleri çıktıya karışmaz
      final t = part['text'];
      if (t is String) b.write(t);
    }
    return b.toString();
  }

  /// Gemini isteği/yanıtı güvenlik nedeniyle engellediyse açıklama; yoksa null.
  static String? _geminiBlock(Map j) {
    final fb = j['promptFeedback'];
    if (fb is Map && fb['blockReason'] != null) return 'istek engellendi (${fb['blockReason']})';
    final cands = j['candidates'];
    if (cands is List && cands.isNotEmpty && cands.first is Map) {
      final fr = (cands.first as Map)['finishReason'];
      if (fr is String && (fr == 'SAFETY' || fr == 'RECITATION' || fr == 'PROHIBITED_CONTENT')) {
        return 'yanıt engellendi ($fr)';
      }
    }
    return null;
  }

  static String _openAiText(Map j) {
    final ch = j['choices'];
    if (ch is! List || ch.isEmpty) return '';
    final first = ch.first;
    if (first is! Map) return '';
    final delta = first['delta'];
    if (delta is! Map) return '';
    final t = delta['content'];
    return t is String ? t : '';
  }

  /// HTTP durum koduna göre sağlayıcıyı ne kadar süre dinlendireceğimizi belirler.
  static _CloudError _errorFor(
    CloudProvider pr,
    int status,
    String body,
    HttpHeaders? headers, {
    int emitted = 0,
  }) {
    var msg = _briefBody(body);
    final lower = body.toLowerCase();
    int cool;
    if (status == 429) {
      final daily = lower.contains('perday') || lower.contains('per day') || lower.contains('daily');
      cool = daily ? 30 * 60 * 1000 : _retryAfterMs(body, headers) ?? 60 * 1000;
      msg = 'kota/sınır (429): $msg';
    } else if (status == 401 || status == 403) {
      cool = 6 * 60 * 60 * 1000;
      msg = 'anahtar reddedildi ($status): $msg';
    } else if (status == 404) {
      cool = 6 * 60 * 60 * 1000;
      msg = 'model/uç nokta bulunamadı (404): model adını kontrol et. $msg';
    } else if (status == 413) {
      cool = 60 * 1000;
      msg = 'istek çok büyük (413): $msg';
    } else if (status == 400) {
      cool = 5 * 60 * 1000;
      msg = 'geçersiz istek (400): $msg';
    } else if (status >= 500) {
      cool = 45 * 1000;
      msg = 'sunucu hatası ($status): $msg';
    } else {
      cool = 60 * 1000;
      msg = 'HTTP $status: $msg';
    }
    return _CloudError(msg, cool, emitted: emitted);
  }

  static int? _retryAfterMs(String body, HttpHeaders? headers) {
    final h = headers?.value('retry-after');
    if (h != null) {
      final s = double.tryParse(h.trim());
      if (s != null) return (s * 1000).ceil().clamp(1000, 15 * 60 * 1000);
    }
    // Gemini: "retryDelay": "34s"
    final m = RegExp(r'"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"').firstMatch(body);
    if (m != null) {
      final s = double.tryParse(m.group(1)!);
      if (s != null) return (s * 1000).ceil().clamp(1000, 15 * 60 * 1000);
    }
    // Groq: "Please try again in 7.5s" / "in 1m3.2s"
    final g = RegExp(r'try again in (?:(\d+)m)?(\d+(?:\.\d+)?)s').firstMatch(body);
    if (g != null) {
      final mins = int.tryParse(g.group(1) ?? '0') ?? 0;
      final s = double.tryParse(g.group(2)!) ?? 0;
      return ((mins * 60 + s) * 1000).ceil().clamp(1000, 15 * 60 * 1000);
    }
    return null;
  }

  static String _briefBody(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is Map) {
        final m = (j['error'] as Map)['message'];
        if (m is String && m.isNotEmpty) return m.length > 220 ? '${m.substring(0, 220)}…' : m;
      }
    } catch (_) {}
    final t = body.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > 220 ? '${t.substring(0, 220)}…' : t;
  }
}

/// Otonom mod için araştırma: Gemini + Google Arama (yalnızca Gemini anahtarı varsa).
/// Hiçbir koşulda istisna fırlatmaz; başarısızlıkta null döner ve oturum araştırmasız sürer.
Future<String?> cloudResearch(String goal, {String projectHint = ''}) async {
  final cfg = CloudConfig.instance;
  if (!cfg.research) return null;
  final g = cfg.providers[CloudProvider.gemini]!;
  if (!g.usable) return null;
  if ((CloudEngine._cool[CloudProvider.gemini] ?? 0) > DateTime.now().millisecondsSinceEpoch) return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/${g.model.trim()}:generateContent',
    );
    final prompt = 'Bir Flutter/Dart projesini şu hedef doğrultusunda geliştireceğiz:\n$goal\n\n'
        '${projectHint.isEmpty ? '' : 'Proje bağımlılıkları: $projectHint\n\n'}'
        'Web\'de ARAŞTIR ve Türkçe, madde madde, en çok 1800 karakterlik kısa bir not yaz: '
        '(1) bu hedef için güncel en iyi uygulama yaklaşımı, (2) kullanılabilecek güncel Flutter/Dart '
        'paketleri ve sık yapılan hatalar, (3) kaçınılması gereken kullanımdan kalkmış API\'ler. '
        'Kod yazma; yalnızca doğrulanmış bilgi ver, emin olmadığını belirt.';
    final body = {
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
          ],
        },
      ],
      'tools': [
        {'google_search': <String, dynamic>{}},
      ],
      'generationConfig': {'maxOutputTokens': 4096, 'temperature': 0.2},
    };
    final req = await client.postUrl(uri).timeout(const Duration(seconds: 30));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    req.headers.set('x-goog-api-key', g.apiKey.trim());
    final bytes = utf8.encode(jsonEncode(body));
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close().timeout(const Duration(seconds: 120));
    final txt = await utf8.decoder.bind(res).join().timeout(const Duration(seconds: 120));
    if (res.statusCode != 200) {
      final e = CloudEngine._errorFor(CloudProvider.gemini, res.statusCode, txt, res.headers);
      CloudEngine._cool[CloudProvider.gemini] = DateTime.now().millisecondsSinceEpoch + e.cooldownMs;
      CrashGuard.log('Bulut araştırma', e.message, null);
      return null;
    }
    final j = jsonDecode(txt);
    if (j is! Map) return null;
    final text = CloudEngine._geminiText(j).trim();
    if (text.isEmpty) return null;
    final sources = <String>[];
    final cands = j['candidates'];
    if (cands is List && cands.isNotEmpty && cands.first is Map) {
      final gm = (cands.first as Map)['groundingMetadata'];
      if (gm is Map && gm['groundingChunks'] is List) {
        for (final ch in gm['groundingChunks'] as List) {
          if (ch is Map && ch['web'] is Map) {
            final title = (ch['web'] as Map)['title'];
            if (title is String && title.isNotEmpty && !sources.contains(title) && sources.length < 5) {
              sources.add(title);
            }
          }
        }
      }
    }
    final out = StringBuffer(text.length > 1600 ? text.substring(0, 1600) : text);
    if (sources.isNotEmpty) out.write('\nKaynaklar: ${sources.join(', ')}');
    return out.toString();
  } catch (e, st) {
    CrashGuard.log('Bulut araştırma', e.toString(), st);
    return null;
  } finally {
    try {
      client.close(force: true);
    } catch (_) {}
  }
}
