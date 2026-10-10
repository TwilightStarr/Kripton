// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/item_filter.dart';
import '../domain/item_kind.dart';
import '../domain/item_summary.dart';
import '../services/vault_providers.dart';
import 'vault_controller.dart';

enum ListStatus { loading, ready, error }

/// Liste ekranının durumu. Arama metni ve özetler burada tutulur; kasa
/// kilitlenince (ya da ekran kapanınca) provider yok edilir ve hepsi bırakılır.
@immutable
class ItemListState {
  const ItemListState({
    this.query = '',
    this.kinds = const {},
    this.favoritesOnly = false,
    this.trashed = false,
    this.sort = ItemSort.titleAsc,
    this.status = ListStatus.loading,
    this.items = const [],
    this.unreadableCount = 0,
  });

  final String query;

  /// Boşsa tüm türler.
  final Set<ItemKind> kinds;
  final bool favoritesOnly;
  final bool trashed;
  final ItemSort sort;
  final ListStatus status;
  final List<ItemSummary> items;

  /// Çözülemeyen (bozuk) kayıt sayısı.
  final int unreadableCount;

  bool get hasActiveFilter =>
      query.trim().isNotEmpty || kinds.isNotEmpty || favoritesOnly;

  ItemListState copyWith({
    String? query,
    Set<ItemKind>? kinds,
    bool? favoritesOnly,
    bool? trashed,
    ItemSort? sort,
    ListStatus? status,
    List<ItemSummary>? items,
    int? unreadableCount,
  }) =>
      ItemListState(
        query: query ?? this.query,
        kinds: kinds ?? this.kinds,
        favoritesOnly: favoritesOnly ?? this.favoritesOnly,
        trashed: trashed ?? this.trashed,
        sort: sort ?? this.sort,
        status: status ?? this.status,
        items: items ?? this.items,
        unreadableCount: unreadableCount ?? this.unreadableCount,
      );
}

/// Liste/arama durumu. `autoDispose` + kilit durumunu izleme: kasa
/// kilitlenince ya da ekran kapanınca abonelik iptal edilir, özetler ve arama
/// metni bırakılır.
final itemListProvider =
    NotifierProvider.autoDispose<ItemListController, ItemListState>(
  ItemListController.new,
);

class ItemListController extends AutoDisposeNotifier<ItemListState> {
  static const _debounce = Duration(milliseconds: 150);

  StreamSubscription<List<ItemSummary>>? _sub;
  Timer? _timer;
  List<ItemSummary> _latest = const [];
  int _gen = 0;
  bool _disposed = false;

  @override
  ItemListState build() {
    _disposed = false;
    final open = ref.watch(vaultControllerProvider
        .select((s) => s.phase == VaultPhase.unlocked && !s.revealPending));
    ref.onDispose(() {
      _disposed = true;
      _gen++;
      _timer?.cancel();
      _sub?.cancel();
      _sub = null;
      _latest = const [];
    });
    if (open) Future<void>.microtask(_subscribe);
    return const ItemListState();
  }

  ItemFilter _filter(ItemListState s) => ItemFilter(
        kinds: s.kinds.isEmpty ? null : s.kinds,
        favoritesOnly: s.favoritesOnly,
        trash: s.trashed ? TrashScope.trashed : TrashScope.active,
        sort: s.sort,
      );

  void _fail() {
    if (_disposed) return;
    state = state.copyWith(status: ListStatus.error, items: const []);
  }

  void _subscribe() {
    if (_disposed) return;
    _sub?.cancel();
    _sub = null;
    final gen = ++_gen;
    try {
      final repo = ref.read(vaultManagerProvider).repository;
      state = state.copyWith(unreadableCount: repo.unreadableIds.length);
      _sub = repo.watchList(_filter(state)).listen(
        (list) {
          if (gen != _gen) return;
          _latest = list;
          unawaited(_publish(gen));
        },
        onError: (Object _) {
          if (gen == _gen) _fail();
        },
      );
    } catch (_) {
      _fail();
    }
  }

  Future<void> _publish(int gen) async {
    final q = state.query.trim();
    final List<ItemSummary> items;
    try {
      items = q.isEmpty
          ? _latest
          : await ref
              .read(vaultManagerProvider)
              .repository
              .search(q, filter: _filter(state));
    } catch (_) {
      if (gen == _gen) _fail();
      return;
    }
    // Bu arada filtre/sorgu değiştiyse ya da kilitlendiyse sonucu at.
    if (_disposed || gen != _gen || state.query.trim() != q) return;
    state = state.copyWith(status: ListStatus.ready, items: items);
  }

  // ------------------------------------------------------------ kullanıcı

  void setQuery(String query) {
    state = state.copyWith(query: query);
    _timer?.cancel();
    if (query.trim().isEmpty) {
      unawaited(_publish(_gen));
    } else {
      _timer = Timer(_debounce, () => unawaited(_publish(_gen)));
    }
  }

  void toggleKind(ItemKind kind) {
    final next = {...state.kinds};
    if (!next.remove(kind)) next.add(kind);
    state = state.copyWith(kinds: next);
    _subscribe();
  }

  void clearKinds() {
    state = state.copyWith(kinds: const {});
    _subscribe();
  }

  void setFavoritesOnly(bool value) {
    state = state.copyWith(favoritesOnly: value);
    _subscribe();
  }

  void setSort(ItemSort sort) {
    state = state.copyWith(sort: sort);
    _subscribe();
  }

  void setTrashed(bool value) {
    state = state.copyWith(trashed: value);
    _subscribe();
  }

  /// Hata ekranındaki "Tekrar dene".
  void retry() {
    state = state.copyWith(status: ListStatus.loading);
    _subscribe();
  }
}
