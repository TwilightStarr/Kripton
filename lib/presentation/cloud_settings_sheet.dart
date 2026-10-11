// Değişiklik: bulut ayarlarına "Anahtarı sına ve modelleri getir", aranabilir model seçici,
// 1 token'lık model testi (yeşil/kırmızı durum) ve model adı temizleme eklendi.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/cloud_engine.dart';
import '../data/cloud_models.dart';

Future<void> showCloudSettingsSheet(BuildContext context, {CloudModelService? service}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => _CloudSettingsBody(service: service ?? CloudModelService()),
  );
}

/// Aranabilir model seçim listesi (alt sayfa). Seçilen model kimliğini döndürür; kapatılırsa null.
Future<String?> showCloudModelPicker(
  BuildContext context, {
  required CloudProvider provider,
  required List<CloudModelInfo> models,
  required String current,
  int filteredOut = 0,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => _ModelPickerBody(
      provider: provider,
      models: models,
      current: current,
      filteredOut: filteredOut,
    ),
  );
}

class _ModelPickerBody extends StatefulWidget {
  const _ModelPickerBody({
    required this.provider,
    required this.models,
    required this.current,
    required this.filteredOut,
  });

  final CloudProvider provider;
  final List<CloudModelInfo> models;
  final String current;
  final int filteredOut;

  @override
  State<_ModelPickerBody> createState() => _ModelPickerBodyState();
}

class _ModelPickerBodyState extends State<_ModelPickerBody> {
  final TextEditingController _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final inset = media.viewInsets.bottom;
    final height = math.max(280.0, media.size.height * 0.85 - inset);
    final q = _q.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.models
        : [
            for (final m in widget.models)
              if (m.id.toLowerCase().contains(q) || m.label.toLowerCase().contains(q)) m,
          ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: inset),
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.provider.label} modelleri',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  '${widget.models.length} sohbet modeli'
                  '${widget.filteredOut > 0 ? ' · ${widget.filteredOut} sohbet dışı model (embedding, ses, görsel…) gizlendi' : ''}',
                  style: TextStyle(fontSize: 11.5, color: KColors.muted),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _search,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (v) => setState(() => _q = v),
                  decoration: const InputDecoration(
                    hintText: 'Model ara…',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: shown.isEmpty
                      ? Center(
                          child: Text('Eşleşen model yok.', style: TextStyle(color: KColors.muted)),
                        )
                      : ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (context, i) {
                            final m = shown[i];
                            final selected = m.id == widget.current;
                            final sub = [
                              if (m.label.isNotEmpty && m.label != m.id) m.label,
                              if (m.contextTokens != null) '${m.contextTokens} token bağlam',
                            ].join(' · ');
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                m.id,
                                style: TextStyle(
                                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                                  color: selected ? KColors.accent : KColors.text,
                                ),
                              ),
                              subtitle: sub.isEmpty
                                  ? null
                                  : Text(sub, style: TextStyle(fontSize: 11, color: KColors.muted)),
                              trailing: selected ? Icon(Icons.check, size: 18, color: KColors.accent) : null,
                              onTap: () => Navigator.of(context).pop(m.id),
                            );
                          },
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

/// Kart içinde gösterilen yeşil/kırmızı durum satırının verisi.
class _Status {
  const _Status(this.ok, this.text);

  final bool ok;
  final String text;
}

class _CloudSettingsBody extends StatefulWidget {
  const _CloudSettingsBody({required this.service});

  final CloudModelService service;

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

  CloudModelService get _service => widget.service;

  /// Sağlayıcıdan alınan sohbet modelleri (seçim listesi).
  final Map<CloudProvider, List<CloudModelInfo>> _known = {};
  final Map<CloudProvider, int> _filteredOut = {};
  final Set<CloudProvider> _fetching = {};
  final Set<CloudProvider> _testing = {};
  final Map<CloudProvider, _Status> _keyStatus = {};
  final Map<CloudProvider, _Status> _modelStatus = {};

  /// Liste alınamayınca önerilen varsayılan model.
  final Map<CloudProvider, String> _suggest = {};

  /// Son başarılı sınanan "anahtar|model" imzası (aynı değerler için testi tekrarlamamak için).
  final Map<CloudProvider, String> _verified = {};
  bool _saving = false;
  String? _warn;

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

  /// Alandaki model adını temizler (boşluk, büyük/küçük harf, `models/` öneki); boşsa varsayılana döner.
  String _normalizedModel(CloudProvider p) {
    final known = _known[p]?.map((e) => e.id);
    final m = normalizeModelName(_models[p]!.text, known: known);
    return m.isEmpty ? p.defaultModel : m;
  }

  /// Anahtarı sınar, sohbet modellerini getirir ve başarılıysa seçim listesini açar.
  Future<void> _fetch(CloudProvider p) async {
    if (_fetching.contains(p) || _saving) return;
    setState(() {
      _fetching.add(p);
      _keyStatus.remove(p);
      _suggest.remove(p);
    });
    final r = await _service.fetchModels(p, _keys[p]!.text);
    if (!mounted) return;
    if (r.ok) {
      setState(() {
        _fetching.remove(p);
        _known[p] = r.models;
        _filteredOut[p] = r.filteredOut;
        _keyStatus[p] = _Status(true, r.message);
      });
      await _pick(p);
    } else {
      setState(() {
        _fetching.remove(p);
        if (r.kind == CloudCheckKind.invalidKey || r.kind == CloudCheckKind.noKey) _known.remove(p);
        _keyStatus[p] = _Status(false, r.message);
        final s = r.suggestedModel;
        if (s != null) _suggest[p] = s;
      });
    }
  }

