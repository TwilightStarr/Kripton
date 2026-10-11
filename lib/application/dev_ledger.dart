// Görev 4/10 (Geliştirme Modu v2): hata defteri, "önceki hatalardan kaçın" dersleri ve model güveni.
//
// Saf Dart; ağ ve UI yok. Her ret/başarısızlık [DevErrorEntry] olarak kaydedilir; ayrıntılar
// SecretMask'ten geçer. Kalıcılık: JSONL (ekleme + boyut sınırlı döndürme), güven durumu AtomicFile ile.
// Hiçbir yöntem istisna fırlatmaz (defter hatası geliştirme oturumunu durdurmamalı).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../data/atomic_file.dart';
import '../data/secret_mask.dart';
import 'dev_guard.dart';

/// Kayıttaki rol adları.
class DevRole {
  const DevRole._();

  static const String analyst = 'analist';
  static const String fixer = 'düzeltici';
  static const String verifier = 'doğrulayıcı';
}

String _cleanText(String s, int max) {
  final r = SecretMask.redact(s).replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
  return r.length <= max ? r : '${r.substring(0, max)}…';
}

/// Defterdeki tek kayıt. Metin alanları oluşturulurken maskelenir ve kısaltılır.
///
/// [modelId]: çıktısı REDDEDİLEN model (yamayı yazan düzeltici; doğrulayıcı biçimi bozduysa doğrulayıcı).
class DevErrorEntry {
  DevErrorEntry({
    required this.ts,
    required String rol,
    required String modelId,
    required String kapiKodu,
    required String ayrinti,
    String dosya = '',
    this.deneme = 0,
  }) : rol = _cleanText(rol, 40),
       modelId = _cleanText(modelId, 120),
       kapiKodu = _cleanText(kapiKodu, 12),
       ayrinti = _cleanText(ayrinti, 400),
       dosya = _cleanText(dosya, 200);

  /// Epoch milisaniye.
  final int ts;
  final String rol;
  final String modelId;
  final String kapiKodu;
  final String ayrinti;
  final String dosya;

  /// Aynı iş için kaçıncı deneme (0 = bilinmiyor/ilk).
  final int deneme;

  Map<String, Object?> toJson() => {
    'ts': ts,
    'rol': rol,
    'model': modelId,
    'kapi': kapiKodu,
    'ayrinti': ayrinti,
    'dosya': dosya,
    'deneme': deneme,
  };

  /// Bozuk/eksik kayıt için null (istisna fırlatmaz).
  static DevErrorEntry? tryParse(Object? j) {
    if (j is! Map) return null;
    final ts = j['ts'];
    final kapi = j['kapi'];
    if (ts is! int || kapi is! String || kapi.isEmpty) return null;
    String s(String k) {
      final v = j[k];
      return v is String ? v : '';
    }

    final d = j['deneme'];
    return DevErrorEntry(
      ts: ts,
      rol: s('rol'),
      modelId: s('model'),
      kapiKodu: kapi,
      ayrinti: s('ayrinti'),
      dosya: s('dosya'),
      deneme: d is int ? d : 0,
    );
  }
}

/// Bir modelin EWMA ret oranı ve histerezisli "demote" önerisi.
///
/// Ret oranı = üssel hareketli ortalama (alfa). En az [minSamples] gözlemden sonra oran
/// [demoteAbove]'u aşarsa model "demote" önerilir; oran [restoreBelow]'un altına inince öneri kalkar.
class ModelTrust {
  ModelTrust({
    this.alpha = 0.2,
    this.demoteAbove = 0.6,
    this.restoreBelow = 0.35,
    this.minSamples = 5,
    this.maxModels = 64,
  });

  final double alpha;
  final double demoteAbove;
  final double restoreBelow;
  final int minSamples;
  final int maxModels;

  final Map<String, _Trust> _m = <String, _Trust>{};

