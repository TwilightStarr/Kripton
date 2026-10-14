// Görev 7/19 (Geliştirme Modu v2): Geliştirme Modu izleme ekranı (tablet odaklı, saatlerce açık kalır).
//
// Düzen (LayoutBuilder): ≥1000 dp 3 sütun, 600-1000 dp 2 sütun, <600 dp üstte TabBar. Alttan açılan
// sayfa/sekme YOKTUR; her şey sayfa içi panel, sekme veya diyalogdur.
// Bu dosya yalnızca okur: veri kaynağı, eylemler ve diff içeriği `dev_session_providers.dart`
// üzerinden (provider override ile) verilir. Bağlama Prompt 8'dedir.
//
// Sade Mod (`settings.liteOnStart`): animasyon kapalı (TickerMode), gölge yok, güncelleme daha seyrek.
// Erişilebilirlik: anlamlı Semantics, ≥48 dp dokunma hedefleri, durum her zaman ikon + METİN ile verilir.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart' show appProvider, interruptedDevSessionProvider;
import '../application/dev_guard.dart' show DevGate;
import '../application/dev_ledger.dart' show DevRole;
import '../application/dev_session_store.dart';
import '../application/settings_controller.dart';
import '../core/theme.dart';
import '../data/native_services.dart' show BatteryExemptState, BatteryOptimization;
import '../data/secret_mask.dart';
import 'dev_diff_view.dart';
import 'dev_session_providers.dart';
import 'miui_hint.dart' show maybeShowMiuiHint;

/// ≥ bu genişlik: 3 sütun.
const double kDevWideBreakpoint = 1000;

/// ≥ bu genişlik: 2 sütun; altı: sekmeler.
const double kDevMediumBreakpoint = 600;

/// Günlük panelinin seviye filtresi (null = tümü). Sekme değişince korunur.
final devLogFilterProvider = StateProvider<DevEventLevel?>((ref) => null);

// ------------------------------------------------------------------ yardımcılar

String _two(int v) => v.toString().padLeft(2, '0');

/// `g ss:dd:ss` (bir günden uzunsa gün öneki).
String devFormatDuration(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final days = d.inDays;
  final h = d.inHours % 24;
  final core = '${_two(h)}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}';
  if (days > 0) return '$days g $core';
  return '${d.inHours}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}';
}

String _fmtLimit(Duration d) {
  if (d.inHours >= 48 && d.inHours % 24 == 0) return '${d.inDays} g';
  if (d.inMinutes >= 60 && d.inMinutes % 60 == 0) return '${d.inHours} sa';
  return '${d.inMinutes} dk';
}

