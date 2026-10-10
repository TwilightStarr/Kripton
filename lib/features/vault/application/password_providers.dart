// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/security/password_strength.dart';

/// Yeni ana parola güç tahmincisi. `main.dart` yaygın parola listesini
/// varlıklardan yükleyip override eder (testler küçük bir liste verir).
final passwordEstimatorProvider = Provider<PasswordStrengthEstimator>(
  (ref) => throw UnimplementedError('passwordEstimatorProvider override edilmeli'),
);
