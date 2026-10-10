// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/security/password_strength.dart';
import '../application/item_actions.dart';
import '../application/item_form_codec.dart';
import '../application/password_providers.dart';
import '../domain/item_data.dart';
import '../domain/item_kind.dart';
import '../domain/vault_item.dart';
import 'item_kind_ui.dart';
import 'kind_fields.dart';
import 'widgets/custom_fields_editor.dart';
import 'widgets/generator_sheet.dart';
import 'widgets/secret_text_field.dart';
import 'widgets/strength_meter.dart';

/// Kayıt ekleme/düzenleme. [existing] verilirse düzenleme, yoksa yeni kayıt.
///
/// Gizli alanlar yalnızca controller'larda durur; ekran kapanınca (kilit dâhil)
/// temizlenir. Kaydetme hatasında form dokunulmadan kalır (veri kaybı yok).
class ItemEditScreen extends ConsumerStatefulWidget {
  const ItemEditScreen({super.key, required this.kind, this.existing});

  final ItemKind kind;
  final VaultItem? existing;

  @override
  ConsumerState<ItemEditScreen> createState() => _ItemEditScreenState();
}

class _ItemEditScreenState extends ConsumerState<ItemEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _category = TextEditingController();
  final _tags = TextEditingController();
  final _notes = TextEditingController();
  final Map<String, TextEditingController> _ctl = {};
  final Map<String, String> _misc = {};
  final List<CustomRowState> _custom = [];

  late final List<FieldSpec> _specs;
  late int _initialHash;
  bool _favorite = false;
  bool _dirty = false;
  bool _saving = false;
  String? _error;
  PasswordReport? _pwReport;
  bool _cardOff = false;

  bool get _isEdit => widget.existing != null;
  ItemKind get _kind => widget.kind;

  @override
  void initState() {
    super.initState();
    _specs = specsFor(_kind);
    final e = widget.existing;
    final fields = e == null ? const <String, String>{} : dataToFields(e.data);
    for (final f in _specs) {
      switch (f.type) {
        case FieldType.text:
        case FieldType.secret:
        case FieldType.multiline:
        case FieldType.secretMultiline:
          _ctl[f.key] = TextEditingController(text: fields[f.key] ?? '');
        case FieldType.date:
          _misc[f.key] = fields[f.key] ?? '';
        case FieldType.wifiSecurity:
          _misc[f.key] = fields[f.key] ?? 'wpa2';
        case FieldType.toggle:
          _misc[f.key] = fields[f.key] ?? '0';
      }
    }
    if (e != null) {
      _title.text = e.title;
      _category.text = e.category ?? '';
      _tags.text = e.tags.join(', ');
      _notes.text = e.notes;
      _favorite = e.isFavorite;
      for (final c in e.customFields) {
        _custom.add(CustomRowState(name: c.name, value: c.value, type: c.type));
      }
    }
    _initialHash = _hash();
  }

  @override
  void dispose() {
    for (final c in [_title, _category, _tags, _notes, ..._ctl.values]) {
      c.clear();
      c.dispose();
    }
    for (final r in _custom) {
      r.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------ durum

  Map<String, String> _fields() => {
        for (final e in _ctl.entries) e.key: e.value.text,
        ..._misc,
      };

  int _hash() => Object.hashAll([
        _title.text,
        _category.text,
        _tags.text,
        _notes.text,
        _favorite,
        for (final e in _ctl.entries) e.value.text,
        for (final v in _misc.values) v,
        for (final r in _custom) ...[r.name.text, r.value.text, r.type.name],
      ]);

  void _touch() => setState(() => _dirty = _hash() != _initialHash);

  void _onFieldChanged(String key, String value) {
    if (key == 'password' &&
        (_kind == ItemKind.login || _kind == ItemKind.wifi)) {
      final estimator = ref.read(passwordEstimatorProvider);
      _pwReport = value.isEmpty ? null : estimator.estimate(value);
    }
    if (_kind == ItemKind.card && key == 'number') {
      _cardOff = cardNumberLooksOff(value);
    }
  }

  // ----------------------------------------------------------- kaydet

  String? _blankToNull(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  List<CustomField> _customFields() => [
        for (final r in _custom)
          if (r.name.text.trim().isNotEmpty || r.value.text.isNotEmpty)
            CustomField(r.name.text.trim(), r.value.text, r.type),
      ];

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final data = fieldsToData(_kind, _fields());
    final tags = normalizeTags(_tags.text.split(RegExp(r'[,\n]')));
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final actions = ref.read(itemActionsProvider);
      final e = widget.existing;
      if (e == null) {
        await actions.create(ItemDraft(
          title: _title.text.trim(),
          data: data,
          category: _blankToNull(_category.text),
          isFavorite: _favorite,
          tags: tags,
          notes: _notes.text,
          customFields: _customFields(),
        ));
      } else {
        await actions.update(e.copyWith(
          title: _title.text.trim(),
          data: data,
          category: _blankToNull(_category.text),
          isFavorite: _favorite,
          tags: tags,
          notes: _notes.text,
          customFields: _customFields(),
        ));
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Kaydedilemedi. Girdiğiniz bilgiler formda duruyor; '
            'tekrar deneyin.';
      });
    }
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Değişiklikler atılsın mı?'),
        content: const Text('Kaydedilmemiş değişiklikler kaybolacak.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Düzenlemeye devam et'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Değişiklikleri at'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _trash() async {
    final e = widget.existing;
    if (e == null || _saving) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Çöp kutusuna taşınsın mı?'),
        content: const Text(
            'Kayıt çöp kutusunda 30 gün kalır, bu sürede geri yükleyebilirsiniz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Çöpe taşı'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(itemActionsProvider).trash(e.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Çöp kutusuna taşınamadı.');
    }
  }

  Future<void> _generate(String key) async {
    final value = await showGeneratorSheet(context);
    if (value == null || !mounted) return;
    _ctl[key]?.text = value;
    _onFieldChanged(key, value);
    _touch();
  }

  Future<void> _pickDate(String key) async {
    final current = DateTime.tryParse(_misc[key] ?? '');
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime(2000),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    _misc[key] = '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    _touch();
  }

  // ------------------------------------------------------------ çizim

  InputDecoration _deco(String label, {String? helper, Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
        suffixIcon: suffix,
      );

  Widget _buildField(FieldSpec f) {
    switch (f.type) {
      case FieldType.text:
        return TextFormField(
          controller: _ctl[f.key],
          enabled: !_saving,
          keyboardType: f.keyboard,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          decoration: _deco(
            f.label,
            helper: f.helper ??
                (f.key == 'number' && _cardOff
                    ? 'Numara geçerli görünmüyor (yazım hatası olabilir).'
                    : null),
          ),
          validator: (v) => validateField(_kind, f.key, v ?? ''),
          onChanged: (v) => _onFieldChanged(f.key, v),
        );
      case FieldType.secret:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SecretTextField(
              controller: _ctl[f.key]!,
              label: f.label,
              enabled: !_saving,
              keyboardType: f.keyboard,
              helperText: f.helper ??
                  (f.key == 'number' && _cardOff
                      ? 'Numara geçerli görünmüyor (yazım hatası olabilir).'
                      : null),
              validator: (v) => validateField(_kind, f.key, v ?? ''),
              onChanged: (v) => _onFieldChanged(f.key, v),
              extraAction: f.generator
                  ? IconButton(
                      tooltip: 'Parola üret',
                      icon: const Icon(Icons.auto_fix_high),
                      onPressed: _saving ? null : () => _generate(f.key),
                    )
                  : null,
            ),
            if (f.generator && _pwReport != null) ...[
              const SizedBox(height: 8),
              StrengthMeter(report: _pwReport!),
            ],
          ],
        );
      case FieldType.multiline:
        return TextFormField(
          controller: _ctl[f.key],
          enabled: !_saving,
          minLines: f.lines,
          maxLines: f.lines + 6,
          keyboardType: f.keyboard ?? TextInputType.multiline,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          decoration: _deco(f.label, helper: f.helper)
              .copyWith(alignLabelWithHint: true),
          onChanged: (v) => _onFieldChanged(f.key, v),
        );
      case FieldType.secretMultiline:
        return _SecretMultiline(
          controller: _ctl[f.key]!,
          label: f.label,
          enabled: !_saving,
        );
      case FieldType.date:
        final iso = _misc[f.key] ?? '';
        return InkWell(
          onTap: _saving ? null : () => _pickDate(f.key),
          child: InputDecorator(
            decoration: _deco(
              f.label,
              suffix: iso.isEmpty
                  ? const Icon(Icons.calendar_today_outlined)
                  : IconButton(
                      tooltip: '${f.label} temizle',
                      icon: const Icon(Icons.clear),
                      onPressed: _saving
                          ? null
                          : () {
                              _misc[f.key] = '';
                              _touch();
                            },
                    ),
            ),
            child: Text(iso.isEmpty ? 'Seçilmedi' : displayDate(iso)),
          ),
        );
      case FieldType.wifiSecurity:
        return DropdownButtonFormField<String>(
          value: _misc[f.key],
          decoration: _deco(f.label),
          items: [
            for (final s in WifiSecurity.values)
              DropdownMenuItem(
                value: s.name,
                child: Text(wifiSecurityLabel(s.name)),
              ),
          ],
          onChanged: _saving
              ? null
              : (v) {
                  if (v == null) return;
                  _misc[f.key] = v;
                  _touch();
                },
        );
      case FieldType.toggle:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.label),
          value: _misc[f.key] == '1',
          onChanged: _saving
              ? null
              : (v) {
                  _misc[f.key] = v ? '1' : '0';
                  _touch();
                },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final title = _isEdit ? 'Kaydı düzenle' : 'Yeni ${kindLabel(_kind)}';
    const gap = SizedBox(height: 16);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            if (_isEdit)
              IconButton(
                tooltip: 'Çöpe taşı',
                icon: const Icon(Icons.delete_outline),
                onPressed: _saving ? null : _trash,
              ),
            IconButton(
              tooltip: 'Kaydet',
              icon: const Icon(Icons.check),
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
        body: SafeArea(
          child: Form(
            key: _formKey,
            onChanged: _touch,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextFormField(
                  controller: _title,
                  enabled: !_saving,
                  autofocus: !_isEdit,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  textInputAction: TextInputAction.next,
                  decoration: _deco('Başlık'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Başlık gerekli.' : null,
                ),
                for (final f in _specs) ...[gap, _buildField(f)],
                gap,
                TextFormField(
                  controller: _notes,
                  enabled: !_saving,
                  minLines: 3,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration:
                      _deco('Notlar').copyWith(alignLabelWithHint: true),
                ),
                gap,
                TextFormField(
                  controller: _category,
                  enabled: !_saving,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: _deco('Kategori'),
                ),
                gap,
                TextFormField(
                  controller: _tags,
                  enabled: !_saving,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: _deco('Etiketler',
                      helper: 'Virgülle ayırın (ör. iş, banka).'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Favori'),
                  value: _favorite,
                  onChanged: _saving
                      ? null
                      : (v) {
                          _favorite = v;
                          _touch();
                        },
                ),
                gap,
                CustomFieldsEditor(
                  rows: _custom,
                  enabled: !_saving,
                  onChanged: _touch,
                ),
                if (_error != null) ...[
                  gap,
                  Semantics(
                    liveRegion: true,
                    child: Text(_error!, style: text.bodyMedium?.copyWith(color: scheme.error)),
                  ),
                ],
                gap,
                if (_saving)
                  const LinearProgressIndicator()
                else
                  FilledButton(onPressed: _save, child: const Text('Kaydet')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Çok satırlı gizli alan (ör. SSH özel anahtarı). Gizliyken içerik yerine
/// karakter sayısı gösterilir; düzenlemek için "Göster".
class _SecretMultiline extends StatefulWidget {
  const _SecretMultiline({
    required this.controller,
    required this.label,
    required this.enabled,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;

  @override
  State<_SecretMultiline> createState() => _SecretMultilineState();
}

class _SecretMultilineState extends State<_SecretMultiline> {
  late bool _hidden = widget.controller.text.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final toggle = IconButton(
      tooltip: _hidden ? 'Göster' : 'Gizle',
      icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
      onPressed: () => setState(() => _hidden = !_hidden),
    );
    if (_hidden) {
      return InputDecorator(
        decoration: InputDecoration(
          labelText: widget.label,
          suffixIcon: toggle,
        ),
        child: Text('••••••••  (${widget.controller.text.length} karakter)'),
      );
    }
    return TextFormField(
      controller: widget.controller,
      enabled: widget.enabled,
      minLines: 4,
      maxLines: 10,
      keyboardType: TextInputType.multiline,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      decoration: InputDecoration(
        labelText: widget.label,
        alignLabelWithHint: true,
        suffixIcon: toggle,
      ),
    );
  }
}
