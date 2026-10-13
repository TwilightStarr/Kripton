import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../application/app_controller.dart';
import '../application/output_validator.dart';
import '../core/theme.dart';
import '../domain/entities.dart';

bool _sheetOpen = false;

/// Sonuç ekranını açar. Zaten açıksa ikinci kez açmaz (ör. "Yine de indir" sonrası artifact oluşunca
/// ana sayfa dinleyicisi tekrar tetiklenir; açık sayfa kendiliğinden güncellenir).
void showResultSheet(BuildContext context) {
  if (_sheetOpen) return;
  _sheetOpen = true;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const ResultSheet(),
  ).whenComplete(() => _sheetOpen = false);
}

class ResultSheet extends ConsumerWidget {
  const ResultSheet({super.key});

  void _snack(BuildContext c, String m) =>
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _open(BuildContext context, Artifact a) async {
    final r = await OpenFilex.open(a.path);
    if (r.type != ResultType.done && context.mounted) _snack(context, 'Dosya açılamadı: ${r.message}');
  }

  Future<void> _save(BuildContext context, Artifact a) async {
    try {
      final bytes = await File(a.path).readAsBytes();
      final out = await FilePicker.platform.saveFile(
        dialogTitle: 'Dosyayı kaydet',
        fileName: a.filename,
        bytes: bytes,
      );
      if (context.mounted) _snack(context, out == null ? 'Kaydetme iptal edildi.' : 'Dosya kaydedildi.');
    } catch (e) {
      if (context.mounted) _snack(context, 'Kaydedilemedi: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appProvider);
    final a = s.artifact;
    final rejected = s.rejected;
    final outputs = [...s.agentOutputs]..sort((x, y) => x.order.compareTo(y.order));

    if (a == null && rejected == null && !s.failed && outputs.isEmpty) {
      return const SizedBox(height: 120, child: Center(child: Text('Henüz çıktı yok.')));
    }

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.78,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            if (a != null) ..._successHeader(context, a),
            if (a == null && rejected != null) ..._rejectedHeader(context, ref, rejected),
            if (a == null && rejected == null) ..._failedHeader(s),
            if (s.contextWarning != null) ...[
              const SizedBox(height: 12),
              _Banner(icon: Icons.memory, color: KColors.amber, title: 'Küçük bağlam uyarısı', text: s.contextWarning!),
            ],
            if (outputs.isNotEmpty) ...[
              const SizedBox(height: 16),
              const _SectionLabel('AJAN ÇIKTILARI'),
              const SizedBox(height: 6),
              for (final o in outputs) _AgentOutputTile(output: o),
            ],
            if (a != null) ...[
              const SizedBox(height: 16),
              _SectionLabel(a.format == OutputFormat.zip ? 'ARŞİV İÇERİĞİ' : 'ÖNİZLEME'),
              const SizedBox(height: 6),
              _CodeBox(text: a.preview.isEmpty ? '(boş)' : a.preview),
            ],
            if (a == null && rejected != null) ...[
              const SizedBox(height: 16),
              const _SectionLabel('DOĞRULANAMAYAN ÇIKTI (ÖNİZLEME)'),
              const SizedBox(height: 6),
              _CodeBox(
                text: rejected.content.trim().isEmpty
                    ? '(boş)'
                    : (rejected.content.length > 6000
                        ? '${rejected.content.substring(0, 6000)}\n…'
                        : rejected.content),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _successHeader(BuildContext context, Artifact a) => [
        Row(
          children: [
            Icon(Icons.task_alt, color: KColors.green),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.filename, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('${a.format.product} • ${a.sizeLabel}', style: TextStyle(color: KColors.muted, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _open(context, a),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Aç'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _save(context, a),
                icon: const Icon(Icons.download, size: 18),
                label: const Text('İndir'),
              ),
            ),
          ],
        ),
      ];

  /// Doğrulayıcı reddetti: dosya üretilmedi. Hata detayı + "Yine de indir".
  List<Widget> _rejectedHeader(BuildContext context, WidgetRef ref, OutputValidationException r) => [
        Row(
          children: [
            Icon(Icons.rule, color: KColors.red),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Çıktı doğrulanamadı', style: TextStyle(fontWeight: FontWeight.w700)),
                  Text('${r.format.product} dosyası oluşturulmadı', style: TextStyle(color: KColors.muted, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _Banner(
          icon: Icons.error_outline,
          color: KColors.red,
          title: 'Hata detayı',
          text: [for (final p in r.problems) '• $p'].join('\n'),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: KColors.amber, foregroundColor: KColors.bg),
            onPressed: () => ref.read(appProvider.notifier).downloadAnyway(),
            icon: const Icon(Icons.download_for_offline_outlined, size: 18),
            label: const Text('Yine de indir'),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Doğrulama atlanır; dosya beklenen biçime uymayabilir.',
            style: TextStyle(color: KColors.muted, fontSize: 11.5),
          ),
        ),
      ];

  /// Doğrulayıcıya varmadan önce bir ajan çöktü (ör. think-only, bellek, model hatası).
  List<Widget> _failedHeader(AppState s) => [
        Row(
          children: [
            Icon(Icons.error_outline, color: KColors.red),
            const SizedBox(width: 10),
            const Expanded(child: Text('Akış tamamlanamadı', style: TextStyle(fontWeight: FontWeight.w700))),
          ],
        ),
        if (s.status.isNotEmpty) ...[
          const SizedBox(height: 10),
          _Banner(icon: Icons.info_outline, color: KColors.red, title: 'Ayrıntı', text: s.status),
        ],
      ];
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(fontSize: 11, color: KColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.6),
      );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.title, required this.text});

  final IconData icon;
  final Color color;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12.5)),
                  const SizedBox(height: 3),
                  SelectableText(text, style: const TextStyle(fontSize: 12.5, height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: KColors.codeBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: KColors.border),
        ),
        child: SelectableText(
          text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.4),
        ),
      );
}

/// Tek bir ajanın çıktısı: durum simgesi, ad/rol, karakter sayısı; açılınca not ve önizleme.
class _AgentOutputTile extends StatelessWidget {
  const _AgentOutputTile({required this.output});

  final AgentOutput output;

  (IconData, Color, String) get _look => switch (output.status) {
        AgentOutputStatus.ok => (Icons.check_circle, KColors.green, 'Tamam'),
        AgentOutputStatus.corrected => (Icons.build_circle, KColors.amber, 'Düzeltildi'),
        AgentOutputStatus.skipped => (Icons.skip_next, KColors.muted, 'Atlandı'),
        AgentOutputStatus.failed => (Icons.cancel, KColors.red, 'Sorun'),
      };

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = _look;
    final o = output;
    final subtitle = [
      o.role,
      label,
      if (o.chars > 0) '${o.chars} karakter',
    ].join(' • ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: KColors.card.withOpacity(0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: o.isProblem ? KColors.red.withOpacity(0.6) : KColors.border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          // Sorunlu adım kendiliğinden açık gelir: kullanıcı hatanın nerede olduğunu hemen görsün.
          initiallyExpanded: o.isProblem,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          leading: Icon(icon, color: color, size: 22),
          title: Text(
            o.isValidator ? o.name : '${o.order}. ${o.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
          ),
          subtitle: Text(subtitle, style: TextStyle(color: color, fontSize: 11.5)),
          children: [
            if (o.note != null && o.note!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SelectableText(o.note!, style: const TextStyle(fontSize: 12.5, height: 1.35)),
              ),
            if (o.preview.isNotEmpty) _CodeBox(text: o.preview),
          ],
        ),
      ),
    );
  }
}
