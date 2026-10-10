// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/crypto/crypto_exceptions.dart';
import '../../core/crypto/crypto_labels.dart';
import '../../core/crypto/csprng.dart';
import '../../core/crypto/hkdf.dart';
import '../../core/crypto/kdf_params.dart';
import '../../core/crypto/key_derivation.dart';
import '../../core/crypto/vault_header.dart';
import '../../core/crypto/vault_keys.dart';
import '../../core/crypto/vault_service.dart';
import '../../core/security/constant_time.dart';
import '../../core/security/secret_bytes.dart';
import '../../core/storage/storage_exceptions.dart';
import '../vault/data/item_codec.dart';
import '../vault/domain/vault_records.dart';
import '../vault/domain/vault_repository.dart';
import 'backup_format.dart';

class BackupInfo {
  const BackupInfo(this.header, this.totalBytes);
  final BackupHeader header;
  final int totalBytes;
  int get formatVersion => header.formatVersion;
  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch(header.createdAtMs);
  KdfParams get kdf => header.kdf;
}

class BackupVerification {
  const BackupVerification({
    required this.info,
    required this.passwordAndIntegrityOk,
    required this.fullyVerified,
    this.itemCount,
    this.trashedCount,
    this.attachmentCount,
  });
  final BackupInfo info;

  /// Yedek parolası doğru ve MAC + dış katman geçerli.
  final bool passwordAndIntegrityOk;

  /// İç katman da (K_backup ile) çözüldü ve kayıtlar ayrıştırıldı.
  final bool fullyVerified;
  final int? itemCount;
  final int? trashedCount;
  final int? attachmentCount;
}

class RestoreReport {
  int created = 0, skipped = 0, overwritten = 0, duplicated = 0;
  int get total => created + skipped + overwritten + duplicated;
}

/// Yeni cihazda sıfırdan kurtarma sonucu: başlık kaydedilmeli, DB bu oturumun
/// anahtarlarıyla açılıp [snapshots] geri yüklenmelidir.
class RestoredVault {
  RestoredVault(this.header, this.session, this.snapshots);
  final VaultHeader header;
  final VaultSession session;
  final List<VaultItemSnapshot> snapshots;
}

/// `.quanta` yedeği: çift katman — dış: Argon2id(yedek parolası) -> AES-256-GCM;
/// iç: K_backup (VMK'dan) -> XChaCha20-Poly1305. Başlık + dış şifreli metin ayrıca
/// HMAC ile mühürlenir. İç katmanı açmak için HEM yedek parolası HEM kasa kimlik
/// bilgileri (veya mevcut açık oturum) gerekir.
class BackupService {
  BackupService({
    Argon2Runner? runner,
    this.policy = KdfPolicy.production,
    Csprng? random,
    DateTime Function()? clock,
  })  : _runner = runner ?? const IsolateArgon2Runner(),
        _random = random ?? Csprng(),
        _clock = clock ?? DateTime.now;

  final Argon2Runner _runner;
  final KdfPolicy policy;
  final Csprng _random;
  final DateTime Function() _clock;
  final AesGcm _aes = AesGcm.with256bits();
  final Xchacha20 _xchacha = Xchacha20.poly1305Aead();

  static const _malformed = QuantaCryptoException(CryptoFailure.malformedData);

  // ---------------------------------------------------------------- yardımcı

  Uint8List _aad(String label, Uint8List header) =>
      Uint8List.fromList([...utf8.encode(label), ...header]);

  Future<({Uint8List outer, Uint8List mac})> _subkeys(
      SecretBytes password, BackupHeader h) async {
    policy.validate(h.kdf); // pahalı işten ÖNCE (DoS/downgrade)
    final pw = password.copyBytes();
    Uint8List? pwKey;
    try {
      pwKey = await _runner.derive(input: pw, salt: h.salt, params: h.kdf);
      final outer = await hkdfSha512(
          ikm: pwKey, info: utf8.encode(CryptoLabels.backupOuter), length: 32);
      final mac = await hkdfSha512(
          ikm: pwKey, info: utf8.encode(CryptoLabels.backupMac), length: 32);
      return (outer: outer, mac: mac);
    } finally {
      pw.fillRange(0, pw.length, 0);
      pwKey?.fillRange(0, pwKey.length, 0);
    }
  }

