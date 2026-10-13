import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../core/theme.dart';
import '../domain/entities.dart';
import '../domain/inference_settings.dart';
import 'flow_graph.dart';
import 'miui_hint.dart';

class AgentCard extends ConsumerStatefulWidget {
  final AgentConfig agent;
  final bool isFirst;
  final bool isLast;

  const AgentCard({
    super.key,
    required this.agent,
    required this.isFirst,
    required this.isLast,
  });

  @override
  ConsumerState<AgentCard> createState() => _AgentCardState();
}

class _AgentCardState extends ConsumerState<AgentCard> {
  late final TextEditingController _name;
  late final TextEditingController _system;
  late final TextEditingController _user;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.agent.name);
    _system = TextEditingController(text: widget.agent.systemPrompt);
    _user = TextEditingController(text: widget.agent.userPrompt);
  }

  @override
  void dispose() {
    _name.dispose();
    _system.dispose();
    _user.dispose();
    super.dispose();
  }

  AppController get _c => ref.read(appProvider.notifier);

  void _update(AgentConfig a) => _c.updateAgent(a);

  AgentConfig _withInf(AgentConfig a, InferenceSettings i) => a.copyWith(inference: i);

  Widget _slider({
    required String title,
    required String hint,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required bool enabled,
    required ValueChanged<double> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(title, style: TextStyle(fontSize: 12, color: KColors.text)),
          ),
          Text(
            value.toStringAsFixed(2),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: KColors.amber),
          ),
        ],
      ),
      Slider(
        value: value.clamp(min, max).toDouble(),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: enabled ? onChanged : null,
      ),
      Text(hint, style: TextStyle(fontSize: 10.5, color: KColors.muted)),
    ],
  );

  Widget _inferenceSection(AgentConfig a, bool running) {
    final inf = a.inference;
    const caps = <int>[0, 256, 512, 1024, 2048, 4096];
    final capValue = caps.contains(inf.maxTokens ?? 0) ? (inf.maxTokens ?? 0) : 0;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          'ÜRETİM AYARLARI${inf.isDefault ? '' : '  •  özel'}',
          style: TextStyle(
            fontSize: 10.5,
            color: KColors.muted,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        children: [
          _slider(
            title: 'Sıcaklık',
            hint: 'Düşük: tutarlı ve kesin (kod, denetim). Yüksek: daha yaratıcı.',
            value: inf.temperature,
            min: 0.0,
            max: 1.5,
            divisions: 30,
            enabled: !running,
            onChanged: (v) => _update(_withInf(a, inf.copyWith(temperature: v))),
          ),
          _slider(
            title: 'Top-P',
            hint: 'Olası sözcük havuzunun genişliği; 0.9 çoğu iş için uygundur.',
            value: inf.topP,
            min: 0.1,
            max: 1.0,
            divisions: 18,
            enabled: !running,
            onChanged: (v) => _update(_withInf(a, inf.copyWith(topP: v))),
          ),
          _slider(
            title: 'Tekrar cezası',
            hint: 'Yüksek değer tekrarı azaltır; çok yükseği kodu bozabilir.',
            value: inf.repeatPenalty,
            min: 1.0,
            max: 1.5,
            divisions: 25,
            enabled: !running,
            onChanged: (v) => _update(_withInf(a, inf.copyWith(repeatPenalty: v))),
          ),
          _label('AZAMİ ÇIKTI (TOKEN)'),
          DropdownButtonFormField<int>(
            value: capValue,
            isExpanded: true,
            dropdownColor: KColors.card,
            style: TextStyle(fontSize: 13, color: KColors.text),
            items: [
              for (final c in caps)
                DropdownMenuItem(value: c, child: Text(c == 0 ? 'Otomatik (bağlama göre)' : '$c')),
            ],
            onChanged: running
                ? null
                : (c) {
                    if (c == null) return;
                    _update(
                      _withInf(a, c == 0 ? inf.copyWith(clearMaxTokens: true) : inf.copyWith(maxTokens: c)),
                    );
                  },
          ),
          Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Bağlam penceresi her zaman üst sınırdır; bu değer yalnızca çıktıyı kısaltabilir.',
              style: TextStyle(fontSize: 10.5, color: KColors.muted),
            ),
          ),
          if (!inf.isDefault)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: running ? null : () => _update(_withInf(a, const InferenceSettings())),
                child: const Text('Varsayılana dön', style: TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }


  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 5, top: 10),
    child: Text(
      t,
      style: TextStyle(
        fontSize: 10.5,
        color: KColors.muted,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final a = widget.agent;
    final s = ref.watch(appProvider);
    final running = s.running;
    final selected = s.selectedAgentId == a.id;
    final models = s.models;
    final color = modeColor(a.mode);
    final hasModel = models.any((m) => m.id == a.modelId);
    return GestureDetector(
      onTap: () => _c.selectAgent(a.id),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: KColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? color : KColors.border,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: color.withOpacity(0.18),
                  child: Text(
                    '${a.order}',
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _name,
                    enabled: !running,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      fillColor: Colors.transparent,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (v) => _update(a.copyWith(name: v)),
                  ),
                ),
                if (a.status == AgentStatus.completed)
                  Icon(
                    Icons.check_circle,
                    size: 18,
                    color: KColors.green,
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.isFirst || running
                      ? null
                      : () => _c.moveAgent(a.id, -1),
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.isLast || running
                      ? null
                      : () => _c.moveAgent(a.id, 1),
                  icon: const Icon(Icons.arrow_downward, size: 18),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: running ? null : () => _c.deleteAgent(a.id),
                  icon: Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: KColors.red,
                  ),
                ),
              ],
            ),
            _label('İŞLEV MODU'),
            DropdownButtonFormField<AgentMode>(
              value: a.mode,
              isExpanded: true,
              dropdownColor: KColors.card,
              style: TextStyle(fontSize: 13, color: KColors.text),
              items: [
                for (final m in AgentMode.values)
                  DropdownMenuItem(value: m, child: Text(m.label)),
              ],
              onChanged: running
                  ? null
                  : (m) {
                      if (m != null) _update(a.copyWith(mode: m));
                    },
            ),
            if (a.mode == AgentMode.converter || a.mode == AgentMode.export)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  'İsteğe bağlı ajan',
                  style: TextStyle(fontSize: 12.5),
                ),
                subtitle: Text(
                  'Açıksa çalıştırma atlanır; biçimlendirmeyi nihai dosya motoru yapar.',
                  style: TextStyle(fontSize: 10.5, color: KColors.muted),
                ),
                value: a.optional,
                onChanged: running
                    ? null
                    : (value) => _update(a.copyWith(optional: value)),
              ),
            _label('MODEL (GGUF)'),
            DropdownButtonFormField<String>(
              value: hasModel ? a.modelId : null,
              isExpanded: true,
              dropdownColor: KColors.card,
              style: TextStyle(fontSize: 13, color: KColors.text),
              items: [
                for (final m in models)
                  DropdownMenuItem(
                    value: m.id,
                    child: Text(
                      '${m.isCached ? '✓' : '⬇'}  ${m.name} • ${m.quantization}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: running
                  ? null
                  : (id) {
                      if (id == null) return;
                      _update(a.copyWith(modelId: id));
                      final m = models.firstWhere((x) => x.id == id);
                      if (!m.isCached)
                        maybeShowMiuiHint(
                          context,
                        ).whenComplete(() => _c.startDownload(id));
                    },
            ),
            if (a.mode == AgentMode.debugger) ...[
              _label('DÖNGÜ SAYISI (N)'),
              Row(
                children: [
                  IconButton.outlined(
                    visualDensity: VisualDensity.compact,
                    onPressed: running || a.maxLoops <= 1
                        ? null
                        : () => _update(a.copyWith(maxLoops: a.maxLoops - 1)),
                    icon: const Icon(Icons.remove, size: 16),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text(
                      '${a.maxLoops}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: KColors.amber,
                      ),
                    ),
                  ),
                  IconButton.outlined(
                    visualDensity: VisualDensity.compact,
                    onPressed: running || a.maxLoops >= 10
                        ? null
                        : () => _update(a.copyWith(maxLoops: a.maxLoops + 1)),
                    icon: const Icon(Icons.add, size: 16),
                  ),
                ],
              ),
            ],
            _inferenceSection(a, running),
            _label('SİSTEM İSTEMİ'),
            TextField(
              controller: _system,
              enabled: !running,
              minLines: 2,
              maxLines: 5,
              style: const TextStyle(fontSize: 12.5),
              onChanged: (v) => _update(a.copyWith(systemPrompt: v)),
            ),
            _label('KULLANICI İSTEMİ'),
            TextField(
              controller: _user,
              enabled: !running,
              minLines: 2,
              maxLines: 5,
              style: const TextStyle(fontSize: 12.5),
              onChanged: (v) => _update(a.copyWith(userPrompt: v)),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Ek dosyalar (${a.attachedFiles.length})',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: KColors.muted,
                    ),
                  ),
                ),
                OutlinedButton(
                  onPressed: running ? null : () => _c.attachFiles(a.id),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('+ Dosya Ekle'),
                ),
              ],
            ),
            if (a.attachedFiles.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final f in a.attachedFiles)
                      InputChip(
                        label: Text(
                          f.name,
                          style: const TextStyle(fontSize: 11),
                        ),
                        visualDensity: VisualDensity.compact,
                        onDeleted: running
                            ? null
                            : () => _update(
                                a.copyWith(
                                  attachedFiles: a.attachedFiles
                                      .where((x) => x.id != f.id)
                                      .toList(),
                                ),
                              ),
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
