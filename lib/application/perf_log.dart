import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Bir üretimin (ajan adımı) ölçümleri.
class PerfSample {
  PerfSample({
    required this.modelId,
    required this.at,
    required this.tokPerSec,
    required this.prefillTokPerSec,
    required this.firstTokenMs,
    required this.loadMs,
    required this.peakRamMb,
    required this.threads,
    required this.contextSize,
    required this.promptTokens,
    required this.genTokens,
    this.batch,
  });

  final String modelId;
  final int at;
  final double tokPerSec;
  final double prefillTokPerSec;
  final int firstTokenMs;
  final int loadMs;
  final int peakRamMb;
  final int threads;
  final int contextSize;
  final int promptTokens;
  final int genTokens;
  final int? batch;

  Map<String, Object?> toJson() => {
        'modelId': modelId,
        'at': at,
        'tps': tokPerSec,
        'prefill': prefillTokPerSec,
        'ttft': firstTokenMs,
        'load': loadMs,
        'ram': peakRamMb,
        'threads': threads,
        'ctx': contextSize,
        'ptok': promptTokens,
        'gtok': genTokens,
        'batch': batch,
      };

  static PerfSample fromJson(Map<String, dynamic> j) => PerfSample(
        modelId: j['modelId'] as String,
        at: j['at'] as int,
        tokPerSec: (j['tps'] as num).toDouble(),
        prefillTokPerSec: (j['prefill'] as num).toDouble(),
        firstTokenMs: j['ttft'] as int,
        loadMs: j['load'] as int,
        peakRamMb: j['ram'] as int,
        threads: j['threads'] as int,
        contextSize: j['ctx'] as int,
        promptTokens: j['ptok'] as int,
        genTokens: j['gtok'] as int,
        batch: j['batch'] as int?,
      );
}

/// /proc/meminfo okuma (Android/Linux). Okunamazsa null.
class MemInfo {
  static int? _kb(String key) {
    try {
      for (final l in File('/proc/meminfo').readAsLinesSync()) {
        if (l.startsWith(key)) return int.tryParse(RegExp(r'\d+').firstMatch(l)?.group(0) ?? '');
      }
    } catch (_) {}
    return null;
  }

  static int? availableMb() => _kb('MemAvailable:') == null ? null : _kb('MemAvailable:')! ~/ 1024;

  /// Dart sürecinin RSS'i (mmap'li model sayfaları dahil) MB.
  static int rssMb() {
    try {
      return ProcessInfo.currentRss ~/ (1024 * 1024);
    } catch (_) {
      return 0;
    }
  }
}

/// RAM güvenlik payı: 512 → 1024 MB. 8192 bağlam yalnızca pay + KV/hesap ara belleği sığarsa seçilir.
class RamPolicy {
  static const safetyMb = 1024; // Dimensity 9300+ / 12 GB: arka plan + HyperOS uygulamaları için
  static const minSafetyMb = 768;

  /// [modelMb] model dosyası (mmap), [kvMbPerK] 1K bağlam başına KV tahmini (7B Q4 ≈ 56 MB, 3B ≈ 36 MB).
  static int pickContext({required int modelMb, required int availMb, int kvMbPerK = 56, int fallback = 4096}) {
    for (final c in const [8192, 4096, 2048]) {
      final need = modelMb + kvMbPerK * (c ~/ 1024) + 350; // 350 MB: hesap grafiği/ara bellek
      if (c == 8192 ? availMb - need >= safetyMb : availMb - need >= minSafetyMb) return c;
    }
    return 2048;
  }
}

/// Ölçüm geçmişi (son 50 örnek) — disk: perf_log.json.
class PerfLog {
  PerfLog._();
  static final PerfLog instance = PerfLog._();

  final List<PerfSample> samples = [];
  bool _loaded = false;

  Future<File> _file() async => File(p.join((await getApplicationSupportDirectory()).path, 'perf_log.json'));

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (await f.exists()) {
        final l = jsonDecode(await f.readAsString()) as List;
        samples.addAll(l.map((e) => PerfSample.fromJson(e as Map<String, dynamic>)));
      }
    } catch (_) {}
  }

  Future<void> add(PerfSample s) async {
    await load();
    samples.add(s);
    if (samples.length > 50) samples.removeRange(0, samples.length - 50);
    try {
      await (await _file()).writeAsString(jsonEncode([for (final x in samples) x.toJson()]));
    } catch (_) {}
  }

  PerfSample? latestFor(String modelId) {
    for (var i = samples.length - 1; i >= 0; i--) {
      if (samples[i].modelId == modelId) return samples[i];
    }
    return null;
  }

  /// Katalogdaki 'tokensPerSec' metni için gerçek ölçüm aralığı: son 5 ölçümün min-max'ı.
  String? measuredLabel(String modelId) {
    final l = samples.where((s) => s.modelId == modelId && s.tokPerSec > 0).toList();
    if (l.isEmpty) return null;
    final t = l.sublist(l.length > 5 ? l.length - 5 : 0).map((s) => s.tokPerSec).toList()..sort();
    return '${t.first.toStringAsFixed(0)} - ${t.last.toStringAsFixed(0)} tok/s (ölçüldü)';
  }
}

final perfLogProvider = Provider<PerfLog>((ref) => PerfLog.instance);
