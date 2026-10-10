// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/storage/storage_exceptions.dart';
import 'package:quanta/features/vault/data/drift_vault_repository.dart';
import 'package:quanta/features/vault/domain/item_data.dart';
import 'package:quanta/features/vault/domain/item_filter.dart';
import 'package:quanta/features/vault/domain/item_kind.dart';
import 'package:quanta/features/vault/domain/vault_item.dart';
import 'package:quanta/features/vault/domain/vault_records.dart';
import 'package:quanta/features/vault/domain/vault_repository.dart';

import 'vault_test_helpers.dart';

Matcher storageFail(StorageFailure k) => throwsA(
    isA<QuantaStorageException>().having((e) => e.kind, 'kind', k));

void main() {
  late TestVault v;
  setUp(() async => v = await openTestVault());
  tearDown(() => v.dispose());

  group('CRUD', () {
    test('create/read tüm türler gidiş-dönüş', () async {
      final drafts = <ItemDraft>[
        loginDraft('site'),
        const ItemDraft(title: 'Kart', data: CardData(holder: 'ALI', number: '4111111111111111', expiryMonth: 12, expiryYear: 2030, cvv: '123', pin: '9999')),
        const ItemDraft(title: 'Not', data: NoteData(body: 'a\nb')),
        const ItemDraft(title: 'Ev', data: WifiData(ssid: 'EvAg', password: 'x', security: WifiSecurity.wpa3, hidden: true)),
        ItemDraft(title: 'Kimlik', data: IdentityData(firstName: 'Ali', lastName: 'Veli', nationalId: '10000000146', birthDate: DateTime(1990, 5, 17))),
        const ItemDraft(title: 'API', data: ApiKeyData(key: 'k1\nk2', secret: 's', endpoint: 'https://api.x')),
        const ItemDraft(title: 'SSH', data: SshKeyData(privateKey: '-----BEGIN-----\nabc\n-----END-----', publicKey: 'ssh-ed25519 AAA', passphrase: 'pp')),
        const ItemDraft(title: 'Özel', data: CustomData(), customFields: [CustomField('a', 'b'), CustomField('gizli', 'c', CustomFieldType.hidden)]),
      ];
      for (final d in drafts) {
        final c = await v.repo.create(d);
        final r = (await v.repo.read(c.id))!;
        expect(r.kind, d.kind);
        expect(r.title, d.title);
        expect(r.data.toJson(), d.data.toJson());
        expect(r.customFields, d.customFields);
      }
    });

    test('ortak alanlar: kategori, favori, etiket normalizasyonu, renk', () async {
      final c = await v.repo.create(const ItemDraft(
          title: 'x',
          data: NoteData(body: 'b'),
          category: ' Banka ',
          isFavorite: true,
          colorValue: 0xFF112233,
          tags: ['İş', ' İş ', '', 'Ev']));
      final r = (await v.repo.read(c.id))!;
      expect(r.category, 'Banka');
      expect(r.isFavorite, isTrue);
      expect(r.colorValue, 0xFF112233);
      // normalizeTags: kırpar, boşları atar, büyük/küçük harf duyarsız tekilleştirir.
      expect(r.tags, ['İş', 'Ev']);
    });

    test('update: zaman damgaları ve değişmezler', () async {
      final c = await v.repo.create(loginDraft('a'));
      v.clock.advance(const Duration(hours: 1));
      final u = await v.repo.update(c.copyWith(title: 'b', createdAt: DateTime(1999)));
      expect(u.title, 'b');
      expect(u.createdAt, c.createdAt); // çağıranın değeri yok sayılır
      expect(u.updatedAt.isAfter(c.updatedAt), isTrue);
      expect((await v.repo.read(c.id))!.title, 'b');
    });

    test('update: tür değiştirilemez, olmayan kayıt notFound', () async {
      final c = await v.repo.create(loginDraft('a'));
      await expectLater(
          v.repo.update(c.copyWith(data: const NoteData(body: 'x'))),
          storageFail(StorageFailure.invalidInput));
      final ghost = c.copyWith();
      await v.repo.delete(c.id);
      await expectLater(v.repo.update(ghost), storageFail(StorageFailure.notFound));
    });

    test('delete idempotent; read null döner', () async {
      final c = await v.repo.create(loginDraft('a'));
      await v.repo.delete(c.id);
      await v.repo.delete(c.id);
      expect(await v.repo.read(c.id), isNull);
      expect(await v.repo.list(), isEmpty);
    });

    test('blob\'lar şifreli: DB\'de düz metin yok', () async {
      await v.repo.create(loginDraft('benzersizbaslik', pw: 'cok-gizli-parola-xyz'));
      final rows = await v.db.query('SELECT summary_blob, payload_blob FROM items');
      for (final col in ['summary_blob', 'payload_blob']) {
        final s = String.fromCharCodes(rows.single.read<Uint8List>(col));
        expect(s.contains('benzersizbaslik'), isFalse);
        expect(s.contains('cok-gizli-parola-xyz'), isFalse);
      }
    });

    test('blob başka kayda taşınırsa (AAD) açılmaz', () async {
      final a = await v.repo.create(loginDraft('a'));
      final b = await v.repo.create(loginDraft('b'));
      final blobA = (await v.db.query('SELECT payload_blob FROM items WHERE id=?', [a.id]))
          .single.read<Uint8List>('payload_blob');
      await v.db.exec('UPDATE items SET payload_blob = ? WHERE id = ?', [blobA, b.id]);
      await expectLater(v.repo.read(b.id), throwsA(anything));
    });
  });

  group('parola geçmişi', () {
    test('her değişimde eski parola saklanır, en fazla 10', () async {
      var item = await v.repo.create(loginDraft('a', pw: 'p0'));
      for (var i = 1; i <= 12; i++) {
        v.clock.advance(const Duration(minutes: 1));
        item = await v.repo.update(
            item.copyWith(data: LoginData(username: 'ali', password: 'p$i')));
      }
      final h = await v.repo.passwordHistory(item.id);
      expect(h.length, 10);
      expect(h.first.password, 'p11'); // en yeni emekli parola
      expect(h.last.password, 'p2');
      expect(h.map((e) => e.password), isNot(contains('p0')));
    });

    test('parola değişmezse geçmiş eklenmez', () async {
      final item = await v.repo.create(loginDraft('a', pw: 'p0'));
      await v.repo.update(item.copyWith(title: 'yeni'));
      expect(await v.repo.passwordHistory(item.id), isEmpty);
    });

    test('silinen kaydın geçmişi de silinir', () async {
      var item = await v.repo.create(loginDraft('a', pw: 'p0'));
      item = await v.repo.update(item.copyWith(data: const LoginData(password: 'p1')));
      await v.repo.delete(item.id);
      expect(await v.db.query('SELECT 1 FROM password_history'), isEmpty);
    });
  });

  group('çöp kutusu', () {
    test('trash/restore', () async {
      final c = await v.repo.create(loginDraft('a'));
      await v.repo.trash(c.id);
      expect(await v.repo.list(), isEmpty);
      expect((await v.repo.list(const ItemFilter(trash: TrashScope.trashed))).length, 1);
      expect((await v.repo.read(c.id))!.isTrashed, isTrue);
      await v.repo.restore(c.id);
      expect((await v.repo.list()).length, 1);
      expect((await v.repo.read(c.id))!.isTrashed, isFalse);
    });

    test('30 gün sonra kalıcı silinir, öncesinde silinmez', () async {
      final old = await v.repo.create(loginDraft('eski'));
      final fresh = await v.repo.create(loginDraft('yeni'));
      await v.repo.trash(old.id);
      v.clock.advance(const Duration(days: 20));
      await v.repo.trash(fresh.id);
      v.clock.advance(const Duration(days: 11)); // eski: 31 gün, yeni: 11 gün
      expect(await v.repo.purgeExpiredTrash(), 1);
      expect(await v.repo.read(old.id), isNull);
      expect(await v.repo.read(fresh.id), isNotNull);
    });

    test('emptyTrash yalnızca çöptekileri siler', () async {
      final a = await v.repo.create(loginDraft('a'));
      await v.repo.create(loginDraft('b'));
      await v.repo.trash(a.id);
      expect(await v.repo.emptyTrash(), 1);
      expect((await v.repo.list()).length, 1);
    });

    test('update çöp durumunu ve son kullanımı bozmaz', () async {
      final c = await v.repo.create(loginDraft('a'));
      await v.repo.markUsed(c.id);
      await v.repo.trash(c.id);
      final u = await v.repo.update((await v.repo.read(c.id))!.copyWith(title: 'z', trashedAt: null, lastUsedAt: null));
      expect(u.isTrashed, isTrue);
      expect(u.lastUsedAt, isNotNull);
    });
  });

  group('ekler', () {
    test('ekle/oku/listele/sil ve 1 MB sınırı', () async {
      final c = await v.repo.create(loginDraft('a'));
      final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final info = await v.repo.addAttachment(c.id, 'kod.png', data);
      expect((await v.repo.listAttachments(c.id)).single.name, 'kod.png');
      final back = (await v.repo.readAttachment(info.id))!;
      expect(back.bytes, data);
      await expectLater(
          v.repo.addAttachment(c.id, 'buyuk', Uint8List(1024 * 1024 + 1)),
          storageFail(StorageFailure.limitExceeded));
      await v.repo.addAttachment(c.id, 'tam', Uint8List(1024 * 1024)); // sınırda OK
      await v.repo.deleteAttachment(info.id);
      expect((await v.repo.listAttachments(c.id)).length, 1);
    });

    test('kayıt silinince ekler de gider', () async {
      final c = await v.repo.create(loginDraft('a'));
      await v.repo.addAttachment(c.id, 'x', Uint8List(10));
      await v.repo.delete(c.id);
      expect(await v.db.query('SELECT 1 FROM attachments'), isEmpty);
    });
  });

  group('arama ve liste', () {
    test('başlık, kullanıcı adı, URL, etiket; Türkçe katlama; kilit sonrası boş', () async {
      await v.repo.create(const ItemDraft(
          title: 'Işık Bankası',
          tags: ['finans'],
          data: LoginData(username: 'şükrü', password: 'x', urls: ['https://www.isikbank.com.tr'])));
      await v.repo.create(loginDraft('github', user: 'octo', urls: ['https://github.com']));
      expect((await v.repo.search('isik')).single.title, 'Işık Bankası');
      expect((await v.repo.search('SUKRU')).length, 1);
      expect((await v.repo.search('isikbank.com')).length, 1);
      expect((await v.repo.search('finans')).length, 1);
      expect((await v.repo.search('octo git')).length, 1);
      expect(await v.repo.search('yokböyle'), isEmpty);
      expect((await v.repo.search('')).length, 2);
    });

    test('arama sonucu parola içermez', () async {
      await v.repo.create(loginDraft('a', pw: 'gizli-xyz'));
      expect(await v.repo.search('gizli-xyz'), isEmpty);
    });

    test('filtre ve sıralama', () async {
      final a = await v.repo.create(const ItemDraft(title: 'b', category: 'X', data: NoteData(body: 'z')));
      v.clock.advance(const Duration(minutes: 1));
      await v.repo.create(const ItemDraft(title: 'a', category: 'Y', data: LoginData(password: 'p')));
      await v.repo.setFavorite(a.id, true);
      expect((await v.repo.list()).map((e) => e.title), ['a', 'b']);
      expect((await v.repo.list(const ItemFilter(sort: ItemSort.updatedDesc))).first.title, 'a');
      expect((await v.repo.list(const ItemFilter(favoritesOnly: true))).single.title, 'b');
      expect((await v.repo.list(const ItemFilter(category: 'y'))).single.title, 'a');
      expect((await v.repo.list(const ItemFilter(kinds: {ItemKind.login}))).single.title, 'a');
    });

    test('kör indeks: kapalıyken unsupported; açıkken tam eşleşme', () async {
      final a = await v.repo.create(loginDraft('site', user: 'Ali', urls: ['https://www.example.com/x']));
      await expectLater(v.repo.findByExact(BlindField.username, 'ali'),
          storageFail(StorageFailure.unsupported));
      await v.repo.setBlindIndexEnabled(true);
      expect((await v.repo.findByExact(BlindField.username, 'ALI')).single.id, a.id);
      expect((await v.repo.findByExact(BlindField.host, 'https://example.com')).single.id, a.id);
      expect(await v.repo.findByExact(BlindField.username, 'al'), isEmpty);
      final tokens = await v.db.query('SELECT token FROM blind_index');
      expect(tokens, isNotEmpty);
      // düz metin yok
      expect(String.fromCharCodes(tokens.first.read<Uint8List>('token')).contains('ali'), isFalse);
      await v.repo.update(a.copyWith(data: const LoginData(username: 'veli', password: 'pw-1', urls: ['https://x.example'])));
      expect(await v.repo.findByExact(BlindField.username, 'ali'), isEmpty);
      expect((await v.repo.findByExact(BlindField.username, 'veli')).length, 1);
      await v.repo.setBlindIndexEnabled(false);
      expect(await v.db.query('SELECT 1 FROM blind_index'), isEmpty);
    });
  });

  group('reaktif akışlar', () {
    test('watchList ilk değeri ve değişiklikleri yayınlar', () async {
      final events = <int>[];
      final sub = v.repo.watchList().listen((l) => events.add(l.length));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await v.repo.create(loginDraft('a'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final b = await v.repo.create(loginDraft('b'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await v.repo.delete(b.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(events.first, 0);
      expect(events.last, 1);
      expect(events, contains(2));
    });

    test('watch(id) güncel kaydı verir', () async {
      final c = await v.repo.create(loginDraft('a'));
      final got = <String?>[];
      final sub = v.repo.watch(c.id).listen((i) => got.add(i?.title));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await v.repo.update(c.copyWith(title: 'b'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(got.first, 'a');
      expect(got.last, 'b');
    });
  });

  group('kilit sözleşmesi', () {
    test('oturum kilitlenince tüm işlemler StateError', () async {
      final c = await v.repo.create(loginDraft('a'));
      v.session.dispose();
      await expectLater(v.repo.create(loginDraft('b')), throwsStateError);
      await expectLater(v.repo.read(c.id), throwsStateError);
      await expectLater(v.repo.update(c), throwsStateError);
      await expectLater(v.repo.delete(c.id), throwsStateError);
      await expectLater(v.repo.trash(c.id), throwsStateError);
      await expectLater(v.repo.restore(c.id), throwsStateError);
      await expectLater(v.repo.list(), throwsStateError);
      await expectLater(v.repo.search('a'), throwsStateError);
      await expectLater(v.repo.passwordHistory(c.id), throwsStateError);
      expect(() => v.repo.watchList(), throwsStateError);
      expect(() => v.repo.readAll(), throwsStateError);
    });

    test('close() sonrası indeks boş ve işlemler StateError', () async {
      await v.repo.create(loginDraft('a'));
      await v.repo.close();
      await expectLater(v.repo.list(), throwsStateError);
    });

    test('yeniden açılışta indeks DB\'den kurulur', () async {
      await v.repo.create(loginDraft('kalici'));
      await v.repo.close();
      final again = await DriftVaultRepository.open(db: v.db, session: v.session, clock: v.clock.call);
      expect((await again.search('kalici')).length, 1);
      await again.close();
    });

    test('yanlış anahtarla kayıtlar unreadable sayılır', () async {
      await v.repo.create(loginDraft('a'));
      await v.repo.close();
      final other = await openTestVault();
      final wrong = await DriftVaultRepository.open(db: v.db, session: other.session, clock: v.clock.call);
      expect(wrong.unreadableIds.length, 1);
      expect(await wrong.list(), isEmpty);
      await wrong.close();
      await other.dispose();
    });
  });

  group('snapshot / geri yükleme', () {
    test('overwrite / skip / duplicate', () async {
      var item = await v.repo.create(loginDraft('a', pw: 'p0'));
      item = await v.repo.update(item.copyWith(data: const LoginData(username: 'ali', password: 'p1')));
      await v.repo.addAttachment(item.id, 'ek', Uint8List.fromList([1, 2, 3]));
      final snap = await v.repo.exportSnapshots().first;
      expect(snap.history.length, 1);
      expect(snap.attachments.length, 1);

      expect(await v.repo.restoreSnapshot(snap, ConflictPolicy.skip), ImportDisposition.skipped);
      expect(await v.repo.restoreSnapshot(snap, ConflictPolicy.overwrite), ImportDisposition.overwritten);
      expect((await v.repo.list()).length, 1);
      expect((await v.repo.passwordHistory(item.id)).length, 1);
      expect(await v.repo.restoreSnapshot(snap, ConflictPolicy.duplicate), ImportDisposition.duplicated);
      final all = await v.repo.list();
      expect(all.length, 2);
      expect(all.map((e) => e.title), contains('a (kopya)'));
      final dup = all.firstWhere((e) => e.title == 'a (kopya)');
      expect((await v.repo.listAttachments(dup.id)).length, 1);
    });

    test('olmayan kayıt created; zaman damgaları korunur', () async {
      final c = await v.repo.create(loginDraft('a'));
      await v.repo.trash(c.id);
      final snap = await v.repo.exportSnapshots().first;
      await v.repo.delete(c.id);
      expect(await v.repo.restoreSnapshot(snap, ConflictPolicy.skip), ImportDisposition.created);
      final r = (await v.repo.read(c.id))!;
      expect(r.createdAt, snap.item.createdAt);
      expect(r.isTrashed, isTrue);
    });
  });
}
