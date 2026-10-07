// Değişiklik: YENİ — sohbet yazı animasyonu modu (kapalı / kelime / harf).

/// Sohbette yanıtın ekrana yazılış biçimi (Ayarlar → "Yazı animasyonu").
enum ChatTypeMode {
  off('Kapalı'),
  word('Kelime'),
  letter('Harf');

  const ChatTypeMode(this.label);

  /// Menüde görünen ad.
  final String label;

  /// Kayıtlı değerden okur; bilinmeyen / eski kayıtlarda varsayılan (harf).
  static ChatTypeMode fromId(Object? id) {
    for (final m in values) {
      if (m.name == id) return m;
    }
    return ChatTypeMode.letter;
  }
}
