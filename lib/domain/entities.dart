import 'inference_settings.dart';

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

enum AgentMode { generator, debugger, converter, export }

enum OutputFormat { zip, pdf, pptx, docx, txt }

enum AgentStatus { idle, running, looping, completed, error }

enum LogType { info, loop, success, warning, error }

enum ChatTemplate { chatml, llama3, mistral, phi3, alpaca, deepseek }

extension OutputFormatX on OutputFormat {
  String get modeLabel => switch (this) {
    OutputFormat.zip => 'ZIP Kodlama',
    OutputFormat.pdf => 'PDF Üretimi',
    OutputFormat.pptx => 'PPTX Sunumu',
    OutputFormat.docx => 'DOCX Raporu',
    OutputFormat.txt => 'TXT Raporu',
  };

  String get product => switch (this) {
    OutputFormat.zip => 'ZIP Arşivi',
    OutputFormat.pdf => 'PDF Belgesi',
    OutputFormat.pptx => 'PPTX Sunumu',
    OutputFormat.docx => 'DOCX Raporu',
    OutputFormat.txt => 'TXT Metin Çıktısı',
  };
}

extension AgentModeX on AgentMode {
  String get label => switch (this) {
    AgentMode.generator => 'Üretici (Generator)',
    AgentMode.debugger => 'Hata Ayıklama (Debugging)',
    AgentMode.converter => 'Dönüştürücü (Converter)',
    AgentMode.export => 'Nihai Çıktı (Export)',
  };
}

class AttachedFile {
  final String id;
  final String name;
  final String content;
  final int size;

  const AttachedFile({
    required this.id,
    required this.name,
    required this.size,
    required this.content,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'size': size,
    'content': content,
  };

  factory AttachedFile.fromJson(Map<String, dynamic> j) => AttachedFile(
    id: j['id'] as String,
    name: j['name'] as String,
    size: j['size'] as int,
    content: j['content'] as String,
  );
}

class AgentConfig {
  final String id;
  final int order;
  final String name;
  final AgentMode mode;
  final String modelId;
  final String systemPrompt;
  final String userPrompt;
  final int maxLoops;
  final bool optional;
  final List<AttachedFile> attachedFiles;
  final AgentStatus status;
  final int currentLoop;

  /// Bu ajanın model çıkarım ayarları (sıcaklık, top-p, tekrar cezası, azami token).
  final InferenceSettings inference;

  const AgentConfig({
    required this.id,
    required this.order,
    required this.name,
    required this.mode,
    required this.modelId,
    required this.systemPrompt,
    required this.userPrompt,
    this.maxLoops = 3,
    this.optional = false,
    this.attachedFiles = const [],
    this.status = AgentStatus.idle,
    this.currentLoop = 0,
    this.inference = const InferenceSettings(),
  });

  AgentConfig copyWith({
    int? order,
    String? name,
    AgentMode? mode,
    String? modelId,
    String? systemPrompt,
    String? userPrompt,
    int? maxLoops,
    bool? optional,
    List<AttachedFile>? attachedFiles,
    AgentStatus? status,
    int? currentLoop,
    InferenceSettings? inference,
  }) => AgentConfig(
    id: id,
    order: order ?? this.order,
    name: name ?? this.name,
    mode: mode ?? this.mode,
    modelId: modelId ?? this.modelId,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    userPrompt: userPrompt ?? this.userPrompt,
    maxLoops: maxLoops ?? this.maxLoops,
    optional: optional ?? this.optional,
    attachedFiles: attachedFiles ?? this.attachedFiles,
    status: status ?? this.status,
    currentLoop: currentLoop ?? this.currentLoop,
    inference: inference ?? this.inference,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'order': order,
    'name': name,
    'mode': mode.name,
    'modelId': modelId,
    'systemPrompt': systemPrompt,
    'userPrompt': userPrompt,
    'maxLoops': maxLoops,
    'optional': optional,
    'attachedFiles': attachedFiles.map((e) => e.toJson()).toList(),
    // Varsayılan ayarlar yazılmaz: eski kayıt/dışa aktarım biçimi değişmez.
    if (!inference.isDefault) 'inference': inference.toJson(),
  };

