// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/argon2_benchmark.dart';
import '../../../core/crypto/csprng.dart';
import '../../../core/crypto/kdf_params.dart';
import '../../../core/crypto/secret_key_codec.dart';
import '../../../core/crypto/vault_service.dart';
import '../../../core/security/secret_bytes.dart';
import '../services/vault_manager.dart';
import '../services/vault_providers.dart';
import 'unlock_throttle.dart';

/// Kök ekranın hangi bölümü göstereceğini belirler.
///
/// [setupIncomplete]: kasa oluşturuldu ama Secret Key onaylanmadan uygulama
/// kapandı; kullanıcıya silme/bırakma seçeneği sunulur (otomatik silinmez).
enum VaultPhase { loading, noVault, setupIncomplete, locked, unlocked, error }

enum UnlockOutcome { success, failed, throttled, busy }

/// Kasa oluşturulduktan sonra BİR KEZ gösterilecek gizli veriler.
///
/// Dart `String`'leri sıfırlanamaz (README, "Bellek hijyeni"): yalnızca
/// referansı bırakırız. Ham [SecretBytes] kopyası biçimlendirmeden hemen sonra
/// `dispose()` edilir.
@immutable
class RevealSecrets {
  const RevealSecrets({
    required this.secretKey,
    required this.recoveryWords,
    this.secretKeyChanged = false,
    this.recoveryKept = false,
  });

  final String secretKey;
  final List<String> recoveryWords;

  /// Kurtarma ifadesiyle sıfırlamada yeni Secret Key üretildi (eskisi geçersiz).
  final bool secretKeyChanged;

  /// Kurtarma ifadesi değişmedi (yeniden gösterilmez; eldekini saklayın).
  final bool recoveryKept;

  @override
  String toString() => 'RevealSecrets(<redacted>)';
}

@immutable
class VaultState {
  const VaultState({
    required this.phase,
    this.reveal,
    this.lockedUntil,
    this.failedAttempts = 0,
  });

  final VaultPhase phase;

  /// Null değilse kasa açık ama kullanıcı Secret Key'i henüz onaylamadı.
  final RevealSecrets? reveal;

  /// İstemci tarafı bekleme (bilgi amaçlı; bkz. [UnlockThrottle]).
  final DateTime? lockedUntil;
  final int failedAttempts;

  bool get revealPending => reveal != null;
}

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Kasa oluşturmadan önce Argon2id politikasını seçer. Varsayılan: cihaz
/// kıyaslaması ([Argon2Benchmark]); sonuç `KdfPolicy.production` ile doğrulanır
/// ve politika tabanının altına inemez. Testler sabit/ucuz parametre verir.
final kdfParamsResolverProvider =
    Provider<Future<KdfParams?> Function()>((ref) {
  return () async => (await Argon2Benchmark.calibrate()).params;
});

/// Hareketsizlik sonrası otomatik kilit süresi (ayar ekranı sonraki aşamada).
final autoLockTimeoutProvider =
    Provider<Duration>((ref) => const Duration(minutes: 1));

final vaultControllerProvider =
    NotifierProvider<VaultController, VaultState>(VaultController.new);

/// Kasa yaşam döngüsü iş mantığı. Widget'lar yalnızca state'i çizer.
class VaultController extends Notifier<VaultState> {
  late UnlockThrottle _throttle;
  late VaultManager _manager;
  bool _busy = false;

  /// Kasa oluşturuldu ama Secret Key onaylanmadı işareti. Süreç bu aralıkta
  /// ölürse kasa BOŞTUR ve kullanıcı anahtarı hiç görmemiştir; açılışta silinir.
  File get _marker => File('${_manager.dbFile.parent.path}/vault.setup_pending');

  @override
  VaultState build() {
    _manager = ref.read(vaultManagerProvider);
    _throttle = UnlockThrottle(clock: ref.read(clockProvider));
    final manager = _manager;
    ref.onDispose(() => unawaited(manager.lock().catchError((Object _) {})));
    Future<void>.microtask(_init);
    return const VaultState(phase: VaultPhase.loading);
  }

  Future<void> reload() async {
    state = const VaultState(phase: VaultPhase.loading);
    await _init();
  }

