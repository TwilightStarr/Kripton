// Değişiklik: yeni dosya. LiteRT-LM çalışma zamanı soyutlaması + motorlar arası küçük arayüzler.
import 'dart:async';

import 'chatml_parser.dart';

enum LiteRtBackend {
  npu('NPU'),
  gpu('GPU'),
  cpu('CPU');

  const LiteRtBackend(this.label);
  final String label;
}

class LiteRtSampling {
  const LiteRtSampling({
    required this.temperature,
    required this.topP,
    required this.topK,
    required this.repeatPenalty,
  });

  final double temperature;
  final double topP;
  final int topK;
  final double repeatPenalty;

  /// [LiteRtRuntime.supportedSampling] içinde kullanılan ayar adları.
  static const Set<String> names = {'temperature', 'topP', 'topK', 'repeatPenalty'};
}

/// flutter_litert_lm üzerindeki ince katman. Pakete dokunan TEK yer bunun uygulamasıdır
/// (litert_runtime_flutter.dart); motor mantığı bu arayüzle sahte çalışma zamanıyla test edilir.
abstract class LiteRtRuntime {
  /// Modeli [backend] ile yükler. Backend desteklenmiyorsa/başarısızsa istisna fırlatır.
  Future<void> load(String path, LiteRtBackend backend, {required int contextTokens});

  /// Yüklü modeli boşaltır. Yüklü değilken çağrılması zararsız olmalı.
  Future<void> unload();

  /// Paketin konuşma/mesaj API'siyle tek bir yanıt üretir ([system] + [history] + [user]).
  /// Şablonu paket uygular; buraya ham ChatML GİTMEZ.
  Stream<String> send({
    String? system,
    required List<ChatMlMessage> history,
    required String user,
    required LiteRtSampling sampling,
    required int maxTokens,
  });

  /// Sözleşme: üretimi durdurur, akışı kapatır ve native boşa çıkınca tamamlanır.
  Future<void> cancel();

  /// Paketin gerçekten uyguladığı örnekleme ayarları ([LiteRtSampling.names] alt kümesi).
  Set<String> get supportedSampling;

  /// Yüklü modelin bağlam penceresi (bilinmiyorsa null).
  int? get contextSize;
}

/// Modeli açıkça boşaltabilen motorlar. Olmayanlar için RoutingEngine dispose() kullanır.
abstract interface class UnloadableEngine {
  Future<void> unload();
}

/// Etkin LiteRT backend'ini bildiren motorlar.
abstract interface class BackendReporter {
  LiteRtBackend? get activeBackend;
}

/// Çağrıları sırayla çalıştıran kapı (LlamaEngine'deki _Mutex ile aynı disiplin).
class EngineGate {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() fn) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return prev.then((_) => fn()).whenComplete(done.complete);
  }
}
