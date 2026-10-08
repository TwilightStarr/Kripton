// Değişiklik: yeni dosya. Bulut motoru ayarları (API anahtarları, model adları, sıra, araştırma).
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/cloud_engine.dart';

Future<void> showCloudSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => const _CloudSettingsBody(),
  );
}

class _CloudSettingsBody extends StatefulWidget {
  const _CloudSettingsBody();

  @override
  State<_CloudSettingsBody> createState() => _CloudSettingsBodyState();
}

class _CloudSettingsBodyState extends State<_CloudSettingsBody> {
  final CloudConfig _cfg = CloudConfig.instance;
  late final Map<CloudProvider, TextEditingController> _keys;
  late final Map<CloudProvider, TextEditingController> _models;
  late final Map<CloudProvider, bool> _enabled;
  late List<CloudProvider> _order;
  late bool _research;
  late bool _hybrid;
  final Set<CloudProvider> _hidden = {for (final p in CloudProvider.values) p};

  @override
  void initState() {
    super.initState();
    _keys = {
      for (final p in CloudProvider.values) p: TextEditingController(text: _cfg.providers[p]!.apiKey),
    };
    _models = {
      for (final p in CloudProvider.values) p: TextEditingController(text: _cfg.providers[p]!.model),
    };
    _enabled = {for (final p in CloudProvider.values) p: _cfg.providers[p]!.enabled};
    _order = List<CloudProvider>.of(_cfg.order);
    _research = _cfg.research;
    _hybrid = _cfg.hybrid;
  }

  @override
  void dispose() {
    for (final c in _keys.values) {
      c.dispose();
    }
    for (final c in _models.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _move(int index, int delta) {
    final to = index + delta;
    if (to < 0 || to >= _order.length) return;
    setState(() {
      final p = _order.removeAt(index);
      _order.insert(to, p);
    });
  }

  Future<void> _save() async {
    for (final p in CloudProvider.values) {
      final c = _cfg.providers[p]!;
      c.apiKey = _keys[p]!.text.trim();
      final m = _models[p]!.text.trim();
      c.model = m.isEmpty ? p.defaultModel : m;
      c.enabled = _enabled[p]!;
    }
    _cfg.order = List<CloudProvider>.of(_order);
    _cfg.research = _research;
    _cfg.hybrid = _hybrid;
    await _cfg.save();
    if (mounted) Navigator.of(context).pop();
  }

  Widget _providerCard(CloudProvider p) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(p.label, style: const TextStyle(fontWeight: FontWeight.w700))),
              Switch(
                value: _enabled[p]!,
                onChanged: (v) => setState(() => _enabled[p] = v),
              ),
            ],
          ),
          Text('Anahtar: ${p.keyHint}', style: TextStyle(fontSize: 11, color: KColors.muted)),
          const SizedBox(height: 8),
          TextField(
            controller: _keys[p],
            obscureText: _hidden.contains(p),
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API anahtarı',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_hidden.contains(p) ? Icons.visibility : Icons.visibility_off, size: 18),
                onPressed: () => setState(() {
                  if (!_hidden.remove(p)) _hidden.add(p);
                }),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _models[p],
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Model adı',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Bulut motorları', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(
                'Anahtarlar yalnızca bu telefonda, uygulamanın özel klasöründe saklanır. İstekler doğrudan '
                'ilgili sağlayıcıya gider. Ücretsiz katmanlarda istekleriniz sağlayıcı tarafından ürün '
                'geliştirmede kullanılabilir; gizli kodu bulut motoruyla işleme.',
                style: TextStyle(fontSize: 12, color: KColors.muted, height: 1.4),
              ),
              const SizedBox(height: 14),
              for (final p in CloudProvider.values) _providerCard(p),
              const Text('Otomatik mod sırası', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              for (var i = 0; i < _order.length; i++)
                Row(
                  children: [
                    Text('${i + 1}. ${_order[i].label}'),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.arrow_upward, size: 18),
                      onPressed: i == 0 ? null : () => _move(i, -1),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_downward, size: 18),
                      onPressed: i == _order.length - 1 ? null : () => _move(i, 1),
                    ),
                  ],
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _hybrid,
                onChanged: (v) => setState(() => _hybrid = v),
                title: const Text('Hibrit: önce yerel, sonra bulut'),
                subtitle: Text(
                  'Otonom modda işi yerel modeller yapar; yerel model takılırsa kısa süre, kararlı olunca ve '
                  'süre bitmeden önce bulut modelleri son bir doğrulama geçişi yapar.',
                  style: TextStyle(fontSize: 11.5, color: KColors.muted),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _research,
                onChanged: (v) => setState(() => _research = v),
                title: const Text('Otonom modda web araştırması'),
                subtitle: Text(
                  'Hedef yazıldıysa Gemini + Google Arama ile güncel bilgi toplar (Gemini anahtarı gerekir).',
                  style: TextStyle(fontSize: 11.5, color: KColors.muted),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: _save, child: const Text('Kaydet')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
