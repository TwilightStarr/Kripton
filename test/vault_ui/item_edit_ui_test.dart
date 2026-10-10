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
import 'package:quanta/features/vault/domain/item_data.dart';
import 'package:quanta/features/vault/domain/item_kind.dart';
import 'package:quanta/features/vault/domain/vault_item.dart';
import 'package:quanta/features/vault/services/vault_providers.dart';

import 'fakes.dart';

VaultItem fullLogin(String id, String title, {bool trashed = false}) =>
    VaultItem(
      id: id,
      title: title,
      data: const LoginData(username: 'ali', password: 'eski-parola-1'),
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      trashedAt: trashed ? DateTime.utc(2026, 1, 2) : null,
    );

void main() {
  late Directory tmp;
  late FakeManager fake;

  setUp(() => tmp = Directory.systemTemp.createTempSync('quanta_edit_ui'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump();
  }

  Future<void> openVault(WidgetTester tester, FakeRepo repo) async {
    fake = FakeManager(tmp, repo: repo)..accept = true;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultManagerProvider.overrideWithValue(fake),
        passwordEstimatorProvider.overrideWithValue(
          PasswordStrengthEstimator(CommonPasswordList.fromLines(['password'])),
        ),
      ],
      child: const QuantaApp(),
    ));
    await settle(tester);
    final key = (await tester.runAsync(() => SecretKeyCodec.format(
        SecretBytes(Uint8List.fromList(List.filled(16, 7))))))!;
    await tester.enterText(
        find.byType(TextFormField).at(0), 'dogru-parola-1234');
    await tester.enterText(find.byType(TextFormField).at(1), key);
    await tester.tap(find.text('Kasayı aç'));
    await settle(tester);
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  Future<void> startNewLogin(WidgetTester tester) async {
    await tester.tap(find.text('Kayıt ekle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Giriş').last);
    await tester.pumpAndSettle();
    expect(find.text('Yeni Giriş'), findsOneWidget);
  }

  testWidgets('yeni giriş kaydı eklenir', (tester) async {
    final repo = FakeRepo(const []);
    await openVault(tester, repo);

    await startNewLogin(tester);
    await tester.enterText(field('Başlık'), 'Github');
    await tester.enterText(field('Kullanıcı adı'), 'ali');
    await tester.enterText(field('Parola'), 'k7#Vq9!zLm2\$Xw');
    await tester.tap(find.byTooltip('Kaydet'));
    await tester.pumpAndSettle();

    expect(repo.created, hasLength(1));
    final d = repo.created.single;
    expect(d.title, 'Github');
    expect(d.kind, ItemKind.login);
    expect((d.data as LoginData).username, 'ali');
    expect((d.data as LoginData).password, 'k7#Vq9!zLm2\$Xw');
    // Liste ekranına dönülür ve yeni kayıt görünür.
    expect(find.text('Yeni Giriş'), findsNothing);
    expect(find.text('Github'), findsOneWidget);
  });

  testWidgets('boş başlık kaydedilmez', (tester) async {
    final repo = FakeRepo(const []);
    await openVault(tester, repo);
    await startNewLogin(tester);

    await tester.tap(find.byTooltip('Kaydet'));
    await tester.pumpAndSettle();

    expect(find.text('Başlık gerekli.'), findsOneWidget);
    expect(repo.created, isEmpty);
  });

  testWidgets('kart: geçersiz ay kaydı engeller', (tester) async {
    final repo = FakeRepo(const []);
    await openVault(tester, repo);
    await tester.tap(find.text('Kayıt ekle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kart').last);
    await tester.pumpAndSettle();

    await tester.enterText(field('Başlık'), 'Banka');
    await tester.enterText(field('Son kullanma ayı (1-12)'), '13');
    await tester.tap(find.byTooltip('Kaydet'));
    await tester.pumpAndSettle();

    expect(find.text('Ay 1-12 arasında olmalı.'), findsOneWidget);
    expect(repo.created, isEmpty);
  });

  testWidgets('değişiklikle geri: onay sorulur, atılırsa kayıt yazılmaz',
      (tester) async {
    final repo = FakeRepo(const []);
    await openVault(tester, repo);
    await startNewLogin(tester);

    await tester.enterText(field('Başlık'), 'Yarım kalan');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Değişiklikler atılsın mı?'), findsOneWidget);

    // Devam et: ekran açık kalır.
    await tester.tap(find.text('Düzenlemeye devam et'));
    await tester.pumpAndSettle();
    expect(find.text('Yeni Giriş'), findsOneWidget);

    // At: listeye dönülür.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Değişiklikleri at'));
    await tester.pumpAndSettle();
    expect(find.text('Yeni Giriş'), findsNothing);
    expect(repo.created, isEmpty);
  });

  testWidgets('değişiklik yoksa geri onaysız kapanır', (tester) async {
    await openVault(tester, FakeRepo(const []));
    await startNewLogin(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Değişiklikler atılsın mı?'), findsNothing);
    expect(find.text('Yeni Giriş'), findsNothing);
  });

  testWidgets('kaydetme hatasında form korunur', (tester) async {
    final repo = FakeRepo(const [])..failWrites = true;
    await openVault(tester, repo);
    await startNewLogin(tester);

    await tester.enterText(field('Başlık'), 'Kaybolmasın');
    await tester.tap(find.byTooltip('Kaydet'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Kaydedilemedi'), findsOneWidget);
    expect(find.text('Yeni Giriş'), findsOneWidget);
    expect(find.text('Kaybolmasın'), findsOneWidget); // alan dolu kaldı

    repo.failWrites = false;
    await tester.tap(find.byTooltip('Kaydet'));
    await tester.pumpAndSettle();
    expect(repo.created.single.title, 'Kaybolmasın');
  });

  testWidgets('mevcut kayıt düzenlenir', (tester) async {
    final repo = FakeRepo(const [], full: [fullLogin('a1', 'Github')]);
    await openVault(tester, repo);

    await tester.tap(find.text('Github'));
    await tester.pumpAndSettle();
    expect(find.text('Kaydı düzenle'), findsOneWidget);
    expect(find.text('Github'), findsWidgets);

    await tester.enterText(field('Başlık'), 'Github (iş)');
    await tester.tap(find.byTooltip('Kaydet'));
    await tester.pumpAndSettle();

    expect(repo.updated.single.title, 'Github (iş)');
    expect((repo.updated.single.data as LoginData).username, 'ali');
    expect(find.text('Github (iş)'), findsOneWidget);
  });

  testWidgets('düzenleme ekranından çöpe taşınır', (tester) async {
    final repo = FakeRepo(const [], full: [fullLogin('a1', 'Github')]);
    await openVault(tester, repo);

    await tester.tap(find.text('Github'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Çöpe taşı'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Çöpe taşı'));
    await tester.pumpAndSettle();

    expect(repo.trashedIds, ['a1']);
    expect(find.text('Github'), findsNothing); // aktif listeden kalktı
  });

  testWidgets('çöp kutusu: geri yükle ve onaylı kalıcı silme', (tester) async {
    final repo = FakeRepo(const [], full: [
      fullLogin('t1', 'Eski bir', trashed: true),
      fullLogin('t2', 'Eski iki', trashed: true),
    ]);
    await openVault(tester, repo);
    await tester.tap(find.byTooltip('Çöp kutusu'));
    await tester.pumpAndSettle();

    // Geri yükle
    await tester.tap(find.text('Eski bir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Geri yükle'));
    await tester.pumpAndSettle();
    expect(repo.restoredIds, ['t1']);

    // Kalıcı sil: önce vazgeç, sonra onayla
    await tester.tap(find.text('Eski iki'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kalıcı olarak sil'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(repo.deletedIds, isEmpty);

    await tester.tap(find.text('Eski iki'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kalıcı olarak sil'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Kalıcı olarak sil'));
    await tester.pumpAndSettle();
    expect(repo.deletedIds, ['t2']);
  });

  testWidgets('çöp kutusunu boşalt onay ister', (tester) async {
    final repo = FakeRepo(const [],
        full: [fullLogin('t1', 'Eski', trashed: true)]);
    await openVault(tester, repo);
    await tester.tap(find.byTooltip('Çöp kutusu'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Çöp kutusunu boşalt'));
    await tester.pumpAndSettle();
    expect(repo.emptied, 0);
    await tester
        .tap(find.widgetWithText(FilledButton, 'Çöp kutusunu boşalt'));
    await tester.pumpAndSettle();
    expect(repo.emptied, 1);
  });

  testWidgets('parola üreteci değeri forma yazar', (tester) async {
    final repo = FakeRepo(const []);
    await openVault(tester, repo);
    await startNewLogin(tester);

    await tester.tap(find.byTooltip('Parola üret'));
    await tester.pumpAndSettle();
    expect(find.text('Parola üret'), findsOneWidget); // sayfa başlığı
    await tester.tap(find.text('Kullan'));
    await tester.pumpAndSettle();

    await tester.enterText(field('Başlık'), 'Üretilmiş');
    await tester.tap(find.byTooltip('Kaydet'));
    await tester.pumpAndSettle();
    final pw = (repo.created.single.data as LoginData).password;
    expect(pw.length, 20); // varsayılan rastgele uzunluk
  });

  testWidgets('kilitlenince açık düzenleme ekranı kapanır', (tester) async {
    await openVault(tester, FakeRepo(const []));
    await startNewLogin(tester);
    await tester.enterText(field('Başlık'), 'Gizli taslak');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle(tester);
    await tester.pumpAndSettle();

    expect(find.text('Kasa kilitli'), findsOneWidget);
    expect(find.text('Gizli taslak'), findsNothing);
    expect(find.text('Yeni Giriş'), findsNothing);
  });
}