  // ------------------------------------------------------------------ oluştur

  Future<Uint8List> createBackup({
    required VaultRepository repository,
    required VaultKeys keys,
    required VaultHeader vaultHeader,
    required SecretBytes backupPassword,
    KdfParams? params,
  }) async {
    final kdf = params ?? KdfParams.production;
    policy.validate(kdf);
    final header = BackupHeader(
      formatVersion: BackupHeader.currentFormat,
      createdAtMs: _clock().millisecondsSinceEpoch,
      kdf: kdf,
      salt: _random.bytes(BackupHeader.saltLength),
    );
    final headerBytes = header.encode();

    // --- iç yük (JSON)
    final items = <Map<String, Object?>>[];
    await for (final s in repository.exportSnapshots()) {
      items.add({
        ...ItemCodec.backupJson(s.item),
        'history': [
          for (final h in s.history)
            {
              'id': h.id,
              'changedAt': h.changedAt.millisecondsSinceEpoch,
              'setAt': h.setAt?.millisecondsSinceEpoch,
              'password': h.password,
            }
        ],
        'attachments': [
          for (final a in s.attachments)
            {
              'id': a.info.id,
              'name': a.info.name,
              'createdAt': a.info.createdAt.millisecondsSinceEpoch,
              'data': base64Encode(a.bytes),
            }
        ],
      });
      for (final a in s.attachments) {
        a.bytes.fillRange(0, a.bytes.length, 0);
      }
    }
    final plain = Uint8List.fromList(utf8.encode(jsonEncode({
      'format': 1,
      'createdAt': header.createdAtMs,
      'items': items,
    })));

    Uint8List? innerKeyCopy;
    Uint8List? outerPlain;
    try {
      // --- iç katman: K_backup + XChaCha20-Poly1305
      innerKeyCopy = keys.backup.copyBytes();
      final nInner = _random.bytes(24);
      final inner = await _xchacha.encrypt(plain,
          secretKey: SecretKeyData(innerKeyCopy),
          nonce: nInner,
          aad: _aad(CryptoLabels.backupInner, headerBytes));
      final vh = vaultHeader.encode();
      final b = BytesBuilder()
        ..addByte(vh.length >> 8)
        ..addByte(vh.length & 0xFF)
        ..add(vh)
        ..add(nInner)
        ..add(inner.cipherText)
        ..add(inner.mac.bytes);
      outerPlain = b.toBytes();

      // --- dış katman: Argon2id(yedek parolası) + AES-256-GCM
      final sk = await _subkeys(backupPassword, header);
      try {
        final nOuter = _random.bytes(BackupHeader.outerNonceLength);
        final outer = await _aes.encrypt(outerPlain,
            secretKey: SecretKeyData(sk.outer),
            nonce: nOuter,
            aad: _aad(CryptoLabels.backupFile, headerBytes));
        final body = BytesBuilder()
          ..add(headerBytes)
          ..add(nOuter)
          ..add(outer.cipherText)
          ..add(outer.mac.bytes);
        final macBytes = (await Hmac.sha256().calculateMac(body.toBytes(),
                secretKey: SecretKeyData(sk.mac)))
            .bytes;
        return (BytesBuilder()
              ..add(body.toBytes())
              ..add(macBytes))
            .toBytes();
      } finally {
        sk.outer.fillRange(0, sk.outer.length, 0);
        sk.mac.fillRange(0, sk.mac.length, 0);
      }
    } finally {
      plain.fillRange(0, plain.length, 0);
      innerKeyCopy?.fillRange(0, innerKeyCopy.length, 0);
      outerPlain?.fillRange(0, outerPlain.length, 0);
    }
  }

  // ------------------------------------------------------------- denetle/aç

  /// Parolasız yapı kontrolü: sihirli bayt, sürüm, KDF parametreleri.
  static BackupInfo inspect(Uint8List bytes) =>
      BackupInfo(BackupHeader.decode(bytes), bytes.length);