  Future<void> _init() async {
    try {
      final has = await _manager.hasVault();
      if (has && await _marker.exists()) {
        // Otomatik SİLMEYİZ: kullanıcıya sorulur (bkz. discardIncompleteSetup).
        state = const VaultState(phase: VaultPhase.setupIncomplete);
        return;
      }
      state = VaultState(phase: has ? VaultPhase.locked : VaultPhase.noVault);
    } catch (_) {
      state = const VaultState(phase: VaultPhase.error);
    }
  }

  // ---------------------------------------------------------------- oluştur

  /// Yeni kasa oluşturur ve (başarılıysa) kasayı açık bırakır; Secret Key ve
  /// kurtarma kelimeleri [VaultState.reveal] içinde BİR KEZ gösterilmek üzere
  /// tutulur. [password] bu çağrıda dispose edilir (hata yolunda da).
  Future<bool> createVault({
    required SecretBytes password,
    required bool withRecovery,
  }) async {
    if (_busy || state.phase != VaultPhase.noVault) {
      password.dispose();
      return false;
    }
    _busy = true;
    CreatedVault? created;
    var attemptStarted = false;
    try {
      // Var olan bir kasayı asla geri alma (rollback) ile silmemek için önce bak.
      if (await _manager.hasVault()) return false;
      final params = await ref.read(kdfParamsResolverProvider)();
      await _marker.writeAsString('1', flush: true);
      attemptStarted = true;
      created = await _manager.createVault(
        password: password,
        params: params,
        withRecovery: withRecovery,
      );
      final keyText = await SecretKeyCodec.format(created.secretKey);
      state = VaultState(
        phase: VaultPhase.unlocked,
        reveal: RevealSecrets(
          secretKey: keyText,
          recoveryWords: List<String>.unmodifiable(created.recoveryWords),
        ),
      );
      return true;
    } catch (_) {
      if (attemptStarted) await _rollbackCreate();
      return false;
    } finally {
      password.dispose();
      created?.secretKey.dispose();
      _busy = false;
    }
  }

  /// Onaylanmamış (boş) kasayı siler ve kasa oluşturmaya döner. Yalnızca
  /// [VaultPhase.setupIncomplete] iken çalışır.
  Future<void> discardIncompleteSetup() async {
    if (state.phase != VaultPhase.setupIncomplete) return;
    await _discardUnconfirmedVault();
    state = const VaultState(phase: VaultPhase.noVault);
  }

  /// Kasayı olduğu gibi bırakır (kullanıcı Secret Key'i biliyor olabilir).
  Future<void> keepIncompleteSetup() async {
    if (state.phase != VaultPhase.setupIncomplete) return;
    try {
      if (await _marker.exists()) await _marker.delete();
    } catch (_) {}
    state = const VaultState(phase: VaultPhase.locked);
  }

  /// Kullanıcı Secret Key'i kaydettiğini onayladı: işareti sil, gizli veriyi bırak.
  Future<void> acknowledgeReveal() async {
    if (state.reveal == null) return;
    try {
      if (await _marker.exists()) await _marker.delete();
    } catch (_) {}
    state = const VaultState(phase: VaultPhase.unlocked);
  }

  Future<void> _rollbackCreate() async {
    try {
      await _manager.lock();
    } catch (_) {}
    await _discardUnconfirmedVault();
    state = const VaultState(phase: VaultPhase.noVault);
  }

