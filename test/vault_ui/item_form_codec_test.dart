// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/features/vault/application/item_form_codec.dart';
import 'package:quanta/features/vault/domain/item_data.dart';
import 'package:quanta/features/vault/domain/item_kind.dart';

void main() {
  group('dataToFields / fieldsToData gidiş-dönüş', () {
    void roundTrip(ItemData d) {
      final back = fieldsToData(d.kind, dataToFields(d));
      expect(back.toJson(), d.toJson(), reason: d.kind.name);
    }

    test('login', () => roundTrip(const LoginData(
        username: 'ali',
        password: 'p w',
        urls: ['https://a.example', 'https://b.example'],
        totpUri: 'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP')));
    test('card', () => roundTrip(const CardData(
        holder: 'Ali Veli',
        number: '4242 4242 4242 4242',
        expiryMonth: 7,
        expiryYear: 2031,
        cvv: '123',
        pin: '4321')));
    test('note', () => roundTrip(const NoteData(body: 'satır1\nsatır2')));
    test('wifi', () => roundTrip(const WifiData(
        ssid: 'Ev', password: 'x', security: WifiSecurity.wpa3, hidden: true)));
    test('identity', () => roundTrip(IdentityData(
        firstName: 'Ayşe',
        lastName: 'Yılmaz',
        nationalId: '10000000146',
        birthDate: DateTime(1990, 5, 17),
        passportExpiry: DateTime(2032, 1, 2),
        phone: '+90 555',
        email: 'a@b.c',
        address: 'Ankara\nÇankaya')));
    test('apiKey', () => roundTrip(const ApiKeyData(
        key: 'k', secret: 's', endpoint: 'https://api.example')));
    test('sshKey', () => roundTrip(const SshKeyData(
        privateKey: '-----BEGIN-----\nabc\n-----END-----',
        publicKey: 'ssh-ed25519 AAAA',
        passphrase: 'pp',
        host: 'sunucu')));
    test('custom', () => roundTrip(const CustomData()));
  });

  test('alan anahtarları toJson anahtarlarıyla birebir aynıdır', () {
    const samples = <ItemData>[
      LoginData(username: 'a', password: 'b', urls: ['u'], totpUri: 't'),
      CardData(holder: 'a', number: '1', expiryMonth: 1, expiryYear: 2030),
      NoteData(body: 'b'),
      WifiData(ssid: 's', password: 'p'),
      ApiKeyData(key: 'k'),
      SshKeyData(privateKey: 'k'),
    ];
    for (final d in samples) {
      expect(dataToFields(d).keys.toSet(), d.toJson().keys.toSet(),
          reason: d.kind.name);
    }
  });

  test('boş/geçersiz sayı ve tarih null olur', () {
    final d = fieldsToData(ItemKind.card, {
      'number': '1',
      'expMonth': 'abc',
      'expYear': '',
    }) as CardData;
    expect(d.expiryMonth, isNull);
    expect(d.expiryYear, isNull);
    final i = fieldsToData(ItemKind.identity, {'birthDate': 'saçma'})
        as IdentityData;
    expect(i.birthDate, isNull);
  });

  test('splitLines boşları atar ve kırpar', () {
    expect(splitLines(' a \r\n\n b\n'), ['a', 'b']);
    expect(splitLines(''), isEmpty);
  });

  group('validateField', () {
    test('kart ayı/yılı', () {
      expect(validateField(ItemKind.card, 'expMonth', ''), isNull);
      expect(validateField(ItemKind.card, 'expMonth', '12'), isNull);
      expect(validateField(ItemKind.card, 'expMonth', '13'), isNotNull);
      expect(validateField(ItemKind.card, 'expMonth', '0'), isNotNull);
      expect(validateField(ItemKind.card, 'expYear', '2030'), isNull);
      expect(validateField(ItemKind.card, 'expYear', '30'), isNotNull);
      expect(validateField(ItemKind.card, 'expYear', '1999'), isNotNull);
    });

    test('totp adresi', () {
      expect(validateField(ItemKind.login, 'totp', ''), isNull);
      expect(
          validateField(ItemKind.login, 'totp',
              'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP'),
          isNull);
      expect(validateField(ItemKind.login, 'totp', 'merhaba'), isNotNull);
    });

    test('hata metni girilen değeri içermez', () {
      final msg = validateField(ItemKind.login, 'totp', 'GIZLI-DEGER-123')!;
      expect(msg.contains('GIZLI-DEGER-123'), isFalse);
    });
  });

  test('kart numarası uyarısı Luhn\'a bakar', () {
    expect(cardNumberLooksOff('4242 4242 4242 4242'), isFalse);
    expect(cardNumberLooksOff('4242 4242 4242 4241'), isTrue);
    expect(cardNumberLooksOff(''), isFalse);
  });
}