  /// MAC + dış katmanı doğrular, çözülmüş dış yükü döndürür.
  Future<({BackupHeader header, Uint8List headerBytes, Uint8List outerPlain})>
      _openOuter(Uint8List bytes, SecretBytes password) async {
    final header = BackupHeader.decode(bytes);
    final headerBytes = Uint8List.fromList(bytes.sublist(0, BackupHeader.length));
    final macStart = bytes.length - BackupHeader.macLength;
    final tagStart = macStart - BackupHeader.tagLength;
    const ctStart = BackupHeader.length + BackupHeader.outerNonceLength;
    if (tagStart < ctStart) throw _malformed;

    final sk = await _subkeys(password, header);
    try {
      final expected = (await Hmac.sha256().calculateMac(
              bytes.sublist(0, macStart),
              secretKey: SecretKeyData(sk.mac)))
          .bytes;
      if (!constantTimeEquals(expected, bytes.sublist(macStart))) {
        throw const QuantaCryptoException(CryptoFailure.authenticationFailed);
      }
      try {
        final plain = await _aes.decrypt(
          SecretBox(bytes.sublist(ctStart, tagStart),
              nonce: bytes.sublist(
                  BackupHeader.length, BackupHeader.length + 12),
              mac: Mac(bytes.sublist(tagStart, macStart))),
          secretKey: SecretKeyData(sk.outer),
          aad: _aad(CryptoLabels.backupFile, headerBytes),
        );
        return (
          header: header,
          headerBytes: headerBytes,
          outerPlain: Uint8List.fromList(plain)
        );
      } on SecretBoxAuthenticationError {
        throw const QuantaCryptoException(CryptoFailure.authenticationFailed);
      }
    } finally {
      sk.outer.fillRange(0, sk.outer.length, 0);
      sk.mac.fillRange(0, sk.mac.length, 0);
    }
  }

  ({VaultHeader vaultHeader, Uint8List innerBlob}) _splitOuter(Uint8List p) {
    if (p.length < 2) throw _malformed;
    final n = (p[0] << 8) | p[1];
    if (n == 0 || 2 + n + 24 + 16 > p.length) throw _malformed;
    return (
      vaultHeader: VaultHeader.decode(Uint8List.fromList(p.sublist(2, 2 + n))),
      innerBlob: Uint8List.fromList(p.sublist(2 + n)),
    );
  }

