// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/crypto/crypto_exceptions.dart';
import 'package:quanta/core/crypto/vault_service.dart';
import 'package:quanta/core/util/text_fold.dart';
import 'package:quanta/features/vault/domain/item_filter.dart';
import 'package:quanta/features/vault/domain/item_kind.dart';
import 'package:quanta/features/vault/domain/item_summary.dart';
import 'package:quanta/features/vault/domain/vault_item.dart';
import 'package:quanta/features/vault/domain/vault_repository.dart';
import 'package:quanta/features/vault/services/vault_manager.dart';

ItemSummary summary(
  String id,
  String title, {
  ItemKind kind = ItemKind.login,
  String subtitle = '',
  bool favorite = false,
  bool totp = false,
  bool trashed = false,
}) =>
    ItemSummary(
      id: id,
      kind: kind,
      title: title,
      subtitle: subtitle,
      urls: const [],
      tags: const [],
      hasTotp: totp,
      isFavorite: favorite,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      trashedAt: trashed ? DateTime.utc(2026, 1, 2) : null,
    );

/// Bellek içi sahte depo: liste/arama/izleme + temel CRUD.
class FakeRepo extends Fake implements VaultRepository {
  FakeRepo(List<ItemSummary> items, {List<VaultItem> full = const []})
      : _items = [...items, for (final i in full) _sum(i)],
        _full = {for (final i in full) i.id: i};

  List<ItemSummary> _items;
  final Map<String, VaultItem> _full;
  final _changes = StreamController<void>.broadcast();
  int searchCalls = 0;
  int _seq = 0;
  bool failList = false;
  bool failWrites = false;

  final List<ItemDraft> created = [];
  final List<VaultItem> updated = [];
  final List<String> trashedIds = [];
  final List<String> restoredIds = [];
  final List<String> deletedIds = [];
  int emptied = 0;

  static ItemSummary _sum(VaultItem i) => ItemSummary(
        id: i.id,
        kind: i.kind,
        title: i.title,
        subtitle: i.data.subtitle,
        urls: i.data.urls,
        tags: i.tags,
        hasTotp: i.data.hasTotp,
        isFavorite: i.isFavorite,
        createdAt: i.createdAt,
        updatedAt: i.updatedAt,
        trashedAt: i.trashedAt,
      );

  void setItems(List<ItemSummary> items) {
    _items = [...items];
    _changes.add(null);
  }

  void _write() {
    if (failWrites) throw StateError('write failed');
  }

  List<ItemSummary> _list(ItemFilter f) =>
      [for (final s in _items) if (f.matches(s)) s]..sort(f.compare);

  @override
  List<String> get unreadableIds => const [];

  @override
  Future<VaultItem?> read(String id) async => _full[id];

  @override
  Future<VaultItem> create(ItemDraft draft) async {
    _write();
    created.add(draft);
    final item = VaultItem(
      id: 'new${_seq++}',
      title: draft.title,
      data: draft.data,
      createdAt: DateTime.utc(2026, 1, 3),
      updatedAt: DateTime.utc(2026, 1, 3),
      category: draft.category,
      isFavorite: draft.isFavorite,
      tags: draft.tags,
      notes: draft.notes,
      customFields: draft.customFields,
    );
    _full[item.id] = item;
    setItems([..._items, _sum(item)]);
    return item;
  }

  @override
  Future<VaultItem> update(VaultItem item) async {
    _write();
    updated.add(item);
    _full[item.id] = item;
    setItems([for (final s in _items) s.id == item.id ? _sum(item) : s]);
    return item;
  }

  @override
  Future<void> trash(String id) async {
    _write();
    trashedIds.add(id);
    setItems([
      for (final s in _items)
        s.id == id ? s.copyWith(trashedAt: DateTime.utc(2026, 1, 4)) : s
    ]);
  }

  @override
  Future<void> restore(String id) async {
    _write();
    restoredIds.add(id);
    setItems([
      for (final s in _items) s.id == id ? s.copyWith(trashedAt: null) : s
    ]);
  }

  @override
  Future<void> delete(String id) async {
    _write();
    deletedIds.add(id);
    _full.remove(id);
    setItems([for (final s in _items) if (s.id != id) s]);
  }

  @override
  Future<int> emptyTrash() async {
    _write();
    emptied++;
    final n = _items.where((s) => s.isTrashed).length;
    setItems([for (final s in _items) if (!s.isTrashed) s]);
    return n;
  }

  @override
  Future<List<ItemSummary>> list(
          [ItemFilter filter = const ItemFilter()]) async =>
      _list(filter);

  @override
  Future<List<ItemSummary>> search(String query,
      {ItemFilter filter = const ItemFilter()}) async {
    searchCalls++;
    final q = foldForSearch(query);
    return [
      for (final s in _list(filter))
        if (foldForSearch(s.title).contains(q)) s
    ];
  }

  @override
  Stream<List<ItemSummary>> watchList(
      [ItemFilter filter = const ItemFilter()]) async* {
    if (failList) throw StateError('boom');
    yield _list(filter);
    await for (final _ in _changes.stream) {
      yield _list(filter);
    }
  }
}

/// Dosya/Argon2 kullanmayan sahte yönetici: widget testleri hızlı ve
/// FakeAsync ile uyumlu kalır (gerçek akış vault_controller_test.dart'ta).
class FakeManager extends Fake implements VaultManager {
  FakeManager(this.dir, {this.exists = true, FakeRepo? repo})
      : repo = repo ?? FakeRepo(const []);

  final Directory dir;
  final bool exists;
  final FakeRepo repo;
  bool accept = false;
  bool unlocked = false;
  int unlockCalls = 0;
  int lockCalls = 0;

  @override
  File get dbFile => File('${dir.path}/vault.qdb');

  @override
  Future<bool> hasVault() async => exists;

  @override
  bool get isUnlocked => unlocked;

  @override
  VaultRepository get repository =>
      unlocked ? repo : throw StateError('vault is locked');

  @override
  Future<VaultRepository> unlock(UnlockCredentials credentials,
      {bool runMaintenance = true}) async {
    unlockCalls++;
    if (!accept) {
      throw const QuantaCryptoException(CryptoFailure.authenticationFailed);
    }
    unlocked = true;
    return repo;
  }

  @override
  Future<void> lock() async {
    lockCalls++;
    unlocked = false;
  }
}
