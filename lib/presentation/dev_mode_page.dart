import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../application/app_controller.dart';
import '../application/dev_mode.dart';
import '../core/theme.dart';
import '../domain/entities.dart';
import 'cancel_dialog.dart';
import 'chat_page.dart';
import 'home_page.dart';
import 'live_status.dart';
import 'model_manager_page.dart';

/// Ana ekranda sola kaydırınca açılan "Geliştirme Modu".
///
/// Kullanıcı yalnızca üç şey girer: proje ZIP'i, tur sayısı ve hangi AI'ların çalışacağı.
/// Her turda 1. AI hataları bulur, 2. AI düzeltir ve yeni TAM ZIP üretilir; ZIP bir sonraki turun
/// girdisi olur. Tur sayısı dolunca durur.
class DevModePage extends ConsumerStatefulWidget {
  const DevModePage({super.key});

  /// Sağdan kayarak açan sayfa geçişi (sola kaydırma hareketiyle uyumlu).
  static Route<void> route() => PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) => const DevModePage(),
    transitionsBuilder: (_, animation, __, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
      child: child,
    ),
  );

  @override
  ConsumerState<DevModePage> createState() => _DevModePageState();
}

class _DevModePageState extends ConsumerState<DevModePage> {
  final _rounds = TextEditingController(text: '3');
  bool _coverAll = false;
  String? _zipPath;
  String _zipName = '';
  int _zipSize = 0;
  String? _analystId;
  String? _fixerId;

  @override
  void dispose() {
    _rounds.dispose();
    super.dispose();
  }

  int? get _roundCount {
    final n = int.tryParse(_rounds.text.trim());
    if (n == null || n < 1) return null;
    return n > kDevMaxRounds ? kDevMaxRounds : n;
  }

  /// Varsayılan: hem analiz hem düzeltme için talimat uyan birincil model (Qwen); akıl yürütme
  /// modeli (DeepSeek R1) bütçeyi düşünmeye harcayıp boş çıktı verebildiği için varsayılan değildir.
  String? _defaultId(AppState s) {
    final cached = s.models.where((m) => m.isCached).toList();
    if (cached.isEmpty) return null;
    final pick = s.defaultPick?.primaryId;
    for (final m in cached) {
      if (m.id == pick) return m.id;
    }
    return cached.first.id;
  }

