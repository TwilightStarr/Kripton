// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import '../../core/crypto/crypto_exceptions.dart';
import '../../core/crypto/vault_header.dart';
import '../../core/crypto/vault_service.dart';
import '../../core/security/constant_time.dart';
import '../vault/domain/item_data.dart';
import '../vault/domain/vault_item.dart';
import '../vault/domain/vault_repository.dart';
import 'csv_codec.dart';
import 'import_service.dart';

/// Tek kullanımlık, kısa ömürlü yetki. Yalnızca [PlainExportService.authorize] üretir.
class PlainExportAuthorization {
  PlainExportAuthorization._(this.expiresAt);
  final DateTime expiresAt;
  bool _used = false;
}

class PlainExportResult {
  PlainExportResult(this.bytes, this.itemCount, this.advisory);
  final Uint8List bytes;
  final int itemCount;
  final PlaintextAdvisory advisory;
}

/// Düz CSV dışa aktarım: (1) risk açıkça onaylanmalı, (2) ana kimlik bilgileri
/// yeniden girilip başlıkla doğrulanmalı ve AÇIK oturumla aynı kasa olmalı.
/// Dosya yazılmaz: çağıran bayt'ları alır (ve ardından uyarıyı göstermelidir).
class PlainExportService {
  PlainExportService(this._vaultService,
      {DateTime Function()? clock, this.validFor = const Duration(minutes: 2)})
      : _clock = clock ?? DateTime.now;
  final VaultService _vaultService;
  final DateTime Function() _clock;
  final Duration validFor;

  static const columns = [
    'type', 'title', 'category', 'favorite', 'tags', 'url', 'username',
    'password', 'totp', 'notes', 'extra_json'
  ];

  Future<PlainExportAuthorization> authorize({
    required bool acknowledgedRisk,
    required VaultHeader header,
    required UnlockCredentials credentials,
    required VaultSession currentSession,
  }) async {
    if (!acknowledgedRisk) {
      throw const QuantaCryptoException(CryptoFailure.invalidInput);
    }
    if (currentSession.isLocked) throw StateError('vault is locked');
    final fresh = await _vaultService.unlock(header, credentials); // yanlışsa fırlatır
    try {
      final a = currentSession.keys.index.copyBytes();
      final b = fresh.keys.index.copyBytes();
      final same = constantTimeEquals(a, b);
      a.fillRange(0, a.length, 0);
      b.fillRange(0, b.length, 0);
      if (!same) {
        throw const QuantaCryptoException(CryptoFailure.authenticationFailed);
      }
    } finally {
      fresh.dispose();
    }
    return PlainExportAuthorization._(_clock().add(validFor));
  }

  Future<PlainExportResult> exportCsv({
    required PlainExportAuthorization authorization,
    required VaultRepository repository,
  }) async {
    if (authorization._used || _clock().isAfter(authorization.expiresAt)) {
      throw const QuantaCryptoException(CryptoFailure.authenticationFailed);
    }
    authorization._used = true;
    final rows = <List<String>>[columns];
    var n = 0;
    await for (final item in repository.readAll()) {
      rows.add(_row(item));
      n++;
    }
    return PlainExportResult(
        Uint8List.fromList(utf8.encode(CsvCodec.encode(rows))),
        n,
        const PlaintextAdvisory('dışa aktarılan CSV'));
  }

  List<String> _row(VaultItem i) {
    final d = i.data;
    String url = '', user = '', pw = '', totp = '';
    Object? extraData;
    switch (d) {
      case LoginData():
        url = d.urls.join('\n');
        user = d.username;
        pw = d.password;
        totp = d.totpUri;
      case WifiData():
        user = d.ssid;
        pw = d.password;
        extraData = {'security': d.security.name, 'hidden': d.hidden};
      case ApiKeyData():
        url = d.endpoint;
        pw = d.key;
        extraData = {'secret': d.secret};
      default:
        extraData = d.toJson();
    }
    final extra = {
      if (extraData != null) 'data': extraData,
      if (i.customFields.isNotEmpty)
        'custom': [for (final f in i.customFields) f.toJson()],
    };
    return [
      i.kind.wireName,
      i.title,
      i.category ?? '',
      i.isFavorite ? '1' : '0',
      i.tags.join(';'),
      url,
      user,
      pw,
      totp,
      i.notes,
      extra.isEmpty ? '' : jsonEncode(extra),
    ];
  }
}
