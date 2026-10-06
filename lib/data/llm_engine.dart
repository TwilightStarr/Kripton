import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_llama/flutter_llama.dart';

import '../application/token_budget.dart';
import '../domain/entities.dart';
import '../domain/inference_settings.dart';
import 'crash_guard.dart';
import 'gguf_meta.dart';
import 'native_services.dart';

/// Model dosyası bozuk/eksik/yarım; çağıran registry kaydını silmelidir.
class ModelFileException implements Exception {
  const ModelFileException(this.path, this.message);
  final String path;
  final String message;
  @override
  String toString() => 'Model dosyası geçersiz: $message ($path)';
}

class InsufficientMemoryException implements Exception {
  const InsufficientMemoryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Üretim, kurtarma adımlarına (akışsız deneme, profil düşürme) rağmen başarısız oldu.
/// [message] kullanıcıya gösterilebilir, eyleme dönüktür.
class GenerationFailedException implements Exception {
  const GenerationFailedException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

/// Düşürülmüş profille yeniden denendikten sonra da başarısız olunca gösterilen mesaj.
const String kGenerationFailedRetriedMessage =
    'Üretim başarısız. Daha küçük bağlamla yeniden denendi; sürerse daha küçük model seç.';

/// Yeniden deneme hiç yapılamadıysa (daha düşük profil yok / prompt sığmıyor / yeniden yükleme başarısız).
const String kGenerationFailedNoRetryMessage =
    'Üretim başarısız. Bağlam daha fazla küçültülemedi; daha küçük model seç.';

/// Yüklemeden önce: dosya var, .part değil, boyut beklenenle eşit, ilk 4 bayt "GGUF".
Future<void> validateModelFile(String path, {int? expectedBytes}) async {
  if (path.endsWith('.part'))
    throw ModelFileException(path, 'yarım indirme (.part)');
  final f = File(path);
  if (!await f.exists()) throw ModelFileException(path, 'dosya yok');
  final len = await f.length();
  if (expectedBytes != null && len != expectedBytes) {
    throw ModelFileException(path, 'boyut uyuşmuyor: $len != $expectedBytes');
  }
  final raf = await f.open();
  try {
    final head = await raf.read(4);
    if (head.length != 4 || String.fromCharCodes(head) != 'GGUF') {
      throw ModelFileException(path, 'GGUF başlığı yok');
    }
  } finally {
    await raf.close();
  }
}

int? parseMemAvailableBytes(String meminfo) {
  final m = RegExp(
    r'^MemAvailable:\s+(\d+)\s*kB',
    multiLine: true,
  ).firstMatch(meminfo);
  return m == null ? null : int.parse(m.group(1)!) * 1024;
}

enum MemoryStatus { green, yellow, red }

class MemoryCandidate {
  const MemoryCandidate({
    required this.ctx,
    required this.batch,
    required this.needBytes,
    required this.status,
  });

  final int ctx;
  final int batch;
  final int needBytes;
  final MemoryStatus status;
}

class MemoryPlan {
  const MemoryPlan({
    required this.candidates,
    required this.selectedIndex,
    required this.availableBytes,
    required this.totalBytes,
  });

  final List<MemoryCandidate> candidates;
  final int selectedIndex;
  final int availableBytes;
  final int totalBytes;

  MemoryCandidate get selected => candidates[selectedIndex];
  bool get isRed => selected.status == MemoryStatus.red;
}

/// Memory needed by every allowed (context, batch) profile, in preferred order.
MemoryPlan memoryPlan({
  required int availableBytes,
  required int totalBytes,
  required int modelBytes,
  required int kvPerToken,
  int? nFf,
}) {
  const gb3 = 3 * 1024 * 1024 * 1024;
  final pairs = <(int, int)>[];
  if (modelBytes <= gb3) {
    pairs.addAll(const [(4096, 2048), (4096, 1024), (4096, 512)]);
  }
  pairs.addAll(const [
    (4096, 1024),
    (4096, 512),
    (3072, 512),
    (2048, 512),
    (2048, 256),
    (1536, 256),
    (1024, 128),
  ]);
  final seen = <(int, int)>{};
  final candidates = <MemoryCandidate>[];
  for (final (ctx, batch) in pairs) {
    if (batch > ctx || !seen.add((ctx, batch))) continue;
    final computeBytes = nFf == null ? batch * 16 * 1024 : (batch * nFf * 6);
    final need =
        modelBytes + ctx * kvPerToken + computeBytes + 384 * 1024 * 1024;
    final status = need <= availableBytes * 0.92
        ? MemoryStatus.green
        : need <= totalBytes * 0.62
            ? MemoryStatus.yellow
            : MemoryStatus.red;
    candidates.add(
      MemoryCandidate(ctx: ctx, batch: batch, needBytes: need, status: status),
    );
  }

  final firstFit = candidates.indexWhere(
    (candidate) => candidate.status != MemoryStatus.red,
  );
  return MemoryPlan(
    candidates: List.unmodifiable(candidates),
    selectedIndex: firstFit < 0 ? candidates.length - 1 : firstFit,
    availableBytes: availableBytes,
    totalBytes: totalBytes,
  );
}

/// Legacy conservative estimate used only if a model has no readable GGUF metadata.
int fallbackKvBytesPerToken(int modelBytes) {
  const mb = 1024 * 1024;
  if (modelBytes <= 2048 * mb) return 128 * 1024;
  if (modelBytes <= 4096 * mb) return 256 * 1024;
  if (modelBytes <= 6144 * mb) return 384 * 1024;
  return 512 * 1024;
}

/// Kullanıcı ayarı: iş parçacığı sayısı. 0 = Otomatik (4/6/8 dışı değerler yok sayılır).
/// UI sonraki adımda buraya yazar; Otomatik => kAutoThreads().
class LlamaTuning {
  static int threadsOverride = 0;

