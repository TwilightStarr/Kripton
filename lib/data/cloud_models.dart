// Değişiklik: yeni dosya. Bulut sağlayıcıları için anahtar sınama, model listesi alma ve
// 1 token'lık model testi. Yalnızca dart:io HttpClient kullanır; istemci enjekte edilebilir (testler).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cloud_engine.dart';
import 'secret_mask.dart';

/// Anahtar sınama / model listesi / model testi isteklerinin zaman aşımı.
const Duration kCloudCheckTimeout = Duration(seconds: 20);

/// [CloudModelService] sonuçlarındaki hata türleri.
enum CloudCheckKind {
  ok,
  noKey,
  invalidKey, // 401 / 403 (Gemini'de 400 API_KEY_INVALID)
  quota, // 429
  network, // bağlantı yok / DNS / TLS
  timeout, // 20 sn içinde yanıt yok
  notFound, // 404: model/uç nokta yok
  emptyList, // anahtar geçerli ama sohbet modeli kalmadı
  other,
}

/// Seçim listesindeki tek model.
class CloudModelInfo {
  const CloudModelInfo(this.id, {this.label = '', this.contextTokens});

  final String id;
  final String label;
  final int? contextTokens;
}

/// Model listesi alma sonucu. Başarısızsa [suggestedModel] sağlayıcının varsayılan modelidir.
class CloudModelsResult {
  const CloudModelsResult({
    required this.kind,
    required this.message,
    this.models = const [],
    this.filteredOut = 0,
    this.suggestedModel,
    this.statusCode,
  });

  final CloudCheckKind kind;

  /// Kullanıcıya gösterilecek Türkçe açıklama (anahtar içermez).
  final String message;
  final List<CloudModelInfo> models;

  /// Sohbet dışı (embedding, ses, görsel vb.) olduğu için elenen model sayısı.
  final int filteredOut;
  final String? suggestedModel;
  final int? statusCode;

  bool get ok => kind == CloudCheckKind.ok;
}

/// 1 token'lık model testi sonucu.
class CloudModelTestResult {
  const CloudModelTestResult({
    required this.kind,
    required this.message,
    this.statusCode,
    this.latencyMs,
    this.retryAfter,
    this.dailyQuota = false,
  });

  final CloudCheckKind kind;
  final String message;
  final int? statusCode;
  final int? latencyMs;

  /// Görev 5: sunucunun bildirdiği bekleme (Retry-After / retryDelay / "try again in"); yoksa null.
  final Duration? retryAfter;

  /// Görev 5: 429 yanıtı günlük kotanın bittiğini gösteriyorsa true.
  final bool dailyQuota;

  bool get ok => kind == CloudCheckKind.ok;
}

/// Sohbet/metin üretmeyen modelleri (embedding, ses, görsel, video, yeniden sıralama, moderasyon) ayıklar.
final RegExp _nonChatId = RegExp(
  r'embed|tts|whisper|transcri|speech|audio|image|video|diffusion|dall-e|sdxl|rerank|moderat|guard|'
  r'lyria|orpheus|playai|(^|[/\-_.:])(veo|aqa|flux)($|[/\-_.:])',
  caseSensitive: false,
);

bool _looksNonChat(String id) => _nonChatId.hasMatch(id);

class _CheckFailure implements Exception {
  _CheckFailure(this.kind, this.message, {this.statusCode});

  final CloudCheckKind kind;
  final String message;
  final int? statusCode;
}

class _Reply {
  const _Reply(this.status, this.body, {this.retryAfterHeader});

  final int status;
  final String body;
  final String? retryAfterHeader;
}

/// Görev 5: 429/5xx yanıtındaki bekleme süresini çıkarır: `Retry-After` başlığı (saniye), Gemini
/// `"retryDelay": "34s"`, Groq `try again in 1m3.2s`. Bulunamazsa null; sonuç 1 sn..15 dk aralığına çekilir.
Duration? parseCloudRetryAfter(String body, {String? header}) {
  const lo = 1000;
  const hi = 15 * 60 * 1000;
  Duration? ms(double seconds) => Duration(milliseconds: (seconds * 1000).ceil().clamp(lo, hi));
  final h = header == null ? null : double.tryParse(header.trim());
  if (h != null && h >= 0) return ms(h);
  final m = RegExp(r'"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"').firstMatch(body);
  if (m != null) {
    final s = double.tryParse(m.group(1)!);
    if (s != null) return ms(s);
  }
  final g = RegExp(r'try again in (?:(\d+)m)?(\d+(?:\.\d+)?)s', caseSensitive: false).firstMatch(body);
  if (g != null) {
    final mins = int.tryParse(g.group(1) ?? '0') ?? 0;
    final s = double.tryParse(g.group(2)!) ?? 0;
    return ms(mins * 60 + s);
  }
  return null;
}

