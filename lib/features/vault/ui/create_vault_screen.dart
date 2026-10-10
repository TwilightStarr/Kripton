// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/vault_service.dart';
import '../../../core/security/password_strength.dart';
import '../application/password_policy.dart';
import '../application/password_providers.dart';
import '../application/vault_controller.dart';
import 'secret_input.dart';
import 'widgets/secret_text_field.dart';
import 'widgets/strength_meter.dart';

/// Kasa oluşturma: karşılama -> ana parola (+ kurtarma seçeneği) -> oluşturma.
/// Başarılı olunca kök ekran Secret Key gösterim ekranına geçer.
class CreateVaultScreen extends ConsumerStatefulWidget {
  const CreateVaultScreen({super.key});

  @override
  ConsumerState<CreateVaultScreen> createState() => _CreateVaultScreenState();
}

class _CreateVaultScreenState extends ConsumerState<CreateVaultScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _showForm = false;
  bool _withRecovery = true;
  bool _acceptWeak = false;
  bool _busy = false;
  String? _error;
  PasswordReport? _report;

  @override
  void dispose() {
    _password.clear();
    _confirm.clear();
    _password.dispose();
    _confirm.dispose();
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

  String? _validatePassword(String? value) {
    final v = value ?? '';
    if (v.runes.length < VaultService.minPasswordLength) {
      return 'En az ${VaultService.minPasswordLength} karakter olmalı.';
    }
    if (_verdict == PasswordVerdict.blocked) {
      return 'Bu parola çok zayıf veya çok yaygın. Daha uzun, '
          'tahmin edilmesi zor bir parola seçin.';
    }
    return null;
  }

  String? _validateConfirm(String? value) =>
      value == _password.text ? null : 'Parolalar eşleşmiyor.';

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_verdict == PasswordVerdict.weak && !_acceptWeak) {
      setState(() => _error = 'Zayıf parolayı kullanmak için onay kutusunu '
          'işaretleyin veya daha güçlü bir parola seçin.');
      return;
    }
    final password = takeSecretBytes(_password);
    _confirm.clear();
    setState(() {
      _busy = true;
      _error = null;
      _report = null;
    });
    final ok = await ref
        .read(vaultControllerProvider.notifier)
        .createVault(password: password, withRecovery: _withRecovery);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = 'Kasa oluşturulamadı. Parolanızı yeniden girip tekrar deneyin.';
      });
    }
    // Başarılıysa kök ekran bu widget'ı kaldırır.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Quanta')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: _showForm ? _buildForm(context) : _buildWelcome(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWelcome(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.lock_outline,
            size: 64, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text('Quanta\'ya hoş geldiniz',
            style: text.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text(
          'Quanta tamamen çevrimdışı çalışır: verileriniz yalnızca bu '
          'cihazda, şifreli olarak saklanır ve hiçbir yere gönderilmez.',
          style: text.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          'Kasanızı iki şey korur: ana parolanız ve size bir kez '
          'göstereceğimiz Secret Key. İkisini de kaybederseniz verilerinize '
          'kimse, biz de dahil, erişemez.',
          style: text.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        FilledButton(
          onPressed: () => setState(() => _showForm = true),
          child: const Text('Kasa oluştur'),
        ),
      ],
    );
  }

  Widget _buildForm(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final report = _report;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Ana parola belirleyin', style: text.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Uzun bir parola cümlesi seçin (en az '
            '${VaultService.minPasswordLength} karakter). Bu parolayı '
            'unutursanız kurtarma ifadeniz olmadan kasanız açılamaz.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 20),
          SecretTextField(
            controller: _password,
            label: 'Ana parola',
            enabled: !_busy,
            autofocus: true,
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
            label: 'Ana parola (tekrar)',
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            validator: _validateConfirm,
            onSubmitted: (_) => _submit(),
          ),
          if (_verdict == PasswordVerdict.weak) ...[
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _acceptWeak,
              onChanged:
                  _busy ? null : (v) => setState(() => _acceptWeak = v ?? false),
              title: const Text(
                'Bu parolanın zayıf olduğunu anlıyorum, yine de kullanmak '
                'istiyorum.',
              ),
            ),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _withRecovery,
            onChanged: _busy ? null : (v) => setState(() => _withRecovery = v),
            title: const Text('Kurtarma ifadesi oluştur'),
            subtitle: const Text(
              '24 kelimelik ifade, ana parolanızı unutursanız kasaya erişmenizi '
              'sağlar. Kapatırsanız parolanızı unutmanın çaresi yoktur.',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          ],
          const SizedBox(height: 16),
          if (_busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: const Text(
                'Kasa oluşturuluyor… Cihazınıza göre birkaç saniye sürebilir; '
                'lütfen uygulamayı kapatmayın.',
                textAlign: TextAlign.center,
              ),
            ),
          ] else
            FilledButton(
              onPressed: _submit,
              child: const Text('Kasayı oluştur'),
            ),
        ],
      ),
    );
  }
}
