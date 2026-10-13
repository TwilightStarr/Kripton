// Görev 5/19 (Geliştirme Modu v2): oturum olay deposu.
//
// Dizin düzeni: `<kök>/dev_sessions/<oturum-id>/`
//   events.jsonl (+ .1, .2, ... döndürülmüş)  olay günlüğü: toplu ekleme, boyut sınırlı döndürme
//   session.json                              kontrol noktası (AtomicFile)
//   changes.json                              dosya -> durum / commit sha / ilk-son içerik özeti (AtomicFile)
//
// Hafif: [DevSessionStore.append] senkron döner, satırlar bellekte toplanır ve toplu yazılır. Kalp atışı
// olayları akışa her zaman gider ama diske seyrek yazılır (günlük dolup önemli olayları itmesin).
// Dayanıklı: bozuk satır/dosya atlanır; yarım kalan son satır sonraki ekleme öncesi kapatılır; G/Ç hataları
// sayılır ve yutulur (depo, geliştirme oturumunu durdurmaz). Sırlar: her metin SecretMask'ten geçer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/atomic_file.dart';
import '../data/secret_mask.dart';

/// Olay önem seviyesi. JSON değeri `name`.
enum DevEventLevel { bilgi, uyari, hata }

/// Olay türü. JSON değeri `name`.
enum DevEventKind { asama, analiz, yama, commit, ci, geriAlma, bekleme, kalpAtisi, durum }

String _clean(String s, int max) {
  final r = SecretMask.redact(s).replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), ' ');
  final t = r.trim();
  return t.length <= max ? t : '${t.substring(0, max)}…';
}

/// Oturumdaki tek olay. Metin alanları oluşturulurken maskelenir ve kısaltılır.
class DevEvent {
  DevEvent({
    DateTime? ts,
    this.level = DevEventLevel.bilgi,
    required this.kind,
    required String message,
    List<String> files = const [],
    String sha = '',
    String runUrl = '',
    String modelId = '',
  })  : ts = (ts ?? DateTime.now()).toUtc(),
        message = _clean(message, 4000),
        files = List<String>.unmodifiable(_cleanFiles(files)),
        sha = _clean(sha, 80),
        runUrl = _clean(runUrl, 300),
        modelId = _clean(modelId, 160);

  final DateTime ts;
  final DevEventLevel level;
  final DevEventKind kind;

  /// Redakte edilmiş mesaj (en çok 4000 karakter).
  final String message;
  final List<String> files;
  final String sha;
  final String runUrl;
  final String modelId;

  static List<String> _cleanFiles(List<String> f) {
    final seen = <String>{};
    final out = <String>[];
    for (final x in f) {
      final c = _clean(x, 300);
      if (c.isEmpty || !seen.add(c)) continue;
      out.add(c);
      if (out.length >= 100) break;
    }
    return out;
  }

  Map<String, Object?> toJson() => {
        'ts': ts.millisecondsSinceEpoch,
        'seviye': level.name,
        'tur': kind.name,
        'mesaj': message,
        if (files.isNotEmpty) 'dosyalar': files,
        if (sha.isNotEmpty) 'sha': sha,
        if (runUrl.isNotEmpty) 'runUrl': runUrl,
        if (modelId.isNotEmpty) 'modelId': modelId,
      };

  /// Geçersiz/bozuk girdide null. Bilinmeyen seviye `bilgi`, bilinmeyen tür `durum` sayılır.
  static DevEvent? tryParse(Object? j) {
    if (j is! Map) return null;
    final ts = j['ts'];
    if (ts is! num) return null;
    final msg = j['mesaj'];
    if (msg is! String) return null;
    final lv = j['seviye'];
    final kd = j['tur'];
    final files = j['dosyalar'];
    return DevEvent(
      ts: DateTime.fromMillisecondsSinceEpoch(ts.toInt(), isUtc: true),
      level: DevEventLevel.values.firstWhere((e) => e.name == lv, orElse: () => DevEventLevel.bilgi),
      kind: DevEventKind.values.firstWhere((e) => e.name == kd, orElse: () => DevEventKind.durum),
      message: msg,
      files: files is List ? [for (final f in files) if (f is String) f] : const [],
      sha: j['sha'] is String ? j['sha'] as String : '',
      runUrl: j['runUrl'] is String ? j['runUrl'] as String : '',
      modelId: j['modelId'] is String ? j['modelId'] as String : '',
    );
  }

