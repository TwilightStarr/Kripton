// Değişiklik: artımlı filtre (O(n²) kalktı), _replying re-entrancy bayrağı, canlı balon↔kalıcı mesaj tek karede devri (settleId), akış yedek bilgisi, stop(visibleChars).
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/chat_store.dart';
import '../data/crash_guard.dart';
import '../data/llm_engine.dart';
import '../data/profile_zip.dart';
import '../domain/chat_models.dart';
import '../domain/entities.dart';
import '../domain/inference_settings.dart';
import 'app_controller.dart';
import 'chat_memory.dart';
import 'chat_stream_filter.dart';
import 'engine_lock.dart';
import 'settings_controller.dart';
import 'token_budget.dart';

/// Ekranda bir kerede gösterilen mesaj sayısı (daha eskiler "Eski mesajlar" ile yüklenir; hepsi diskte durur).
const int kChatPageSize = 60;

/// Sohbet için örnekleme: akış ajanlarından (0.4) biraz daha yaratıcı.
const InferenceSettings kChatSampling = InferenceSettings(
  temperature: 0.7,
  topP: 0.9,
  topK: 40,
  repeatPenalty: 1.1,
);

final chatStoreProvider = Provider<ChatStore>((ref) => ChatStore());

/// Model listesi (AppController'dan). Testlerde geçersiz kılınabilir.
final chatModelsProvider = Provider<List<GgufModel>>(
  (ref) => ref.watch(appProvider.select((s) => s.models)),
);

/// Model listesi yüklendi mi?
final chatModelsLoadedProvider = Provider<bool>(
  (ref) => ref.watch(appProvider.select((s) => s.loaded)),
);

/// AI akışı / Geliştirme Modu çalışıyor mu (motor dolu).
final workflowBusyProvider = Provider<bool>(
  (ref) => ref.watch(appProvider.select((s) => s.running || s.cancelling)),
);

/// Cihaza göre seçilen varsayılan model kimliği.
final chatDefaultModelIdProvider = Provider<String?>(
  (ref) => ref.watch(appProvider.select((s) => s.defaultPick?.primaryId)),
);

/// Sohbet için seçili model: kullanıcının seçimi → cihaz varsayılanı → ilk indirilmiş (akıl yürütme modeli olmayan).
GgufModel? resolveChatModel(List<GgufModel> models, String? wantedId, String? defaultId) {
  final cached = [for (final m in models) if (m.isCached) m];
  if (cached.isEmpty) return null;
  for (final id in [wantedId, defaultId]) {
    if (id == null) continue;
    for (final m in cached) {
      if (m.id == id) return m;
    }
  }
  for (final m in cached) {
    if (m.template != ChatTemplate.deepseek) return m;
  }
  return cached.first;
}

final chatModelProvider = Provider<GgufModel?>((ref) {
  final models = ref.watch(chatModelsProvider);
  final wanted = ref.watch(settingsProvider.select((s) => s.chatModelId));
  final def = ref.watch(chatDefaultModelIdProvider);
  return resolveChatModel(models, wanted, def);
});

final chatProvider = NotifierProvider<ChatController, ChatState>(ChatController.new);

class ChatState {
  const ChatState({
    this.loaded = false,
    this.messages = const [],
    this.totalMessages = 0,
    this.sources = const [],
    this.pins = const [],
    this.generating = false,
    this.preparing = false,
    this.phase = '',
    this.draft = '',
    this.error,
    this.notice,
    this.noticeId = 0,
    this.lastRecalled = 0,
    this.importing = false,
    this.streamFallback = false,
    this.settleId,
  });

  final bool loaded;

  /// Ekranda görünen (en yeni) mesajlar.
  final List<ChatMessage> messages;

  /// Diskteki toplam mesaj sayısı.
  final int totalMessages;
  final List<ProfileSource> sources;
  final List<PinnedNote> pins;
  final bool generating;

