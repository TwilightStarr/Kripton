// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../crypto/hex.dart';
import '../crypto/vault_keys.dart';
import 'quanta_database.dart';
import 'storage_exceptions.dart';

/// SQLCipher'ı yükler ve vault anahtarıyla açar.
///
/// Anahtar: `K_db = HKDF-SHA512(VMK, "quanta/v1/db")` (bkz. [VaultKeys.db]),
/// SQLCipher'a HAM anahtar olarak verilir (`PRAGMA key = "x'<64 hex>'"`): anahtar
/// zaten yüksek entropili olduğundan SQLCipher'ın kendi PBKDF2'si atlanır.
///
/// UYARI (bellek): hex dizgisi Dart `String`'idir, sıfırlanamaz ve arka plan
/// isolate'ına kopyalanır. Kendi `Uint8List` kopyalarımızı sıfırlarız.
abstract final class DatabaseOpener {
  static Future<QuantaDatabase> open({
    required File file,
    required VaultKeys keys,
  }) async {
    final raw = keys.db.copyBytes();
    final String hexKey;
    try {
      hexKey = toHex(raw);
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
    await file.parent.create(recursive: true);
    final db = QuantaDatabase(_executor(file, hexKey));
    try {
      await db.verifyOpen();
    } catch (_) {
      await db.close();
      rethrow;
    }
    return db;
  }

  // Closure yalnızca [hexKey] yakalar (isolate'a gönderilebilir olmalı).
  static QueryExecutor _executor(File file, String hexKey) {
    return NativeDatabase.createInBackground(
      file,
      isolateSetup: _isolateSetup,
      setup: (rawDb) => _applyPragmas(rawDb, hexKey),
    );
  }

  static Future<void> _isolateSetup() async {
    await applyWorkaroundToOpenSqlCipherOnOldAndroidVersions();
    sqlite_open.open
        .overrideFor(sqlite_open.OperatingSystem.android, openCipherOnAndroid);
  }

  static void _applyPragmas(sqlite.Database rawDb, String hexKey) {
    // SQLCipher yoksa SESSİZCE düz SQLite'a düşmek felakettir: reddet.
    final hasCipher = rawDb.select('PRAGMA cipher_version;').isNotEmpty;
    if (!hasCipher) {
      throw const QuantaStorageException(StorageFailure.unsupported);
    }
    rawDb.execute("PRAGMA key = \"x'$hexKey'\";");
    rawDb.execute('PRAGMA cipher_memory_security = ON;');
    rawDb.execute('PRAGMA secure_delete = ON;');
    rawDb.execute('PRAGMA foreign_keys = ON;');
  }
}
