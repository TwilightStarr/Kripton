// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';

import 'crypto_exceptions.dart';

/// Argon2id parametreleri. [memoryKiB] KiB cinsindendir (131072 = 128 MiB).
@immutable
class KdfParams {
  const KdfParams({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
    this.hashLength = 32,
  });

  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final int hashLength;

  /// Varsayılan: 128 MiB, t=3, p=2.
  static const production =
      KdfParams(memoryKiB: 131072, iterations: 3, parallelism: 2);

  /// Düşük bellekli cihazlar: 64 MiB, t=3, p=2 (politika tabanı).
  static const lowMemory =
      KdfParams(memoryKiB: 65536, iterations: 3, parallelism: 2);

  /// Her parametre en az [other] kadar güçlü mü? (rehash kararı için)
  bool isAtLeast(KdfParams other) =>
      memoryKiB >= other.memoryKiB &&
      iterations >= other.iterations &&
      parallelism >= other.parallelism;

  @override
  bool operator ==(Object other) =>
      other is KdfParams &&
      other.memoryKiB == memoryKiB &&
      other.iterations == iterations &&
      other.parallelism == parallelism &&
      other.hashLength == hashLength;

  @override
  int get hashCode =>
      Object.hash(memoryKiB, iterations, parallelism, hashLength);

  @override
  String toString() =>
      'KdfParams(m=${memoryKiB}KiB, t=$iterations, p=$parallelism)';
}

/// Kabul edilebilir parametre aralığı. Alt sınır: downgrade/kurcalama savunması.
/// Üst sınır: kurcalanmış başlıkla DoS (devasa bellek/süre) savunması —
/// başlık MAC'i KDF'den SONRA doğrulanabildiği için sınırlar KDF'den ÖNCE uygulanır.
@immutable
class KdfPolicy {
  const KdfPolicy({
    required this.minMemoryKiB,
    required this.minIterations,
    required this.minParallelism,
    required this.maxMemoryKiB,
    required this.maxIterations,
    required this.maxParallelism,
  });

  final int minMemoryKiB;
  final int minIterations;
  final int minParallelism;
  final int maxMemoryKiB;
  final int maxIterations;
  final int maxParallelism;

  static const production = KdfPolicy(
    minMemoryKiB: 65536, // 64 MiB
    minIterations: 3,
    minParallelism: 2,
    maxMemoryKiB: 1048576, // 1 GiB
    maxIterations: 64,
    maxParallelism: 16,
  );

  /// SADECE testler için (hızlı çalışsın diye). Üretimde kullanmayın.
  @visibleForTesting
  static const testing = KdfPolicy(
    minMemoryKiB: 64,
    minIterations: 1,
    minParallelism: 1,
    maxMemoryKiB: 4096,
    maxIterations: 8,
    maxParallelism: 4,
  );

  void validate(KdfParams p) {
    final ok = p.hashLength == 32 &&
        p.memoryKiB >= minMemoryKiB &&
        p.memoryKiB <= maxMemoryKiB &&
        p.iterations >= minIterations &&
        p.iterations <= maxIterations &&
        p.parallelism >= minParallelism &&
        p.parallelism <= maxParallelism &&
        p.memoryKiB >= 8 * p.parallelism;
    if (!ok) {
      throw const QuantaCryptoException(CryptoFailure.weakParameters);
    }
  }
}