  Future<void> _discardUnconfirmedVault() async {
    final h = _manager.headerStore;
    final base = _manager.dbFile.path;
    final files = <File>[
      h.file,
      h.backupFile,
      File('${h.file.path}.tmp'),
      _manager.dbFile,
      File('$base-wal'),
      File('$base-shm'),
      File('$base-journal'),
      _marker,
    ];
    for (final f in files) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  // -------------------------------------------------------------------- aç

  /// Ana parola + Secret Key ile açar. Her iki [SecretBytes] de bu çağrıda
  /// dispose edilir. Hata ayrıntısı DIŞARI VERİLMEZ (tek tip "başarısız").
  Future<UnlockOutcome> unlock({
    required SecretBytes password,
    required SecretBytes secretKey,
  }) {
    final creds = UnlockCredentials(password: password, secretKey: secretKey);
    return _attemptUnlock(
      () => _manager.unlock(creds),
      cleanup: creds.dispose,
    );
  }

  /// 24 kelimelik kurtarma ifadesiyle açar (boşlukla ayrılmış metin).
  Future<UnlockOutcome> unlockWithRecovery(String phrase) {
    final words = phrase
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    return _attemptUnlock(() => _manager.unlockWithRecovery(words));
  }

  Future<UnlockOutcome> _attemptUnlock(
    Future<Object?> Function() action, {
    void Function()? cleanup,
  }) async {
    try {
      if (_busy || state.phase != VaultPhase.locked) return UnlockOutcome.busy;
      if (_throttle.remaining > Duration.zero) {
        _publishThrottle();
        return UnlockOutcome.throttled;
      }
      _busy = true;
      try {
        await action();
        _throttle.recordSuccess();
        state = const VaultState(phase: VaultPhase.unlocked);
        return UnlockOutcome.success;
      } catch (_) {
        _throttle.recordFailure();
        _publishThrottle();
        return UnlockOutcome.failed;
      } finally {
        _busy = false;
      }
    } finally {
      cleanup?.call();
    }
  }

  void _publishThrottle() {
    state = VaultState(
      phase: state.phase,
      lockedUntil: _throttle.lockedUntil,
      failedAttempts: _throttle.failures,
    );
  }

  // ------------------------------------------------ parola sıfırlama

  /// Ana parolayı unuttuysa: 24 kelimelik kurtarma ifadesiyle yeni ana parola
  /// belirler ve kasayı açar.
  ///
  /// [existingSecretKey] doluysa o kullanılır (değişmez, yeniden gösterim yok).
  /// Boşsa YENİ bir Secret Key üretilir (eskisi geçersiz olur) ve tek seferlik
  /// gösterim ekranına düşer. Kurtarma ifadesi DEĞİŞMEZ. [newPassword] bu
  /// çağrıda dispose edilir.
  ///
  /// Güvenlik notu: sıfırlama sonrası süreç gösterimden önce ölürse yeni Secret
  /// Key görülmemiş olur; kurtarma ifadesi geçerli kaldığından sıfırlama
  /// tekrarlanabilir.
  Future<UnlockOutcome> resetPasswordWithRecovery({
    required String phrase,
    required SecretBytes newPassword,
    String? existingSecretKey,
  }) async {
    SecretBytes? secretKey;
    SecretBytes? passCopy;
    SecretBytes? keyCopy;
    try {
      if (_busy || state.phase != VaultPhase.locked) return UnlockOutcome.busy;
      if (_throttle.remaining > Duration.zero) {
        _publishThrottle();
        return UnlockOutcome.throttled;
      }
      final words = phrase
          .trim()
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();
      final given = (existingSecretKey ?? '').trim();
      final generated = given.isEmpty;
      final SecretBytes key;
      try {
        key = generated
            ? SecretKeyCodec.generate(Csprng())
            : await SecretKeyCodec.parse(given);
      } catch (_) {
        return UnlockOutcome.failed; // biçim hatası: deneme sayılmaz
      }
      secretKey = key;
      final pc = newPassword.use(SecretBytes.copyOf);
      passCopy = pc;
      final kc = key.use(SecretBytes.copyOf);
      keyCopy = kc;
      _busy = true;
      try {
        await _manager.resetWithRecovery(
          words: words,
          next: UnlockCredentials(password: newPassword, secretKey: key),
        );
        await _manager.unlock(
            UnlockCredentials(password: pc, secretKey: kc));
        _throttle.recordSuccess();
        if (generated) {
          final text = await SecretKeyCodec.format(key);
          state = VaultState(
            phase: VaultPhase.unlocked,
            reveal: RevealSecrets(
              secretKey: text,
              recoveryWords: const [],
              secretKeyChanged: true,
              recoveryKept: true,
            ),
          );
        } else {
          state = const VaultState(phase: VaultPhase.unlocked);
        }
        return UnlockOutcome.success;
      } catch (_) {
        _throttle.recordFailure();
        _publishThrottle();
        return UnlockOutcome.failed;
      } finally {
        _busy = false;
      }
    } finally {
      newPassword.dispose();
      secretKey?.dispose();
      passCopy?.dispose();
      keyCopy?.dispose();
    }
  }

  // ---------------------------------------------------------------- kilitle

  /// Kasayı kilitler ve gizli veri taşıyan her state'i temizler. UI önce
  /// temizlenir (state), sonra depo/anahtarlar kapatılır.
  Future<void> lock() async {
    if (state.phase != VaultPhase.unlocked) return;
    state = VaultState(
      phase: VaultPhase.locked,
      lockedUntil: _throttle.lockedUntil,
      failedAttempts: _throttle.failures,
    );
    try {
      await _manager.lock();
    } catch (_) {}
  }
}
