// SPDX-License-Identifier: Apache-2.0
import '../../../core/storage/storage_exceptions.dart';
import 'item_kind.dart';

String _s(Map<String, Object?> j, String k) {
  final v = j[k];
  return v is String ? v : '';
}

List<String> _ls(Map<String, Object?> j, String k) {
  final v = j[k];
  return v is List ? [for (final e in v) if (e is String) e] : const <String>[];
}

int? _i(Map<String, Object?> j, String k) {
  final v = j[k];
  return v is int ? v : null;
}

bool _b(Map<String, Object?> j, String k) => j[k] == true;

String _two(int n) => n.toString().padLeft(2, '0');

String? _dateOut(DateTime? d) =>
    d == null ? null : '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

DateTime? _dateIn(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is! String || v.isEmpty) return null;
  final p = DateTime.tryParse(v);
  return p == null ? null : DateTime(p.year, p.month, p.day);
}

/// Türe özgü alanlar. Ortak alanlar (başlık, etiket, not...) [VaultItem]'dadır.
/// Tüm değerler şifreli payload blob'una gider; hiçbiri düz sütunda saklanmaz.
sealed class ItemData {
  const ItemData();

  ItemKind get kind;
  Map<String, Object?> toJson();

  /// Parola geçmişi tutulan birincil sır (yoksa null).
  String? get primarySecret => null;

  /// Listede gösterilen ikinci satır (kullanıcı adı, SSID...). Özet blob'una girer.
  String get subtitle => '';

  /// Aramaya ve 2FA denetimine giren adresler.
  List<String> get urls => const [];

  bool get hasTotp => false;

  /// Boş bırakılmış zorunlu alanlar (güvenlik denetimi için).
  List<String> get missingRequired => const [];

  static ItemData fromJson(ItemKind kind, Map<String, Object?> j) {
    try {
      switch (kind) {
        case ItemKind.login:
          return LoginData(
              username: _s(j, 'username'),
              password: _s(j, 'password'),
              urls: _ls(j, 'urls'),
              totpUri: _s(j, 'totp'));
        case ItemKind.card:
          return CardData(
              holder: _s(j, 'holder'),
              number: _s(j, 'number'),
              expiryMonth: _i(j, 'expMonth'),
              expiryYear: _i(j, 'expYear'),
              cvv: _s(j, 'cvv'),
              pin: _s(j, 'pin'));
        case ItemKind.note:
          return NoteData(body: _s(j, 'body'));
        case ItemKind.wifi:
          return WifiData(
              ssid: _s(j, 'ssid'),
              password: _s(j, 'password'),
              security: WifiSecurity.fromWire(_s(j, 'security')),
              hidden: _b(j, 'hidden'));
        case ItemKind.identity:
          return IdentityData(
              firstName: _s(j, 'firstName'),
              lastName: _s(j, 'lastName'),
              nationalId: _s(j, 'nationalId'),
              passportNumber: _s(j, 'passportNumber'),
              birthDate: _dateIn(j, 'birthDate'),
              birthPlace: _s(j, 'birthPlace'),
              nationality: _s(j, 'nationality'),
              passportExpiry: _dateIn(j, 'passportExpiry'),
              phone: _s(j, 'phone'),
              email: _s(j, 'email'),
              address: _s(j, 'address'));
        case ItemKind.apiKey:
          return ApiKeyData(
              key: _s(j, 'key'),
              secret: _s(j, 'secret'),
              endpoint: _s(j, 'endpoint'));
        case ItemKind.sshKey:
          return SshKeyData(
              privateKey: _s(j, 'privateKey'),
              publicKey: _s(j, 'publicKey'),
              passphrase: _s(j, 'passphrase'),
              host: _s(j, 'host'));
        case ItemKind.custom:
          return const CustomData();
      }
    } on TypeError {
      throw const QuantaStorageException(StorageFailure.corrupted);
    }
  }
}

final class LoginData extends ItemData {
  const LoginData({
    this.username = '',
    this.password = '',
    this.urls = const [],
    this.totpUri = '',
  });

  final String username;
  final String password;

  @override
  final List<String> urls;

  /// `otpauth://totp/...` URI'si (algoritma/hane/periyot içinde). Boş = yok.
  final String totpUri;

  @override
  ItemKind get kind => ItemKind.login;
  @override
  String? get primarySecret => password;
  @override
  String get subtitle => username;
  @override
  bool get hasTotp => totpUri.isNotEmpty;
  @override
  List<String> get missingRequired => [
        if (username.isEmpty) 'username',
        if (password.isEmpty) 'password',
      ];

  @override
  Map<String, Object?> toJson() => {
        'username': username,
        'password': password,
        'urls': urls,
        'totp': totpUri,
      };
}

final class CardData extends ItemData {
  const CardData({
    this.holder = '',
    this.number = '',
    this.expiryMonth,
    this.expiryYear,
    this.cvv = '',
    this.pin = '',
  });

  final String holder;
  final String number;
  final int? expiryMonth; // 1..12
  final int? expiryYear; // 4 haneli
  final String cvv;
  final String pin;

  @override
  ItemKind get kind => ItemKind.card;

  @override
  String get subtitle {
    final digits = number.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 4
        ? '•••• ${digits.substring(digits.length - 4)}'
        : holder;
  }

  @override
  List<String> get missingRequired => [if (number.isEmpty) 'number'];

