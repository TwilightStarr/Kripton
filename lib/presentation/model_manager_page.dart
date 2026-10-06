import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../application/model_fit.dart';
import '../core/theme.dart';
import '../domain/entities.dart';
import 'miui_hint.dart';

class ModelManagerPage extends ConsumerWidget {
  const ModelManagerPage({super.key});

  Widget _pill(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.withOpacity(0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.withOpacity(0.4)),
        ),
        child: Text(t, style: TextStyle(color: c, fontSize: 10.5, fontWeight: FontWeight.w600)),
      );

  Color _fitColor(ModelFit f) => switch (f) {
        ModelFit.fits => KColors.green,
        ModelFit.borderline => KColors.amber,
        ModelFit.tooBig => KColors.red,
      };

  Future<void> _confirmDelete(BuildContext context, AppController c, GgufModel m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Modeli sil'),
        content: Text('${m.name} yerel depodan silinecek. Tekrar kullanmak için yeniden indirmen gerekir.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true) await c.deleteModel(m.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appProvider);
    final c = ref.read(appProvider.notifier);
    final totalRam = s.totalRamBytes;
    return Scaffold(
      appBar: AppBar(title: const Text('Yerel Model Yöneticisi')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: KColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: KColors.border),
            ),
            child: Text(
              'Modeller bir kez indirilir ve ${s.cachedCount} / ${s.models.length} model yerelde. Aynı model tüm akışlarda yeniden indirilmeden yerel dosya yolundan yüklenir.',
              style: TextStyle(fontSize: 12, color: KColors.muted, height: 1.4),
            ),
          ),
          if (totalRam != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 2),
              child: Text(
                'Cihaz RAM\'i: ${(totalRam / 1e9).toStringAsFixed(1)} GB • rozetler toplam RAM\'e göre hesaplanır.',
                style: TextStyle(fontSize: 11, color: KColors.muted),
              ),
            ),
          const SizedBox(height: 12),
          for (final m in s.models)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: KColors.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: m.isCached ? KColors.green.withOpacity(0.5) : KColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(m.name, style: const TextStyle(fontWeight: FontWeight.w700))),
                      if (m.isCached) Icon(Icons.check_circle, color: KColors.green, size: 20),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (totalRam != null)
                        _pill(
                          modelFitLabel(modelFit(m, totalBytes: totalRam)),
                          _fitColor(modelFit(m, totalBytes: totalRam)),
                        ),
                      if (s.defaultPick?.primaryId == m.id) _pill('Önerilen', KColors.accent),
                      _pill(m.quantization, KColors.accent),
                      _pill('${m.sizeGb.toStringAsFixed(1)} GB disk', KColors.muted),
                      _pill('${m.ramGb.toStringAsFixed(1)} GB RAM', KColors.amber),
                      _pill(m.tokensPerSec, KColors.green),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(m.quality, style: TextStyle(fontSize: 12, color: KColors.muted)),
                  if (m.sha256 != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'SHA-256: ${m.sha256!.substring(0, 16)}…',
                        style: TextStyle(fontSize: 10.5, color: KColors.muted, fontFamily: 'monospace'),
                      ),
                    ),
                  const SizedBox(height: 10),
                  if (s.downloads.containsKey(m.id))
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LinearProgressIndicator(
                                value: s.downloads[m.id]! >= 1 ? null : s.downloads[m.id],
                                color: KColors.accent,
                                backgroundColor: KColors.border,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                s.downloads[m.id]! >= 1
                                    ? 'Doğrulanıyor...'
                                    : '%${(s.downloads[m.id]! * 100).toStringAsFixed(1)}',
                                style: TextStyle(fontSize: 11, color: KColors.muted),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (s.downloads[m.id]! < 1)
                          OutlinedButton(onPressed: () => c.cancelDownload(m.id), child: const Text('Duraklat')),
                      ],
                    )
                  else if (m.isCached)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: s.running ? null : () => _confirmDelete(context, c, m),
                        icon: Icon(Icons.delete_outline, size: 18, color: KColors.red),
                        label: Text('Sil', style: TextStyle(color: KColors.red)),
                      ),
                    )
                  else
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: () => maybeShowMiuiHint(context).whenComplete(() => c.startDownload(m.id)),
                        icon: const Icon(Icons.download, size: 18),
                        label: const Text('İndir'),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