  Future<void> _pickZip() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    final f = res?.files.single;
    if (f == null || f.path == null) return;
    setState(() {
      _zipPath = f.path;
      _zipName = f.name;
      _zipSize = f.size;
    });
  }

  String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1048576).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appProvider);
    final c = ref.read(appProvider.notifier);
    final models = s.models;
    final cachedIds = {for (final m in models) if (m.isCached) m.id};
    // Seçili model silindiyse/yoksa varsayılana dön.
    final analystId = cachedIds.contains(_analystId) ? _analystId : _defaultId(s);
    final fixerId = cachedIds.contains(_fixerId) ? _fixerId : _defaultId(s);
    final rounds = _roundCount;
    final canStart =
        !s.running &&
        !s.cancelling &&
        _zipPath != null &&
        (_coverAll || rounds != null) &&
        analystId != null &&
        fixerId != null;
    final dev = s.dev;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: const Text('Geliştirme Modu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Mod değiştir',
            icon: const Icon(Icons.swap_horiz),
            onSelected: (v) {
              final nav = Navigator.of(context);
              if (v == 'chat') {
                nav.push(ChatPage.route());
              } else if (nav.canPop()) {
                nav.pop();
              } else {
                nav.push(MaterialPageRoute<void>(builder: (_) => const HomePage()));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'flow', child: Text('AI Akışı modu')),
              PopupMenuItem(value: 'chat', child: Text('Sohbet modu')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 130),
            children: [
              _card(
                child: Text(
                  '1. AI projedeki hataları, eksikleri ve hata üretebilecek yerleri bulur → 2. AI bunları düzeltir → '
                  'yeni TAM ZIP üretilir → ZIP tekrar 1. AI\'a verilir. Girdiğin tur sayısı kadar sürer, sonra durur.',
                  style: TextStyle(color: KColors.muted, fontSize: 12.5, height: 1.4),
                ),
              ),
              const SizedBox(height: 12),
              _card(
                title: '1. PROJE ZIP\'İ',
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _zipPath == null ? 'ZIP seçilmedi' : '$_zipName  (${_size(_zipSize)})',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _zipPath == null ? KColors.muted : KColors.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: s.running ? null : _pickZip,
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: Text(_zipPath == null ? 'ZIP seç' : 'Değiştir'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _card(
                title: '2. KAÇ TUR?',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Tüm projeyi gez', style: TextStyle(fontSize: 13)),
                      subtitle: Text(
                        'Tur sayısını yok sayar: her kaynak dosya baştan sona bir kez incelenene kadar '
                        'parça parça otomatik sürer (en çok $kDevMaxStepsCoverAll adım).',
                        style: TextStyle(fontSize: 11, color: KColors.muted),
                      ),
                      value: _coverAll,
                      onChanged: s.running ? null : (v) => setState(() => _coverAll = v),
                    ),
                    if (_coverAll)
                      Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          'Her adım en fazla 2 model çalıştırması yapar; büyük projede uzun sürebilir. '
                          'Şarjdayken çalıştır, istediğin an iptal edebilirsin (o ana kadarki ZIP korunur).',
                          style: TextStyle(fontSize: 11.5, color: KColors.muted),
                        ),
                      )
                    else ...[
                    Row(
                      children: [
                        IconButton.outlined(
                          onPressed: s.running || (rounds ?? 1) <= 1
                              ? null
                              : () => setState(() => _rounds.text = '${(rounds ?? 2) - 1}'),
                          icon: const Icon(Icons.remove),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 84,
                          child: TextField(
                            controller: _rounds,
                            enabled: !s.running,
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconButton.outlined(
                          onPressed: s.running || (rounds ?? 0) >= kDevMaxRounds
                              ? null
                              : () => setState(() => _rounds.text = '${(rounds ?? 0) + 1}'),
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final n in const [1, 3, 5, 10])
                          ChoiceChip(
                            label: Text('$n'),
                            selected: rounds == n,
                            onSelected: s.running ? null : (_) => setState(() => _rounds.text = '$n'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      rounds == null
                          ? '1 ile $kDevMaxRounds arasında bir sayı gir.'
                          : 'En çok $kDevMaxRounds tur. Her tur en fazla 2 model çalıştırması yapar (≈ ${rounds * 2}); telefonda uzun sürebilir, şarjdayken çalıştır.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: rounds == null ? KColors.red : KColors.muted,
                      ),
                    ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _card(
                title: '3. HANGİ AI?',
                child: cachedIds.isEmpty
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'İndirilmiş model yok. Önce Model Yöneticisi\'nden bir model indir.',
                            style: TextStyle(color: KColors.amber, fontSize: 12.5),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(builder: (_) => const ModelManagerPage()),
                            ),
                            icon: const Icon(Icons.memory, size: 16),
                            label: const Text('Model yöneticisi'),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _modelPicker(
                            label: '1. AI — hataları bulur',
                            value: analystId,
                            models: models,
                            enabled: !s.running,
                            onChanged: (v) => setState(() => _analystId = v),
                          ),
                          const SizedBox(height: 12),
                          _modelPicker(
                            label: '2. AI — düzeltir',
                            value: fixerId,
                            models: models,
                            enabled: !s.running,
                            onChanged: (v) => setState(() => _fixerId = v),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'İpucu: ikisi için de talimat uyan bir model (Qwen) seç. DeepSeek R1 akıl yürütme modelidir; '
                            'çıktı bütçesini düşünmeye harcayıp boş yanıt verebilir.',
                            style: TextStyle(fontSize: 11.5, color: KColors.muted, height: 1.35),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: s.running
                    ? FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: KColors.red, foregroundColor: Colors.white),
                        onPressed: s.cancelling ? null : () => confirmAndCancel(context, ref),
                        icon: const Icon(Icons.cancel_outlined),
                        label: Text(s.cancelling ? 'İptal ediliyor…' : 'İptal Et'),
                      )
                    : FilledButton.icon(
                        onPressed: canStart
                            ? () => c.startDevMode(
                                DevModeConfig(
                                  zipPath: _zipPath!,
                                  rounds: rounds ?? 1,
                                  analystModelId: analystId!,
                                  fixerModelId: fixerId!,
                                  coverAll: _coverAll,
                                ),
                              )
                            : null,
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text('Geliştirmeyi Başlat'),
                      ),
              ),
              if (dev != null) ...[
                const SizedBox(height: 16),
                _progress(dev, s.running),
              ],
            ],
          ),
          const Positioned(left: 0, right: 0, bottom: 0, child: LiveStatusBar(showLite: false)),
        ],
      ),
    );
  }

  Widget _card({String? title, required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: KColors.card,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: KColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Text(
            title,
            style: TextStyle(fontSize: 10.5, color: KColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.6),
          ),
          const SizedBox(height: 8),
        ],
        child,
      ],
    ),
  );

  Widget _modelPicker({
    required String label,
    required String? value,
    required List<GgufModel> models,
    required bool enabled,
    required ValueChanged<String?> onChanged,
  }) => DropdownButtonFormField<String>(
    value: value,
    isExpanded: true,
    dropdownColor: KColors.card,
    decoration: InputDecoration(labelText: label),
    style: TextStyle(fontSize: 13, color: KColors.text, fontWeight: FontWeight.w600),
    items: [
      for (final m in models)
        DropdownMenuItem<String>(
          value: m.id,
          enabled: m.isCached,
          child: Text(
            m.isCached ? m.name : '${m.name} (indirilmedi)',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: m.isCached ? KColors.text : KColors.muted),
          ),
        ),
    ],
    onChanged: enabled ? onChanged : null,
  );

  static (IconData, Color, String) _statusLook(DevRoundStatus st) => switch (st) {
    DevRoundStatus.fixed => (Icons.check_circle, KColors.green, 'Düzeltildi'),
    DevRoundStatus.clean => (Icons.verified_outlined, KColors.accent, 'Hata bulunamadı'),
    DevRoundStatus.noPatch => (Icons.warning_amber_rounded, KColors.amber, 'Yama uygulanamadı'),
    DevRoundStatus.failed => (Icons.error_outline, KColors.red, 'Başarısız'),
  };

  Widget _progress(DevProgress dev, bool running) {
    final done = dev.results.length;
    return _card(
      title: 'İLERLEME',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            dev.active
                ? 'Tur ${dev.round}/${dev.total} · ${dev.phase}'
                : '${dev.phase} · $done/${dev.total} tur, ${dev.fixedRounds} turda düzeltme',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: dev.total == 0 ? null : (done / dev.total).clamp(0.0, 1.0),
            color: KColors.accent,
            backgroundColor: KColors.border,
            minHeight: 5,
          ),
          const SizedBox(height: 10),
          for (final r in dev.results.reversed)
            Builder(
              builder: (_) {
                final (icon, color, label) = _statusLook(r.status);
                return Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    leading: Icon(icon, color: color, size: 20),
                    title: Text('Tur ${r.round} — $label', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    subtitle: Text(
                      r.reviewed.join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: KColors.muted),
                    ),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (r.findings > 0) Text('Bulunan sorun: ${r.findings}', style: const TextStyle(fontSize: 12)),
                      if (r.changedFiles.isNotEmpty)
                        Text('Değişen dosyalar: ${r.changedFiles.join(', ')}', style: const TextStyle(fontSize: 12)),
                      for (final n in r.notes)
                        Text('• $n', style: TextStyle(fontSize: 11.5, color: KColors.amber)),
                      if (r.report.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('1. AI raporu', style: TextStyle(fontSize: 11, color: KColors.muted, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        SelectableText(
                          r.report.trim(),
                          style: const TextStyle(fontSize: 11.5, height: 1.35, fontFamily: 'monospace'),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          if (!running && dev.zipPath != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => OpenFilex.open(dev.zipPath!),
                icon: const Icon(Icons.folder_zip_outlined),
                label: const Text('Güncel ZIP\'i aç / paylaş'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
