// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../generator/eff_wordlist.dart';
import '../../generator/password_generator.dart';

/// Parola üreteci (CSPRNG). Testler sabit rastgelelikle override edebilir.
final passwordGeneratorProvider =
    Provider<PasswordGenerator>((ref) => PasswordGenerator());

/// EFF diceware listesi; yalnızca diceware sekmesi açılınca varlıklardan yüklenir.
final effWordlistProvider =
    FutureProvider<EffWordlist>((ref) => EffWordlist.loadFromAssets());
