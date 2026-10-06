import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/app_controller.dart';
import 'package:kripton_ai/application/settings_controller.dart';
import 'package:kripton_ai/core/theme.dart';
import 'package:kripton_ai/domain/entities.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => KPalette.current = KPalette.gece);

  group('tema paletleri', () {
    test('kimlikler benzersiz, bilinmeyen kimlik varsayılana düşer', () {
      final ids = KPalette.all.map((p) => p.id).toSet();
      expect(ids.length, KPalette.all.length);
      expect(KPalette.all.length, greaterThanOrEqualTo(5));
      expect(KPalette.byId('yok_boyle_bir_tema'), same(KPalette.gece));
      expect(KPalette.byId(null), same(KPalette.gece));
    });

    test('her palet için ThemeData üretilir ve parlaklık eşleşir', () {
      for (final p in KPalette.all) {
        final t = buildTheme(p);
        expect(t.brightness, p.brightness, reason: p.id);
        expect(t.scaffoldBackgroundColor, p.bg, reason: p.id);
        expect(t.colorScheme.primary, p.accent, reason: p.id);
      }
    });

    test('KColors geçerli paleti okur', () {
      KPalette.current = KPalette.amoled;
      expect(KColors.bg, const Color(0xFF000000));
      KPalette.current = KPalette.gunIsigi;
      expect(KColors.card, const Color(0xFFFFFFFF));
    });

    test('ayarlar JSON gidiş-dönüş; bozuk tema kimliği varsayılana döner', () {
      const s = AppSettings(themeId: 'orman', liteOnStart: true);
      final back = AppSettings.fromJson(s.toJson());
      expect(back.themeId, 'orman');
      expect(back.liteOnStart, isTrue);
      expect(AppSettings.fromJson({'theme': 'x', 'liteOnStart': 1}).themeId, 'gece');
      expect(AppSettings.fromJson({}).liteOnStart, isFalse);
    });

    test('setTheme paleti hemen günceller', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(settingsProvider.notifier).setTheme('mor_gece');
      expect(KPalette.current.id, 'mor_gece');
      expect(c.read(settingsProvider).themeId, 'mor_gece');
    });
  });

  group('sade mod', () {
    late FakeEngine engine;
    late ProviderContainer container;

    Future<AppController> setUp0(FakeEngine e, {bool liteOnStart = false}) async {
      engine = e;
      final model = await File('${Directory.systemTemp.path}/kripton_fake_model.gguf').writeAsString('x');
      container = ProviderContainer(overrides: [
        engineProvider.overrideWithValue(engine),
        fileServiceProvider.overrideWithValue(FakeFiles()),
        storageProvider.overrideWithValue(FakeStorage([testWorkflow()], model.path)),
        settingsProvider.overrideWith(() => SettingsController(AppSettings(liteOnStart: liteOnStart))),
      ]);
      addTearDown(container.dispose);
      container.read(appProvider);
      await waitFor(() => container.read(appProvider).loaded);
      return container.read(appProvider.notifier);
    }

    test('liteOnStart açıkken akış sade başlar, canlı metin tutulmaz, bitince normale döner', () async {
      final c = await setUp0(FakeEngine(), liteOnStart: true);
      final run = c.start();
      expect(container.read(appProvider).lite, isTrue);
      await run.timeout(const Duration(seconds: 5));

      final s = container.read(appProvider);
      expect(s.artifact, isNotNull, reason: 'sade mod çıktıyı etkilemez');
      expect(s.running, isFalse);
      expect(s.lite, isFalse, reason: 'akış bitince sade mod kapanır');
      expect(container.read(liveTokensProvider), isEmpty);
    });

    test('kapalıyken akış normal başlar ve canlı metin birikir', () async {
      final c = await setUp0(FakeEngine(hangOnCall: 1));
      final run = c.start();
      expect(container.read(appProvider).lite, isFalse);
      await waitFor(() => engine.generateCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(container.read(liveTokensProvider), isNotEmpty);
      c.cancel();
      await run.timeout(const Duration(seconds: 3));
    });

    test('akış sürerken setLite(true) canlı metni boşaltır, setLite(false) geri döner', () async {
      final c = await setUp0(FakeEngine(hangOnCall: 2));
      final run = c.start();
      await waitFor(() => engine.generateCalls == 2);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(container.read(liveTokensProvider), isNotEmpty);

      c.setLite(true);
      expect(container.read(appProvider).lite, isTrue);
      expect(container.read(liveTokensProvider), isEmpty);
      expect(container.read(appProvider).running, isTrue, reason: 'akış kesilmez');

      c.setLite(false);
      expect(container.read(appProvider).lite, isFalse);

      c.cancel();
      await run.timeout(const Duration(seconds: 3));
      expect(container.read(appProvider).running, isFalse);
    });

    test('sade modda ekran günlüğü en fazla 40 kayıtla sınırlanır', () async {
      final c = await setUp0(FakeEngine(hangOnCall: 1), liteOnStart: true);
      final run = c.start();
      await waitFor(() => engine.generateCalls == 1);
      expect(container.read(appProvider).logs.length, lessThanOrEqualTo(40));
      c.cancel();
      await run.timeout(const Duration(seconds: 3));
    });
  });
}
