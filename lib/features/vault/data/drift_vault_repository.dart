// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryRow;

import '../../../core/crypto/crypto_exceptions.dart';
import '../../../core/crypto/csprng.dart';
import '../../../core/crypto/vault_service.dart';
import '../../../core/storage/meta_store.dart';
import '../../../core/storage/quanta_database.dart';
import '../../../core/storage/schema.dart';
import '../../../core/storage/secure_eraser.dart';
import '../../../core/storage/storage_exceptions.dart';
import '../../../core/util/text_fold.dart';
import '../../../core/util/url_utils.dart';
import '../../../core/util/uuid.dart';
import '../domain/item_filter.dart';
import '../domain/item_kind.dart';
import '../domain/item_summary.dart';
import '../domain/vault_item.dart';
import '../domain/vault_records.dart';
import '../domain/vault_repository.dart';
import 'item_codec.dart';
import 'search_index.dart';

/// drift/SQLCipher üzerinde [VaultRepository].
///
/// Her hassas alan, aşama 1'in kaskad şifresiyle (XChaCha20-Poly1305 ⊂ AES-256-GCM)
/// ayrı blob olarak yazılır; AAD = (kayıt kimliği, payload şema sürümü, alan adı).
/// Bu, SQLCipher'ın (üçüncü katman) ÜZERİNDE ek bir savunma derinliğidir.
class DriftVaultRepository implements VaultRepository {
  DriftVaultRepository._(this._db, this._session, this._rng, this._clock)
      : _meta = MetaStore(_db),
        _eraser = SecureEraser(_db, MetaStore(_db));

  /// Açar, özet blob'larını çözüp bellek indeksini kurar.
  static Future<DriftVaultRepository> open({
    required QuantaDatabase db,
    required VaultSession session,
    Csprng? random,
    DateTime Function()? clock,
  }) async {
    if (session.isLocked) throw StateError('vault is locked');
    final repo = DriftVaultRepository._(
        db, session, random ?? Csprng(), clock ?? DateTime.now);
    repo._blind =
        (await repo._meta.get(MetaStore.blindIndexEnabled)) == '1';
    await repo._loadIndex();
    return repo;
  }

  final QuantaDatabase _db;
  final VaultSession _session;
  final Csprng _rng;
  final DateTime Function() _clock;
  final MetaStore _meta;
  final SecureEraser _eraser;

  final SearchIndex _index = SearchIndex();
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<String> _unreadable = [];
  bool _closed = false;
  bool _blind = false;

  @override
  List<String> get unreadableIds => List.unmodifiable(_unreadable);

  // ------------------------------------------------------------- yardımcılar

  void _ensureOpen() {
    if (_closed || _session.isLocked) throw StateError('vault is locked');
  }

  DateTime _now() => ItemCodec.dt(_clock().millisecondsSinceEpoch);
  static int _ms(DateTime d) => d.millisecondsSinceEpoch;

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<Uint8List> _seal(
          Map<String, Object?> json, String recordId, String field) =>
      _session.cipher.sealJson(
          json: json,
          recordId: recordId,
          schemaVersion: Schema.payloadSchema,
          field: field);

  Future<Map<String, Object?>> _unseal(
          Uint8List blob, String recordId, int schema, String field) =>
      _session.cipher.openJson(
          blob: blob, recordId: recordId, schemaVersion: schema, field: field);

  static ItemColumns _cols(QueryRow r) => (
        kindCode: r.read<int>('kind'),
        favorite: r.read<int>('is_favorite') != 0,
        createdAt: r.read<int>('created_at'),
        updatedAt: r.read<int>('updated_at'),
        lastUsedAt: r.readNullable<int>('last_used_at'),
        trashedAt: r.readNullable<int>('trashed_at'),
      );

  static const _colList =
      'kind, is_favorite, created_at, updated_at, last_used_at, trashed_at';

