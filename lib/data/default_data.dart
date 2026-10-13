import '../domain/entities.dart';

// GGUF anahtarları (qwen2.block_count / embedding_length / attention.head_count[_kv] / feed_forward_length).
// Katman ve head sayıları Qwen model kartlarından doğrulandı: 1.5B 28 kat. 12Q/2KV, 3B 36 kat., 7B 28 kat. 28Q/4KV.
const _qwenCoder1_5bArch = GgufArch(
  blockCount: 28,
  embeddingLength: 1536,
  attentionHeadCount: 12,
  attentionHeadCountKv: 2,
  feedForwardLength: 8960,
);
const _qwenCoder3bArch = GgufArch(
  blockCount: 36,
  embeddingLength: 2048,
  attentionHeadCount: 16,
  attentionHeadCountKv: 2,
  feedForwardLength: 11008,
);
const _qwenCoder7bArch = GgufArch(
  blockCount: 28,
  embeddingLength: 3584,
  attentionHeadCount: 28,
  attentionHeadCountKv: 4,
  feedForwardLength: 18944,
);

const modelCatalog = <GgufModel>[
  GgufModel(
    id: 'qwen-2.5-coder-7b-q4km',
    name: 'Qwen 2.5 Coder 7B (Instruct)',
    family: 'Qwen',
    parameters: '7B',
    quantization: 'Q4_K_M',
    sizeGb: 4.1,
    ramGb: 4.8,
    tokensPerSec: '18 - 24 tok/s',
    quality: 'Optimum Denge (Varsayılan Önerilen)',
    url:
        'https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf',
    fileName: 'qwen2.5-coder-7b-q4_k_m.gguf',
    template: ChatTemplate.chatml,
    arch: _qwenCoder7bArch,
  ),
  GgufModel(
    id: 'deepseek-r1-distill-7b-q4km',
    name: 'DeepSeek R1 Distill Qwen 7B',
    family: 'DeepSeek',
    parameters: '7B',
    quantization: 'Q4_K_M',
    sizeGb: 4.1,
    ramGb: 4.8,
    tokensPerSec: '17 - 23 tok/s',
    quality: 'Yüksek Mantıksal ve Adım Adım Muhakeme',
    url:
        'https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf',
    fileName: 'deepseek-r1-distill-qwen-7b-q4_k_m.gguf',
    template: ChatTemplate.deepseek,
  ),
  GgufModel(
    id: 'mistral-7b-instruct-v03-q5km',
    name: 'Mistral 7B Instruct v0.3',
    family: 'Mistral',
    parameters: '7B',
    quantization: 'Q5_K_M',
    sizeGb: 4.8,
    ramGb: 5.6,
    tokensPerSec: '12 - 16 tok/s',
    quality: 'Yüksek (Kodlama ve Hata Ayıklama)',
    url:
        'https://huggingface.co/MaziyarPanahi/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3.Q5_K_M.gguf',
    fileName: 'mistral-7b-instruct-v0.3-q5_k_m.gguf',
    template: ChatTemplate.mistral,
  ),
  GgufModel(
    id: 'llama-3.2-3b-q4km',
    name: 'Llama 3.2 3B Instruct',
    family: 'Llama',
    parameters: '3.2B',
    quantization: 'Q4_K_M',
    sizeGb: 2.1,
    ramGb: 2.7,
    tokensPerSec: '28 - 36 tok/s',
    quality: 'Düşük RAM ve Hızlı Mobil Çıkarım',
    url:
        'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    fileName: 'llama-3.2-3b-instruct-q4_k_m.gguf',
    template: ChatTemplate.llama3,
  ),
  GgufModel(
    id: 'qwen-2.5-coder-7b-q5km',
    name: 'Qwen 2.5 Coder 7B (Hassas Hata Ayıklama)',
    family: 'Qwen',
    parameters: '7B',
    quantization: 'Q5_K_M',
    sizeGb: 4.8,
    ramGb: 5.6,
    tokensPerSec: '12 - 16 tok/s',
    quality: 'Yüksek Hassasiyet (Kod Analizi)',
    url:
        'https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q5_k_m.gguf',
    fileName: 'qwen2.5-coder-7b-q5_k_m.gguf',
    template: ChatTemplate.chatml,
    arch: _qwenCoder7bArch,
  ),
  GgufModel(
    id: 'phi-3.5-mini-3.8b-q4km',
    name: 'Phi-3.5 Mini Instruct 3.8B',
    family: 'Phi',
    parameters: '3.8B',
    quantization: 'Q4_K_M',
    sizeGb: 2.3,
    ramGb: 2.9,
    tokensPerSec: '25 - 32 tok/s',
    quality: 'Dengeli Dokümantasyon & Özetleme',
    url:
        'https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf',
    fileName: 'phi-3.5-mini-instruct-q4_k_m.gguf',
    template: ChatTemplate.phi3,
  ),
  // --- Düşük RAM seçenekleri (sizeGb/ramGb catalogBytes + arch'tan türetilir) ---
  // catalogBytes: Hugging Face dosya sayfasındaki boyut (ondalık GB'den yuvarlanmış; indirme sırasında
  // sunucunun bildirdiği kesin boyutla doğrulanır).
  GgufModel(
    id: 'qwen-2.5-coder-3b-q4km',
    name: 'Qwen 2.5 Coder 3B (Instruct)',
    family: 'Qwen',
    parameters: '3B',
    quantization: 'Q4_K_M',
    catalogBytes: 1930000000,
    arch: _qwenCoder3bArch,
    tokensPerSec: 'tahmini 28 - 36 tok/s',
    quality: 'Düşük RAM: 7B\'ye göre yaklaşık yarı RAM, kodlama odaklı',
    url:
        'https://huggingface.co/bartowski/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf',
    fileName: 'Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf',
    template: ChatTemplate.chatml,
  ),
  GgufModel(
    id: 'qwen-2.5-coder-1.5b-q4km',
    name: 'Qwen 2.5 Coder 1.5B (Instruct)',
    family: 'Qwen',
    parameters: '1.5B',
    quantization: 'Q4_K_M',
    catalogBytes: 986000000,
    arch: _qwenCoder1_5bArch,
    tokensPerSec: 'tahmini 45 - 60 tok/s',
    quality: 'En düşük RAM: basit kod/özet görevleri, kalite 7B\'nin altında',
    url:
        'https://huggingface.co/bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf',
    fileName: 'Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf',
    template: ChatTemplate.chatml,
  ),
  GgufModel(
    id: 'qwen-2.5-coder-7b-iq4xs',
    name: 'Qwen 2.5 Coder 7B (IQ4_XS, hafif)',
    family: 'Qwen',
    parameters: '7B',
    quantization: 'IQ4_XS',
    catalogBytes: 4220000000,
    arch: _qwenCoder7bArch,
    tokensPerSec: 'tahmini 15 - 20 tok/s',
    quality:
        'RAM kazancı küçüktür: dosya Q4_K_S\'ten yalnızca 0.24 GB küçük; 7B\'nin bellek tabanı yüksek kalır. IQ4_XS ARM CPU\'da K-kuantlardan yavaş olabilir.',
    url:
        'https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-IQ4_XS.gguf',
    fileName: 'Qwen2.5-Coder-7B-Instruct-IQ4_XS.gguf',
    template: ChatTemplate.chatml,
  ),
];

