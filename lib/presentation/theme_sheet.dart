import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../application/settings_controller.dart';
import '../core/theme.dart';
import '../domain/start_screen.dart';

/// Görünüm ve performans: tema seçimi + sade mod tercihi.
Future<void> showAppearanceSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AppearanceSheet(),
    );

class _AppearanceSheet extends ConsumerWidget {
  const _AppearanceSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final c = ref.read(settingsProvider.notifier);
    final running = ref.watch(appProvider.select((a) => a.running));
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Görünüm', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: KColors.text)),
            const SizedBox(height: 4),
            Text('Tema anında uygulanır ve hatırlanır.', style: TextStyle(fontSize: 12.5, color: KColors.muted)),
            const SizedBox(height: 14),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.55,
              children: [
                for (final p in KPalette.all)
                  _ThemeTile(palette: p, selected: p.id == s.themeId, onTap: () => c.setTheme(p.id)),
              ],
            ),
            const SizedBox(height: 22),
            Text('Açılış ekranı', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: KColors.text)),
            const SizedBox(height: 4),
            Text(
              'Uygulama açılınca hangi mod ilk görünsün? Bir sonraki açılışta geçerli olur.',
              style: TextStyle(fontSize: 12.5, color: KColors.muted),
            ),
            const SizedBox(height: 10),
            Container(
              decoration: kCardDecoration(),
              child: Column(
                children: [
                  for (final m in StartScreen.values)
                    ListTile(
                      onTap: () => c.setStartScreen(m),
                      leading: Icon(
                        m == s.startScreen ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: m == s.startScreen ? KColors.accent : KColors.muted,
                      ),
                      title: Text(m.label, style: TextStyle(fontWeight: FontWeight.w700, color: KColors.text)),
                      subtitle: Text(m.hint, style: TextStyle(fontSize: 12, color: KColors.muted)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: kCardDecoration(),
              child: Row(
                children: [
                  Icon(Icons.eco_outlined, color: KColors.green),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Sade mod', style: TextStyle(fontWeight: FontWeight.w700, color: KColors.text)),
                        const SizedBox(height: 3),
                        Text(
                          'AI akışı başlayınca tek ekranlık hafif arayüz açılır: canlı yazı, günlük, grafik ve animasyon yok → daha az RAM.',
                          style: TextStyle(fontSize: 12, height: 1.35, color: KColors.muted),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: s.liteOnStart,
                    onChanged: (v) {
                      c.setLiteOnStart(v);
                      // Akış zaten sürüyorsa hemen uygula.
                      if (running) ref.read(appProvider.notifier).setLite(v);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({required this.palette, required this.selected, required this.onTap});

  final KPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return InkWell(
      borderRadius: BorderRadius.circular(KRadius.md),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: p.bg,
          borderRadius: BorderRadius.circular(KRadius.md),
          border: Border.all(color: selected ? KColors.accent : p.border, width: selected ? 2 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: p.card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: p.border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [p.accent, p.accent2]),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(height: 4, width: 36, decoration: BoxDecoration(color: p.text, borderRadius: BorderRadius.circular(2))),
                          const SizedBox(height: 4),
                          Container(height: 4, width: 22, decoration: BoxDecoration(color: p.muted, borderRadius: BorderRadius.circular(2))),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: p.text),
                  ),
                ),
                if (selected) Icon(Icons.check_circle, size: 16, color: KColors.accent),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
