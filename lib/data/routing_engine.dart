// Değişiklik: yeni dosya. Uzantıya göre LlamaEngine / LiteRtEngine seçen yönlendirici.
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

import 'crash_guard.dart';
import 'litert_engine.dart';
import 'litert_runtime.dart';
import 'llm_engine.dart';

enum EngineKind { llama, litert }

/// .litertlm / .task -> LiteRT-LM. Diğer her şey (.gguf dahil) -> llama.cpp; böylece GGUF yolu eskisi gibi
/// kalır (uzantısı farklı adlandırılmış GGUF'u LlamaEngine kendi başlık denetimiyle ele alır).
EngineKind engineKindForPath(String path) {
  final p = path.toLowerCase();
  if (p.endsWith('.litertlm') || p.endsWith('.task')) return EngineKind.litert;
  return EngineKind.llama;
}

class RoutingEngine implements LlmEngine, StreamStatusSource, BackendReporter {
  RoutingEngine({LlmEngine? llama, LlmEngine? litert})
      : _llama = llama ?? LlamaEngine(),
        _litert = litert ?? LiteRtEngine() {
    _bindFallback(_llama);
  }

  final LlmEngine _llama;
  final LlmEngine _litert;
  final EngineGate _gate = EngineGate();

  LlmEngine? _active;
  EngineKind? _activeKind;

  // Sohbet ekranı streamFallback'i engine.streamFallback'ten okur: etkin motorun değerini yansıtır.
  final ValueNotifier<bool> _fb = ValueNotifier<bool>(false);
  ValueListenable<bool>? _fbSource;

  @override
  ValueListenable<bool> get streamFallback => _fb;

  void _bindFallback(LlmEngine e) {
    _fbSource?.removeListener(_mirror);
    _fbSource = e is StreamStatusSource ? e.streamFallback : null;
    _fbSource?.addListener(_mirror);
    _mirror();
  }

  void _mirror() {
    final v = _fbSource?.value ?? false;
    if (_fb.value != v) _fb.value = v;
  }

  /// Hiçbir model yüklenmediyse eski davranış: llama.cpp motoru.
  LlmEngine get _current => _active ?? _llama;

  String? get activeEngineName => switch (_activeKind) {
        EngineKind.llama => 'llama.cpp',
        EngineKind.litert => 'LiteRT-LM',
        null => null,
      };

  @override
  LiteRtBackend? get activeBackend {
    final a = _active;
    return a is BackendReporter ? a.activeBackend : null;
  }

  @override
  String? get loadedPath => _active?.loadedPath;

  @override
  int? get contextSize => _current.contextSize;

  @override
  int? get batchSize => _current.batchSize;

  @override
  Future<bool> waitNativeIdle(Duration timeout) => _current.waitNativeIdle(timeout);

  @override
  Stream<String> generate(String prompt, {int maxTokens = 1536}) =>
      _current.generate(prompt, maxTokens: maxTokens);

  @override
  Future<void> stop() => _current.stop();

  @override
  Future<void> ensureLoaded(String path, {int? expectedBytes}) => _gate.run(() async {
        final kind = engineKindForPath(path);
        final target = kind == EngineKind.litert ? _litert : _llama;
        final current = _active;
        if (current != null && !identical(current, target)) {
          // Aynı anda ikisi RAM'de olmasın: ESKİ motor önce boşaltılır.
          await _unloadEngine(current);
        }
        _active = target;
        _activeKind = kind;
        _bindFallback(target);
        await target.ensureLoaded(path, expectedBytes: expectedBytes);
      });

  String _nameOf(LlmEngine e) => identical(e, _llama) ? 'llama.cpp' : 'LiteRT-LM';

  Future<void> _unloadEngine(LlmEngine e) async {
    if (e.loadedPath == null) return;
    final name = _nameOf(e);
    CrashGuard.log('Motor değişimi', '$name boşaltılıyor (iki motor aynı anda RAM\'de tutulmaz)', null);
    try {
      await e.stop();
    } catch (_) {}
    if (e is UnloadableEngine) {
      await e.unload();
    } else {
      await e.dispose(); // LlamaEngine: stop + unload; sonrasında yeniden kullanılabilir
    }
    if (e.loadedPath != null) {
      throw StateError('$name motoru boşaltılamadı; yeni model yüklenmedi (iki model aynı anda RAM\'e alınmaz).');
    }
  }

  @override
  Future<void> dispose() async {
    _fbSource?.removeListener(_mirror);
    _fbSource = null;
    await Future.wait<void>([_llama.dispose(), _litert.dispose()]);
  }
}
