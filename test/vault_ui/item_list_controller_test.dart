// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/storage/quanta_database.dart';
import 'package:quanta/features/vault/application/item_list_controller.dart';
import 'package:quanta/features/vault/application/vault_controller.dart';
import 'package:quanta/features/vault/domain/item_kind.dart';
import 'package:quanta/features/vault/domain/vault_item.dart';
import 'package:quanta/features/vault/domain/item_data.dart';
import 'package:quanta/features/vault/services/vault_manager.dart';
import 'package:quanta/features/vault/services/vault_providers.dart';

import '../helpers.dart';
import '../vault/vault_test_helpers.dart' show loginDraft;

void main() {
  late Directory tmp;
  late VaultManager manager;
  late ProviderContainer container;

  ItemListState st() => container.read(itemListProvider);
  ItemListController ctl() => container.read(itemListProvider.notifier);

  Future<void> until(bool Function() test, [String why = '']) async {
    for (var i = 0; i < 300; i++) {
      if (test()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('zaman aşımı: $why');
  }

  List<String> titles() => [for (final i in st().items) i.title];

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('quanta_list');
    manager = VaultManager(
      directory: tmp,
      vaultService: makeService(),
      databaseFactory: (f, k) async => QuantaDatabase(NativeDatabase(f)),
    );
    container = ProviderContainer(overrides: [
      vaultManagerProvider.overrideWithValue(manager),
      kdfParamsResolverProvider.overrideWithValue(() async => testKdf),
    ]);
    final vc = container.read(vaultControllerProvider.notifier);
    await until(() => container.read(vaultControllerProvider).phase ==
        VaultPhase.noVault);
    expect(
        await vc.createVault(password: sb(goodPassword), withRecovery: false),
        isTrue);
    await vc.acknowledgeReveal();
  });

  tearDown(() async {
    container.dispose();
    await manager.lock();
    tmp.deleteSync(recursive: true);
  });

  Future<VaultItem> add(String title,
      {bool fav = false, ItemKind kind = ItemKind.login}) async {
    final repo = manager.repository;
    final item = kind == ItemKind.login
        ? await repo.create(loginDraft(title))
        : await repo.create(
            ItemDraft(title: title, data: const NoteData(body: 'x')));
    if (fav) await repo.setFavorite(item.id, true);
    return item;
  }

  void listen() => container.listen(itemListProvider, (_, __) {});

  test('liste başlığa göre sıralı gelir ve canlı güncellenir', () async {
    await add('Zeta');
    await add('Alfa');
    listen();
    await until(() => st().status == ListStatus.ready, 'ilk liste');
    expect(titles(), ['Alfa', 'Zeta']);

    await add('Beta');
    await until(() => st().items.length == 3, 'canlı güncelleme');
    expect(titles(), ['Alfa', 'Beta', 'Zeta']);
  });

  test('arama Türkçe karakterleri katlar ve sonucu daraltır', () async {
    await add('Işık Bankası');
    await add('Github');
    listen();
    await until(() => st().items.length == 2);

    ctl().setQuery('isik');
    await until(() => st().items.length == 1, 'arama');
    expect(titles(), ['Işık Bankası']);

    ctl().setQuery('');
    await until(() => st().items.length == 2, 'arama temizlendi');
  });

  test('tür ve favori filtreleri', () async {
    await add('Giriş A', fav: true);
    await add('Giriş B');
    await add('Not C', kind: ItemKind.note);
    listen();
    await until(() => st().items.length == 3);

    ctl().toggleKind(ItemKind.note);
    await until(() => st().items.length == 1, 'tür filtresi');
    expect(titles(), ['Not C']);

    ctl().clearKinds();
    ctl().setFavoritesOnly(true);
    await until(() => titles().length == 1 && titles().first == 'Giriş A',
        'favori filtresi');
  });

  test('çöp kutusu görünümü', () async {
    final a = await add('Silinecek');
    await add('Kalacak');
    listen();
    await until(() => st().items.length == 2);

    await manager.repository.trash(a.id);
    await until(() => titles().length == 1 && titles().first == 'Kalacak',
        'çöpe taşındı');

    ctl().setTrashed(true);
    await until(() => titles().length == 1 && titles().first == 'Silinecek',
        'çöp görünümü');
  });

  test('kilitlenince arama metni ve özetler bırakılır', () async {
    await add('Gizli Başlık');
    listen();
    await until(() => st().items.isNotEmpty);
    ctl().setQuery('gizli');
    await until(() => st().query == 'gizli');

    await container.read(vaultControllerProvider.notifier).lock();
    await until(() => st().items.isEmpty && st().query.isEmpty,
        'kilit sonrası temizlik');
    expect(manager.isUnlocked, isFalse);
    expect(() => manager.repository, throwsStateError);
  });
}
