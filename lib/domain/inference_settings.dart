/// Bir ajanın model çıkarım (örnekleme) ayarları.
///
/// Varsayılanlar, ayarlar eklenmeden önceki sabit değerlerle aynıdır; yani ayarı değiştirmeyen
/// kullanıcı için davranış değişmez.
class InferenceSettings {
  const InferenceSettings({
    this.temperature = defaultTemperature,
    this.topP = defaultTopP,
    this.topK = defaultTopK,
    this.repeatPenalty = defaultRepeatPenalty,
    this.maxTokens,
  });

  static const double defaultTemperature = 0.4;
  static const double defaultTopP = 0.9;
  static const int defaultTopK = 40;
  static const double defaultRepeatPenalty = 1.1;

  /// Düşük sıcaklık: kod/hata denetimi gibi tutarlı çıktı isteyen ajanlar için.
  static const InferenceSettings precise = InferenceSettings(
    temperature: 0.2,
    topP: 0.85,
    repeatPenalty: 1.05,
  );

  final double temperature;
  final double topP;
  final int topK;
  final double repeatPenalty;

  /// Üretilecek en çok token. null = bağlam bütçesinin izin verdiği kadar (otomatik).
  /// Bağlam bütçesi her zaman üst sınırdır; bu değer yalnızca onu DÜŞÜREBİLİR.
  final int? maxTokens;

  bool get isDefault =>
      temperature == defaultTemperature &&
      topP == defaultTopP &&
      topK == defaultTopK &&
      repeatPenalty == defaultRepeatPenalty &&
      maxTokens == null;

  /// Geçerli aralığa sıkıştırılmış kopya (bozuk kayıt/içe aktarım güvenliği).
  InferenceSettings clamped() => InferenceSettings(
    temperature: temperature.isNaN ? defaultTemperature : temperature.clamp(0.0, 2.0).toDouble(),
    topP: topP.isNaN ? defaultTopP : topP.clamp(0.05, 1.0).toDouble(),
    topK: topK.clamp(1, 200).toInt(),
    repeatPenalty: repeatPenalty.isNaN ? defaultRepeatPenalty : repeatPenalty.clamp(1.0, 2.0).toDouble(),
    maxTokens: maxTokens == null || maxTokens! <= 0 ? null : maxTokens!.clamp(32, 8192).toInt(),
  );

  /// [maxTokens] null yapılabilsin diye ayrı bayrak kullanılır.
  InferenceSettings copyWith({
    double? temperature,
    double? topP,
    int? topK,
    double? repeatPenalty,
    int? maxTokens,
    bool clearMaxTokens = false,
  }) => InferenceSettings(
    temperature: temperature ?? this.temperature,
    topP: topP ?? this.topP,
    topK: topK ?? this.topK,
    repeatPenalty: repeatPenalty ?? this.repeatPenalty,
    maxTokens: clearMaxTokens ? null : (maxTokens ?? this.maxTokens),
  );

  Map<String, dynamic> toJson() => {
    'temperature': temperature,
    'topP': topP,
    'topK': topK,
    'repeatPenalty': repeatPenalty,
    if (maxTokens != null) 'maxTokens': maxTokens,
  };

  factory InferenceSettings.fromJson(Map<String, dynamic> j) => InferenceSettings(
    temperature: (j['temperature'] as num?)?.toDouble() ?? defaultTemperature,
    topP: (j['topP'] as num?)?.toDouble() ?? defaultTopP,
    topK: (j['topK'] as num?)?.toInt() ?? defaultTopK,
    repeatPenalty: (j['repeatPenalty'] as num?)?.toDouble() ?? defaultRepeatPenalty,
    maxTokens: (j['maxTokens'] as num?)?.toInt(),
  ).clamped();

  @override
  bool operator ==(Object other) =>
      other is InferenceSettings &&
      other.temperature == temperature &&
      other.topP == topP &&
      other.topK == topK &&
      other.repeatPenalty == repeatPenalty &&
      other.maxTokens == maxTokens;

  @override
  int get hashCode => Object.hash(temperature, topP, topK, repeatPenalty, maxTokens);
}

/// O an çalışan üretimin örnekleme ayarları.
///
/// Motor (LlmEngine) arayüzü ve sahte uygulamaları değişmesin diye ayarlar parametre olarak
/// taşınmaz; üretimler motor içinde zaten sıraya dizildiğinden (tek seferde bir üretim) çalıştırıcı
/// üretimden önce [current]'ı ayarlar, bitince [reset] eder. Native çağrı [current]'ı okur.
class SamplingScope {
  const SamplingScope._();

  static InferenceSettings current = const InferenceSettings();

  static void reset() => current = const InferenceSettings();
}
