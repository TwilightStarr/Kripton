import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/storage.dart';
import '../domain/start_screen.dart';
import 'app_controller.dart' show storageProvider;

/// Kalıcı görünüm / performans tercihleri.
class AppSettings {
  /// Seçili tema paleti ([KPalette.id]).
  final String themeId;

  /// Açıksa AI akışı başlayınca çalışırken sade ekran açılır (daha az RAM/CPU).
  /// Akış sırasında istenildiği an açılıp kapatılabilir.
  final bool liteOnStart;

  /// Uygulama açılırken ilk görünen mod ekranı (Ayarlar → Açılış ekranı).
  final StartScreen startScreen;

  /// Sohbet modunda seçilen model ([GgufModel.id]); null = cihaz varsayılanı.
  final String? chatModelId;

  /// Açıksa sohbet açılınca model ilk mesajı beklemeden arka planda hazırlanır.
  /// Düşük RAM'li telefonlarda kapatılabilir (model ilk mesajda yüklenir).
  final bool chatAutoPrepare;

  const AppSettings({
    this.themeId = 'gece',
    this.liteOnStart = false,
    this.startScreen = StartScreen.flow,
    this.chatModelId,
    this.chatAutoPrepare = true,
  });

  AppSettings copyWith({
    String? themeId,
    bool? liteOnStart,
    StartScreen? startScreen,
    String? chatModelId,
    bool? chatAutoPrepare,
  }) => AppSettings(
        themeId: themeId ?? this.themeId,
        liteOnStart: liteOnStart ?? this.liteOnStart,
        startScreen: startScreen ?? this.startScreen,
        chatModelId: chatModelId ?? this.chatModelId,
        chatAutoPrepare: chatAutoPrepare ?? this.chatAutoPrepare,
      );

  Map<String, dynamic> toJson() => {
        'theme': themeId,
        'liteOnStart': liteOnStart,
        'startScreen': startScreen.name,
        if (chatModelId != null) 'chatModel': chatModelId,
        'chatAutoPrepare': chatAutoPrepare,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        themeId: KPalette.byId(j['theme'] as String?).id,
        liteOnStart: j['liteOnStart'] == true,
        startScreen: startScreenFromId(j['startScreen']),
        chatModelId: j['chatModel'] is String ? j['chatModel'] as String : null,
        chatAutoPrepare: j['chatAutoPrepare'] != false,
      );

  /// Açılışta (runApp'ten önce) okunur; hata olursa varsayılanlar döner.
  static Future<AppSettings> load(Storage st) async {
    try {
      return AppSettings.fromJson(await st.loadSettings());
    } catch (_) {
      return const AppSettings();
    }
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class SettingsController extends Notifier<AppSettings> {
  SettingsController([this._initial]);

  final AppSettings? _initial;

  @override
  AppSettings build() {
    final s = _initial ?? AppSettings(themeId: KPalette.current.id);
    KPalette.current = KPalette.byId(s.themeId);
    return s;
  }

  void setTheme(String id) {
    final p = KPalette.byId(id);
    if (state.themeId == p.id) return;
    KPalette.current = p; // önce palet, sonra durum: dinleyenler yeni renkleri okur
    state = state.copyWith(themeId: p.id);
    _save();
  }

  void setLiteOnStart(bool v) {
    if (state.liteOnStart == v) return;
    state = state.copyWith(liteOnStart: v);
    _save();
  }

  void setStartScreen(StartScreen v) {
    if (state.startScreen == v) return;
    state = state.copyWith(startScreen: v);
    _save();
  }

  void setChatModel(String id) {
    if (state.chatModelId == id) return;
    state = state.copyWith(chatModelId: id);
    _save();
  }

  void setChatAutoPrepare(bool v) {
    if (state.chatAutoPrepare == v) return;
    state = state.copyWith(chatAutoPrepare: v);
    _save();
  }

  Future<void> _save() async {
    try {
      await ref.read(storageProvider).saveSettings(state.toJson());
    } catch (_) {}
  }
}
