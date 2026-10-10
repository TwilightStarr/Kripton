// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/storage/quanta_database.dart';
import 'package:quanta/core/storage/schema.dart';
import 'package:quanta/core/storage/storage_exceptions.dart';

Future<List<String>> ddl(QuantaDatabase db) async => [
      for (final r in await db.query(
          "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name"))
        '${r.read<String>('type')}|${r.read<String>('name')}|${r.read<String>('sql')}'
    ];

void main() {
  late Directory tmp;
  late File file;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('quanta_mig');
    file = File('${tmp.path}/db.sqlite');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('v1 -> v2: veri korunur, blind_index eklenir', () async {
    final v1 = QuantaDatabase(NativeDatabase(file), targetSchemaVersion: 1);
    await v1.exec(
        'INSERT INTO items(id, kind, is_favorite, created_at, updated_at, payload_schema, summary_blob, payload_blob) '
        'VALUES (?, 1, 0, 1, 2, 1, x\'0102\', x\'0304\')',
        ['abc']);
    expect(await v1.query("SELECT name FROM sqlite_master WHERE name='blind_index'"),
        isEmpty);
    await v1.close();

    final v2 = QuantaDatabase(NativeDatabase(file));
    final rows = await v2.query('SELECT id FROM items');
    expect(rows.single.read<String>('id'), 'abc');
    expect(await v2.query("SELECT name FROM sqlite_master WHERE name='blind_index'"),
        isNotEmpty);
    final uv = await v2.query('PRAGMA user_version');
    expect(uv.single.read<int>('user_version'), Schema.current);
    await v2.close();
  });

  test('yükseltilmiş şema == sıfırdan kurulan şema', () async {
    final v1 = QuantaDatabase(NativeDatabase(file), targetSchemaVersion: 1);
    await v1.verifyOpen();
    await v1.close();
    final upgraded = QuantaDatabase(NativeDatabase(file));
    final a = await ddl(upgraded);
    await upgraded.close();

    final fresh = QuantaDatabase(NativeDatabase.memory());
    final b = await ddl(fresh);
    await fresh.close();
    expect(a, b);
  });

  test('daha yeni şemalı DB reddedilir', () async {
    // Bu uygulamadan "daha yeni" bir DB'yi taklit et: güncel şemayı kur, user_version'ı yükselt.
    final newer = QuantaDatabase(NativeDatabase(file));
    await newer.verifyOpen();
    await newer.customStatement('PRAGMA user_version = ${Schema.current + 1}');
    await newer.close();
    final db = QuantaDatabase(NativeDatabase(file));
    await expectLater(
        db.verifyOpen(),
        throwsA(isA<QuantaStorageException>()
            .having((e) => e.kind, 'kind', StorageFailure.newerSchema)));
    await db.close();
  });
}