String _hms(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

String _shortSha(String s) => s.length > 7 ? s.substring(0, 7) : s;

String _gateTitle(String code) {
  try {
    final t = DevGate.title(code);
    return t.isEmpty ? code : t;
  } catch (_) {
    return code;
  }
}

class _StatusLook {
  const _StatusLook(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}

_StatusLook _statusLook(DevSessionStatus s) {
  switch (s) {
    case DevSessionStatus.hazir:
      return _StatusLook('Hazır', Icons.hourglass_empty, KColors.muted);
    case DevSessionStatus.calisiyor:
      return _StatusLook('Çalışıyor', Icons.play_circle_outline, KColors.accent);
    case DevSessionStatus.bekliyor:
      return _StatusLook('Bekliyor', Icons.hourglass_top, KColors.amber);
    case DevSessionStatus.duraklatildi:
      return _StatusLook('Duraklatıldı', Icons.pause_circle_outline, KColors.amber);
    case DevSessionStatus.tamamlandi:
      return _StatusLook('Bitti', Icons.check_circle_outline, KColors.green);
    case DevSessionStatus.hata:
      return _StatusLook('Hata', Icons.error_outline, KColors.red);
    case DevSessionStatus.iptal:
      return _StatusLook('Durduruldu', Icons.cancel_outlined, KColors.muted);
  }
}

_StatusLook _ciLook(DevCiState s) {
  switch (s) {
    case DevCiState.yok:
      return _StatusLook('CI: yok', Icons.remove_circle_outline, KColors.muted);
    case DevCiState.calisiyor:
      return _StatusLook('CI: çalışıyor', Icons.sync, KColors.accent);
    case DevCiState.basarili:
      return _StatusLook('CI: başarılı', Icons.check_circle_outline, KColors.green);
    case DevCiState.basarisiz:
      return _StatusLook('CI: başarısız', Icons.highlight_off, KColors.red);
    case DevCiState.bekliyor:
      return _StatusLook('CI: bekleniyor', Icons.hourglass_top, KColors.amber);
  }
}

String _levelLabel(DevEventLevel l) {
  switch (l) {
    case DevEventLevel.bilgi:
      return 'BİLGİ';
    case DevEventLevel.uyari:
      return 'UYARI';
    case DevEventLevel.hata:
      return 'HATA';
  }
}

Color _levelColor(DevEventLevel l) {
  switch (l) {
    case DevEventLevel.bilgi:
      return KColors.muted;
    case DevEventLevel.uyari:
      return KColors.amber;
    case DevEventLevel.hata:
      return KColors.red;
  }
}

IconData _kindIcon(DevEventKind k) {
  switch (k) {
    case DevEventKind.asama:
      return Icons.timeline;
    case DevEventKind.analiz:
      return Icons.search;
    case DevEventKind.yama:
      return Icons.build_outlined;
    case DevEventKind.commit:
      return Icons.commit;
    case DevEventKind.ci:
      return Icons.fact_check_outlined;
    case DevEventKind.geriAlma:
      return Icons.undo;
    case DevEventKind.bekleme:
      return Icons.hourglass_bottom;
    case DevEventKind.kalpAtisi:
      return Icons.favorite_border;
    case DevEventKind.durum:
      return Icons.info_outline;
  }
}

String _kindLabel(DevEventKind k) {
  switch (k) {
    case DevEventKind.asama:
      return 'Aşama';
    case DevEventKind.analiz:
      return 'Analiz';
    case DevEventKind.yama:
      return 'Yama';
    case DevEventKind.commit:
      return 'Commit';
    case DevEventKind.ci:
      return 'CI';
    case DevEventKind.geriAlma:
      return 'Geri alma';
    case DevEventKind.bekleme:
      return 'Bekleme';
    case DevEventKind.kalpAtisi:
      return 'Canlılık';
    case DevEventKind.durum:
      return 'Durum';
  }
}

String _changeLabel(DevChangeStatus s) {
  switch (s) {
    case DevChangeStatus.eklendi:
      return 'Eklendi';
    case DevChangeStatus.degistirildi:
      return 'Değişti';
    case DevChangeStatus.silindi:
      return 'Silindi';
    case DevChangeStatus.geriAlindi:
      return 'Geri alındı';
  }
}

IconData _changeIcon(DevChangeStatus s) {
  switch (s) {
    case DevChangeStatus.eklendi:
      return Icons.add_circle_outline;
    case DevChangeStatus.degistirildi:
      return Icons.edit_outlined;
    case DevChangeStatus.silindi:
      return Icons.delete_outline;
    case DevChangeStatus.geriAlindi:
      return Icons.undo;
  }
}

Color _changeColor(DevChangeStatus s) {
  switch (s) {
    case DevChangeStatus.eklendi:
      return KColors.green;
    case DevChangeStatus.degistirildi:
      return KColors.accent;
    case DevChangeStatus.silindi:
      return KColors.red;
    case DevChangeStatus.geriAlindi:
      return KColors.purple;
  }
}

const Map<String, String> _roleNames = {
  DevRole.analyst: 'Analist',
  DevRole.fixer: 'Düzeltici',
  DevRole.verifier: 'Doğrulayıcı',
};

// ------------------------------------------------------------------ ortak parçalar

/// Saniyede bir yeniden kurulan küçük alt ağaç; [active] false iken zamanlayıcı yoktur.
class _Ticking extends ConsumerStatefulWidget {
  const _Ticking({required this.active, required this.builder});

  final bool active;
  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  ConsumerState<_Ticking> createState() => _TickingState();
}

class _TickingState extends ConsumerState<_Ticking> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _Ticking oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.active) {
      _t ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _t?.cancel();
      _t = null;
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    _t = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clock = ref.watch(devClockProvider);
    return widget.builder(context, clock());
  }
}

/// Düz (gölgesiz) panel kartı: başlık + içerik.
class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.icon, required this.child, this.trailing});

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: title,
      child: Container(
        decoration: BoxDecoration(
          color: KColors.card,
          borderRadius: BorderRadius.circular(KRadius.md),
          border: Border.all(color: KColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: KColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: KColors.text),
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
            Divider(height: 1, color: KColors.border),
            Expanded(
              child: Padding(padding: const EdgeInsets.all(8), child: child),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.4, color: KColors.muted),
          ),
        ),
      );
}

/// Üst şeritteki küçük bilgi kutusu: ikon + metin; anlamı Semantics etiketiyle de verilir.
class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.semantics,
    required this.child,
    this.color,
    this.maxWidth = 360,
  });

  final IconData icon;
  final String semantics;
  final Widget child;
  final Color? color;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: semantics,
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: KColors.bg,
              borderRadius: BorderRadius.circular(KRadius.sm),
              border: Border.all(color: KColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color ?? KColors.muted),
                const SizedBox(width: 6),
                Flexible(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Text _chipText(String t, {Color? color, bool bold = false}) => Text(
      t,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
        color: color ?? KColors.text,
      ),
    );

// ------------------------------------------------------------------ kök ekran

/// Geliştirme Modu izleme ekranı. Veri/eylem kaynakları provider ile verilir (bkz. dev_session_providers).
class DevSessionScreen extends ConsumerStatefulWidget {
  const DevSessionScreen({super.key});

  @override
  ConsumerState<DevSessionScreen> createState() => _DevSessionScreenState();
}

class _DevSessionScreenState extends ConsumerState<DevSessionScreen> {
  late final DevWakelock _wake;
  bool _keepAwakeAfter = false;

  @override
  void initState() {
    super.initState();
    _wake = ref.read(devWakelockProvider);
    unawaited(_wake(true));
  }

