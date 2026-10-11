// Değişiklik: yeni dosya. Geliştirme Modu v2 hata defteri (DevLedger) ve model güven puanı (ModelTrust).
import 'dart:convert';
import 'dart:io';

import '../data/secret_mask.dart';
import 'dev_guard.dart';

/// Bir AI hatasının (kapı reddi, doğrulayıcı reddi vb.) defter kaydı. [detail] her zaman redact edilmiştir.
class DevErrorEntry {
  const DevErrorEntry({
    required this.tsMs,
    required this.role,
    required this.modelId,
    required this.gate,
    required this.detail,
    this.path = '',
    this.attempt = 0,
  });

  final int tsMs;

  /// analyst | fixer | verifier ...
  final String role;
  final String modelId;

  /// Kapı kodu (G1..G8 ...) veya başka bir hata sınıfı.
  final String gate;
  final String detail;
  final String path;
  final int attempt;

  Map<String, dynamic> toJson() => {
    'ts': tsMs,
    'role': role,
    'model': modelId,
    'gate': gate,
    'detail': detail,
    'path': path,
    'attempt': attempt,
  };

  factory DevErrorEntry.fromJson(Map<String, dynamic> j) => DevErrorEntry(
    tsMs: (j['ts'] as num?)?.toInt() ?? 0,
    role: (j['role'] as String?) ?? '',
    modelId: (j['model'] as String?) ?? '',
    gate: (j['gate'] as String?) ?? '',
    detail: (j['detail'] as String?) ?? '',
    path: (j['path'] as String?) ?? '',
    attempt: (j['attempt'] as num?)?.toInt() ?? 0,
  );

  String toJsonLine() => jsonEncode(toJson());
}

/// Defterin kalıcı depolaması (JSONL: satır başına bir kayıt).
abstract class LedgerStore {
  Future<void> append(String line);
  Future<String> readAll();
  Future<void> replaceAll(String content);
}

/// Bellek içi depo (varsayılan ve testler için).
class MemoryLedgerStore implements LedgerStore {
  MemoryLedgerStore();

  String _content = '';

  @override
  Future<void> append(String line) async {
    _content += '$line\n';
  }

  @override
  Future<String> readAll() async => _content;

  @override
  Future<void> replaceAll(String content) async {
    _content = content;
  }
}

/// Dosya tabanlı depo. Tüm işlemler sıraya konur; yenileme geçici dosya + rename ile yapılır.
/// Hiçbir işlem istisna sızdırmaz (defter yazılamasa da oturum çökmez).
class FileLedgerStore implements LedgerStore {
  FileLedgerStore(this.path);

  final String path;
  Future<void> _chain = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() job, T fallback) {
    final done = _chain.then((_) async {
      try {
        return await job();
      } catch (_) {
        return fallback;
      }
    });
    _chain = done.then((_) {});
    return done;
  }

  @override
  Future<void> append(String line) => _serial<void>(() async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }, null);

  @override
  Future<String> readAll() => _serial<String>(() async {
    final f = File(path);
    if (!await f.exists()) return '';
    return utf8.decode(await f.readAsBytes(), allowMalformed: true);
  }, '');

  @override
  Future<void> replaceAll(String content) => _serial<void>(() async {
    final f = File(path);
    await f.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(path);
  }, null);
}

/// AI hatalarının defteri: kaydeder, istatistik çıkarır ve sonraki isteklere "ders" listesi üretir.
class DevLedger {
  DevLedger({LedgerStore? store, int maxFileBytes = 256 * 1024, int Function()? nowMs})
    : _store = store ?? MemoryLedgerStore(),
      _maxFileBytes = maxFileBytes,
      _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Bellekte tutulan en çok kayıt (saatlerce çalışmada büyüme sınırı).
  static const int maxEntriesInMemory = 5000;
  static const int maxDetailChars = 500;

  /// Depodan okuyarak açar. Bozuk satırlar atlanır; hiçbir koşulda istisna fırlatmaz.
  static Future<DevLedger> open({
    LedgerStore? store,
    int maxFileBytes = 256 * 1024,
    int Function()? nowMs,
  }) async {
    final l = DevLedger(store: store, maxFileBytes: maxFileBytes, nowMs: nowMs);
    String raw;
    try {
      raw = await l._store.readAll();
    } catch (_) {
      raw = '';
    }
    for (final line in const LineSplitter().convert(raw)) {
      final t = line.trim();
      if (t.isEmpty) continue;
      try {
        final j = jsonDecode(t);
        if (j is Map) l._add(DevErrorEntry.fromJson(Map<String, dynamic>.from(j)));
      } catch (_) {
        // bozuk satır atlanır
      }
    }
    l._fileBytes = utf8.encode(raw).length;
    return l;
  }

  final LedgerStore _store;
  final int _maxFileBytes;
  final int Function() _nowMs;
  final List<DevErrorEntry> _entries = <DevErrorEntry>[];
  int _fileBytes = 0;
  Future<void> _chain = Future<void>.value();

  List<DevErrorEntry> get entries => List.unmodifiable(_entries);

  void _add(DevErrorEntry e) {
    _entries.add(e);
    if (_entries.length > maxEntriesInMemory) {
      _entries.removeRange(0, _entries.length - maxEntriesInMemory);
    }
  }

