// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/features/import_export/csv_codec.dart';
import 'package:quanta/features/import_export/importers.dart';
import 'package:quanta/features/vault/domain/item_data.dart';
import 'package:quanta/features/vault/domain/vault_item.dart';

String fx(String n) => File('test/fixtures/import/$n').readAsStringSync();
LoginData login(ItemDraft d) => d.data as LoginData;

void main() {
  group('CSV kodeği', () {
    test('tırnak, virgül, gömülü satır sonu, "" kaçışı, CRLF, BOM', () {
      final rows = CsvCodec.parse('\uFEFFa,b,c\r\n"x,1","y\n2","z""q"\r\n\r\nson,,');
      expect(rows, [
        ['a', 'b', 'c'],
        ['x,1', 'y\n2', 'z"q'],
        ['son', '', ''],
      ]);
    });
    test('encode -> parse gidiş-dönüş', () {
      final rows = [
        ['a', 'b,c', 'd"e', 'f\ng', ' boşluk '],
        ['', 'x', '', '', ''],
      ];
      expect(CsvCodec.parse(CsvCodec.encode(rows)), rows);
    });
    test('kapanmamış tırnak hata', () {
      expect(() => CsvCodec.parse('a,"b'), throwsFormatException);
    });
  });

  test('Bitwarden JSON', () {
    final p = BitwardenJsonImporter().parse(fx('bitwarden.json'));
    expect(p.drafts.length, 4);
    expect(p.issues.single.row, 5); // bilinmeyen tür
    final gh = p.drafts[0];
    expect(gh.title, 'GitHub');
    expect(gh.category, 'İş');
    expect(gh.isFavorite, isTrue);
    expect(gh.notes, 'not1');
    expect(login(gh).username, 'ali');
    expect(login(gh).password, 's3cret!');
    expect(login(gh).urls, ['https://github.com', 'https://gist.github.com']);
    expect(login(gh).totpUri, startsWith('otpauth://totp/'));
    expect(gh.customFields.map((f) => f.type), [CustomFieldType.text, CustomFieldType.hidden]);
    expect((p.drafts[1].data as NoteData).body, 'satır1\nsatır2');
    final card = p.drafts[2].data as CardData;
    expect([card.number, card.expiryMonth, card.expiryYear, card.cvv], ['4111111111111111', 12, 2030, '123']);
    expect((p.drafts[3].data as IdentityData).nationalId, '10000000146');
  });

  test('Bitwarden JSON: şifreli dışa aktarım ve bozuk JSON reddedilir', () {
    expect(() => BitwardenJsonImporter().parse('{"encrypted":true,"items":[]}'), throwsFormatException);
    expect(() => BitwardenJsonImporter().parse('{bozuk'), throwsFormatException);
  });

  test('Bitwarden CSV', () {
    final p = CsvLoginImporter.bitwarden().parse(fx('bitwarden.csv'));
    expect(p.drafts.length, 2);
    final a = p.drafts[0];
    expect(a.title, 'Örnek, Site');
    expect(a.category, 'İş');
    expect(a.isFavorite, isTrue);
    expect(a.notes, 'çok\nsatırlı not');
    expect(login(a).password, 'p"ass');
    expect(login(a).totpUri, startsWith('otpauth://totp/'));
    expect(a.customFields.single.name, 'Hesap');
    expect(p.drafts[1].data, isA<NoteData>());
  });

  test('KeePass CSV (KeePassXC ve eski biçim)', () {
    final p = CsvLoginImporter.keepass().parse(fx('keepass.csv'));
    expect(p.drafts.length, 1);
    expect(p.issues.length, 1); // boş satır
    expect(p.drafts.single.category, 'Genel/Banka');
    expect(login(p.drafts.single).password, 'pw1');
    final old = CsvLoginImporter.keepass().parse(fx('keepass_legacy.csv'));
    expect(old.drafts.single.title, 'Forum');
    expect(login(old.drafts.single).username, 'kullanici');
    expect(login(old.drafts.single).urls, ['http://forum.example']);
    expect(old.drafts.single.notes, 'yorum');
  });

  test('Chrome CSV (yeni ve eski)', () {
    final p = CsvLoginImporter.chrome().parse(fx('chrome.csv'));
    expect(p.drafts.length, 2);
    expect(login(p.drafts[1]).username, 'veli');
    expect(p.drafts[1].notes, 'not, virgüllü');
    final old = CsvLoginImporter.chrome().parse(fx('chrome_old.csv'));
    expect(login(old.drafts.single).password, 'y');
  });

  test('1Password CSV', () {
    final p = CsvLoginImporter.onePassword().parse(fx('1password.csv'));
    expect(p.drafts.length, 2); // login + secure note
    expect(p.issues.single.message, contains('credit card'));
    final n = p.drafts[0];
    expect(n.title, 'Netflix');
    expect(n.isFavorite, isTrue);
    expect(n.tags, ['aile', 'eğlence']);
    expect(login(n).urls, ['https://netflix.com']);
    expect((p.drafts[1].data as NoteData).body, 'içerik');
  });

  test('tanınmayan başlık reddedilir; hata mesajı sır içermez', () {
    expect(() => CsvLoginImporter.chrome().parse('foo,bar\n1,2'), throwsFormatException);
    final p = CsvLoginImporter.onePassword().parse(fx('1password.csv'));
    for (final i in p.issues) {
      expect(i.message.contains('pw!'), isFalse);
    }
  });

  test('normalizeTotp', () {
    expect(normalizeTotp('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'), startsWith('otpauth://totp/'));
    expect(normalizeTotp('steam://xyz'), isNull);
    expect(normalizeTotp(''), isNull);
  });
}