/// Katalogdaki tahmini tok/s metni yerine gerçek ölçüm varsa onu göster ([measured] PerfLog.measuredLabel çıktısı).
String tokensLabel(GgufModel m, String? measured) => measured ?? m.tokensPerSec;

const _qwen = 'qwen-2.5-coder-7b-q4km';
const _deep = 'deepseek-r1-distill-7b-q4km';

// Hazır akışların ÖRNEK görevleri: kullanıcı ana ekrandan değiştirebilir. Ajan promptları göreve bağımlı değildir;
// görev, çalıştırma sırasında her ajanın prompt'unun başına "KULLANICI GÖREVİ" bloğu olarak eklenir.
const _taskZip =
    'Android NDK için Vulkan destekli bellek güvenli bir yerel tampon yöneticisi (NativeBufferManager) yaz.';
const _taskPdf =
    'Adreno 730 ve Mali-G715 üzerinde Q4_K_M ve Q5_K_M kuantizasyonlarının tok/sn ve termal kısıtlama (thermal throttling) metriklerini analiz eden bir rapor hazırla.';
const _taskPptx =
    'Kripton yerel ajan orkestrasyonu, mmap bellek yönetimi ve FFI katmanı için 5 slaytlık profesyonel sunum taslağı hazırla.';

AgentConfig _agent(
  String wf,
  int order,
  String name,
  AgentMode mode,
  String modelId,
  String system,
  String user, {
  int loops = 3,
  bool optional = false,
}) => AgentConfig(
  id: '$wf-a$order',
  order: order,
  name: name,
  mode: mode,
  modelId: modelId,
  systemPrompt: system,
  userPrompt: user,
  maxLoops: loops,
  optional: optional,
);

