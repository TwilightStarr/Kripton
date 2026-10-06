import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../core/theme.dart';

/// Proje akışının türü.
enum ProjectMode {
  /// Sıfırdan yeni Flutter projesi (ZIP).
  newFlutter,

  /// Kripton'un uygulamaya gömülü kendi kaynağını geliştirmesi.
  selfImprove,

  /// Kullanıcının seçtiği bir proje ZIP'ini geliştirmek.
  openProject,
}

extension ProjectModeX on ProjectMode {
  String get heading => switch (this) {
    ProjectMode.newFlutter => 'Yeni Flutter projesi',
    ProjectMode.selfImprove => 'Kripton kendini geliştirsin',
    ProjectMode.openProject => 'Proje ZIP\'i seç ve geliştir',
  };

  String get hint => switch (this) {
    ProjectMode.newFlutter =>
      'Ajanlar sıfırdan bir Flutter projesi yazar; eksik pubspec, kurulum.sh ve CI dosyaları otomatik tamamlanır.',
    ProjectMode.selfImprove =>
      'Kripton kendi kaynağını okur, görevi uygular ve güncellenmiş TAM kaynak ZIP\'i üretir. '
          'Yeni sürümü ZIP\'i derleyerek kurarsın; uygulama çalışırken kendini değiştirmez.',
    ProjectMode.openProject =>
      'Seçtiğin proje ZIP\'i okunur; yalnızca değişen dosyalar üretilir ve projenin üstüne bindirilerek tam ZIP verilir.',
  };

  String get taskLabel => switch (this) {
    ProjectMode.newFlutter => 'Ne uygulaması yazılsın? (zorunlu)',
    ProjectMode.selfImprove => 'Kripton\'a ne eklensin / ne düzeltilsin? (zorunlu)',
    ProjectMode.openProject => 'Projede ne yapılsın? (zorunlu)',
  };
}

class ProjectTaskSheet extends ConsumerStatefulWidget {
  const ProjectTaskSheet({super.key, required this.mode});

  final ProjectMode mode;

  @override
  ConsumerState<ProjectTaskSheet> createState() => _ProjectTaskSheetState();
}

class _ProjectTaskSheetState extends ConsumerState<ProjectTaskSheet> {
  final _title = TextEditingController();
  final _task = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _task.dispose();
    super.dispose();
  }

  bool get _needsTitle => widget.mode == ProjectMode.newFlutter;

  bool get _ready =>
      !_busy && _task.text.trim().isNotEmpty && (!_needsTitle || _title.text.trim().isNotEmpty);

  Future<void> _submit() async {
    final c = ref.read(appProvider.notifier);
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    switch (widget.mode) {
      case ProjectMode.newFlutter:
        c.createProjectWorkflow(title: _title.text, task: _task.text);
        nav.pop();
      case ProjectMode.selfImprove:
        c.createSelfImproveWorkflow(_task.text);
        nav.pop();
      case ProjectMode.openProject:
        final ok = await c.pickProjectAndCreate(_task.text);
        if (ok) {
          nav.pop();
        } else if (mounted) {
          setState(() => _busy = false);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.mode.heading, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(widget.mode.hint, style: TextStyle(color: KColors.muted, fontSize: 12)),
            const SizedBox(height: 16),
            if (_needsTitle) ...[
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Proje adı'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _task,
              minLines: 3,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                labelText: widget.mode.taskLabel,
                alignLabelWithHint: true,
                helperText: widget.mode == ProjectMode.selfImprove
                    ? 'Küçük, tek amaçlı görevler daha iyi sonuç verir (yerel 7B model).'
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _ready ? _submit : null,
                icon: Icon(widget.mode == ProjectMode.openProject ? Icons.folder_open : Icons.add),
                label: Text(widget.mode == ProjectMode.openProject ? 'ZIP seç ve akışı oluştur' : 'Akışı oluştur'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Alt sayfayı açar.
Future<void> showProjectTaskSheet(BuildContext context, ProjectMode mode) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ProjectTaskSheet(mode: mode),
    );