  @override
  String toString() => 'DevEvent(${kind.name}/${level.name}: $message)';
}

/// Oturum durumu.
enum DevSessionStatus { hazir, calisiyor, bekliyor, duraklatildi, tamamlandi, hata, iptal }

/// Kontrol noktası (`session.json`). Token/anahtar İÇERMEZ; serbest metinler maskelenir.
class DevSessionState {
  DevSessionState({
    required String id,
    this.status = DevSessionStatus.hazir,
    String repo = '',
    String branch = '',
    String baseBranch = '',
    String headSha = '',
    DateTime? startedAt,
    DateTime? updatedAt,
    Map<String, int> counters = const {},
    List<String> blockedFiles = const [],
    List<String> lastSignatures = const [],
    Map<String, String> models = const {},
    String phase = '',
    String note = '',
  })  : id = DevSessionStore.sanitizeId(id),
        repo = _clean(repo, 120),
        branch = _clean(branch, 200),
        baseBranch = _clean(baseBranch, 200),
        headSha = _clean(headSha, 80),
        startedAt = (startedAt ?? DateTime.now()).toUtc(),
        updatedAt = (updatedAt ?? startedAt ?? DateTime.now()).toUtc(),
        counters = Map<String, int>.unmodifiable(_cleanCounters(counters)),
        blockedFiles = List<String>.unmodifiable(_cleanList(blockedFiles, 200, 300)),
        lastSignatures = List<String>.unmodifiable(_cleanList(lastSignatures, 20, 160)),
        models = Map<String, String>.unmodifiable({
          for (final e in models.entries.take(8)) _clean(e.key, 40): _clean(e.value, 160),
        }),
        phase = _clean(phase, 80),
        note = _clean(note, 400);

  final String id;
  final DevSessionStatus status;
  final String repo;
  final String branch;
  final String baseBranch;
  final String headSha;
  final DateTime startedAt;
  final DateTime updatedAt;

  /// Sayaçlar (ör. `deneme`, `commit`, `ciHata`, `red`).
  final Map<String, int> counters;

  /// Art arda başarısız olduğu için bloklanan dosyalar.
  final List<String> blockedFiles;

  /// Son CI hata imzaları (`CiFailureSignature.id`); döngü tespiti için.
  final List<String> lastSignatures;

  /// Rol -> model kimliği (devam ederken aynı atamaya dönmek için).
  final Map<String, String> models;
  final String phase;
  final String note;

  static Map<String, int> _cleanCounters(Map<String, int> c) {
    final out = <String, int>{};
    for (final e in c.entries) {
      final k = _clean(e.key, 40);
      if (k.isEmpty) continue;
      out[k] = e.value;
      if (out.length >= 64) break;
    }
    return out;
  }

  static List<String> _cleanList(List<String> l, int maxItems, int maxLen) {
    final out = <String>[];
    for (final x in l) {
      final c = _clean(x, maxLen);
      if (c.isEmpty || out.contains(c)) continue;
      out.add(c);
    }
    return out.length > maxItems ? out.sublist(out.length - maxItems) : out;
  }