/// Görev 5: 429 gövdesi günlük kota bitişini mi söylüyor (Gemini `PerDay`, OpenRouter `free-models-per-day`,
/// Groq `per day`/`daily`)? Gemini'de `limit: 0` ücretsiz katmanda hiç kota olmadığı anlamına gelir.
bool isDailyQuotaBody(String body) {
  final lower = body.toLowerCase();
  return RegExp(r'per[\s_-]?day|daily|limit:\s*0\b').hasMatch(lower);
}

typedef CloudHttpClientFactory = HttpClient Function();

/// Gemini / Groq / OpenRouter için anahtar sınama, model listesi ve model testi.
/// Hiçbir yöntem istisna fırlatmaz; sonuç nesnesi hata türünü taşır. Anahtar hiçbir mesajda yer almaz.
class CloudModelService {
  CloudModelService({
    CloudHttpClientFactory? clientFactory,
    this.timeout = kCloudCheckTimeout,
    Map<CloudProvider, String>? baseUrls,
  })  : _factory = clientFactory ?? HttpClient.new,
        _bases = {...defaultBaseUrls, ...?baseUrls};

  static const Map<CloudProvider, String> defaultBaseUrls = {
    CloudProvider.gemini: 'https://generativelanguage.googleapis.com/v1beta',
    CloudProvider.groq: 'https://api.groq.com/openai/v1',
    CloudProvider.openrouter: 'https://openrouter.ai/api/v1',
  };

  final CloudHttpClientFactory _factory;
  final Duration timeout;
  final Map<CloudProvider, String> _bases;

  // ---------------------------------------------------------------- liste

