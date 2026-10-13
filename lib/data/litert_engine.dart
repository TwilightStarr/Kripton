// Değişiklik: yeni dosya. LiteRT-LM motoru (LlamaEngine ile aynı kapı/CrashGuard/ölçüm/keep-alive disiplini).
import 'dart:async';
import 'dart:io';

import '../application/token_budget.dart';
import '../domain/entities.dart';
import '../domain/inference_settings.dart';
import 'chatml_parser.dart';
import 'crash_guard.dart';
import 'litert_runtime.dart';
import 'litert_runtime_flutter.dart';
import 'llm_engine.dart';
import 'native_services.dart';

const String kLiteRtLoadFailedMessage =
    'LiteRT modeli yüklenemedi (NPU/GPU/CPU denendi). Aynı modelin GGUF sürümünü llama.cpp ile dene.';
const String kLiteRtGenerateFailedMessage =
    'LiteRT üretimi başarısız. Aynı modelin GGUF sürümünü llama.cpp ile dene.';

class _Run {
  bool cancelled = false;
  int emitted = 0;
  StreamSubscription<String>? inner;
  void Function()? abort;
}

class LiteRtEngine implements LlmEngine, UnloadableEngine, BackendReporter {
  LiteRtEngine({
    LiteRtRuntime? runtime,
    this.backendOrder = const [LiteRtBackend.npu, LiteRtBackend.gpu, LiteRtBackend.cpu],
    this.template = ChatTemplate.chatml,
    this.contextTokens = 4096,
  })  : assert(backendOrder.length > 0),
        _runtime = runtime ?? FlutterLiteRtRuntime();

  /// Denenecek backend sırası. Yükleme ya da İLK üretim başarısızsa bir alttaki denenir.
  final List<LiteRtBackend> backendOrder;

  /// Kripton'un ürettiği istemin şablonu. Şimdilik yalnızca ChatML (Qwen) desteklenir.
  ChatTemplate template;

  /// Çalışma zamanına verilen bağlam üst sınırı (çalışma zamanı kendi değerini bildirirse o geçerli).
  final int contextTokens;

  final LiteRtRuntime _runtime;

  static const _idleTimeout = Duration(seconds: 8);
  static const _disposeWait = Duration(seconds: 15);

  final EngineGate _gate = EngineGate();
  final Set<_Run> _runs = {};
  _Run? _activeRun;
  Future<void> _stopChain = Future<void>.value();

  String? _loaded;
  int? _loadedSize;
  LiteRtBackend? _activeBackend;
  int _backendIndex = -1;
  bool _verified = false; // etkin backend'de bir üretim hatasız tamamlandı
  bool _samplingLogged = false;

  // Bekleyen native üretim sayacı (LlamaEngine'deki _enter/_exit ile aynı).
  int _active = 0;
  Completer<void> _idleGate = Completer<void>()..complete();

  void _enter() {
    if (_active++ == 0) _idleGate = Completer<void>();
  }

  void _exit() {
    if (--_active == 0 && !_idleGate.isCompleted) _idleGate.complete();
  }

  @override
  String? get loadedPath => _loaded;

  @override
  LiteRtBackend? get activeBackend => _activeBackend;

  @override
  int? get contextSize => _loaded == null ? null : (_runtime.contextSize ?? contextTokens);

  /// LiteRT prompt'u kendi işler; GGUF'taki n_batch sınırı yoktur => bilinmiyor (null).
  @override
  int? get batchSize => null;

