// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import '../../core/util/base32.dart';
import '../totp/totp.dart';
import '../vault/domain/item_data.dart';
import '../vault/domain/vault_item.dart';
import 'csv_codec.dart';

enum ImportSource { bitwardenJson, bitwardenCsv, keepassCsv, chromeCsv, onePasswordCsv }

/// Satır numarası + mesaj. Mesajlar ASLA gizli değer içermez.
class ImportIssue {
  const ImportIssue(this.row, this.message);
  final int row;
  final String message;
}

class ParsedImport {
  ParsedImport(this.drafts, this.issues);
  final List<ItemDraft> drafts;
  final List<ImportIssue> issues;
}

abstract interface class ItemImporter {
  ParsedImport parse(String content);
  static ItemImporter forSource(ImportSource s) => switch (s) {
        ImportSource.bitwardenJson => BitwardenJsonImporter(),
        ImportSource.bitwardenCsv => CsvLoginImporter.bitwarden(),
        ImportSource.keepassCsv => CsvLoginImporter.keepass(),
        ImportSource.chromeCsv => CsvLoginImporter.chrome(),
        ImportSource.onePasswordCsv => CsvLoginImporter.onePassword(),
      };
}

/// TOTP ham değeri (otpauth URI veya Base32) -> otpauth URI; çözülemezse null.
String? normalizeTotp(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  try {
    if (t.toLowerCase().startsWith('otpauth://')) {
      return TotpConfig.parseUri(t).toUri();
    }
    return TotpConfig(secret: Base32.decode(t)).toUri();
  } on FormatException {
    return null;
  }
}

/// totp'yi LoginData alanına, olmazsa gizli özel alana koyar.
(String, List<CustomField>) _totpOrField(String raw) {
  if (raw.trim().isEmpty) return ('', const []);
  final n = normalizeTotp(raw);
  return n != null
      ? (n, const [])
      : ('', [CustomField('TOTP (içe aktarılan)', raw.trim(), CustomFieldType.hidden)]);
}

// ------------------------------------------------------------ Bitwarden JSON

class BitwardenJsonImporter implements ItemImporter {
  @override
  ParsedImport parse(String content) {
    final Object? root;
    try {
      root = jsonDecode(content);
    } on FormatException {
      throw const FormatException('geçersiz JSON');
    }
    if (root is! Map<String, Object?>) throw const FormatException('beklenmeyen JSON');
    if (root['encrypted'] == true) {
      throw const FormatException('şifreli Bitwarden dışa aktarımı desteklenmiyor');
    }
    final folders = <String, String>{};
    final fl = root['folders'];
    if (fl is List) {
      for (final f in fl.whereType<Map<String, Object?>>()) {
        if (f['id'] is String && f['name'] is String) {
          folders[f['id']! as String] = f['name']! as String;
        }
      }
    }
    final drafts = <ItemDraft>[];
    final issues = <ImportIssue>[];
    final items = root['items'];
    if (items is! List) throw const FormatException('items yok');
    var n = 0;
    for (final it in items) {
      n++;
      if (it is! Map<String, Object?>) {
        issues.add(ImportIssue(n, 'geçersiz kayıt'));
        continue;
      }
      final d = _item(it, folders);
      if (d == null) {
        issues.add(ImportIssue(n, 'desteklenmeyen tür: ${it['type']}'));
      } else {
        drafts.add(d);
      }
    }
    return ParsedImport(drafts, issues);
  }

  static String _s(Object? v) => v is String ? v : '';
  static Map<String, Object?> _m(Object? v) =>
      v is Map<String, Object?> ? v : const {};

  ItemDraft? _item(Map<String, Object?> it, Map<String, String> folders) {
    final type = it['type'];
    final fields = <CustomField>[
      for (final f in (it['fields'] is List ? it['fields']! as List : const [])
          .whereType<Map<String, Object?>>())
        CustomField(_s(f['name']), _s(f['value']),
            f['type'] == 1 ? CustomFieldType.hidden : CustomFieldType.text)
    ];
    final folder = it['folderId'] is String ? folders[it['folderId']] : null;
    ItemDraft mk(ItemData data, [List<CustomField> extra = const []]) =>
        ItemDraft(
          title: _s(it['name']),
          data: data,
          category: folder,
          isFavorite: it['favorite'] == true,
          notes: _s(it['notes']),
          customFields: [...fields, ...extra],
        );
    switch (type) {
      case 1:
        final l = _m(it['login']);
        final (totp, extra) = _totpOrField(_s(l['totp']));
        final uris = [
          for (final u in (l['uris'] is List ? l['uris']! as List : const [])
              .whereType<Map<String, Object?>>())
            if (_s(u['uri']).isNotEmpty) _s(u['uri'])
        ];
        return mk(
            LoginData(
                username: _s(l['username']),
                password: _s(l['password']),
                urls: uris,
                totpUri: totp),
            extra);
      case 2:
        return ItemDraft(
          title: _s(it['name']),
          data: NoteData(body: _s(it['notes'])),
          category: folder,
          isFavorite: it['favorite'] == true,
          customFields: fields,
        );
      case 3:
        final c = _m(it['card']);
        return mk(CardData(
          holder: _s(c['cardholderName']),
          number: _s(c['number']),
          expiryMonth: int.tryParse(_s(c['expMonth'])),
          expiryYear: int.tryParse(_s(c['expYear'])),
          cvv: _s(c['code']),
        ));
      case 4:
        final i = _m(it['identity']);
        final addr = [
          for (final k in ['address1', 'address2', 'address3', 'city', 'state', 'postalCode', 'country'])
            if (_s(i[k]).isNotEmpty) _s(i[k])
        ].join(', ');
        return mk(
            IdentityData(
              firstName: [_s(i['firstName']), _s(i['middleName'])]
                  .where((x) => x.isNotEmpty)
                  .join(' '),
              lastName: _s(i['lastName']),
              nationalId: _s(i['ssn']),
              passportNumber: _s(i['passportNumber']),
              phone: _s(i['phone']),
              email: _s(i['email']),
              address: addr,
            ),
            [
              if (_s(i['licenseNumber']).isNotEmpty)
                CustomField('Ehliyet no', _s(i['licenseNumber']), CustomFieldType.hidden),
              if (_s(i['company']).isNotEmpty) CustomField('Şirket', _s(i['company'])),
            ]);
    }
    return null;
  }
}