  DevSessionState copyWith({
    DevSessionStatus? status,
    String? repo,
    String? branch,
    String? baseBranch,
    String? headSha,
    DateTime? updatedAt,
    Map<String, int>? counters,
    List<String>? blockedFiles,
    List<String>? lastSignatures,
    Map<String, String>? models,
    String? phase,
    String? note,
  }) =>
      DevSessionState(
        id: id,
        status: status ?? this.status,
        repo: repo ?? this.repo,
        branch: branch ?? this.branch,
        baseBranch: baseBranch ?? this.baseBranch,
        headSha: headSha ?? this.headSha,
        startedAt: startedAt,
        updatedAt: updatedAt ?? this.updatedAt,
        counters: counters ?? this.counters,
        blockedFiles: blockedFiles ?? this.blockedFiles,
        lastSignatures: lastSignatures ?? this.lastSignatures,
        models: models ?? this.models,
        phase: phase ?? this.phase,
        note: note ?? this.note,
      );

  /// [name] sayacını [by] kadar artırılmış kopya.
  DevSessionState incremented(String name, [int by = 1]) =>
      copyWith(counters: {...counters, name: (counters[name] ?? 0) + by});

  Map<String, Object?> toJson() => {
        'v': 1,
        'id': id,
        'durum': status.name,
        'depo': repo,
        'dal': branch,
        'tabanDal': baseBranch,
        'headSha': headSha,
        'baslangic': startedAt.millisecondsSinceEpoch,
        'son': updatedAt.millisecondsSinceEpoch,
        'sayaclar': counters,
        'blokluDosyalar': blockedFiles,
        'imzalar': lastSignatures,
        'modeller': models,
        'asama': phase,
        'not': note,
      };

  /// Bozuk girdide null; alan tipi yanlışsa o alan varsayılana düşer (kısmi okuma).
  static DevSessionState? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String || id.trim().isEmpty) return null;
    String s(String k) => j[k] is String ? j[k] as String : '';
    DateTime? d(String k) => j[k] is num ? DateTime.fromMillisecondsSinceEpoch((j[k] as num).toInt(), isUtc: true) : null;
    List<String> l(String k) => j[k] is List ? [for (final e in j[k] as List) if (e is String) e] : const [];
    final c = j['sayaclar'];
    final m = j['modeller'];
    return DevSessionState(
      id: id,
      status: DevSessionStatus.values.firstWhere((e) => e.name == j['durum'], orElse: () => DevSessionStatus.hazir),
      repo: s('depo'),
      branch: s('dal'),
      baseBranch: s('tabanDal'),
      headSha: s('headSha'),
      startedAt: d('baslangic'),
      updatedAt: d('son'),
      counters: c is Map ? {for (final e in c.entries) if (e.key is String && e.value is num) e.key as String: (e.value as num).toInt()} : const {},
      blockedFiles: l('blokluDosyalar'),
      lastSignatures: l('imzalar'),
      models: m is Map ? {for (final e in m.entries) if (e.key is String && e.value is String) e.key as String: e.value as String} : const {},
      phase: s('asama'),
      note: s('not'),
    );
  }
}

/// `changes.json` içindeki dosya durumu.
enum DevChangeStatus { eklendi, degistirildi, silindi, geriAlindi }

/// İçerik özeti: uzunluk, satır sayısı, SHA-256'nın ilk 16 hex'i ve maskelenmiş kısa önizleme.
/// Tam içerik SAKLANMAZ.
class DevContentDigest {
  const DevContentDigest({required this.length, required this.lines, required this.hash, required this.preview});

  factory DevContentDigest.of(String content) {
    final h = sha256.convert(utf8.encode(content)).toString().substring(0, 16);
    final head = content.length > 120 ? content.substring(0, 120) : content;
    final prev = _clean(head.replaceAll(RegExp(r'\s+'), ' '), 120);
    final lines = content.isEmpty ? 0 : '\n'.allMatches(content).length + (content.endsWith('\n') ? 0 : 1);
    return DevContentDigest(length: content.length, lines: lines, hash: h, preview: prev);
  }

  final int length;
  final int lines;
  final String hash;
  final String preview;

  Map<String, Object?> toJson() => {'uzunluk': length, 'satir': lines, 'hash': hash, 'onizleme': preview};