  /// Model sohbet açılınca (ilk mesajdan önce) arka planda yükleniyor.
  final bool preparing;

  /// "Model hazırlanıyor…", "Yazıyor…" gibi anlık durum.
  final String phase;

  /// Üretilmekte olan yanıtın görünen kısmı.
  final String draft;
  final String? error;
  final String? notice;
  final int noticeId;

  /// Son yanıtta hafızadan kaç parça kullanıldı.
  final int lastRecalled;
  final bool importing;

  /// Canlı akış kullanılamıyor; yanıt akışsız (complete) yolla, hazır olunca geliyor.
  final bool streamFallback;

  /// Canlı balondan az önce kalıcı mesaja dönüşen yanıtın kimliği (arayüz animasyonu aynı balonda sürdürür).
  final String? settleId;

  bool get hasOlder => messages.length < totalMessages;

  ChatState copyWith({
    bool? loaded,
    List<ChatMessage>? messages,
    int? totalMessages,
    List<ProfileSource>? sources,
    List<PinnedNote>? pins,
    bool? generating,
    bool? preparing,
    String? phase,
    String? draft,
    String? error,
    bool clearError = false,
    String? notice,
    int? noticeId,
    int? lastRecalled,
    bool? importing,
    bool? streamFallback,
    String? settleId,
    bool clearSettle = false,
  }) => ChatState(
    loaded: loaded ?? this.loaded,
    messages: messages ?? this.messages,
    totalMessages: totalMessages ?? this.totalMessages,
    sources: sources ?? this.sources,
    pins: pins ?? this.pins,
    generating: generating ?? this.generating,
    preparing: preparing ?? this.preparing,
    phase: phase ?? this.phase,
    draft: draft ?? this.draft,
    error: clearError ? null : (error ?? this.error),
    notice: notice ?? this.notice,
    noticeId: noticeId ?? this.noticeId,
    lastRecalled: lastRecalled ?? this.lastRecalled,
    importing: importing ?? this.importing,
    streamFallback: streamFallback ?? this.streamFallback,
    settleId: clearSettle ? null : (settleId ?? this.settleId),
  );
}

class ChatController extends Notifier<ChatState> {
  final List<ChatMessage> _all = [];
  final MemoryIndex _index = MemoryIndex();
  MemoryData _memory = const MemoryData();
  int _shown = kChatPageSize;
  int _seq = 0;
  bool _cancelled = false;

  /// Durdur'a basıldığında ekranda görünen karakter sayısı (kod birimi); null = tümü.
  int? _stopVisibleChars;

  /// send / retry / prepare sürerken yeniden girişi engeller (state.generating henüz true olmadan da).
  bool _replying = false;
  bool _disposed = false;
  bool _prepareAfterInit = false;
  bool _prepareManualAfterInit = false;
  bool _prepareError = false;
  Completer<void>? _cancelSignal;
  DateTime _lastUi = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  ChatState build() {
    ref.onDispose(() {
      _cancelled = true;
      _disposed = true;
    });
    Future.microtask(_init);
    return const ChatState();
  }

  Future<void> _init() async {
    final store = ref.read(chatStoreProvider);
    final msgs = await store.loadMessages();
    final mem = await store.loadMemory();
    _all
      ..clear()
      ..addAll(msgs);
    _memory = mem;
    for (final m in msgs) {
      _index.add(_msgItem(m));
    }
    for (final s in mem.sources) {
      _addSource(s);
    }
    for (final p in mem.pins) {
      _index.add(_pinItem(p));
    }
    state = state.copyWith(
      loaded: true,
      messages: _window(),
      totalMessages: _all.length,
      sources: mem.sources,
      pins: mem.pins,
    );
    if (_prepareAfterInit) {
      final manual = _prepareManualAfterInit;
      _prepareAfterInit = false;
      _prepareManualAfterInit = false;
      unawaited(prepare(manual: manual));
    }
  }

