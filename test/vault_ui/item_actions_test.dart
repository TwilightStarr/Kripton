// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/storage/quanta_database.dart';
import 'package:quanta/features/vault/application/item_actions.dart';
import 'package:quanta/features/vault/application/vault_controller.dart';
import 'package:quanta/features/vault/domain/item_data.dart';
import 'package:quanta/features/vault/domain/vault_item.dart';
import 'package:quanta/features/vault/services/vault_manager.dart';
import 'package:quanta/features/vault/services/vault_providers.dart';

import '../helpers.dart';

void main() {
  late Directory tmp;
  late VaultManager manager;
  late ProviderContainer container;
  late ItemActions actions;

  Future<void> until(bool Function() test) async {
    for (var i = 0; i < 300; i++) {
      if (test()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('zaman aşımı');
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('quanta_actions');
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
    await until(() =>
        container.read(vaultControllerProvider).phase == VaultPhase.noVault);
    expect(
        await vc.createVault(password: sb(goodPassword), withRecovery: false),
        isTrue);
    await vc.acknowledgeReveal();
    actions = container.read(itemActionsProvider);
  });

  tearDown(() async {
    container.dispose();
    await manager.lock();
    tmp.deleteSync(recursive: true);
  });

  const draft = ItemDraft(
    title: 'Github',
    data: LoginData(username: 'ali', password: 'eski-parola-1'),
    tags: ['iş'],
    notes: 'not',
    customFields: [CustomField('Soru', 'Cevap', CustomFieldType.hidden)],
  );

  test('ekle -> oku: tüm alanlar korunur', () async {
    final created = await actions.create(draft);
    final read = (await actions.read(created.id))!;
    expect(read.title, 'Github');
    expect((read.data as LoginData).password, 'eski-parola-1');
    expect(read.tags, ['iş']);
    expect(read.notes, 'not');
    expect(read.customFields.single,
        const CustomField('Soru', 'Cevap', CustomFieldType.hidden));
  });

  test('düzenle: parola değişince eski parola geçmişte korunur', () async {
    final created = await actions.create(draft);
    await actions.update(created.copyWith(
        title: 'Github (iş)',
        data: const LoginData(username: 'ali', password: 'yeni-parola-2')));

    final read = (await actions.read(created.id))!;
    expect(read.title, 'Github (iş)');
    expect((read.data as LoginData).password, 'yeni-parola-2');
    final history = await manager.repository.passwordHistory(created.id);
    expect(history.map((h) => h.password), ['eski-parola-1']);
  });

  test('çöpe taşı -> geri yükle', () async {
    final created = await actions.create(draft);
    await actions.trash(created.id);
    expect((await actions.read(created.id))!.isTrashed, isTrue);
    await actions.restore(created.id);
    expect((await actions.read(created.id))!.isTrashed, isFalse);
  });

  test('kalıcı sil: kayıt tamamen kalkar', () async {
    final created = await actions.create(draft);
    await actions.trash(created.id);
    await actions.deletePermanently(created.id);
    expect(await actions.read(created.id), isNull);
  });

  test('çöp kutusunu boşalt yalnızca çöptekileri siler', () async {
    final a = await actions.create(draft);
    final b = await actions.create(draft.copyOf('Diğer'));
    await actions.trash(a.id);
    expect(await actions.emptyTrash(), 1);
    expect(await actions.read(a.id), isNull);
    expect(await actions.read(b.id), isNotNull);
  });

  test('kilitliyken işlemler StateError ile düşer', () async {
    final created = await actions.create(draft);
    await container.read(vaultControllerProvider.notifier).lock();
    expect(() => actions.read(created.id), throwsStateError);
    expect(() => actions.create(draft), throwsStateError);
  });
}

extension on ItemDraft {
  ItemDraft copyOf(String title) => ItemDraft(title: title, data: data);
}
