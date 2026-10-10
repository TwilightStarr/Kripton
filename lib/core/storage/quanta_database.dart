// SPDX-License-Identifier: Apache-2.0

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'schema.dart';
import 'storage_exceptions.dart';

Variable<Object> _bind(Object a) {
  if (a is int) return Variable.withInt(a);
  if (a is String) return Variable.withString(a);
  if (a is Uint8List) return Variable.withBlob(a);
  throw ArgumentError('unsupported SQL argument type: ${a.runtimeType}');
}

/// drift tabanlı veritabanı. Şema kod üretimi OLMADAN, düz SQL ile tanımlıdır
/// ([Schema]); drift'in yürütücüsünü (SQLCipher dâhil), transaction'larını ve
/// `MigrationStrategy`sini kullanır. NULL parametre bağlanmaz: NULL gereken yerde
/// SQL'e literal yazılır.
class QuantaDatabase extends GeneratedDatabase {
  /// [targetSchemaVersion] yalnızca migration testleri içindir (eski şemayı kurmak).
  QuantaDatabase(super.executor, {@visibleForTesting int? targetSchemaVersion})
      : _target = targetSchemaVersion ?? Schema.current;

  final int _target;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      const <TableInfo<Table, Object?>>[];

  @override
  Iterable<DatabaseSchemaEntity> get allSchemaEntities =>
      const <DatabaseSchemaEntity>[];

  @override
  int get schemaVersion => _target;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          for (final s in Schema.createStatements(schemaVersion)) {
            await customStatement(s);
          }
        },
        onUpgrade: (m, from, to) async {
          if (from > to) {
            throw const QuantaStorageException(StorageFailure.newerSchema);
          }
          for (var v = from + 1; v <= to; v++) {
            for (final s in Schema.stepStatements(v)) {
              await customStatement(s);
            }
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// INSERT/UPDATE/DELETE; etkilenen satır sayısını döndürür.
  Future<int> exec(String sql, [List<Object> args = const []]) =>
      customUpdate(sql, variables: [for (final a in args) _bind(a)]);

  Future<List<QueryRow>> query(String sql, [List<Object> args = const []]) =>
      customSelect(sql, variables: [for (final a in args) _bind(a)]).get();

  /// Anahtar doğru mu / şema bu uygulamadan yeni mi? Açılıştan hemen sonra çağırın.
  Future<void> verifyOpen() async {
    try {
      await customSelect('SELECT count(*) AS c FROM sqlite_master').get();
      final rows = await customSelect('PRAGMA user_version').get();
      final v = rows.single.read<int>('user_version');
      if (v > schemaVersion) {
        throw const QuantaStorageException(StorageFailure.newerSchema);
      }
    } on QuantaStorageException {
      rethrow;
    } on Object catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('not a database') || msg.contains('notadb')) {
        throw const QuantaStorageException(StorageFailure.keyMismatch);
      }
      rethrow;
    }
  }
}
