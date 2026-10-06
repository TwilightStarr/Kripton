import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../core/theme.dart';
import '../domain/entities.dart';

class NewWorkflowSheet extends ConsumerStatefulWidget {
  const NewWorkflowSheet({super.key});

  @override
  ConsumerState<NewWorkflowSheet> createState() => _NewWorkflowSheetState();
}

class _NewWorkflowSheetState extends ConsumerState<NewWorkflowSheet> {
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _task = TextEditingController();
  OutputFormat _format = OutputFormat.zip;

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _task.dispose();
    super.dispose();
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
            const Text('Yeni AI Akışı Ekle', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Sıralı veya döngüsel çoklu ajan hattı oluştur', style: TextStyle(color: KColors.muted, fontSize: 12)),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Akış adı'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _desc,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Açıklama (isteğe bağlı)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _task,
              minLines: 3,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: 'Görev / İstek (zorunlu)',
                alignLabelWithHint: true,
                helperText: 'Tüm ajanlara bağlayıcı görev olarak iletilir.',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            Text('İŞLEV MODU', style: TextStyle(fontSize: 11, color: KColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final f in OutputFormat.values)
                  ChoiceChip(
                    label: Text(f.modeLabel),
                    selected: _format == f,
                    onSelected: (_) => setState(() => _format = f),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _title.text.trim().isEmpty || _task.text.trim().isEmpty
                    ? null
                    : () {
                        ref.read(appProvider.notifier).createWorkflow(_title.text, _desc.text, _task.text, _format);
                        Navigator.of(context).pop();
                      },
                icon: const Icon(Icons.add),
                label: const Text('Akışı Oluştur'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