  @override
  void dispose() {
    // Oturum hâlâ sürüyorsa (motor kendi kilidini tutar) ekran kilidi bırakılmaz.
    if (!_keepAwakeAfter) unawaited(_wake(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(settingsProvider.select((s) => s.themeId)); // tema değişince yeniden kur
    final lite = ref.watch(settingsProvider.select((s) => s.liteOnStart));
    final phase = ref.watch(devSessionViewProvider.select((v) => v.phase));
    ref.listen<DevSessionStatus?>(devSessionViewProvider.select((v) => v.session?.status), (_, s) {
      _keepAwakeAfter = s != null && devSessionActiveStatus(s);
    });

    Widget content;
    if (phase == DevLoadPhase.noSource) {
      content = const _Empty('Geliştirme oturumu kaynağı bağlı değil. Bir oturum başlatıldığında burada izlenir.');
    } else if (phase == DevLoadPhase.loading) {
      content = const _Empty('Oturum yükleniyor…');
    } else {
      content = LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TopStrip(compact: w < kDevMediumBreakpoint),
              const _WaitBanner(),
              const _ResilienceBanners(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: w >= kDevWideBreakpoint
                      ? const _ThreeColumns(key: ValueKey('dev-layout-wide'))
                      : (w >= kDevMediumBreakpoint
                          ? const _TwoColumns(key: ValueKey('dev-layout-medium'))
                          : const _PhoneTabs(key: ValueKey('dev-layout-tabs'))),
                ),
              ),
            ],
          );
        },
      );
    }

    final scaffold = Scaffold(
      backgroundColor: KColors.bg,
      body: SafeArea(
        child: Semantics(
          container: true,
          label: 'Geliştirme oturumu izleme ekranı',
          child: content,
        ),
      ),
    );
    // Sade Mod: bu ağaçta hiçbir animasyon çalışmaz.
    return lite ? TickerMode(enabled: false, child: scaffold) : scaffold;
  }
}

// ------------------------------------------------------------------ düzenler

class _ThreeColumns extends StatelessWidget {
  const _ThreeColumns({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 26,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 3, child: _TimelinePanel()),
              SizedBox(height: 12),
              Expanded(flex: 2, child: _ModelsPanel()),
            ],
          ),
        ),
        SizedBox(width: 12),
        Expanded(flex: 46, child: _FilesPanel(sideBySide: true)),
        SizedBox(width: 12),
        Expanded(
          flex: 28,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 6, child: _LogPanel()),
              SizedBox(height: 12),
              Expanded(flex: 5, child: _CiLedgerPanel()),
            ],
          ),
        ),
      ],
    );
  }
}

class _TwoColumns extends StatelessWidget {
  const _TwoColumns({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 3, child: _TimelinePanel()),
              SizedBox(height: 12),
              Expanded(flex: 2, child: _ModelsPanel()),
              SizedBox(height: 12),
              Expanded(flex: 3, child: _CiLedgerPanel()),
            ],
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _FilesPanel(sideBySide: false)),
              SizedBox(height: 12),
              Expanded(child: _LogPanel()),
            ],
          ),
        ),
      ],
    );
  }
}

class _PhoneTabs extends StatelessWidget {
  const _PhoneTabs({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: KColors.accent,
            unselectedLabelColor: KColors.muted,
            indicatorColor: KColors.accent,
            dividerColor: KColors.border,
            tabs: const [
              Tab(height: 48, text: 'Aşamalar'),
              Tab(height: 48, text: 'Dosyalar'),
              Tab(height: 48, text: 'Günlük'),
              Tab(height: 48, text: 'CI ve defter'),
            ],
          ),
          const SizedBox(height: 8),
          const Expanded(
            child: TabBarView(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: _TimelinePanel()),
                    SizedBox(height: 12),
                    Expanded(flex: 2, child: _ModelsPanel()),
                  ],
                ),
                _FilesPanel(sideBySide: false),
                _LogPanel(),
                _CiLedgerPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ üst şerit

class _TopStrip extends ConsumerStatefulWidget {
  const _TopStrip({required this.compact});

  final bool compact;

  @override
  ConsumerState<_TopStrip> createState() => _TopStripState();
}

class _TopStripState extends ConsumerState<_TopStrip> {
  bool _busy = false;

