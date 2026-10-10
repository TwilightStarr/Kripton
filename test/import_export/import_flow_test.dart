// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/storage/quanta_database.dart';
import 'package:quanta/features/vault/data/drift_vault_repository.dart';
import 'package:quanta/core/crypto/crypto_exceptions.dart';
import 'package:quanta/core/crypto/vault_service.dart';
import 'package:quanta/core/security/secret_bytes.dart';
import 'package:quanta/features/import_export/csv_codec.dart';
import 'package:quanta/features/import_export/import_service.dart';
import 'package:quanta/features/import_export/importers.dart';
import 'package:quanta/features/import_export/plain_export.dart';
import 'package:quanta/features/vault/domain/item_data.dart';
import 'package:quanta/features/vault/domain/vault_item.dart';
import 'package:quanta/features/vault/domain/vault_records.dart';

import '../helpers.dart';
import '../vault/vault_test_helpers.dart';

const chromeCsv = 'name,url,username,password\n'
    'a.example,https://a.example,ali,pw1\n'
    'b.example,https://b.example,veli,pw2\n'
    'a.example,https://a.example,ali,pw1-dup\n';

void main() {
  late TestVault v;
  late Directory tmp;
  setUp(() async {
    v = await openTestVault();
    tmp = Directory.systemTemp.createTempSync('quanta_imp');
  });
  tearDown(() async {
    await v.dispose();
    tmp.deleteSync(recursive: true);
  });

  ImportFlow flowFor(String csv, {File? file}) => ImportFlow(
      service: ImportService(v.repo), source: ImportSource.chromeCsv, content: csv, sourceFile: file);

  group('çakışma çözümü', () {
    test('dosya içi yinelenenler de çakışma sayılır; skip', () async {
      final f = flowFor(chromeCsv);
      final pre = await f.preview();
      expect(pre.total, 3);
      expect(pre.conflicts, 1);
      final r = await f.apply(ConflictPolicy.skip);
      expect([r.created, r.skipped], [2, 1]);
      expect((await v.repo.list()).length, 2);
    });

    test('overwrite: aynı kayıt güncellenir, geçmiş tutulur', () async {
      final first = flowFor('name,url,username,password\na.example,https://a.example,ali,eski\n');
      await first.preview();
      await first.apply(ConflictPolicy.skip);
      final f = flowFor('name,url,username,password\na.example,https://a.example,ali,yeni\n');
      await f.preview();
      final r = await f.apply(ConflictPolicy.overwrite);
      expect(r.overwritten, 1);
      final all = await v.repo.list();
      expect(all.length, 1);
      final item = (await v.repo.read(all.single.id))!;
      expect((item.data as LoginData).password, 'yeni');
      expect((await v.repo.passwordHistory(item.id)).single.password, 'eski');
    });

    test('duplicate: kopya oluşturur', () async {
      await v.repo.create(const ItemDraft(
          title: 'a.example',
          data: LoginData(username: 'ali', password: 'x', urls: ['https://a.example'])));
      final f = flowFor('name,url,username,password\na.example,https://a.example,ali,pw\n');
      await f.preview();
      final r = await f.apply(ConflictPolicy.duplicate);
      expect(r.duplicated, 1);
      expect((await v.repo.list()).map((e) => e.title), containsAll(['a.example', 'a.example (kopya)']));
    });

    test('Türkçe büyük/küçük harf farkı aynı kayıt sayılır', () async {
      await v.repo.create(const ItemDraft(title: 'IŞIK', data: LoginData(username: 'a', password: 'x')));
      final f = flowFor('name,url,username,password\nışık,,a,y\n');
      expect((await f.preview()).conflicts, 1);
    });
  });

  group('düz dosya uyarı akışı', () {
    test('sıra zorunlu: önce preview, sonra apply, sonra karar', () async {
      final f = flowFor(chromeCsv);
      await expectLater(f.apply(ConflictPolicy.skip), throwsStateError);
      expect(() => f.shredSource(), throwsStateError);
      await f.preview();
      await f.apply(ConflictPolicy.skip);
      expect(f.stage, ImportStage.applied); // karar verilmeden bitmedi
      expect(() => f.keepSourceAcknowledged(acknowledged: false), throwsStateError);
      f.keepSourceAcknowledged(acknowledged: true);
      expect(f.stage, ImportStage.finished);
    });

    test('uyarı metni dosya adını ve silme adımlarını içerir', () {
      final adv = flowFor('a', file: File('${tmp.path}/export.csv')).advisory;
      expect(adv.steps.first, contains('export.csv'));
      expect(adv.steps.length, greaterThanOrEqualTo(3));
    });

    test('dosyayı ezip siler', () async {
      final file = File('${tmp.path}/export.csv')..writeAsStringSync(chromeCsv);
      final f = await ImportFlow.fromFile(ImportService(v.repo), ImportSource.chromeCsv, file);
      await f.preview();
      await f.apply(ConflictPolicy.skip);
      final res = await f.shredSource();
      expect(res.deleted, isTrue);
      expect(file.existsSync(), isFalse);
      expect(f.stage, ImportStage.finished);
    });

    test('shredder: içerik silmeden önce ezilir', () async {
      final file = File('${tmp.path}/s.txt')..writeAsStringSync('GIZLI-PAROLA' * 100);
      final raf = file.openSync();
      raf.closeSync();
      await PlaintextShredder().shred(file);
      expect(file.existsSync(), isFalse);
    });
  });

  group('düz CSV dışa aktarım', () {
    late VaultService vs;
    late CreatedVault created;
    late PlainExportService svc;

    UnlockCredentials creds(String pw) => UnlockCredentials(
        password: sb(pw), secretKey: SecretBytes.copyOf(created.secretKey.copyBytes()));

    setUp(() async {
      vs = makeService();
      created = await vs.createVault(password: sb(goodPassword), params: testKdf, withRecovery: false);
      svc = PlainExportService(vs);
    });

    Future<TestVault> vaultWith(CreatedVault c) async {
      final db = QuantaDatabase(NativeDatabase.memory());
      final repo = await DriftVaultRepository.open(db: db, session: c.session, clock: FakeClock().call);
      return TestVault(db, c.session, repo, FakeClock());
    }

    test('risk onayı olmadan reddedilir', () async {
      await expectLater(
          svc.authorize(acknowledgedRisk: false, header: created.header, credentials: creds(goodPassword), currentSession: created.session),
          throwsA(isA<QuantaCryptoException>()));
    });

    test('yanlış ana parola reddedilir', () async {
      await expectLater(
          svc.authorize(acknowledgedRisk: true, header: created.header, credentials: creds('yanlis-parola'), currentSession: created.session),
          throwsA(isA<QuantaCryptoException>()));
    });

    test('yetki tek kullanımlık; CSV doğru içerik; süre dolunca geçersiz', () async {
      final tv = await vaultWith(created);
      await tv.repo.create(const ItemDraft(
          title: 'Site, "özel"', notes: 'n\n2',
          data: LoginData(username: 'ali', password: 'p,w', urls: ['https://a.example'])));
      await tv.repo.create(const ItemDraft(title: 'Silinecek', data: NoteData(body: 'x')));
      final nId = (await tv.repo.list()).firstWhere((e) => e.title == 'Silinecek').id;
      await tv.repo.trash(nId);

      final auth = await svc.authorize(
          acknowledgedRisk: true, header: created.header, credentials: creds(goodPassword), currentSession: created.session);
      final out = await svc.exportCsv(authorization: auth, repository: tv.repo);
      expect(out.itemCount, 1); // çöptekiler hariç
      final rows = CsvCodec.parse(utf8.decode(out.bytes));
      expect(rows.first, PlainExportService.columns);
      expect(rows[1][1], 'Site, "özel"');
      expect(rows[1][7], 'p,w');
      expect(rows[1][9], 'n\n2');
      expect(out.advisory.steps, isNotEmpty);
      await expectLater(svc.exportCsv(authorization: auth, repository: tv.repo),
          throwsA(isA<QuantaCryptoException>()));

      final clock = FakeClock();
      final short = PlainExportService(vs, clock: clock.call, validFor: const Duration(seconds: 1));
      final a2 = await short.authorize(
          acknowledgedRisk: true, header: created.header, credentials: creds(goodPassword), currentSession: created.session);
      clock.advance(const Duration(seconds: 5));
      await expectLater(short.exportCsv(authorization: a2, repository: tv.repo),
          throwsA(isA<QuantaCryptoException>()));
      await tv.repo.close();
      await tv.db.close();
    });

    test('başka kasanın oturumuyla yetki alınamaz', () async {
      final other = await vs.createVault(password: sb(goodPassword), params: testKdf, withRecovery: false);
      await expectLater(
          svc.authorize(acknowledgedRisk: true, header: created.header, credentials: creds(goodPassword), currentSession: other.session),
          throwsA(isA<QuantaCryptoException>()));
      other.session.dispose();
    });
  });
}