/// Model atama kuralı: üretici ve dönüştürücü/export ajanları talimat uyan modeli ([primaryId], Qwen)
/// kullanır; akıl yürütme modeli ([reviewerId], DeepSeek R1) YALNIZCA hata denetçisi (debugger) olur.
/// R1 <think> bütçesini aşınca anlamsız çıktı üretebildiği için hiçbir akışta 1. ajan (üretici) değildir.
/// [primaryId]/[reviewerId] verilmezse (RAM bilinmiyor) eski varsayılanlar: Qwen 7B + DeepSeek R1 7B.
List<Workflow> defaultWorkflows({String? primaryId, String? reviewerId}) {
  final primary = primaryId ?? _qwen;
  final reviewer = reviewerId ?? _deep;
  final now = DateTime.now().millisecondsSinceEpoch;
  return [
    Workflow(
      id: 'wf-mobile-debugging-zip',
      title: 'Mobil GGUF Hata Ayıklama & ZIP Paketleme Akışı',
      description:
          '1. Ajan kod üretir, 2. Ajan hata ayıklar (Loop Modu), 3. Ajan test edilmiş kodu ZIP arşivine paketler.',
      task: _taskZip,
      targetFormat: OutputFormat.zip,
      createdAt: now,
      updatedAt: now,
      agents: [
        _agent(
          'wf-zip',
          1,
          '1. AI (Kod Üretici - Generator)',
          AgentMode.generator,
          primary,
          'Sen uzman bir mobil sistem ve C++/Dart yazılımcısısın. İstenilen modülü eksiksiz, üretim kalitesinde kodla. Her dosyayı ayrı bir kod bloğunda ver ve dosya yolunu bloğun hemen üstünde ayrı bir satırda yaz.',
          'Yukarıdaki KULLANICI GÖREVİ\'ni yerine getir: istenen modülü kodla.',
        ),
        _agent(
          'wf-zip',
          2,
          '2. AI (Hata Denetleyici - Debugger Loop)',
          AgentMode.debugger,
          reviewer,
          'Gelen kodu bellek sızıntısı, eşzamanlılık ve derleme hataları açısından katı bir şekilde denetle. Eğer hata bulursan "[STATUS: ERROR] Hata detayı: ..." formatında yaz. Hata yoksa "[STATUS: SUCCESS]" yaz.',
          'Yukarıdaki KULLANICI GÖREVİ\'ne göre 1. Ajanın ürettiği kodu derinlemesine analiz et; görevden sapma veya hata varsa bildir.',
        ),
        _agent(
          'wf-zip',
          3,
          '3. AI (ZIP Paketleyici - Export)',
          AgentMode.export,
          primary,
          'Önceki ajanın onaylanmış kodunu yalnızca mevcut biçimini koruyarak aktar. İçeriği yeniden yazma, yeni dosya veya bilgi ekleme.',
          'Önceki ajan çıktısını aynen aktar; biçimlendirme gerekirse yalnızca biçimlendir.',
          optional: true,
        ),
      ],
    ),
    Workflow(
      id: 'wf-vulkan-report-pdf',
      title: 'Android NDK Vulkan Performans Raporu & PDF',
      description:
          'Adreno GPU üzerinde Vulkan çıkarım metriklerini analiz eden ve biçimlendirilmiş PDF raporu üreten akış.',
      task: _taskPdf,
      targetFormat: OutputFormat.pdf,
      createdAt: now - 1,
      updatedAt: now - 1,
      agents: [
        _agent(
          'wf-pdf',
          1,
          '1. AI (Performans Veri Analisti)',
          AgentMode.generator,
          primary,
          'Verilen konuda uzman bir teknik analist ve rapor yazarısın; yalnızca kullanıcının görevindeki konuya odaklanırsın.',
          'Yukarıdaki KULLANICI GÖREVİ\'ni yerine getir: gerekli verileri ve analizi üret.',
        ),
        _agent(
          'wf-pdf',
          2,
          '2. AI (Metrik Doğrulayıcı & Mantık Kontrolü)',
          AgentMode.debugger,
          reviewer,
          'Verilen istatistiksel çıkarımları doğrula. Matematiksel veya mantıksal tutarsızlık varsa [STATUS: ERROR] ver.',
          'Yukarıdaki KULLANICI GÖREVİ\'ne göre 1. Ajanın rakamlarını ve çıkarımlarını doğrula.',
          loops: 2,
        ),
        _agent(
          'wf-pdf',
          3,
          '3. AI (PDF Belge Oluşturucu)',
          AgentMode.converter,
          primary,
          'Önceki ajanın raporunu yalnızca mevcut bilgileri koruyarak biçimlendir; içerik ekleme veya özetleme.',
          'Önceki ajan çıktısını aynen aktar; biçimlendirme gerekirse yalnızca biçimlendir.',
          optional: true,
        ),
      ],
    ),
    Workflow(
      id: 'wf-agent-presentation-pptx',
      title: 'Kripton Çoklu Ajan Mimarisi & PPTX Sunumu',
      description:
          'On-device çoklu ajan sistem mimarisini yapılandırılmış PowerPoint sunum slaytlarına dönüştürür.',
      task: _taskPptx,
      targetFormat: OutputFormat.pptx,
      createdAt: now - 2,
      updatedAt: now - 2,
      agents: [
        _agent(
          'wf-pptx',
          1,
          '1. AI (Mimar & İçerik Üretici)',
          AgentMode.generator,
          primary,
          'Verilen konuda teknik sunum içeriği yazan bir sunum yazarısın; yalnızca kullanıcının görevindeki konuya odaklanırsın.',
          'Yukarıdaki KULLANICI GÖREVİ\'ni yerine getir: sunum taslağını hazırla.',
        ),
        _agent(
          'wf-pptx',
          2,
          '2. AI (Slayt Düzenleyici & Formatlayıcı)',
          AgentMode.converter,
          primary,
          'Metinleri net başlıklara ve madde işaretlerine dönüştür. Her slayt "## Başlık" satırıyla başlasın, altında "- madde" satırları olsun.',
          'Yukarıdaki KULLANICI GÖREVİ\'ni yerine getir: taslağın slayt hiyerarşisini başlık ve madde yapısına uyarla.',
        ),
        _agent(
          'wf-pptx',
          3,
          '3. AI (PPTX İkili Dosya Motoru)',
          AgentMode.export,
          primary,
          'Önceki ajanın slayt içeriğini yalnızca biçimlendir. Bilgiyi değiştirme, ekleme veya özetleme.',
          'Önceki ajan çıktısını aynen aktar; biçimlendirme gerekirse yalnızca biçimlendir.',
          optional: true,
        ),
      ],
    ),
  ];
}