  Future<void> _run(Future<Object?> Function() action, String okMessage) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      final r = await action();
      final extra = r is String && r.isNotEmpty ? ' $r' : '';
      messenger?.showSnackBar(SnackBar(content: Text('$okMessage$extra')));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('İşlem başarısız: ${SecretMask.redact('$e')}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmStop(DevSessionControls c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Oturum durdurulsun mu?'),
        content: const Text(
          'Geliştirme oturumu durdurulur. Dal ve commitler silinmez; sonra kaldığı yerden devam edilebilir.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Durdur')),
        ],
      ),
    );
    if (ok == true && mounted) await _run(c.stop, 'Oturum durduruldu.');
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(devSessionViewProvider.select((v) => v.session));
    final ciState = ref.watch(devSessionViewProvider.select((v) => v.ci.state));
    final limits = ref.watch(devLimitsProvider);
    final controls = ref.watch(devControlsProvider);
    final compact = widget.compact;
    final maxW = compact ? 280.0 : 360.0;

    final chips = <Widget>[];
    if (session == null) {
      chips.add(_InfoChip(
        icon: Icons.hourglass_empty,
        semantics: 'Oturum verisi henüz yok',
        maxWidth: maxW,
        child: _chipText('Oturum verisi yok'),
      ));
    } else {
      final look = _statusLook(session.status);
      final commits = session.counters['commit'] ?? 0;
      final ci = _ciLook(ciState);
      chips.add(_InfoChip(
        icon: look.icon,
        color: look.color,
        semantics: 'Durum: ${look.label}',
        maxWidth: maxW,
        child: _chipText(look.label, color: look.color, bold: true),
      ));
      final repoBranch = [
        if (session.repo.isNotEmpty) session.repo,
        if (session.branch.isNotEmpty) session.branch,
      ].join(' · ');
      chips.add(_InfoChip(
        icon: Icons.call_split,
        semantics: 'Depo ve dal: ${repoBranch.isEmpty ? 'bilinmiyor' : repoBranch}',
        maxWidth: maxW,
        child: _chipText(repoBranch.isEmpty ? '—' : repoBranch),
      ));
      chips.add(_Ticking(
        active: devSessionActiveStatus(session.status),
        builder: (context, now) {
          final el = devElapsed(session, now);
          final rem = limits.maxDuration - el;
          final remText = devFormatDuration(rem.isNegative ? Duration.zero : rem);
          final elText = devFormatDuration(el);
          return _InfoChip(
            icon: Icons.timer_outlined,
            maxWidth: maxW,
            semantics: 'Geçen süre $elText, kalan süre $remText, azami ${_fmtLimit(limits.maxDuration)}',
            child: _chipText('Geçen $elText · Kalan $remText / ${_fmtLimit(limits.maxDuration)}'),
          );
        },
      ));
      chips.add(_InfoChip(
        icon: Icons.commit,
        semantics: 'Commit sayısı $commits, azami ${limits.maxCommits}',
        maxWidth: maxW,
        child: _chipText('Commit $commits / ${limits.maxCommits}'),
      ));
      chips.add(_InfoChip(
        icon: ci.icon,
        color: ci.color,
        semantics: ci.label,
        maxWidth: maxW,
        child: _chipText(ci.label, color: ci.color, bold: true),
      ));
      chips.add(_InfoChip(
        icon: Icons.timeline,
        semantics: 'Şu anki aşama: ${session.phase.isEmpty ? 'yok' : session.phase}',
        maxWidth: maxW,
        child: _chipText('Aşama: ${session.phase.isEmpty ? '—' : session.phase}'),
      ));
      for (final e in _roleNames.entries) {
        final m = session.models[e.key] ?? '';
        chips.add(_InfoChip(
          icon: Icons.memory,
          semantics: '${e.value} modeli: ${m.isEmpty ? 'atanmadı' : m}',
          maxWidth: maxW,
          child: _chipText('${e.value}: ${m.isEmpty ? '—' : m}'),
        ));
      }
    }

    final status = session?.status;
    final active = status != null && devSessionActiveStatus(status);
    final paused = status == DevSessionStatus.duraklatildi;
    final commitCount = session?.counters['commit'] ?? 0;
    final c = controls;
    final noCtl = c == null ? 'Denetim bağlı değil' : '';

    final buttons = <Widget>[
      _ControlButton(
        icon: paused ? Icons.play_arrow : Icons.pause,
        label: paused ? 'Devam' : 'Duraklat',
        tooltip: noCtl,
        onPressed: (c != null && !_busy && (paused || (active && c.canPause)))
            ? () => _run(paused ? c.resume : c.pause, paused ? 'Devam ediliyor.' : 'Duraklatıldı.')
            : null,
      ),
      _ControlButton(
        icon: Icons.stop_circle_outlined,
        label: 'Durdur',
        tooltip: noCtl,
        onPressed: (c != null && !_busy && active) ? () => _confirmStop(c) : null,
      ),
      _ControlButton(
        icon: Icons.merge_type,
        label: 'Dalı PR olarak aç',
        tooltip: c == null ? noCtl : (commitCount == 0 ? 'Henüz commit yok' : ''),
        onPressed: (c != null && !_busy && session != null && commitCount > 0)
            ? () => _run(c.openPullRequest, 'Taslak PR açıldı.')
            : null,
      ),
    ];

    final decoration = BoxDecoration(
      color: KColors.card,
      border: Border(bottom: BorderSide(color: KColors.border)),
    );

    if (compact) {
      return Container(
        decoration: decoration,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [for (final c in chips) Padding(padding: const EdgeInsets.only(right: 8), child: c)]),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [for (final b in buttons) Padding(padding: const EdgeInsets.only(right: 8), child: b)]),
            ),
          ],
        ),
      );
    }
    return Container(
      decoration: decoration,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [...chips, ...buttons],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({required this.icon, required this.label, required this.onPressed, this.tooltip = ''});

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final btn = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return tooltip.isEmpty ? btn : Tooltip(message: tooltip, child: btn);
  }
}

// ------------------------------------------------------------------ bekleme şeridi

class _WaitBanner extends ConsumerWidget {
  const _WaitBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(devSessionViewProvider.select((v) => v.session?.status));
    final note = ref.watch(devSessionViewProvider.select((v) => v.session?.note ?? ''));
    final wait = ref.watch(devSessionViewProvider.select((v) => v.wait));
    if (status == null || !devSessionActiveStatus(status)) return const SizedBox.shrink();
    if (status != DevSessionStatus.bekliyor && wait == null) return const SizedBox.shrink();
    final reason = wait?.reason ?? (note.isNotEmpty ? note : 'Bekleme nedeni bildirilmedi.');
    final retryAt = wait?.retryAt;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: KColors.amber.withOpacity(0.12),
          borderRadius: BorderRadius.circular(KRadius.sm),
          border: Border.all(color: KColors.amber),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.hourglass_top, size: 18, color: KColors.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Bekleniyor',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: KColors.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    reason,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, height: 1.35, color: KColors.text),
                  ),
                  const SizedBox(height: 2),
                  if (retryAt == null)
                    Text(
                      'Yeniden deneme zamanı bilinmiyor; koşullar düzelince kendiliğinden sürer.',
                      style: TextStyle(fontSize: 12, color: KColors.muted),
                    )
                  else
                    _Ticking(
                      active: true,
                      builder: (context, now) {
                        final left = retryAt.difference(now);
                        final text = left.isNegative || left.inSeconds == 0
                            ? 'Şimdi yeniden deneniyor…'
                            : 'Yeniden deneme: ${devFormatDuration(left)} sonra (${_hms(retryAt)})';
                        return Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: KColors.text));
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