  /// Bir sonucu işler (rejected: true = ret/başarısızlık).
  void observe(String modelId, {required bool rejected}) {
    final id = modelId.trim();
    if (id.isEmpty) return;
    final t = _m.remove(id) ?? _Trust();
    final x = rejected ? 1.0 : 0.0;
    t.rate = t.samples == 0 ? x : (alpha * x + (1 - alpha) * t.rate);
    t.samples++;
    if (t.samples >= minSamples) {
      if (!t.demoted && t.rate > demoteAbove) t.demoted = true;
      if (t.demoted && t.rate < restoreBelow) t.demoted = false;
    }
    _m[id] = t; // en son gözlenen sona taşınır
    while (_m.length > maxModels) {
      _m.remove(_m.keys.first);
    }
  }

  /// EWMA ret oranı (0..1); bilinmeyen model için 0.
  double rate(String modelId) => _m[modelId.trim()]?.rate ?? 0;

  int samples(String modelId) => _m[modelId.trim()]?.samples ?? 0;

  /// true: bu model için demote önerilir (daha güvenilir bir modele geç).
  bool isDemoted(String modelId) => _m[modelId.trim()]?.demoted ?? false;

  /// Şu an demote önerilen modeller.
  Set<String> demoted() => {
    for (final e in _m.entries)
      if (e.value.demoted) e.key,
  };

  Map<String, Object?> toJson() => {
    'v': 1,
    'models': {
      for (final e in _m.entries) e.key: {'r': e.value.rate, 'n': e.value.samples, 'd': e.value.demoted},
    },
  };

  /// Bozuk veriyi yok sayar; geçerli kayıtları yükler.
  void loadJson(Object? j) {
    _m.clear();
    if (j is! Map) return;
    final models = j['models'];
    if (models is! Map) return;
    for (final e in models.entries) {
      final k = e.key;
      final v = e.value;
      if (k is! String || k.trim().isEmpty || v is! Map) continue;
      final r = v['r'];
      final n = v['n'];
      final d = v['d'];
      if (r is! num || n is! int || !r.isFinite || n < 0) continue;
      _m[k] = _Trust()
        ..rate = r.toDouble().clamp(0.0, 1.0).toDouble()
        ..samples = n
        ..demoted = d == true;
      if (_m.length >= maxModels) break;
    }
  }
}

class _Trust {
  double rate = 0;
  int samples = 0;
  bool demoted = false;
}

/// Hata defteri. [dir] verilirse JSONL olarak kalıcıdır; verilmezse yalnızca bellektedir.
class DevLedger {
  DevLedger({
    Directory? dir,
    this.fileName = 'dev_ledger.jsonl',
    this.maxFileBytes = 256 * 1024,
    this.maxMemoryEntries = 500,
    ModelTrust? trust,
    int Function()? now,
  }) : _dir = dir,
       trust = trust ?? ModelTrust(),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Directory? _dir;
  final String fileName;

  /// Ana dosya bu boyutu aşınca `.1` olarak döndürülür (eski `.1` silinir).
  final int maxFileBytes;
  final int maxMemoryEntries;
  final ModelTrust trust;
  final int Function() _now;

  final List<DevErrorEntry> _entries = <DevErrorEntry>[];
  Future<void> _chain = Future<void>.value();

  /// Yüklemede atlanan bozuk satır sayısı.
  int corruptLines = 0;

  /// Yazılamayan kayıt sayısı (G/Ç hatası); defter bellekte çalışmaya devam eder.
  int writeFailures = 0;

  /// Bellekteki kayıt sayısı (en çok [maxMemoryEntries]).
  int get entryCount => _entries.length;

  List<DevErrorEntry> get entries => List<DevErrorEntry>.unmodifiable(_entries);

  String? get _path {
    final d = _dir;
    return d == null ? null : p.join(d.path, fileName);
  }

  String? get _trustPath {
    final d = _dir;
    return d == null ? null : p.join(d.path, 'dev_trust.json');
  }

