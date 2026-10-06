/// Uygulama açılırken hangi mod ekranının ilk görüneceği (Ayarlar → Açılış ekranı).
enum StartScreen { flow, chat, dev }

extension StartScreenX on StartScreen {
  String get label => switch (this) {
        StartScreen.flow => 'AI Akışı',
        StartScreen.chat => 'Sohbet',
        StartScreen.dev => 'Geliştirme Modu',
      };

  String get hint => switch (this) {
        StartScreen.flow => 'Çok ajanlı akış ana ekranı (varsayılan)',
        StartScreen.chat => 'Çevrimdışı AI ile kalıcı hafızalı sohbet',
        StartScreen.dev => 'Proje ZIP\'ini turlarla geliştirme',
      };
}

/// Kayıtlı kimlikten ([StartScreen.name]) açılış ekranı; bilinmiyorsa [StartScreen.flow].
StartScreen startScreenFromId(Object? id) {
  for (final s in StartScreen.values) {
    if (s.name == id) return s;
  }
  return StartScreen.flow;
}
