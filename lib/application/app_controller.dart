import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/default_data.dart';
import '../data/file_service.dart';
import '../data/llm_engine.dart';
import '../data/model_downloader.dart';
import '../data/native_services.dart';
import '../data/project_snapshot.dart';
import '../data/project_source.dart';
import '../data/project_zip.dart';
import '../data/routing_engine.dart';
import '../data/storage.dart';
import '../domain/entities.dart';
import '../domain/inference_settings.dart';
import '../data/workflow_zip_service.dart';
import 'dev_mode.dart';
import 'engine_lock.dart';
import 'model_fit.dart';
import 'settings_controller.dart';
import 'telemetry_bridge.dart';
import 'telemetry_service.dart';
import 'thermal_governor.dart';
import 'output_validator.dart';
import 'workflow_package_mapper.dart';
import 'workflow_runner.dart';

final storageProvider = Provider<Storage>((ref) => Storage());
final fileServiceProvider = Provider<FileService>((ref) => FileService());
final downloaderProvider = Provider<ModelDownloader>(
  (ref) => ModelDownloader(),
);

/// Cihazın toplam RAM'i (bayt); okunamazsa null. Testlerde geçersiz kılınabilir.
final deviceRamProvider = Provider<Future<int?> Function()>(
  (ref) => () async {
    try {
      return (await MemInfoNative.current()).totalBytes;
    } catch (_) {
      return null;
    }
  },
);
final engineProvider = Provider<LlmEngine>((ref) {
  final e = RoutingEngine(); // .gguf -> LlamaEngine, .litertlm/.task -> LiteRtEngine
  ref.onDispose(e.dispose);
  return e;
});
final runnerProvider = Provider<WorkflowRunner>(
  (ref) => WorkflowRunner(
    ref.read(engineProvider),
    ref.read(fileServiceProvider),
    ref.read(storageProvider),
  ),
);
final liveTokensProvider = StateProvider<String>((ref) => '');

/// Canlı izleme paneli (LiveTelemetrySheet) için telemetri akışı; AppController besler.
final telemetryServiceProvider = Provider<TelemetryService>((ref) {
  final s = TelemetryService();
  ref.onDispose(s.dispose);
  return s;
});
final appProvider = NotifierProvider<AppController, AppState>(
  AppController.new,
);

class AppState {
  final bool loaded;
  final List<Workflow> workflows;
  final String currentId;
  final List<GgufModel> models;
  final String? selectedAgentId;
  final bool running;
  final bool cancelling;
  final bool failed;
  final String status;
  final String liveAgent;
  final List<ExecutionLog> logs;
  final Artifact? artifact;

  /// Doğrulamadan geçemeyen çıktı (dosya üretilmedi); "yine de indir" için saklanır.
  final OutputValidationException? rejected;

  /// Akış sırasında her ajanın (ve doğrulayıcının) ürettiği çıktı özetleri; sonuç ekranında listelenir.
  final List<AgentOutput> agentOutputs;

  /// Küçük bağlam uyarısı (akış başında); yoksa null. Yeni akışta temizlenir.
  final String? contextWarning;
  final Map<String, double> downloads;
  final String? notice;
  final int noticeId;
  final int? totalRamBytes;
  final DefaultModelPick? defaultPick;

  /// Geliştirme Modu ilerlemesi (hiç başlatılmadıysa null).
  final DevProgress? dev;

  /// Sade mod açık mı: akış sürerken tam arayüz yerine tek ekranlık hafif arayüz gösterilir;
  /// canlı token metni, günlük ve telemetri kareleri üretilmez (RAM/CPU azalır).
  final bool lite;

  /// Son akışın başlangıç zamanı (sade ekranda geçen süre için).
  final DateTime? startedAt;

  const AppState({
    this.loaded = false,
    this.workflows = const [],
    this.currentId = '',
    this.models = const [],
    this.selectedAgentId,
    this.running = false,
    this.cancelling = false,
    this.failed = false,
    this.status = '',
    this.liveAgent = '',
    this.logs = const [],
    this.artifact,
    this.rejected,
    this.agentOutputs = const [],
    this.contextWarning,
    this.downloads = const {},
    this.notice,
    this.noticeId = 0,
    this.totalRamBytes,
    this.defaultPick,
    this.dev,
    this.lite = false,
    this.startedAt,
  });

  Workflow? get current {
    for (final w in workflows) {
      if (w.id == currentId) return w;
    }
    return null;
  }

  int get cachedCount => models.where((m) => m.isCached).length;

  AppState copyWith({
    bool? loaded,
    List<Workflow>? workflows,
    String? currentId,
    List<GgufModel>? models,
    String? selectedAgentId,
    bool? running,
    bool? cancelling,
    bool? failed,
    String? status,
    String? liveAgent,
    List<ExecutionLog>? logs,
    Artifact? artifact,
    bool clearArtifact = false,
    OutputValidationException? rejected,
    bool clearRejected = false,
    List<AgentOutput>? agentOutputs,
    String? contextWarning,
    bool clearContextWarning = false,
    Map<String, double>? downloads,
    String? notice,
    int? noticeId,
    int? totalRamBytes,
    DefaultModelPick? defaultPick,
    DevProgress? dev,
    bool clearDev = false,
    bool? lite,
    DateTime? startedAt,
  }) => AppState(
    loaded: loaded ?? this.loaded,
    workflows: workflows ?? this.workflows,
    currentId: currentId ?? this.currentId,
    models: models ?? this.models,
    selectedAgentId: selectedAgentId ?? this.selectedAgentId,
    running: running ?? this.running,
    cancelling: cancelling ?? this.cancelling,
    failed: failed ?? this.failed,
    status: status ?? this.status,
    liveAgent: liveAgent ?? this.liveAgent,
    logs: logs ?? this.logs,
    artifact: clearArtifact ? null : (artifact ?? this.artifact),
    rejected: clearRejected ? null : (rejected ?? this.rejected),
    agentOutputs: agentOutputs ?? this.agentOutputs,
    contextWarning: clearContextWarning
        ? null
        : (contextWarning ?? this.contextWarning),
    downloads: downloads ?? this.downloads,
    notice: notice ?? this.notice,
    noticeId: noticeId ?? this.noticeId,
    totalRamBytes: totalRamBytes ?? this.totalRamBytes,
    defaultPick: defaultPick ?? this.defaultPick,
    dev: clearDev ? null : (dev ?? this.dev),
    lite: lite ?? this.lite,
    startedAt: startedAt ?? this.startedAt,
  );
}