// ------------------------------------------------------------------ dayanıklılık şeritleri (Görev 9/19)

/// Pil muafiyeti durumu (testlerde override edilir). Android dışında/kanal yokken `unknown`.
final devBatteryStateProvider =
    FutureProvider.autoDispose<BatteryExemptState>((ref) => BatteryOptimization.status());

class _ResilienceBanners extends ConsumerWidget {
  const _ResilienceBanners();

  Widget _box(Widget child) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: KColors.amber.withOpacity(0.12),
          borderRadius: BorderRadius.circular(KRadius.sm),
          border: Border.all(color: KColors.amber),
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(devSessionViewProvider.select((v) => v.session?.status));
    final note = ref.watch(devSessionViewProvider.select((v) => v.session?.note ?? ''));
    final interrupted = ref.watch(interruptedDevSessionProvider);
    final battery = ref.watch(devBatteryStateProvider).valueOrNull ?? BatteryExemptState.unknown;
    final controls = ref.read(devControlsProvider);
    final active = status != null && devSessionActiveStatus(status);
    final items = <Widget>[];

    if (interrupted != null && !active) {
      final sys = interrupted.serviceTimeout ? ' Ön plan servisi sistem tarafından durdurulmuştu.' : '';
      items.add(_box(Semantics(
        liveRegion: true,
        container: true,
        child: Row(children: [
          Icon(Icons.restore, size: 18, color: KColors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Yarım kalmış oturum: ${interrupted.branch}.$sys İlerleme kayıtlı; aynı dalda, aynı sayaçlarla sürer.',
              style: TextStyle(fontSize: 12.5, height: 1.35, color: KColors.text),
            ),
          ),
          TextButton(
            onPressed: () => ref.read(appProvider.notifier).resumeInterruptedDevSession(),
            child: const Text('Devam et'),
          ),
        ]),
      )));
    }

    if (status == DevSessionStatus.duraklatildi) {
      items.add(_box(Semantics(
        liveRegion: true,
        container: true,
        child: Row(children: [
          Icon(Icons.pause_circle_outline, size: 18, color: KColors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              note.isEmpty ? 'Oturum duraklatıldı.' : note,
              style: TextStyle(fontSize: 12.5, height: 1.35, color: KColors.text),
            ),
          ),
          if (controls != null)
            TextButton(onPressed: () => controls.resume(), child: const Text('Devam')),
        ]),
      )));
    }

    if (active && battery == BatteryExemptState.denied) {
      items.add(_box(Semantics(
        container: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.battery_alert, size: 18, color: KColors.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Pil optimizasyonu açık: telefon uykuya geçince oturum yavaşlayabilir veya sistem tarafından '
                'durdurulabilir. Oturum çalışır ama uzun süreli kullanım için muafiyet ver ve şarja tak.',
                style: TextStyle(fontSize: 12.5, height: 1.35, color: KColors.text),
              ),
            ),
          ]),
          Wrap(spacing: 8, children: [
            TextButton(
              onPressed: () async {
                await BatteryOptimization.request();
                ref.invalidate(devBatteryStateProvider);
              },
              child: const Text('Muafiyet iste'),
            ),
            TextButton(
              onPressed: () => maybeShowMiuiHint(context, force: true),
              child: const Text('HyperOS/MIUI ayarları'),
            ),
          ]),
        ]),
      )));
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(children: items);
  }
}

// ------------------------------------------------------------------ sol: zaman çizgisi + modeller

const Set<DevEventKind> _timelineKinds = {
  DevEventKind.asama,
  DevEventKind.commit,
  DevEventKind.ci,
  DevEventKind.geriAlma,
  DevEventKind.bekleme,
  DevEventKind.durum,
};

