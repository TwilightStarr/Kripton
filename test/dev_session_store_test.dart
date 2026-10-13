// Görev 5/19: DevSessionStore testleri — olay ekleme/tail, toplu yazma, döndürme, bozuk dosya kurtarma,
// kontrol noktası, değişiklik haritası, oturum listesi, akış, kalp atışı seyreltme, sır maskeleme, G/Ç hatası.
// Gerçek ağ yok; gerçek sır yok (sahte belirteçler çalışma zamanında birleştirilir).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/dev_session_store.dart';
import 'package:kripton_ai/data/secret_mask.dart';
import 'package:path/path.dart' as p;

String _fakeToken() => 'ghp_${'Q' * 30}';

DevSessionStore _store(Directory base, String id, {DateTime? at, int maxBytes = 256 * 1024, int keep = 3, Duration? gap}) {
  var clock = at ?? DateTime.utc(2026, 10, 11, 10);
  return DevSessionStore(
    baseDir: base,
    sessionId: id,
    maxEventBytes: maxBytes,
    rotatedKeep: keep,
    flushInterval: const Duration(milliseconds: 20),
    heartbeatMinGap: gap ?? const Duration(seconds: 60),
    now: () => clock = clock.add(const Duration(milliseconds: 1)),
  );
}

DevEvent _ev(String msg, {DateTime? ts, DevEventKind kind = DevEventKind.asama, DevEventLevel level = DevEventLevel.bilgi}) =>
    DevEvent(ts: ts ?? DateTime.utc(2026, 10, 11, 10), kind: kind, level: level, message: msg);

int _idx(DevEvent e) => int.parse(e.message.split(' ')[1]);

