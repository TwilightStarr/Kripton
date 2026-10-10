// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

/// Gizli veri girişi: öneri/otomatik düzeltme/IME öğrenmesi kapalı, varsayılan
/// gizli, göster/gizle düğmeli (dokunma hedefi ≥ 48dp, etiketli).
class SecretTextField extends StatefulWidget {
  const SecretTextField({
    super.key,
    required this.controller,
    required this.label,
    this.helperText,
    this.validator,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
    this.enabled = true,
    this.autofocus = false,
    this.monospace = false,
    this.capitalizeCharacters = false,
    this.extraAction,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String label;
  final String? helperText;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;
  final bool enabled;
  final bool autofocus;
  final bool monospace;
  final bool capitalizeCharacters;

  /// Göster/gizle düğmesinin yanında ek eylem (ör. parola üret).
  final Widget? extraAction;
  final TextInputType? keyboardType;

  @override
  State<SecretTextField> createState() => _SecretTextFieldState();
}

class _SecretTextFieldState extends State<SecretTextField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      obscureText: !_visible,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      textCapitalization: widget.capitalizeCharacters
          ? TextCapitalization.characters
          : TextCapitalization.none,
      textInputAction: widget.textInputAction,
      keyboardType: widget.keyboardType,
      style: widget.monospace
          ? const TextStyle(fontFamily: 'monospace', letterSpacing: 1)
          : null,
      validator: widget.validator,
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helperText,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.extraAction != null) widget.extraAction!,
            IconButton(
              tooltip: _visible ? 'Gizle' : 'Göster',
              icon: Icon(_visible ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _visible = !_visible),
            ),
          ],
        ),
      ),
    );
  }
}
