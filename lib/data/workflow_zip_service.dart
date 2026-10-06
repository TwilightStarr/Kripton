// lib/data/workflow_zip_service.dart
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import '../domain/workflow_package_schema.dart';

class ZipValidationException implements Exception {
  final String message;
  ZipValidationException(this.message);

  @override
  String toString() => message;
}

class ResolvedWorkflowStep {
  final WorkflowStepManifest manifest;
  final String systemPrompt;
  final String userTemplate;
  final WorkflowStepInferenceConfig config;
  final String? schemaContent;

  ResolvedWorkflowStep({
    required this.manifest,
    required this.systemPrompt,
    required this.userTemplate,
    required this.config,
    this.schemaContent,
  });
}

class ResolvedWorkflowPackage {
  final WorkflowManifest manifest;
  final List<ResolvedWorkflowStep> steps;

  ResolvedWorkflowPackage({required this.manifest, required this.steps});
}

class WorkflowZipService {
  /// Paket sınırları: bozuk/kötü niyetli ZIP telefonu belleğe boğmasın.
  static const int maxZipBytes = 20 * 1024 * 1024;
  static const int maxEntryBytes = 5 * 1024 * 1024;
  static const int maxSteps = 32;

  /// compute() Isolate üzerinde ZIP okur ve doğrular.
  static Future<ResolvedWorkflowPackage> readWorkflowZip(String filePath) async {
    final file = File(filePath);
    final len = await file.length();
    if (len > maxZipBytes) {
      throw ZipValidationException(
        'ZIP dosyası çok büyük (${(len / 1048576).toStringAsFixed(1)} MB). Sınır: ${maxZipBytes ~/ 1048576} MB.',
      );
    }
    final bytes = await file.readAsBytes();
    return parseZipBytes(bytes);
  }

  static Future<ResolvedWorkflowPackage> parseZipBytes(Uint8List bytes) =>
      compute(_parseZipBytesInIsolate, bytes);

  /// Güvenli yol: ters eğik çizgi → eğik çizgi; başında ./ ve / atılır; '..' içeren yol reddedilir.
  static String? _cleanPath(String raw) {
    var n = raw.replaceAll('\\', '/');
    while (n.startsWith('./')) {
      n = n.substring(2);
    }
    while (n.startsWith('/')) {
      n = n.substring(1);
    }
    if (n.split('/').contains('..')) return null;
    return n;
  }

  static String _text(ArchiveFile f, String name) {
    if (f.size > maxEntryBytes) {
      throw ZipValidationException(
        'ZIP dosyası geçersiz: "$name" çok büyük (sınır ${maxEntryBytes ~/ 1048576} MB).',
      );
    }
    try {
      return utf8.decode(f.content as List<int>);
    } catch (_) {
      throw ZipValidationException('ZIP dosyası geçersiz: "$name" UTF-8 metin değil.');
    }
  }

  static ResolvedWorkflowPackage _parseZipBytesInIsolate(Uint8List bytes) {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw ZipValidationException('Dosya geçerli bir ZIP arşivi değil.');
    }

    var fileMap = <String, ArchiveFile>{};
    for (final file in archive) {
      if (!file.isFile) continue;
      final name = _cleanPath(file.name);
      if (name == null) {
        throw ZipValidationException('ZIP dosyası geçersiz: güvensiz yol "${file.name}".');
      }
      fileMap[name] = file;
    }

    // Klasör sıkıştırılmışsa (tek üst klasör altında workflow.json) üst klasörü soy.
    if (!fileMap.containsKey('workflow.json')) {
      final nested = fileMap.keys.where((k) => k.endsWith('/workflow.json')).toList();
      if (nested.length == 1) {
        final prefix = nested.first.substring(0, nested.first.length - 'workflow.json'.length);
        fileMap = {
          for (final e in fileMap.entries)
            if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
        };
      }
    }

    // 1. workflow.json kontrolü
    final manifestFile = fileMap['workflow.json'];
    if (manifestFile == null) {
      throw ZipValidationException('ZIP dosyası geçersiz: workflow.json bulunamadı.');
    }

    WorkflowManifest manifest;
    try {
      manifest = WorkflowManifest.fromJson(
        jsonDecode(_text(manifestFile, 'workflow.json')) as Map<String, dynamic>,
      );
    } on ZipValidationException {
      rethrow;
    } catch (_) {
      throw ZipValidationException(
        'ZIP dosyası geçersiz: workflow.json JSON formatı bozuk veya zorunlu alanlar eksik.',
      );
    }