  /// Model seçim listesini açar; seçilen model alana yazılır ve hemen sınanır.
  Future<void> _pick(CloudProvider p) async {
    final list = _known[p];
    if (list == null || list.isEmpty) {
      await _fetch(p);
      return;
    }
    final chosen = await showCloudModelPicker(
      context,
      provider: p,
      models: list,
      current: _normalizedModel(p),
      filteredOut: _filteredOut[p] ?? 0,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _models[p]!.text = chosen;
      _modelStatus.remove(p);
      _suggest.remove(p);
    });
    await _testModel(p);
  }

  /// Seçili modele 1 token'lık istek atar; sonucu kartta gösterir. Çalışıyorsa true.
  Future<bool> _testModel(CloudProvider p, {bool skipIfVerified = false}) async {
    final key = _keys[p]!.text.trim();
    final model = _normalizedModel(p);
    final sig = '$key|$model';
    if (skipIfVerified && _verified[p] == sig) return true;
    if (key.isEmpty) {
      setState(() => _modelStatus[p] = const _Status(false, 'Model sınanamadı: önce API anahtarını gir.'));
      return false;
    }
    setState(() {
      _testing.add(p);
      _modelStatus.remove(p);
    });
    final r = await _service.testModel(p, key, model);
    if (!mounted) return r.ok;
    setState(() {
      _testing.remove(p);
      if (r.ok) {
        _verified[p] = sig;
        final ms = r.latencyMs == null ? '' : ' (${r.latencyMs} ms)';
        _modelStatus[p] = _Status(true, 'Model çalışıyor: $model$ms');
      } else {
        _verified.remove(p);
        _modelStatus[p] = _Status(false, 'Model sınanamadı ($model): ${r.message}');
      }
    });
    return r.ok;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _warn = null;
    });
    // Kaydetmeden önce etkin sağlayıcıların modelleri 1 token'lık istekle sınanır (paralel, en çok 20 sn).
    final targets = [
      for (final p in CloudProvider.values)
        if (_enabled[p]! && _keys[p]!.text.trim().isNotEmpty) p,
    ];
    final results = await Future.wait([for (final p in targets) _testModel(p, skipIfVerified: true)]);
    if (!mounted) return;
    final failed = [
      for (var i = 0; i < targets.length; i++)
        if (!results[i]) targets[i].label,
    ];
    // Başarısız test kaydı engellemez.
    for (final p in CloudProvider.values) {
      final c = _cfg.providers[p]!;
      c.apiKey = _keys[p]!.text.trim();
      c.model = _normalizedModel(p);
      _models[p]!.text = c.model;
      c.enabled = _enabled[p]!;
    }
    _cfg.order = List<CloudProvider>.of(_order);
    _cfg.research = _research;
    _cfg.hybrid = _hybrid;
    await _cfg.save();
    if (!mounted) return;
    if (failed.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _warn = 'Ayarlar kaydedildi ancak şu sağlayıcıların modeli doğrulanamadı: ${failed.join(', ')}. '
          'Kartlardaki kırmızı uyarılara bak; düzeltip yeniden kaydedebilirsin.';
    });
  }

  Widget _statusLine(_Status s) {
    final color = s.ok ? KColors.green : KColors.red;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(s.ok ? Icons.check_circle : Icons.error, size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(s.text, style: TextStyle(fontSize: 11.5, color: color, height: 1.35)),
          ),
        ],
      ),
    );
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
            onChanged: (_) => setState(() => _modelStatus.remove(p)),
            decoration: InputDecoration(
              labelText: 'Model adı (listeden seç ya da yaz)',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Model listesi',
                icon: const Icon(Icons.arrow_drop_down, size: 22),
                onPressed: (_fetching.contains(p) || _saving) ? null : () => _pick(p),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: (_fetching.contains(p) || _testing.contains(p) || _saving) ? null : () => _fetch(p),
              icon: _fetching.contains(p)
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.travel_explore, size: 16),
              label: const Text('Anahtarı sına ve modelleri getir', overflow: TextOverflow.ellipsis),
            ),
          ),
          if (_keyStatus[p] != null) _statusLine(_keyStatus[p]!),
          if (_suggest[p] != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Model listesi alınamadığı için varsayılan model öneriliyor: ${_suggest[p]}',
                      style: TextStyle(fontSize: 11.5, color: KColors.amber, height: 1.35),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _models[p]!.text = _suggest[p]!;
                      _suggest.remove(p);
                      _modelStatus.remove(p);
                    }),
                    child: const Text('Kullan'),
                  ),
                ],
              ),
            ),
          if (_testing.contains(p))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Model sınanıyor…', style: TextStyle(fontSize: 11.5, color: KColors.muted)),
            )
          else if (_modelStatus[p] != null)
            _statusLine(_modelStatus[p]!),
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
              if (_warn != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: KColors.amber),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 18, color: KColors.amber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_warn!, style: TextStyle(fontSize: 12, color: KColors.amber, height: 1.4)),
                      ),
                      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Kapat')),
                    ],
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Modeller sınanıyor ve kaydediliyor…' : 'Kaydet'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
