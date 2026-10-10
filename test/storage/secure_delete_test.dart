// SPDX-License-Identifier: Apache-2.0
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/storage/meta_store.dart';
import 'package:quanta/core/storage/quanta_database.dart';
import 'package:quanta/core/storage/secure_eraser.dart';
import 'package:quanta/features/vault/services/maintenance_service.dart';

bool containsMarker(File f, List<int> marker) {
  final bytes = f.readAsBytesSync();
  outer:
  for (var i = 0; i + marker.length <= bytes.length; i++) {
    for (var j = 0; j < marker.length; j++) {
      if (bytes[i + j] != marker[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  late Directory tmp;
  late File file;
  late QuantaDatabase db;
  final marker = Uint8List.fromList(
      List.generate(40, (i) => 'QUANTA_MARKER_0123456789_ABCDEFGHIJKLMNOP'.codeUnitAt(i)));

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('quanta_sd');
    file = File('${tmp.path}/db.sqlite');
    db = QuantaDatabase(NativeDatabase(file));
    await db.verifyOpen();
    await db.customStatement('PRAGMA secure_delete = OFF'); // yalnızca ezmeyi sına
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> insertWithMarker() async {
    final blob = Uint8List.fromList([...marker, ...marker, ...marker]);
    await db.exec(
        'INSERT INTO items(id, kind, is_favorite, created_at, updated_at, payload_schema, summary_blob, payload_blob) '
        'VALUES (?, 1, 0, 1, 1, 1, ?, ?)',
        ['id1', blob, blob]);
    await db.exec(
        'INSERT INTO attachments(id, item_id, created_at, size, payload_schema, name_blob, data_blob) VALUES (?, ?, 1, 3, 1, ?, ?)',
        ['a1', 'id1', blob, blob]);
  }

  test('eraseItem: işaretçi önce dosyada VAR, sonra YOK', () async {
    await insertWithMarker();
    expect(containsMarker(file, marker), isTrue, reason: 'test duyarlılığı');
    final ok = await db.transaction(
        () => SecureEraser(db, MetaStore(db)).eraseItem('id1'));
    expect(ok, isTrue);
    expect(await db.query('SELECT 1 FROM items'), isEmpty);
    expect(await db.query('SELECT 1 FROM attachments'), isEmpty);
    expect(containsMarker(file, marker), isFalse);
  });

  test('silme sayacı artar; eşik/aralık kuralı', () async {
    final meta = MetaStore(db);
    final m = MaintenanceService(db,
        clock: () => DateTime.utc(2026, 1, 1),
        vacuumInterval: const Duration(days: 7),
        deleteThreshold: 5);
    expect(await m.isVacuumDue(), isFalse); // silme yok
    await insertWithMarker();
    await db.transaction(() => SecureEraser(db, meta).eraseItem('id1'));
    expect(await meta.getInt(MetaStore.deletesSinceVacuum), 1);
    // Hiç VACUUM yapılmadı (last=0) ve >=1 silme var => aralık dolmuş sayılır.
    expect(await m.isVacuumDue(), isTrue);
    await meta.setInt(MetaStore.lastVacuumMs,
        DateTime.utc(2026, 1, 1).millisecondsSinceEpoch);
    expect(await m.isVacuumDue(), isFalse); // az önce yapıldı, eşik altı
    await meta.setInt(MetaStore.deletesSinceVacuum, 5);
    expect(await m.isVacuumDue(), isTrue); // eşik
  });

  test('VACUUM: aralık dolunca çalışır, sayaç sıfırlanır', () async {
    final meta = MetaStore(db);
    await meta.setInt(MetaStore.deletesSinceVacuum, 1);
    final m = MaintenanceService(db,
        clock: () => DateTime.utc(2026, 1, 1),
        vacuumInterval: const Duration(days: 7));
    expect(await m.vacuumIfDue(), isTrue);
    expect(await meta.getInt(MetaStore.deletesSinceVacuum), 0);
    expect(await m.vacuumIfDue(), isFalse);
  });
}
