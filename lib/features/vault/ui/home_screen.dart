// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/item_list_controller.dart';
import '../application/vault_controller.dart';
import '../domain/item_filter.dart';
import 'item_flows.dart';
import 'item_kind_ui.dart';
import 'widgets/filter_bar.dart';
import 'widgets/item_tile.dart';

/// Açık kasa: arama, tür çipleri, sıralama, çöp kutusu görünümü ve liste.
/// Kayıt ekleme/düzenleme, çöp kutusu eylemleri (geri yükle, kalıcı sil).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.clear(); // arama metni kilitlenince/çıkınca bırakılır
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trashed = ref.watch(itemListProvider.select((s) => s.trashed));
    final sort = ref.watch(itemListProvider.select((s) => s.sort));
    final ctl = ref.read(itemListProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text(trashed ? 'Çöp kutusu' : 'Kasa'),
        actions: [
          PopupMenuButton<ItemSort>(
            tooltip: 'Sırala',
            icon: const Icon(Icons.sort),
            initialValue: sort,
            onSelected: ctl.setSort,
            itemBuilder: (_) => [
              for (final s in ItemSort.values)
                CheckedPopupMenuItem<ItemSort>(
                  value: s,
                  checked: s == sort,
                  child: Text(sortLabel(s)),
                ),
            ],
          ),
          if (trashed)
            IconButton(
              tooltip: 'Çöp kutusunu boşalt',
              icon: const Icon(Icons.delete_forever),
              onPressed: () => emptyTrashFlow(context, ref),
            ),
          IconButton(
            tooltip: trashed ? 'Kasaya dön' : 'Çöp kutusu',
            icon: Icon(trashed ? Icons.inventory_2_outlined : Icons.delete_outline),
            onPressed: () => ctl.setTrashed(!trashed),
          ),
          IconButton(
            tooltip: 'Kilitle',
            icon: const Icon(Icons.lock),
            onPressed: () => ref.read(vaultControllerProvider.notifier).lock(),
          ),
        ],
      ),
      floatingActionButton: trashed
          ? null
          : FloatingActionButton.extended(
              onPressed: () => addItemFlow(context),
              icon: const Icon(Icons.add),
              label: const Text('Kayıt ekle'),
            ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _search,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                textInputAction: TextInputAction.search,
                onChanged: ctl.setQuery,
                decoration: InputDecoration(
                  labelText: 'Ara',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _search,
                    builder: (_, v, __) => v.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            tooltip: 'Aramayı temizle',
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _search.clear();
                              ctl.setQuery('');
                            },
                          ),
                  ),
                ),
              ),
            ),
            const FilterBar(),
            const SizedBox(height: 4),
            const _UnreadableBanner(),
            const Expanded(child: _ItemList()),
          ],
        ),
      ),
    );
  }
}

class _UnreadableBanner extends ConsumerWidget {
  const _UnreadableBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(itemListProvider.select((s) => s.unreadableCount));
    if (n == 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.all(12),
      child: Text(
        '$n kayıt okunamadı (bozuk olabilir). Diğer kayıtlar etkilenmedi.',
        style: TextStyle(color: scheme.onErrorContainer),
      ),
    );
  }
}

class _ItemList extends ConsumerWidget {
  const _ItemList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(itemListProvider);
    switch (s.status) {
      case ListStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case ListStatus.error:
        return _Message(
          text: 'Liste yüklenemedi.',
          action: FilledButton(
            onPressed: ref.read(itemListProvider.notifier).retry,
            child: const Text('Tekrar dene'),
          ),
        );
      case ListStatus.ready:
        if (s.items.isEmpty) {
          final text = s.hasActiveFilter
              ? 'Eşleşen kayıt yok.'
              : (s.trashed
                  ? 'Çöp kutusu boş. Silinen kayıtlar burada 30 gün kalır.'
                  : 'Kasanız boş. Başlamak için “Kayıt ekle”ye dokunun.');
          return _Message(text: text);
        }
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 88), // FAB için boşluk
          itemCount: s.items.length,
          itemBuilder: (_, i) {
            final item = s.items[i];
            return ItemTile(
              key: ValueKey(item.id),
              item: item,
              onTap: () => item.isTrashed
                  ? trashedItemFlow(context, ref, item)
                  : openItemFlow(context, ref, item),
            );
          },
        );
    }
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(text, textAlign: TextAlign.center),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
