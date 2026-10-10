// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../generator/password_generator.dart';
import '../../application/generator_providers.dart';

enum _Mode { random, diceware, pin }

/// Parola üreteci alt sayfası. Seçilen değeri `String` olarak döndürür
/// ("Kullan"); iptalde null.
Future<String?> showGeneratorSheet(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _GeneratorSheet(),
    );

class _GeneratorSheet extends ConsumerStatefulWidget {
  const _GeneratorSheet();

  @override
  ConsumerState<_GeneratorSheet> createState() => _GeneratorSheetState();
}

class _GeneratorSheetState extends ConsumerState<_GeneratorSheet> {
  _Mode _mode = _Mode.random;

  // rastgele
  double _length = 20;
  bool _lower = true, _upper = true, _digits = true, _symbols = true;
  bool _noAmbiguous = false;

  // diceware
  double _words = 6;
  String _sep = '-';
  bool _capitalize = false;
  bool _withNumber = false;

  // PIN
  double _pinLength = 6;

  GeneratedPassword? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _regen());
  }

  Future<void> _regen() async {
    final gen = ref.read(passwordGeneratorProvider);
    try {
      GeneratedPassword r;
      switch (_mode) {
        case _Mode.random:
          r = gen.random(RandomPasswordOptions(
            length: _length.round(),
            lowercase: _lower,
            uppercase: _upper,
            digits: _digits,
            symbols: _symbols,
            excludeAmbiguous: _noAmbiguous,
          ));
        case _Mode.diceware:
          final list = await ref.read(effWordlistProvider.future);
          r = gen.diceware(
            list,
            DicewareOptions(
              wordCount: _words.round(),
              separator: _sep,
              capitalize: _capitalize,
              includeNumber: _withNumber,
            ),
          );
        case _Mode.pin:
          r = gen.pin(PinOptions(length: _pinLength.round()));
      }
      if (!mounted) return;
      setState(() {
        _result = r;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _result = null;
        _error = 'Parola üretilemedi.';
      });
    }
  }

  void _change(VoidCallback fn) {
    setState(fn);
    _regen();
  }

  int get _classCount =>
      [_lower, _upper, _digits, _symbols].where((e) => e).length;

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged,
      {bool enabled = true}) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final r = _result;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            24, 0, 24, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Parola üret', style: text.titleLarge),
              const SizedBox(height: 12),
              SegmentedButton<_Mode>(
                segments: const [
                  ButtonSegment(value: _Mode.random, label: Text('Rastgele')),
                  ButtonSegment(value: _Mode.diceware, label: Text('Kelime')),
                  ButtonSegment(value: _Mode.pin, label: Text('PIN')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => _change(() => _mode = s.first),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error ?? r?.value ?? '…',
                    textAlign: TextAlign.center,
                    style: text.titleMedium?.copyWith(
                      fontFamily: 'monospace',
                      color: _error != null ? scheme.error : null,
                    ),
                  ),
                ),
              ),
              if (r != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Yaklaşık ${r.entropyBits.round()} bit entropi',
                  style: text.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 8),
              if (_mode == _Mode.random) ..._randomOptions(),
              if (_mode == _Mode.diceware) ..._dicewareOptions(),
              if (_mode == _Mode.pin) ..._pinOptions(),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _regen,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Yenile'),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(64, 52)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed:
                          r == null ? null : () => Navigator.pop(context, r.value),
                      child: const Text('Kullan'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _randomOptions() => [
        Text('Uzunluk: ${_length.round()}'),
        Slider(
          value: _length,
          min: RandomPasswordOptions.minLength.toDouble(),
          max: 64,
          divisions: 64 - RandomPasswordOptions.minLength,
          label: '${_length.round()}',
          onChanged: (v) => _change(() => _length = v),
        ),
        _toggle('Küçük harf', _lower, (v) => _change(() => _lower = v),
            enabled: !(_lower && _classCount == 1)),
        _toggle('Büyük harf', _upper, (v) => _change(() => _upper = v),
            enabled: !(_upper && _classCount == 1)),
        _toggle('Rakam', _digits, (v) => _change(() => _digits = v),
            enabled: !(_digits && _classCount == 1)),
        _toggle('Sembol', _symbols, (v) => _change(() => _symbols = v),
            enabled: !(_symbols && _classCount == 1)),
        _toggle('Karışan karakterleri çıkar (O, 0, l, 1…)', _noAmbiguous,
            (v) => _change(() => _noAmbiguous = v)),
      ];

  List<Widget> _dicewareOptions() => [
        Text('Kelime sayısı: ${_words.round()}'),
        Slider(
          value: _words,
          min: 3,
          max: 12,
          divisions: 9,
          label: '${_words.round()}',
          onChanged: (v) => _change(() => _words = v),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final s in const ['-', ' ', '.', '_'])
              ChoiceChip(
                label: Text(s == ' ' ? 'boşluk' : s),
                selected: _sep == s,
                onSelected: (_) => _change(() => _sep = s),
              ),
          ],
        ),
        _toggle('Baş harfleri büyük', _capitalize,
            (v) => _change(() => _capitalize = v)),
        _toggle('Rakam ekle', _withNumber, (v) => _change(() => _withNumber = v)),
      ];

  List<Widget> _pinOptions() => [
        Text('Uzunluk: ${_pinLength.round()}'),
        Slider(
          value: _pinLength,
          min: 4,
          max: 12,
          divisions: 8,
          label: '${_pinLength.round()}',
          onChanged: (v) => _change(() => _pinLength = v),
        ),
      ];
}