class AppController extends Notifier<AppState> {
  Timer? _saveTimer;
  Timer? _flushTimer;
  final StringBuffer _buf = StringBuffer();
  CancelToken? _cancel;
  final Set<String> _active = {};
  int _lastStep = 0;
  final Map<String, DownloadCancel> _downloads = {};
  // Canlı metin tamponu: histerezisle kırpılır (her 40 ms'de 30K'lık substring kopyası yok).
  static const _liveKeep = 30000;
  static const _liveMax = 36000;
  String _lastTransferPreview = '';
  TelemetryBridge? _tb;
  TelemetryBridge get _bridge =>
      _tb ??= TelemetryBridge(ref.read(telemetryServiceProvider));

  @override
  AppState build() {
    ref.onDispose(() {
      _tb?.end(cancelled: true);
      _saveTimer?.cancel();
      _flushTimer?.cancel();
      _cancel?.cancel();
    });
    Future.microtask(_init);
    return const AppState();
  }

  Future<void> _init() async {
    final st = ref.read(storageProvider);
    final reg = await st.loadRegistry();
    final models = modelCatalog.map((m) {
      final r = reg[m.id];
      if (r != null && File(r['path'] ?? '').existsSync()) {
        return m.withCache(
          r['path'],
          r['sha256'],
          sizeBytes: int.tryParse(r['size'] ?? ''),
        );
      }
      return m;
    }).toList();
    final totalRam = await ref.read(deviceRamProvider)();
    final pick = pickDefaultModels(models, totalRam);
    var wfs = await st.loadWorkflows();
    if (wfs == null || wfs.isEmpty) {
      wfs = defaultWorkflows(
        primaryId: pick.primaryId,
        reviewerId: pick.reviewerId,
      );
      await st.saveWorkflows(wfs);
    } else {
      // Eski kayıtlı hazır akışlarda R1 üretici/dönüştürücü olarak atanmışsa Qwen'e al (yalnızca debugger kalır).
      final migrated = migrateReasoningRoles(wfs, pick.primaryId);
      if (migrated != null) {
        wfs = migrated;
        await st.saveWorkflows(wfs);
      }
    }
    state = state.copyWith(
      totalRamBytes: totalRam,
      defaultPick: pick,
      loaded: true,
      workflows: wfs,
      models: models,
      currentId: wfs.first.id,
      selectedAgentId: wfs.first.agents.isEmpty
          ? null
          : wfs.first.agents.first.id,
    );
  }

  void _notice(String m) =>
      state = state.copyWith(notice: m, noticeId: state.noticeId + 1);