class _TimelinePanel extends ConsumerWidget {
  const _TimelinePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(devSessionViewProvider.select((v) => v.events));
    final phase = ref.watch(devSessionViewProvider.select((v) => v.session?.phase ?? ''));
    final shown = <DevEvent>[];
    for (var i = events.length - 1; i >= 0 && shown.length < 200; i--) {
      if (_timelineKinds.contains(events[i].kind)) shown.add(events[i]);
    }
    return _Panel(
      title: 'Aşama zaman çizgisi',
      icon: Icons.timeline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            label: 'Şu anki aşama: ${phase.isEmpty ? 'yok' : phase}',
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'Şu an: ${phase.isEmpty ? '—' : phase}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: KColors.accent),
                ),
              ),
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? const _Empty('Henüz aşama olayı yok.')
                : ListView.builder(
                    key: const ValueKey('dev-timeline-list'),
                    itemCount: shown.length,
                    itemBuilder: (context, i) => _TimelineTile(event: shown[i], last: i == shown.length - 1),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.event, required this.last});

  final DevEvent event;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final lvl = _levelColor(e.level);
    final extra = [
      if (e.sha.isNotEmpty) _shortSha(e.sha),
      if (e.level != DevEventLevel.bilgi) _levelLabel(e.level),
    ].join(' · ');
    return Semantics(
      container: true,
      label: '${_hms(e.ts)} ${_kindLabel(e.kind)}${e.level == DevEventLevel.bilgi ? '' : ', ${_levelLabel(e.level)}'}: ${e.message}',
      child: ExcludeSemantics(
        child: Stack(
          children: [
            if (!last) Positioned(left: 13, top: 22, bottom: 0, child: Container(width: 2, color: KColors.border)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 28,
                  child: Icon(_kindIcon(e.kind), size: 18, color: e.level == DevEventLevel.bilgi ? KColors.accent : lvl),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_hms(e.ts)} · ${_kindLabel(e.kind)}${extra.isEmpty ? '' : ' · $extra'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: KColors.muted),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          e.message,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, height: 1.3, color: KColors.text),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelsPanel extends ConsumerWidget {
  const _ModelsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(devSessionViewProvider.select((v) => v.session?.models ?? const <String, String>{}));
    final counters = ref.watch(devSessionViewProvider.select((v) => v.session?.counters ?? const <String, int>{}));
    final blocked = ref.watch(devSessionViewProvider.select((v) => v.session?.blockedFiles.length ?? 0));
    final ledger = ref.watch(devSessionViewProvider.select((v) => v.ledger));
    final stats = {for (final m in ledger.models) m.modelId: m};

    final counterLabels = <String, String>{
      'tur': 'Tur',
      'ret': 'Ret',
      'ciHata': 'CI hatası',
      'ciYesil': 'CI yeşil',
      'geriAlma': 'Geri alma',
      'bekleme': 'Bekleme',
      'cakisma': 'Çakışma',
      'kararli': 'Kararlı geçiş',
    };
    final counterChips = <String>[
      for (final e in counterLabels.entries)
        if ((counters[e.key] ?? 0) > 0) '${e.value}: ${counters[e.key]}',
      if (blocked > 0) 'Bloklu dosya: $blocked',
    ];
    final goal = models['hedef'] ?? '';
    final lastGreen = models['sonYesil'] ?? '';

    return _Panel(
      title: 'Modeller ve roller',
      icon: Icons.memory,
      child: ListView(
        key: const ValueKey('dev-models-list'),
        children: [
          for (final e in _roleNames.entries) _RoleRow(role: e.value, modelId: models[e.key] ?? '', stat: stats[models[e.key] ?? '']),
          if (goal.isNotEmpty) _kv('Hedef', goal),
          if (lastGreen.isNotEmpty) _kv('Son yeşil commit', _shortSha(lastGreen)),
          if (counterChips.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in counterChips)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: KColors.bg,
                      borderRadius: BorderRadius.circular(KRadius.sm),
                      border: Border.all(color: KColors.border),
                    ),
                    child: Text(t, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: KColors.text)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '$k: ', style: TextStyle(fontWeight: FontWeight.w800, color: KColors.muted)),
              TextSpan(text: v, style: TextStyle(color: KColors.text)),
            ],
          ),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12.5, height: 1.3),
        ),
      );
}

class _RoleRow extends StatelessWidget {
  const _RoleRow({required this.role, required this.modelId, required this.stat});

  final String role;
  final String modelId;
  final DevModelStat? stat;

  @override
  Widget build(BuildContext context) {
    final s = stat;
    final trust = s == null || s.samples == 0
        ? 'güven verisi yok'
        : 'ret oranı %${(s.rate * 100).round()} (${s.samples} örnek)${s.demoted ? ' · düşürüldü' : ''}';
    final assigned = modelId.isNotEmpty;
    return Semantics(
      container: true,
      label: '$role: ${assigned ? modelId : 'atanmadı'}, $trust',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(assigned ? Icons.memory : Icons.do_not_disturb_on_outlined, size: 18, color: assigned ? KColors.accent : KColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(role, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: KColors.muted)),
                    Text(
                      assigned ? modelId : 'Atanmadı',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: KColors.text),
                    ),
                    Text(
                      trust,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: s != null && s.demoted ? KColors.amber : KColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ orta: dosyalar + diff

class _FilesPanel extends ConsumerWidget {
  const _FilesPanel({required this.sideBySide});

  final bool sideBySide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final changes = ref.watch(devSessionViewProvider.select((v) => v.changes));
    final selected = ref.watch(devSelectedFileProvider);
    DevChange? sel;
    if (selected != null) {
      for (final c in changes) {
        if (c.path == selected) {
          sel = c;
          break;
        }
      }
    }
    void select(String? p) => ref.read(devSelectedFileProvider.notifier).state = p;

    final counts = <DevChangeStatus, int>{};
    for (final c in changes) {
      counts[c.status] = (counts[c.status] ?? 0) + 1;
    }
    final summary = [
      for (final s in DevChangeStatus.values)
        if ((counts[s] ?? 0) > 0) '${counts[s]} ${_changeLabel(s).toLowerCase()}',
    ].join(' · ');

    final list = _FileList(changes: changes, selected: sel?.path, onSelect: (p) => select(p));

    Widget child;
    if (sel == null) {
      child = list;
    } else if (sideBySide) {
      child = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 2, child: list),
          VerticalDivider(width: 17, color: KColors.border),
          Expanded(flex: 3, child: _DiffPane(change: sel, onClose: () => select(null), backIcon: false)),
        ],
      );
    } else {
      child = _DiffPane(change: sel, onClose: () => select(null), backIcon: true);
    }

