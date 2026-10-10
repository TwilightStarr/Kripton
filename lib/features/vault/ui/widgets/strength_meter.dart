// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../../../../core/security/password_strength.dart';
import '../../application/password_policy.dart';

/// Ana parola güç göstergesi (renk tek başına anlam taşımaz: metin etiketi var).
class StrengthMeter extends StatelessWidget {
  const StrengthMeter({super.key, required this.report});

  final PasswordReport report;

  static const _labels = ['Çok zayıf', 'Zayıf', 'Orta', 'İyi', 'Güçlü'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final score = report.score.clamp(0, 4);
    final color = score < 2
        ? scheme.error
        : (score == 2 ? scheme.tertiary : scheme.primary);
    final reasons = [
      for (final w in report.weaknesses.take(3)) describeWeakness(w),
    ];
    final label = 'Parola gücü: ${_labels[score]}';
    return Semantics(
      liveRegion: true,
      label: reasons.isEmpty ? label : '$label. ${reasons.join(', ')}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              value: (score + 1) / 5,
              color: color,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 6),
            Text(label, style: text.labelLarge?.copyWith(color: color)),
            if (reasons.isNotEmpty)
              Text(reasons.join(' · '), style: text.bodySmall),
          ],
        ),
      ),
    );
  }
}
