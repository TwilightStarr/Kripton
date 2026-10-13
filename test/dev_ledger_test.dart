// Görev 4/10: DevLedger (JSONL defter, döndürme, bozuk dosya, ders listesi, sır maskeleme) ve ModelTrust.
// Gerçek ağ yok; gerçek sır yok (sahte anahtarlar çalışma zamanında birleştirilir).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/dev_guard.dart';
import 'package:kripton_ai/application/dev_ledger.dart';
import 'package:kripton_ai/data/project_snapshot.dart';
import 'package:kripton_ai/data/secret_mask.dart';
import 'package:path/path.dart' as p;

DevErrorEntry _e(
  String gate, {
  String model = 'm1',
  String detail = 'ayrıntı',
  String rol = DevRole.fixer,
  String dosya = 'lib/main.dart',
  int ts = 1000,
  int deneme = 1,
}) => DevErrorEntry(ts: ts, rol: rol, modelId: model, kapiKodu: gate, ayrinti: detail, dosya: dosya, deneme: deneme);

String _fakeToken() => 'ghp_${'Q' * 30}';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('devledger_test_');
  });

  tearDown(() {
    SecretMask.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('kayıt ve özetler', () {
    test('statsByGate / statsByModel çoktan aza sıralı sayar', () async {
      final l = DevLedger();
      await l.record(_e('G3', model: 'a'));
      await l.record(_e('G3', model: 'a'));
      await l.record(_e('G3', model: 'b'));
      await l.record(_e('G2', model: 'b'));
      await l.record(_e('G7', model: 'a'));
      expect(l.statsByGate(), {'G3': 3, 'G2': 1, 'G7': 1});
      expect(l.statsByGate().keys.first, 'G3');
      expect(l.statsByModel(), {'a': 3, 'b': 2});
      expect(l.entryCount, 5);
    });

    test('bellek sınırı: en eski kayıtlar atılır', () async {
      final l = DevLedger(maxMemoryEntries: 10);
      for (var i = 0; i < 25; i++) {
        await l.record(_e('G1', ts: i));
      }
      expect(l.entries.length, 10);
      expect(l.entries.first.ts, 15);
      expect(l.entries.last.ts, 24);
    });

    test('recordVerdict her ihlali ayrı kayıt olarak yazar', () async {
      final l = DevLedger(now: () => 42);
      final v = DevGuard.check(
        ProjectSnapshot(name: 'd', text: {'lib/main.dart': 'void main() {}\n'}),
        scope: {'lib/main.dart'},
        rawOutput: '<<<<<<< DOSYA: lib/uydurma.dart\n<<<<<<< ESKİ\nx\n=======\ny\n>>>>>>> YENİ\n',
      );
      expect(v.ok, isFalse);
      await l.recordVerdict(v, rol: DevRole.fixer, modelId: 'fixer-1', deneme: 2);
      expect(l.entries.length, v.violations.length);
      expect(l.entries.first.kapiKodu, DevGate.path);
      expect(l.entries.first.ts, 42);
      expect(l.entries.first.deneme, 2);
      expect(l.entries.first.modelId, 'fixer-1');
      expect(l.statsByGate()[DevGate.path], 1);
    });

    test('recordVerifier: RED düzelticiye, ayrıştırılamama doğrulayıcıya yazılır; ONAY güveni artırır', () async {
      final l = DevLedger();
      await l.recordVerifier(
        parseVerifier('KARAR: RED\n- ilgisiz silme'),
        fixerModelId: 'fix',
        verifierModelId: 'ver',
        dosya: 'lib/a.dart',
      );
      await l.recordVerifier(parseVerifier('bilmiyorum'), fixerModelId: 'fix', verifierModelId: 'ver');
      await l.recordVerifier(parseVerifier('KARAR: ONAY'), fixerModelId: 'fix', verifierModelId: 'ver');
      expect(l.entries.length, 2);
      expect(l.entries[0].kapiKodu, DevGate.verifierRed);
      expect(l.entries[0].modelId, 'fix');
      expect(l.entries[0].rol, DevRole.fixer);
      expect(l.entries[0].ayrinti, 'ilgisiz silme');
      expect(l.entries[1].kapiKodu, DevGate.verifierUnparsable);
      expect(l.entries[1].modelId, 'ver');
      expect(l.entries[1].rol, DevRole.verifier);
      expect(l.trust.samples('fix'), 2); // RED + ONAY
      expect(l.trust.samples('ver'), 1);
    });
  });

  group('sır maskeleme', () {
    test('ayrıntı, model ve dosya alanları maskelenir; bellekte, özetlerde, derste ve diskte sır yoktur', () async {
      final tok = _fakeToken();
      SecretMask.register('zzKayitliDeger-12345678');
      final l = DevLedger(dir: tmp);
      await l.record(
        _e(
          'G8',
          model: 'cloud:groq $tok',
          detail: 'anahtar $tok ve zzKayitliDeger-12345678 sızdı\nikinci satır',
          dosya: 'lib/$tok.dart',
        ),
      );
      await l.flush();
      final e = l.entries.single;
      for (final field in [e.ayrinti, e.modelId, e.dosya, jsonEncode(e.toJson())]) {
        expect(field, isNot(contains(tok)));
        expect(field, isNot(contains('zzKayitliDeger-12345678')));
      }
      expect(e.ayrinti, isNot(contains('\n')));
      expect(l.lessons(), isNot(contains(tok)));
      expect(l.statsByModel().keys.join(), isNot(contains(tok)));
      final disk = File(p.join(tmp.path, 'dev_ledger.jsonl')).readAsStringSync();
      expect(disk, isNot(contains(tok)));
      expect(disk, isNot(contains('zzKayitliDeger-12345678')));
      final trustDisk = File(p.join(tmp.path, 'dev_trust.json')).readAsStringSync();
      expect(trustDisk, isNot(contains(tok)));
    });

    test('uzun ayrıntı kısaltılır', () {
      expect(_e('G1', detail: 'x' * 5000).ayrinti.length, lessThanOrEqualTo(401));
    });
  });

  group('lessons', () {
    test('defter boşken boş metin', () {
      expect(DevLedger().lessons(), '');
    });

    test('en sık kapılar önce gelir, en çok 5 kapı, örnek içerir', () async {
      final l = DevLedger();
      for (var i = 0; i < 6; i++) {
        await l.record(_e('G3', detail: 'eşleşmedi $i'));
      }
      for (var i = 0; i < 4; i++) {
        await l.record(_e('G2', detail: 'kapsam dışı'));
      }
      for (final g in ['G1', 'G4', 'G5', 'G6', 'G7']) {
        await l.record(_e(g));
      }
      final s = l.lessons(maxChars: 2000);
      expect(s, startsWith('ÖNCEKİ HATALARDAN KAÇIN:'));
      final lines = s.split('\n');
      expect(lines.length, 6); // başlık + 5 kapı
      expect(lines[1], startsWith('- G3'));
      expect(lines[1], contains('(6×)'));
      expect(lines[1], contains('Örn: "eşleşmedi 5"'));
      expect(lines[2], startsWith('- G2'));
    });

    test('uzunluk sınırı her maxChars değerinde sağlanır', () async {
      final l = DevLedger();
      for (final g in DevGate.all) {
        for (var i = 0; i < 3; i++) {
          await l.record(_e(g, detail: 'uzun ayrıntı ' * 20));
        }
      }
      var nonEmpty = 0;
      for (var max = 0; max <= 1500; max += 7) {
        final s = l.lessons(maxChars: max);
        expect(s.length, lessThanOrEqualTo(max), reason: 'maxChars=$max');
        if (s.isNotEmpty) {
          nonEmpty++;
          expect(s, startsWith('ÖNCEKİ HATALARDAN KAÇIN:'));
        }
      }
      expect(nonEmpty, greaterThan(50));
      expect(l.lessons().length, lessThanOrEqualTo(600));
    });
  });

  group('kalıcılık, döndürme, bozuk dosya', () {
    test('kaydet → yeni örnekte yükle', () async {
      final a = DevLedger(dir: tmp);
      await a.record(_e('G3', detail: 'bir', ts: 1));
      await a.record(_e('G2', detail: 'iki', ts: 2, dosya: 'lib/x.dart', deneme: 3));
      await a.flush();
      final b = DevLedger(dir: tmp);
      await b.load();
      expect(b.entries.length, 2);
      expect(b.entries.last.kapiKodu, 'G2');
      expect(b.entries.last.dosya, 'lib/x.dart');
      expect(b.entries.last.deneme, 3);
      expect(b.corruptLines, 0);
      expect(b.statsByGate(), {'G3': 1, 'G2': 1});
    });

    test('boyut sınırı aşılınca döndürülür; en yeni kayıtlar korunur', () async {
      final l = DevLedger(dir: tmp, maxFileBytes: 800);
      for (var i = 0; i < 60; i++) {
        await l.record(_e('G1', detail: 'kayıt $i', ts: i));
      }
      await l.flush();
      final main = File(p.join(tmp.path, 'dev_ledger.jsonl'));
      final old = File(p.join(tmp.path, 'dev_ledger.jsonl.1'));
      expect(old.existsSync(), isTrue);
      expect(main.lengthSync(), lessThan(800 + 400));
      expect(old.lengthSync(), lessThan(800 + 400));
      final b = DevLedger(dir: tmp, maxFileBytes: 800);
      await b.load();
      expect(b.entries.last.ts, 59);
      expect(b.entries.length, lessThan(60)); // eski kayıtlar döndürmede düştü
      expect(b.entries.length, greaterThan(5));
      expect(b.corruptLines, 0);
    });

    test('bozuk satırlar atlanır, geçerli kayıtlar kurtarılır, istisna yok', () async {
      final good1 = jsonEncode(_e('G3', ts: 1).toJson());
      final good2 = jsonEncode(_e('G5', ts: 2).toJson());
      final f = File(p.join(tmp.path, 'dev_ledger.jsonl'));
      f.writeAsBytesSync([
        ...utf8.encode('$good1\n'),
        ...utf8.encode('{"ts":1,"kapi":\n'),
        ...[0xff, 0xfe, 0x00, 0x80, 0x0a],
        ...utf8.encode('bu json değil\n'),
        ...utf8.encode('[1,2,3]\n'),
        ...utf8.encode('{"ts":"x","kapi":"G1"}\n'),
        ...utf8.encode('$good2\n'),
        ...utf8.encode('{"ts":3,"kapi":"G2","ayr'), // yarım son satır
      ]);
      final l = DevLedger(dir: tmp);
      await l.load();
      expect(l.entries.map((e) => e.kapiKodu), ['G3', 'G5']);
      expect(l.corruptLines, greaterThanOrEqualTo(5));
      // Bozuk dosyadan sonra da yazılabilir.
      await l.record(_e('G7', ts: 9));
      await l.flush();
      final b = DevLedger(dir: tmp);
      await b.load();
      expect(b.entries.map((e) => e.kapiKodu), contains('G7'));
    });

    test('bozuk güven dosyası varsayılana düşer', () async {
      File(p.join(tmp.path, 'dev_trust.json')).writeAsStringSync('{bozuk');
      final l = DevLedger(dir: tmp);
      await l.load();
      expect(l.trust.demoted(), isEmpty);
    });

    test('yazılamayan dizin: istisna yok, bellek çalışır, writeFailures artar', () async {
      final blocker = File(p.join(tmp.path, 'dosya'))..writeAsStringSync('x');
      final l = DevLedger(dir: Directory(p.join(blocker.path, 'alt')));
      await l.record(_e('G1'));
      await l.flush();
      expect(l.entries.length, 1);
      expect(l.writeFailures, greaterThan(0));
      await l.load(); // yükleme de istisna fırlatmaz
    });

    test('dir verilmezse yalnızca bellekte çalışır', () async {
      final l = DevLedger();
      await l.record(_e('G1'));
      await l.load();
      expect(l.writeFailures, 0);
    });
  });

  group('ModelTrust (EWMA)', () {
    test('en az minSamples gözlemden önce demote önerilmez', () {
      final t = ModelTrust();
      for (var i = 0; i < 4; i++) {
        t.observe('m', rejected: true);
      }
      expect(t.isDemoted('m'), isFalse);
      t.observe('m', rejected: true);
      expect(t.isDemoted('m'), isTrue);
      expect(t.demoted(), {'m'});
    });

    test('histerezis: düzelince geri alınır', () {
      final t = ModelTrust();
      for (var i = 0; i < 6; i++) {
        t.observe('m', rejected: true);
      }
      expect(t.isDemoted('m'), isTrue);
      // rate = 0.8^k: 4 başarıda 0.41 (hâlâ demote), 5 başarıda 0.33 (<0.35 → geri)
      for (var i = 0; i < 4; i++) {
        t.observe('m', rejected: false);
      }
      expect(t.rate('m'), closeTo(0.4096, 0.001));
      expect(t.isDemoted('m'), isTrue);
      t.observe('m', rejected: false);
      expect(t.isDemoted('m'), isFalse);
      expect(t.demoted(), isEmpty);
    });

    test('dengeli sonuçlar demote üretmez; oran 0..1 aralığında', () {
      final t = ModelTrust();
      for (var i = 0; i < 100; i++) {
        t.observe('m', rejected: i.isOdd);
        expect(t.rate('m'), inInclusiveRange(0, 1));
      }
      expect(t.isDemoted('m'), isFalse);
      expect(t.rate('bilinmeyen'), 0);
      expect(t.isDemoted('bilinmeyen'), isFalse);
    });

    test('JSON gidiş-dönüş ve bozuk veriyi yok sayma', () {
      final t = ModelTrust();
      for (var i = 0; i < 8; i++) {
        t.observe('a', rejected: true);
      }
      t.observe('b', rejected: false);
      final u = ModelTrust()..loadJson(jsonDecode(jsonEncode(t.toJson())));
      expect(u.isDemoted('a'), isTrue);
      expect(u.samples('a'), 8);
      expect(u.rate('b'), 0);
      final v = ModelTrust()
        ..loadJson({
          'models': {
            'x': {'r': 'kötü', 'n': 3},
            'y': {'r': 5.0, 'n': 7, 'd': true},
            '': {'r': 0.5, 'n': 1},
            'z': 'yanlış',
          },
        });
      expect(v.rate('x'), 0);
      expect(v.rate('y'), 1.0); // aralığa sıkıştırıldı
      ModelTrust().loadJson('bozuk');
      ModelTrust().loadJson(null);
    });

    test('model sayısı sınırlıdır', () {
      final t = ModelTrust(maxModels: 5);
      for (var i = 0; i < 20; i++) {
        t.observe('m$i', rejected: true);
      }
      expect((t.toJson()['models'] as Map).length, 5);
      expect(t.samples('m0'), 0);
      expect(t.samples('m19'), 1);
    });

    test('defter: güven kalıcıdır (yeniden yüklemede demote korunur)', () async {
      final l = DevLedger(dir: tmp);
      for (var i = 0; i < 6; i++) {
        await l.record(_e('G3', model: 'kotu-model'));
      }
      await l.flush();
      expect(l.trust.isDemoted('kotu-model'), isTrue);
      final b = DevLedger(dir: tmp);
      await b.load();
      expect(b.trust.isDemoted('kotu-model'), isTrue);
      for (var i = 0; i < 6; i++) {
        await b.recordSuccess(modelId: 'kotu-model');
      }
      await b.flush();
      expect(b.trust.isDemoted('kotu-model'), isFalse);
    });
  });
}