    return _Panel(
      title: 'Değişen dosyalar (${changes.length})',
      icon: Icons.difference_outlined,
      trailing: null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (summary.isNotEmpty && sel == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: KColors.muted)),
            ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({required this.changes, required this.selected, required this.onSelect});

  final List<DevChange> changes;
  final String? selected;
  final void Function(String path) onSelect;

  @override
  Widget build(BuildContext context) {
    if (changes.isEmpty) return const _Empty('Henüz değişen dosya yok.');
    return ListView.builder(
      key: const ValueKey('dev-files-list'),
      itemCount: changes.length,
      itemBuilder: (context, i) {
        final c = changes[i];
        final isSel = c.path == selected;
        final color = _changeColor(c.status);
        final sha = c.commitSha.isEmpty ? 'commit yok' : 'commit ${_shortSha(c.commitSha)}';
        return Semantics(
          button: true,
          selected: isSel,
          label: '${_changeLabel(c.status)}: ${c.path}, $sha, ${c.commits} commit',
          excludeSemantics: true,
          onTap: () => onSelect(c.path),
          child: InkWell(
            borderRadius: BorderRadius.circular(KRadius.sm),
            onTap: () => onSelect(c.path),
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: isSel ? KColors.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(KRadius.sm),
                border: Border.all(color: isSel ? KColors.accent : KColors.border),
              ),
              child: Row(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_changeIcon(c.status), size: 18, color: color),
                      const SizedBox(height: 2),
                      Text(_changeLabel(c.status), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color)),
                    ],
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          c.path,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: KColors.text, fontFamily: 'monospace'),
                        ),
                        Text(
                          '$sha · ${c.commits} commit',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: KColors.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DiffPane extends ConsumerWidget {
  const _DiffPane({required this.change, required this.onClose, required this.backIcon});

  final DevChange change;
  final VoidCallback onClose;
  final bool backIcon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(devDiffProvider(DevDiffKey(change.path, change.commitSha)));
    Widget body;
    if (async.isLoading) {
      body = const _Empty('Diff yükleniyor…');
    } else if (async.hasError) {
      body = _Empty('Diff yüklenemedi: ${SecretMask.redact('${async.error}')}');
    } else {
      final d = async.value;
      final r = d?.result;
      if (r != null) {
        body = DevDiffView(diff: r, path: change.path);
      } else {
        final last = change.last;
        final info = last == null ? '' : '\nSon içerik: ${last.lines} satır, ${last.length} karakter (özet ${last.hash}).';
        body = _Empty('${d?.unavailable ?? 'Diff yok.'}$info');
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: backIcon ? 'Dosya listesine dön' : 'Diff görünümünü kapat',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: onClose,
              icon: Icon(backIcon ? Icons.arrow_back : Icons.close, size: 20),
            ),
            Expanded(
              child: Semantics(
                container: true,
                label: 'Diff: ${change.path}',
                child: ExcludeSemantics(
                  child: Text(
                    change.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: KColors.text, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
          ],
        ),
        Expanded(child: body),
      ],
    );
  }
}

// ------------------------------------------------------------------ sağ: günlük

class _LogPanel extends ConsumerWidget {
  const _LogPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(devSessionViewProvider.select((v) => v.events));
    final newer = ref.watch(devSessionViewProvider.select((v) => v.newer));
    final hasOlder = ref.watch(devSessionViewProvider.select((v) => v.hasOlder));
    final loadingOlder = ref.watch(devSessionViewProvider.select((v) => v.loadingOlder));
    final filter = ref.watch(devLogFilterProvider);
    final ctl = ref.read(devSessionViewProvider.notifier);

    final shown = filter == null ? events : [for (final e in events) if (e.level == filter) e];

    Widget chip(String label, DevEventLevel? lv) {
      return ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: filter == lv,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onSelected: (_) => ref.read(devLogFilterProvider.notifier).state = lv,
      );
    }

    return _Panel(
      title: 'Canlı günlük',
      icon: Icons.receipt_long_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              chip('Tümü', null),
              chip('Bilgi', DevEventLevel.bilgi),
              chip('Uyarı', DevEventLevel.uyari),
              chip('Hata', DevEventLevel.hata),
            ],
          ),
          if (newer > 0 || hasOlder)
            Wrap(
              spacing: 8,
              runSpacing: 0,
              children: [
                if (hasOlder)
                  TextButton.icon(
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: loadingOlder ? null : ctl.loadOlder,
                    icon: const Icon(Icons.history, size: 18),
                    label: Text(loadingOlder ? 'Yükleniyor…' : 'Daha eski'),
                  ),
                if (newer > 0)
                  TextButton.icon(
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: ctl.jumpToLatest,
                    icon: const Icon(Icons.vertical_align_bottom, size: 18),
                    label: Text('Canlıya dön ($newer yeni olay)'),
                  ),
              ],
            ),
          const SizedBox(height: 4),
          Expanded(
            child: shown.isEmpty
                ? _Empty(filter == null ? 'Henüz olay yok.' : 'Bu seviyede olay yok.')
                : ListView.builder(
                    key: const ValueKey('dev-log-list'),
                    reverse: true, // en yeni altta; canlıda otomatik olarak yeniye yapışık
                    itemCount: shown.length,
                    itemBuilder: (context, i) => _LogRow(event: shown[shown.length - 1 - i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.event});

  final DevEvent event;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final extra = e.sha.isEmpty ? '' : ' · ${_shortSha(e.sha)}';
    return Semantics(
      container: true,
      label: '${_hms(e.ts)} ${_levelLabel(e.level)} ${_kindLabel(e.kind)}: ${e.message}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 58,
                child: Text(_hms(e.ts), style: TextStyle(fontSize: 11, color: KColors.muted, fontFamily: 'monospace')),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  _levelLabel(e.level),
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: _levelColor(e.level)),
                ),
              ),
              Expanded(
                child: Text(
                  '${e.message}$extra',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, height: 1.3, color: KColors.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ sağ: CI + hata defteri

class _CiLedgerPanel extends ConsumerWidget {
  const _CiLedgerPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ci = ref.watch(devSessionViewProvider.select((v) => v.ci));
    final ledger = ref.watch(devSessionViewProvider.select((v) => v.ledger));
    final look = _ciLook(ci.state);
    final hasFail = ci.failures.isNotEmpty;

    return _Panel(
      title: 'CI ve hata defteri',
      icon: Icons.fact_check_outlined,
      child: ListView(
        key: const ValueKey('dev-ci-list'),
        children: [
          Semantics(
            container: true,
            label: '${look.label}${ci.stage.isEmpty ? '' : ', aşama: ${ci.stage}'}',
            child: ExcludeSemantics(
              child: Row(
                children: [
                  Icon(look.icon, size: 18, color: look.color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(look.label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: look.color)),
                  ),
                  if (ci.sha.isNotEmpty) Text(_shortSha(ci.sha), style: TextStyle(fontSize: 11.5, color: KColors.muted, fontFamily: 'monospace')),
                ],
              ),
            ),
          ),
          if (ci.stage.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Aşama: ${ci.stage}', maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: KColors.text)),
            ),
          if (hasFail) ...[
            const SizedBox(height: 6),
            Text('Hatalar (${ci.failures.length})', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: KColors.muted)),
            for (final f in ci.failures.take(8))
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('✗ $f', maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, height: 1.3, color: KColors.red)),
              ),
            if (ci.failures.length > 8)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('+${ci.failures.length - 8} hata daha', style: TextStyle(fontSize: 12, color: KColors.muted)),
              ),
          ],
          if (ci.runUrl.isNotEmpty) _RunLink(url: ci.runUrl),
          const SizedBox(height: 10),
          Divider(height: 1, color: KColors.border),
          const SizedBox(height: 8),
          _LedgerSection(ledger: ledger),
        ],
      ),
    );
  }
}

