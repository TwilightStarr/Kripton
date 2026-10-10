// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../security/secret_bytes.dart';
import 'crypto_labels.dart';
import 'hkdf.dart';

/// VMK'dan HKDF-SHA512 ile türetilen bağımsız alt anahtarlar.
class VaultKeys {
  VaultKeys._({
    required this.outer,
    required this.inner,
    required this.index,
    required this.backup,
    required this.header,
    required this.db,
  });

  final SecretBytes outer; // AES-256-GCM
  final SecretBytes inner; // XChaCha20-Poly1305
  final SecretBytes index; // arama indeksi HMAC
  final SecretBytes backup; // yedek dosyası
  final SecretBytes header; // başlık MAC
  final SecretBytes db; // SQLCipher ham anahtarı (aşama 2)

  static Future<VaultKeys> derive(Uint8List vmk) async {
    Future<SecretBytes> d(String label) async => SecretBytes(
        await hkdfSha512(ikm: vmk, info: utf8.encode(label), length: 32));
    return VaultKeys._(
      outer: await d(CryptoLabels.outer),
      inner: await d(CryptoLabels.inner),
      index: await d(CryptoLabels.index),
      backup: await d(CryptoLabels.backup),
      header: await d(CryptoLabels.header),
      db: await d(CryptoLabels.db),
    );
  }

  /// Arama indeksi için kör (blind) belirteç: HMAC-SHA256(K_index, normalize(terim)).
  Future<Uint8List> searchToken(String term) async {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(term.trim().toLowerCase()),
      secretKey: index.use((b) => SecretKeyData(b)),
    );
    return Uint8List.fromList(mac.bytes);
  }

  bool get isDisposed => outer.isDisposed;

  void dispose() {
    outer.dispose();
    inner.dispose();
    index.dispose();
    backup.dispose();
    header.dispose();
    db.dispose();
  }
}
