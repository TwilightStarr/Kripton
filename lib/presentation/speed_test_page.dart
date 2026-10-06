import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../application/perf_log.dart';
import '../application/token_budget.dart';
import '../core/theme.dart';
import '../data/default_data.dart';
import '../domain/chat_template.dart';
import '../domain/entities.dart';
import 'miui_hint.dart';

// Sabit Türkçe+kod karışımı test metni (her ölçümde aynı yük).
const _benchPrompt = 'Aşağıdaki Dart fonksiyonunu Türkçe açıkla ve olası hataları listele:\n'
    'int topla(List<int> l) { var t = 0; for (final x in l) { t += x; } return t; }\n'
    'Önce kısa bir özet, sonra maddeler halinde yaz.';
const _benchTokens = 128;

class SpeedTestPage extends ConsumerStatefulWidget {
  const SpeedTestPage({super.key});

  @override
  ConsumerState<SpeedTestPage> createState() => _SpeedTestPageState();
}

class _SpeedTestPageState extends ConsumerState<SpeedTestPage> {
  String? _modelId;
  bool _busy = false;
  String _msg = '';
  PerfSample? _last;

  @override
  void initState() {
    super.initState();
    PerfLog.instance.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _run(GgufModel m) async {
    setState(() {
      _busy = true;
      _msg = 'Model yükleniyor...';
    });
    final engine = ref.read(engineProvider);
    try {
      final loadSw = Stopwatch()..start();
      await engine.ensureLoaded(m.localPath!, expectedBytes: m.sizeBytes);
      final loadMs = loadSw.elapsedMilliseconds;
      if (!await engine.waitNativeIdle(const Duration(seconds: 8))) {
        throw StateError('Önceki üretim hâlâ sürüyor.');
      }
      if (mounted) setState(() => _msg = 'Üretiliyor...');
      final prompt = applyTemplate(m.template, 'Kısa ve net yanıt ver.', _benchPrompt);
      final promptTok = estimateTokens(prompt, m.template);
      var peak = MemInfo.rssMb();
      final sw = Stopwatch()..start();
      int? first;
      var n = 0;
      await for (final _ in engine.generate(prompt, maxTokens: _benchTokens)) {
        first ??= sw.elapsedMilliseconds;
        n++;
        if (n % 16 == 0) peak = peak < MemInfo.rssMb() ? MemInfo.rssMb() : peak;
      }
      final total = sw.elapsedMilliseconds;
      final ttft = first ?? total;
      final genMs = (total - ttft) < 1 ? 1 : total - ttft;
      final s = PerfSample(
        modelId: m.id,
        at: DateTime.now().millisecondsSinceEpoch,
        tokPerSec: n > 1 ? (n - 1) * 1000 / genMs : 0,
        prefillTokPerSec: ttft > 0 ? promptTok * 1000 / ttft : 0,
        firstTokenMs: ttft,
        loadMs: loadMs,
        peakRamMb: peak < MemInfo.rssMb() ? MemInfo.rssMb() : peak,
        threads: _dyn(() => (engine as dynamic).threads as int?) ?? 0,
        contextSize: engine.contextSize ?? 0,
        promptTokens: promptTok,
        genTokens: n,
        batch: _dyn(() => (engine as dynamic).batchSize as int?),
      );
      await PerfLog.instance.add(s);
      if (mounted) {
        setState(() {
          _last = s;
          _msg = 'Tamamlandı ve kaydedildi.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _msg = 'Hata: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  T? _dyn<T>(T? Function() f) {
    try {
      return f();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appProvider);
    final cached = s.models.where((m) => m.isCached).toList();
    _modelId ??= cached.isEmpty ? null : cached.first.id;
    GgufModel? sel;
    for (final m in cached) {
      if (m.id == _modelId) sel = m;
    }
    final log = PerfLog.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Hız Testi')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (cached.isEmpty)
            Text('Önce Model yöneticisinden bir model indir.', style: TextStyle(color: KColors.muted))
          else ...[
            DropdownButtonFormField<String>(
              value: _modelId,
              isExpanded: true,
              dropdownColor: KColors.card,
              items: [for (final m in cached) DropdownMenuItem(value: m.id, child: Text(m.name, overflow: TextOverflow.ellipsis))],
              onChanged: _busy ? null : (v) => setState(() => _modelId = v),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy || s.running || sel == null ? null : () => _run(sel!),
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.speed),
              label: Text(_busy ? 'Ölçülüyor...' : 'Hız testini başlat ($_benchTokens token)'),
            ),
            if (_msg.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(_msg, style: TextStyle(color: KColors.muted, fontSize: 12))),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => maybeShowMiuiHint(context, force: true),
            icon: const Icon(Icons.phone_android, size: 16),
            label: const Text('HyperOS arka plan ayarları'),
          ),
          if (_last != null) ...[const SizedBox(height: 14), RepaintBoundary(child: _SampleCard(_last!, title: 'Son ölçüm'))],
          const SizedBox(height: 14),
          const Text('KATALOG (ÖLÇÜLEN)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
          const SizedBox(height: 6),
          for (final m in s.models)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              subtitle: Text(tokensLabel(m, log.measuredLabel(m.id)),
                  style: TextStyle(fontSize: 11.5, color: log.measuredLabel(m.id) != null ? KColors.green : KColors.muted)),
            ),
          const SizedBox(height: 14),
          const Text('GEÇMİŞ', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
          const SizedBox(height: 6),
          for (final x in log.samples.reversed.take(10))
            Padding(padding: const EdgeInsets.only(bottom: 8), child: _SampleCard(x)),
        ],
      ),
    );
  }
}

class _SampleCard extends StatelessWidget {
  const _SampleCard(this.s, {this.title});

  final PerfSample s;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final t = DateTime.fromMillisecondsSinceEpoch(s.at);
    String two(int v) => v.toString().padLeft(2, '0');
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(k, style: TextStyle(color: KColors.muted, fontSize: 11.5, fontFamily: 'monospace')),
            Text(v, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${title ?? s.modelId}  ${two(t.hour)}:${two(t.minute)}',
              style: TextStyle(fontSize: 11.5, color: KColors.accent, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          row('tok/s', s.tokPerSec.toStringAsFixed(1)),
          row('prefill tok/s', s.prefillTokPerSec.toStringAsFixed(0)),
          row('ilk token', '${s.firstTokenMs} ms'),
          row('yükleme', '${s.loadMs} ms'),
          row('tepe RAM (RSS)', '${s.peakRamMb} MB'),
          row('thread / batch / ctx', '${s.threads == 0 ? '—' : s.threads} / ${s.batch ?? '—'} / ${s.contextSize}'),
        ],
      ),
    );
  }
}
