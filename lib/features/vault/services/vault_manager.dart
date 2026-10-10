// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import '../../../core/crypto/csprng.dart';
import '../../../core/crypto/kdf_params.dart';
import '../../../core/crypto/vault_header.dart';
import '../../../core/crypto/vault_keys.dart';
import '../../../core/crypto/vault_service.dart';
import '../../../core/security/secret_bytes.dart';
import '../../../core/storage/database_opener.dart';
import '../../../core/storage/quanta_database.dart';
import '../../../core/storage/storage_exceptions.dart';
import '../../../core/storage/vault_header_store.dart';
import '../data/drift_vault_repository.dart';
import '../domain/vault_repository.dart';
import 'maintenance_service.dart';

typedef DatabaseFactory = Future<QuantaDatabase> Function(
    File file, VaultKeys keys);

/// Kasanın yaşam döngüsü: oluştur / aç / kilitle / kimlik bilgisi değiştir.
///
/// Dizin düzeni: `<directory>/vault.header` (şifreli DB'nin DIŞINDA) ve
/// `<directory>/vault.qdb` (SQLCipher). Dizini çağıran verir (ör. path_provider).
///
/// Kilitleme sırası: depo kapanır (indeks sıfırlanır, akışlar biter) -> DB kapanır
/// -> oturum anahtarları sıfırlanır.
class VaultManager {
  VaultManager({
    required Directory directory,
    required VaultService vaultService,
    Csprng? random,
    DateTime Function()? clock,
    DatabaseFactory? databaseFactory,
  })  : _vaultService = vaultService,
        _random = random ?? Csprng(),
        _clock = clock ?? DateTime.now,
        _openDb = databaseFactory ??
            ((f, k) => DatabaseOpener.open(file: f, keys: k)),
        headerStore = FileVaultHeaderStore(File('${directory.path}/vault.header')),
        dbFile = File('${directory.path}/vault.qdb');

  final VaultService _vaultService;
  final Csprng _random;
  final DateTime Function() _clock;
  final DatabaseFactory _openDb;

  final FileVaultHeaderStore headerStore;
  final File dbFile;

  VaultSession? _session;
  QuantaDatabase? _db;
  DriftVaultRepository? _repo;
  MaintenanceService? _maintenance;

  bool get isUnlocked => _session != null && !_session!.isLocked;
  Future<bool> hasVault() => headerStore.exists();

  VaultRepository get repository =>
      _repo ?? (throw StateError('vault is locked'));
  VaultSession get session =>
      _session ?? (throw StateError('vault is locked'));
  VaultKeys get keys => session.keys;

  // --------------------------------------------------------------- oluştur

  /// Yeni kasa. Dönen [CreatedVault.secretKey] ve kurtarma kelimeleri kullanıcıya
  /// BİR KEZ gösterilmeli, sonra `secretKey.dispose()` çağrılmalıdır. Kasa açık kalır.
  Future<CreatedVault> createVault({
    required SecretBytes password,
    SecretBytes? keyFile,
    KdfParams? params,
    bool withRecovery = true,
  }) async {
    if (_session != null) throw StateError('vault already unlocked');
    if (await headerStore.exists()) throw StateError('vault already exists');
    final created = await _vaultService.createVault(
      password: password,
      keyFile: keyFile,
      params: params,
      withRecovery: withRecovery,
    );
    try {
      await _attach(created.session);
      await headerStore.save(created.header);
    } catch (_) {
      await lock();
      if (await dbFile.exists()) await dbFile.delete();
      created.secretKey.dispose();
      rethrow;
    }
    return created;
  }

  // ------------------------------------------------------------------ aç

  Future<VaultRepository> unlock(UnlockCredentials credentials,
      {bool runMaintenance = true}) async {
    if (_session != null) throw StateError('vault already unlocked');
    final header = await _requireHeader();
    final session = await _vaultService.unlock(header, credentials);
    return _finishUnlock(session, runMaintenance);
  }

  Future<VaultRepository> unlockWithRecovery(List<String> words,
      {bool runMaintenance = true}) async {
    if (_session != null) throw StateError('vault already unlocked');
    final header = await _requireHeader();
    final session = await _vaultService.unlockWithRecovery(header, words);
    return _finishUnlock(session, runMaintenance);
  }

  Future<VaultRepository> _finishUnlock(
      VaultSession session, bool runMaintenance) async {
    await _attach(session);
    if (runMaintenance) {
      // Bakım hatası kilit açmayı engellemez.
      try {
        await _repo!.purgeExpiredTrash();
        await _maintenance!.vacuumIfDue();
      } catch (_) {}
    }
    return _repo!;
  }

  Future<VaultHeader> _requireHeader() async {
    final h = await headerStore.load();
    if (h == null) throw const QuantaStorageException(StorageFailure.notFound);
    return h;
  }

  Future<void> _attach(VaultSession session) async {
    QuantaDatabase? db;
    try {
      db = await _openDb(dbFile, session.keys);
      final repo = await DriftVaultRepository.open(
          db: db, session: session, random: _random, clock: _clock);
      _db = db;
      _repo = repo;
      _maintenance = MaintenanceService(db, clock: _clock);
      _session = session;
    } catch (_) {
      await db?.close();
      session.dispose();
      rethrow;
    }
  }

  // ---------------------------------------------------------------- kilitle

  Future<void> lock() async {
    final repo = _repo;
    final db = _db;
    final session = _session;
    _repo = null;
    _db = null;
    _session = null;
    _maintenance = null;
    await repo?.close();
    await db?.close();
    session?.dispose();
  }

  Future<bool> runMaintenance({bool force = false}) {
    final m = _maintenance;
    if (m == null) throw StateError('vault is locked');
    return m.vacuumIfDue(force: force);
  }

  // ------------------------------------------------- kimlik bilgisi değişimi

  /// Ana parola / Secret Key / key file değişimi veya KDF artırımı. Veri yeniden
  /// şifrelenmez (yalnızca VMK yeniden sarılır). Kasa açık ya da kapalı olabilir.
  Future<void> changeCredentials({
    required UnlockCredentials current,
    required UnlockCredentials next,
    KdfParams? newParams,
  }) async {
    final header = await _requireHeader();
    final updated = await _vaultService.changeCredentials(
        header: header, current: current, next: next, newParams: newParams);
    await headerStore.save(updated);
  }

  Future<void> resetWithRecovery({
    required List<String> words,
    required UnlockCredentials next,
    KdfParams? newParams,
  }) async {
    final header = await _requireHeader();
    final updated = await _vaultService.resetWithRecovery(
        header: header, words: words, next: next, newParams: newParams);
    await headerStore.save(updated);
  }

  Future<VaultHeader> currentHeader() => _requireHeader();
}
