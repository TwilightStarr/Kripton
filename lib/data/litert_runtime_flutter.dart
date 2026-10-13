// Değişiklik: yeni dosya. flutter_litert_lm adaptörü: YER TUTUCU.
//
// DOĞRULANAMADI: bu ortamda flutter_litert_lm kaynağı/README/example okunamadı (Flutter, pub cache ve ağ yok).
// API UYDURULMADI. Paketin gerçek API'si okunduktan sonra yalnızca bu dosya doldurulur:
//   load(): paketin motor/model oluşturma çağrısı; backend (npu/gpu/cpu) seçimi, bağlam üst sınırı = contextTokens.
//   unload(): model/konuşma/motor nesnelerini kapatma.
//   send(): konuşma oluştur (system + history) -> son kullanıcı mesajını gönder -> parça akışı (Stream<String>).
//           Örnekleme (temperature/topP/topK/repeatPenalty) paket destekliyorsa uygula, [supportedSampling]'e yaz.
//           maxTokens paket tarafında yoksa burada sayarak kes.
//   cancel(): paketin iptal çağrısı; native boşalınca tamamlansın ve send() akışı kapansın.
// Hata durumunda motor (LiteRtEngine) Türkçe hata verir ve GGUF/llama.cpp yolunu önerir; uygulama çökmez.
import 'chatml_parser.dart';
import 'litert_runtime.dart';

class FlutterLiteRtRuntime implements LiteRtRuntime {
  FlutterLiteRtRuntime();

  static const String _notBound =
      'flutter_litert_lm adaptörü henüz bağlanmadı (litert_runtime_flutter.dart)';

  @override
  Future<void> load(String path, LiteRtBackend backend, {required int contextTokens}) =>
      Future<void>.error(UnsupportedError(_notBound));

  @override
  Future<void> unload() => Future<void>.value();

  @override
  Stream<String> send({
    String? system,
    required List<ChatMlMessage> history,
    required String user,
    required LiteRtSampling sampling,
    required int maxTokens,
  }) =>
      Stream<String>.error(UnsupportedError(_notBound));

  @override
  Future<void> cancel() => Future<void>.value();

  @override
  Set<String> get supportedSampling => const <String>{};

  @override
  int? get contextSize => null;
}
