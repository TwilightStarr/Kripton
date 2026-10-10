// SPDX-License-Identifier: Apache-2.0
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/crypto/crypto_exceptions.dart';
import 'package:quanta/core/crypto/key_derivation.dart';
import 'package:quanta/core/crypto/kdf_params.dart';
import 'package:quanta/core/crypto/vault_keys.dart';
import 'package:quanta/core/crypto/vault_service.dart';
import 'package:quanta/core/security/secret_bytes.dart';
import 'package:quanta/core/storage/quanta_database.dart';
import 'package:quanta/features/backup/backup_format.dart';
import 'package:quanta/features/backup/backup_service.dart';
import 'package:quanta/features/vault/data/drift_vault_repository.dart';
import 'package:quanta/features/vault/domain/item_data.dart';
import 'package:quanta/features/vault/domain/vault_item.dart';
import 'package:quanta/features/vault/domain/vault_records.dart';

import '../helpers.dart';

Matcher failsWith(CryptoFailure k) =>
    throwsA(isA<QuantaCryptoException>().having((e) => e.kind, 'kind', k));

BackupService svcFor() => BackupService(
    runner: const InlineArgon2Runner(), policy: KdfPolicy.testing);

void main() {
  late VaultService vs;
  late CreatedVault created;
  late QuantaDatabase db;
  late DriftVaultRepository repo;
  late Uint8List backup;
  const bpw = 'yedek-parolasi-2026';

  setUp(() async {
    vs = makeService();
    created = await vs.createVault(
        password: sb(goodPassword), params: testKdf, withRecovery: false);
    db = QuantaDatabase(NativeDatabase.memory());
    repo = await DriftVaultRepository.open(db: db, session: created.session);
    var a = await repo.create(const ItemDraft(
        title: 'Site',
        category: 'K',
        tags: ['t'],
        data: LoginData(username: 'ali', password: 'eski', urls: ['https://x.example'])));
    a = await repo.update(a.copyWith(data: const LoginData(username: 'ali', password: 'yeni', urls: ['https://x.example'])));
    await repo.addAttachment(a.id, 'kod.txt', Uint8List.fromList([9, 8, 7]));
    final n = await repo.create(const ItemDraft(title: 'Not', data: NoteData(body: 'gövde')));
    await repo.trash(n.id);
    backup = await svcFor().createBackup(
        repository: repo,
        keys: created.session.keys,
        vaultHeader: created.header,
        backupPassword: sb(bpw),
        params: testKdf);
  });

  tearDown(() async {
    await repo.close();
    await db.close();
    created.session.dispose();
  });

  group('biçim', () {
    test('başlık yapısı ve inspect (parolasız)', () {
      expect(backup.sublist(0, 4), BackupHeader.magic);
      expect(backup[4], 1);
      final info = BackupService.inspect(backup);
      expect(info.formatVersion, 1);
      expect(info.kdf.memoryKiB, testKdf.memoryKiB);
      expect(info.header.salt.length, 16);
      expect(info.totalBytes, backup.length);
    });

    test('her yedek farklı (tuz/nonce rastgele)', () async {
      final b2 = await svcFor().createBackup(
          repository: repo, keys: created.session.keys, vaultHeader: created.header,
          backupPassword: sb(bpw), params: testKdf);
      expect(b2, isNot(backup));
    });

    test('düz metin sızmaz', () {
      final s = String.fromCharCodes(backup);
      for (final t in ['Site', 'ali', 'yeni', 'eski', 'gövde', 'kod.txt', 'x.example']) {
        expect(s.contains(t), isFalse, reason: t);
      }
    });
  });

  group('round-trip', () {
    test('doğrula (restore etmeden): yalnızca parola, sonra tam', () async {
      final v1 = await svcFor().verify(backup, backupPassword: sb(bpw));
      expect(v1.passwordAndIntegrityOk, isTrue);
      expect(v1.fullyVerified, isFalse);
      final v2 = await svcFor().verify(backup, backupPassword: sb(bpw), keys: created.session.keys);
      expect(v2.fullyVerified, isTrue);
      expect(v2.itemCount, 2);
      expect(v2.trashedCount, 1);
      expect(v2.attachmentCount, 1);
      expect((await repo.list()).length, 1); // verify hiçbir şey değiştirmedi
    });

    test('boş kasaya geri yükleme: içerik, geçmiş, ek, çöp durumu aynı', () async {
      final db2 = QuantaDatabase(NativeDatabase.memory());
      final repo2 = await DriftVaultRepository.open(db: db2, session: created.session);
      final rep = await svcFor().restore(
          bytes: backup, backupPassword: sb(bpw), keys: created.session.keys, repository: repo2);
      expect(rep.created, 2);
      final orig = await repo.exportSnapshots().toList();
      final got = await repo2.exportSnapshots().toList();
      expect(got.length, orig.length);
      for (final o in orig) {
        final g = got.firstWhere((x) => x.item.id == o.item.id);
        expect(g.item.title, o.item.title);
        expect(g.item.data.toJson(), o.item.data.toJson());
        expect(g.item.isTrashed, o.item.isTrashed);
        expect(g.item.createdAt, o.item.createdAt);
        expect(g.history.map((h) => h.password), o.history.map((h) => h.password));
        expect(g.attachments.map((a) => a.bytes), o.attachments.map((a) => a.bytes));
      }
      // tekrar geri yükleme + çakışma politikaları
      final again = await svcFor().restore(
          bytes: backup, backupPassword: sb(bpw), keys: created.session.keys,
          repository: repo2, policy: ConflictPolicy.skip);
      expect(again.skipped, 2);
      final dup = await svcFor().restore(
          bytes: backup, backupPassword: sb(bpw), keys: created.session.keys,
          repository: repo2, policy: ConflictPolicy.duplicate);
      expect(dup.duplicated, 2);
      await repo2.close();
      await db2.close();
    });

    test('yeni cihaz: yedekteki başlıkla kasa açılır', () async {
      final creds = UnlockCredentials(
          password: sb(goodPassword),
          secretKey: SecretBytes.copyOf(created.secretKey.copyBytes()));
      final r = await svcFor().openAsNewVault(
          bytes: backup, backupPassword: sb(bpw), vaultCredentials: creds, vaultService: vs);
      expect(r.snapshots.length, 2);
      expect(r.header.encode(), created.header.encode());
      r.session.dispose();
    });
  });

  group('bozuk / yetkisiz yedek reddi', () {
    test('yanlış yedek parolası', () async {
      await expectLater(svcFor().verify(backup, backupPassword: sb('yanlis')),
          failsWith(CryptoFailure.authenticationFailed));
    });

    test('doğru yedek parolası ama yanlış kasa anahtarı (iç katman)', () async {
      final other = await VaultKeys.derive(Uint8List(32)..fillRange(0, 32, 5));
      await expectLater(
          svcFor().verify(backup, backupPassword: sb(bpw), keys: other),
          failsWith(CryptoFailure.authenticationFailed));
    });

    test('her bölgeden bayt çevirme reddedilir', () async {
      final positions = <int>[
        0, 3, // magic
        5, // flags
        8, 13, // createdAt
        16, 20, 22, // KDF
        30, 40, // salt
        45, 52, // outer nonce
        60, backup.length ~/ 2, backup.length - 49, // ciphertext
        backup.length - 40, // tag
        backup.length - 33, backup.length - 1, // mac
      ];
      for (final p in positions) {
        final bad = Uint8List.fromList(backup)..[p] ^= 0x01;
        await expectLater(
            svcFor().verify(bad, backupPassword: sb(bpw)), throwsA(isA<QuantaCryptoException>()),
            reason: 'konum $p');
      }
    });

    test('kesik ve boş dosya', () async {
      for (final n in [0, 10, 40, 100, backup.length - 1]) {
        await expectLater(
            svcFor().verify(Uint8List.sublistView(backup, 0, n), backupPassword: sb(bpw)),
            throwsA(isA<QuantaCryptoException>()),
            reason: 'uzunluk $n');
      }
    });

    test('sonuna bayt eklemek reddedilir', () async {
      final bad = Uint8List.fromList([...backup, 0]);
      await expectLater(svcFor().verify(bad, backupPassword: sb(bpw)),
          throwsA(isA<QuantaCryptoException>()));
    });

    test('gelecek sürüm ve zayıf KDF parametresi', () async {
      final v2 = Uint8List.fromList(backup)..[4] = 2;
      await expectLater(svcFor().verify(v2, backupPassword: sb(bpw)),
          failsWith(CryptoFailure.unsupportedVersion));
      // Üretim politikası test parametrelerini (256 KiB) reddeder.
      final strict = BackupService(runner: const InlineArgon2Runner());
      await expectLater(strict.verify(backup, backupPassword: sb(bpw)),
          failsWith(CryptoFailure.weakParameters));
    });
  });

  group('geri uyumluluk (v1 altın dosya)', () {
    // tool/gen_backup_fixture.py ile (Dart'tan bağımsız, docs/DATA.md §9'a göre) üretildi.
    // Bu test geçtiği sürece gelecekteki sürümler v1 dosyalarını okumaya devam eder.
    final fixture = File('test/fixtures/backup_v1.quanta');
    late Uint8List bytes;
    late VaultKeys keys;
    setUp(() async {
      bytes = fixture.readAsBytesSync();
      keys = await VaultKeys.derive(Uint8List.fromList(List.generate(32, (i) => i)));
    });
    tearDown(() => keys.dispose());

    test('başlık', () {
      final i = BackupService.inspect(bytes);
      expect(i.formatVersion, 1);
      expect(i.header.createdAtMs, 1760000000000);
      expect(i.kdf.memoryKiB, 256);
    });

    test('doğrulama ve içerik', () async {
      final s = svcFor();
      final v = await s.verify(bytes, backupPassword: sb('yedek-parolasi-2026'), keys: keys);
      expect(v.fullyVerified, isTrue);
      expect(v.itemCount, 2);
      expect(v.trashedCount, 1);
      expect(v.attachmentCount, 1);
      final snaps = await s.openSnapshots(bytes, backupPassword: sb('yedek-parolasi-2026'), keys: keys);
      final login = snaps.firstWhere((x) => x.item.id.startsWith('1111'));
      expect(login.item.title, 'Örnek Site');
      expect(login.item.isFavorite, isTrue);
      expect((login.item.data as LoginData).password, 'p@ss-Yeni-9');
      expect(login.item.customFields.single.value, '4321');
      expect(login.history.single.password, 'eski-parola');
      expect(String.fromCharCodes(login.attachments.single.bytes), 'kurtarma-kodu-0123456789');
      final note = snaps.firstWhere((x) => x.item.id.startsWith('2222'));
      expect(note.item.isTrashed, isTrue);
      expect((note.item.data as NoteData).body, 'gizli gövde');
    });
  });
}
