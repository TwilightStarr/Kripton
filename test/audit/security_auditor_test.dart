// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/core/crypto/csprng.dart';
import 'package:quanta/core/crypto/vault_keys.dart';
import 'package:quanta/core/security/common_passwords.dart';
import 'package:quanta/core/security/password_strength.dart';
import 'package:quanta/features/audit/security_auditor.dart';
import 'package:quanta/features/audit/two_factor_directory.dart';
import 'package:quanta/features/vault/domain/item_data.dart';
import 'package:quanta/features/vault/domain/vault_item.dart';

final now = DateTime.utc(2026, 6, 1);

VaultItem login(String id, String pw,
        {String user = 'u', String url = 'https://rastgele.example', String totp = '', DateTime? changed, DateTime? trashed, String title = 'T'}) =>
    VaultItem(
        id: id,
        title: title,
        data: LoginData(username: user, password: pw, urls: [url], totpUri: totp),
        createdAt: changed ?? now,
        updatedAt: now,
        secretChangedAt: changed ?? now,
        trashedAt: trashed);

void main() {
  late SecurityAuditor auditor;
  late PasswordFingerprinter fp;

  setUp(() async {
    final common = CommonPasswordList.fromLines(['password', '123456', 'qwerty', 'letmein']);
    auditor = SecurityAuditor(PasswordStrengthEstimator(common));
    fp = PasswordFingerprinter(await VaultKeys.derive(Csprng().bytes(32)));
  });

  Future<AuditReport> run(List<VaultItem> items) =>
      auditor.run(items: Stream.fromIterable(items), fingerprints: fp, now: now);

  const strong1 = 'Xq7#vB2!nLp9@zRt4';
  const strong2 = 'mK8\$wE3&hYc5^uJd1';

  test('temiz kasa 100 puan', () async {
    final r = await run([login('1', strong1), login('2', strong2)]);
    expect(r.issues, isEmpty);
    expect(r.score, 100);
    expect(r.totalItems, 2);
  });

  test('yaygın ve zayıf parola', () async {
    final r = await run([login('1', 'password'), login('2', 'abc123'), login('3', strong1)]);
    expect(r.ofType(AuditIssueType.commonPassword).map((e) => e.itemId), ['1']);
    expect(r.ofType(AuditIssueType.weakPassword).map((e) => e.itemId), contains('2'));
    expect(r.score, lessThan(100));
  });

  test('tekrar kullanılan parola, detay parola içermez', () async {
    final r = await run([login('1', strong1), login('2', strong1), login('3', strong2)]);
    expect(r.ofType(AuditIssueType.reusedPassword).map((e) => e.itemId).toSet(), {'1', '2'});
    for (final i in r.issues) {
      expect(i.detail.contains(strong1), isFalse);
    }
  });

  test('eski parola (>1 yıl)', () async {
    final r = await run([
      login('old', strong1, changed: now.subtract(const Duration(days: 366))),
      login('new', strong2, changed: now.subtract(const Duration(days: 300))),
    ]);
    expect(r.ofType(AuditIssueType.oldPassword).map((e) => e.itemId), ['old']);
  });

  test('TOTP\'siz ama destekleyen site', () async {
    final r = await run([
      login('gh', strong1, url: 'https://github.com/login'),
      login('gh2', strong2, url: 'https://gist.github.com',
          totp: 'otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'),
      login('x', 'Zt5%pQ8&dFh2*Lm7', url: 'https://bilinmeyen-site.example'),
    ]);
    expect(r.ofType(AuditIssueType.missingTotp).map((e) => e.itemId), ['gh']);
  });

  test('boş alanlı kayıtlar', () async {
    final r = await run([
      login('a', ''),
      VaultItem(id: 'n', title: '', data: const NoteData(), createdAt: now, updatedAt: now),
      VaultItem(id: 'w', title: 'ag', data: const WifiData(ssid: 'x', security: WifiSecurity.open), createdAt: now, updatedAt: now),
    ]);
    final ids = r.ofType(AuditIssueType.emptyFields).map((e) => e.itemId).toSet();
    expect(ids, {'a', 'n'}); // açık Wi-Fi'da parola boş olabilir
  });

  test('çöp kutusundakiler denetlenmez', () async {
    final r = await run([login('1', 'password', trashed: now), login('2', strong1)]);
    expect(r.totalItems, 1);
    expect(r.issues, isEmpty);
  });

  test('skor aralığı 0..100 ve kötü kasa düşük', () async {
    final r = await run([for (var i = 0; i < 5; i++) login('$i', 'password')]);
    expect(r.score, inInclusiveRange(0, 100));
    expect(r.score, lessThan(30));
    expect((await run([])).score, 100);
  });

  test('2FA dizini alt alan adı eşleşmesi', () {
    const d = TwoFactorDirectory();
    expect(d.supports('https://accounts.google.com'), isTrue);
    expect(d.supports('notgithub.com'), isFalse);
    expect(d.withExtra(['kurum.example']).supports('https://sso.kurum.example'), isTrue);
  });
}
