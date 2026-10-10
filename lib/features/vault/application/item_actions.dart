// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/vault_item.dart';
import '../domain/vault_repository.dart';
import '../services/vault_providers.dart';

/// Kayıt işlemleri (ekle/düzenle/çöp/kalıcı sil). UI yalnızca bunu çağırır.
/// Kilitliyken tüm çağrılar [StateError] ile düşer (depo sözleşmesi).
class ItemActions {
  ItemActions(this._ref);
  final Ref _ref;

  VaultRepository get _repo => _ref.read(vaultManagerProvider).repository;

  Future<VaultItem?> read(String id) => _repo.read(id);
  Future<VaultItem> create(ItemDraft draft) => _repo.create(draft);

  /// Parola değiştiyse eski parolayı depo kendisi geçmişe yazar.
  Future<VaultItem> update(VaultItem item) => _repo.update(item);

  /// Silme = çöp kutusuna taşı (30 gün sonra kalıcı silinir).
  Future<void> trash(String id) => _repo.trash(id);
  Future<void> restore(String id) => _repo.restore(id);

  /// KALICI güvenli silme (ezme + silme). Geri alınamaz.
  Future<void> deletePermanently(String id) => _repo.delete(id);
  Future<int> emptyTrash() => _repo.emptyTrash();
}

final itemActionsProvider = Provider<ItemActions>(ItemActions.new);