  static String? _cat(String? c) {
    final t = c?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  Future<void> _loadIndex() async {
    _index.clear();
    _unreadable.clear();
    final rows = await _db.query(
        'SELECT id, $_colList, payload_schema, summary_blob FROM items');
    for (final r in rows) {
      final id = r.read<String>('id');
      try {
        final json = await _unseal(r.read<Uint8List>('summary_blob'), id,
            r.read<int>('payload_schema'), 'summary');
        _index.put(ItemCodec.summaryFrom(id: id, json: json, cols: _cols(r)));
      } on QuantaCryptoException {
        _unreadable.add(id);
      } on QuantaStorageException {
        _unreadable.add(id);
      }
    }
  }

  Future<VaultItem?> _readFull(String id) async {
    final rows = await _db.query(
        'SELECT $_colList, payload_schema, payload_blob FROM items WHERE id = ?',
        [id]);
    if (rows.isEmpty) return null;
    final r = rows.single;
    final json = await _unseal(r.read<Uint8List>('payload_blob'), id,
        r.read<int>('payload_schema'), 'payload');
    return ItemCodec.itemFrom(id: id, json: json, cols: _cols(r));
  }

  Future<bool> _rowExists(String id) async =>
      (await _db.query('SELECT 1 AS x FROM items WHERE id = ?', [id]))
          .isNotEmpty;

  // ------------------------------------------------------------ kör indeks

  Future<void> _insertTokens(ItemSummary s) async {
    final tokens = <(int, Uint8List)>[];
    Future<void> add(BlindField f, String v) async {
      final n = foldForSearch(v).trim();
      if (n.isEmpty) return;
      tokens.add((f.code, await _session.keys.searchToken('${f.name}\u0000$n')));
    }

    await add(BlindField.title, s.title);
    if (s.kind == ItemKind.login) await add(BlindField.username, s.subtitle);
    for (final u in s.urls) {
      final h = hostOf(u);
      if (h != null) await add(BlindField.host, h);
    }
    for (final t in s.tags) {
      await add(BlindField.tag, t);
    }
    for (final (field, token) in tokens) {
      await _db.exec(
          'INSERT OR IGNORE INTO blind_index(item_id, field, token) VALUES (?, ?, ?)',
          [s.id, field, token]);
    }
  }

  Future<void> _rewriteTokens(ItemSummary s) async {
    if (!_blind) return;
    await _eraser.eraseBlindIndexOf(s.id);
    await _insertTokens(s);
  }

  @override
  Future<bool> isBlindIndexEnabled() async {
    _ensureOpen();
    return _blind;
  }

  @override
  Future<void> setBlindIndexEnabled(bool enabled) async {
    _ensureOpen();
    await _db.transaction(() async {
      await _eraser.eraseAllBlindIndex();
      if (enabled) {
        for (final s in _index.list(const ItemFilter(trash: TrashScope.all))) {
          await _insertTokens(s);
        }
      }
      await _meta.set(MetaStore.blindIndexEnabled, enabled ? '1' : '0');
    });
    _blind = enabled;
  }

  @override
  Future<List<ItemSummary>> findByExact(BlindField field, String term) async {
    _ensureOpen();
    if (!_blind) {
      throw const QuantaStorageException(StorageFailure.unsupported);
    }
    final n = field == BlindField.host
        ? (hostOf(term) ?? foldForSearch(term).trim())
        : foldForSearch(term).trim();
    if (n.isEmpty) return const [];
    final token = await _session.keys.searchToken('${field.name}\u0000$n');
    final rows = await _db.query(
        'SELECT item_id FROM blind_index WHERE field = ? AND token = ?',
        [field.code, token]);
    final out = <ItemSummary>[];
    for (final r in rows) {
      final s = _index.get(r.read<String>('item_id'));
      if (s != null) out.add(s);
    }
    return out;
  }

  // ----------------------------------------------------------------- yazma

  Future<void> _insertHistory(String itemId, PasswordHistoryEntry e) async {
    final blob = await _seal(
        {'p': e.password, 'setAt': e.setAt?.millisecondsSinceEpoch},
        '$itemId/ph/${e.id}',
        'password');
    await _db.exec(
        'INSERT INTO password_history(id, item_id, changed_at, payload_schema, blob) '
        'VALUES (?, ?, ?, ?, ?)',
        [e.id, itemId, _ms(e.changedAt), Schema.payloadSchema, blob]);
  }

  Future<void> _trimHistory(String itemId) async {
    final rows = await _db.query(
        'SELECT id FROM password_history WHERE item_id = ? '
        'ORDER BY changed_at DESC, rowid DESC LIMIT -1 OFFSET ?',
        [itemId, Schema.maxPasswordHistory]);
    for (final r in rows) {
      await _eraser.eraseHistoryRow(r.read<String>('id'));
    }
  }

  Future<void> _insertAttachment(
      String itemId, String attId, String name, Uint8List bytes, DateTime at) async {
    final nameBlob =
        await _seal({'name': name}, '$itemId/att/$attId', 'att_name');
    final dataBlob = await _session.cipher.seal(
        payload: bytes,
        recordId: '$itemId/att/$attId',
        schemaVersion: Schema.payloadSchema,
        field: 'att_data');
    await _db.exec(
        'INSERT INTO attachments(id, item_id, created_at, size, payload_schema, name_blob, data_blob) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [attId, itemId, _ms(at), bytes.length, Schema.payloadSchema, nameBlob, dataBlob]);
  }

  /// Çağıranın transaction'ı içinde çalışır.
  Future<void> _insertRow(
    VaultItem item, {
    List<PasswordHistoryEntry> history = const [],
    List<AttachmentData> attachments = const [],
    bool freshChildIds = false,
  }) async {
    final payload = await _seal(ItemCodec.payloadJson(item), item.id, 'payload');
    final summary = await _seal(ItemCodec.summaryJson(item), item.id, 'summary');
    await _db.exec(
        'INSERT INTO items(id, kind, is_favorite, created_at, updated_at, '
        'payload_schema, summary_blob, payload_blob) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          item.id,
          item.kind.code,
          item.isFavorite ? 1 : 0,
          _ms(item.createdAt),
          _ms(item.updatedAt),
          Schema.payloadSchema,
          summary,
          payload,
        ]);
    if (item.lastUsedAt != null) {
      await _db.exec('UPDATE items SET last_used_at = ? WHERE id = ?',
          [_ms(item.lastUsedAt!), item.id]);
    }
    if (item.trashedAt != null) {
      await _db.exec('UPDATE items SET trashed_at = ? WHERE id = ?',
          [_ms(item.trashedAt!), item.id]);
    }
    final recent = [...history]
      ..sort((a, b) => b.changedAt.compareTo(a.changedAt));
    for (final h in recent.take(Schema.maxPasswordHistory)) {
      await _insertHistory(
          item.id,
          freshChildIds
              ? PasswordHistoryEntry(
                  id: newUuidV4(_rng),
                  password: h.password,
                  changedAt: h.changedAt,
                  setAt: h.setAt)
              : h);
    }
    for (final a in attachments) {
      if (a.bytes.length > Schema.maxAttachmentBytes) {
        throw const QuantaStorageException(StorageFailure.limitExceeded);
      }
      await _insertAttachment(item.id,
          freshChildIds ? newUuidV4(_rng) : a.info.id, a.info.name, a.bytes, a.info.createdAt);
    }
    await _rewriteTokens(ItemCodec.summaryOfItem(item));
  }

  @override
  Future<VaultItem> create(ItemDraft d) async {
    _ensureOpen();
    final now = _now();
    final item = VaultItem(
      id: newUuidV4(_rng),
      title: d.title,
      data: d.data,
      category: _cat(d.category),
      isFavorite: d.isFavorite,
      tags: normalizeTags(d.tags),
      colorValue: d.colorValue,
      notes: d.notes,
      customFields: d.customFields,
      createdAt: now,
      updatedAt: now,
      secretChangedAt: (d.data.primarySecret ?? '').isEmpty ? null : now,
    );
    await _db.transaction(() => _insertRow(item));
    _index.put(ItemCodec.summaryOfItem(item));
    _notify();
    return item;
  }

  @override
  Future<VaultItem?> read(String id) async {
    _ensureOpen();
    return _readFull(id);
  }

  @override
  Future<VaultItem> update(VaultItem item) async {
    _ensureOpen();
    late VaultItem saved;
    await _db.transaction(() async {
      final old = await _readFull(item.id);
      if (old == null) {
        throw const QuantaStorageException(StorageFailure.notFound);
      }
      if (old.kind != item.kind) {
        throw const QuantaStorageException(StorageFailure.invalidInput);
      }
      final now = _now();
      final oldSecret = old.data.primarySecret ?? '';
      final newSecret = item.data.primarySecret ?? '';
      final changed = oldSecret != newSecret;
      saved = item.copyWith(
        category: _cat(item.category),
        tags: normalizeTags(item.tags),
        createdAt: old.createdAt,
        updatedAt: now,
        lastUsedAt: old.lastUsedAt,
        trashedAt: old.trashedAt,
        secretChangedAt: changed
            ? (newSecret.isEmpty ? null : now)
            : old.secretChangedAt,
      );
      final payload = await _seal(ItemCodec.payloadJson(saved), saved.id, 'payload');
      final summary = await _seal(ItemCodec.summaryJson(saved), saved.id, 'summary');
      await _db.exec(
          'UPDATE items SET is_favorite = ?, updated_at = ?, payload_schema = ?, '
          'summary_blob = ?, payload_blob = ? WHERE id = ?',
          [
            saved.isFavorite ? 1 : 0,
            _ms(now),
            Schema.payloadSchema,
            summary,
            payload,
            saved.id,
          ]);
      if (changed && oldSecret.isNotEmpty) {
        await _insertHistory(
            old.id,
            PasswordHistoryEntry(
                id: newUuidV4(_rng),
                password: oldSecret,
                changedAt: now,
                setAt: old.secretChangedAt));
        await _trimHistory(old.id);
      }
      await _rewriteTokens(ItemCodec.summaryOfItem(saved));
    });
    _index.put(ItemCodec.summaryOfItem(saved));
    _notify();
    return saved;
  }

  @override
  Future<void> delete(String id) async {
    _ensureOpen();
    final existed = await _db.transaction(() => _eraser.eraseItem(id));
    if (!existed) return; // idempotent
    _index.remove(id);
    _notify();
  }

  @override
  Future<void> trash(String id) async {
    _ensureOpen();
    final now = _now();
    final n = await _db.exec(
        'UPDATE items SET trashed_at = COALESCE(trashed_at, ?) WHERE id = ?',
        [_ms(now), id]);
    if (n == 0) throw const QuantaStorageException(StorageFailure.notFound);
    final s = _index.get(id);
    if (s != null && s.trashedAt == null) {
      _index.put(s.copyWith(trashedAt: now));
    }
    _notify();
  }

  @override
  Future<void> restore(String id) async {
    _ensureOpen();
    final n =
        await _db.exec('UPDATE items SET trashed_at = NULL WHERE id = ?', [id]);
    if (n == 0) throw const QuantaStorageException(StorageFailure.notFound);
    final s = _index.get(id);
    if (s != null) _index.put(s.copyWith(trashedAt: null));
    _notify();
  }

  Future<int> _purge(List<String> ids) async {
    if (ids.isEmpty) return 0;
    var n = 0;
    await _db.transaction(() async {
      for (final id in ids) {
        if (await _eraser.eraseItem(id)) n++;
      }
    });
    for (final id in ids) {
      _index.remove(id);
    }
    _notify();
    return n;
  }

  @override
  Future<int> purgeExpiredTrash() async {
    _ensureOpen();
    final cutoff = _ms(_now().subtract(Schema.trashRetention));
    final rows = await _db.query(
        'SELECT id FROM items WHERE trashed_at IS NOT NULL AND trashed_at <= ?',
        [cutoff]);
    return _purge([for (final r in rows) r.read<String>('id')]);
  }

  @override
  Future<int> emptyTrash() async {
    _ensureOpen();
    final rows =
        await _db.query('SELECT id FROM items WHERE trashed_at IS NOT NULL');
    return _purge([for (final r in rows) r.read<String>('id')]);
  }

  @override
  Future<void> markUsed(String id) async {
    _ensureOpen();
    final now = _now();
    final n = await _db.exec(
        'UPDATE items SET last_used_at = ? WHERE id = ?', [_ms(now), id]);
    if (n == 0) throw const QuantaStorageException(StorageFailure.notFound);
    final s = _index.get(id);
    if (s != null) _index.put(s.copyWith(lastUsedAt: now));
    _notify();
  }

  @override
  Future<void> setFavorite(String id, bool value) async {
    _ensureOpen();
    final n = await _db.exec(
        'UPDATE items SET is_favorite = ? WHERE id = ?', [value ? 1 : 0, id]);
    if (n == 0) throw const QuantaStorageException(StorageFailure.notFound);
    final s = _index.get(id);
    if (s != null) _index.put(s.copyWith(isFavorite: value));
    _notify();
  }

  // ---------------------------------------------------------- liste / arama

  @override
  Future<List<ItemSummary>> list([ItemFilter filter = const ItemFilter()]) async {
    _ensureOpen();
    return _index.list(filter);
  }

  @override
  Future<List<ItemSummary>> search(String query,
      {ItemFilter filter = const ItemFilter()}) async {
    _ensureOpen();
    return _index.search(query, filter);
  }

  // ------------------------------------------------------------ reaktif

  /// Değişiklikleri birleştirir (coalesce) ve sıralı yayınlar.
  Stream<T> _watch<T>(Future<T> Function() read) {
    StreamSubscription<void>? sub;
    late final StreamController<T> out;
    var running = false;
    var dirty = false;

    Future<void> pump() async {
      if (running) {
        dirty = true;
        return;
      }
      running = true;
      try {
        do {
          dirty = false;
          final v = await read();
          if (!out.isClosed) out.add(v);
        } while (dirty);
      } catch (e, st) {
        if (!out.isClosed) {
          out.addError(e, st);
          await out.close();
        }
      } finally {
        running = false;
      }
    }

    out = StreamController<T>(
      onListen: () {
        sub = _changes.stream.listen((_) => pump(), onDone: () {
          if (!out.isClosed) out.close();
        });
        pump();
      },
      onCancel: () async {
        await sub?.cancel();
      },
    );
    return out.stream;
  }

  @override
  Stream<List<ItemSummary>> watchList(
      [ItemFilter filter = const ItemFilter()]) {
    _ensureOpen();
    return _watch(() async {
      _ensureOpen();
      return _index.list(filter);
    });
  }

  @override
  Stream<VaultItem?> watch(String id) {
    _ensureOpen();
    return _watch(() async {
      _ensureOpen();
      return _readFull(id);
    });
  }

  @override
  Stream<VaultItem> readAll({bool includeTrashed = false}) {
    _ensureOpen();
    return _readAllImpl(includeTrashed);
  }

  Stream<VaultItem> _readAllImpl(bool includeTrashed) async* {
    final ids = [
      for (final s in _index.list(ItemFilter(
          trash: includeTrashed ? TrashScope.all : TrashScope.active)))
        s.id
    ];
    for (final id in ids) {
      _ensureOpen();
      final it = await _readFull(id);
      if (it != null) yield it;
    }
  }

  // ------------------------------------------------- parola geçmişi / ekler

  @override
  Future<List<PasswordHistoryEntry>> passwordHistory(String itemId) async {
    _ensureOpen();
    final rows = await _db.query(
        'SELECT id, changed_at, payload_schema, blob FROM password_history '
        'WHERE item_id = ? ORDER BY changed_at DESC, rowid DESC',
        [itemId]);
    final out = <PasswordHistoryEntry>[];
    for (final r in rows) {
      final id = r.read<String>('id');
      final j = await _unseal(r.read<Uint8List>('blob'), '$itemId/ph/$id',
          r.read<int>('payload_schema'), 'password');
      final p = j['p'];
      if (p is! String) {
        throw const QuantaStorageException(StorageFailure.corrupted);
      }
      final setAt = j['setAt'];
      out.add(PasswordHistoryEntry(
        id: id,
        password: p,
        changedAt: ItemCodec.dt(r.read<int>('changed_at')),
        setAt: setAt is int ? ItemCodec.dt(setAt) : null,
      ));
    }
    return out;
  }

  @override
  Future<AttachmentInfo> addAttachment(
      String itemId, String name, Uint8List bytes) async {
    _ensureOpen();
    if (name.trim().isEmpty) {
      throw const QuantaStorageException(StorageFailure.invalidInput);
    }
    if (bytes.length > Schema.maxAttachmentBytes) {
      throw const QuantaStorageException(StorageFailure.limitExceeded);
    }
    if (!await _rowExists(itemId)) {
      throw const QuantaStorageException(StorageFailure.notFound);
    }
    final id = newUuidV4(_rng);
    final now = _now();
    await _db.transaction(() => _insertAttachment(itemId, id, name, bytes, now));
    _notify();
    return AttachmentInfo(
        id: id, itemId: itemId, name: name, size: bytes.length, createdAt: now);
  }

  Future<AttachmentInfo> _attInfo(QueryRow r) async {
    final id = r.read<String>('id');
    final itemId = r.read<String>('item_id');
    final j = await _unseal(r.read<Uint8List>('name_blob'), '$itemId/att/$id',
        r.read<int>('payload_schema'), 'att_name');
    final name = j['name'];
    if (name is! String) {
      throw const QuantaStorageException(StorageFailure.corrupted);
    }
    return AttachmentInfo(
        id: id,
        itemId: itemId,
        name: name,
        size: r.read<int>('size'),
        createdAt: ItemCodec.dt(r.read<int>('created_at')));
  }

  @override
  Future<List<AttachmentInfo>> listAttachments(String itemId) async {
    _ensureOpen();
    final rows = await _db.query(
        'SELECT id, item_id, created_at, size, payload_schema, name_blob '
        'FROM attachments WHERE item_id = ? ORDER BY created_at, rowid',
        [itemId]);
    return [for (final r in rows) await _attInfo(r)];
  }

  @override
  Future<AttachmentData?> readAttachment(String attachmentId) async {
    _ensureOpen();
    final rows = await _db.query(
        'SELECT id, item_id, created_at, size, payload_schema, name_blob, data_blob '
        'FROM attachments WHERE id = ?',
        [attachmentId]);
    if (rows.isEmpty) return null;
    final r = rows.single;
    final info = await _attInfo(r);
    final bytes = await _session.cipher.open(
        blob: r.read<Uint8List>('data_blob'),
        recordId: '${info.itemId}/att/${info.id}',
        schemaVersion: r.read<int>('payload_schema'),
        field: 'att_data');
    return AttachmentData(info, bytes);
  }

  @override
  Future<void> deleteAttachment(String attachmentId) async {
    _ensureOpen();
    final ok = await _db.transaction(() => _eraser.eraseAttachment(attachmentId));
    if (ok) _notify();
  }

  // ------------------------------------------------------ yedek / geri yükleme

  @override
  Stream<VaultItemSnapshot> exportSnapshots() {
    _ensureOpen();
    return _exportImpl();
  }

  Stream<VaultItemSnapshot> _exportImpl() async* {
    final ids = [
      for (final s in _index.list(const ItemFilter(trash: TrashScope.all))) s.id
    ];
    for (final id in ids) {
      _ensureOpen();
      final item = await _readFull(id);
      if (item == null) continue;
      final attRows = await _db.query(
          'SELECT id FROM attachments WHERE item_id = ? ORDER BY created_at, rowid',
          [id]);
      final atts = <AttachmentData>[];
      for (final r in attRows) {
        final a = await readAttachment(r.read<String>('id'));
        if (a != null) atts.add(a);
      }
      yield VaultItemSnapshot(
          item: item, history: await passwordHistory(id), attachments: atts);
    }
  }

  @override
  Future<ImportDisposition> restoreSnapshot(
      VaultItemSnapshot s, ConflictPolicy policy) async {
    _ensureOpen();
    var result = ImportDisposition.created;
    VaultItem? written;
    await _db.transaction(() async {
      final exists = await _rowExists(s.item.id);
      if (!exists) {
        await _insertRow(s.item, history: s.history, attachments: s.attachments);
        written = s.item;
        result = ImportDisposition.created;
        return;
      }
      switch (policy) {
        case ConflictPolicy.skip:
          result = ImportDisposition.skipped;
        case ConflictPolicy.overwrite:
          await _eraser.eraseItem(s.item.id);
          await _insertRow(s.item,
              history: s.history, attachments: s.attachments);
          written = s.item;
          result = ImportDisposition.overwritten;
        case ConflictPolicy.duplicate:
          final copy = VaultItem(
            id: newUuidV4(_rng),
            title: '${s.item.title} (kopya)',
            data: s.item.data,
            category: s.item.category,
            isFavorite: s.item.isFavorite,
            tags: s.item.tags,
            colorValue: s.item.colorValue,
            notes: s.item.notes,
            customFields: s.item.customFields,
            createdAt: s.item.createdAt,
            updatedAt: s.item.updatedAt,
            lastUsedAt: s.item.lastUsedAt,
            trashedAt: s.item.trashedAt,
            secretChangedAt: s.item.secretChangedAt,
          );
          await _insertRow(copy,
              history: s.history,
              attachments: s.attachments,
              freshChildIds: true);
          written = copy;
          result = ImportDisposition.duplicated;
      }
    });
    final w = written;
    if (w != null) {
      _index.put(ItemCodec.summaryOfItem(w));
      _notify();
    }
    return result;
  }

  // ------------------------------------------------------------------ kapat

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _index.clear();
    _unreadable.clear();
    await _changes.close();
  }
}
