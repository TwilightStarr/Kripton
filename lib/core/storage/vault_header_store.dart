// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import '../crypto/vault_header.dart';

/// Vault başlığı (sarılmış VMK + KDF parametreleri) şifreli DB'nin DIŞINDA saklanır:
/// DB anahtarı ancak başlıkla açılan VMK'dan türer (tavuk-yumurta).
abstract interface class VaultHeaderStore {
  Future<bool> exists();
  Future<VaultHeader?> load();
  Future<void> save(VaultHeader header);
}

/// Atomik yazım: geçici dosya -> flush -> eskiyi `.bak`a kopyala -> rename.
class FileVaultHeaderStore implements VaultHeaderStore {
  FileVaultHeaderStore(this.file);
  final File file;

  File get _tmp => File('${file.path}.tmp');
  File get backupFile => File('${file.path}.bak');

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<VaultHeader?> load() async {
    if (!await file.exists()) return null;
    return VaultHeader.decode(await file.readAsBytes());
  }

  /// Elle kurtarma için: bir önceki başlık. Otomatik KULLANILMAZ (geri alma
  /// saldırısı: eski parola/zayıf parametre — bkz. CRYPTO.md §6.4).
  Future<VaultHeader?> loadPrevious() async {
    if (!await backupFile.exists()) return null;
    return VaultHeader.decode(await backupFile.readAsBytes());
  }

  @override
  Future<void> save(VaultHeader header) async {
    await file.parent.create(recursive: true);
    await _tmp.writeAsBytes(header.encode(), flush: true);
    if (await file.exists()) await file.copy(backupFile.path);
    await _tmp.rename(file.path);
  }
}