  /// Diskten yükler (varsa). Bozuk satırlar atlanır; hiçbir koşulda istisna fırlatmaz.
  Future<void> load() async {
    _entries.clear();
    corruptLines = 0;
    final path = _path;
    if (path == null) return;
    try {
      final cap = maxFileBytes * 2;
      for (final f in <String>['$path.1', path]) {
        for (final line in await _readLines(File(f), cap)) {
          final t = line.trim();
          if (t.isEmpty) continue;
          DevErrorEntry? e;
          try {
            e = DevErrorEntry.tryParse(jsonDecode(t));
          } catch (_) {
            e = null;
          }
          if (e == null) {
            corruptLines++;
          } else {
            _entries.add(e);
          }
        }
      }
      _trim();
    } catch (_) {
      // Okunamayan defter: bellek boş kalır.
    }
    try {
      final tp = _trustPath;
      if (tp != null) trust.loadJson(await AtomicFile.readJson(tp));
    } catch (_) {
      trust.loadJson(null);
    }
  }

  static Future<List<String>> _readLines(File f, int cap) async {
    if (!await f.exists()) return const [];
    final raf = await f.open();
    try {
      final len = await raf.length();
      final start = len > cap ? len - cap : 0;
      await raf.setPosition(start);
      final bytes = await raf.read(len - start);
      final lines = utf8.decode(bytes, allowMalformed: true).split('\n');
      if (start > 0 && lines.isNotEmpty) lines.removeAt(0); // kesik ilk satır
      return lines;
    } finally {
      await raf.close();
    }
  }

  void _trim() {
    if (_entries.length > maxMemoryEntries) {
      _entries.removeRange(0, _entries.length - maxMemoryEntries);
    }
  }

  /// Bir ret/başarısızlığı kaydeder (bellek hemen, disk sıraya alınarak). Asla istisna fırlatmaz.
  Future<void> record(DevErrorEntry e) {
    _entries.add(e);
    _trim();
    trust.observe(e.modelId, rejected: true);
    return _enqueue(() => _persist(e));
  }

  /// Bir [GuardVerdict]'in her ihlalini ayrı kayıt olarak yazar ([modelId]: yamayı yazan model).
  Future<void> recordVerdict(
    GuardVerdict v, {
    required String rol,
    required String modelId,
    int deneme = 0,
  }) async {
    final ts = _now();
    final made = <DevErrorEntry>[
      for (final x in v.violations)
        DevErrorEntry(
          ts: ts,
          rol: rol,
          modelId: modelId,
          kapiKodu: x.code,
          ayrinti: x.detail,
          dosya: x.path,
          deneme: deneme,
        ),
    ];
    _entries.addAll(made);
    _trim();
    if (made.isNotEmpty) trust.observe(modelId, rejected: true);
    await _enqueue(() async {
      for (final e in made) {
        await _persistLine(e);
      }
      await _saveTrust();
    });
  }

  /// Doğrulayıcı kararını kaydeder: RED/ayrıştırılamadı ise ilgili kapıyla, ONAY ise güven artışı olarak.
  /// [fixerModelId]: yamayı yazan model (RED onun sayılır); [verifierModelId]: ayrıştırılamama durumunda suçlanan.
  Future<void> recordVerifier(
    VerifierVerdict v, {
    required String fixerModelId,
    required String verifierModelId,
    String dosya = '',
    int deneme = 0,
  }) {
    if (v.approved) return recordSuccess(modelId: fixerModelId);
    final unparsed = !v.parsed;
    return record(
      DevErrorEntry(
        ts: _now(),
        rol: unparsed ? DevRole.verifier : DevRole.fixer,
        modelId: unparsed ? verifierModelId : fixerModelId,
        kapiKodu: v.gate,
        ayrinti: unparsed ? (v.problem ?? 'belirsiz') : v.reasons.join(' / '),
        dosya: dosya,
        deneme: deneme,
      ),
    );
  }

  /// Başarılı (kapılardan ve doğrulayıcıdan geçen) bir sonucu güven hesabına işler.
  Future<void> recordSuccess({required String modelId}) {
    trust.observe(modelId, rejected: false);
    return _enqueue(_saveTrust);
  }

  /// Bekleyen yazmaların bitmesini bekler.
  Future<void> flush() => _chain;

