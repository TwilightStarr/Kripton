// Değişiklik: yeni dosya. API anahtarlarını günlük, hata mesajı ve çökme raporlarında maskeler.

/// API anahtarlarının düz metin olarak log / hata / çökme raporuna sızmasını engeller.
///
/// İki katmanlı çalışır: (1) uygulamada kullanılan anahtarlar [register] ile kaydedilir ve metinde
/// aynen geçtiği yerler maskelenir; (2) kayıt dışı kalsa bile bilinen anahtar biçimleri
/// (Gemini `AIza…`, Groq `gsk_…`, OpenRouter `sk-or-…`, `Bearer …`, `api_key=…`) kalıpla maskelenir.
class SecretMask {
  SecretMask._();

  /// Maskelenmiş değerin yerine yazılan metin.
  static const String placeholder = '***';

  static const int _minSecretLength = 8;
  static const int _maxKnown = 32;

  static final Set<String> _known = <String>{};

  static final List<RegExp> _patterns = <RegExp>[
    RegExp(r'AIza[0-9A-Za-z_\-]{20,}'),
    RegExp(r'gsk_[0-9A-Za-z]{16,}'),
    RegExp(r'sk-or-[0-9A-Za-z_\-]{8,}'),
    RegExp(r'(?<![0-9A-Za-z])sk-[0-9A-Za-z_\-]{16,}'),
    RegExp(r'Bearer\s+[0-9A-Za-z._~+/\-]+=*', caseSensitive: false),
  ];

  static final RegExp _keyValue = RegExp(
    r'''((?:x-goog-api-key|x-api-key|api[_-]?key|authorization|access_token)["']?\s*[:=]\s*["']?)([^\s"',&;}]+)''',
    caseSensitive: false,
  );

  /// Bir anahtarı "bilinen gizli değer" olarak kaydeder (çok kısa değerler yok sayılır).
  static void register(String? secret) {
    final s = secret?.trim();
    if (s == null || s.length < _minSecretLength) return;
    _known.add(s);
    while (_known.length > _maxKnown) {
      _known.remove(_known.first);
    }
  }

  /// Kayıtlı anahtarları unutur (testler için).
  static void clear() => _known.clear();

  /// Arayüzde göstermek için kısaltılmış anahtar (ör. `AIza…Xy`). Kısa anahtarlar tamamen gizlenir.
  static String display(String key) {
    final k = key.trim();
    if (k.length < 12) return placeholder;
    return '${k.substring(0, 4)}…${k.substring(k.length - 2)}';
  }

  /// [text] içindeki anahtarları maskeler. Anahtar içermeyen metin aynen döner.
  static String redact(String text) {
    if (text.isEmpty) return text;
    var out = text;
    if (_known.isNotEmpty) {
      final byLength = _known.toList()..sort((a, b) => b.length.compareTo(a.length));
      for (final s in byLength) {
        out = out.replaceAll(s, placeholder);
      }
    }
    for (final re in _patterns) {
      out = out.replaceAll(re, placeholder);
    }
    out = out.replaceAllMapped(_keyValue, (m) => '${m.group(1)}$placeholder');
    return out;
  }
}