class _RunLink extends ConsumerWidget {
  const _RunLink({required this.url});

  final String url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> copy() async {
      final messenger = ScaffoldMessenger.maybeOf(context);
      await ref.read(devCopyProvider)(url);
      messenger?.showSnackBar(const SnackBar(content: Text('Bağlantı panoya kopyalandı.')));
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48), alignment: Alignment.centerLeft),
              onPressed: () async {
                final ok = await ref.read(devOpenUrlProvider)(url);
                if (!ok) await copy();
              },
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            ),
          ),
          IconButton(
            tooltip: 'Bağlantıyı kopyala',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: copy,
            icon: const Icon(Icons.copy, size: 18),
          ),
        ],
      ),
    );
  }
}

class _LedgerSection extends StatelessWidget {
  const _LedgerSection({required this.ledger});

  final DevLedgerSummary ledger;

  @override
  Widget build(BuildContext context) {
    if (ledger.models.isEmpty && ledger.gates.isEmpty) {
      return Text(
        'Hata defteri: henüz ret yok.',
        style: TextStyle(fontSize: 12.5, color: KColors.muted),
      );
    }
    final top = ledger.gates.isEmpty ? null : ledger.gates.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Hata defteri', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: KColors.text)),
        if (top != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'En sık kapı: ${top.code} ${_gateTitle(top.code)} (${top.count})',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: KColors.amber),
            ),
          ),
        const SizedBox(height: 6),
        for (final m in ledger.models.take(6)) _ModelRejectRow(stat: m),
        if (ledger.gates.length > 1) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final g in ledger.gates.take(6))
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: KColors.bg,
                    borderRadius: BorderRadius.circular(KRadius.sm),
                    border: Border.all(color: KColors.border),
                  ),
                  child: Text('${g.code} × ${g.count}', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: KColors.text)),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ModelRejectRow extends StatelessWidget {
  const _ModelRejectRow({required this.stat});

  final DevModelStat stat;

  @override
  Widget build(BuildContext context) {
    final known = stat.samples > 0;
    final pct = (stat.rate * 100).round();
    final text = known ? 'ret oranı %$pct · ${stat.rejects} ret' : '${stat.rejects} ret';
    return Semantics(
      container: true,
      label: '${stat.modelId}: $text${stat.demoted ? ', düşürüldü' : ''}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(stat.modelId, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: KColors.text)),
              const SizedBox(height: 3),
              if (known)
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: stat.rate.clamp(0.0, 1.0),
                    minHeight: 5,
                    color: stat.demoted ? KColors.red : KColors.accent,
                    backgroundColor: KColors.border,
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                '$text${stat.demoted ? ' · düşürüldü' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: stat.demoted ? KColors.amber : KColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