  // ───────────────────────── yardımcılar ─────────────────────────

  MemoryItem _msgItem(ChatMessage m) => MemoryItem(
    id: 'm:${m.id}',
    kind: MemoryKind.message,
    text: m.text,
    ts: m.ts,
    role: m.role,
    group: 'chat',
  );

  MemoryItem _pinItem(PinnedNote p) =>
      MemoryItem(id: 'n:${p.id}', kind: MemoryKind.pin, text: p.text, ts: p.ts, group: 'pin');

  void _addSource(ProfileSource s) {
    for (var i = 0; i < s.chunks.length; i++) {
      final c = s.chunks[i];
      _index.add(
        MemoryItem(
          id: 'p:${s.id}:$i',
          kind: MemoryKind.profile,
          text: c.text,
          ts: s.importedAt,
          label: c.path,
          group: s.id,
        ),
      );
    }
  }

  List<ChatMessage> _window() => _all.length <= _shown ? List.of(_all) : _all.sublist(_all.length - _shown);

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  void _notice(String m) => state = state.copyWith(notice: m, noticeId: state.noticeId + 1);

  /// Her yanıtta verilen "çekirdek" profil: her dosyanın ilk parçası (dosya adı sırasıyla).
  List<MemoryItem> _coreItems() {
    final out = <MemoryItem>[];
    for (final s in _memory.sources) {
      final seen = <String>{};
      for (var i = 0; i < s.chunks.length; i++) {
        final c = s.chunks[i];
        if (!seen.add(c.path)) continue;
        out.add(
          MemoryItem(
            id: 'p:${s.id}:$i',
            kind: MemoryKind.profile,
            text: c.text,
            ts: s.importedAt,
            label: c.path,
            group: s.id,
          ),
        );
        if (out.length >= 12) return out;
      }
    }
    return out;
  }

  List<MemoryItem> _pinItems() => [for (final p in _memory.pins) _pinItem(p)];

  /// Mesajı listeye ekler, ardından diske yazar. [endLive] true ise canlı balon (generating/draft/phase)
  /// AYNI state güncellemesinde kapatılır: canlı balon ile kalıcı mesaj aynı karede el değiştirir.
  Future<void> _persistMessage(ChatMessage m, {bool endLive = false}) async {
    _all.add(m);
    _index.add(_msgItem(m));
    state = endLive
        ? state.copyWith(
            messages: _window(),
            totalMessages: _all.length,
            generating: false,
            phase: '',
            draft: '',
            settleId: m.id,
          )
        : state.copyWith(messages: _window(), totalMessages: _all.length);
    try {
      await ref.read(chatStoreProvider).append(m);
    } catch (e) {
      _notice('Mesaj diske kaydedilemedi: $e');
    }
  }

  // ───────────────────────── mesajlaşma ─────────────────────────

