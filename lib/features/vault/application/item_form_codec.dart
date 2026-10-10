// SPDX-License-Identifier: Apache-2.0
import '../../totp/totp.dart';
import '../domain/item_data.dart';
import '../domain/item_kind.dart';

/// Form alanları <-> [ItemData] dönüşümü (saf, UI'dan bağımsız).
///
/// Anahtar adları `ItemData.toJson()` anahtarlarıyla aynıdır. Tüm değerler
/// `String`'dir: ay/yıl rakam metni, tarih `yyyy-MM-dd`, anahtarlı alanlar
/// (`hidden`) '1'/'0', Wi-Fi güvenliği `WifiSecurity.name`.
Map<String, String> dataToFields(ItemData d) {
  String date(DateTime? v) => v == null
      ? ''
      : '${v.year.toString().padLeft(4, '0')}-'
          '${v.month.toString().padLeft(2, '0')}-'
          '${v.day.toString().padLeft(2, '0')}';
  return switch (d) {
    final LoginData x => {
        'username': x.username,
        'password': x.password,
        'urls': x.urls.join('\n'),
        'totp': x.totpUri,
      },
    final CardData x => {
        'holder': x.holder,
        'number': x.number,
        'expMonth': x.expiryMonth?.toString() ?? '',
        'expYear': x.expiryYear?.toString() ?? '',
        'cvv': x.cvv,
        'pin': x.pin,
      },
    final NoteData x => {'body': x.body},
    final WifiData x => {
        'ssid': x.ssid,
        'password': x.password,
        'security': x.security.name,
        'hidden': x.hidden ? '1' : '0',
      },
    final IdentityData x => {
        'firstName': x.firstName,
        'lastName': x.lastName,
        'nationalId': x.nationalId,
        'passportNumber': x.passportNumber,
        'birthDate': date(x.birthDate),
        'birthPlace': x.birthPlace,
        'nationality': x.nationality,
        'passportExpiry': date(x.passportExpiry),
        'phone': x.phone,
        'email': x.email,
        'address': x.address,
      },
    final ApiKeyData x => {
        'key': x.key,
        'secret': x.secret,
        'endpoint': x.endpoint,
      },
    final SshKeyData x => {
        'privateKey': x.privateKey,
        'publicKey': x.publicKey,
        'passphrase': x.passphrase,
        'host': x.host,
      },
    CustomData() => const {},
  };
}

/// Satırlara böler, kırpar, boşları atar (URL listesi için).
List<String> splitLines(String s) => [
      for (final l in s.split(RegExp(r'[\r\n]+')))
        if (l.trim().isNotEmpty) l.trim()
    ];

DateTime? _parseDate(String? s) {
  if (s == null || s.isEmpty) return null;
  final p = DateTime.tryParse(s);
  return p == null ? null : DateTime(p.year, p.month, p.day);
}

ItemData fieldsToData(ItemKind kind, Map<String, String> f) {
  String s(String k) => f[k] ?? '';
  int? i(String k) => int.tryParse(s(k).trim());
  switch (kind) {
    case ItemKind.login:
      return LoginData(
        username: s('username'),
        password: s('password'),
        urls: splitLines(s('urls')),
        totpUri: s('totp').trim(),
      );
    case ItemKind.card:
      return CardData(
        holder: s('holder'),
        number: s('number'),
        expiryMonth: i('expMonth'),
        expiryYear: i('expYear'),
        cvv: s('cvv'),
        pin: s('pin'),
      );
    case ItemKind.note:
      return NoteData(body: s('body'));
    case ItemKind.wifi:
      return WifiData(
        ssid: s('ssid'),
        password: s('password'),
        security: WifiSecurity.fromWire(s('security')),
        hidden: s('hidden') == '1',
      );
    case ItemKind.identity:
      return IdentityData(
        firstName: s('firstName'),
        lastName: s('lastName'),
        nationalId: s('nationalId'),
        passportNumber: s('passportNumber'),
        birthDate: _parseDate(f['birthDate']),
        birthPlace: s('birthPlace'),
        nationality: s('nationality'),
        passportExpiry: _parseDate(f['passportExpiry']),
        phone: s('phone'),
        email: s('email'),
        address: s('address'),
      );
    case ItemKind.apiKey:
      return ApiKeyData(
        key: s('key'),
        secret: s('secret'),
        endpoint: s('endpoint'),
      );
    case ItemKind.sshKey:
      return SshKeyData(
        privateKey: s('privateKey'),
        publicKey: s('publicKey'),
        passphrase: s('passphrase'),
        host: s('host'),
      );
    case ItemKind.custom:
      return const CustomData();
  }
}

/// Alan doğrulaması: hata mesajı ya da null. Hata metinleri içerik taşımaz.
String? validateField(ItemKind kind, String key, String value) {
  final v = value.trim();
  if (v.isEmpty) return null;
  if (kind == ItemKind.card && key == 'expMonth') {
    final m = int.tryParse(v);
    return (m == null || m < 1 || m > 12) ? 'Ay 1-12 arasında olmalı.' : null;
  }
  if (kind == ItemKind.card && key == 'expYear') {
    final y = int.tryParse(v);
    return (y == null || v.length != 4 || y < 2000 || y > 2100)
        ? 'Yılı 4 haneli girin (ör. 2030).'
        : null;
  }
  if (kind == ItemKind.login && key == 'totp') {
    try {
      TotpConfig.parseUri(v);
    } on FormatException {
      return 'Geçerli bir otpauth:// adresi girin.';
    }
  }
  return null;
}

/// Kart numarası yazım uyarısı (engellemez; güvenlik özelliği değildir).
bool cardNumberLooksOff(String number) =>
    number.trim().isNotEmpty && !CardData.luhnValid(number);