void main() {
  late Directory tmp;

  setUp(() {
    SecretMask.clear();
    tmp = Directory.systemTemp.createTempSync('devsession_test_');
  });

  tearDown(() {
    SecretMask.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('DevEvent', () {
    test('JSON gidiş-dönüş; alanlar korunur', () {
      final e = DevEvent(
        ts: DateTime.utc(2026, 10, 11, 10, 30),
        level: DevEventLevel.uyari,
        kind: DevEventKind.ci,
        message: 'CI başarısız',
        files: const ['lib/a.dart', 'lib/a.dart', 'lib/b.dart'],
        sha: 'abc123',
        runUrl: 'https://github.com/o/r/actions/runs/1',
        modelId: 'groq:x',
      );
      expect(e.files, ['lib/a.dart', 'lib/b.dart'], reason: 'yinelenen dosya atılır');
      final back = DevEvent.tryParse(jsonDecode(jsonEncode(e.toJson())));
      expect(back, isNotNull);
      expect(back!.ts, e.ts);
      expect(back.level, DevEventLevel.uyari);
      expect(back.kind, DevEventKind.ci);
      expect(back.message, 'CI başarısız');
      expect(back.files, e.files);
      expect(back.sha, 'abc123');
      expect(back.runUrl, e.runUrl);
      expect(back.modelId, 'groq:x');
    });

    test('bozuk girdi null; bilinmeyen seviye/tür varsayılana düşer', () {
      expect(DevEvent.tryParse(null), isNull);
      expect(DevEvent.tryParse('metin'), isNull);
      expect(DevEvent.tryParse({'mesaj': 'x'}), isNull, reason: 'ts yok');
      expect(DevEvent.tryParse({'ts': 1}), isNull, reason: 'mesaj yok');
      final e = DevEvent.tryParse({'ts': 5, 'mesaj': 'm', 'seviye': '???', 'tur': '???'});
      expect(e!.level, DevEventLevel.bilgi);
      expect(e.kind, DevEventKind.durum);
    });

    test('mesaj kısaltılır, kontrol karakterleri temizlenir', () {
      final e = _ev('${'a' * 5000}\u0000\u0007');
      expect(e.message.length, lessThanOrEqualTo(4001));
      expect(e.message.contains('\u0000'), isFalse);
    });

    test('REDACT: token tüm metin alanlarında maskelenir', () {
      final t = _fakeToken();
      SecretMask.register('kayitli-gizli-anahtar-123456');
      final e = DevEvent(
        kind: DevEventKind.commit,
        message: 'push $t ve kayitli-gizli-anahtar-123456',
        files: ['dosya_$t.dart'],
        sha: t,
        runUrl: 'https://x/y?token=$t',
        modelId: t,
      );
      final all = jsonEncode(e.toJson());
      expect(all.contains(t), isFalse);
      expect(all.contains('kayitli-gizli-anahtar-123456'), isFalse);
      expect(e.message.contains('***'), isTrue);
    });
  });

  group('olay günlüğü', () {
    test('append -> flush -> tail sırayla döner; yeni örnek de okur', () async {
      final s = _store(tmp, 'o1');
      for (var i = 0; i < 5; i++) {
        s.append(_ev('olay $i'));
      }
      await s.flush();
      final t = await s.tail(3);
      expect(t.map(_idx), [2, 3, 4]);
      expect((await s.tail(100)).length, 5);
      expect(await s.tail(0), isEmpty);
      await s.close();
      final s2 = _store(tmp, 'o1');
      expect((await s2.tail(100)).map(_idx), [0, 1, 2, 3, 4]);
      await s2.close();
    });

    test('tail tamponu kendiliğinden yazar (flush gerekmez)', () async {
      final s = _store(tmp, 'o2');
      s.append(_ev('olay 0'));
      expect((await s.tail(10)).length, 1);
      await s.close();
    });

    test('otomatik toplu yazma: zamanlayıcı tamponu diske yazar', () async {
      final s = _store(tmp, 'o3');
      s.append(_ev('olay 0'));
      s.append(_ev('olay 1'));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final f = File(p.join(s.dir.path, DevSessionStore.eventsFileName));
      expect(f.existsSync(), isTrue);
      expect(f.readAsLinesSync().where((l) => l.trim().isNotEmpty).length, 2);
      await s.close();
    });

    test('maxBatch dolunca hemen yazılır', () async {
      final s = DevSessionStore(
        baseDir: tmp,
        sessionId: 'o4',
        maxBatch: 3,
        flushInterval: const Duration(hours: 1),
      );
      for (var i = 0; i < 3; i++) {
        s.append(_ev('olay $i'));
      }
      await s.flush();
      expect((await s.tail(10)).length, 3);
      await s.close();
    });

    test('akış: olaylar diske yazılmadan gelir; close sonrası append yok sayılır', () async {
      final s = _store(tmp, 'o5');
      final got = <DevEvent>[];
      final done = Completer<void>();
      final sub = s.events.listen(got.add, onDone: done.complete);
      s.log(DevEventKind.analiz, 'bir');
      s.log(DevEventKind.yama, 'iki', level: DevEventLevel.uyari);
      await Future<void>.delayed(Duration.zero);
      expect(got.map((e) => e.message), ['bir', 'iki']);
      expect(got[1].level, DevEventLevel.uyari);
      await s.close();
      await done.future.timeout(const Duration(seconds: 2));
      s.append(_ev('kapandıktan sonra'));
      await s.flush();
      expect((await _store(tmp, 'o5').tail(10)).map((e) => e.message), ['bir', 'iki']);
      await sub.cancel();
    });

    test('kalp atışı: akışa hepsi gider, diske seyrek yazılır; tamponda biri diğerini değiştirir', () async {
      final s = _store(tmp, 'o6', gap: const Duration(seconds: 60));
      final t0 = DateTime.utc(2026, 10, 11, 10);
      final got = <DevEvent>[];
      final sub = s.events.listen(got.add);
      for (var i = 0; i < 5; i++) {
        s.append(_ev('kalp ${i}', ts: t0.add(Duration(seconds: 10 * i)), kind: DevEventKind.kalpAtisi));
      }
      s.append(_ev('olay 9', ts: t0.add(const Duration(seconds: 45))));
      await s.flush();
      await Future<void>.delayed(Duration.zero);
      expect(got.length, 6);
      var t = await s.tail(100);
      expect(t.where((e) => e.kind == DevEventKind.kalpAtisi).length, 1);
      expect(t.any((e) => e.message == 'olay 9'), isTrue, reason: 'önemli olaylar seyreltilmez');

      s.append(_ev('kalp x', ts: t0.add(const Duration(seconds: 61)), kind: DevEventKind.kalpAtisi));
      await s.flush();
      t = await s.tail(100);
      expect(t.where((e) => e.kind == DevEventKind.kalpAtisi).length, 2);

      // aralık geçmiş iki kalp atışı arka arkaya tamponda: sonuncusu öncekini değiştirir
      s.append(_ev('kalp y', ts: t0.add(const Duration(seconds: 130)), kind: DevEventKind.kalpAtisi));
      s.append(_ev('kalp z', ts: t0.add(const Duration(seconds: 200)), kind: DevEventKind.kalpAtisi));
      await s.flush();
      t = await s.tail(100);
      final hb = t.where((e) => e.kind == DevEventKind.kalpAtisi).map((e) => e.message).toList();
      expect(hb, ['kalp 0', 'kalp x', 'kalp z']);
      await sub.cancel();
      await s.close();
    });

    test('döndürme: boyut sınırı aşılınca .1/.2 oluşur, rotatedKeep kadar tutulur, en yeni olaylar kalır', () async {
      final s = _store(tmp, 'rot', maxBytes: 700, keep: 2);
      for (var i = 0; i < 40; i++) {
        s.append(_ev('olay $i ${'x' * 40}'));
        await s.flush();
      }
      final main = File(p.join(s.dir.path, DevSessionStore.eventsFileName));
      expect(main.lengthSync(), lessThanOrEqualTo(700));
      expect(File('${main.path}.1').existsSync(), isTrue);
      expect(File('${main.path}.2').existsSync(), isTrue);
      expect(File('${main.path}.3').existsSync(), isFalse, reason: 'rotatedKeep=2');
      final all = await s.tail(1000);
      final idx = all.map(_idx).toList();
      expect(idx.last, 39);
      expect(idx.first, greaterThan(0), reason: 'en eski olaylar düşmüş olmalı');
      for (var i = 1; i < idx.length; i++) {
        expect(idx[i], idx[i - 1] + 1, reason: 'sıra bozulmadan ardışık');
      }
      expect((await s.tail(3)).map(_idx), [37, 38, 39]);
      await s.close();
    });

    test('yeniden başlatma sonrası döndürme sürer', () async {
      var s = _store(tmp, 'rot2', maxBytes: 600, keep: 2);
      for (var i = 0; i < 12; i++) {
        s.append(_ev('olay $i ${'x' * 40}'));
        await s.flush();
      }
      await s.close();
      s = _store(tmp, 'rot2', maxBytes: 600, keep: 2);
      for (var i = 12; i < 24; i++) {
        s.append(_ev('olay $i ${'x' * 40}'));
        await s.flush();
      }
      final idx = (await s.tail(1000)).map(_idx).toList();
      expect(idx.last, 23);
      for (var i = 1; i < idx.length; i++) {
        expect(idx[i], idx[i - 1] + 1);
      }
      await s.close();
    });

    test('bozuk satırlar atlanır; yarım son satır sonraki olayla birleşmez', () async {
      final s = _store(tmp, 'bozuk');
      s.dir.createSync(recursive: true);
      final good1 = jsonEncode(_ev('olay 1').toJson());
      final good2 = jsonEncode(_ev('olay 2').toJson());
      File(p.join(s.dir.path, DevSessionStore.eventsFileName)).writeAsStringSync(
        '$good1\n{"ts": 1, "mesaj": \n\u00ff\u00fe ikili çöp \u0000\n$good2\n{"ts":123,"seviye":"bi',
      );
      var t = await s.tail(10);
      expect(t.map((e) => e.message), ['olay 1', 'olay 2']);
      expect(s.corruptLines, greaterThanOrEqualTo(2));

      s.append(_ev('olay 3'));
      await s.flush();
      t = await s.tail(10);
      expect(t.map((e) => e.message), ['olay 1', 'olay 2', 'olay 3'], reason: 'yarım satır yeni olayı bozmamalı');
      await s.close();
    });

    test('tamamen çöp dosya: tail boş, çökme yok, yeni olay yazılabilir', () async {
      final s = _store(tmp, 'cop');
      s.dir.createSync(recursive: true);
      File(p.join(s.dir.path, DevSessionStore.eventsFileName)).writeAsBytesSync(List<int>.generate(300, (i) => (i * 37) % 256));
      expect(await s.tail(10), isEmpty);
      s.append(_ev('olay 0'));
      expect((await s.tail(10)).map((e) => e.message), ['olay 0']);
      await s.close();
    });

    test('REDACT: diskteki dosyada, tail çıktısında ve akışta token yoktur', () async {
      final t = _fakeToken();
      final s = _store(tmp, 'sir');
      final got = <DevEvent>[];
      final sub = s.events.listen(got.add);
      s.log(DevEventKind.commit, 'push başarısız: $t', files: ['a_$t.dart'], sha: t, modelId: t);
      await s.flush();
      await Future<void>.delayed(Duration.zero);
      final text = File(p.join(s.dir.path, DevSessionStore.eventsFileName)).readAsStringSync();
      expect(text.contains(t), isFalse);
      expect(jsonEncode((await s.tail(5)).map((e) => e.toJson()).toList()).contains(t), isFalse);
      expect(got.single.message.contains(t), isFalse);
      await sub.cancel();
      await s.close();
    });

    test('G/Ç hatası: istisna fırlatılmaz, sayaç artar', () async {
      final blocker = File(p.join(tmp.path, 'blocker'))..writeAsStringSync('x');
      final s = DevSessionStore(baseDir: Directory(blocker.path), sessionId: 'x', flushInterval: const Duration(hours: 1));
      s.log(DevEventKind.durum, 'yazılamayacak');
      await s.flush();
      expect(s.writeFailures, greaterThan(0));
      expect(await s.saveCheckpoint(DevSessionState(id: 'x')), isFalse);
      expect(await s.tail(5), isEmpty);
      expect(await s.loadSession(), isNull);
      expect(await s.listSessions(), isEmpty);
      expect(await s.loadChanges(), isEmpty);
      expect(await s.recordChange('a.dart', status: DevChangeStatus.eklendi), isFalse);
      await s.close();
    });
  });

  group('oturum kimliği', () {
    test('sanitizeId: yol kaçışı ve geçersiz karakterler engellenir', () {
      final id = DevSessionStore.sanitizeId('../evil/..\\x');
      expect(id.contains('..'), isFalse);
      expect(id.contains('/'), isFalse);
      expect(id.contains('\\'), isFalse);
      expect(id.startsWith('.'), isFalse);
      expect(DevSessionStore.sanitizeId(''), 'oturum');
      expect(DevSessionStore.sanitizeId('   '), 'oturum');
      expect(DevSessionStore.sanitizeId('a' * 200).length, 80);
      expect(DevSessionStore.sanitizeId('dev-2026_10.11'), 'dev-2026_10.11');
    });

    test('dizin her zaman dev_sessions altındadır', () {
      final s = _store(tmp, '../../kacis');
      expect(p.isWithin(p.join(tmp.path, DevSessionStore.rootDirName), s.dir.path), isTrue);
    });
  });

  group('kontrol noktası (session.json)', () {
    DevSessionState state(String note, {String id = 's1'}) => DevSessionState(
          id: id,
          status: DevSessionStatus.calisiyor,
          repo: 'o/r',
          branch: 'kripton/dev-1',
          baseBranch: 'main',
          headSha: 'abc123',
          startedAt: DateTime.utc(2026, 10, 11, 9),
          counters: const {'deneme': 3, 'commit': 2},
          blockedFiles: const ['lib/a.dart'],
          lastSignatures: const ['analyze:lib/a.dart:1'],
          models: const {'analist': 'gemini:x', 'düzeltici': 'groq:y'},
          phase: 'ci',
          note: note,
        );

    test('kaydet -> yükle gidiş-dönüş', () async {
      final s = _store(tmp, 's1');
      expect(await s.loadSession(), isNull, reason: 'henüz yok');
      expect(await s.saveCheckpoint(state('A')), isTrue);
      final back = (await _store(tmp, 's1').loadSession())!;
      expect(back.id, 's1');
      expect(back.status, DevSessionStatus.calisiyor);
      expect(back.repo, 'o/r');
      expect(back.branch, 'kripton/dev-1');
      expect(back.baseBranch, 'main');
      expect(back.headSha, 'abc123');
      expect(back.startedAt, DateTime.utc(2026, 10, 11, 9));
      expect(back.updatedAt.isAfter(back.startedAt), isTrue, reason: 'saveCheckpoint updatedAt günceller');
      expect(back.counters, {'deneme': 3, 'commit': 2});
      expect(back.blockedFiles, ['lib/a.dart']);
      expect(back.lastSignatures, ['analyze:lib/a.dart:1']);
      expect(back.models['analist'], 'gemini:x');
      expect(back.phase, 'ci');
      expect(back.note, 'A');
    });

    test('incremented/copyWith', () {
      final a = state('A');
      final b = a.incremented('deneme').incremented('yeni', 5);
      expect(b.counters['deneme'], 4);
      expect(b.counters['yeni'], 5);
      expect(a.counters['deneme'], 3, reason: 'özgün nesne değişmez');
      expect(b.copyWith(status: DevSessionStatus.bekliyor).status, DevSessionStatus.bekliyor);
    });

    test('REDACT: serbest metin alanlarında token saklanmaz', () async {
      final t = _fakeToken();
      final s = _store(tmp, 's1');
      await s.saveCheckpoint(state('not $t'));
      final raw = File(p.join(s.dir.path, DevSessionStore.sessionFileName)).readAsStringSync();
      expect(raw.contains(t), isFalse);
    });

    test('bozuk ana dosya: yedekten kurtarılır (çökme yok)', () async {
      final s = _store(tmp, 's1');
      await s.saveCheckpoint(state('A'));
      await s.saveCheckpoint(state('B'));
      final main = File(p.join(s.dir.path, DevSessionStore.sessionFileName));
      main.writeAsStringSync('{{{ yarım kalmış');
      final back = await _store(tmp, 's1').loadSession();
      expect(back, isNotNull);
      expect(back!.note, 'A', reason: 'son sağlam yedek (önceki sürüm)');
    });

    test('yedeksiz bozuk dosya: null döner, istisna yok; sonra yeniden kaydedilebilir', () async {
      final s = _store(tmp, 's2');
      s.dir.createSync(recursive: true);
      File(p.join(s.dir.path, DevSessionStore.sessionFileName)).writeAsStringSync('çöp çöp');
      expect(await s.loadSession(), isNull);
      expect(await s.saveCheckpoint(state('Z', id: 's2')), isTrue);
      expect((await s.loadSession())!.note, 'Z');
    });

    test('tür hatalı alanlar varsayılana düşer; kimliksiz kayıt null', () {
      final st = DevSessionState.tryParse({
        'id': 'q',
        'durum': 'bilinmeyen',
        'sayaclar': {'a': 'metin', 'b': 2},
        'blokluDosyalar': ['x', 5, null],
        'modeller': {'r': 1, 's': 'm'},
      })!;
      expect(st.status, DevSessionStatus.hazir);
      expect(st.counters, {'b': 2});
      expect(st.blockedFiles, ['x']);
      expect(st.models, {'s': 'm'});
      expect(DevSessionState.tryParse({'durum': 'hazir'}), isNull);
      expect(DevSessionState.tryParse([1, 2]), isNull);
    });

    test('eşzamanlı kayıtlar bozulmaz: sonuç geçerli ve son yazılan', () async {
      final s = _store(tmp, 's3');
      var cur = DevSessionState(id: 's3');
      final futures = <Future<bool>>[];
      for (var i = 0; i < 10; i++) {
        cur = cur.incremented('n');
        futures.add(s.saveCheckpoint(cur));
      }
      expect((await Future.wait(futures)).every((x) => x), isTrue);
      expect((await s.loadSession())!.counters['n'], 10);
    });

    test('sınırlar: engelli dosya ve imza listeleri kırpılır', () {
      final st = DevSessionState(
        id: 'k',
        blockedFiles: [for (var i = 0; i < 500; i++) 'lib/f$i.dart'],
        lastSignatures: [for (var i = 0; i < 100; i++) 'sig$i'],
      );
      expect(st.blockedFiles.length, 200);
      expect(st.blockedFiles.last, 'lib/f499.dart', reason: 'en yeniler korunur');
      expect(st.lastSignatures.length, 20);
    });
  });

  group('oturum listesi', () {
    test('en son güncellenen önce; bozuk oturum readable=false; geçersiz dizin adları atlanır', () async {
      final a = _store(tmp, 'a', at: DateTime.utc(2020, 1, 1));
      final b = _store(tmp, 'b', at: DateTime.utc(2021, 1, 1));
      await a.saveCheckpoint(DevSessionState(id: 'a', status: DevSessionStatus.tamamlandi, branch: 'kripton/dev-a'));
      await b.saveCheckpoint(DevSessionState(id: 'b', status: DevSessionStatus.calisiyor, branch: 'kripton/dev-b'));
      final c = _store(tmp, 'c');
      c.dir.createSync(recursive: true);
      File(p.join(c.dir.path, DevSessionStore.sessionFileName)).writeAsStringSync('çöp');
      Directory(p.join(tmp.path, DevSessionStore.rootDirName, 'bad name')).createSync(recursive: true);
      File(p.join(tmp.path, DevSessionStore.rootDirName, 'dosya.txt')).writeAsStringSync('x');

      final list = await a.listSessions();
      final ids = list.map((e) => e.id).toList();
      expect(ids.toSet(), {'a', 'b', 'c'});
      expect(ids.indexOf('b'), lessThan(ids.indexOf('a')));
      final byId = {for (final e in list) e.id: e};
      expect(byId['a']!.status, DevSessionStatus.tamamlandi);
      expect(byId['a']!.branch, 'kripton/dev-a');
      expect(byId['a']!.readable, isTrue);
      expect(byId['b']!.status, DevSessionStatus.calisiyor);
      expect(byId['c']!.readable, isFalse);
      expect((await a.listSessions(limit: 1)).length, 1);
    });

    test('hiç oturum yoksa boş liste', () async {
      expect(await _store(tmp, 'x').listSessions(), isEmpty);
    });
  });

  group('değişiklikler (changes.json)', () {
    test('ilk özet korunur, son özet güncellenir, commit sayacı artar, silinmede son özet yok', () async {
      final s = _store(tmp, 'ch');
      expect(await s.recordChange('lib/a.dart', status: DevChangeStatus.eklendi, commitSha: 'sha1', content: 'void main() {}\n'), isTrue);
      expect(
        await s.recordChange(
          'lib/a.dart',
          status: DevChangeStatus.degistirildi,
          commitSha: 'sha2',
          content: 'void main() {\n  print(1);\n}\n',
        ),
        isTrue,
      );
      var m = await s.loadChanges();
      var c = m['lib/a.dart']!;
      expect(c.status, DevChangeStatus.degistirildi);
      expect(c.commitSha, 'sha2');
      expect(c.commits, 2);
      expect(c.first!.length, 15);
      expect(c.first!.lines, 1);
      expect(c.last!.lines, 3);
      expect(c.first!.hash, hasLength(16));
      expect(c.first!.hash, isNot(c.last!.hash));

      await s.recordChange('lib/a.dart', status: DevChangeStatus.silindi);
      m = await s.loadChanges();
      c = m['lib/a.dart']!;
      expect(c.status, DevChangeStatus.silindi);
      expect(c.last, isNull);
      expect(c.first, isNotNull);
      expect(c.commitSha, 'sha2', reason: 'sha verilmezse önceki korunur');
      expect(c.commits, 3);
    });

    test('tam içerik saklanmaz; önizleme kısadır ve maskelenir', () async {
      final t = _fakeToken();
      final s = _store(tmp, 'ch2');
      await s.recordChange('lib/b.dart', status: DevChangeStatus.eklendi, content: 'const k = "$t";\n${'x' * 500}UNIQUEMARKER');
      final raw = File(p.join(s.dir.path, DevSessionStore.changesFileName)).readAsStringSync();
      expect(raw.contains('UNIQUEMARKER'), isFalse);
      expect(raw.contains(t), isFalse);
      final c = (await s.loadChanges())['lib/b.dart']!;
      expect(c.first!.preview.length, lessThanOrEqualTo(121));
      expect(c.first!.length, greaterThan(500));
    });

    test('yeniden başlatma: diskten okunur', () async {
      final s = _store(tmp, 'ch3');
      await s.recordChange('a.dart', status: DevChangeStatus.eklendi, commitSha: 's1', content: 'a');
      await s.recordChange('b.dart', status: DevChangeStatus.geriAlindi, commitSha: 's2');
      final m = await _store(tmp, 'ch3').loadChanges();
      expect(m.keys.toSet(), {'a.dart', 'b.dart'});
      expect(m['b.dart']!.status, DevChangeStatus.geriAlindi);
      expect(m['b.dart']!.last, isNull);
    });

    test('maxChangeEntries aşılınca en eski güncellenen düşer', () async {
      final s = DevSessionStore(baseDir: tmp, sessionId: 'ch4', maxChangeEntries: 3);
      for (var i = 0; i < 5; i++) {
        await s.recordChange('f$i.dart', status: DevChangeStatus.eklendi, content: 'x$i');
      }
      final m = await s.loadChanges();
      expect(m.keys.toList(), ['f2.dart', 'f3.dart', 'f4.dart']);
    });

    test('bozuk changes.json: boş harita, çökme yok, yeni kayıt yazılabilir', () async {
      final s = _store(tmp, 'ch5');
      s.dir.createSync(recursive: true);
      File(p.join(s.dir.path, DevSessionStore.changesFileName)).writeAsStringSync('}}}');
      expect(await s.loadChanges(), isEmpty);
      expect(await s.recordChange('a.dart', status: DevChangeStatus.eklendi, content: 'a'), isTrue);
      expect((await _store(tmp, 'ch5').loadChanges()).keys, ['a.dart']);
    });

    test('boş yol reddedilir', () async {
      final s = _store(tmp, 'ch6');
      expect(await s.recordChange('   ', status: DevChangeStatus.eklendi), isFalse);
    });

    test('DevContentDigest: boş içerik 0 satır; son satırsız metin doğru sayılır', () {
      expect(DevContentDigest.of('').lines, 0);
      expect(DevContentDigest.of('a\nb').lines, 2);
      expect(DevContentDigest.of('a\nb\n').lines, 2);
      expect(DevContentDigest.of('aynı').hash, DevContentDigest.of('aynı').hash);
    });
  });
}
