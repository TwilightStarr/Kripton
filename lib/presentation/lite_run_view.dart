import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../core/theme.dart';
import '../domain/entities.dart';
import 'cancel_dialog.dart';

/// Sade mod: AI akışı çalışırken ana ekranın YERİNE gösterilen tek ekranlık, çok hafif arayüz.
///
/// RAM/CPU'yu azaltmak için bilinçli olarak şunlar yoktur: canlı token metni, günlük listesi,
/// akış grafiği, ajan kartları (metin kutuları), telemetri paneli, animasyonlar ve gölgeler.
/// Yalnızca birkaç küçük metin ve tek bir (animasyonsuz) ilerleme çubuğu çizilir; tam arayüz
/// ağacı bu sırada bellekten atılır. Kullanıcı istediği an tam arayüze dönebilir.
class LiteRunView extends ConsumerWidget {
  const LiteRunView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Ekran yalnızca bu birkaç değer değişince yeniden kurulur (kayıt/token akışı izlenmez).
    final (agent, status, cancelling) = ref.watch(
      appProvider.select((s) => (s.liveAgent, s.status, s.cancelling)),
    );
    final (done, total) = ref.watch(
      appProvider.select((s) {
        final agents = s.current?.agents ?? const <AgentConfig>[];
        return (
          agents.where((a) => a.status == AgentStatus.completed).length,
          agents.length,
        );
      }),
    );
    final c = ref.read(appProvider.notifier);
    final step = total == 0 ? 0 : (done + 1).clamp(1, total);

    // TickerMode kapalı: bu alt ağaçta hiçbir animasyon çalışmaz.
    return TickerMode(
      enabled: false,
      child: Scaffold(
        backgroundColor: KColors.bg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.eco_outlined, size: 18, color: KColors.green),
                    const SizedBox(width: 8),
                    Text(
                      'SADE MOD',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w800,
                        color: KColors.green,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  cancelling ? 'İptal ediliyor…' : 'Yapay zekâ çalışıyor',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: KColors.text,
                  ),
                ),
                const SizedBox(height: 10),
                if (agent.isNotEmpty)
                  Text(
                    agent,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: KColors.accent,
                    ),
                  ),
                const SizedBox(height: 18),
                if (total > 0) ...[
                  // Belirli (determinate) değer: animasyon/ticker yok, yalnızca adım değişince çizilir.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: done / total,
                      minHeight: 6,
                      color: KColors.accent,
                      backgroundColor: KColors.border,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        'Adım $step / $total',
                        style: TextStyle(fontSize: 12.5, color: KColors.muted),
                      ),
                      const Spacer(),
                      const _Elapsed(),
                    ],
                  ),
                  const SizedBox(height: 18),
                ],
                Text(
                  status.isEmpty ? 'Hazırlanıyor…' : status,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: KColors.muted,
                    fontFamily: 'monospace',
                  ),
                ),
                const Spacer(),
                Text(
                  'Canlı yazı akışı, günlük, grafik ve animasyonlar kapalı; '
                  'arayüz en az belleği kullanır. Üretim aynı hızda sürer.',
                  style: TextStyle(fontSize: 11.5, height: 1.4, color: KColors.muted),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: KColors.red,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: cancelling ? null : () => confirmAndCancel(context, ref),
                    child: Text(cancelling ? 'İptal ediliyor…' : 'İptal Et'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => c.setLite(false),
                    child: const Text('Tam arayüze dön'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Geçen süre: saniyede bir yalnızca bu küçük metin yeniden kurulur.
class _Elapsed extends ConsumerStatefulWidget {
  const _Elapsed();

  @override
  ConsumerState<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends ConsumerState<_Elapsed> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final started = ref.read(appProvider).startedAt;
    final d = started == null ? Duration.zero : DateTime.now().difference(started);
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final txt = h > 0
        ? '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}'
        : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
    return Text(
      txt,
      style: TextStyle(
        fontSize: 12.5,
        color: KColors.muted,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