  /// Dimensity 9300+ (4xX4 + 4xA720): decode bellek bant genişliğine bağlı, 6 iş parçacığı
  /// genelde yeterli; 8 hepsini (A720 dahil) kullanır. Otomatik = 6 (8 çekirdekli cihazda), diğerlerinde n-2.
  static int resolveThreads(int processors) {
    final o = threadsOverride;
    if (o == 4 || o == 6 || o == 8) return o < processors ? o : processors;
    return processors >= 8 ? 6 : (processors - 2).clamp(2, 6);
  }
}

/// Uygulamanın gördüğü motor arayüzü. WorkflowRunner yalnızca bunu bilir;
/// testlerde sahte (fake) uygulama verilir.
abstract class LlmEngine {
  String? get loadedPath;

  Future<void> ensureLoaded(String path, {int? expectedBytes});

  Stream<String> generate(String prompt, {int maxTokens = 1536});

  Future<void> stop();

  Future<void> dispose();

  /// Native üretim bitene dek bekler; zaman aşımında false (yeni üretim başlatılmamalı).
  Future<bool> waitNativeIdle(Duration timeout);

  /// Yüklü modelin bağlam penceresi (bilinmiyorsa null).
  int? get contextSize;

  /// Yüklü modelin n_batch değeri (model yüklü değilse / bilinmiyorsa null). Eklenti prompt'u
  /// tek llama_decode ile işlediğinden prompt token sayısı bu değeri asla aşmamalıdır.
  int? get batchSize;
}

/// flutter_llama üzerindeki ince katman. LlamaEngine'deki geri-düşme (fallback)
/// mantığı bu arayüz sayesinde eklenti olmadan test edilebilir.
abstract class LlamaBackend {
  Future<bool> load(String path);

  Future<void> unload();

  /// [unload]'dan sonra aynı modeli, mevcut yükleme profilinin bir seviye altıyla ([downgradeProfile])
  /// yeniden yükler. Daha düşük seviye yoksa ya da yükleme başarısızsa false.
  Future<bool> loadDowngraded(String path);

  /// Native EventChannel üzerinden token akışı.
  Stream<String> stream(String prompt, int maxTokens);

  /// Akışsız (bloklayan) üretim.
  Future<String> complete(String prompt, int maxTokens);

  Future<void> stop();

  /// Bekleyen native üretim çağrısı kalmadıysa true; timeout'ta false.
  Future<bool> waitIdle(Duration timeout);

  int? get contextSize;

  /// Yüklemede kullanılan n_batch (yüklenmeden önce null).
  int? get batchSize;

  Future<bool> get underMemoryPressure async => false;

  Stream<int> get trimEvents => const Stream<int>.empty();
}

/// Yükleme profili. Art arda çökmede (crashStreak) daha küçük bağlam/batch/iş parçacığı.
class LoadProfile {
  const LoadProfile({
    required this.ctx,
    required this.batch,
    required this.threads,
    required this.level,
  });
  final int ctx;
  final int batch;
  final int threads;
  final int level;
}

LoadProfile chooseLoadProfile({
  required MemoryPlan plan,
  required int streak,
  required int threads,
}) {
  final index = math
      .min(plan.selectedIndex + math.max(0, streak), plan.candidates.length - 1)
      .toInt();
  return _profileAt(plan, index, threads);
}

LoadProfile _profileAt(MemoryPlan plan, int index, int threads) {
  final candidate = plan.candidates[index];
  final profileThreads =
      index == 0 ? threads : (index == 1 ? math.min(threads, 4) : 2);
  return LoadProfile(
    ctx: candidate.ctx,
    batch: candidate.batch,
    threads: profileThreads,
    level: index,
  );
}

/// Return the next smaller memory-plan candidate, including after an LMK/crash.
LoadProfile? downgradeProfile(
  LoadProfile current, {
  required MemoryPlan plan,
  required int threads,
}) {
  final nextIndex = current.level + 1;
  if (nextIndex >= plan.candidates.length) return null;
  return _profileAt(plan, nextIndex, threads);
}

/// Motor bir şablon bilmez (generate yalnızca hazır prompt alır); token tahmininde en muhafazakâr
/// (en düşük karakter/token) şablon kullanılır => tahmin asla az çıkmaz.
const ChatTemplate kEngineEstimateTemplate = ChatTemplate.phi3;

/// Prompt'u tahmini [maxTokens] token'a sığdırır: baş (%30) + uç (%70) korunur, orta çıkarılır
/// (başta sistem/şablon açılışı, sonda kullanıcı isteği ve asistan etiketi kalır).
/// Sığdıramazsa (çok küçük sınır) son denemeyi döndürür; çağıran yine de tahmini denetlemelidir.
String fitPromptToTokens(
  String prompt,
  int maxTokens, {
  ChatTemplate template = kEngineEstimateTemplate,
}) {
  if (estimateTokens(prompt, template) <= maxTokens) return prompt;
  const marker = '\n[...]\n';
  var p = prompt;
  for (var i = 0; i < 6 && estimateTokens(p, template) > maxTokens; i++) {
    final allowed =
        (maxTokens * charsPerToken(template, p) * math.pow(0.9, i)).floor() -
            marker.length;
    if (allowed < 40) return p;
    final head = (allowed * 0.3).floor();
    final tail = allowed - head;
    if (head + tail + marker.length >= prompt.length) continue;
    p = prompt.substring(0, head) +
        marker +
        prompt.substring(prompt.length - tail);
  }
  return p;
}

/// true: her yüklemeden sonra kısa + orta (en çok ~batch/2 token) prompt duman testi çalışır.
/// Tanı bitince false yapılabilir (yükleme süresini uzatır).
const bool kLoadProbes = true;

/// Motor ölçümleri (UI butonu sonraki adımda `EngineMetrics.last*` okur). Hepsi CrashGuard.log'a da yazılır.
/// Not: token sayısı = native akıştan gelen olay sayısı (1 olay ≈ 1 token varsayımı, doğrulanmadı);
/// prefill token'ı [estimateTokens] tahminidir (muhafazakâr: gerçekten fazla çıkabilir) => prefill tok/s YAKLAŞIK ve düşük değerdir.
class EngineMetrics {
  static int? lastLoadMs;
  static int? lastPeakRssMb; // /proc/self/status VmHWM (süreç tepe RSS)
  static double? lastDecodeTps;
  static double? lastPrefillTps;
  static int? lastFirstTokenMs;
  static int modelSwitches = 0; // farklı modele geçiş (unload+load) sayısı

