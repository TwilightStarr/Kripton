// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/secret_key_codec.dart';
import '../../../core/crypto/vault_service.dart';
import '../../../core/security/password_strength.dart';
import '../application/password_policy.dart';
import '../application/password_providers.dart';
import '../application/vault_controller.dart';
import 'secret_input.dart';
import 'widgets/secret_text_field.dart';
import 'widgets/strength_meter.dart';

/// Ana parolayı unutan kullanıcı için: 24 kelimelik kurtarma ifadesiyle yeni
/// ana parola belirleme. Secret Key girilirse korunur; girilmezse yenisi
/// üretilir (eskisi geçersiz olur) ve tek seferlik gösterilir.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phrase = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _secretKey = TextEditingController();

  bool _acceptWeak = false;
  bool _busy = false;
  String? _error;
  PasswordReport? _report;

  @override
  void dispose() {
    for (final c in [_phrase, _password, _confirm, _secretKey]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  PasswordVerdict? get _verdict {
    final r = _report;
    return r == null ? null : judgePassword(r);
  }

  void _onPasswordChanged(String value) {
    final estimator = ref.read(passwordEstimatorProvider);
    setState(() {
      _report = value.isEmpty ? null : estimator.estimate(value);
      if (_verdict != PasswordVerdict.weak) _acceptWeak = false;
      _error = null;
    });
  }

  String? _validatePhrase(String? v) {
    final n = (v ?? '').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    return n.length == 24 ? null : 'Kurtarma ifadesi 24 kelime olmalı.';
  }

  String? _validatePassword(String? v) {
    if ((v ?? '').runes.length < VaultService.minPasswordLength) {
      return 'En az ${VaultService.minPasswordLength} karakter olmalı.';
    }
    if (_verdict == PasswordVerdict.blocked) {
      return 'Bu parola çok zayıf veya çok yaygın. Daha uzun, '
          'tahmin edilmesi zor bir parola seçin.';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_verdict == PasswordVerdict.weak && !_acceptWeak) {
      setState(() => _error = 'Zayıf parolayı kullanmak için onay kutusunu '
          'işaretleyin veya daha güçlü bir parola seçin.');
      return;
    }
    final keyText = _secretKey.text.trim();
    if (keyText.isNotEmpty) {
      try {
        (await SecretKeyCodec.parse(keyText)).dispose();
      } catch (_) {
        if (!mounted) return;
        setState(() => _error = 'Secret Key biçimi geçersiz. Boş '
            'bırakırsanız yeni bir Secret Key üretilir.');
        return;
      }
    }
    final phrase = _phrase.text;
    final password = takeSecretBytes(_password);
    _confirm.clear();
    _secretKey.clear();
    _phrase.clear();
    if (!mounted) {
      password.dispose();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _report = null;
    });
    final outcome =
        await ref.read(vaultControllerProvider.notifier).resetPasswordWithRecovery(
              phrase: phrase,
              newPassword: password,
              existingSecretKey: keyText,
            );
    if (!mounted) return;
    if (outcome == UnlockOutcome.success) {
      Navigator.of(context).pop(); // kök ekran kasayı/Secret Key gösterimini çizer
      return;
    }
    setState(() {
      _busy = false;
      _error = outcome == UnlockOutcome.throttled
          ? 'Çok fazla başarısız deneme. Biraz bekleyip tekrar deneyin.'
          : 'Parola sıfırlanamadı. Kurtarma ifadesini kontrol edip tekrar '
              'deneyin.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final report = _report;
    return Scaffold(
      appBar: AppBar(title: const Text('Ana parolayı sıfırla')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Kurtarma ifadenizi girin ve yeni bir ana parola '
                      'belirleyin. Kasadaki verileriniz korunur.',
                      style: text.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _phrase,
                      enabled: !_busy,
                      minLines: 3,
                      maxLines: 5,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      keyboardType: TextInputType.multiline,
                      validator: _validatePhrase,
                      decoration: const InputDecoration(
                        labelText: 'Kurtarma ifadesi (24 kelime)',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SecretTextField(
                      controller: _password,
                      label: 'Yeni ana parola',
                      enabled: !_busy,
                      textInputAction: TextInputAction.next,
                      validator: _validatePassword,
                      onChanged: _onPasswordChanged,
                    ),
                    if (report != null) ...[
                      const SizedBox(height: 8),
                      StrengthMeter(report: report),
                    ],
                    const SizedBox(height: 16),
                    SecretTextField(
                      controller: _confirm,
                      label: 'Yeni ana parola (tekrar)',
                      enabled: !_busy,
                      textInputAction: TextInputAction.next,
                      validator: (v) =>
                          v == _password.text ? null : 'Parolalar eşleşmiyor.',
                    ),
                    if (_verdict == PasswordVerdict.weak) ...[
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _acceptWeak,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _acceptWeak = v ?? false),
                        title: const Text(
                          'Bu parolanın zayıf olduğunu anlıyorum, yine de '
                          'kullanmak istiyorum.',
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SecretTextField(
                      controller: _secretKey,
                      label: 'Secret Key (varsa)',
                      helperText: 'Elinizdeyse girin, korunur. Boş '
                          'bırakırsanız yeni bir Secret Key üretilir ve '
                          'eskisi geçersiz olur.',
                      enabled: !_busy,
                      monospace: true,
                      capitalizeCharacters: true,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child:
                            Text(_error!, style: TextStyle(color: scheme.error)),
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (_busy) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      const Text(
                        'Parola sıfırlanıyor… Birkaç saniye sürebilir.',
                        textAlign: TextAlign.center,
                      ),
                    ] else
                      FilledButton(
                        onPressed: _submit,
                        child: const Text('Parolayı sıfırla'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