  Future<void> _enqueue(Future<void> Function() job) {
    _chain = _chain.then((_) async {
      try {
        await job();
      } catch (_) {
        writeFailures++;
      }
    });
    return _chain;
  }

  Future<void> _persist(DevErrorEntry e) async {
    await _persistLine(e);
    await _saveTrust();
  }

  Future<void> _persistLine(DevErrorEntry e) async {
    final path = _path;
    if (path == null) return;
    final f = File(path);
    await f.parent.create(recursive: true);
    if (await f.exists() && await f.length() >= maxFileBytes) {
      final old = File('$path.1');
      if (await old.exists()) await old.delete();
      await f.rename(old.path);
    }
    // Önceki yazma yarım kaldıysa (satır sonu yok) yeni kayıt yeni satırdan başlasın.
    var prefix = '';
    if (await f.exists() && await f.length() > 0) {
      final raf = await f.open();
      try {
        await raf.setPosition(await raf.length() - 1);
        final last = await raf.read(1);
        if (last.isNotEmpty && last[0] != 0x0a) prefix = '\n';
      } finally {
        await raf.close();
      }
    }
    await f.writeAsString('$prefix${jsonEncode(e.toJson())}\n', mode: FileMode.append, flush: true);
  }

  Future<void> _saveTrust() async {
    final tp = _trustPath;
    if (tp == null) return;
    await AtomicFile.writeJson(tp, trust.toJson());
  }

  // ---------------- Özetler ----------------

  /// Model başına ret sayısı (çoktan aza).
  Map<String, int> statsByModel() => _countBy((e) => e.modelId);

  /// Kapı kodu başına ret sayısı (çoktan aza).
  Map<String, int> statsByGate() => _countBy((e) => e.kapiKodu);

  Map<String, int> _countBy(String Function(DevErrorEntry) key) {
    final m = <String, int>{};
    for (final e in _entries) {
      final k = key(e);
      if (k.isEmpty) continue;
      m[k] = (m[k] ?? 0) + 1;
    }
    final keys = m.keys.toList()
      ..sort((a, b) {
        final c = m[b]!.compareTo(m[a]!);
        return c != 0 ? c : a.compareTo(b);
      });
    return {for (final k in keys) k: m[k]!};
  }

  static const String _header = 'ÖNCEKİ HATALARDAN KAÇIN:';

  /// Sonraki isteğe eklenecek kısa Türkçe ders listesi (en sık 3-5 kapı, örnekli).
  /// Uzunluk her zaman en çok [maxChars]; ders yoksa ya da sığmıyorsa boş metin.
  String lessons({int maxChars = 600}) {
    if (_entries.isEmpty || maxChars < _header.length + 40) return '';
    final window = _entries.length > 300 ? _entries.sublist(_entries.length - 300) : _entries;
    final count = <String, int>{};
    final last = <String, DevErrorEntry>{};
    for (final e in window) {
      if (e.kapiKodu.isEmpty) continue;
      count[e.kapiKodu] = (count[e.kapiKodu] ?? 0) + 1;
      last[e.kapiKodu] = e;
    }
    if (count.isEmpty) return '';
    final codes = count.keys.toList()
      ..sort((a, b) {
        final c = count[b]!.compareTo(count[a]!);
        return c != 0 ? c : last[b]!.ts.compareTo(last[a]!.ts);
      });
    final top = codes.take(5).toList();

    String line(String code, {required bool example}) {
      final b = StringBuffer('- $code ${DevGate.title(code)} (${count[code]}×): ${DevGate.advice(code)}');
      if (example) {
        final ex = _cleanText(last[code]!.ayrinti, 60);
        if (ex.isNotEmpty) b.write(' Örn: "$ex"');
      }
      return b.toString();
    }

    String build(int k, bool example) =>
        [_header, for (final c in top.take(k)) line(c, example: example)].join('\n');

    for (var k = top.length; k >= 1; k--) {
      for (final ex in const [true, false]) {
        final s = build(k, ex);
        if (s.length <= maxChars) return s;
      }
    }
    final s = build(1, false);
    return '${s.substring(0, math.max(0, maxChars - 1))}…';
  }
}