  static int? readPeakRssMb() {
    try {
      final m = RegExp(
        r'^VmHWM:\s+(\d+)\s*kB',
        multiLine: true,
      ).firstMatch(File('/proc/self/status').readAsStringSync());
      return m == null ? null : int.parse(m.group(1)!) ~/ 1024;
    } catch (_) {
      return null;
    }
  }

  static void recordGen({
    required int promptTokEst,
    required int tokens,
    required int firstMs,
    required int totalMs,
  }) {
    lastFirstTokenMs = tokens > 0 ? firstMs : null;
    lastPrefillTps =
        (tokens > 0 && firstMs > 0) ? promptTokEst * 1000 / firstMs : null;
    final decMs = totalMs - firstMs;
    lastDecodeTps =
        (tokens > 1 && decMs > 0) ? (tokens - 1) * 1000 / decMs : null;
    lastPeakRssMb = readPeakRssMb();
    CrashGuard.log(
      'Ölçüm üretim',
      'ilkToken=${firstMs}ms prefill~${lastPrefillTps?.toStringAsFixed(1)} tok/s (tahmini ${promptTokEst} tok) '
          'decode=${lastDecodeTps?.toStringAsFixed(1)} tok/s ($tokens olay) toplam=${totalMs}ms tepeRSS=${lastPeakRssMb}MB',
      null,
    );
  }
}

/// CPU özellik denetimi (SIGILL ön uyarısı): derleme armv9-a+i8mm+dotprod+fp16 varsayar.
/// Eksikse yalnızca loglanır (aynı .so çalışır durumda kalmaz; çökme izi CrashGuard'a düşer).
Future<bool> cpuHasRequiredFeatures() async {
  try {
    final t = await File('/proc/cpuinfo').readAsString();
    final f = RegExp(
          r'^Features\s*:\s*(.*)$',
          multiLine: true,
        ).firstMatch(t)?.group(1) ??
        '';
    final set = f.split(RegExp(r'\s+')).toSet();
    final ok = set.contains('asimddp') &&
        set.contains('i8mm') &&
        (set.contains('asimdhp') || set.contains('fphp'));
    CrashGuard.log('CPU özellikleri', 'dotprod/i8mm/fp16 tam=$ok', null);
    return ok;
  } catch (_) {
    return true; // okunamadı: engelleme
  }
}

/// Probe için güvenli orta uzunlukta prompt: en çok batch/2 (en az 8) kelime => token sayısı
/// batch'in altında kalır. Eklenti prompt'u n_batch'lik parçalara bölmediğinden batch'i aşan
/// prompt GGML_ASSERT ile native abort (SIGABRT) üretir; bu yüzden asla batch'e yaklaşılmaz.
String buildProbePrompt(int batch) =>
    List.filled(math.max(8, batch ~/ 2), 'test').join(' ');

class FlutterLlamaBackend implements LlamaBackend {
  // Kaynak: flutter_llama 1.1.2, FlutterLlama.generateStream (pub.dev API sayfası):
  //   EventChannel('flutter_llama/stream') + _channel.invokeMethod('generateStream', params.toMap())
  // MethodChannel adı yayımlanmış belgelerde görünmüyor; 'flutter_llama' varsayımdır (DOĞRULANAMADI).
  // Yanlışsa MissingPluginException fırlar ve LlamaEngine akışsız moda düşer.
  static const _methodChannelName = 'flutter_llama';
  static const _eventChannelName = 'flutter_llama/stream';

  // Abonelik native tarafa ulaşsın diye üretim çağrısından önce küçük bir pay.
  // Flutter kanal mesajları gönderim sırasıyla işlenir (listen -> generateStream); 50 ms yerine
  // yalnızca bir olay-döngüsü turu. Yetmezse NO_EVENT_SINK yeniden deneme yolu (LlamaEngine._produce) devrede.
  static const _listenSettle = Duration.zero;
  // invokeMethod döndükten sonra token geldiyse (senkron native) kuyruk boşalma payı.
  // Asıl bitiş sinyali native onDone (endOfStream); bu yalnızca yedek. 2 sn -> 400 ms (her token arm'ı sıfırlar).
  static const _tailGrace = Duration(milliseconds: 400);
  // invokeMethod hiç token gelmeden döndüyse (asenkron native) bekleme sınırı.
  static const _stallLimit = Duration(seconds: 90);

  FlutterLlamaBackend({
    Future<int?> Function()? memAvailable,
    Future<int?> Function()? totalMemory,
  })  : _memAvailableOverride = memAvailable,
        _totalMemoryOverride = totalMemory;

  final Future<int?> Function()? _memAvailableOverride;
  final Future<int?> Function()? _totalMemoryOverride;
  String? _modelName;
  int? _modelSize;
  int? _ctx;
  int _batch = 512;
  bool _batchKnown =
      false; // load() profili belirleyene dek batchSize null döner
  int _threads = 4;
  int? _memAtLoadMb;
  int? _kvPerToken;
  int? _nFf;
  MemoryPlan? _plan;
  LoadProfile? _profile; // son yükleme profili

  // Bekleyen native üretim çağrısı sayacı (invokeMethod / generate dönene dek "meşgul").
  // Not: eklenti kaynağı çevrimdışı doğrulanamadı; asenkron native'de çağrı erken dönebilir.
  int _active = 0;
  Completer<void> _idleGate = Completer<void>()..complete();

  void _enter() {
    if (_active++ == 0) _idleGate = Completer<void>();
  }

  void _exit() {
    if (--_active == 0 && !_idleGate.isCompleted) _idleGate.complete();
  }

  @override
  int? get contextSize => _ctx;

  @override
  int? get batchSize => _batchKnown ? _batch : null;