  factory AgentConfig.fromJson(Map<String, dynamic> j) => AgentConfig(
    id: j['id'] as String,
    order: j['order'] as int,
    name: j['name'] as String,
    mode: _enum(AgentMode.values, j['mode'], AgentMode.generator),
    modelId: j['modelId'] as String,
    systemPrompt: j['systemPrompt'] as String,
    userPrompt: j['userPrompt'] as String,
    maxLoops: (j['maxLoops'] as int?) ?? 3,
    optional: (j['optional'] as bool?) ?? false,
    attachedFiles: ((j['attachedFiles'] as List?) ?? const [])
        .map((e) => AttachedFile.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    inference: j['inference'] is Map
        ? InferenceSettings.fromJson(Map<String, dynamic>.from(j['inference'] as Map))
        : const InferenceSettings(),
  );
}

class Workflow {
  final String id;
  final String title;
  final String description;

  /// Kullanıcının asıl isteği (Görev / İstek). Tüm ajanların prompt'una bağlayıcı blok olarak girer.
  final String task;
  final OutputFormat targetFormat;
  final List<AgentConfig> agents;
  final int createdAt;
  final int updatedAt;

  /// Geliştirilecek mevcut proje (kendini geliştirme / proje düzenleme). `asset:self` Kripton'un
  /// uygulamaya gömülü kaynağıdır; aksi hâlde uygulama deposuna kopyalanmış bir ZIP'in yoludur.
  /// Doluysa ajanlara proje özeti verilir ve çıktı bu projenin üstüne bindirilip tam ZIP yazılır.
  final String? baseProject;

  const Workflow({
    required this.id,
    required this.title,
    required this.description,
    this.task = '',
    required this.targetFormat,
    required this.agents,
    required this.createdAt,
    required this.updatedAt,
    this.baseProject,
  });

  Workflow copyWith({
    String? title,
    String? description,
    String? task,
    OutputFormat? targetFormat,
    List<AgentConfig>? agents,
    int? updatedAt,
    String? baseProject,
  }) => Workflow(
    id: id,
    title: title ?? this.title,
    description: description ?? this.description,
    task: task ?? this.task,
    targetFormat: targetFormat ?? this.targetFormat,
    agents: agents ?? this.agents,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    baseProject: baseProject ?? this.baseProject,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'task': task,
    'targetFormat': targetFormat.name,
    'agents': agents.map((e) => e.toJson()).toList(),
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    if (baseProject != null) 'baseProject': baseProject,
  };

  factory Workflow.fromJson(Map<String, dynamic> j) {
    final description = (j['description'] as String?) ?? '';
    // Eski kayıtlarda 'task' yoktur: açıklama (yoksa boş metin) görev olarak kullanılır.
    final task = j['task'] is String ? j['task'] as String : description;
    return Workflow(
      id: j['id'] as String,
      title: j['title'] as String,
      description: description,
      task: task,
      targetFormat: _enum(
        OutputFormat.values,
        j['targetFormat'],
        OutputFormat.txt,
      ),
      agents: (j['agents'] as List)
          .map((e) => AgentConfig.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      createdAt: j['createdAt'] as int,
      updatedAt: j['updatedAt'] as int,
      baseProject: j['baseProject'] as String?,
    );
  }
}

/// GGUF metadata'sından KV/FFN hesabı için gereken mimari değerleri (model kartı = GGUF anahtarları).
/// Formül [GgufMeta.kvBytesPerToken] ile aynıdır (F16 K+V önbelleği, token başına bayt).
class GgufArch {
  const GgufArch({
    required this.blockCount,
    required this.embeddingLength,
    required this.attentionHeadCount,
    required this.attentionHeadCountKv,
    required this.feedForwardLength,
  });

  final int blockCount;
  final int embeddingLength;
  final int attentionHeadCount;
  final int attentionHeadCountKv;
  final int feedForwardLength;

  int get kvBytesPerToken =>
      2 *
      blockCount *
      ((embeddingLength * attentionHeadCountKv) ~/ attentionHeadCount) *
      2;
}

/// Katalogdaki RAM tahmini: dosya boyutu + KV(ctx) + sabit 0.5 GB (ondalık GB, 1 GB = 1e9 bayt).
const kRamEstimateCtx = 4096;
const kRamOverheadBytes = 500 * 1000 * 1000;

double estimateRamGb({
  required int fileBytes,
  required int kvBytesPerToken,
  int ctx = kRamEstimateCtx,
  int overheadBytes = kRamOverheadBytes,
}) => (fileBytes + kvBytesPerToken * ctx + overheadBytes) / 1e9;

class GgufModel {
  final String id;
  final String name;
  final String family;
  final String parameters;
  final String quantization;
  final String tokensPerSec;
  final String quality;
  final String url;
  final String fileName;
  final ChatTemplate template;
  final String? localPath;
  final String? sha256;

