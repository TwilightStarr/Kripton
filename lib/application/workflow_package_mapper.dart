import '../data/workflow_zip_service.dart';
import '../domain/entities.dart';
import '../domain/inference_settings.dart';
import '../domain/workflow_package_schema.dart';

/// ZIP paketi ([ResolvedWorkflowPackage]) ile uygulamanın [Workflow] modeli arasında dönüşüm.
///
/// Paketteki çıkarım ayarları (temperature, top_p, max_tokens, repeat_penalty) [AgentConfig.inference]'a
/// aktarılır ve dışa aktarımda geri yazılır. `max_tokens: 0` "otomatik" demektir. Şema dosyaları
/// (`schema_file`) hâlâ kullanılmaz.
class WorkflowPackageMapper {
  static const _userQuery = r'$user_query';

  // Eski sürümler her adıma bu sabit değerleri yazıyordu; gerçek bir tercih olmadığından "ayarsız" sayılır
  // (aksi hâlde eski paketler sıcaklığı 0.7'ye, çıktıyı 1024 token'a sınırlardı).
  static bool _isLegacyDefault(WorkflowStepInferenceConfig c) =>
      c.temperature == 0.7 && c.topP == 0.9 && c.maxTokens == 1024 && c.repeatPenalty == 1.1;

  static InferenceSettings inferenceFrom(WorkflowStepInferenceConfig c) {
    if (_isLegacyDefault(c)) return const InferenceSettings();
    return InferenceSettings(
      temperature: c.temperature,
      topP: c.topP,
      repeatPenalty: c.repeatPenalty,
      maxTokens: c.maxTokens > 0 ? c.maxTokens : null,
    ).clamped();
  }

  static WorkflowStepInferenceConfig configFrom(InferenceSettings s) => WorkflowStepInferenceConfig(
    temperature: s.temperature,
    topP: s.topP,
    maxTokens: s.maxTokens ?? 0,
    repeatPenalty: s.repeatPenalty,
  );

  static OutputFormat _format(String? name) {
    for (final f in OutputFormat.values) {
      if (f.name == name) return f;
    }
    return OutputFormat.txt;
  }

  static AgentMode _mode(String? name, int index, int total) {
    for (final m in AgentMode.values) {
      if (m.name == name) return m;
    }
    return AgentMode.generator;
  }

  /// `{{anahtar}}` yer tutucularını, ana projedeki prompt yapısına uygun düz metne çevirir
  /// (görev ve önceki ajan çıktısı runner tarafından zaten bağlama eklenir).
  static String resolveTemplate(String template, Map<String, String>? mapping) {
    var out = template;
    mapping?.forEach((key, pattern) {
      final ph = RegExp('\\{\\{\\s*${RegExp.escape(key)}\\s*\\}\\}');
      final text = pattern == _userQuery
          ? 'yukarıdaki KULLANICI GÖREVİ'
          : 'önceki ajanın çıktısı';
      out = out.replaceAll(ph, text);
    });
    return out;
  }

  static String? _modelIdFor(
    String family,
    List<GgufModel> catalog,
    String? primaryId,
    String? reviewerId,
  ) {
    final f = family.trim().toLowerCase();
    // Varsayılan seçim aynı aileyse onu tercih et (cihaz RAM'ine göre seçilmiştir).
    for (final id in [primaryId, reviewerId]) {
      if (id == null) continue;
      for (final m in catalog) {
        if (m.id == id && m.family.toLowerCase() == f) return id;
      }
    }
    for (final m in catalog) {
      if (m.family.toLowerCase() == f) return m.id;
    }
    return null;
  }

  static Workflow toWorkflow(
    ResolvedWorkflowPackage pkg, {
    required List<GgufModel> catalog,
    String? primaryId,
    String? reviewerId,
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final id = 'wf-$now';
    final fallback = primaryId ?? (catalog.isEmpty ? '' : catalog.first.id);
    final steps = [...pkg.steps]
      ..sort((a, b) => a.manifest.stepIndex.compareTo(b.manifest.stepIndex));
    final agents = <AgentConfig>[
      for (var i = 0; i < steps.length; i++)
        AgentConfig(
          id: '$id-a${i + 1}',
          order: i + 1,
          name: steps[i].manifest.agentName,
          mode: _mode(steps[i].manifest.agentMode, i, steps.length),
          modelId:
              _modelIdFor(steps[i].manifest.targetModelFamily, catalog, primaryId, reviewerId) ??
              fallback,
          systemPrompt: steps[i].systemPrompt,
          userPrompt: resolveTemplate(steps[i].userTemplate, steps[i].manifest.inputMapping),
          inference: inferenceFrom(steps[i].config),
        ),
    ];
    final m = pkg.manifest;
    final author = m.author.trim();
    final desc = m.description.trim().isEmpty ? 'ZIP paketinden içe aktarıldı.' : m.description.trim();
    return Workflow(
      id: id,
      title: m.title.trim().isEmpty ? 'İçe aktarılan akış' : m.title.trim(),
      description: author.isEmpty ? desc : '$desc (Yazar: $author)',
      targetFormat: _format(m.outputFormat),
      agents: agents,
      createdAt: now,
      updatedAt: now,
    );
  }

  static ResolvedWorkflowPackage fromWorkflow(Workflow wf, List<GgufModel> catalog) {
    final agents = [...wf.agents]..sort((a, b) => a.order.compareTo(b.order));
    String family(String modelId) {
      for (final m in catalog) {
        if (m.id == modelId) return m.family;
      }
      return 'Qwen';
    }

    final steps = <ResolvedWorkflowStep>[];
    for (var i = 0; i < agents.length; i++) {
      final a = agents[i];
      final n = i + 1;
      steps.add(
        ResolvedWorkflowStep(
          manifest: WorkflowStepManifest(
            stepId: 'step_$n',
            stepIndex: n,
            agentName: a.name,
            targetModelFamily: family(a.modelId),
            // Yollar dışa aktarımda ZIP içindeki gerçek yollarla yeniden yazılır.
            promptFiles: WorkflowStepPromptFiles(
              systemPrompt: 'prompts/step_${n}_system.txt',
              userTemplate: 'prompts/step_${n}_user.txt',
            ),
            configFile: 'configs/step_${n}_config.json',
            inputMapping: n == 1
                ? {'user_query': _userQuery}
                : {'previous_output': '\$step_${n - 1}.output'},
            agentMode: a.mode.name,
          ),
          systemPrompt: a.systemPrompt,
          userTemplate: a.userPrompt,
          config: configFrom(a.inference),
        ),
      );
    }
    return ResolvedWorkflowPackage(
      manifest: WorkflowManifest(
        workflowId: wf.id,
        title: wf.title,
        version: '1.0.0',
        author: '',
        description: wf.description,
        outputFormat: wf.targetFormat.name,
        steps: [for (final s in steps) s.manifest],
      ),
      steps: steps,
    );
  }
}
