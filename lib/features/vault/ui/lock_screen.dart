// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/secret_key_codec.dart';
import '../../../core/security/secret_bytes.dart';
import '../application/vault_controller.dart';
import 'reset_password_screen.dart';
import 'secret_input.dart';
import 'widgets/secret_text_field.dart';

/// Kilit ekranı: ana parola + Secret Key, ya da kurtarma ifadesiyle aç.
///
/// Yanlış girişte tek tip hata gösterilir; parola mı Secret Key mi yanlış,
/// ayırt edilmez.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  static const authFailedMessage = 'Kimlik doğrulama başarısız.';

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _secretKey = TextEditingController();
  final _phrase = TextEditingController();

  bool _recovery = false;
  bool _busy = false;
  String? _error;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker(ref.read(vaultControllerProvider).lockedUntil);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    for (final c in [_password, _secretKey, _phrase]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  Duration get _remaining {
    final until = ref.read(vaultControllerProvider).lockedUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(ref.read(clockProvider)());
    return left.isNegative ? Duration.zero : left;
  }

  void _syncTicker(DateTime? until) {
    if (until == null) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_remaining == Duration.zero) {
        _ticker?.cancel();
        _ticker = null;
      }
    });
  }

  String? _validatePassword(String? v) =>
      (v == null || v.isEmpty) ? 'Ana parolayı girin.' : null;

  String? _validateSecretKey(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Secret Key\'i girin.' : null;

  String? _validatePhrase(String? v) {
    final n = (v ?? '').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    return n.length == 24 ? null : 'Kurtarma ifadesi 24 kelime olmalı.';
  }

  Future<void> _submit() async {
    if (_busy || _remaining > Duration.zero) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final controller = ref.read(vaultControllerProvider.notifier);

    if (_recovery) {
      final phrase = _phrase.text;
      _phrase.clear();
      setState(() {
        _busy = true;
        _error = null;
      });
      await _finish(controller.unlockWithRecovery(phrase));
      return;
    }

    // Secret Key biçimi yerel olarak doğrulanır (yalnızca yazım hatası
    // sağlaması); biçim hatası deneme sayılmaz ve hiçbir gizli bilgi sızdırmaz.
    final SecretBytes secretKey;
    try {
      secretKey = await SecretKeyCodec.parse(_secretKey.text);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Secret Key biçimi geçersiz. QNTA-… ile '
          'başlayan 5 gruplu anahtarı eksiksiz girin.');
      return;
    }
    _secretKey.clear();
    final password = takeSecretBytes(_password);
    if (!mounted) {
      password.dispose();
      secretKey.dispose();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await _finish(controller.unlock(password: password, secretKey: secretKey));
  }

  Future<void> _finish(Future<UnlockOutcome> attempt) async {
    final outcome = await attempt;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = switch (outcome) {
        UnlockOutcome.success => null,
        UnlockOutcome.failed => LockScreen.authFailedMessage,
        UnlockOutcome.throttled => null,
        UnlockOutcome.busy => null,
      };
    });
  }

  void _toggleMode() {
    _password.clear();
    _secretKey.clear();
    _phrase.clear();
    setState(() {
      _recovery = !_recovery;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<VaultState>(vaultControllerProvider, (prev, next) {
      _syncTicker(next.lockedUntil);
    });
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final wait = _remaining;
    final blocked = wait > Duration.zero;

    return Scaffold(
      appBar: AppBar(title: const Text('Quanta')),
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
                    Icon(Icons.lock_outline, size: 56, color: scheme.primary),
                    const SizedBox(height: 12),
                    Text('Kasa kilitli',
                        style: text.headlineSmall, textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    if (_recovery) ...[
                      TextFormField(
                        controller: _phrase,
                        enabled: !_busy,
                        minLines: 4,
                        maxLines: 6,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        keyboardType: TextInputType.multiline,
                        validator: _validatePhrase,
                        decoration: const InputDecoration(
                          labelText: 'Kurtarma ifadesi (24 kelime)',
                          helperText: 'Kelimeleri sırasıyla, boşlukla ayırarak '
                              'girin veya yapıştırın.',
                          helperMaxLines: 3,
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                    ] else ...[
                      SecretTextField(
                        controller: _password,
                        label: 'Ana parola',
                        enabled: !_busy,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        validator: _validatePassword,
                      ),
                      const SizedBox(height: 16),
                      SecretTextField(
                        controller: _secretKey,
                        label: 'Secret Key',
                        helperText: 'QNTA-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX '
                            '(yapıştırabilirsiniz)',
                        enabled: !_busy,
                        monospace: true,
                        capitalizeCharacters: true,
                        textInputAction: TextInputAction.done,
                        validator: _validateSecretKey,
                        onSubmitted: (_) => _submit(),
                      ),
                    ],
                    if (blocked) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          'Çok fazla başarısız deneme. '
                          '${wait.inSeconds + 1} saniye sonra tekrar '
                          'deneyin.',
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(_error!,
                            style: TextStyle(color: scheme.error)),
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (_busy) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: const Text(
                          'Kasa açılıyor… Birkaç saniye sürebilir.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ] else
                      FilledButton(
                        onPressed: blocked ? null : _submit,
                        child: Text(
                            _recovery ? 'Kurtarma ifadesiyle aç' : 'Kasayı aç'),
                      ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : _toggleMode,
                      child: Text(_recovery
                          ? 'Ana parola ve Secret Key ile aç'
                          : 'Kurtarma ifadesiyle aç'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const ResetPasswordScreen(),
                                ),
                              ),
                      child: const Text('Ana parolamı unuttum'),
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