  /// Yazım hatası kontrolü (güvenlik özelliği değil).
  bool get hasValidLuhn => luhnValid(number);

  static bool luhnValid(String number) {
    final d = number.replaceAll(RegExp(r'[\s-]'), '');
    if (d.length < 12 || d.length > 19 || !RegExp(r'^\d+$').hasMatch(d)) {
      return false;
    }
    var sum = 0;
    var alt = false;
    for (var i = d.length - 1; i >= 0; i--) {
      var n = d.codeUnitAt(i) - 48;
      if (alt) {
        n *= 2;
        if (n > 9) n -= 9;
      }
      sum += n;
      alt = !alt;
    }
    return sum % 10 == 0;
  }

  @override
  Map<String, Object?> toJson() => {
        'holder': holder,
        'number': number,
        'expMonth': expiryMonth,
        'expYear': expiryYear,
        'cvv': cvv,
        'pin': pin,
      };
}

final class NoteData extends ItemData {
  const NoteData({this.body = ''});
  final String body;

  @override
  ItemKind get kind => ItemKind.note;
  @override
  List<String> get missingRequired => [if (body.isEmpty) 'body'];
  @override
  Map<String, Object?> toJson() => {'body': body};
}

enum WifiSecurity {
  open,
  wep,
  wpa,
  wpa2,
  wpa3,
  enterprise;

  static WifiSecurity fromWire(String s) {
    for (final v in values) {
      if (v.name == s) return v;
    }
    return WifiSecurity.wpa2;
  }
}

final class WifiData extends ItemData {
  const WifiData({
    this.ssid = '',
    this.password = '',
    this.security = WifiSecurity.wpa2,
    this.hidden = false,
  });

  final String ssid;
  final String password;
  final WifiSecurity security;
  final bool hidden;

  @override
  ItemKind get kind => ItemKind.wifi;
  @override
  String? get primarySecret => password;
  @override
  String get subtitle => ssid;
  @override
  List<String> get missingRequired => [
        if (ssid.isEmpty) 'ssid',
        if (password.isEmpty && security != WifiSecurity.open) 'password',
      ];

  @override
  Map<String, Object?> toJson() => {
        'ssid': ssid,
        'password': password,
        'security': security.name,
        'hidden': hidden,
      };
}

final class IdentityData extends ItemData {
  const IdentityData({
    this.firstName = '',
    this.lastName = '',
    this.nationalId = '',
    this.passportNumber = '',
    this.birthDate,
    this.birthPlace = '',
    this.nationality = '',
    this.passportExpiry,
    this.phone = '',
    this.email = '',
    this.address = '',
  });

  final String firstName;
  final String lastName;

  /// T.C. kimlik no (veya başka ülke ulusal kimlik numarası).
  final String nationalId;
  final String passportNumber;
  final DateTime? birthDate; // yalnızca tarih
  final String birthPlace;
  final String nationality;
  final DateTime? passportExpiry;
  final String phone;
  final String email;
  final String address;

  @override
  ItemKind get kind => ItemKind.identity;
  @override
  String get subtitle => '$firstName $lastName'.trim();
  @override
  List<String> get missingRequired =>
      [if (firstName.isEmpty && lastName.isEmpty) 'name'];

  @override
  Map<String, Object?> toJson() => {
        'firstName': firstName,
        'lastName': lastName,
        'nationalId': nationalId,
        'passportNumber': passportNumber,
        'birthDate': _dateOut(birthDate),
        'birthPlace': birthPlace,
        'nationality': nationality,
        'passportExpiry': _dateOut(passportExpiry),
        'phone': phone,
        'email': email,
        'address': address,
      };
}

/// Çok satırlı API anahtarı / belirteç.
final class ApiKeyData extends ItemData {
  const ApiKeyData({this.key = '', this.secret = '', this.endpoint = ''});
  final String key;
  final String secret;
  final String endpoint;

  @override
  ItemKind get kind => ItemKind.apiKey;
  @override
  String? get primarySecret => key;
  @override
  List<String> get urls => endpoint.isEmpty ? const [] : [endpoint];
  @override
  List<String> get missingRequired => [if (key.isEmpty) 'key'];

  @override
  Map<String, Object?> toJson() =>
      {'key': key, 'secret': secret, 'endpoint': endpoint};
}

/// Çok satırlı SSH anahtarı (PEM/OpenSSH).
final class SshKeyData extends ItemData {
  const SshKeyData({
    this.privateKey = '',
    this.publicKey = '',
    this.passphrase = '',
    this.host = '',
  });
  final String privateKey;
  final String publicKey;
  final String passphrase;
  final String host;

  @override
  ItemKind get kind => ItemKind.sshKey;
  @override
  String get subtitle => host;
  @override
  List<String> get missingRequired => [if (privateKey.isEmpty) 'privateKey'];

  @override
  Map<String, Object?> toJson() => {
        'privateKey': privateKey,
        'publicKey': publicKey,
        'passphrase': passphrase,
        'host': host,
      };
}

/// Yalnızca kullanıcı tanımlı alanlardan oluşan kayıt (alanlar [VaultItem.customFields]'te).
final class CustomData extends ItemData {
  const CustomData();
  @override
  ItemKind get kind => ItemKind.custom;
  @override
  Map<String, Object?> toJson() => const {};
}