  @override
  Future<bool> waitIdle(Duration timeout) async {
    if (_active == 0) return true;
    try {
      await _idleGate.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<bool> get underMemoryPressure async =>
      (await MemInfoNative.current()).underPressure;

  @override
  Stream<int> get trimEvents => MemInfoNative.trimEvents;

  final FlutterLlama _llama = FlutterLlama.instance;
  final MethodChannel _method = const MethodChannel(_methodChannelName);
  final EventChannel _events = const EventChannel(_eventChannelName);

  GenerationParams _params(String prompt, int maxTokens) {
    // Ajan başına ayarlar (SamplingScope); ayarlanmamışsa eski sabit değerler.
    final s = SamplingScope.current;
    return GenerationParams(
      prompt: prompt,
      temperature: s.temperature,
      topP: s.topP,
      topK: s.topK,
      maxTokens: maxTokens,
      repeatPenalty: s.repeatPenalty,
    );
  }

  Map<String, Object?> _baseExtra() => {
        'batchSize': _batch,
        'nThreads': _threads,
        'streak': CrashGuard.crashStreak,
        'memAvailMbAtLoad': _memAtLoadMb,
        'memAvailMbNow': CrashGuard.memAvailableMbSync(),
      };

  void _beginGen(String prompt, int maxTokens) => CrashGuard.beginOp(
        'generate',
        model: _modelName,
        size: _modelSize,
        contextSize: _ctx,
        extra: {
          ..._baseExtra(),
          'promptChars': prompt.length,
          'promptTokensEst': estimateTokens(
            prompt,
            kEngineEstimateTemplate,
          ), // PromptBudget ile aynı tahminci
          'batchCap': PromptBudget.batchSoftCap(
            _batch,
          ), // promptTokensEst ile karşılaştırmak için (batchShare)
          'maxTokens': maxTokens,
        },
      );

  @override
  Future<bool> load(String path) async {
    final size = await File(path).length();
    final snapshot = await MemInfoNative.current();
    final avail =
        (await _memAvailableOverride?.call()) ?? snapshot.availableBytes;
    final total = (await _totalMemoryOverride?.call()) ?? snapshot.totalBytes;
    final effectiveTotal = total ?? avail ?? size;
    final effectiveAvailable = avail ?? effectiveTotal ~/ 2;
    final meta = await GgufMeta.readFile(path);
    _kvPerToken = meta?.kvBytesPerToken ?? fallbackKvBytesPerToken(size);
    _nFf = meta?.feedForwardLength;
    final plan = memoryPlan(
      availableBytes: effectiveAvailable,
      totalBytes: effectiveTotal,
      modelBytes: size,
      kvPerToken: _kvPerToken!,
      nFf: _nFf,
    );
    final threads = LlamaTuning.resolveThreads(Platform.numberOfProcessors);
    unawaited(cpuHasRequiredFeatures());
    final prof = chooseLoadProfile(
      plan: plan,
      streak: CrashGuard.crashStreak,
      threads: threads,
    );
    final ok = await _loadProfile(
      path,
      size,
      effectiveAvailable,
      plan,
      prof,
      redOnly: plan.isRed,
    );
    if (!ok && plan.isRed) throw _insufficientMemory(plan, size);
    return ok;
  }

  @override
  Future<bool> loadDowngraded(String path) async {
    final cur = _profile;
    final oldPlan = _plan;
    if (cur == null || oldPlan == null) return false;
    final threads = LlamaTuning.resolveThreads(Platform.numberOfProcessors);
    final size = await File(path).length();
    final snapshot = await MemInfoNative.current();
    final avail =
        (await _memAvailableOverride?.call()) ?? snapshot.availableBytes;
    final total = (await _totalMemoryOverride?.call()) ?? snapshot.totalBytes;
    final effectiveTotal = total ?? avail ?? size;
    final effectiveAvailable = avail ?? effectiveTotal ~/ 2;
    final plan = memoryPlan(
      availableBytes: effectiveAvailable,
      totalBytes: effectiveTotal,
      modelBytes: size,
      kvPerToken: _kvPerToken ?? fallbackKvBytesPerToken(size),
      nFf: _nFf,
    );
    _plan = plan;
    final next = downgradeProfile(cur, plan: plan, threads: threads);
    if (next == null) {
      CrashGuard.log(
        'Profil düşürme',
        'daha düşük seviye yok (seviye=${cur.level})',
        null,
      );
      return false;
    }
    CrashGuard.log(
      'Profil düşürme',
      'seviye ${cur.level} -> ${next.level} ctx=${next.ctx} batch=${next.batch} threads=${next.threads}',
      null,
    );
    return _loadProfile(path, size, effectiveAvailable, plan, next);
  }

  InsufficientMemoryException _insufficientMemory(
    MemoryPlan plan,
    int modelBytes,
  ) {
    const mb = 1024 * 1024;
    final required = plan.selected.needBytes;
    final release = math.max(0, (required / 0.92 - plan.availableBytes).ceil());
    return InsufficientMemoryException(
      'RAM yetersiz: en küçük profil yaklaşık ${(required / mb).ceil()} MB istiyor, '
      'kullanılabilir bellek ${(plan.availableBytes / mb).floor()} MB. '
      'Yaklaşık ${(release / mb).ceil()} MB RAM boşaltın; arka plan uygulamalarını kapatıp yeniden deneyin '
      'veya daha küçük model seçin (model ${(modelBytes / mb).ceil()} MB).',
    );
  }

  Future<bool> _loadProfile(
    String path,
    int size,
    int avail,
    MemoryPlan plan,
    LoadProfile firstProfile, {
    bool redOnly = false,
  }) async {
    _plan = plan;
    _modelName = path.split('/').last;
    _modelSize = size;
    _memAtLoadMb = avail ~/ 1048576;
    if (plan.selected.status == MemoryStatus.yellow) {
      const warning = 'RAM sınırda; arka plan uygulamalarını kapat';
      CrashGuard.log('Bellek uyarısı', warning, null);
      MemInfoNative.notify(warning);
    }
    CrashGuard.beginOp(
      'load',
      model: _modelName,
      size: size,
      contextSize: firstProfile.ctx,
      extra: _baseExtra(),
    );
    await NativeKeepAlive.acquire();
    try {
      // nGpuLayers 0 / useGpu false: Mali GPU'da llama.cpp Vulkan/OpenCL backend'i bu cihazda CPU
      // (X4/A720 + i8mm/dotprod) yolundan genelde yavaş; CI de bu backend'leri kapalı derler.
      // Eklenti 1.1.2'de (doğrulanamadı) LlamaConfig yalnızca modelPath/nThreads/nGpuLayers/contextSize/
      // batchSize/useGpu/verbose; flash-attn, KV q8_0, mmap/mlock ve ayrı batch-thread ALANI YOK =>
      // kullanılmadı. llama.cpp varsayılanları (use_mmap=true, use_mlock=false) geçerli kabul edilir.
      Future<bool> attempt(int ctx, int batch, int threads) {
        final sw = Stopwatch()..start();
        return _llama
            .loadModel(
          LlamaConfig(
            modelPath: path,
            nThreads: threads,
            nGpuLayers: 0,
            contextSize: ctx,
            batchSize: batch,
            useGpu: false,
            verbose: false,
          ),
        )
            .whenComplete(() {
          EngineMetrics.lastLoadMs = sw.elapsedMilliseconds;
          EngineMetrics.lastPeakRssMb = EngineMetrics.readPeakRssMb();
          CrashGuard.log(
            'Ölçüm yükleme',
            '${sw.elapsedMilliseconds}ms ctx=$ctx batch=$batch threads=$threads tepeRSS=${EngineMetrics.lastPeakRssMb}MB',
            null,
          );
        });
      }

      var candidate = firstProfile;
      Object? lastError;
      var ok = false;
      while (true) {
        _profile = candidate;
        _ctx = candidate.ctx;
        _batch = candidate.batch;
        _batchKnown = true;
        _threads = candidate.threads;
        CrashGuard.log(
          'Yükleme profili',
          'seviye=${candidate.level} ctx=${candidate.ctx} batch=${candidate.batch} threads=${candidate.threads} '
              'streak=${CrashGuard.crashStreak} memMbAtLoad=$_memAtLoadMb model=$_modelName',
          null,
        );
        try {
          ok = await attempt(candidate.ctx, candidate.batch, candidate.threads);
          lastError = null;
        } catch (e) {
          lastError = e;
          CrashGuard.log('Yükleme adayı başarısız', e, null);
        }
        if (ok) break;
        if (redOnly) break;
        final next = downgradeProfile(
          candidate,
          plan: plan,
          threads: LlamaTuning.resolveThreads(Platform.numberOfProcessors),
        );
        if (next == null) break;
        CrashGuard.log(
          'Yükleme geri dönüş',
          'aday ${candidate.level} başarısız; sıradaki aday ${next.level}: ctx=${next.ctx} batch=${next.batch}',
          null,
        );
        candidate = next;
      }
      if (ok && kLoadProbes) await _probe();
      if (!ok && lastError != null && !redOnly) throw lastError;
      return ok;
    } finally {
      await NativeKeepAlive.release();
      CrashGuard
          .endOp(); // Dart istisnası native çökme değildir; yalnızca süreç ölürse iz kalır
    }
  }

  /// Yükleme sonrası duman testi: kısa prompt, sonra en çok batch/2 token'lık orta prompt.
  /// Hata yalnızca loglanır. Kısa probe başarıyla biterse crashStreak sıfırlanır.
  Future<void> _probe() async {
    try {
      final sw = Stopwatch()..start();
      final short = await _run('Merhaba. Sadece OK yaz.', 8, countOk: false);
      // Yükleme + ilk üretim native çökmeden geçti: crashStreak sıfırlanır (aksi halde probe'lar
      // countOk:false olduğundan streak hiç düşmez ve cihaz kalıcı olarak seviye 2'de kalır).
      // Probe hata verirse (catch) çağrılmaz.
      CrashGuard.markOk();
      CrashGuard.log(
        'probe kısa',
        'ok ${sw.elapsedMilliseconds}ms çıktı="${short.trim()}"',
        null,
      );
      final midPrompt = buildProbePrompt(_batch);
      sw
        ..reset()
        ..start();
      final mid = await _run(midPrompt, 8, countOk: false);
      CrashGuard.log(
        'probe orta',
        'prompt ~batch/2 token (batch=$_batch) ok ${sw.elapsedMilliseconds}ms çıktı="${mid.trim()}"',
        null,
      );
    } catch (e, st) {
      CrashGuard.log('probe BAŞARISIZ', e, st);
    }
  }

  @override
  Future<void> unload() {
    _batchKnown = false;
    return _llama.unloadModel();
  }

  @override
  Future<String> complete(String prompt, int maxTokens) =>
      _run(prompt, maxTokens, countOk: true);

  Future<String> _run(
    String prompt,
    int maxTokens, {
    required bool countOk,
  }) async {
    _beginGen(prompt, maxTokens);
    _enter();
    await NativeKeepAlive.acquire();
    try {
      final text = (await _llama.generate(_params(prompt, maxTokens))).text;
      if (countOk) CrashGuard.markOk();
      return text;
    } finally {
      _exit();
      await NativeKeepAlive.release();
      CrashGuard.endOp();
    }
  }

  @override
  Future<void> stop() => _llama.stopGeneration();

  @override
  Stream<String> stream(String prompt, int maxTokens) {
    late final StreamController<String> c;
    StreamSubscription<dynamic>? sub;
    Timer? watchdog;
    var received = 0;
    var finished = false;
    var invokeReturned = false;
    var keepAlive = false;
    final swGen = Stopwatch();
    var firstMs = 0;
    var lastMs = 0;
    var loggedMetrics = false;

    void logMetrics() {
      if (loggedMetrics || received == 0) return;
      loggedMetrics = true;
      EngineMetrics.recordGen(
        promptTokEst: estimateTokens(prompt, kEngineEstimateTemplate),
        tokens: received,
        firstMs: firstMs,
        totalMs: lastMs,
      );
    }

    void dropKeepAlive() {
      if (!keepAlive) return;
      keepAlive = false;
      unawaited(NativeKeepAlive.release());
    }

    void finish([Object? error, StackTrace? st]) {
      if (finished) return;
      finished = true;
      logMetrics();
      CrashGuard.endOp();
      watchdog?.cancel();
      dropKeepAlive();
      final s = sub;
      sub = null;
      if (s != null) unawaited(s.cancel());
      if (!c.isClosed) {
        if (error != null) c.addError(error, st);
        unawaited(c.close());
      }
    }

    void arm(Duration d) {
      watchdog?.cancel();
      watchdog = Timer(d, finish);
    }

    Future<void> begin() async {
      // 1) ÖNCE abone ol: native onListen tetiklensin ve eventSink dolsun.
      sub = _events.receiveBroadcastStream().listen(
            (dynamic e) {
              if (e is! String || finished) return;
              received++;
              lastMs = swGen.elapsedMilliseconds;
              if (received == 1) firstMs = lastMs;
              if (!c.isClosed) c.add(e);
              if (invokeReturned) arm(_tailGrace);
            },
            onError: (Object e, StackTrace st) => finish(e, st),
            onDone: () {
              // Native akışı kendisi bitirdi: hatasız tamamlanma.
              CrashGuard.markOk();
              finish();
            },
          );
      await Future<void>.delayed(_listenSettle);
      if (finished) return;
      // 2) SONRA üretimi başlat. Ön plan servisi, üretim (finish/cancel) bitene dek açık kalır.
      _beginGen(prompt, maxTokens);
      swGen.start();
      _enter();
      keepAlive = true;
      unawaited(NativeKeepAlive.acquire());
      final call = _method.invokeMethod<dynamic>(
        'generateStream',
        _params(prompt, maxTokens).toMap(),
      );
      unawaited(
        call.then<void>((_) => _exit(), onError: (Object _) => _exit()),
      );
      try {
        await call;
        invokeReturned = true;
        if (!finished) arm(received > 0 ? _tailGrace : _stallLimit);
      } catch (e, st) {
        finish(e, st);
      }
    }

    c = StreamController<String>(
      onListen: () => unawaited(begin()),
      onCancel: () {
        finished = true;
        logMetrics();
        CrashGuard.endOp();
        watchdog?.cancel();
        dropKeepAlive();
        final s = sub;
        sub = null;
        if (s != null) unawaited(s.cancel());
      },
    );
    return c.stream;
  }
}

/// Native çağrıları (load/generate/unload/stop) tek sırada çalıştırır.
class _Mutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() fn) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return prev.then((_) => fn()).whenComplete(done.complete);
  }
}

class _GenRun {
  bool cancelled = false;
  bool pressureStopped = false;
  int emitted = 0;
  StreamSubscription<String>? inner;
  void Function()? abort;
}

class LlamaEngine implements LlmEngine {
  LlamaEngine({
    LlamaBackend? backend,
    Duration retryDelay = const Duration(milliseconds: 150),
  })  : _backend = backend ?? FlutterLlamaBackend(),
        _retryDelay = retryDelay;

