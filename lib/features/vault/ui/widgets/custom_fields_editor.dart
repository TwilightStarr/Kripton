// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../../domain/vault_item.dart';

/// Tek bir özel alan satırının düzenlenebilir durumu.
class CustomRowState {
  CustomRowState({String name = '', String value = '', this.type = CustomFieldType.text})
      : name = TextEditingController(text: name),
        value = TextEditingController(text: value);

  final TextEditingController name;
  final TextEditingController value;
  CustomFieldType type;

  void dispose() {
    name.clear();
    value.clear();
    name.dispose();
    value.dispose();
  }
}

String customTypeLabel(CustomFieldType t) => switch (t) {
      CustomFieldType.text => 'Metin',
      CustomFieldType.hidden => 'Gizli',
      CustomFieldType.url => 'Adres',
      CustomFieldType.date => 'Tarih',
    };

/// Kullanıcı tanımlı alanlar: ad, tür ve değer. Satırlar [rows] listesinde
/// tutulur; değişiklikte [onChanged] çağrılır (üst widget `setState` yapar).
class CustomFieldsEditor extends StatelessWidget {
  const CustomFieldsEditor({
    super.key,
    required this.rows,
    required this.onChanged,
    this.enabled = true,
  });

  final List<CustomRowState> rows;
  final VoidCallback onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Özel alanlar', style: text.titleMedium),
        const SizedBox(height: 8),
        for (var i = 0; i < rows.length; i++)
          _Row(
            key: ObjectKey(rows[i]),
            row: rows[i],
            index: i,
            enabled: enabled,
            onRemove: () {
              rows.removeAt(i).dispose();
              onChanged();
            },
            onChanged: onChanged,
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: enabled
                ? () {
                    rows.add(CustomRowState());
                    onChanged();
                  }
                : null,
            icon: const Icon(Icons.add),
            label: const Text('Alan ekle'),
          ),
        ),
      ],
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    super.key,
    required this.row,
    required this.index,
    required this.enabled,
    required this.onRemove,
    required this.onChanged,
  });

  final CustomRowState row;
  final int index;
  final bool enabled;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final n = widget.index + 1;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: r.name,
              enabled: widget.enabled,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(labelText: 'Alan adı $n'),
              validator: (v) => ((v ?? '').trim().isEmpty &&
                      r.value.text.isNotEmpty)
                  ? 'Alan adı gerekli.'
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<CustomFieldType>(
              value: r.type,
              decoration: InputDecoration(labelText: 'Tür $n'),
              items: [
                for (final t in CustomFieldType.values)
                  DropdownMenuItem(value: t, child: Text(customTypeLabel(t))),
              ],
              onChanged: widget.enabled
                  ? (t) {
                      if (t == null) return;
                      setState(() => r.type = t);
                      widget.onChanged();
                    }
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: r.value,
              enabled: widget.enabled,
              obscureText: r.type == CustomFieldType.hidden,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              keyboardType: r.type == CustomFieldType.url
                  ? TextInputType.url
                  : TextInputType.text,
              decoration: InputDecoration(labelText: 'Değer $n'),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: widget.enabled ? widget.onRemove : null,
                icon: const Icon(Icons.delete_outline),
                label: Text('Alan $n\'i sil'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