  /// Bir hatayı kaydeder. Metin alanları SecretMask'ten geçer; depolama hatası yutulur.
  Future<DevErrorEntry> record({
    required String role,
    required String modelId,
    required String gate,
    required String detail,
    String path = '',
    int attempt = 0,
  }) {
    var d = SecretMask.redact(detail);
    if (d.length > maxDetailChars) d = '${d.substring(0, maxDetailChars)}…';
    final e = DevErrorEntry(
      tsMs: _nowMs(),
      role: SecretMask.redact(role),
      modelId: SecretMask.redact(modelId),
      gate: gate,
      detail: d,
      path: SecretMask.redact(path),
      attempt: attempt,
    );
    _add(e);
    final done = _chain.then((_) => _persist(e));
    _chain = done;
    return done.then((_) => e);
  }

  Future<void> _persist(DevErrorEntry e) async {
    try {
      final line = e.toJsonLine();
      await _store.append(line);
      _fileBytes += utf8.encode(line).length + 1;
      if (_fileBytes > _maxFileBytes) await _rotate();
    } catch (_) {
      // defter yazılamasa da oturum sürer
    }
  }

  /// Dosyayı, en yeni kayıtlar sınırın içinde kalacak şekilde küçültür.
  Future<void> _rotate() async {
    final kept = <String>[];
    var bytes = 0;
    for (var i = _entries.length - 1; i >= 0; i--) {
      final line = _entries[i].toJsonLine();
      final n = utf8.encode(line).length + 1;
      if (bytes + n > _maxFileBytes) break;
      kept.add(line);
      bytes += n;
    }
    final content = kept.reversed.map((l) => '$l\n').join();
    await _store.replaceAll(content);
    _fileBytes = bytes;
  }

  Map<String, int> statsByModel() {
    final m = <String, int>{};
    for (final e in _entries) {
      m[e.modelId] = (m[e.modelId] ?? 0) + 1;
    }
    return m;
  }

  Map<String, int> statsByGate() {
    final m = <String, int>{};
    for (final e in _entries) {
      m[e.gate] = (m[e.gate] ?? 0) + 1;
    }
    return m;
  }

  /// Sonraki isteğe eklenecek kısa Türkçe "ders" listesi: en sık 5 kapı, örnekle.
  /// Hiç kayıt yoksa veya [maxChars] içine tek madde bile sığmıyorsa boş döner.
  String lessons({int maxChars = 600}) {
    if (_entries.isEmpty) return '';
    final byGate = statsByGate().entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    const header = 'ÖNCEKİ HATALARDAN KAÇIN:';
    final b = StringBuffer(header);
    var added = 0;
    for (final g in byGate.take(5)) {
      DevErrorEntry? last;
      for (var i = _entries.length - 1; i >= 0; i--) {
        if (_entries[i].gate == g.key) {
          last = _entries[i];
          break;
        }
      }
      final desc = kGateDescriptions[g.key];
      var ex = last == null ? '' : last.detail.replaceAll('\n', ' ');
      if (ex.length > 80) ex = '${ex.substring(0, 80)}…';
      final where = last == null || last.path.isEmpty ? '' : '${last.path}: ';
      final line =
          '\n- ${g.key} ×${g.value}${desc == null ? '' : ' ($desc)'}${ex.isEmpty ? '' : ' — örn. $where$ex'}';
      if (b.length + line.length > maxChars) break;
      b.write(line);
      added++;
    }
    return added == 0 ? '' : b.toString();
  }
}

/// Model başına üstel ağırlıklı ret oranı. Yeterli örnek ve yüksek ret oranında "demote" önerir;
/// oran düzelince "promote" önerir. Karar verme çağıranındır (mark* ile işlenir).
class ModelTrust {
  ModelTrust({
    this.alpha = 0.3,
    this.demoteThreshold = 0.5,
    this.recoverThreshold = 0.2,
    this.minSamples = 5,
  });

  final double alpha;
  final double demoteThreshold;
  final double recoverThreshold;
  final int minSamples;

  final Map<String, double> _rate = <String, double>{};
  final Map<String, int> _samples = <String, int>{};
  final Set<String> _demoted = <String>{};

  /// [rejected] true ise bu çıktı reddedildi (kapı veya doğrulayıcı).
  void observe(String modelId, bool rejected) {
    final x = rejected ? 1.0 : 0.0;
    final n = _samples[modelId] ?? 0;
    _rate[modelId] = n == 0 ? x : alpha * x + (1 - alpha) * (_rate[modelId] ?? 0.0);
    _samples[modelId] = n + 1;
  }

  double rate(String modelId) => _rate[modelId] ?? 0.0;

  int samplesOf(String modelId) => _samples[modelId] ?? 0;

  bool demoteRecommended(String modelId) =>
      !_demoted.contains(modelId) &&
      samplesOf(modelId) >= minSamples &&
      rate(modelId) > demoteThreshold;

  bool promoteRecommended(String modelId) =>
      _demoted.contains(modelId) &&
      samplesOf(modelId) >= minSamples &&
      rate(modelId) <= recoverThreshold;

  bool isDemoted(String modelId) => _demoted.contains(modelId);

  void markDemoted(String modelId) => _demoted.add(modelId);

  void markPromoted(String modelId) => _demoted.remove(modelId);
}