  void _persist() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      ref.read(storageProvider).saveWorkflows(state.workflows);
    });
  }

  void _mutateCurrent(Workflow Function(Workflow) f, {bool persist = true}) {
    final cur = state.current;
    if (cur == null) return;
    final next = f(cur);
    state = state.copyWith(
      workflows: [for (final w in state.workflows) w.id == cur.id ? next : w],
    );
    if (persist) _persist();
  }

  List<AgentConfig> _reorder(List<AgentConfig> list) => [
    for (var i = 0; i < list.length; i++) list[i].copyWith(order: i + 1),
  ];

  List<AgentConfig> _sorted(Workflow w) =>
      [...w.agents]..sort((a, b) => a.order.compareTo(b.order));

  void selectWorkflow(String id) {
    for (final w in state.workflows) {
      if (w.id == id) {
        state = state.copyWith(
          currentId: id,
          selectedAgentId: w.agents.isEmpty ? null : w.agents.first.id,
        );
      }
    }
  }

  void selectAgent(String id) => state = state.copyWith(selectedAgentId: id);

  void createWorkflow(
    String title,
    String description,
    String task,
    OutputFormat f,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'wf-$now';
    final wf = Workflow(
      id: id,
      title: title.trim(),
      description: description.trim().isEmpty
          ? 'Yerel çoklu ajan boru hattı.'
          : description.trim(),
      task: task.trim(),
      targetFormat: f,
      agents: starterAgents(
        id,
        f,
        primaryId: state.defaultPick?.primaryId,
        reviewerId: state.defaultPick?.reviewerId,
      ),
      createdAt: now,
      updatedAt: now,
    );
    state = state.copyWith(
      workflows: [wf, ...state.workflows],
      currentId: id,
      selectedAgentId: wf.agents.first.id,
    );
    _persist();
  }

  void duplicateWorkflow() {
    final cur = state.current;
    if (cur == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'wf-$now';
    final wf = Workflow(
      id: id,
      title: '${cur.title} (Kopya)',
      description: cur.description,
      task: cur.task,
      targetFormat: cur.targetFormat,
      agents: [
        for (final a in _sorted(cur))
          AgentConfig(
            id: '$id-a${a.order}',
            order: a.order,
            name: a.name,
            mode: a.mode,
            modelId: a.modelId,
            systemPrompt: a.systemPrompt,
            userPrompt: a.userPrompt,
            maxLoops: a.maxLoops,
            attachedFiles: a.attachedFiles,
          ),
      ],
      createdAt: now,
      updatedAt: now,
      baseProject: cur.baseProject,
    );
    state = state.copyWith(
      workflows: [wf, ...state.workflows],
      currentId: id,
      selectedAgentId: wf.agents.isEmpty ? null : wf.agents.first.id,
    );
    _persist();
  }

  /// Flutter proje akışı oluşturur (ZIP çıktı). [baseProject] doluysa mevcut proje geliştirilir
  /// (`ProjectSource.selfRef` = Kripton'un kendi kaynağı); boşsa sıfırdan yeni proje üretilir.
  void createProjectWorkflow({
    required String title,
    required String task,
    String? baseProject,
    String description = '',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'wf-$now';
    final wf = Workflow(
      id: id,
      title: title.trim(),
      description: description.trim().isEmpty
          ? (baseProject == null
                ? 'Yeni Flutter projesi: Mimar → Kodlayıcı → Denetçi → ZIP.'
                : 'Mevcut projeyi geliştirir: değişen dosyalar tabanın üstüne bindirilir, tam proje ZIP verilir.')
          : description.trim(),
      task: task.trim(),
      targetFormat: OutputFormat.zip,
      agents: projectAgents(
        id,
        primaryId: state.defaultPick?.primaryId,
        reviewerId: state.defaultPick?.reviewerId,
        existingProject: baseProject != null,
      ),
      createdAt: now,
      updatedAt: now,
      baseProject: baseProject,
    );
    state = state.copyWith(
      workflows: [wf, ...state.workflows],
      currentId: id,
      selectedAgentId: wf.agents.first.id,
    );
    _persist();
  }

  /// "Kendini geliştir": uygulamaya gömülü Kripton kaynağı üzerinde çalışan bir akış ekler.
  void createSelfImproveWorkflow(String task) => createProjectWorkflow(
    title: 'Kripton Kendini Geliştir',
    task: task,
    baseProject: ProjectSource.selfRef,
    description:
        'Kripton kendi kaynak kodunu okur, görevi uygular ve güncellenmiş TAM kaynak ZIP\'ini üretir. '
        'ZIP\'i derleyip (GitHub Actions veya ./kurulum.sh) yeni sürümü kurarsın.',
  );

  /// Kullanıcının seçtiği proje ZIP'ini depoya kopyalar ve onu geliştiren bir akış ekler.
  /// İptal edilirse veya hata olursa false döner.
  Future<bool> pickProjectAndCreate(String task) async {
    if (state.running || state.cancelling) return false;
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      final path = res?.files.single.path;
      if (path == null) return false;
      final dir = await ref.read(storageProvider).projectsDir();
      final saved = await ProjectSource.copyInto(dir, path);
      final base = path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
      createProjectWorkflow(title: 'Proje: $base', task: task, baseProject: saved);
      return true;
    } catch (e) {
      _notice('Proje ZIP\'i yüklenemedi: $e');
      return false;
    }
  }

  void deleteWorkflow() {
    if (state.workflows.length <= 1 || state.running) return;
    final next = state.workflows.where((w) => w.id != state.currentId).toList();
    state = state.copyWith(
      workflows: next,
      currentId: next.first.id,
      selectedAgentId: next.first.agents.isEmpty
          ? null
          : next.first.agents.first.id,
    );
    _persist();
  }

  /// Ana ekrandaki görev kutusu: her değişiklikte güncellenir, kayıt 500 ms debounce ile yapılır.
  void setTask(String task) =>
      _mutateCurrent((w) => w.copyWith(task: task, updatedAt: _ts()));

  void setFormat(OutputFormat f) =>
      _mutateCurrent((w) => w.copyWith(targetFormat: f));

  void addAgent() {
    final cur = state.current;
    if (cur == null) return;
    final order = cur.agents.length + 1;
    final a = AgentConfig(
      id: 'agent-${DateTime.now().microsecondsSinceEpoch}',
      order: order,
      name: '$order. AI (Ek Ajan)',
      mode: AgentMode.generator,
      modelId:
          state.defaultPick?.primaryId ??
          (state.models.isEmpty
              ? modelCatalog.first.id
              : state.models.first.id),
      systemPrompt: 'Verilen bağlamı işleyerek sonraki aşamaya devret.',
      userPrompt:
          'Yukarıdaki KULLANICI GÖREVİ\'ni yerine getir: bu aşamaya düşen kısmı tamamla.',
    );
    _mutateCurrent(
      (w) => w.copyWith(agents: [..._sorted(w), a], updatedAt: _ts()),
    );
    state = state.copyWith(selectedAgentId: a.id);
  }

  int _ts() => DateTime.now().millisecondsSinceEpoch;

  void updateAgent(AgentConfig a) => _mutateCurrent(
    (w) => w.copyWith(
      agents: [for (final x in w.agents) x.id == a.id ? a : x],
      updatedAt: _ts(),
    ),
  );

  void deleteAgent(String id) {
    final cur = state.current;
    if (cur == null || cur.agents.length <= 1 || state.running) return;
    _mutateCurrent(
      (w) => w.copyWith(
        agents: _reorder(_sorted(w).where((a) => a.id != id).toList()),
        updatedAt: _ts(),
      ),
    );
  }

  void moveAgent(String id, int delta) {
    final cur = state.current;
    if (cur == null || state.running) return;
    final list = _sorted(cur);
    final i = list.indexWhere((a) => a.id == id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= list.length) return;
    final t = list[i];
    list[i] = list[j];
    list[j] = t;
    _mutateCurrent((w) => w.copyWith(agents: _reorder(list), updatedAt: _ts()));
  }

  Future<void> attachFiles(String agentId) async {
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (res == null) return;
    final cur = state.current;
    if (cur == null) return;
    AgentConfig? agent;
    for (final a in cur.agents) {
      if (a.id == agentId) agent = a;
    }
    if (agent == null) return;
    final added = <AttachedFile>[];
    for (final f in res.files) {
      final bytes = f.bytes;
      if (bytes == null) continue;
      try {
        added.add(
          await ref.read(fileServiceProvider).readAttachment(f.name, bytes),
        );
      } catch (e) {
        _notice('Dosya okunamadı: ${f.name}');
      }
    }
    if (added.isEmpty) return;
    final latest =
        state.current?.agents.firstWhere(
          (a) => a.id == agentId,
          orElse: () => agent!,
        ) ??
        agent;
    updateAgent(
      latest.copyWith(attachedFiles: [...latest.attachedFiles, ...added]),
    );
    _notice('${added.length} dosya eklendi.');
  }

  void _setProgress(String id, double v) =>
      state = state.copyWith(downloads: {...state.downloads, id: v});

  Future<void> startDownload(String id) async {
    if (state.downloads.containsKey(id)) return;
    GgufModel? m;
    for (final x in state.models) {
      if (x.id == id) m = x;
    }
    if (m == null || m.isCached) return;
    final model = m;
    final cancel = DownloadCancel();
    _downloads[id] = cancel;
    _setProgress(id, 0);
    _notice('İndirme başlatıldı: ${model.name}');
    try {
      final st = ref.read(storageProvider);
      final dl = ref.read(downloaderProvider);
      final path = await dl.download(
        model,
        await st.modelsDir(),
        (v) => _setProgress(id, v),
        cancel,
      );
      final hash = await dl.sha256Of(path);
      final reg = await st.loadRegistry();
      final size = await File(
        path,
      ).length(); // indirici boyutu doğruladı: beklenene eşit
      reg[id] = {'path': path, 'sha256': hash, 'size': '$size'};
      await st.saveRegistry(reg);
      state = state.copyWith(
        models: [
          for (final x in state.models)
            x.id == id ? x.withCache(path, hash, sizeBytes: size) : x,
        ],
      );
      _notice('${model.name} indirildi ve kaydedildi.');
    } on DownloadCancelled {
      _notice('İndirme duraklatıldı: ${model.name}');
    } catch (e) {
      _notice('İndirme hatası: $e');
    } finally {
      _downloads.remove(id);
      final d = {...state.downloads}..remove(id);
      state = state.copyWith(downloads: d);
    }
  }

  void cancelDownload(String id) => _downloads[id]?.cancelled = true;

  Future<void> deleteModel(String id) async {
    GgufModel? m;
    for (final x in state.models) {
      if (x.id == id) m = x;
    }
    if (m == null || !m.isCached) return;
    try {
      final f = File(m.localPath!);
      if (await f.exists()) await f.delete();
      final st = ref.read(storageProvider);
      final reg = await st.loadRegistry();
      reg.remove(id);
      await st.saveRegistry(reg);
      state = state.copyWith(
        models: [
          for (final x in state.models)
            x.id == id ? x.withCache(null, null) : x,
        ],
      );
      _notice('${m.name} silindi.');
    } catch (e) {
      _notice('Silinemedi: $e');
    }
  }

  /// Sade modda tutulan en fazla günlük sayısı (normal modda sınırsız, eskisi gibi).
  static const _liteLogKeep = 40;

  /// Sade modu açar/kapatır (akış sırasında da çağrılabilir).
  /// Açılırken canlı metin, ekran günlüğü, telemetri geçmişi ve görsel önbellek boşaltılır.
  void setLite(bool on) {
    if (state.lite == on) return;
    _bridge.lite = on;
    if (on) {
      _buf.clear();
      _lastTransferPreview = '';
      ref.read(liveTokensProvider.notifier).state = '';
      ref.read(telemetryServiceProvider).reset();
      final logs = state.logs;
      state = state.copyWith(
        lite: true,
        logs: logs.length > _liteLogKeep
            ? logs.sublist(logs.length - _liteLogKeep)
            : logs,
      );
      try {
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
      } catch (_) {}
    } else {
      state = state.copyWith(lite: false);
    }
  }

  void _flush() {
    if (state.lite) {
      _buf.clear();
      return;
    }
    if (_buf.isEmpty) return;
    final add = _buf.toString();
    _buf.clear();
    final n = ref.read(liveTokensProvider.notifier);
    var s = n.state + add;
    if (s.length > _liveMax) s = s.substring(s.length - _liveKeep);
    n.state = s;
  }

  void _setAgentState(String id, AgentStatus s, int loop) {
    final cur = state.current;
    if (cur == null) return;
    state = state.copyWith(
      workflows: [
        for (final w in state.workflows)
          w.id == cur.id
              ? w.copyWith(
                  agents: [
                    for (final a in w.agents)
                      a.id == id ? a.copyWith(status: s, currentLoop: loop) : a,
                  ],
                )
              : w,
      ],
    );
  }

  String _now() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  void _addLog(String who, String msg, LogType type) => state = state.copyWith(
    logs: [
      ...state.logs,
      ExecutionLog(time: _now(), agentName: who, message: msg, type: type),
    ],
  );

  /// Çalışan (running/looping) düğümleri izler; iptalde idle, hatada error'a çevrilir.
  void _trackAgent(String id, AgentStatus s, int loop) {
    if (s == AgentStatus.running || s == AgentStatus.looping) {
      _active.add(id);
      final order = state.current?.agents
          .where((a) => a.id == id)
          .map((a) => a.order)
          .firstOrNull;
      if (order != null) _lastStep = order;
    } else {
      _active.remove(id);
    }
    _setAgentState(id, s, loop);
  }

  Future<void> _wakelock(bool on) async {
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {}
  }

  /// Çalıştırıcı olaylarını uygulama durumuna ve telemetriye bağlar ([start] ve Geliştirme Modu ortak).
  RunCallbacks _callbacks(CancelToken ct) => RunCallbacks(
    status: (t) {
      if (!ct.cancelled) state = state.copyWith(status: t);
    },
    log: (l) {
      if (!ct.cancelled) {
        final all = [...state.logs, l];
        state = state.copyWith(
          logs: state.lite && all.length > _liteLogKeep
              ? all.sublist(all.length - _liteLogKeep)
              : all,
        );
        _bridge.onLog(l);
      }
    },
    token: (t) {
      if (!ct.cancelled) {
        if (!state.lite) _buf.write(t); // sade modda metin biriktirilmez
        _bridge.onToken(t);
      }
    },
    live: (name) {
      if (ct.cancelled) return;
      _bridge.onLive(name);
      _buf.clear();
      if (!state.lite) {
        ref.read(liveTokensProvider.notifier).state = _lastTransferPreview;
      }
      state = state.copyWith(liveAgent: name);
    },
    transfer: (message) {
      if (ct.cancelled) return;
      _flush();
      _buf.clear();
      if (!state.lite) {
        _lastTransferPreview = message;
        ref.read(liveTokensProvider.notifier).state = message;
      }
      state = state.copyWith(liveAgent: 'Ajanlar arası aktarım');
    },
    agent: (id, s, loop) {
      if (!ct.cancelled) {
        _trackAgent(id, s, loop);
        _bridge.onAgent(id, s, loop);
      }
    },
    agentOutput: (o) {
      if (ct.cancelled) return;
      final list = [...state.agentOutputs];
      final i = list.indexWhere((x) => x.agentId == o.agentId);
      if (i >= 0) {
        list[i] = o; // aynı ajan: doğrulama sonrası düzeltilmiş kayıt öncekinin yerine geçer
      } else {
        list.add(o);
      }
      state = state.copyWith(agentOutputs: list);
    },
    notice: (m) {
      if (ct.cancelled) return;
      state = state.copyWith(contextWarning: m);
      _notice(m);
    },
  );

  Future<void> start() async {
    final wf = state.current;
    if (wf == null || state.running || state.cancelling) return;
    if (ref.read(chatBusyProvider)) {
      _notice('Sohbet modu yanıt üretiyor; bitince akışı başlat.');
      return;
    }
    final ct = CancelToken();
    _cancel = ct;
    _active.clear();
    _lastStep = 0;
    _buf.clear();
    _lastTransferPreview = '';
    ref.read(liveTokensProvider.notifier).state = '';
    final lite = ref.read(settingsProvider).liteOnStart;
    _bridge.lite = lite;
    state = state.copyWith(
      running: true,
      cancelling: false,
      failed: false,
      status: '',
      logs: const [],
      clearArtifact: true,
      clearRejected: true,
      clearContextWarning: true,
      agentOutputs: const [],
      lite: lite,
      startedAt: DateTime.now(),
      workflows: [
        for (final w in state.workflows)
          w.id == wf.id
              ? w.copyWith(
                  agents: [
                    for (final a in w.agents)
                      a.copyWith(status: AgentStatus.idle, currentLoop: 0),
                  ],
                )
              : w,
      ],
    );
    _flushTimer?.cancel();
    // Token partileri: ~40 ms'de bir tek güncelleme (her token için notify yok).
    _flushTimer = Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => _flush(),
    );
    _bridge.begin(wf, state.models);
    await _wakelock(true); // üretim boyunca (finally'ye kadar) aktif
    DeviceThermal.charging().then((c) {
      if (c == false && wf.agents.length >= 3 && state.running) {
        _notice(
          'İpucu: uzun iş akışlarını şarjdayken çalıştır; ısınma ve yavaşlama azalır.',
        );
      }
    });
    try {
      final art = await ref
          .read(runnerProvider)
          .run(
            wf,
            state.models,
            _callbacks(ct),
            ct,
          );
      if (ct.cancelled) {
        try {
          await File(
            art.path,
          ).delete(); // iptal, son anda bitmiş dosyadan sonra geldiyse sonuç sunulmaz
        } catch (_) {}
        _onCancelled();
      } else {
        state = state.copyWith(artifact: art);
      }
    } on CancelledException {
      _onCancelled();
    } on OutputValidationException catch (e) {
      // Çıktı biçim sözleşmesine/göreve uymadı: dosya üretilmedi, içerik "yine de indir" için saklanır.
      if (ct.cancelled) {
        _onCancelled();
      } else {
        _active.clear();
        state = state.copyWith(
          failed: true,
          rejected: e,
          status:
              'Çıktı doğrulanamadı, dosya oluşturulmadı: ${e.summary} '
              '"Yine de indir" ile mevcut çıktıyı dosyaya çevirebilirsin.',
        );
        _addLog('Sistem', '$e', LogType.error);
      }
    } catch (e) {
      // İptal sırasında gelen ikincil hata (ör. native stop yarışı) çift günlük üretmesin.
      if (ct.cancelled) {
        _onCancelled();
      } else {
        for (final id in _active) {
          _setAgentState(id, AgentStatus.error, 0);
        }
        _active.clear();
        if (e is ModelFileException) {
          state = state.copyWith(
            models: [
              for (final x in state.models)
                x.localPath == e.path ? x.withCache(null, null) : x,
            ],
          );
        }
        state = state.copyWith(failed: true, status: 'Hata: $e');
        _addLog('Sistem', '$e', LogType.error);
      }
    } finally {
      _flush();
      _flushTimer?.cancel();
      _flushTimer = null;
      _buf.clear();
      _cancel = null;
      _active.clear();
      _bridge.end(failed: state.failed, cancelled: ct.cancelled);
      _bridge.lite = false;
      await _wakelock(false);
      state = state.copyWith(running: false, cancelling: false, lite: false);
    }
  }

  // ---- Eksik yardımcılar: "Yine de indir" akışın görevini/tabanını buradan okur ----

  Workflow? _workflowById(String id) {
    for (final w in state.workflows) {
      if (w.id == id) return w;
    }
    return null;
  }

  String _workflowTask(String workflowId) => _workflowById(workflowId)?.task ?? '';

  String? _workflowBase(String workflowId) => _workflowById(workflowId)?.baseProject;

  // ---- Geliştirme Modu ----

  void _devSet(DevProgress Function(DevProgress) f) {
    final cur = state.dev ?? const DevProgress();
    state = state.copyWith(dev: f(cur));
  }

  static String _safeName(String s) {
    final t = s
        .replaceAll(RegExp(r'[^A-Za-z0-9ÇĞİÖŞÜçğıöşü_-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return t.isEmpty ? 'proje' : t;
  }

  /// Geliştirme Modu: seçilen ZIP'i, kullanıcının girdiği tur sayısı kadar şu döngüyle geliştirir:
  /// 1. AI kodu inceleyip hataları raporlar → 2. AI raporu yama olarak uygular → yeni TAM ZIP yazılır
  /// ve bir sonraki turun girdisi olur. Tur sayısı dolunca (veya iptalde) durur; sonsuz döngü yoktur.
  /// Her tur modelin bağlamına sığan küçük bir kod parçasını ([DevPlanner]) işler.
  Future<void> startDevMode(DevModeConfig cfg) async {
    if (state.running || state.cancelling) return;
    if (ref.read(chatBusyProvider)) {
      _notice('Sohbet modu yanıt üretiyor; bitince Geliştirme Modu\'nu başlat.');
      return;
    }
    GgufModel? find(String id) {
      for (final m in state.models) {
        if (m.id == id) return m;
      }
      return null;
    }

    final analyst = find(cfg.analystModelId);
    final fixer = find(cfg.fixerModelId);
    if (analyst == null || !analyst.isCached || fixer == null || !fixer.isCached) {
      _notice('Seçilen AI modeli indirilmemiş. Model yöneticisinden indirip tekrar dene.');
      return;
    }
    var total = cfg.rounds < 1 ? 1 : (cfg.rounds > kDevMaxRounds ? kDevMaxRounds : cfg.rounds);

    String saved;
    ProjectSnapshot snap;
    try {
      final dir = await ref.read(storageProvider).projectsDir();
      saved = await ProjectSource.copyInto(dir, cfg.zipPath);
      snap = await ProjectSource.load(saved);
    } catch (e) {
      _notice('Proje ZIP\'i okunamadı: $e');
      return;
    }
    if (!snap.text.keys.any(DevPlanner.eligible)) {
      _notice('ZIP içinde incelenecek Dart/Flutter kaynağı (lib/ veya test/) bulunamadı.');
      return;
    }

    final coverAll = cfg.coverAll;
    final stepLimit = coverAll ? kDevMaxStepsCoverAll : total;
    if (coverAll) {
      // Tahmini adım sayısı; gerçek sayı yeniden denetimlerle biraz farklı olabilir (aşılırsa güncellenir).
      final est = DevPlanner.estimateSteps(
        snap,
        chunkChars: ref.read(runnerProvider).devChunkChars(),
      );
      total = est > kDevMaxStepsCoverAll ? kDevMaxStepsCoverAll : est;
    }

    final ct = CancelToken();
    _cancel = ct;
    _active.clear();
    _lastStep = 0;
    _buf.clear();
    _lastTransferPreview = '';
    ref.read(liveTokensProvider.notifier).state = '';
    final analystAgent = AgentConfig(
      id: 'dev-analyst',
      order: 1,
      name: '1. AI (Hata Bulucu)',
      mode: AgentMode.generator,
      modelId: analyst.id,
      systemPrompt: DevPrompts.analystSystem,
      userPrompt: '',
      inference: InferenceSettings.precise,
    );
    final fixerAgent = AgentConfig(
      id: 'dev-fixer',
      order: 2,
      name: '2. AI (Düzeltici)',
      mode: AgentMode.generator,
      modelId: fixer.id,
      systemPrompt: DevPrompts.fixerSystem,
      userPrompt: '',
      inference: InferenceSettings.precise,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final devWf = Workflow(
      id: 'dev-mode',
      title: 'Geliştirme Modu',
      description: 'Hata bul → düzelt → ZIP, $total tur.',
      targetFormat: OutputFormat.zip,
      agents: [analystAgent, fixerAgent],
      createdAt: now,
      updatedAt: now,
    );
    state = state.copyWith(
      running: true,
      cancelling: false,
      failed: false,
      status: 'Geliştirme Modu başlıyor…',
      logs: const [],
      clearArtifact: true,
      clearRejected: true,
      clearContextWarning: true,
      agentOutputs: const [],
      dev: DevProgress(
        active: true,
        total: total,
        phase: 'Hazırlanıyor',
        sourceName: snap.name,
      ),
    );
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(const Duration(milliseconds: 40), (_) => _flush());
    _bridge.begin(devWf, state.models);
    await _wakelock(true);

    final runner = ref.read(runnerProvider);
    final cb = _callbacks(ct);
    final planner = DevPlanner();
    final results = <DevRoundResult>[];
    var curPath = saved; // bir sonraki turun girdisi olan en güncel ZIP
    String? prevOutput; // silinebilecek ara ZIP
    String? lastOutput;
    var failStreak = 0;
    try {
      for (var r = 1; r <= stepLimit; r++) {
        if (ct.cancelled) throw const CancelledException();
        if (r > total) {
          // "Tüm projeyi gez": tahmin aşıldı (yeniden denetimler); sayacı gerçeğe uydur.
          total = r;
          _devSet((d) => d.copyWith(total: total));
        }
        final plan = planner.plan(
          snap,
          chunkChars: runner.devChunkChars(),
          wrap: !coverAll,
        );
        if (plan == null) {
          _addLog('Sistem', 'İncelenecek içerik kalmadı; $r. turda durduruldu.', LogType.info);
          break;
        }
        _devSet((d) => d.copyWith(round: r, phase: '1. AI analiz ediyor'));
        state = state.copyWith(
          status: 'Tur $r/$total — 1. AI analiz ediyor: ${plan.labels.join(', ')}',
        );
        _addLog('Tur $r/$total', 'İncelenen: ${plan.labels.join(', ')}', LogType.info);
        try {
          // 1. AI: hataları bul.
          cb.agent(analystAgent.id, AgentStatus.running, 0);
          final raw = await runner.inferOnce(
            agent: analystAgent,
            system: DevPrompts.analystSystem,
            user: DevPrompts.analystUser(snap, plan, r, total),
            models: state.models,
            cb: cb,
            ct: ct,
          );
          cb.agent(analystAgent.id, AgentStatus.completed, 0);
          final report = DevReport.parse(raw, snap, scope: plan.paths);
          if (!report.hasFindings) {
            planner.advance(plan);
            results.add(
              DevRoundResult(
                round: r,
                status: DevRoundStatus.clean,
                reviewed: plan.labels,
                report: raw,
                notes: report.dropped > 0
                    ? ['${report.dropped} bulgu, bu turun kapsamında olmayan/var olmayan dosyaya işaret ettiği için atıldı.']
                    : const [],
              ),
            );
            failStreak = 0;
            _addLog('Tur $r/$total', '1. AI hata bulamadı.', LogType.success);
            _devSet((d) => d.copyWith(results: [...results]));
            continue;
          }
          _addLog('Tur $r/$total', '${report.findings.length} sorun bulundu; 2. AI\'a iletiliyor.', LogType.warning);

          // 2. AI: raporu yama olarak uygula.
          _devSet((d) => d.copyWith(phase: '2. AI düzeltiyor'));
          state = state.copyWith(status: 'Tur $r/$total — 2. AI düzeltiyor (${report.findings.length} sorun)');
          cb.agent(fixerAgent.id, AgentStatus.running, 0);
          final fixOut = await runner.inferOnce(
            agent: fixerAgent,
            system: DevPrompts.fixerSystem,
            user: DevPrompts.fixerUser(plan, report),
            models: state.models,
            cb: cb,
            ct: ct,
          );
          cb.agent(fixerAgent.id, AgentStatus.completed, 0);
          final outcome = await DevPatcher.apply(
            snap: snap,
            plan: plan,
            patches: WorkflowRunner.parsePatches(fixOut),
            reinfer: (prompt) => runner.inferOnce(
              agent: fixerAgent,
              system: DevPrompts.fixerSystem,
              user: prompt,
              models: state.models,
              cb: cb,
              ct: ct,
            ),
          );
          for (final n in outcome.notes) {
            _addLog('Tur $r/$total', n, LogType.warning);
          }
          if (outcome.changed.isEmpty) {
            planner.advance(plan);
            results.add(
              DevRoundResult(
                round: r,
                status: DevRoundStatus.noPatch,
                reviewed: plan.labels,
                findings: report.findings.length,
                report: raw,
                notes: outcome.notes,
              ),
            );
            failStreak = 0;
            _devSet((d) => d.copyWith(results: [...results]));
            continue;
          }

          // Yeni TAM ZIP: değişen dosyalar tabanın üstüne bindirilir (sürüm +1, CHANGELOG güncellenir).
          final built = buildProjectZip(
            files: outcome.changed,
            rawContent: raw,
            title: snap.name,
            task: 'Geliştirme Modu tur $r/$total: ${report.findings.length} sorun düzeltildi',
            base: snap,
          );
          final outDir = await ref.read(storageProvider).outputsDir();
          final fileName =
              '${_safeName(snap.name)}_gelistirme_t${r}_${DateTime.now().millisecondsSinceEpoch}.zip';
          final outPath = '${outDir.path}/$fileName';
          await File(outPath).writeAsBytes(built.bytes, flush: true);
          if (ct.cancelled) {
            try {
              await File(outPath).delete();
            } catch (_) {}
            throw const CancelledException();
          }
          if (prevOutput != null) {
            try {
              await File(prevOutput).delete(); // yalnızca bizim ürettiğimiz ara ZIP silinir
            } catch (_) {}
          }
          prevOutput = outPath;
          lastOutput = outPath;
          curPath = outPath;
          snap = await ProjectSource.load(curPath);
          planner.advance(plan, changedPaths: outcome.changed.keys.toSet());
          results.add(
            DevRoundResult(
              round: r,
              status: DevRoundStatus.fixed,
              reviewed: plan.labels,
              findings: report.findings.length,
              changedFiles: outcome.changed.keys.toList()..sort(),
              report: raw,
              notes: outcome.notes,
            ),
          );
          failStreak = 0;
          _addLog('Tur $r/$total', 'ZIP güncellendi: ${outcome.changed.keys.join(', ')}', LogType.success);
          _devSet((d) => d.copyWith(results: [...results], zipPath: outPath));
        } on CancelledException {
          rethrow;
        } on ModelFileException {
          rethrow;
        } catch (e) {
          // Tek turun hatası (ör. think-only/boş çıktı) döngüyü bitirmez; art arda iki hata bitirir.
          cb.agent(analystAgent.id, AgentStatus.error, 0);
          cb.agent(fixerAgent.id, AgentStatus.error, 0);
          planner.advance(plan);
          failStreak++;
          results.add(
            DevRoundResult(
              round: r,
              status: DevRoundStatus.failed,
              reviewed: plan.labels,
              notes: ['$e'],
            ),
          );
          _addLog('Tur $r/$total', 'Tur başarısız: $e', LogType.error);
          _devSet((d) => d.copyWith(results: [...results]));
          if (failStreak >= 2) {
            throw StateError('Art arda iki turda model geçerli çıktı üretemedi: $e');
          }
        }
      }
      if (ct.cancelled) throw const CancelledException();

      // Bitiş: en güncel ZIP, sonuç ekranında Aç/İndir olarak sunulur.
      final fixedCount = results.where((x) => x.status == DevRoundStatus.fixed).length;
      String describe(DevRoundResult x) {
        switch (x.status) {
          case DevRoundStatus.fixed:
            return 'düzeltildi (${x.changedFiles.join(', ')})';
          case DevRoundStatus.clean:
            return 'hata bulunamadı';
          case DevRoundStatus.noPatch:
            return 'hata bulundu, yama uygulanamadı';
          case DevRoundStatus.failed:
            return 'başarısız';
        }
      }

      final summary = StringBuffer()
        ..writeln('Geliştirme Modu: ${results.length}/$total tur tamamlandı, $fixedCount turda düzeltme yapıldı.')
        ..writeln();
      for (final x in results) {
        summary.writeln('Tur ${x.round}: ${describe(x)}');
      }
      final finalZip = lastOutput;
      Artifact? art;
      if (finalZip != null) {
        art = Artifact(
          format: OutputFormat.zip,
          filename: finalZip.split(RegExp(r'[\\/]')).last,
          path: finalZip,
          size: await File(finalZip).length(),
          preview: summary.toString(),
          tree: [
            for (final x in results)
              for (final c in x.changedFiles) TreeEntry(c, 0),
          ],
        );
      }
      _devSet((d) => d.copyWith(active: false, phase: 'Tamamlandı', zipPath: lastOutput));
      final allFailed = results.isNotEmpty && results.every((x) => x.status == DevRoundStatus.failed);
      state = state.copyWith(
        artifact: art,
        failed: allFailed,
        status: allFailed
            ? 'Geliştirme tamamlanamadı: hiçbir tur geçerli çıktı üretemedi. Günlüğe bak.'
            : fixedCount > 0
            ? 'Geliştirme tamamlandı: $fixedCount turda düzeltme yapıldı. ZIP hazır.'
            : 'Geliştirme tamamlandı: hiçbir turda uygulanabilir düzeltme çıkmadı.',
      );
      _addLog('Sistem', summary.toString().trim(), LogType.success);
    } on CancelledException {
      _devSet((d) => d.copyWith(active: false, phase: 'İptal edildi', zipPath: lastOutput));
      _onCancelled();
    } catch (e) {
      if (ct.cancelled) {
        _devSet((d) => d.copyWith(active: false, phase: 'İptal edildi', zipPath: lastOutput));
        _onCancelled();
      } else {
        for (final id in _active) {
          _setAgentState(id, AgentStatus.error, 0);
        }
        _active.clear();
        if (e is ModelFileException) {
          state = state.copyWith(
            models: [
              for (final x in state.models)
                x.localPath == e.path ? x.withCache(null, null) : x,
            ],
          );
        }
        _devSet((d) => d.copyWith(active: false, phase: 'Hata', zipPath: lastOutput));
        state = state.copyWith(failed: true, status: 'Hata: $e');
        _addLog('Sistem', '$e', LogType.error);
      }
    } finally {
      _flush();
      _flushTimer?.cancel();
      _flushTimer = null;
      _buf.clear();
      _cancel = null;
      _active.clear();
      _bridge.end(failed: state.failed, cancelled: ct.cancelled);
      await _wakelock(false);
      state = state.copyWith(running: false, cancelling: false);
    }
  }

  /// Seçilen ZIP akış paketini (workflow.json + prompts/configs) yeni bir akış olarak ekler.
  Future<void> importWorkflowZip(String path) async {
    if (state.running || state.cancelling) return;
    try {
      final pkg = await WorkflowZipService.readWorkflowZip(path);
      final wf = WorkflowPackageMapper.toWorkflow(
        pkg,
        catalog: state.models.isEmpty ? modelCatalog : state.models,
        primaryId: state.defaultPick?.primaryId,
        reviewerId: state.defaultPick?.reviewerId,
      );
      state = state.copyWith(
        workflows: [wf, ...state.workflows],
        currentId: wf.id,
        selectedAgentId: wf.agents.first.id,
      );
      _persist();
      _notice('Akış yüklendi: ${wf.title} (${wf.agents.length} adım)');
    } on ZipValidationException catch (e) {
      _notice('$e');
    } catch (e) {
      _notice('ZIP yüklenemedi: $e');
    }
  }

  /// Dosya seçiciyle .zip seçtirir ve [importWorkflowZip] ile içe aktarır.
  Future<void> pickAndImportWorkflowZip() async {
    if (state.running || state.cancelling) return;
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    await importWorkflowZip(path);
  }

  /// Aktif akışı standart ZIP paketi olarak `outputs/` klasörüne yazar; dosya yolunu döner.
  Future<String?> exportWorkflowZip() async {
    final wf = state.current;
    if (wf == null) return null;
    try {
      final pkg = WorkflowPackageMapper.fromWorkflow(
        wf,
        state.models.isEmpty ? modelCatalog : state.models,
      );
      final bytes = await WorkflowZipService.exportWorkflowToZip(pkg);
      final dir = await ref.read(storageProvider).outputsDir();
      final safe = wf.title
          .replaceAll(RegExp(r'[^A-Za-z0-9ÇĞİÖŞÜçğıöşü_-]+'), '_')
          .replaceAll(RegExp(r'^_+|_+$'), '');
      final name = '${safe.isEmpty ? 'akis' : safe}_akis.zip';
      final path = '${dir.path}/$name';
      await File(path).writeAsBytes(bytes, flush: true);
      _notice('Akış paketi kaydedildi: $name');
      return path;
    } catch (e) {
      _notice('Akış dışa aktarılamadı: $e');
      return null;
    }
  }

  /// "Yine de indir": doğrulamadan geçemeyen çıktıyı, doğrulamayı atlayarak dosyaya çevirir.
  /// İçerik beklenen biçime uymayabilir; kullanıcı bunu bilerek seçer.
  Future<void> downloadAnyway() async {
    final r = state.rejected;
    if (r == null || state.running || state.cancelling) return;
    try {
      final art = await ref
          .read(runnerProvider)
          .buildAnyway(
            format: r.format,
            title: r.title,
            content: r.content,
            task: _workflowTask(r.workflowId),
            baseProject: _workflowBase(r.workflowId),
          );
      state = state.copyWith(
        artifact: art,
        clearRejected: true,
        failed: false,
        status:
            'Dosya doğrulama atlanarak oluşturuldu; içerik beklenen biçime uymayabilir.',
      );
      _addLog(
        'Sistem',
        'Doğrulanamayan çıktı kullanıcı isteğiyle dosyaya çevrildi: ${art.filename} (${r.summary})',
        LogType.warning,
      );
    } catch (e) {
      state = state.copyWith(status: 'Dosya oluşturulamadı: $e');
      _addLog('Sistem', 'Yine de indir başarısız: $e', LogType.error);
    }
  }

  void _onCancelled() {
    for (final id in _active) {
      _setAgentState(id, AgentStatus.idle, 0);
    }
    _active.clear();
    _flush(); // iptalden önce gelen tokenlar canlı sekmede kalsın; sonrası zaten yok sayılıyor
    final step = _lastStep > 0
        ? '$_lastStep. AI adımında'
        : 'hazırlık aşamasında';
    state = state.copyWith(
      status: 'İşlem kullanıcı tarafından iptal edildi.',
      clearArtifact: true,
    );
    _addLog('Sistem', 'Akış iptal edildi ($step)', LogType.warning);
  }

  /// Çalışan akışı iptal eder. Çalışmıyorsa veya iptal sürüyorsa hiçbir şey yapmaz.
  void cancel() {
    final ct = _cancel;
    if (ct == null || !state.running || state.cancelling) return;
    state = state.copyWith(cancelling: true, status: 'İptal ediliyor…');
    ct.cancel(); // motoru durdurma (engine.stop) iptali fark eden WorkflowRunner._infer içinde yapılır
  }
}