// ------------------------------------------------------------------- CSV

/// Başlık takma adlarıyla (alias) çalışan CSV içe aktarıcı: Bitwarden, KeePass(XC),
/// Chrome, 1Password. Başlıklar küçük harfe çevrilip kırpılır.
class CsvLoginImporter implements ItemImporter {
  CsvLoginImporter._(this._aliases, {this.splitUrls = false});

  factory CsvLoginImporter.bitwarden() => CsvLoginImporter._({
        'title': ['name'],
        'url': ['login_uri'],
        'username': ['login_username'],
        'password': ['login_password'],
        'notes': ['notes'],
        'totp': ['login_totp'],
        'category': ['folder'],
        'favorite': ['favorite'],
        'type': ['type'],
        'fields': ['fields'],
      }, splitUrls: true);

  factory CsvLoginImporter.keepass() => CsvLoginImporter._({
        'title': ['title', 'account'],
        'url': ['url', 'web site', 'website'],
        'username': ['username', 'login name'],
        'password': ['password'],
        'notes': ['notes', 'comments'],
        'totp': ['totp'],
        'category': ['group'],
      });

  factory CsvLoginImporter.chrome() => CsvLoginImporter._({
        'title': ['name'],
        'url': ['url'],
        'username': ['username'],
        'password': ['password'],
        'notes': ['note', 'notes'],
      });

  factory CsvLoginImporter.onePassword() => CsvLoginImporter._({
        'title': ['title', 'name'],
        'url': ['website', 'url', 'urls'],
        'username': ['username', 'login'],
        'password': ['password'],
        'notes': ['notes', 'note'],
        'totp': ['otpauth', 'one-time password', 'otp', 'totp'],
        'category': ['folder', 'vault'],
        'tags': ['tags'],
        'favorite': ['favorite'],
        'type': ['type'],
      });

  final Map<String, List<String>> _aliases;
  final bool splitUrls;

  @override
  ParsedImport parse(String content) {
    final rows = CsvCodec.parse(content);
    if (rows.isEmpty) throw const FormatException('boş CSV');
    final header = [for (final h in rows.first) h.trim().toLowerCase()];
    final idx = <String, int>{};
    _aliases.forEach((field, names) {
      for (final n in names) {
        final i = header.indexOf(n);
        if (i >= 0) {
          idx[field] = i;
          break;
        }
      }
    });
    if (!idx.containsKey('password') && !idx.containsKey('title')) {
      throw const FormatException('tanınmayan CSV başlığı');
    }
    String get(List<String> r, String f) {
      final i = idx[f];
      return (i == null || i >= r.length) ? '' : r[i];
    }

    final drafts = <ItemDraft>[];
    final issues = <ImportIssue>[];
    for (var n = 1; n < rows.length; n++) {
      final r = rows[n];
      final rowNo = n + 1;
      final type = get(r, 'type').toLowerCase();
      final notes = get(r, 'notes');
      final category = get(r, 'category').trim();
      final fav = const {'1', 'true', 'yes'}.contains(get(r, 'favorite').toLowerCase());
      final tags = [
        for (final t in get(r, 'tags').split(RegExp(r'[;,]')))
          if (t.trim().isNotEmpty) t.trim()
      ];
      if (type.contains('note')) {
        drafts.add(ItemDraft(
            title: get(r, 'title'),
            data: NoteData(body: notes),
            category: category.isEmpty ? null : category,
            isFavorite: fav,
            tags: tags));
        continue;
      }
      if (type.isNotEmpty && type != 'login') {
        issues.add(ImportIssue(rowNo, 'desteklenmeyen tür: $type'));
        continue;
      }
      final urlRaw = get(r, 'url');
      final urls = [
        for (final u in (splitUrls ? urlRaw.split(RegExp(r'[\r\n]+')) : [urlRaw]))
          if (u.trim().isNotEmpty) u.trim()
      ];
      final username = get(r, 'username');
      final password = get(r, 'password');
      var title = get(r, 'title').trim();
      if (title.isEmpty && username.isEmpty && password.isEmpty && urls.isEmpty) {
        issues.add(ImportIssue(rowNo, 'boş satır atlandı'));
        continue;
      }
      if (title.isEmpty) title = urls.isNotEmpty ? urls.first : username;
      final (totp, extra) = _totpOrField(get(r, 'totp'));
      final custom = <CustomField>[...extra];
      for (final line in get(r, 'fields').split(RegExp(r'[\r\n]+'))) {
        final c = line.indexOf(': ');
        if (c > 0) custom.add(CustomField(line.substring(0, c), line.substring(c + 2)));
      }
      drafts.add(ItemDraft(
        title: title,
        data: LoginData(username: username, password: password, urls: urls, totpUri: totp),
        category: category.isEmpty ? null : category,
        isFavorite: fav,
        tags: tags,
        notes: notes,
        customFields: custom,
      ));
    }
    return ParsedImport(drafts, issues);
  }
}