  /// İndirilmiş dosyanın gerçek boyutu (yalnızca önbellekteyken).
  final int? sizeBytes;

  /// Hugging Face'in bildirdiği yaklaşık indirme boyutu (bayt). [arch] ile birlikte verilirse
  /// [sizeGb] ve [ramGb] bundan TÜRETİLİR (elle yazılmaz).
  final int? catalogBytes;
  final GgufArch? arch;
  final double? _sizeGb;
  final double? _ramGb;

  const GgufModel({
    required this.id,
    required this.name,
    required this.family,
    required this.parameters,
    required this.quantization,
    double? sizeGb,
    double? ramGb,
    required this.tokensPerSec,
    required this.quality,
    required this.url,
    required this.fileName,
    required this.template,
    this.localPath,
    this.sha256,
    this.sizeBytes,
    this.catalogBytes,
    this.arch,
  }) : _sizeGb = sizeGb,
       _ramGb = ramGb,
       assert(sizeGb != null || catalogBytes != null),
       assert(ramGb != null || (catalogBytes != null && arch != null));

  double get sizeGb => _sizeGb ?? catalogBytes! / 1e9;

  double get ramGb => (catalogBytes != null && arch != null)
      ? estimateRamGb(
          fileBytes: catalogBytes!,
          kvBytesPerToken: arch!.kvBytesPerToken,
        )
      : _ramGb!;

  bool get isCached => localPath != null;

  GgufModel withCache(String? path, String? hash, {int? sizeBytes}) =>
      GgufModel(
        id: id,
        name: name,
        family: family,
        parameters: parameters,
        quantization: quantization,
        sizeGb: _sizeGb,
        ramGb: _ramGb,
        tokensPerSec: tokensPerSec,
        quality: quality,
        url: url,
        fileName: fileName,
        template: template,
        localPath: path,
        sha256: hash,
        sizeBytes: sizeBytes,
        catalogBytes: catalogBytes,
        arch: arch,
      );
}

class ExecutionLog {
  final String time;
  final String agentName;
  final String message;
  final LogType type;

  const ExecutionLog({
    required this.time,
    required this.agentName,
    required this.message,
    required this.type,
  });
}

enum AgentOutputStatus { ok, corrected, skipped, failed }

/// Bir ajanın (veya çıktı doğrulayıcının) ürettiği çıktının kullanıcıya gösterilen özeti.
/// Sonuç ekranındaki "Ajan çıktıları" bölümü bunları listeler; böylece sorunun hangi adımda
/// çıktığı görülebilir.
class AgentOutput {
  /// Çıktı doğrulayıcı için sabit kimlik (gerçek bir ajan değildir).
  static const String validatorId = 'validator';

  /// Önizleme metni en çok bu kadar karakter tutar (bellek ve ekran için).
  static const int previewLimit = 1500;

  final String agentId;
  final int order;
  final String name;

  /// Kısa rol etiketi (ör. GENERATOR, CONVERTER, DOĞRULAYICI).
  final String role;
  final AgentOutputStatus status;

  /// Çıktının tam uzunluğu (karakter); [preview] kırpılmış olabilir.
  final int chars;
  final String preview;

  /// Hata, doğrulama sorunları veya düzeltme bilgisi.
  final String? note;

  const AgentOutput({
    required this.agentId,
    required this.order,
    required this.name,
    required this.role,
    required this.status,
    this.chars = 0,
    this.preview = '',
    this.note,
  });

  factory AgentOutput.of({
    required String agentId,
    required int order,
    required String name,
    required String role,
    required AgentOutputStatus status,
    String content = '',
    String? note,
  }) {
    final text = content.trim();
    return AgentOutput(
      agentId: agentId,
      order: order,
      name: name,
      role: role,
      status: status,
      chars: text.length,
      preview: text.length > previewLimit ? '${text.substring(0, previewLimit)}\n…' : text,
      note: note,
    );
  }

  bool get isValidator => agentId == validatorId;

  bool get isProblem => status == AgentOutputStatus.failed;
}

class TreeEntry {
  final String path;
  final int size;

  const TreeEntry(this.path, this.size);
}

class Artifact {
  final OutputFormat format;
  final String filename;
  final String path;
  final int size;
  final String preview;
  final List<TreeEntry> tree;

  const Artifact({
    required this.format,
    required this.filename,
    required this.path,
    required this.size,
    required this.preview,
    this.tree = const [],
  });

  String get sizeLabel {
    if (size < 1024) return '$size B';
    if (size < 1048576) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1048576).toStringAsFixed(2)} MB';
  }
}