  /// Kullanıcı mesajını (hemen kalıcı olarak) kaydeder ve yanıt üretir.
  Future<void> send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || _replying || state.generating || state.preparing || !state.loaded) return;
    if (ref.read(workflowBusyProvider)) {
      _notice('Bir AI akışı çalışıyor; bitince sohbete dönebilirsin.');
      return;
    }
    final model = ref.read(chatModelProvider);
    if (model == null) {
      _notice('Sohbet için önce Model yöneticisinden bir model indir.');
      return;
    }
    final um = ChatMessage(
      id: _newId(),
      role: ChatRole.user,
      text: text,
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    _replying = true;
    try {
      await _persistMessage(um);
      await _reply(model, um);
    } finally {
      _replying = false;
    }
  }

  /// Son mesaj kullanıcınınsa (yanıt üretilemediyse) yanıtı yeniden dener; mesaj tekrar eklenmez.
  Future<void> retry() async {
    if (_replying || state.generating || state.preparing || !state.loaded || _all.isEmpty) return;
    final last = _all.last;
    if (last.role != ChatRole.user) return;
    if (ref.read(workflowBusyProvider)) {
      _notice('Bir AI akışı çalışıyor; bitince sohbete dönebilirsin.');
      return;
    }
    final model = ref.read(chatModelProvider);
    if (model == null) {
      _notice('Sohbet için önce Model yöneticisinden bir model indir.');
      return;
    }
    _replying = true;
    try {
      await _reply(model, last);
    } finally {
      _replying = false;
    }
  }

  /// Sohbet modelini ilk mesajı beklemeden yükler (ayar: [AppSettings.chatAutoPrepare]).
  ///
  /// Sessizce çıkar: üretim/hazırlık sürüyorsa, AI akışı motoru kullanıyorsa, indirilmiş model yoksa
  /// veya ayar kapalıysa ([manual] değilse). [chatBusyProvider] bilerek açılmaz: motor kapısı
  /// (_gate) yükleme ile diğer işleri zaten sıraya koyar.
  Future<void> prepare({bool manual = false}) async {
    if (_disposed || _replying || state.generating || state.preparing) return;
    if (!manual && !ref.read(settingsProvider).chatAutoPrepare) return;
    if (!state.loaded) {
      _prepareAfterInit = true;
      _prepareManualAfterInit = _prepareManualAfterInit || manual;
      return;
    }
    if (ref.read(workflowBusyProvider)) return;
    final first = ref.read(chatModelProvider);
    if (first == null || first.localPath == null) return;

    final engine = ref.read(engineProvider);
    final sw = Stopwatch()..start();
    String? lastId = first.id;
    var failed = false;
    _replying = true;
    state = state.copyWith(
      preparing: true,
      phase: 'Model hazırlanıyor…',
      clearError: manual || _prepareError,
    );
    _prepareError = false;
    try {
      // Hazırlanırken başka model seçilirse yenisi de yüklenir (en çok 4 tur).
      for (var round = 0; round < 4; round++) {
        if (_disposed || ref.read(workflowBusyProvider)) return;
        final m = ref.read(chatModelProvider);
        if (m == null || m.localPath == null) return;
        lastId = m.id;
        await engine.ensureLoaded(m.localPath!, expectedBytes: m.sizeBytes);
        await engine.waitNativeIdle(const Duration(seconds: 8));
        if (_disposed) return;
        if (ref.read(chatModelProvider)?.id == m.id) break;
      }
    } catch (e) {
      failed = true;
      if (!_disposed) {
        _prepareError = true;
        state = state.copyWith(error: 'Model hazırlanamadı: ${_errText(e)}');
      }
    } finally {
      CrashGuard.log(
        'Sohbet ön hazırlık',
        '${sw.elapsedMilliseconds}ms model=$lastId${failed ? ' (hata)' : ''}',
        null,
      );
      _replying = false;
      if (!_disposed) state = state.copyWith(preparing: false, phase: '');
    }
  }

  /// [visibleChars]: Durdur'a basıldığı anda ekranda görünen karakter sayısı (yazı animasyonu geride
  /// kalmış olabilir); verilirse kaydedilen yanıt yalnızca görünen kısımla sınırlanır.
  Future<void> stop({int? visibleChars}) async {
    if (!state.generating) return;
    _stopVisibleChars = visibleChars;
    _cancelled = true;
    final s = _cancelSignal;
    if (s != null && !s.isCompleted) s.complete();
    state = state.copyWith(phase: 'Durduruluyor…');
    try {
      await ref.read(engineProvider).stop().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  void _stopQuietly(LlmEngine e) {
    unawaited(e.stop().timeout(const Duration(seconds: 2)).catchError((Object _) {}));
  }

  void _pushDraft(String text, bool thinking, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastUi).inMilliseconds < 80) return;
    _lastUi = now;
    state = state.copyWith(draft: text, phase: thinking ? 'Düşünüyor…' : 'Yazıyor…');
  }

  Future<void> _reply(GgufModel m, ChatMessage userMsg) async {
    final engine = ref.read(engineProvider);
    _cancelled = false;
    _stopVisibleChars = null;
    final signal = Completer<void>();
    _cancelSignal = signal;
    ref.read(chatBusyProvider.notifier).state = true;
    final alreadyLoaded = engine.loadedPath == m.localPath;
    state = state.copyWith(
      generating: true,
      phase: alreadyLoaded ? 'Hafıza taranıyor…' : 'Model hazırlanıyor…',
      draft: '',
      clearError: true,
      clearSettle: true,
    );
    _prepareError = false;
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    // Artımlı filtre: ham tampon tutulmaz, her token'da tüm metin yeniden taranmaz.
    final filter = ChatStreamFilter();
    // Canlı akış yedek bilgisi (LlamaEngine bildirir; sahte motorlar bildirmeyebilir).
    final StreamStatusSource? streamSrc = switch (engine) {
      final StreamStatusSource s => s,
      _ => null,
    };
    void onFallback() {
      if (_disposed || streamSrc == null) return;
      final v = streamSrc.streamFallback.value;
      if (state.streamFallback != v) state = state.copyWith(streamFallback: v);
    }

    streamSrc?.streamFallback.addListener(onFallback);
    try {
      await engine.ensureLoaded(m.localPath!, expectedBytes: m.sizeBytes);
      if (_cancelled) return;
      if (!await engine.waitNativeIdle(const Duration(seconds: 8))) {
        throw StateError('Önceki üretim hâlâ sürüyor; birkaç saniye sonra tekrar dene.');
      }
      if (_cancelled) return;

      // Hafıza + bağlam bütçesi
      state = state.copyWith(phase: 'Hafıza taranıyor…');
      final tpl = m.template;
      final ctx = engine.contextSize ?? 2048;
      final batch = engine.batchSize;
      final r1 = tpl == ChatTemplate.deepseek;
      final bud = PromptBudget.of(ctx, deepseek: r1, batch: batch);
      final charBudget = (bud.usablePromptTokens * charsPerToken(tpl, 'ç')).floor();
      final hardTokens = math.min(
        bud.limit - bud.maxNew,
        batch == null ? 1 << 30 : PromptBudget.batchHardCap(batch),
      );

      final idx = _all.indexWhere((x) => x.id == userMsg.id);
      final upto = idx < 0 ? _all.length : idx;
      final history = _all.sublist(math.max(0, upto - 24), upto);
      final core = _coreItems();
      final exclude = <String>{
        'm:${userMsg.id}',
        for (final h in history) 'm:${h.id}',
        for (final c in core) c.id,
      };
      var query = userMsg.text;
      if (query.length < 40) {
        for (var i = history.length - 1; i >= 0; i--) {
          if (history[i].role == ChatRole.user) {
            query = '${history[i].text} $query';
            break;
          }
        }
      }
      final hits = _index.search(
        query,
        limit: 8,
        exclude: exclude,
        kinds: {MemoryKind.profile, MemoryKind.message},
      );
      final fit = ChatPromptBuilder.buildWithin(
        template: tpl,
        charBudget: charBudget,
        maxPromptTokens: hardTokens,
        userText: userMsg.text,
        history: history,
        pins: _pinItems(),
        core: core,
        recalled: [for (final h in hits) h.item],
      );
      if (!fit.fits) {
        throw StateError('Mesaj bu cihazın bağlam sınırına sığmıyor; daha kısa yaz veya parçala.');
      }
      state = state.copyWith(lastRecalled: fit.prompt.recalled + fit.prompt.profileParts + fit.prompt.pinned);

      // Üretim
      state = state.copyWith(phase: 'Yazıyor…');
      final done = Completer<void>();
      final guard = ThinkGuard(r1 ? bud.thinkChars(tpl) : 0);
      var thinkCut = false;
      var markerCut = false;
      SamplingScope.current = kChatSampling;
      final sub = engine
          .generate(fit.prompt.prompt, maxTokens: bud.maxNew)
          .listen(
            (t) {
              if (_cancelled || thinkCut || markerCut) return;
              filter.add(t);
              if (filter.hitMarker) {
                markerCut = true;
                _stopQuietly(engine);
                if (!done.isCompleted) done.complete();
              } else if (r1) {
                guard.add(t);
                if (guard.exceeded) {
                  thinkCut = true;
                  _stopQuietly(engine);
                  if (!done.isCompleted) done.complete();
                }
              }
              _pushDraft(filter.visible, filter.thinking);
            },
            onError: (Object e, StackTrace st) {
              if (!done.isCompleted) done.completeError(e, st);
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          );
      try {
        await Future.any<void>([done.future, signal.future]);
      } finally {
        try {
          await sub.cancel().timeout(const Duration(seconds: 1));
        } catch (_) {}
        SamplingScope.reset();
      }
      if (_cancelled) {
        try {
          await engine.stop().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }

      filter.finish();
      final thinking = filter.thinking;
      var answer = filter.visible.trim();
      // Durdur'da yalnızca ekranda görünen kısım kaydedilir (animasyon geride kalmış olabilir).
      final cut = _stopVisibleChars;
      if (_cancelled && cut != null && cut < answer.length) {
        answer = answer.substring(0, math.max(0, cut)).trimRight();
      }
      if (answer.isEmpty) {
        if (_cancelled) return;
        throw StateError(
          thinking || thinkCut
              ? 'Model yalnızca düşündü, cevap üretemedi. Daha kısa bir soru dene veya düşünmeyen bir model seç.'
              : 'Model boş yanıt verdi. Tekrar dene.',
        );
      }
      await _persistMessage(
        ChatMessage(
          id: _newId(),
          role: ChatRole.assistant,
          text: _cancelled ? '$answer\n\n[durduruldu]' : answer,
          ts: DateTime.now().millisecondsSinceEpoch,
          modelId: m.id,
        ),
        endLive: true,
      );
    } catch (e) {
      // Yarım kalan yanıt varsa kaybolmasın.
      filter.finish();
      final partial = filter.visible.trim();
      if (partial.isNotEmpty) {
        await _persistMessage(
          ChatMessage(
            id: _newId(),
            role: ChatRole.assistant,
            text: '$partial\n\n[yanıt yarıda kesildi]',
            ts: DateTime.now().millisecondsSinceEpoch,
            modelId: m.id,
          ),
          endLive: true,
        );
      }
      state = state.copyWith(error: _errText(e));
    } finally {
      streamSrc?.streamFallback.removeListener(onFallback);
      SamplingScope.reset();
      ref.read(chatBusyProvider.notifier).state = false;
      try {
        await WakelockPlus.disable();
      } catch (_) {}
      state = state.copyWith(generating: false, phase: '', draft: '', streamFallback: false);
    }
  }

  String _errText(Object e) {
    if (e is InsufficientMemoryException) return e.message;
    if (e is ModelFileException) {
      return 'Model dosyası bozuk veya eksik. Model yöneticisinden silip yeniden indir.';
    }
    if (e is GenerationFailedException) return e.message;
    return e.toString().replaceFirst('Bad state: ', '');
  }

  void clearError() => state = state.copyWith(clearError: true);

  // ───────────────────────── geçmiş / model ─────────────────────────

  void loadOlder() {
    if (!state.hasOlder) return;
    _shown += kChatPageSize;
    state = state.copyWith(messages: _window());
  }

  void selectModel(String id) => ref.read(settingsProvider.notifier).setChatModel(id);

  /// Tüm geçmişi okunur bir Markdown dosyasına yazar; dosya yolunu döndürür (yoksa null).
  Future<String?> exportHistory() async {
    if (_all.isEmpty) {
      _notice('Henüz kayıtlı sohbet yok.');
      return null;
    }
    try {
      final dir = await ref.read(storageProvider).outputsDir();
      final f = await ref.read(chatStoreProvider).exportMarkdown(dir, _all);
      return f.path;
    } catch (e) {
      _notice('Dışa aktarılamadı: $e');
      return null;
    }
  }

  // ───────────────────────── hafıza ─────────────────────────

  Future<void> pickAndImportProfileZip() async {
    if (state.importing) return;
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    final f = res?.files.single;
    if (f == null || f.path == null) return;
    if (f.size > kProfileMaxZipBytes) {
      _notice('ZIP en fazla 20 MB olabilir.');
      return;
    }
    try {
      final bytes = await File(f.path!).readAsBytes();
      await importProfileBytes(bytes, f.name);
    } catch (e) {
      _notice('ZIP okunamadı: $e');
    }
  }

  /// Profil ZIP'ini çözer, aranabilir hafızaya ekler. Aynı adlı ZIP tekrar yüklenirse eskisinin yerini alır.
  Future<void> importProfileBytes(Uint8List bytes, String name) async {
    if (state.importing) return;
    state = state.copyWith(importing: true);
    try {
      final out = await Isolate.run<(ProfileImportResult?, String?)>(() {
        try {
          return (parseProfileZip(bytes, name), null);
        } on FormatException catch (e) {
          return (null, e.message);
        }
      });
      final res = out.$1;
      if (res == null) {
        _notice(out.$2 ?? 'ZIP okunamadı.');
        return;
      }
      for (final old in _memory.sources.where((s) => s.name == name)) {
        _index.removeGroup(old.id);
      }
      final sources = [
        for (final s in _memory.sources)
          if (s.name != name) s,
        res.source,
      ];
      _memory = _memory.copyWith(sources: sources);
      _addSource(res.source);
      await ref.read(chatStoreProvider).saveMemory(_memory);
      state = state.copyWith(sources: sources);
      final skipped = res.skipped.isEmpty ? '' : ' ${res.skipped.length} dosya atlandı.';
      _notice('"$name" yüklendi: ${res.source.fileCount} dosya, ${res.source.chunks.length} parça.$skipped');
    } catch (e) {
      _notice('ZIP işlenemedi: $e');
    } finally {
      state = state.copyWith(importing: false);
    }
  }

  Future<void> removeSource(String id) async {
    if (!_memory.sources.any((s) => s.id == id)) return;
    _index.removeGroup(id);
    final sources = [for (final s in _memory.sources) if (s.id != id) s];
    _memory = _memory.copyWith(sources: sources);
    state = state.copyWith(sources: sources);
    try {
      await ref.read(chatStoreProvider).saveMemory(_memory);
    } catch (e) {
      _notice('Hafıza kaydedilemedi: $e');
    }
  }

  /// Notu her yanıtta modele verilen kalıcı hafızaya ekler.
  Future<void> addPin(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final clipped = t.length > 600 ? '${t.substring(0, 599)}…' : t;
    final note = PinnedNote(id: _newId(), text: clipped, ts: DateTime.now().millisecondsSinceEpoch);
    _memory = _memory.copyWith(pins: [..._memory.pins, note]);
    _index.add(_pinItem(note));
    state = state.copyWith(pins: _memory.pins);
    try {
      await ref.read(chatStoreProvider).saveMemory(_memory);
    } catch (e) {
      _notice('Hafıza kaydedilemedi: $e');
    }
  }

  Future<void> removePin(String id) async {
    if (!_memory.pins.any((p) => p.id == id)) return;
    _index.remove('n:$id');
    _memory = _memory.copyWith(pins: [for (final p in _memory.pins) if (p.id != id) p]);
    state = state.copyWith(pins: _memory.pins);
    try {
      await ref.read(chatStoreProvider).saveMemory(_memory);
    } catch (e) {
      _notice('Hafıza kaydedilemedi: $e');
    }
  }
}