    if (manifest.steps.isEmpty) {
      throw ZipValidationException('ZIP dosyası geçersiz: En az bir AI adımı tanımlanmalıdır.');
    }
    if (manifest.steps.length > maxSteps) {
      throw ZipValidationException('ZIP dosyası geçersiz: en çok $maxSteps adım desteklenir.');
    }

    final resolvedSteps = <ResolvedWorkflowStep>[];

    // 2. N adet adımı tara
    for (final step in manifest.steps) {
      ArchiveFile need(String? path, String what) {
        final f = path == null ? null : fileMap[_cleanPath(path) ?? path];
        if (f == null) {
          throw ZipValidationException('ZIP dosyası geçersiz: "$path" $what bulunamadı.');
        }
        return f;
      }

      final systemPrompt = _text(
        need(step.promptFiles.systemPrompt, 'sistem prompt dosyası'),
        step.promptFiles.systemPrompt,
      );
      final userTemplate = _text(
        need(step.promptFiles.userTemplate, 'kullanıcı istem şablonu'),
        step.promptFiles.userTemplate,
      );

      WorkflowStepInferenceConfig config;
      try {
        final cfgText = _text(need(step.configFile, 'konfigürasyon dosyası'), step.configFile);
        config = WorkflowStepInferenceConfig.fromJson(
          jsonDecode(cfgText) as Map<String, dynamic>,
        );
      } on ZipValidationException {
        rethrow;
      } catch (_) {
        throw ZipValidationException(
          'ZIP dosyası geçersiz: "${step.configFile}" konfigürasyonu bozuk.',
        );
      }

      // Schema (opsiyonel)
      String? schemaContent;
      final sf = step.schemaFile;
      if (sf != null && fileMap.containsKey(_cleanPath(sf) ?? sf)) {
        schemaContent = _text(fileMap[_cleanPath(sf) ?? sf]!, sf);
      }

      resolvedSteps.add(
        ResolvedWorkflowStep(
          manifest: step,
          systemPrompt: systemPrompt,
          userTemplate: userTemplate,
          config: config,
          schemaContent: schemaContent,
        ),
      );
    }

    return ResolvedWorkflowPackage(manifest: manifest, steps: resolvedSteps);
  }

  /// Akışı standart ZIP paketi olarak dışa aktarır.
  static Future<Uint8List> exportWorkflowToZip(ResolvedWorkflowPackage pkg) =>
      compute(_createZipBytesInIsolate, pkg);

  static void _add(Archive a, String name, String text) {
    final b = utf8.encode(text);
    a.addFile(ArchiveFile(name, b.length, b));
  }

  static Uint8List _createZipBytesInIsolate(ResolvedWorkflowPackage pkg) {
    final archive = Archive();
    final newSteps = <WorkflowStepManifest>[];

    for (var i = 0; i < pkg.steps.length; i++) {
      final step = pkg.steps[i];
      final n = i + 1; // çakışmasın diye sıra, manifest'teki stepIndex'e değil konuma bağlı
      final sysPath = 'prompts/step_${n}_system.txt';
      final userPath = 'prompts/step_${n}_user.txt';
      final cfgPath = 'configs/step_${n}_config.json';
      final schemaPath = step.schemaContent != null ? 'schemas/step_${n}_schema.json' : null;

      _add(archive, sysPath, step.systemPrompt);
      _add(archive, userPath, step.userTemplate);
      _add(archive, cfgPath, jsonEncode(step.config.toJson()));
      if (schemaPath != null) _add(archive, schemaPath, step.schemaContent!);

      final m = step.manifest;
      // Manifest, ZIP içindeki GERÇEK dosya yollarını göstermeli; yoksa yeniden içe aktarım bozulur.
      newSteps.add(
        WorkflowStepManifest(
          stepId: m.stepId,
          stepIndex: n,
          agentName: m.agentName,
          targetModelFamily: m.targetModelFamily,
          promptFiles: WorkflowStepPromptFiles(systemPrompt: sysPath, userTemplate: userPath),
          configFile: cfgPath,
          schemaFile: schemaPath,
          inputMapping: m.inputMapping,
          agentMode: m.agentMode,
        ),
      );
    }

    final pm = pkg.manifest;
    final manifest = WorkflowManifest(
      workflowId: pm.workflowId,
      title: pm.title,
      version: pm.version,
      author: pm.author,
      description: pm.description,
      steps: newSteps,
      outputFormat: pm.outputFormat,
    );
    _add(archive, 'workflow.json', const JsonEncoder.withIndent('  ').convert(manifest.toJson()));

    final zipData = ZipEncoder().encode(archive);
    return Uint8List.fromList(zipData!);
  }
}