  /// Anahtarı sınar ve sohbet destekleyen modelleri getirir.
  Future<CloudModelsResult> fetchModels(CloudProvider p, String apiKey) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      return _modelsFailure(p, CloudCheckKind.noKey, 'Önce ${p.label} API anahtarını gir.');
    }
    SecretMask.register(key);
    try {
      if (p == CloudProvider.openrouter) await _validateOpenRouterKey(key);
      final raw = <Object?>[];
      if (p == CloudProvider.gemini) {
        String? token;
        for (var page = 0; page < 5; page++) {
          final q = <String, String>{'pageSize': '1000', if (token != null) 'pageToken': token};
          final uri = Uri.parse('${_bases[p]}/models').replace(queryParameters: q);
          final j = _decode(await _ok(p, await _send('GET', uri, _headers(p, key))));
          final list = j is Map ? j['models'] : null;
          if (list is List) raw.addAll(list);
          final next = j is Map ? j['nextPageToken'] : null;
          if (next is String && next.isNotEmpty) {
            token = next;
          } else {
            break;
          }
        }
      } else {
        final uri = Uri.parse('${_bases[p]}/models');
        final j = _decode(await _ok(p, await _send('GET', uri, _headers(p, key))));
        final list = j is Map ? j['data'] : null;
        if (list is List) raw.addAll(list);
      }
      final parsed = parseModels(p, raw);
      if (parsed.models.isEmpty) {
        return _modelsFailure(
          p,
          CloudCheckKind.emptyList,
          '${p.label} anahtarı geçerli ama sohbet destekleyen model listesi boş geldi.',
          filteredOut: parsed.filteredOut,
        );
      }
      return CloudModelsResult(
        kind: CloudCheckKind.ok,
        message: 'Anahtar geçerli; ${parsed.models.length} sohbet modeli bulundu.',
        models: parsed.models,
        filteredOut: parsed.filteredOut,
      );
    } catch (e) {
      final f = _asFailure(p, e);
      return _modelsFailure(p, f.kind, f.message, statusCode: f.statusCode);
    }
  }

  /// OpenRouter `/models` anahtarsız da çalışır; anahtarı gerçekten sınamak için `/key` çağrılır.
  /// 404 (uç nokta yok) gibi belirsiz durumlar yok sayılır; yalnızca 401/403/429 kesin sonuçtur.
  Future<void> _validateOpenRouterKey(String key) async {
    const p = CloudProvider.openrouter;
    final r = await _send('GET', Uri.parse('${_bases[p]}/key'), _headers(p, key));
    if (r.status == 401 || r.status == 403 || r.status == 429) {
      throw _failureFor(p, r.status, r.body);
    }
  }

  CloudModelsResult _modelsFailure(
    CloudProvider p,
    CloudCheckKind kind,
    String message, {
    int filteredOut = 0,
    int? statusCode,
  }) {
    return CloudModelsResult(
      kind: kind,
      message: message,
      filteredOut: filteredOut,
      suggestedModel: p.defaultModel,
      statusCode: statusCode,
    );
  }

  /// Ham sağlayıcı yanıtındaki model girdilerini ayrıştırır, sohbet dışı olanları eler,
  /// yinelenenleri atar ve alfabetik sıralar.
  static ({List<CloudModelInfo> models, int filteredOut}) parseModels(CloudProvider p, List<Object?> raw) {
    final seen = <String>{};
    final out = <CloudModelInfo>[];
    var filtered = 0;
    for (final e in raw) {
      if (e is! Map) continue;
      final CloudModelInfo? info;
      switch (p) {
        case CloudProvider.gemini:
          info = _parseGemini(e);
        case CloudProvider.groq:
          info = _parseGroq(e);
        case CloudProvider.openrouter:
          info = _parseOpenRouter(e);
      }
      if (info == null) {
        filtered++;
        continue;
      }
      if (seen.add(info.id)) out.add(info);
    }
    out.sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    return (models: out, filteredOut: filtered);
  }

  static CloudModelInfo? _parseGemini(Map m) {
    final name = m['name'];
    if (name is! String || name.isEmpty) return null;
    final id = name.startsWith('models/') ? name.substring(7) : name;
    final methods = m['supportedGenerationMethods'];
    if (methods is List && methods.isNotEmpty) {
      final chat = methods.contains('generateContent') || methods.contains('streamGenerateContent');
      if (!chat) return null;
    }
    if (_looksNonChat(id)) return null;
    final dn = m['displayName'];
    final ctx = m['inputTokenLimit'];
    return CloudModelInfo(id, label: dn is String ? dn : '', contextTokens: ctx is num ? ctx.toInt() : null);
  }

  static CloudModelInfo? _parseGroq(Map m) {
    final id = m['id'];
    if (id is! String || id.isEmpty) return null;
    if (m['active'] == false) return null;
    if (_looksNonChat(id)) return null;
    final ctx = m['context_window'];
    return CloudModelInfo(id, contextTokens: ctx is num ? ctx.toInt() : null);
  }

  static CloudModelInfo? _parseOpenRouter(Map m) {
    final id = m['id'];
    if (id is! String || id.isEmpty) return null;
    if (_looksNonChat(id)) return null;
    final arch = m['architecture'];
    if (arch is Map) {
      final outs = arch['output_modalities'];
      if (outs is List && outs.isNotEmpty) {
        final text = outs.contains('text');
        final other = outs.any((o) => o == 'image' || o == 'audio' || o == 'video' || o == 'embeddings');
        if (!text || other) return null;
      } else {
        final modality = arch['modality'];
        if (modality is String && modality.contains('->')) {
          final output = modality.split('->').last;
          if (!output.contains('text') || output.contains('image') || output.contains('audio')) return null;
        }
      }
    }
    final name = m['name'];
    final ctx = m['context_length'];
    return CloudModelInfo(id, label: name is String ? name : '', contextTokens: ctx is num ? ctx.toInt() : null);
  }

  // ---------------------------------------------------------------- test

  /// Seçilen modele 1 token'lık gerçek bir istek atar. 200 yanıtı = model çalışıyor.
  Future<CloudModelTestResult> testModel(CloudProvider p, String apiKey, String model) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      return CloudModelTestResult(
        kind: CloudCheckKind.noKey,
        message: 'Önce ${p.label} API anahtarını gir.',
      );
    }
    SecretMask.register(key);
    var name = normalizeModelName(model);
    if (name.isEmpty) name = p.defaultModel;
    final watch = Stopwatch()..start();
    try {
      final Uri uri;
      final Map<String, dynamic> body;
      if (p == CloudProvider.gemini) {
        uri = Uri.parse('${_bases[p]}/models/$name:generateContent');
        body = {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': 'ping'},
              ],
            },
          ],
          'generationConfig': {'maxOutputTokens': 1, 'temperature': 0},
        };
      } else {
        uri = Uri.parse('${_bases[p]}/chat/completions');
        body = {
          'model': name,
          'max_tokens': 1,
          'temperature': 0,
          'stream': false,
          'messages': [
            {'role': 'user', 'content': 'ping'},
          ],
        };
      }
      final r = await _send('POST', uri, _headers(p, key), body: body);
      if (r.status != 200) {
        final f = _failureFor(p, r.status, r.body, forModel: true);
        final quota = f.kind == CloudCheckKind.quota;
        return CloudModelTestResult(
          kind: f.kind,
          message: f.message,
          statusCode: r.status,
          retryAfter: (quota || r.status >= 500) ? parseCloudRetryAfter(r.body, header: r.retryAfterHeader) : null,
          dailyQuota: quota && isDailyQuotaBody(r.body),
        );
      }
      watch.stop();
      return CloudModelTestResult(
        kind: CloudCheckKind.ok,
        message: 'Model yanıt verdi.',
        statusCode: 200,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (e) {
      final f = _asFailure(p, e);
      return CloudModelTestResult(kind: f.kind, message: f.message, statusCode: f.statusCode);
    }
  }

  // ---------------------------------------------------------------- HTTP

  Map<String, String> _headers(CloudProvider p, String key) {
    if (p == CloudProvider.gemini) return {'x-goog-api-key': key};
    return {
      'Authorization': 'Bearer $key',
      if (p == CloudProvider.openrouter) 'X-Title': 'Kripton',
    };
  }

  Future<_Reply> _send(String method, Uri uri, Map<String, String> headers, {Map<String, dynamic>? body}) async {
    final client = _factory();
    try {
      client.connectionTimeout = timeout;
      return await () async {
        final req = method == 'GET' ? await client.getUrl(uri) : await client.postUrl(uri);
        headers.forEach(req.headers.set);
        if (body != null) {
          final bytes = utf8.encode(jsonEncode(body));
          req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
          req.contentLength = bytes.length;
          req.add(bytes);
        }
        final res = await req.close();
        final text = await utf8.decoder.bind(res).join();
        String? retryHeader;
        try {
          retryHeader = res.headers.value('retry-after');
        } catch (_) {
          // Başlıklar okunamıyorsa (sahte istemci vb.) gövdedeki ipuçları kullanılır.
        }
        return _Reply(res.statusCode, text, retryAfterHeader: retryHeader);
      }()
          .timeout(timeout);
    } finally {
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  Future<_Reply> _ok(CloudProvider p, _Reply r) async {
    if (r.status != 200) throw _failureFor(p, r.status, r.body);
    return r;
  }

  Object? _decode(_Reply r) {
    try {
      return jsonDecode(r.body);
    } on FormatException {
      throw _CheckFailure(CloudCheckKind.other, 'Sağlayıcıdan beklenmeyen (JSON olmayan) yanıt geldi.');
    }
  }

  _CheckFailure _asFailure(CloudProvider p, Object e) {
    if (e is _CheckFailure) return e;
    if (e is TimeoutException) {
      return _CheckFailure(
        CloudCheckKind.timeout,
        '${p.label} ${timeout.inSeconds} sn içinde yanıt vermedi. Bağlantını kontrol edip yeniden dene.',
      );
    }
    if (e is SocketException || e is HandshakeException || e is HttpException || e is OSError) {
      return _CheckFailure(
        CloudCheckKind.network,
        'Ağ bağlantısı yok ya da ${p.label} sunucusuna ulaşılamadı. İnternet bağlantını kontrol et.',
      );
    }
    return _CheckFailure(CloudCheckKind.other, 'Beklenmeyen hata (${e.runtimeType}).');
  }

  _CheckFailure _failureFor(CloudProvider p, int status, String body, {bool forModel = false}) {
    final brief = _brief(body);
    final tail = brief.isEmpty ? '' : ' Ayrıntı: $brief';
    final lower = body.toLowerCase();
    // Gemini geçersiz anahtarda 400 + API_KEY_INVALID döner.
    final badKey = status == 400 && (lower.contains('api_key_invalid') || lower.contains('api key not valid'));
    if (status == 401 || status == 403 || badKey) {
      return _CheckFailure(
        CloudCheckKind.invalidKey,
        '${p.label} API anahtarı geçersiz ya da yetkisiz (HTTP $status). Anahtarı kontrol et.$tail',
        statusCode: status,
      );
    }
    if (status == 429) {
      return _CheckFailure(
        CloudCheckKind.quota,
        '${p.label} kotası ya da istek sınırı doldu (429). Bir süre bekleyip yeniden dene.$tail',
        statusCode: status,
      );
    }
    if (status == 404) {
      return _CheckFailure(
        CloudCheckKind.notFound,
        forModel
            ? 'Model ${p.label} üzerinde bulunamadı (404). Model adını listeden seç.$tail'
            : '${p.label} model listesi uç noktası bulunamadı (404).$tail',
        statusCode: status,
      );
    }
    if (status >= 500) {
      return _CheckFailure(
        CloudCheckKind.other,
        '${p.label} sunucusu hata verdi (HTTP $status). Biraz sonra yeniden dene.$tail',
        statusCode: status,
      );
    }
    return _CheckFailure(
      CloudCheckKind.other,
      forModel
          ? '${p.label} bu model isteğini reddetti (HTTP $status).$tail'
          : '${p.label} beklenmeyen yanıt verdi (HTTP $status).$tail',
      statusCode: status,
    );
  }

  /// Hata gövdesinden kısa, anahtarsız bir özet çıkarır.
  static String _brief(String body) {
    String text;
    try {
      final j = jsonDecode(body);
      final err = j is Map ? j['error'] : null;
      final m = err is Map ? err['message'] : (err is String ? err : null);
      text = m is String && m.isNotEmpty ? m : body;
    } catch (_) {
      text = body;
    }
    text = SecretMask.redact(text.trim().replaceAll(RegExp(r'\s+'), ' '));
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
}