/// Yeni akış şablonu: 1. ajan (üretici) ve 3. ajan (dönüştürücü) [primaryId]; yalnızca 2. ajan
/// (debugger) [reviewerId] kullanır.
List<AgentConfig> starterAgents(
  String wfId,
  OutputFormat f, {
  String? primaryId,
  String? reviewerId,
}) {
  final primary = primaryId ?? _qwen;
  final reviewer = reviewerId ?? _deep;
  final tag = f.name.toUpperCase();
  return [
    _agent(
      wfId,
      1,
      '1. AI (İçerik & Kod Üretici)',
      AgentMode.generator,
      primary,
      'Verilen sistem gereksinimlerini eksiksiz yerine getiren birincil yapay zekâ modelisin.',
      'Yukarıdaki KULLANICI GÖREVİ\'ni yerine getir: ilk taslağı ve gerekli kaynak verileri üret.',
    ),
    _agent(
      wfId,
      2,
      '2. AI (Hata Denetleyici & Döngü)',
      AgentMode.debugger,
      reviewer,
      'Gelen çıktıyı hata ayıklama ve doğrulama testlerinden geçir. Hata durumunda [STATUS: ERROR], hata yoksa [STATUS: SUCCESS] ver.',
      'Yukarıdaki KULLANICI GÖREVİ\'ne göre 1. Ajanın ürettiği mantığı ve kodları denetle; görevden sapma veya hata varsa bildir.',
    ),
    _agent(
      wfId,
      3,
      '3. AI ($tag Dönüştürücü & Paketleyici)',
      f == OutputFormat.zip ? AgentMode.export : AgentMode.converter,
      primary,
      'Çıktıyı $tag biçimine uygun, Markdown başlıkları ve madde işaretleriyle düzenle.',
      'Önceki ajan çıktısını aynen aktar; biçimlendirme gerekirse yalnızca biçimlendir. İçeriği değiştirme veya özetleme.',
      optional: true,
    ),
  ];
}

