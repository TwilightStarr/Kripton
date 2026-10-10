// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/crypto/kdf_params.dart';
import 'package:quanta/core/crypto/secret_key_codec.dart';
import 'package:quanta/core/security/secret_bytes.dart';
import 'package:quanta/core/storage/quanta_database.dart';
import 'package:quanta/features/vault/application/vault_controller.dart';
import 'package:quanta/features/vault/services/vault_manager.dart';
import 'package:quanta/features/vault/services/vault_providers.dart';

import '../helpers.dart';

void main() {
  late Directory tmp;
  late VaultManager manager;
  late ProviderContainer container;
  late DateTime now;
  Future<KdfParams?> Function() resolver = () async => testKdf;

  VaultManager newManager() => VaultManager(
        directory: tmp,
        vaultService: makeService(),
        databaseFactory: (f, k) async => QuantaDatabase(NativeDatabase(f)),
      );

  ProviderContainer newContainer(VaultManager m) => ProviderContainer(
        overrides: [
          vaultManagerProvider.overrideWithValue(m),
          kdfParamsResolverProvider.overrideWithValue(() => resolver()),
          clockProvider.overrideWithValue(() => now),
        ],
      );

  VaultController ctl() => container.read(vaultControllerProvider.notifier);
  VaultState st() => container.read(vaultControllerProvider);

  Future<void> settle() async {
    for (var i = 0; i < 200; i++) {
      if (st().phase != VaultPhase.loading) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('başlangıç tamamlanmadı');
  }

  File marker() => File('${tmp.path}/vault.setup_pending');

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('quanta_ui');
    now = DateTime.utc(2026, 1, 1, 12);
    resolver = () async => testKdf;
    manager = newManager();
    container = newContainer(manager);
    await settle();
  });

  tearDown(() async {
    container.dispose();
    await manager.lock();
    tmp.deleteSync(recursive: true);
  });

  Future<RevealSecrets> create({bool recovery = true}) async {
    final pw = sb(goodPassword);
    final ok = await ctl().createVault(password: pw, withRecovery: recovery);
    expect(ok, isTrue);
    expect(pw.isDisposed, isTrue, reason: 'parola dispose edilmeli');
    return st().reveal!;
  }

  Future<UnlockOutcome> unlockWith(RevealSecrets r, String password) async {
    final key = await SecretKeyCodec.parse(r.secretKey);
    return ctl().unlock(password: sb(password), secretKey: key);
  }

  test('kasa yokken noVault', () {
    expect(st().phase, VaultPhase.noVault);
  });

  test('oluştur: açık + tek seferlik gösterim; onayla -> temizlenir', () async {
    final r = await create();
    expect(st().phase, VaultPhase.unlocked);
    expect(st().revealPending, isTrue);
    expect(r.secretKey, startsWith('QNTA-'));
    expect(r.recoveryWords, hasLength(24));
    expect(marker().existsSync(), isTrue);
    expect(manager.isUnlocked, isTrue);

    await ctl().acknowledgeReveal();
    expect(st().phase, VaultPhase.unlocked);
    expect(st().reveal, isNull);
    expect(marker().existsSync(), isFalse);
  });

  test('kurtarma kapalıysa kelime listesi boş', () async {
    final r = await create(recovery: false);
    expect(r.recoveryWords, isEmpty);
  });

  test('kilitle: state temizlenir, depo erişilemez', () async {
    await create();
    await ctl().acknowledgeReveal();
    await ctl().lock();
    expect(st().phase, VaultPhase.locked);
    expect(st().reveal, isNull);
    expect(manager.isUnlocked, isFalse);
    expect(() => manager.repository, throwsStateError);
  });

  test('Secret Key + parola ile aç; kimlik bilgileri dispose edilir', () async {
    final r = await create();
    await ctl().acknowledgeReveal();
    await ctl().lock();

    final pw = sb(goodPassword);
    final key = await SecretKeyCodec.parse(r.secretKey);
    expect(await ctl().unlock(password: pw, secretKey: key),
        UnlockOutcome.success);
    expect(st().phase, VaultPhase.unlocked);
    expect(pw.isDisposed, isTrue);
    expect(key.isDisposed, isTrue);
  });

  test('yanlış parola: tek tip başarısızlık, kilitli kalır', () async {
    final r = await create();
    await ctl().acknowledgeReveal();
    await ctl().lock();

    expect(await unlockWith(r, 'tamamen-yanlis-parola'), UnlockOutcome.failed);
    expect(st().phase, VaultPhase.locked);
    expect(manager.isUnlocked, isFalse);
  });

  test('art arda başarısızlıkta bekleme; süre dolunca tekrar denenir', () async {
    final r = await create();
    await ctl().acknowledgeReveal();
    await ctl().lock();

    expect(await unlockWith(r, 'yanlis-parola-1'), UnlockOutcome.failed);
    expect(await unlockWith(r, 'yanlis-parola-2'), UnlockOutcome.failed);
    expect(st().lockedUntil, isNull);
    expect(await unlockWith(r, 'yanlis-parola-3'), UnlockOutcome.failed);
    expect(st().lockedUntil, isNotNull);

    // Bekleme sürerken doğru parola bile denenmez.
    expect(await unlockWith(r, goodPassword), UnlockOutcome.throttled);
    expect(st().phase, VaultPhase.locked);

    now = now.add(const Duration(seconds: 6));
    expect(await unlockWith(r, goodPassword), UnlockOutcome.success);
    expect(st().lockedUntil, isNull);
    expect(st().failedAttempts, 0);
  });

  test('kurtarma ifadesiyle aç', () async {
    final r = await create();
    await ctl().acknowledgeReveal();
    await ctl().lock();

    expect(await ctl().unlockWithRecovery('abc def'), UnlockOutcome.failed);
    final phrase = r.recoveryWords.join('  ').toUpperCase();
    now = now.add(const Duration(minutes: 10));
    expect(await ctl().unlockWithRecovery(phrase), UnlockOutcome.success);
    expect(st().phase, VaultPhase.unlocked);
  });

  Future<void> restartUnconfirmed() async {
    await create(); // onaylanmadı
    container.dispose();
    await manager.lock();
    manager = newManager();
    container = newContainer(manager);
    await settle();
  }

  test('onaylanmamış kasa açılışta SİLİNMEZ, kullanıcıya sorulur', () async {
    await restartUnconfirmed();
    expect(st().phase, VaultPhase.setupIncomplete);
    expect(manager.headerStore.file.existsSync(), isTrue);
    expect(marker().existsSync(), isTrue);
  });

  test('onaylanmamış kasa: sil -> kasa yok', () async {
    await restartUnconfirmed();
    await ctl().discardIncompleteSetup();
    expect(st().phase, VaultPhase.noVault);
    expect(manager.headerStore.file.existsSync(), isFalse);
    expect(manager.dbFile.existsSync(), isFalse);
    expect(marker().existsSync(), isFalse);
  });

  test('onaylanmamış kasa: olduğu gibi bırak -> kilit ekranı', () async {
    await restartUnconfirmed();
    await ctl().keepIncompleteSetup();
    expect(st().phase, VaultPhase.locked);
    expect(manager.headerStore.file.existsSync(), isTrue);
    expect(marker().existsSync(), isFalse);
  });

  test('sil/bırak yalnızca setupIncomplete iken çalışır', () async {
    await create();
    await ctl().acknowledgeReveal();
    await ctl().discardIncompleteSetup();
    await ctl().keepIncompleteSetup();
    expect(st().phase, VaultPhase.unlocked);
    expect(await manager.hasVault(), isTrue);
  });

  test('parola sıfırla (yeni Secret Key): yeni bilgilerle açılır', () async {
    final r = await create();
    await ctl().acknowledgeReveal();
    await ctl().lock();

    final ok = await ctl().resetPasswordWithRecovery(
      phrase: r.recoveryWords.join(' '),
      newPassword: sb('yepyeni-uzun-parola-77'),
    );
    expect(ok, UnlockOutcome.success);
    expect(st().phase, VaultPhase.unlocked);
    final fresh = st().reveal!;
    expect(fresh.secretKeyChanged, isTrue);
    expect(fresh.recoveryKept, isTrue);
    expect(fresh.recoveryWords, isEmpty);
    expect(fresh.secretKey, isNot(r.secretKey));

    await ctl().acknowledgeReveal();
    await ctl().lock();
    // Eski parola + eski Secret Key artık açmaz.
    expect(await unlockWith(r, goodPassword), UnlockOutcome.failed);
    now = now.add(const Duration(minutes: 10));
    // Yeni parola + yeni Secret Key açar.
    expect(await unlockWith(fresh, 'yepyeni-uzun-parola-77'),
        UnlockOutcome.success);
  });

  test('parola sıfırla (mevcut Secret Key korunur): gösterim yok', () async {
    final r = await create();
    await ctl().acknowledgeReveal();
    await ctl().lock();

    final ok = await ctl().resetPasswordWithRecovery(
      phrase: r.recoveryWords.join(' '),
      newPassword: sb('yepyeni-uzun-parola-77'),
      existingSecretKey: r.secretKey,
    );
    expect(ok, UnlockOutcome.success);
    expect(st().phase, VaultPhase.unlocked);
    expect(st().reveal, isNull);

    await ctl().lock();
    expect(await unlockWith(r, 'yepyeni-uzun-parola-77'),
        UnlockOutcome.success);
  });

  test('parola sıfırla: yanlış kurtarma ifadesi başarısız, parola dispose',
      () async {
    final r = await create();
    await ctl().acknowledgeReveal();
    await ctl().lock();

    final pw = sb('yepyeni-uzun-parola-77');
    final ok = await ctl().resetPasswordWithRecovery(
      phrase: List.filled(24, r.recoveryWords.first).join(' '),
      newPassword: pw,
    );
    expect(ok, UnlockOutcome.failed);
    expect(pw.isDisposed, isTrue);
    expect(st().phase, VaultPhase.locked);
    // Eski kimlik bilgileri hâlâ geçerli.
    expect(await unlockWith(r, goodPassword), UnlockOutcome.success);
  });

  test('onaylanmış kasa bir sonraki açılışta korunur', () async {
    await create();
    await ctl().acknowledgeReveal();
    container.dispose();
    await manager.lock();

    manager = newManager();
    container = newContainer(manager);
    await settle();
    expect(st().phase, VaultPhase.locked);
  });

  test('oluşturma hata verirse geri alınır; var olan kasa silinmez', () async {
    resolver = () async => throw StateError('kıyaslama başarısız');
    final pw = sb(goodPassword);
    expect(await ctl().createVault(password: pw, withRecovery: true), isFalse);
    expect(pw.isDisposed, isTrue);
    expect(st().phase, VaultPhase.noVault);
    expect(await manager.hasVault(), isFalse);
    expect(marker().existsSync(), isFalse);
  });

  test('kasa varken createVault reddedilir', () async {
    await create();
    await ctl().acknowledgeReveal();
    final pw = SecretBytes.copyOf([1, 2, 3]);
    expect(await ctl().createVault(password: pw, withRecovery: false), isFalse);
    expect(pw.isDisposed, isTrue);
    expect(await manager.hasVault(), isTrue);
  });
}