  static final RegExp _chunks = RegExp(r'\S+\s*|\s+');

  final LlamaBackend _backend;
  final Duration _retryDelay;
  String? _loaded;
  static const _idleTimeout = Duration(seconds: 8);
  static const _disposeWait = Duration(seconds: 15);
  final _Mutex _gate = _Mutex();
  final Set<_GenRun> _runs = {};
  _GenRun? _activeRun;
  Future<void> _stopChain = Future<void>.value();
  bool _streamingUnsupported = false;

  @override
  String? get loadedPath => _loaded;

  /// NO_EVENT_SINK / kanal bulunamadı gibi nedenlerle akış kalıcı olarak bırakıldıysa true.
  bool get streamingUnsupported => _streamingUnsupported;

  @override
  int? get contextSize => _loaded == null ? null : _backend.contextSize;

  @override
  int? get batchSize => _loaded == null ? null : _backend.batchSize;

  @override
  Future<bool> waitNativeIdle(Duration timeout) => _backend.waitIdle(timeout);

  @override
  Future<void> ensureLoaded(String path, {int? expectedBytes}) =>
      _gate.run(() => _load(path, expectedBytes));

  /// Yalnızca kapı (_gate) elde iken çağrılır. Native üretim bitmeden unload yapılmaz.
  Future<void> _unloadLocked() async {
    await _safeStop();
    if (!await _backend.waitIdle(_idleTimeout)) {
      throw StateError(
        'Native üretim bitmedi; model güvenli biçimde boşaltılamadı.',
      );
    }
    _loaded = null;
    await _backend.unload();
  }