/// Flutter proje geliştirme hattı: Mimar (plan) → Kodlayıcı (tam dosyalar, ZIP sözleşmesi) → Denetçi.
/// [existingProject] doluysa ajanlara mevcut projenin özeti ek dosya olarak verilir (WorkflowRunner)
/// ve yalnızca değişen dosyalar istenir; çıktı mevcut projenin üstüne bindirilir.
List<AgentConfig> projectAgents(
  String wfId, {
  String? primaryId,
  String? reviewerId,
  bool existingProject = false,
}) {
  final primary = primaryId ?? _qwen;
  final reviewer = reviewerId ?? _deep;
  final planSystem = existingProject
      ? 'Sen kıdemli bir Flutter/Dart mimarısın. Kod YAZMA. "PROJE_OZETI.md" ekindeki dosya ağacına bak ve görev için kısa bir plan çıkar: '
            '(1) Değişecek veya eklenecek dosyalar: her satırda "yol — yapılacak iş". Yalnızca ağaçta olan yolları değiştir, yeni dosyaları lib/ veya test/ altına koy. '
            '(2) Gereken yeni paketler (yoksa "yok"). (3) Bozulabilecek yerler. En çok 25 satır yaz.'
      : 'Sen kıdemli bir Flutter/Dart mimarısın. Kod YAZMA. Görev için kısa bir proje planı çıkar: '
            '(1) Dosya listesi: her satırda "yol — görevi" (pubspec.yaml ve lib/main.dart dahil). '
            '(2) Gereken paketler. (3) Ekran ve veri akışının tek paragraflık özeti. En çok 25 satır yaz.';
  final codeSystem = existingProject
      ? 'Sen uzman bir Flutter/Dart geliştiricisisin (Dart 3, null-safety, Material 3). Önceki ajanın planındaki HER dosyayı baştan sona eksiksiz yaz. '
            'Mevcut kodun stilini, import yollarını, sınıf ve fonksiyon adlarını koru; çalışan kodu bozma. Yalnızca plandaki dosyaları ver. '
            'Uydurma paket API\'si kullanma; kullanılmayan import bırakma; `flutter analyze` temiz çıkmalı.'
      : 'Sen uzman bir Flutter/Dart geliştiricisisin (Dart 3, null-safety, Material 3). Önceki ajanın planındaki HER dosyayı baştan sona eksiksiz yaz. '
            'Çalışır durumda, derlenebilir bir uygulama ver; uydurma paket API\'si kullanma; kullanılmayan import bırakma; `flutter analyze` temiz çıkmalı.';
  return [
    _agent(
      wfId,
      1,
      '1. AI (Flutter Mimarı - Planlayıcı)',
      AgentMode.generator,
      primary,
      planSystem,
      'Yukarıdaki KULLANICI GÖREVİ için planı yaz.',
    ),
    _agent(
      wfId,
      2,
      '2. AI (Flutter Kodlayıcı - Generator)',
      AgentMode.generator,
      primary,
      codeSystem,
      'Önceki ajanın planını uygula: her dosyayı tam içeriğiyle yaz.',
    ),
    _agent(
      wfId,
      3,
      '3. AI (Dart Denetçi - Debugger Loop)',
      AgentMode.debugger,
      reviewer,
      'Gelen Dart/Flutter kodunu derleme hataları (eksik import, tür uyuşmazlığı, null-safety, kapanmayan parantez), uydurma API ve görevden sapma açısından katı denetle. '
          'Hata bulursan "[STATUS: ERROR] Hata detayı: ..." formatında yaz. Hata yoksa "[STATUS: SUCCESS]" yaz.',
      'Yukarıdaki KULLANICI GÖREVİ\'ne göre 2. Ajanın yazdığı kodu denetle; hata veya görevden sapma varsa bildir.',
      loops: 2,
    ),
  ];
}

const _builtinWorkflowIds = {
  'wf-mobile-debugging-zip',
  'wf-vulkan-report-pdf',
  'wf-agent-presentation-pptx',
};

/// Eski sürümlerde kaydedilmiş HAZIR akışlarda DeepSeek R1'in üretici/dönüştürücü olarak atanmış
/// olması düzeltilir: debugger olmayan ajanlar [primaryId] modeline alınır. Kullanıcının kendi
/// akışlarına ve debugger ajanlara dokunulmaz. Değişiklik yoksa null döner.
List<Workflow>? migrateReasoningRoles(List<Workflow> list, String primaryId) {
  if (primaryId == _deep) return null;
  var changed = false;
  final out = <Workflow>[];
  for (final w in list) {
    if (!_builtinWorkflowIds.contains(w.id)) {
      out.add(w);
      continue;
    }
    var wfChanged = false;
    final agents = <AgentConfig>[];
    for (final a in w.agents) {
      if (a.mode != AgentMode.debugger && a.modelId == _deep) {
        agents.add(a.copyWith(modelId: primaryId));
        wfChanged = true;
      } else {
        agents.add(a);
      }
    }
    if (wfChanged) {
      changed = true;
      out.add(w.copyWith(agents: agents));
    } else {
      out.add(w);
    }
  }
  return changed ? out : null;
}
