// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'key_derivation.dart';
import 'kdf_params.dart';

class Argon2Calibration {
  const Argon2Calibration({
    required this.params,
    required this.estimatedMs,
    required this.meetsTarget,
  });
  final KdfParams params;
  final int estimatedMs;

  /// false: cihaz, politika tabanında bile hedef süreden yavaş.
  final bool meetsTarget;
}

/// Cihaz başına Argon2id ayarı: 128 MiB'ı dener, çok yavaşsa 64 MiB'a düşer,
/// hâlâ hedefin altındaysa iterasyonu artırır. Politika tabanının ALTINA inmez.
class Argon2Benchmark {
  static Future<int> _measureMs(Argon2Runner runner, KdfParams p) async {
    final sw = Stopwatch()..start();
    await runner.derive(
      input: Uint8List(64), // gizli olmayan sahte girdi
      salt: Uint8List(16),
      params: p,
    );
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  static KdfParams _withIterations(KdfParams base, int msAtBase, int targetMs,
      int maxIterations) {
    final perIter = msAtBase < base.iterations ? 1.0 : msAtBase / base.iterations;
    final extra = ((targetMs - msAtBase) / perIter).floor();
    final it =
        (base.iterations + extra).clamp(base.iterations, maxIterations).toInt();
    return KdfParams(
        memoryKiB: base.memoryKiB,
        iterations: it,
        parallelism: base.parallelism);
  }

  static Future<Argon2Calibration> calibrate({
    Argon2Runner runner = const IsolateArgon2Runner(),
    KdfPolicy policy = KdfPolicy.production,
    int minMs = 500,
    int targetMs = 650,
    int maxMs = 800,
    int maxIterations = 10,
  }) async {
    const low = KdfParams.lowMemory;
    const high = KdfParams.production;

    int? tHigh;
    try {
      tHigh = await _measureMs(runner, high);
    } catch (_) {
      tHigh = null; // bellek yetmedi (OOM vb.)
    }
    if (tHigh != null && tHigh <= maxMs) {
      final p = tHigh < minMs
          ? _withIterations(high, tHigh, targetMs, maxIterations)
          : high;
      policy.validate(p);
      final est = (tHigh * p.iterations / high.iterations).round();
      return Argon2Calibration(params: p, estimatedMs: est, meetsTarget: true);
    }

    final tLow = await _measureMs(runner, low);
    if (tLow > maxMs) {
      policy.validate(low);
      return Argon2Calibration(
          params: low, estimatedMs: tLow, meetsTarget: false);
    }
    final p = tLow < minMs
        ? _withIterations(low, tLow, targetMs, maxIterations)
        : low;
    policy.validate(p);
    final est = (tLow * p.iterations / low.iterations).round();
    return Argon2Calibration(params: p, estimatedMs: est, meetsTarget: true);
  }
}
