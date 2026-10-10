// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../domain/item_kind.dart';

enum FieldType {
  text,
  secret,
  multiline,
  secretMultiline,
  date,
  wifiSecurity,
  toggle,
}

/// Bir form alanının tanımı. [key], `ItemData.toJson()` anahtarıyla aynıdır
/// (bkz. `item_form_codec.dart`).
class FieldSpec {
  const FieldSpec(
    this.key,
    this.label,
    this.type, {
    this.helper,
    this.keyboard,
    this.generator = false,
    this.lines = 3,
  });

  final String key;
  final String label;
  final FieldType type;
  final String? helper;
  final TextInputType? keyboard;

  /// Parola üreteci düğmesi + güç göstergesi.
  final bool generator;
  final int lines;
}

/// Türe özgü alanlar; `lib/features/vault/domain/item_data.dart` modellerine
/// birebir uyar.
List<FieldSpec> specsFor(ItemKind kind) => switch (kind) {
      ItemKind.login => const [
          FieldSpec('username', 'Kullanıcı adı', FieldType.text),
          FieldSpec('password', 'Parola', FieldType.secret, generator: true),
          FieldSpec('urls', 'Web adresleri', FieldType.multiline,
              helper: 'Her satıra bir adres.',
              keyboard: TextInputType.url,
              lines: 2),
          FieldSpec('totp', 'Tek kullanımlık kod (otpauth://…)',
              FieldType.secret,
              helper: 'İsteğe bağlı. Kodları kimlik doğrulayıcıdaki '
                  'otpauth:// adresinden alır.'),
        ],
      ItemKind.card => const [
          FieldSpec('holder', 'Kart sahibi', FieldType.text),
          FieldSpec('number', 'Kart numarası', FieldType.secret,
              keyboard: TextInputType.number),
          FieldSpec('expMonth', 'Son kullanma ayı (1-12)', FieldType.text,
              keyboard: TextInputType.number),
          FieldSpec('expYear', 'Son kullanma yılı (ör. 2030)', FieldType.text,
              keyboard: TextInputType.number),
          FieldSpec('cvv', 'CVV', FieldType.secret,
              keyboard: TextInputType.number),
          FieldSpec('pin', 'PIN', FieldType.secret,
              keyboard: TextInputType.number),
        ],
      ItemKind.note => const [
          FieldSpec('body', 'Not', FieldType.multiline, lines: 8),
        ],
      ItemKind.wifi => const [
          FieldSpec('ssid', 'Ağ adı (SSID)', FieldType.text),
          FieldSpec('password', 'Parola', FieldType.secret, generator: true),
          FieldSpec('security', 'Güvenlik türü', FieldType.wifiSecurity),
          FieldSpec('hidden', 'Gizli ağ', FieldType.toggle),
        ],
      ItemKind.identity => const [
          FieldSpec('firstName', 'Ad', FieldType.text),
          FieldSpec('lastName', 'Soyad', FieldType.text),
          FieldSpec('nationalId', 'Kimlik numarası', FieldType.secret,
              keyboard: TextInputType.number),
          FieldSpec('passportNumber', 'Pasaport numarası', FieldType.secret),
          FieldSpec('birthDate', 'Doğum tarihi', FieldType.date),
          FieldSpec('birthPlace', 'Doğum yeri', FieldType.text),
          FieldSpec('nationality', 'Uyruk', FieldType.text),
          FieldSpec('passportExpiry', 'Pasaport bitiş tarihi', FieldType.date),
          FieldSpec('phone', 'Telefon', FieldType.text,
              keyboard: TextInputType.phone),
          FieldSpec('email', 'E-posta', FieldType.text,
              keyboard: TextInputType.emailAddress),
          FieldSpec('address', 'Adres', FieldType.multiline, lines: 3),
        ],
      ItemKind.apiKey => const [
          FieldSpec('key', 'API anahtarı / belirteç', FieldType.secret),
          FieldSpec('secret', 'Gizli anahtar', FieldType.secret),
          FieldSpec('endpoint', 'Uç nokta adresi', FieldType.text,
              keyboard: TextInputType.url),
        ],
      ItemKind.sshKey => const [
          FieldSpec('privateKey', 'Özel anahtar', FieldType.secretMultiline),
          FieldSpec('publicKey', 'Açık anahtar', FieldType.multiline, lines: 2),
          FieldSpec('passphrase', 'Parola ifadesi', FieldType.secret),
          FieldSpec('host', 'Sunucu', FieldType.text),
        ],
      ItemKind.custom => const <FieldSpec>[],
    };

String wifiSecurityLabel(String name) => switch (name) {
      'open' => 'Açık (parolasız)',
      'wep' => 'WEP',
      'wpa' => 'WPA',
      'wpa2' => 'WPA2',
      'wpa3' => 'WPA3',
      'enterprise' => 'Kurumsal (802.1X)',
      _ => name,
    };

/// `yyyy-MM-dd` -> `gg.aa.yyyy` (boşsa boş).
String displayDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  return '${d.day.toString().padLeft(2, '0')}.'
      '${d.month.toString().padLeft(2, '0')}.${d.year}';
}
