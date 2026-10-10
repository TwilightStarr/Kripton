// SPDX-License-Identifier: Apache-2.0
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/app.dart';
import 'package:quanta/core/crypto/secret_key_codec.dart';
import 'package:quanta/core/security/common_passwords.dart';
import 'package:quanta/core/security/password_strength.dart';
import 'package:quanta/core/security/secret_bytes.dart';
import 'package:quanta/features/vault/application/password_providers.dart';
import 'package:quanta/features/vault/application/vault_controller.dart';
import 'package:quanta/features/vault/services/vault_providers.dart';
import 'package:quanta/features/vault/ui/reveal_screen.dart';

import 'fakes.dart';

void main() {
  late Directory tmp;
  late FakeManager fake;

  setUp(() => tmp = Directory.systemTemp.createTempSync('quanta_widget'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    bool exists = true,
    Duration autoLock = const Duration(minutes: 1),
  }) async {
    fake = FakeManager(tmp, exists: exists);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultManagerProvider.overrideWithValue(fake),
          autoLockTimeoutProvider.overrideWithValue(autoLock),
          passwordEstimatorProvider.overrideWithValue(
            PasswordStrengthEstimator(
              CommonPasswordList.fromLines(['password', 'qwerty123456']),
            ),
          ),
        ],
        child: const QuantaApp(),
      ),
    );
    await settle(tester);
  }

  Future<String> validKey(WidgetTester tester) async =>
      (await tester.runAsync(() => SecretKeyCodec.format(
          SecretBytes(Uint8List.fromList(List.filled(16, 7))))))!;

  Future<void> fillLock(
      WidgetTester tester, String password, String key) async {
    await tester.enterText(find.byType(TextFormField).at(0), password);
    await tester.enterText(find.byType(TextFormField).at(1), key);
  }

  testWidgets('kilit ekranı: yanlış girişte tek tip hata', (tester) async {
    await pumpApp(tester);
    expect(find.text('Kasa kilitli'), findsOneWidget);
    final key = await validKey(tester);

    await fillLock(tester, 'yanlis-parola-123', key);
    await tester.tap(find.text('Kasayı aç'));
    await settle(tester);

    expect(fake.unlockCalls, 1);
    expect(find.text('Kimlik doğrulama başarısız.'), findsOneWidget);
    expect(find.text('Kasa kilitli'), findsOneWidget);
  });

  testWidgets('geçersiz Secret Key biçimi: deneme yapılmaz', (tester) async {
    await pumpApp(tester);
    await fillLock(tester, 'bir-parola-12345', 'QNTA-YANLIS');
    await tester.tap(find.text('Kasayı aç'));
    await settle(tester);

    expect(fake.unlockCalls, 0);
    expect(find.textContaining('Secret Key biçimi geçersiz'), findsOneWidget);
  });

  testWidgets('arka plana geçince kilitlenir', (tester) async {
    await pumpApp(tester);
    fake.accept = true;
    final key = await validKey(tester);
    await fillLock(tester, 'dogru-parola-1234', key);
    await tester.tap(find.text('Kasayı aç'));
    await settle(tester);
    expect(find.text('Kasa'), findsOneWidget); // açık kasa ekranı

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle(tester);

    expect(fake.lockCalls, 1);
    expect(find.text('Kasa kilitli'), findsOneWidget);
  });

  testWidgets('hareketsizlik süresi dolunca kilitlenir', (tester) async {
    await pumpApp(tester, autoLock: const Duration(seconds: 5));
    fake.accept = true;
    final key = await validKey(tester);
    await fillLock(tester, 'dogru-parola-1234', key);
    await tester.tap(find.text('Kasayı aç'));
    await settle(tester);
    expect(find.text('Kasa'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(fake.lockCalls, 1);
    expect(find.text('Kasa kilitli'), findsOneWidget);
  });

  testWidgets('kasa oluştur: kısa parola ve eşleşmeme reddedilir',
      (tester) async {
    await pumpApp(tester, exists: false);
    await tester.tap(find.text('Kasa oluştur'));
    await tester.pump();

    await tester.enterText(find.byType(TextFormField).at(0), 'password');
    await tester.enterText(find.byType(TextFormField).at(1), 'password');
    await tester.tap(find.text('Kasayı oluştur'));
    await tester.pump();
    expect(find.textContaining('En az 12 karakter'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(0), 'k7#Vq9!zLm2\$Xw');
    await tester.enterText(find.byType(TextFormField).at(1), 'baska-bir-sey');
    await tester.tap(find.text('Kasayı oluştur'));
    await tester.pump();
    expect(find.text('Parolalar eşleşmiyor.'), findsOneWidget);
  });

  testWidgets('Secret Key ekranı: onay olmadan devam edilemez, kopyalama yok',
      (tester) async {
    fake = FakeManager(tmp);
    const secrets = RevealSecrets(
      secretKey: 'QNTA-AAAAAA-BBBBBB-CCCCCC-DDDDDD-EEEEEE',
      recoveryWords: ['alfa', 'bravo', 'charlie'],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultManagerProvider.overrideWithValue(fake)],
        child: const MaterialApp(home: RevealScreen(secrets: secrets)),
      ),
    );

    FilledButton button() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Devam'));
    expect(button().onPressed, isNull);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.textContaining('QNTA-AAAAAA'), findsOneWidget);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(button().onPressed, isNotNull);
  });

  testWidgets('onaylanmamış kurulum: sorulur; olduğu gibi bırakılırsa kilit',
      (tester) async {
    File('${tmp.path}/vault.setup_pending').writeAsStringSync('1');
    await pumpApp(tester);
    expect(find.text('Kurulum tamamlanmadı'), findsOneWidget);
    expect(find.text('Kasa kilitli'), findsNothing);

    await tester.tap(find.text('Kasayı olduğu gibi bırak'));
    await settle(tester);
    expect(find.text('Kasa kilitli'), findsOneWidget);
    expect(File('${tmp.path}/vault.setup_pending').existsSync(), isFalse);
  });

  testWidgets('onaylanmamış kurulum: silmek önce onay ister', (tester) async {
    File('${tmp.path}/vault.setup_pending').writeAsStringSync('1');
    await pumpApp(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Sil ve baştan başla'));
    await tester.pumpAndSettle();
    expect(find.text('Kasa silinsin mi?'), findsOneWidget);
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(find.text('Kurulum tamamlanmadı'), findsOneWidget);
  });

  testWidgets('ana parolamı unuttum: sıfırlama ekranı doğrulama yapar',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Ana parolamı unuttum'));
    await tester.pumpAndSettle();
    expect(find.text('Ana parolayı sıfırla'), findsOneWidget);

    await tester.ensureVisible(find.text('Parolayı sıfırla'));
    await tester.tap(find.text('Parolayı sıfırla'));
    await tester.pumpAndSettle();
    expect(find.text('Kurtarma ifadesi 24 kelime olmalı.'), findsOneWidget);
  });
}
