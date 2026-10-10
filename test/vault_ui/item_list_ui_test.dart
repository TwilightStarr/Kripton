// SPDX-License-Identifier: Apache-2.0
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quanta/app.dart';
import 'package:quanta/core/crypto/secret_key_codec.dart';
import 'package:quanta/core/security/secret_bytes.dart';
import 'package:quanta/features/vault/domain/item_kind.dart';
import 'package:quanta/features/vault/services/vault_providers.dart';

import 'fakes.dart';

void main() {
  late Directory tmp;
  late FakeManager fake;

  setUp(() => tmp = Directory.systemTemp.createTempSync('quanta_list_ui'));
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
      overrides: [vaultManagerProvider.overrideWithValue(fake)],
      child: const QuantaApp(),
    ));
    await settle(tester);
    final key = (await tester.runAsync(() => SecretKeyCodec.format(
        SecretBytes(Uint8List.fromList(List.filled(16, 7))))))!;
    await tester.enterText(find.byType(TextFormField).at(0), 'dogru-parola-1234');
    await tester.enterText(find.byType(TextFormField).at(1), key);
    await tester.tap(find.text('Kasayı aç'));
    await settle(tester);
  }

  testWidgets('boş kasa: boş durum mesajı', (tester) async {
    await openVault(tester, FakeRepo(const []));
    expect(find.textContaining('Kasanız boş'), findsOneWidget);
  });

  testWidgets('kayıtlar listelenir, arama daraltır', (tester) async {
    await openVault(
      tester,
      FakeRepo([
        summary('1', 'Github', subtitle: 'ali', favorite: true),
        summary('2', 'Banka', kind: ItemKind.card),
      ]),
    );
    expect(find.text('Github'), findsOneWidget);
    expect(find.text('Banka'), findsOneWidget);
    expect(find.text('ali'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Ara'), 'bank');
    await tester.pump(const Duration(milliseconds: 200));
    await settle(tester);
    expect(find.text('Banka'), findsOneWidget);
    expect(find.text('Github'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Ara'), 'yokki');
    await tester.pump(const Duration(milliseconds: 200));
    await settle(tester);
    expect(find.text('Eşleşen kayıt yok.'), findsOneWidget);
  });

  testWidgets('tür çipi filtreler; çöp kutusu görünümü', (tester) async {
    await openVault(
      tester,
      FakeRepo([
        summary('1', 'Github'),
        summary('2', 'Banka', kind: ItemKind.card),
        summary('3', 'Eski kayıt', trashed: true),
      ]),
    );
    expect(find.text('Eski kayıt'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, 'Kart'));
    await settle(tester);
    expect(find.text('Banka'), findsOneWidget);
    expect(find.text('Github'), findsNothing);

    await tester.tap(find.byTooltip('Çöp kutusu'));
    await settle(tester);
    expect(find.text('Çöp kutusu'), findsOneWidget); // başlık
  });

  testWidgets('liste hatasında tekrar dene gösterilir', (tester) async {
    final repo = FakeRepo([summary('1', 'Github')])..failList = true;
    await openVault(tester, repo);
    expect(find.text('Liste yüklenemedi.'), findsOneWidget);

    repo.failList = false;
    await tester.tap(find.text('Tekrar dene'));
    await settle(tester);
    expect(find.text('Github'), findsOneWidget);
  });

  testWidgets('kilitlenince liste ve arama metni ekrandan kalkar',
      (tester) async {
    await openVault(tester, FakeRepo([summary('1', 'Gizli Başlık')]));
    await tester.enterText(find.widgetWithText(TextField, 'Ara'), 'gizli');
    await tester.pump(const Duration(milliseconds: 200));
    await settle(tester);

    await tester.tap(find.byTooltip('Kilitle'));
    await settle(tester);

    expect(find.text('Kasa kilitli'), findsOneWidget);
    expect(find.text('Gizli Başlık'), findsNothing);
    expect(find.text('gizli'), findsNothing);
    expect(fake.lockCalls, 1);
  });
}