  static DevContentDigest? tryParse(Object? j) {
    if (j is! Map) return null;
    final l = j['uzunluk'];
    final n = j['satir'];
    final h = j['hash'];
    if (l is! num || n is! num || h is! String) return null;
    final pv = j['onizleme'];
    return DevContentDigest(
      length: l.toInt(),
      lines: n.toInt(),
      hash: _clean(h, 32),
      preview: pv is String ? _clean(pv, 120) : '',
    );
  }
}

/// Bir dosyanın oturum boyunca geçirdiği değişiklikler.
class DevChange {
  const DevChange({
    required this.path,
    required this.status,
    required this.commitSha,
    required this.updatedAt,
    this.commits = 1,
    this.first,
    this.last,
  });

  final String path;
  final DevChangeStatus status;

  /// Son değişikliği içeren commit (bilinmiyorsa boş).
  final String commitSha;
  final DateTime updatedAt;
  final int commits;

  /// İlk ve son içerik özeti (silinen dosyada [last] null).
  final DevContentDigest? first;
  final DevContentDigest? last;

  Map<String, Object?> toJson() => {
        'durum': status.name,
        'commit': commitSha,
        'ts': updatedAt.millisecondsSinceEpoch,
        'commitSayisi': commits,
        if (first != null) 'ilk': first!.toJson(),
        if (last != null) 'son': last!.toJson(),
      };

  static DevChange? tryParse(String path, Object? j) {
    if (j is! Map) return null;
    final ts = j['ts'];
    if (ts is! num) return null;
    final cs = j['commitSayisi'];
    return DevChange(
      path: path,
      status: DevChangeStatus.values.firstWhere((e) => e.name == j['durum'], orElse: () => DevChangeStatus.degistirildi),
      commitSha: j['commit'] is String ? _clean(j['commit'] as String, 80) : '',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(ts.toInt(), isUtc: true),
      commits: cs is num ? cs.toInt() : 1,
      first: DevContentDigest.tryParse(j['ilk']),
      last: DevContentDigest.tryParse(j['son']),
    );
  }
}

/// [DevSessionStore.listSessions] satırı.
class DevSessionInfo {
  const DevSessionInfo({
    required this.id,
    required this.status,
    required this.branch,
    required this.startedAt,
    required this.updatedAt,
    required this.readable,
  });

  final String id;
  final DevSessionStatus status;
  final String branch;
  final DateTime? startedAt;
  final DateTime updatedAt;

  /// false: `session.json` yok/okunamadı (dizin var).
  final bool readable;
}

/// Tek bir oturumun olay deposu. Bkz. dosya başlığı.
class DevSessionStore {
  DevSessionStore({
    required Directory baseDir,
    required String sessionId,
    this.maxEventBytes = 256 * 1024,
    this.rotatedKeep = 3,
    this.flushInterval = const Duration(milliseconds: 500),
    this.maxBatch = 50,
    this.maxChangeEntries = 2000,
    this.heartbeatMinGap = const Duration(seconds: 60),
    DateTime Function()? now,
  })  : _base = baseDir,
        id = sanitizeId(sessionId),
        _now = now ?? DateTime.now;

  static const String rootDirName = 'dev_sessions';
  static const String eventsFileName = 'events.jsonl';
  static const String sessionFileName = 'session.json';
  static const String changesFileName = 'changes.json';

  final Directory _base;

  /// Temizlenmiş oturum kimliği (dizin adı).
  final String id;

  /// Ana olay dosyası bu boyutu aşacak olursa `.1` olarak döndürülür (eskiler `.2`, `.3`...).
  final int maxEventBytes;

  /// Tutulan döndürülmüş dosya sayısı.
  final int rotatedKeep;
  final Duration flushInterval;
  final int maxBatch;
  final int maxChangeEntries;

  /// Kalp atışı olaylarının diske yazılma en kısa aralığı (akışa her zaman gider).
  final Duration heartbeatMinGap;
  final DateTime Function() _now;

