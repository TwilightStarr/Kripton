// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/crypto/crypto_exceptions.dart';
import 'package:quanta/core/crypto/vault_service.dart';
import 'package:quanta/core/security/secret_bytes.dart';
import 'package:quanta/core/storage/quanta_database.dart';
import 'package:quanta/features/vault/domain/item_data.dart';
import 'package:quanta/features/vault/domain/vault_item.dart';
import 'package:quanta/features/vault/services/vault_manager.dart';

import '../helpers.dart';

void main() {
  late Directory tmp;
  late VaultManager m;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('quanta_mgr');
    // Düz SQLite ile (SQLCipher cihaz/entegrasyon testindedir).
    m = VaultManager(
      directory: tmp,
      vaultService: makeService(),
      databaseFactory: (f, k) async => QuantaDatabase(NativeDatabase(f)),
    );
  });
  tearDown(() async {
    await m.lock();
    tmp.deleteSync(recursive: true);
  });

  UnlockCredentials creds(CreatedVault c, [String pw = goodPassword]) =>
      UnlockCredentials(
          password: sb(pw), secretKey: SecretBytes.copyOf(c.secretKey.copyBytes()));

  test('oluştur -> yaz -> kilitle -> StateError -> aç -> veri durur', () async {
    expect(await m.hasVault(), isFalse);
    final c = await m.createVault(password: sb(goodPassword), params: testKdf, withRecovery: false);
    expect(m.isUnlocked, isTrue);
    expect(await m.hasVault(), isTrue);
    final repo = m.repository;
    final item = await repo.create(const ItemDraft(
        title: 'benzersiz-baslik-42', data: LoginData(username: 'u', password: 'gizli-pw-xyz')));

    await m.lock();
    expect(m.isUnlocked, isFalse);
    await expectLater(repo.list(), throwsStateError);
    expect(() => m.repository, throwsStateError);
    expect(() => m.keys, throwsStateError);

    // Diskte alan bazlı şifreleme: düz metin yok.
    final raw = String.fromCharCodes(m.dbFile.readAsBytesSync());
    expect(raw.contains('benzersiz-baslik-42'), isFalse);
    expect(raw.contains('gizli-pw-xyz'), isFalse);

    await expectLater(m.unlock(creds(c, 'yanlis-parola')), throwsA(isA<QuantaCryptoException>()));
    expect(m.isUnlocked, isFalse);

    final again = await m.unlock(creds(c));
    expect((await again.read(item.id))!.title, 'benzersiz-baslik-42');
    expect((await again.search('benzersiz')).length, 1);
    c.secretKey.dispose();
  });

  test('ikinci createVault ve çift unlock reddedilir', () async {
    final c = await m.createVault(password: sb(goodPassword), params: testKdf, withRecovery: false);
    await expectLater(m.createVault(password: sb(goodPassword), params: testKdf), throwsStateError);
    await expectLater(m.unlock(creds(c)), throwsStateError);
  });

  test('parola değişimi: eski parola artık açmaz, veri korunur', () async {
    final c = await m.createVault(password: sb(goodPassword), params: testKdf, withRecovery: false);
    final item = await m.repository.create(const ItemDraft(title: 'x', data: NoteData(body: 'b')));
    await m.lock();
    await m.changeCredentials(current: creds(c), next: creds(c, 'yeni-cok-uzun-parola-1'));
    await expectLater(m.unlock(creds(c)), throwsA(isA<QuantaCryptoException>()));
    final repo = await m.unlock(creds(c, 'yeni-cok-uzun-parola-1'));
    expect((await repo.read(item.id))!.title, 'x');
  });

  test('süresi dolan çöp kayıtları kilit açılışında silinir', () async {
    final c = await m.createVault(password: sb(goodPassword), params: testKdf, withRecovery: false);
    final it = await m.repository.create(const ItemDraft(title: 'x', data: NoteData(body: 'b')));
    await m.repository.trash(it.id);
    await m.lock();
    final later = VaultManager(
      directory: tmp,
      vaultService: makeService(),
      clock: () => DateTime.now().add(const Duration(days: 31)),
      databaseFactory: (f, k) async => QuantaDatabase(NativeDatabase(f)),
    );
    final repo = await later.unlock(creds(c));
    expect(await repo.read(it.id), isNull);
    await later.lock();
  });

  test('başlık dosyası atomik yazılır ve yedeği tutulur', () async {
    final c = await m.createVault(password: sb(goodPassword), params: testKdf, withRecovery: false);
    await m.changeCredentials(current: creds(c), next: creds(c, 'baska-uzun-parola-2'));
    expect(m.headerStore.file.existsSync(), isTrue);
    expect(m.headerStore.backupFile.existsSync(), isTrue);
    expect(File('${m.headerStore.file.path}.tmp').existsSync(), isFalse);
  });
}
