// SPDX-License-Identifier: Apache-2.0
import 'package:drift/native.dart';
import 'package:quanta/core/crypto/csprng.dart';
import 'package:quanta/core/crypto/vault_keys.dart';
import 'package:quanta/core/crypto/vault_service.dart';
import 'package:quanta/core/storage/quanta_database.dart';
import 'package:quanta/features/vault/data/drift_vault_repository.dart';
import 'package:quanta/features/vault/domain/item_data.dart';
import 'package:quanta/features/vault/domain/vault_item.dart';

/// Değiştirilebilir test saati.
class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 1, 1, 12);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

class TestVault {
  TestVault(this.db, this.session, this.repo, this.clock);
  final QuantaDatabase db;
  final VaultSession session;
  final DriftVaultRepository repo;
  final FakeClock clock;

  Future<void> dispose() async {
    await repo.close();
    await db.close();
    session.dispose();
  }
}

/// Düz SQLite (bellek) üzerinde; SQLCipher'a özgü davranış cihaz testindedir.
Future<TestVault> openTestVault({FakeClock? clock, VaultKeys? keys}) async {
  final k = keys ?? await VaultKeys.derive(Csprng().bytes(32));
  final session = VaultSession(k);
  final db = QuantaDatabase(NativeDatabase.memory());
  final c = clock ?? FakeClock();
  final repo = await DriftVaultRepository.open(
      db: db, session: session, clock: c.call);
  return TestVault(db, session, repo, c);
}

ItemDraft loginDraft(String title,
        {String user = 'ali', String pw = 'pw-1', List<String>? urls, List<String> tags = const []}) =>
    ItemDraft(
        title: title,
        tags: tags,
        data: LoginData(
            username: user, password: pw, urls: urls ?? ['https://$title.example']));