  final List<DevEvent> _buffer = <DevEvent>[];
  final StreamController<DevEvent> _controller = StreamController<DevEvent>.broadcast();
  Timer? _timer;
  Future<void> _eventChain = Future<void>.value();
  Future<void> _stateChain = Future<void>.value();
  bool _closed = false;
  bool _tailChecked = false;
  DateTime? _lastHeartbeatPersist;
  Map<String, DevChange>? _changes;

  /// Yükleme/okumada atlanan bozuk olay satırı sayısı.
  int corruptLines = 0;

  /// Yazılamayan toplu yazma/dosya sayısı (G/Ç hatası).
  int writeFailures = 0;

  /// Kimlik temizleme: yalnızca `A-Z a-z 0-9 . _ -`; en çok 80 karakter; boşsa `oturum`; `..` olamaz.
  static String sanitizeId(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').replaceAll('..', '_');
    while (s.startsWith('.')) {
      s = s.substring(1);
    }
    if (s.length > 80) s = s.substring(0, 80);
    return s.isEmpty ? 'oturum' : s;
  }

  Directory get dir => Directory(p.join(_base.path, rootDirName, id));
  String get _eventsPath => p.join(dir.path, eventsFileName);
  String get _sessionPath => p.join(dir.path, sessionFileName);
  String get _changesPath => p.join(dir.path, changesFileName);

  /// Olay akışı (yayın). Olaylar diske yazılmadan önce de gelir.
  Stream<DevEvent> get events => _controller.stream;

  // ------------------------------------------------------------ olaylar

  /// Olayı ekler: akışa hemen, diske toplu. Senkron, hafif ve istisna fırlatmaz.
  void append(DevEvent e) {
    if (_closed) return;
    try {
      _controller.add(e);
    } catch (_) {}
    if (e.kind == DevEventKind.kalpAtisi) {
      final last = _lastHeartbeatPersist;
      if (last != null && e.ts.difference(last) < heartbeatMinGap) return;
      _lastHeartbeatPersist = e.ts;
      // Tamponda bekleyen eski kalp atışı varsa yenisiyle değiştirilir.
      final i = _buffer.lastIndexWhere((x) => x.kind == DevEventKind.kalpAtisi);
      if (i >= 0 && i == _buffer.length - 1) {
        _buffer[i] = e;
        _schedule();
        return;
      }
    }
    _buffer.add(e);
    if (_buffer.length >= maxBatch) {
      unawaited(flush());
    } else {
      _schedule();
    }
  }

  /// Kolaylık: olay oluşturup ekler.
  void log(
    DevEventKind kind,
    String message, {
    DevEventLevel level = DevEventLevel.bilgi,
    List<String> files = const [],
    String sha = '',
    String runUrl = '',
    String modelId = '',
  }) =>
      append(DevEvent(
        ts: _now(),
        level: level,
        kind: kind,
        message: message,
        files: files,
        sha: sha,
        runUrl: runUrl,
        modelId: modelId,
      ));

  void _schedule() {
    if (_timer != null || _closed) return;
    _timer = Timer(flushInterval, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Tamponu diske yazar; yazma bitince tamamlanır. Asla istisna fırlatmaz.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_buffer.isNotEmpty) {
      final batch = List<DevEvent>.of(_buffer);
      _buffer.clear();
      _eventChain = _eventChain.then((_) => _writeBatch(batch)).catchError((Object _) {
        writeFailures++;
      });
    }
    return _eventChain;
  }

