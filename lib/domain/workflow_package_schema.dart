// lib/domain/workflow_package_schema.dart

class WorkflowStepPromptFiles {
  final String systemPrompt;
  final String userTemplate;

  WorkflowStepPromptFiles({
    required this.systemPrompt,
    required this.userTemplate,
  });

  factory WorkflowStepPromptFiles.fromJson(Map<String, dynamic> json) {
    return WorkflowStepPromptFiles(
      systemPrompt: json['system_prompt'] as String? ?? '',
      userTemplate: json['user_template'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'system_prompt': systemPrompt,
    'user_template': userTemplate,
  };
}

class WorkflowStepInferenceConfig {
  final double temperature;
  final double topP;
  final int maxTokens;
  final double repeatPenalty;

  WorkflowStepInferenceConfig({
    this.temperature = 0.7,
    this.topP = 0.9,
    this.maxTokens = 1024,
    this.repeatPenalty = 1.1,
  });

  factory WorkflowStepInferenceConfig.fromJson(Map<String, dynamic> json) {
    return WorkflowStepInferenceConfig(
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      topP: (json['top_p'] as num?)?.toDouble() ?? 0.9,
      maxTokens: json['max_tokens'] as int? ?? 1024,
      repeatPenalty: (json['repeat_penalty'] as num?)?.toDouble() ?? 1.1,
    );
  }

  Map<String, dynamic> toJson() => {
    'temperature': temperature,
    'top_p': topP,
    'max_tokens': maxTokens,
    'repeat_penalty': repeatPenalty,
  };
}

class WorkflowStepManifest {
  final String stepId;
  final int stepIndex;
  final String agentName;
  final String targetModelFamily;
  final WorkflowStepPromptFiles promptFiles;
  final String configFile;
  final String? schemaFile;
  final Map<String, String>? inputMapping;

  /// Opsiyonel: generator | debugger | converter | export (yoksa generator).
  final String? agentMode;

  WorkflowStepManifest({
    required this.stepId,
    required this.stepIndex,
    required this.agentName,
    required this.targetModelFamily,
    required this.promptFiles,
    required this.configFile,
    this.schemaFile,
    this.inputMapping,
    this.agentMode,
  });

  factory WorkflowStepManifest.fromJson(Map<String, dynamic> json) {
    return WorkflowStepManifest(
      stepId: json['step_id'] as String,
      stepIndex: json['step_index'] as int? ?? 1,
      agentName: json['agent_name'] as String,
      targetModelFamily: json['target_model_family'] as String,
      promptFiles: WorkflowStepPromptFiles.fromJson(
        json['prompt_files'] as Map<String, dynamic>,
      ),
      configFile: json['config_file'] as String,
      schemaFile: json['schema_file'] as String?,
      inputMapping: (json['input_mapping'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(k, v.toString()),
      ),
      agentMode: json['agent_mode'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'step_id': stepId,
    'step_index': stepIndex,
    'agent_name': agentName,
    'target_model_family': targetModelFamily,
    'prompt_files': promptFiles.toJson(),
    'config_file': configFile,
    if (schemaFile != null) 'schema_file': schemaFile,
    if (inputMapping != null) 'input_mapping': inputMapping,
    if (agentMode != null) 'agent_mode': agentMode,
  };
}

class WorkflowManifest {
  final String workflowId;
  final String title;
  final String version;
  final String author;
  final String description;
  final List<WorkflowStepManifest> steps;

  /// Opsiyonel: zip | pdf | pptx | docx | txt (yoksa txt).
  final String? outputFormat;

  WorkflowManifest({
    required this.workflowId,
    required this.title,
    required this.version,
    required this.author,
    required this.description,
    required this.steps,
    this.outputFormat,
  });

  factory WorkflowManifest.fromJson(Map<String, dynamic> json) {
    return WorkflowManifest(
      workflowId: json['workflow_id'] as String,
      title: json['title'] as String,
      version: json['version'] as String? ?? '1.0.0',
      author: json['author'] as String? ?? '',
      description: json['description'] as String? ?? '',
      steps: (json['steps'] as List<dynamic>)
          .map((e) => WorkflowStepManifest.fromJson(e as Map<String, dynamic>))
          .toList(),
      outputFormat: json['output_format'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'workflow_id': workflowId,
    'title': title,
    'version': version,
    'author': author,
    'description': description,
    if (outputFormat != null) 'output_format': outputFormat,
    'steps': steps.map((s) => s.toJson()).toList(),
  };
}