  @override
  Future<bool> waitNativeIdle(Duration timeout) async {
    if (_active == 0) return true;
    try {
      await _idleGate.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  bool get _hasNextBackend => _backendIndex + 1 < backendOrder.length;

  // ---------------------------------------------------------------- yükleme

  @override
  Future<void> ensureLoaded(String path, {int? expectedBytes}) =>
      _gate.run(() => _load(path, expectedBytes));

  void _requireChatMl() {
    if (template == ChatTemplate.chatml) return;
    throw GenerationFailedException(
      'LiteRT motoru şimdilik yalnızca ChatML (Qwen) şablonunu destekliyor; seçili şablon: ${template.name}. '
      'Bu model için GGUF sürümünü llama.cpp ile kullan.',
      code: 'LITERT_TEMPLATE',
    );
  }

  /// .litertlm/.task için GGUF başlığı denetimi yok (başlık biçimi DOĞRULANAMADI): yalnızca var/boş/.part/boyut.
  Future<int> _validateFile(String path, int? expectedBytes) async {
    if (path.endsWith('.part')) throw ModelFileException(path, 'yarım indirme (.part)');
    final f = File(path);
    if (!await f.exists()) throw ModelFileException(path, 'dosya yok');
    final len = await f.length();
    if (len == 0) throw ModelFileException(path, 'dosya boş');
    if (expectedBytes != null && len != expectedBytes) {
      throw ModelFileException(path, 'boyut uyuşmuyor: $len != $expectedBytes');
    }
    return len;
  }

  Future<void> _load(String path, int? expectedBytes) async {
    if (_loaded == path && _activeBackend != null) return;
    _requireChatMl();
    final size = await _validateFile(path, expectedBytes);
    if (_loaded != null) {
      EngineMetrics.modelSwitches++;
      CrashGuard.log(
        'Model değişimi',
        'LiteRT unload+load #${EngineMetrics.modelSwitches}: ${_loaded!.split('/').last} -> ${path.split('/').last}',
        null,
      );
      await _unloadLocked();
    }
    if (!await waitNativeIdle(_idleTimeout)) {
      throw StateError('Önceki native üretim hâlâ sürüyor; model yüklenmedi.');
    }
    _loadedSize = size;
    _samplingLogged = false;
    await NativeKeepAlive.acquire();
    try {
      await _loadFrom(path, 0);
    } finally {
      await NativeKeepAlive.release();
      CrashGuard.endOp(); // Dart istisnası native çökme değildir; yalnızca süreç ölürse iz kalır
    }
  }

  /// [backendOrder] içinde [start]'tan başlayarak ilk yüklenebilen backend'i etkin yapar.
  Future<void> _loadFrom(String path, int start) async {
    final name = path.split('/').last;
    for (var i = start; i < backendOrder.length; i++) {
      final backend = backendOrder[i];
      CrashGuard.beginOp(
        'load',
        model: name,
        size: _loadedSize,
        contextSize: contextTokens,
        extra: {
          'engine': 'litert',
          'backend': backend.name,
          'memAvailMbNow': CrashGuard.memAvailableMbSync(),
        },
      );
      final sw = Stopwatch()..start();
      try {
        await _runtime.load(path, backend, contextTokens: contextTokens);
        EngineMetrics.lastLoadMs = sw.elapsedMilliseconds;
        EngineMetrics.lastPeakRssMb = EngineMetrics.readPeakRssMb();
        CrashGuard.log(
          'Ölçüm yükleme',
          'LiteRT ${backend.label} ${sw.elapsedMilliseconds}ms ctx=$contextTokens tepeRSS=${EngineMetrics.lastPeakRssMb}MB',
          null,
        );
        _loaded = path;
        _activeBackend = backend;
        _backendIndex = i;
        _verified = false;
        CrashGuard.log('LiteRT backend', 'etkin backend=${backend.label} model=$name', null);
        return;
      } catch (e, st) {
        CrashGuard.log('LiteRT yükleme başarısız', '${backend.label}: ${_brief(e)}', st);
        try {
          await _runtime.unload();
        } catch (_) {}
        if (i + 1 < backendOrder.length) {
          CrashGuard.log(
            'LiteRT geri dönüş',
            '${backend.label} backend\'i yüklenemedi (${_brief(e)}); ${backendOrder[i + 1].label} backend\'ine geçiliyor',
            null,
          );
        }
      }
    }
    _loaded = null;
    _activeBackend = null;
    _backendIndex = -1;
    throw const GenerationFailedException(kLiteRtLoadFailedMessage, code: 'LITERT_LOAD');
  }

  /// Yalnızca kapı (_gate) elde iken. Native üretim bitmeden unload yapılmaz.
  Future<void> _unloadLocked() async {
    await _safeStop();
    if (!await waitNativeIdle(_idleTimeout)) {
      throw StateError('Native üretim bitmedi; model güvenli biçimde boşaltılamadı.');
    }
    _loaded = null;
    _activeBackend = null;
    _backendIndex = -1;
    _verified = false;
    await _runtime.unload();
  }

  // ---------------------------------------------------------------- üretim

  @override
  Stream<String> generate(String prompt, {int maxTokens = 1536}) {
    final run = _Run();
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

  void _cancelRun(_Run run) {
    run.cancelled = true;
    final s = run.inner;
    run.inner = null;
    if (s != null) unawaited(s.cancel());
    run.abort?.call();
  }

  ChatMlParse _parse(String prompt) {
    try {
      final p = parseChatMl(prompt);
      if (p.assistantPrefill.isNotEmpty) {
        CrashGuard.log(
          'LiteRT istem',
          'açık asistan turundaki ön-ek metin yok sayıldı (${p.assistantPrefill.length} karakter)',
          null,
        );
      }
      return p;
    } on ChatMlFormatException catch (e) {
      throw GenerationFailedException(
        'LiteRT için istem ChatML olarak ayrıştırılamadı: ${e.message}',
        code: 'LITERT_CHATML',
      );
    }
  }

  Object _userError(Object e) => e is GenerationFailedException
      ? e
      : const GenerationFailedException(kLiteRtGenerateFailedMessage, code: 'LITERT_GENERATE');

  Future<void> _drive(
    _Run run,
    StreamController<String> c,
    String prompt,
    int maxTokens,
  ) async {
    var graceful = false;
    try {
      if (run.cancelled) return;
      _activeRun = run;
      // Önceki (iptal edilmiş olabilir) üretim native tarafta bitmeden yenisi başlamaz.
      if (!await waitNativeIdle(_idleTimeout)) {
        throw StateError('Önceki native üretim hâlâ sürüyor; yeni üretim başlatılmadı.');
      }
      if (_loaded == null) throw StateError('Model yüklü değil.');
      _requireChatMl();
      final parsed = _parse(prompt);
      await _produce(run, c, prompt, parsed, maxTokens);
      graceful = true;
    } catch (e, st) {
      CrashGuard.log('LiteRT üretim', _brief(e), st);
      if (!run.cancelled && !c.isClosed) c.addError(_userError(e), st);
    } finally {
      // Kapı bırakılmadan native sessizleşmeli (LlamaEngine ile aynı): normal bitişte kısa bekleme,
      // iptal/hata sonrası hemen stop.
      final grace =
          graceful && !run.cancelled ? const Duration(seconds: 1) : Duration.zero;
      if (!await waitNativeIdle(grace)) {
        await _safeStop();
        await waitNativeIdle(_idleTimeout);
      }
      _activeRun = null;
      if (!c.isClosed) await c.close();
    }
  }

  /// Üretir; hiç token gelmeden (ve etkin backend'de henüz başarılı üretim yokken) hata olursa
  /// [backendOrder]'daki bir sonraki backend ile modeli yeniden yükleyip tekrar dener.
  Future<void> _produce(
    _Run run,
    StreamController<String> c,
    String prompt,
    ChatMlParse parsed,
    int maxTokens,
  ) async {
    while (true) {
      final failed = _activeBackend;
      if (failed == null || _loaded == null) throw StateError('Model yüklü değil.');
      Object? error;
      StackTrace? st;
      try {
        await _generateOnce(run, c, prompt, parsed, maxTokens);
        if (run.cancelled) return;
        if (run.emitted == 0 && !_verified && _hasNextBackend) {
          error = StateError('akış hiç token üretmeden bitti');
        } else {
          _verified = true;
          return;
        }
      } catch (e, s) {
        error = e;
        st = s;
      }
      if (run.cancelled) return;
      CrashGuard.log('LiteRT üretim hatası', '${failed.label}: ${_brief(error)}', st);
      if (_verified || run.emitted > 0 || !_hasNextBackend) {
        // Kısmi çıktı varsa ya da backend daha önce çalışmışsa yeniden denemek çıktıyı bozar / yanıltır.
        Error.throwWithStackTrace(error!, st ?? StackTrace.current);
      }
      await _switchToNextBackend(failed, error);
    }
  }

  Future<void> _switchToNextBackend(LiteRtBackend failed, Object? cause) async {
    final next = backendOrder[_backendIndex + 1];
    CrashGuard.log(
      'LiteRT geri dönüş',
      '${failed.label} ilk üretimde başarısız oldu (${_brief(cause)}); ${next.label} backend\'ine geçiliyor',
      null,
    );
    final path = _loaded!;
    try {
      await _safeStop();
      if (!await waitNativeIdle(_idleTimeout)) {
        throw StateError('Native üretim bitmedi; backend değiştirilemedi.');
      }
      try {
        await _runtime.unload();
      } catch (e) {
        CrashGuard.log('LiteRT unload', _brief(e), null);
      }
      await NativeKeepAlive.acquire();
      try {
        await _loadFrom(path, _backendIndex + 1);
      } finally {
        await NativeKeepAlive.release();
        CrashGuard.endOp();
      }
    } catch (_) {
      _loaded = null;
      _activeBackend = null;
      _backendIndex = -1;
      _verified = false;
      rethrow;
    }
  }

  LiteRtSampling _sampling() {
    final s = SamplingScope.current; // ajan başına ayarlar
    return LiteRtSampling(
      temperature: s.temperature,
      topP: s.topP,
      topK: s.topK,
      repeatPenalty: s.repeatPenalty,
    );
  }

  void _logIgnoredSampling() {
    if (_samplingLogged) return;
    _samplingLogged = true;
    final supported = _runtime.supportedSampling;
    final ignored = LiteRtSampling.names.where((n) => !supported.contains(n)).toList();
    if (ignored.isNotEmpty) {
      CrashGuard.log(
        'LiteRT örnekleme',
        'paket şu ayarları desteklemiyor, yok sayıldı: ${ignored.join(', ')}',
        null,
      );
    }
  }

  void _beginGen(String prompt, int maxTokens) => CrashGuard.beginOp(
        'generate',
        model: _loaded?.split('/').last,
        size: _loadedSize,
        contextSize: contextSize,
        extra: {
          'engine': 'litert',
          'backend': _activeBackend?.name,
          'promptChars': prompt.length,
          'promptTokensEst': estimateTokens(prompt, kEngineEstimateTemplate),
          'maxTokens': maxTokens,
          'memAvailMbNow': CrashGuard.memAvailableMbSync(),
        },
      );

  Future<void> _generateOnce(
    _Run run,
    StreamController<String> c,
    String prompt,
    ChatMlParse parsed,
    int maxTokens,
  ) async {
    final turns = parsed.turns;
    final history = turns.sublist(0, turns.length - 1);
    final user = turns.last.text;
    final sampling = _sampling();
    _logIgnoredSampling();
    _beginGen(prompt, maxTokens);
    _enter();
    await NativeKeepAlive.acquire();
    final sw = Stopwatch()..start();
    var count = 0;
    var firstMs = 0;
    var lastMs = 0;
    var ok = false;
    try {
      final stream = _runtime.send(
        system: parsed.system,
        history: history,
        user: user,
        sampling: sampling,
        maxTokens: maxTokens,
      );
      await _pipe(run, c, stream, () {
        count++; // DOĞRULANAMADI: 1 olay ≈ 1 token varsayımı (ölçümler yaklaşık)
        lastMs = sw.elapsedMilliseconds;
        if (count == 1) firstMs = lastMs;
      });
      ok = true;
    } finally {
      // Hata/iptalde native'in gerçekten durduğundan emin olmadan "boşta" sayma.
      if (!ok || run.cancelled) await _safeStop();
      _exit();
      await NativeKeepAlive.release();
      CrashGuard.endOp();
      if (count > 0) {
        EngineMetrics.recordGen(
          promptTokEst: estimateTokens(prompt, kEngineEstimateTemplate),
          tokens: count,
          firstMs: firstMs,
          totalMs: lastMs,
        );
      }
    }
    if (!run.cancelled) CrashGuard.markOk();
  }

  Future<void> _pipe(
    _Run run,
    StreamController<String> c,
    Stream<String> s,
    void Function() onToken,
  ) {
    final done = Completer<void>();
    run.abort = () {
      if (!done.isCompleted) done.complete();
    };
    run.inner = s.listen(
      (t) {
        if (run.cancelled) return;
        run.emitted++;
        onToken();
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

  /// Günlük için kısa özet; prompt/kullanıcı verisi yazılmaz (istisna metni en çok 200 karakter).
  static String _brief(Object? e) {
    final s = e.toString();
    return '${e.runtimeType}: ${s.length > 200 ? s.substring(0, 200) : s}';
  }

  // ---------------------------------------------------------------- durdurma / boşaltma

  Future<void> _safeStop() async {
    try {
      await _runtime.cancel();
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
      if (!identical(r, _activeRun)) _cancelRun(r); // henüz başlamamış üretimler
    }
    return _activeRun != null ? _stopDirect() : _gate.run(_safeStop);
  }

  /// Modeli boşaltır (RoutingEngine motor değişiminde kullanır). Başarısızlıkta istisna fırlatır.
  @override
  Future<void> unload() async {
    for (final r in _runs.toList()) {
      _cancelRun(r);
    }
    if (_activeRun != null) await _stopDirect();
    await _gate.run(() async {
      if (_loaded != null) await _unloadLocked();
    });
  }

  @override
  Future<void> dispose() async {
    try {
      await unload().timeout(_disposeWait);
    } catch (e, st) {
      CrashGuard.log('LiteRtEngine.dispose', e, st);
    }
  }
}
