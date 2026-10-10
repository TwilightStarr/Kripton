// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/vault_controller.dart';

/// Secret Key ve kurtarma ifadesinin BİR KEZ gösterildiği ekran.
/// Kopyala / paylaş / yazdır YOK; geri tuşu kapalı; onay olmadan devam edilmez.
/// Ekran görüntüsü `FLAG_SECURE` ile engellenir (tool/setup_android.sh).
class RevealScreen extends ConsumerStatefulWidget {
  const RevealScreen({super.key, required this.secrets});

  final RevealSecrets secrets;

  @override
  ConsumerState<RevealScreen> createState() => _RevealScreenState();
}

class _RevealScreenState extends ConsumerState<RevealScreen> {
  bool _confirmed = false;
  bool _busy = false;

  Future<void> _continue() async {
    if (!_confirmed || _busy) return;
    setState(() => _busy = true);
    await ref.read(vaultControllerProvider.notifier).acknowledgeReveal();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final words = widget.secrets.recoveryWords;
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Secret Key ve kurtarma'),
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      color: scheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Bunları şimdi KÂĞIDA yazın ve güvenli bir yerde '
                          'saklayın. Bu bilgiler bir daha gösterilmeyecek; '
                          'kaybederseniz kasanız kalıcı olarak açılamaz. '
                          'Ekran görüntüsü alınamaz, kopyalanamaz.',
                          style: text.bodyMedium?.copyWith(
                              color: scheme.onErrorContainer),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      widget.secrets.secretKeyChanged
                          ? 'Yeni Secret Key'
                          : 'Secret Key',
                      style: text.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.secrets.secretKeyChanged
                          ? 'Eski Secret Key artık geçerli değil. Kasayı '
                              'açarken ana parolanızla birlikte bu istenir.'
                          : 'Kasayı açarken ana parolanızla birlikte istenir.',
                      style: text.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Semantics(
                        label: 'Secret Key: ${widget.secrets.secretKey}',
                        child: ExcludeSemantics(
                          child: Text(
                            widget.secrets.secretKey,
                            style: text.titleMedium?.copyWith(
                              fontFamily: 'monospace',
                              letterSpacing: 1,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text('Kurtarma ifadesi', style: text.titleMedium),
                    const SizedBox(height: 4),
                    if (words.isEmpty)
                      Text(
                        widget.secrets.recoveryKept
                            ? 'Kurtarma ifadeniz değişmedi. Elinizdeki 24 '
                                'kelimeyi saklamaya devam edin; yeniden '
                                'gösterilmez.'
                            : 'Kurtarma ifadesi oluşturmadınız. Ana '
                                'parolanızı unutursanız kasaya erişemezsiniz.',
                        style: text.bodyMedium,
                      )
                    else ...[
                      Text(
                        'Ana parolayı unutursanız bu 24 kelime sırasıyla '
                        'kasanızı açar.',
                        style: text.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < words.length; i++)
                            Chip(
                              label: Text('${i + 1}. ${words[i]}',
                                  style: const TextStyle(
                                      fontFamily: 'monospace')),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 24),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _confirmed,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _confirmed = v ?? false),
                      title: Text(
                        widget.secrets.recoveryKept
                            ? 'Kaydettim: yeni Secret Key\'imi kâğıda yazdım.'
                            : 'Kaydettim: Secret Key\'imi ve kurtarma ifademi '
                                'kâğıda yazdım.',
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _confirmed && !_busy ? _continue : null,
                      child: const Text('Devam'),
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