  Future<void> _load(String path, int? expectedBytes) async {
    if (_loaded == path) return;
    await validateModelFile(path, expectedBytes: expectedBytes);
    if (_loaded != null) {
      EngineMetrics.modelSwitches++;
      CrashGuard.log(
        'Model değişimi',
        'unload+load #${EngineMetrics.modelSwitches}: ${_loaded!.split('/').last} -> ${path.split('/').last}',
        null,
      );
      await _unloadLocked();
    }
    if (!await _backend.waitIdle(_idleTimeout)) {
      throw StateError('Önceki native üretim hâlâ sürüyor; model yüklenmedi.');
    }
    final ok = await _backend.load(path);
    if (!ok) throw StateError('Model yüklenemedi: $path');
    _loaded = path;
  }

  @override
  Stream<String> generate(String prompt, {int maxTokens = 1536}) {
    final run = _GenRun();
    late final StreamController<String> c;
    c = StreamController<String>(
      onListen: () {
        _runs.add(run);
        unawaited(
          _gate.run(() => _drive(run, c, prompt, maxTokens)).whenComplete(() {
            _runs.remove(run);
          }),
        );
      },
      onCancel: () => _cancelRun(run),
    );
    return c.stream;
  }

  void _cancelRun(_GenRun run) {
    run.cancelled = true;
    final s = run.inner;
    run.inner = null;
    if (s != null) unawaited(s.cancel());
    run.abort?.call();
  }