  Future<void> _writeBatch(List<DevEvent> batch) async {
    try {
      final text = '${batch.map((e) => SecretMask.redact(jsonEncode(e.toJson()))).join('\n')}\n';
      final bytes = utf8.encode(text);
      await dir.create(recursive: true);
      final file = File(_eventsPath);
      var size = await file.exists() ? await file.length() : 0;
      if (size > 0 && size + bytes.length > maxEventBytes) {
        await _rotate();
        size = 0;
      }
      var prefix = const <int>[];
      if (!_tailChecked && size > 0) {
        // Önceki oturum/çökme yarım satır bırakmış olabilir: yeni satıra geç.
        prefix = await _endsWithNewline(file) ? const <int>[] : const [10];
      }
      _tailChecked = true;
      await file.writeAsBytes(<int>[...prefix, ...bytes], mode: FileMode.append, flush: true);
    } catch (_) {
      writeFailures++;
    }
  }

  static Future<bool> _endsWithNewline(File f) async {
    final raf = await f.open();
    try {
      final len = await raf.length();
      if (len == 0) return true;
      await raf.setPosition(len - 1);
      final b = await raf.read(1);
      return b.isNotEmpty && b.first == 10;
    } finally {
      await raf.close();
    }
  }

  Future<void> _rotate() async {
    final main = File(_eventsPath);
    try {
      final oldest = File('$_eventsPath.$rotatedKeep');
      if (await oldest.exists()) await oldest.delete();
      for (var i = rotatedKeep - 1; i >= 1; i--) {
        final f = File('$_eventsPath.$i');
        if (await f.exists()) await f.rename('$_eventsPath.${i + 1}');
      }
      if (rotatedKeep >= 1) {
        await main.rename('$_eventsPath.1');
      } else {
        await main.delete();
      }
    } catch (_) {
      try {
        if (await main.exists()) await main.delete();
      } catch (_) {
        writeFailures++;
      }
    }
    _tailChecked = true;
  }