  Future<Uint8List> _openInner(
      Uint8List blob, Uint8List headerBytes, SecretBytes backupKey) async {
    final k = backupKey.copyBytes();
    try {
      final plain = await _xchacha.decrypt(
        SecretBox(blob.sublist(24, blob.length - 16),
            nonce: blob.sublist(0, 24),
            mac: Mac(blob.sublist(blob.length - 16))),
        secretKey: SecretKeyData(k),
        aad: _aad(CryptoLabels.backupInner, headerBytes),
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const QuantaCryptoException(CryptoFailure.authenticationFailed);
    } finally {
      k.fillRange(0, k.length, 0);
    }
  }

  List<VaultItemSnapshot> _decodePayload(Uint8List json) {
    try {
      final root = jsonDecode(utf8.decode(json));
      if (root is! Map<String, Object?> || root['format'] != 1) throw _malformed;
      final list = root['items'];
      if (list is! List) throw _malformed;
      final out = <VaultItemSnapshot>[];
      for (final e in list) {
        if (e is! Map<String, Object?>) throw _malformed;
        final item = ItemCodec.itemFromBackup(e);
        final hist = e['history'];
        final atts = e['attachments'];
        out.add(VaultItemSnapshot(
          item: item,
          history: [
            if (hist is List)
              for (final h in hist.whereType<Map<String, Object?>>())
                PasswordHistoryEntry(
                  id: h['id']! as String,
                  password: h['password']! as String,
                  changedAt: ItemCodec.dt(h['changedAt']! as int),
                  setAt: h['setAt'] is int ? ItemCodec.dt(h['setAt']! as int) : null,
                )
          ],
          attachments: [
            if (atts is List)
              for (final a in atts.whereType<Map<String, Object?>>())
                () {
                  final data = base64Decode(a['data']! as String);
                  return AttachmentData(
                      AttachmentInfo(
                        id: a['id']! as String,
                        itemId: item.id,
                        name: a['name']! as String,
                        size: data.length,
                        createdAt: ItemCodec.dt(a['createdAt']! as int),
                      ),
                      data);
                }()
          ],
        ));
      }
      return out;
    } on QuantaCryptoException {
      rethrow;
    } on QuantaStorageException {
      throw _malformed;
    } on FormatException {
      throw _malformed;
    } on TypeError {
      throw _malformed;
    }
  }

  /// Restore ETMEDEN yedeği doğrular. [keys] verilirse iç katman da açılıp
  /// kayıtlar ayrıştırılır (tam doğrulama); verilmezse yalnızca parola+bütünlük.
  Future<BackupVerification> verify(
    Uint8List bytes, {
    required SecretBytes backupPassword,
    VaultKeys? keys,
  }) async {
    final info = inspect(bytes);
    final o = await _openOuter(bytes, backupPassword);
    try {
      final parts = _splitOuter(o.outerPlain);
      if (keys == null) {
        return BackupVerification(
            info: info, passwordAndIntegrityOk: true, fullyVerified: false);
      }
      final plain = await _openInner(parts.innerBlob, o.headerBytes, keys.backup);
      try {
        final snaps = _decodePayload(plain);
        return BackupVerification(
          info: info,
          passwordAndIntegrityOk: true,
          fullyVerified: true,
          itemCount: snaps.length,
          trashedCount: snaps.where((s) => s.item.isTrashed).length,
          attachmentCount:
              snaps.fold<int>(0, (a, s) => a + s.attachments.length),
        );
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
    } finally {
      o.outerPlain.fillRange(0, o.outerPlain.length, 0);
    }
  }

  Future<List<VaultItemSnapshot>> openSnapshots(
    Uint8List bytes, {
    required SecretBytes backupPassword,
    required VaultKeys keys,
  }) async {
    final o = await _openOuter(bytes, backupPassword);
    try {
      final parts = _splitOuter(o.outerPlain);
      final plain = await _openInner(parts.innerBlob, o.headerBytes, keys.backup);
      try {
        return _decodePayload(plain);
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
    } finally {
      o.outerPlain.fillRange(0, o.outerPlain.length, 0);
    }
  }

  /// Mevcut (açık) kasaya geri yükler.
  Future<RestoreReport> restore({
    required Uint8List bytes,
    required SecretBytes backupPassword,
    required VaultKeys keys,
    required VaultRepository repository,
    ConflictPolicy policy = ConflictPolicy.skip,
  }) async {
    final snaps = await openSnapshots(bytes,
        backupPassword: backupPassword, keys: keys);
    final report = RestoreReport();
    for (final s in snaps) {
      switch (await repository.restoreSnapshot(s, policy)) {
        case ImportDisposition.created:
          report.created++;
        case ImportDisposition.skipped:
          report.skipped++;
        case ImportDisposition.overwritten:
          report.overwritten++;
        case ImportDisposition.duplicated:
          report.duplicated++;
      }
    }
    return report;
  }

  /// Yeni cihaz: yedekteki başlıkla (+ ana parola + Secret Key) kasayı açar.
  /// NOT: yedekteki başlık yedek ALINDIĞI andaki parolayı sarar (eski parola).
  Future<RestoredVault> openAsNewVault({
    required Uint8List bytes,
    required SecretBytes backupPassword,
    required UnlockCredentials vaultCredentials,
    required VaultService vaultService,
  }) async {
    final o = await _openOuter(bytes, backupPassword);
    try {
      final parts = _splitOuter(o.outerPlain);
      final session =
          await vaultService.unlock(parts.vaultHeader, vaultCredentials);
      try {
        final plain =
            await _openInner(parts.innerBlob, o.headerBytes, session.keys.backup);
        try {
          return RestoredVault(
              parts.vaultHeader, session, _decodePayload(plain));
        } finally {
          plain.fillRange(0, plain.length, 0);
        }
      } catch (_) {
        session.dispose();
        rethrow;
      }
    } finally {
      o.outerPlain.fillRange(0, o.outerPlain.length, 0);
    }
  }
}