  Future<void> _drive(
    _GenRun run,
    StreamController<String> c,
    String prompt,
    int maxTokens,
  ) async {
    var graceful = false;
    Timer? memoryTimer;
    StreamSubscription<int>? trimSubscription;
    var samplingMemory = false;
    void stopForMemoryPressure() {
      if (run.cancelled || run.pressureStopped) return;
      run.pressureStopped = true;
      const notice =
          'Bellek baskısı: üretim durduruldu. Arka plan uygulamalarını kapatıp '
          'daha küçük bir profille yeniden yükleyin.';
      CrashGuard.log('Bellek baskısı', notice, null);
      MemInfoNative.notify(notice);
      run.abort?.call();
      final inner = run.inner;
      run.inner = null;
      if (inner != null) unawaited(inner.cancel());
      unawaited(_safeStop());
    }

    Future<void> sampleMemory() async {
      if (samplingMemory || run.cancelled || run.pressureStopped) return;
      samplingMemory = true;
      try {
        if (await _backend.underMemoryPressure) stopForMemoryPressure();
      } catch (e) {
        CrashGuard.log('Bellek kontrolü', e, null);
      } finally {
        samplingMemory = false;
      }
    }

    try {
      if (run.cancelled) return;
      _activeRun = run;
      // Önceki (iptal edilmiş olabilir) üretim native tarafta bitmeden yenisi başlamaz.
      if (!await _backend.waitIdle(_idleTimeout)) {
        throw StateError(
          'Önceki native üretim hâlâ sürüyor; yeni üretim başlatılmadı.',
        );
      }
      trimSubscription = _backend.trimEvents.listen((level) {
        if (level >= 15)
          stopForMemoryPressure(); // TRIM_MEMORY_RUNNING_CRITICAL ve üstü
      }, onError: (Object e) => CrashGuard.log('onTrimMemory kanalı', e, null));
      memoryTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(sampleMemory()),
      );
      await sampleMemory();
      if (run.pressureStopped) throw _memoryPressureException();
      await _produce(run, c, prompt, maxTokens);
      if (run.pressureStopped) throw _memoryPressureException();
      graceful = true;
    } catch (e, st) {
      if (!run.cancelled && !c.isClosed) c.addError(e, st);
    } finally {
      memoryTimer?.cancel();
      await trimSubscription?.cancel();
      // Kapı bırakılmadan native sessizleşmeli: normal bitişte kısa süre beklenir,
      // iptal/hata sonrası hemen stop gönderilir.
      // waitIdle native boşalınca ANINDA döner; 2 sn yalnızca üst sınırdı (sabit bekleme değil). Native bitiş
      // sinyali geldiyse kazanç ~0; sınır 1 sn'ye indi (takılı native'de stop daha erken devreye girer).
      final grace = graceful && !run.cancelled
          ? const Duration(seconds: 1)
          : Duration.zero;
      if (!await _backend.waitIdle(grace)) {
        await _safeStop();
        await _backend.waitIdle(_idleTimeout);
      }
      _activeRun = null;
      if (!c.isClosed) await c.close();
    }
  }

  GenerationFailedException _memoryPressureException() =>
      const GenerationFailedException(
        'Bellek baskısı: üretim durduruldu. Arka plan uygulamalarını kapatıp daha küçük bir profille yeniden yükleyin.',
        code: 'MEMORY_PRESSURE',
      );

  /// Akış denemesinden sonra yeni native üretimden (yeniden deneme / complete) önce çağrılır.
  Future<void> _quiesceNative() async {
    await _safeStop();
    if (!await _backend.waitIdle(_idleTimeout)) {
      throw StateError(
        'Akış üretimi native tarafta bitmedi; yeni üretim başlatılmadı.',
      );
    }
  }

  Future<void> _produce(
    _GenRun run,
    StreamController<String> c,
    String prompt,
    int maxTokens,
  ) async {
    if (run.pressureStopped) return;
    var attemptedStream = false;
    if (!_streamingUnsupported) {
      for (var attempt = 0;; attempt++) {
        attemptedStream = true;
        try {
          await _pipe(run, c, _backend.stream(prompt, maxTokens));
          if (run.pressureStopped) return;
          if (run.cancelled || run.emitted > 0) return;
          break; // hiç token gelmedi: bu çağrıda akışa güvenme, akışsız dene
        } on MissingPluginException {
          if (run.pressureStopped) return;
          _streamingUnsupported = true;
          break;
        } on PlatformException catch (e) {
          if (run.pressureStopped) return;
          if (run.cancelled) return;
          if (run.emitted > 0)
            rethrow; // kısmi çıktı varsa yeniden denemek çıktıyı bozar
          if (e.code != 'NO_EVENT_SINK') {
            // GENERATION_FAILED dahil, token gelmeden biten her PlatformException: kurtarma zinciri.
            await _recoverGeneration(
              run,
              c,
              prompt,
              maxTokens,
              e,
              completeTried: false,
            );
            return;
          }
          await Future<void>.delayed(_retryDelay);
          await _quiesceNative();
          if (attempt == 0) continue;
          _streamingUnsupported = true;
          break;
        }
      }
    }
    if (run.cancelled || run.pressureStopped) return;
    if (attemptedStream) await _quiesceNative();
    if (run.pressureStopped) return;
    final String text;
    try {
      text = await _backend.complete(prompt, maxTokens);
    } on PlatformException catch (e) {
      if (run.pressureStopped) return;
      if (run.cancelled) return;
      if (run.emitted > 0) rethrow;
      // complete() zaten denendi: kurtarma doğrudan profil düşürmeyle başlar.
      await _recoverGeneration(
        run,
        c,
        prompt,
        maxTokens,
        e,
        completeTried: true,
      );
      return;
    }
    await _emitText(run, c, text);
  }