  /// Son [n] olay (eskiden yeniye). Önce tamponu yazar; bozuk satırlar atlanır ([corruptLines]).
  Future<List<DevEvent>> tail(int n) async {
    if (n <= 0) return const [];
    await flush();
    final out = <DevEvent>[];
    try {
      final paths = <String>[_eventsPath, for (var i = 1; i <= rotatedKeep; i++) '$_eventsPath.$i'];
      for (final path in paths) {
        if (out.length >= n) break;
        final parsed = <DevEvent>[];
        for (final line in await _readLines(File(path), maxEventBytes * 2)) {
          final t = line.trim();
          if (t.isEmpty) continue;
          DevEvent? e;
          try {
            e = DevEvent.tryParse(jsonDecode(t));
          } catch (_) {
            e = null;
          }
          if (e == null) {
            corruptLines++;
          } else {
            parsed.add(e);
          }
        }
        out.insertAll(0, parsed);
      }
    } catch (_) {
      // Okunamayan günlük: eldeki kadarı döner.
    }
    return out.length > n ? out.sublist(out.length - n) : out;
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

  // ------------------------------------------------------------ kontrol noktası

  Future<T> _serial<T>(Future<T> Function() job, T fallback) {
    final c = Completer<T>();
    _stateChain = _stateChain.then((_) async {
      try {
        c.complete(await job());
      } catch (_) {
        writeFailures++;
        c.complete(fallback);
      }
    });
    return c.future;
  }

  /// `session.json` okur. Dosya yok/bozuksa (ve yedekten kurtarılamazsa) null.
  Future<DevSessionState?> loadSession() => _serial<DevSessionState?>(() async {
        final raw = await AtomicFile.readJson(_sessionPath);
        return DevSessionState.tryParse(raw);
      }, null);

  /// Kontrol noktasını atomik yazar ([DevSessionState.updatedAt] şimdiye çekilir). Başarıyı döner.
  Future<bool> saveCheckpoint(DevSessionState s) => _serial<bool>(() async {
        final state = s.copyWith(updatedAt: _now().toUtc());
        final withId = state.id == id ? state : DevSessionState.tryParse({...state.toJson(), 'id': id}) ?? state;
        await dir.create(recursive: true);
        await AtomicFile.writeJson(_sessionPath, withId.toJson());
        return true;
      }, false);

  /// Çalışma kökündeki tüm oturumlar (en son güncellenen önce). Okunamayan oturum `readable: false` döner.
  Future<List<DevSessionInfo>> listSessions({int limit = 50}) async {
    final out = <DevSessionInfo>[];
    try {
      final root = Directory(p.join(_base.path, rootDirName));
      if (!await root.exists()) return const [];
      await for (final ent in root.list(followLinks: false)) {
        if (ent is! Directory) continue;
        final name = p.basename(ent.path);
        if (sanitizeId(name) != name) continue;
        DevSessionState? st;
        try {
          st = DevSessionState.tryParse(await AtomicFile.readJson(p.join(ent.path, sessionFileName)));
        } catch (_) {
          st = null;
        }
        DateTime modified;
        try {
          modified = (await ent.stat()).modified.toUtc();
        } catch (_) {
          modified = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        }
        out.add(DevSessionInfo(
          id: name,
          status: st?.status ?? DevSessionStatus.hazir,
          branch: st?.branch ?? '',
          startedAt: st?.startedAt,
          updatedAt: st?.updatedAt ?? modified,
          readable: st != null,
        ));
      }
    } catch (_) {
      // Dizin okunamadı: eldeki kadarı döner.
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  // ------------------------------------------------------------ değişiklikler

  Future<Map<String, DevChange>> _loadChangesLocked() async {
    final cached = _changes;
    if (cached != null) return cached;
    final map = <String, DevChange>{};
    final raw = await AtomicFile.readJson(_changesPath);
    final files = raw is Map ? raw['dosyalar'] : null;
    if (files is Map) {
      files.forEach((k, v) {
        if (k is! String) return;
        final c = DevChange.tryParse(k, v);
        if (c != null) map[k] = c;
      });
    }
    return _changes = map;
  }

  /// `changes.json` içeriği (yol -> değişiklik). Okunamazsa boş harita.
  Future<Map<String, DevChange>> loadChanges() => _serial<Map<String, DevChange>>(() async {
        return Map<String, DevChange>.unmodifiable(await _loadChangesLocked());
      }, const {});

  /// Bir dosya değişikliğini kaydeder: ilk özet korunur, son özet [content]'ten güncellenir
  /// (silinmede veya içerik verilmezse son özet temizlenir/aynı kalır), commit sayacı artar.
  /// [commitSha] boşsa önceki değer korunur. Başarıyı döner.
  Future<bool> recordChange(
    String path, {
    required DevChangeStatus status,
    String commitSha = '',
    String? content,
  }) =>
      _serial<bool>(() async {
        final key = _clean(path, 300);
        if (key.isEmpty) return false;
        final map = await _loadChangesLocked();
        final old = map[key];
        final digest = content == null ? null : DevContentDigest.of(content);
        final DevContentDigest? last = status == DevChangeStatus.silindi ? null : (digest ?? old?.last);
        map.remove(key); // en son güncellenen sona
        map[key] = DevChange(
          path: key,
          status: status,
          commitSha: commitSha.isEmpty ? (old?.commitSha ?? '') : _clean(commitSha, 80),
          updatedAt: _now().toUtc(),
          commits: (old?.commits ?? 0) + 1,
          first: old?.first ?? digest,
          last: last,
        );
        while (map.length > maxChangeEntries) {
          map.remove(map.keys.first);
        }
        await dir.create(recursive: true);
        await AtomicFile.writeJson(_changesPath, {
          'v': 1,
          'dosyalar': {for (final e in map.entries) e.key: e.value.toJson()},
        });
        return true;
      }, false);

  // ------------------------------------------------------------ kapanış

  /// Tamponu yazar ve akışı kapatır. Sonraki [append] çağrıları yok sayılır.
  Future<void> close() async {
    if (_closed) return;
    await flush();
    _closed = true;
    _timer?.cancel();
    _timer = null;
    try {
      await _controller.close();
    } catch (_) {}
    await _stateChain;
  }
}