  Future<void> _emitText(
    _GenRun run,
    StreamController<String> c,
    String text,
  ) async {
    for (final m in _chunks.allMatches(text)) {
      if (run.cancelled) return;
      run.emitted++;
      c.add(m.group(0)!);
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Günlük için kısa, güvenli özet: yalnızca kod + mesaj. Prompt, ayrıntı (details) ve kullanıcı verisi yazılmaz.
  static String _brief(Object e) => e is PlatformException
      ? 'kod=${e.code} mesaj=${e.message}'
      : e.runtimeType.toString();

  /// Hiç token gelmeden PlatformException (ör. GENERATION_FAILED) alındığında:
  ///  a) [completeTried] false ise sessizleştir + akışsız complete() ile bir kez dene,
  ///  b) olmazsa modeli boşalt, [downgradeProfile] ile bir seviye düşük profille yeniden yükle, bir kez daha dene,
  ///  c) yine olmazsa Türkçe, eyleme dönük [GenerationFailedException] fırlat.
  /// Yalnızca kapı (_gate) elde iken çağrılır.
  Future<void> _recoverGeneration(
    _GenRun run,
    StreamController<String> c,
    String prompt,
    int maxTokens,
    PlatformException cause, {
    required bool completeTried,
  }) async {
    if (run.pressureStopped) return;
    CrashGuard.log('Üretim hatası', '${_brief(cause)} (token gelmedi)', null);

    if (!completeTried) {
      try {
        await _quiesceNative();
        if (run.cancelled) return;
        CrashGuard.log('Kurtarma (a)', 'akışsız complete() deneniyor', null);
        final text = await _backend.complete(prompt, maxTokens);
        CrashGuard.log('Kurtarma (a)', 'başarılı', null);
        await _emitText(run, c, text);
        return;
      } on PlatformException catch (e) {
        if (run.cancelled) return;
        CrashGuard.log('Kurtarma (a) BAŞARISIZ', _brief(e), null);
      }
    }

    var retried = false;
    try {
      final path = _loaded;
      if (path == null) throw StateError('model yüklü değil');
      CrashGuard.log(
        'Kurtarma (b)',
        'model boşaltılıp düşük profille yeniden yüklenecek',
        null,
      );
      await _unloadLocked();
      if (run.cancelled) return;
      if (!await _backend.loadDowngraded(path)) {
        CrashGuard.log(
          'Kurtarma (b) BAŞARISIZ',
          'düşük profille yükleme yapılamadı',
          null,
        );
      } else {
        _loaded = path;
        // Yeni (daha küçük) batch/ctx'e sığmayan prompt native abort riski taşır: orta kısmı kısaltılır.
        final batch = _backend.batchSize;
        final ctx = _backend.contextSize;
        var p = prompt;
        var fits = true;
        if (batch != null) {
          final hard = PromptBudget.batchHardCap(batch);
          p = fitPromptToTokens(prompt, hard);
          fits = estimateTokens(p, kEngineEstimateTemplate) <= hard;
          if (p.length != prompt.length) {
            CrashGuard.log(
              'Kurtarma (b)',
              'prompt ${prompt.length} -> ${p.length} karakter (batch $batch × %${(PromptBudget.batchHardShare * 100).round()})',
              null,
            );
          }
        }
        var mt = maxTokens;
        if (ctx != null) {
          mt = math.max(
            64,
            math.min(
              maxTokens,
              ctx - estimateTokens(p, kEngineEstimateTemplate) - 32,
            ),
          );
        }
        if (!fits) {
          CrashGuard.log(
            'Kurtarma (b) ATLANDI',
            'prompt yeni batch sınırına sığmıyor',
            null,
          );
        } else if (!run.cancelled) {
          retried = true;
          CrashGuard.log(
            'Kurtarma (b)',
            'complete() yeniden deneniyor (maxTokens=$mt)',
            null,
          );
          final text = await _backend.complete(p, mt);
          CrashGuard.log('Kurtarma (b)', 'başarılı', null);
          await _emitText(run, c, text);
          return;
        }
      }
    } on PlatformException catch (e) {
      if (run.cancelled) return;
      CrashGuard.log('Kurtarma (b) BAŞARISIZ', _brief(e), null);
    } catch (e) {
      if (run.cancelled) return;
      CrashGuard.log('Kurtarma (b) HATA', _brief(e), null);
    }

    if (run.cancelled) return;
    CrashGuard.log(
      'Kurtarma (c)',
      'kullanıcıya hata bildirilecek (yeniden deneme yapıldı=$retried)',
      null,
    );
    throw GenerationFailedException(
      retried
          ? kGenerationFailedRetriedMessage
          : kGenerationFailedNoRetryMessage,
      code: cause.code,
    );
  }

  Future<void> _pipe(
    _GenRun run,
    StreamController<String> c,
    Stream<String> s,
  ) {
    final done = Completer<void>();
    run.abort = () {
      if (!done.isCompleted) done.complete();
    };
    run.inner = s.listen(
      (t) {
        if (run.cancelled) return;
        run.emitted++;
        c.add(t);
      },
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    return done.future.whenComplete(() {
      run.inner = null;
      run.abort = null;
    });
  }

  Future<void> _safeStop() async {
    try {
      await _backend.stop();
    } catch (_) {}
  }

  Future<void> _stopDirect() {
    final r = _stopChain.then((_) => _safeStop());
    _stopChain = r;
    return r;
  }

  /// Üretim sürerken stop kapıyı beklemez (yoksa kendi üretimini bitiremez); aksi halde sıraya girer.
  @override
  Future<void> stop() {
    for (final r in _runs.toList()) {
      if (!identical(r, _activeRun))
        _cancelRun(r); // henüz başlamamış üretimler
    }
    return _activeRun != null ? _stopDirect() : _gate.run(_safeStop);
  }

  @override
  Future<void> dispose() async {
    for (final r in _runs.toList()) {
      _cancelRun(r);
    }
    if (_activeRun != null)
      await _stopDirect(); // önce stop; unload kapıda, bitişten sonra
    try {
      await _gate.run(() async {
        if (_loaded != null) await _unloadLocked();
      }).timeout(_disposeWait);
    } catch (e, st) {
      CrashGuard.log('LlamaEngine.dispose', e, st);
    }
  }
}
