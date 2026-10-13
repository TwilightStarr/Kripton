import 'package:flutter/material.dart';

/// Bir tema paleti. Uygulamadaki tüm renkler buradan gelir; [KColors] geçerli paleti okur.
class KPalette {
  final String id;
  final String name;
  final String description;
  final Brightness brightness;
  final Color bg;
  final Color card;
  final Color border;
  final Color text;
  final Color muted;
  final Color accent;
  final Color accent2; // gradyan ikinci rengi
  final Color onAccent;
  final Color accentSoft; // çip / ikon zemini
  final Color codeBg; // token / kod kutusu zemini
  final Color amber;
  final Color purple;
  final Color green;
  final Color red;

  const KPalette({
    required this.id,
    required this.name,
    required this.description,
    required this.brightness,
    required this.bg,
    required this.card,
    required this.border,
    required this.text,
    required this.muted,
    required this.accent,
    required this.accent2,
    required this.onAccent,
    required this.accentSoft,
    required this.codeBg,
    required this.amber,
    required this.purple,
    required this.green,
    required this.red,
  });

  bool get isDark => brightness == Brightness.dark;

  /// Gece Mavisi: önceki (varsayılan) görünüm.
  static final gece = KPalette(
    id: 'gece',
    name: 'Gece Mavisi',
    description: 'Klasik koyu mavi',
    brightness: Brightness.dark,
    bg: Color(0xFF0F172A),
    card: Color(0xFF1E293B),
    border: Color(0xFF334155),
    text: Color(0xFFE2E8F0),
    muted: Color(0xFF94A3B8),
    accent: Color(0xFF38BDF8),
    accent2: Color(0xFF2563EB),
    onAccent: Color(0xFF0F172A),
    accentSoft: Color(0xFF082F49),
    codeBg: Color(0xFF020617),
    amber: Color(0xFFFBBF24),
    purple: Color(0xFFC084FC),
    green: Color(0xFF34D399),
    red: Color(0xFFF43F5E),
  );

  /// AMOLED: saf siyah zemin; OLED ekranda pil ve ısı için de uygundur.
  static const amoled = KPalette(
    id: 'amoled',
    name: 'AMOLED Siyah',
    description: 'Saf siyah, OLED dostu',
    brightness: Brightness.dark,
    bg: Color(0xFF000000),
    card: Color(0xFF0E1013),
    border: Color(0xFF23272E),
    text: Color(0xFFEDEFF2),
    muted: Color(0xFF8A919C),
    accent: Color(0xFF2DD4BF),
    accent2: Color(0xFF0EA5E9),
    onAccent: Color(0xFF000000),
    accentSoft: Color(0xFF062B27),
    codeBg: Color(0xFF07080A),
    amber: Color(0xFFFBBF24),
    purple: Color(0xFFC084FC),
    green: Color(0xFF4ADE80),
    red: Color(0xFFFB7185),
  );

  static final gunIsigi = KPalette(
    id: 'gun_isigi',
    name: 'Gün Işığı',
    description: 'Temiz açık tema',
    brightness: Brightness.light,
    bg: Color(0xFFF4F7FC),
    card: Color(0xFFFFFFFF),
    border: Color(0xFFDDE5F0),
    text: Color(0xFF0F172A),
    muted: Color(0xFF64748B),
    accent: Color(0xFF2563EB),
    accent2: Color(0xFF7C3AED),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFDBEAFE),
    codeBg: Color(0xFFEEF2F8),
    amber: Color(0xFFB45309),
    purple: Color(0xFF7C3AED),
    green: Color(0xFF047857),
    red: Color(0xFFDC2626),
  );

  static const kum = KPalette(
    id: 'kum',
    name: 'Kum',
    description: 'Sıcak, göz yormayan açık tema',
    brightness: Brightness.light,
    bg: Color(0xFFFAF6F0),
    card: Color(0xFFFFFFFF),
    border: Color(0xFFE8DFD2),
    text: Color(0xFF2B2118),
    muted: Color(0xFF7A6C5D),
    accent: Color(0xFFC2410C),
    accent2: Color(0xFFD97706),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFFFEDD5),
    codeBg: Color(0xFFF3ECE1),
    amber: Color(0xFFB45309),
    purple: Color(0xFF9333EA),
    green: Color(0xFF15803D),
    red: Color(0xFFDC2626),
  );

  static final orman = KPalette(
    id: 'orman',
    name: 'Orman',
    description: 'Koyu yeşil, sakin',
    brightness: Brightness.dark,
    bg: Color(0xFF0B1410),
    card: Color(0xFF13211A),
    border: Color(0xFF244034),
    text: Color(0xFFE4F1E9),
    muted: Color(0xFF89A898),
    accent: Color(0xFF34D399),
    accent2: Color(0xFF059669),
    onAccent: Color(0xFF062016),
    accentSoft: Color(0xFF0F3B2B),
    codeBg: Color(0xFF060C09),
    amber: Color(0xFFFBBF24),
    purple: Color(0xFFC084FC),
    green: Color(0xFF86EFAC),
    red: Color(0xFFF87171),
  );

  static final morGece = KPalette(
    id: 'mor_gece',
    name: 'Mor Gece',
    description: 'Koyu mor, canlı vurgu',
    brightness: Brightness.dark,
    bg: Color(0xFF110E1E),
    card: Color(0xFF1C1830),
    border: Color(0xFF33295A),
    text: Color(0xFFECE8FF),
    muted: Color(0xFFA29CC4),
    accent: Color(0xFFA78BFA),
    accent2: Color(0xFF7C3AED),
    onAccent: Color(0xFF1A1033),
    accentSoft: Color(0xFF2D2357),
    codeBg: Color(0xFF0A0814),
    amber: Color(0xFFFBBF24),
    purple: Color(0xFFE879F9),
    green: Color(0xFF34D399),
    red: Color(0xFFFB7185),
  );

  static const gunBatimi = KPalette(
    id: 'gun_batimi',
    name: 'Gün Batımı',
    description: 'Sıcak koyu, turuncu vurgu',
    brightness: Brightness.dark,
    bg: Color(0xFF1A1110),
    card: Color(0xFF281A18),
    border: Color(0xFF4A2D28),
    text: Color(0xFFFCEDE6),
    muted: Color(0xFFC1A097),
    accent: Color(0xFFFB923C),
    accent2: Color(0xFFF43F5E),
    onAccent: Color(0xFF2A1305),
    accentSoft: Color(0xFF45240F),
    codeBg: Color(0xFF0F0807),
    amber: Color(0xFFFCD34D),
    purple: Color(0xFFD8B4FE),
    green: Color(0xFF4ADE80),
    red: Color(0xFFFB7185),
  );

  static final all = <KPalette>[gece, amoled, gunIsigi, kum, orman, morGece, gunBatimi];

  static KPalette byId(String? id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return gece;
  }

  /// Geçerli palet. Tema değişiminde [ThemeController] günceller ve ağacı yeniden kurdurur.
  static KPalette current = gece;
}

/// Eski kod `KColors.xxx` yazmaya devam eder; değerler artık geçerli paletten okunur.
/// (Bu yüzden `const` bağlamlarda kullanılamaz.)
class KColors {
  static Color get bg => KPalette.current.bg;
  static Color get card => KPalette.current.card;
  static Color get accent => KPalette.current.accent;
  static Color get accent2 => KPalette.current.accent2;
  static Color get onAccent => KPalette.current.onAccent;
  static Color get accentSoft => KPalette.current.accentSoft;
  static Color get codeBg => KPalette.current.codeBg;
  static Color get border => KPalette.current.border;
  static Color get muted => KPalette.current.muted;
  static Color get text => KPalette.current.text;
  static Color get amber => KPalette.current.amber;
  static Color get purple => KPalette.current.purple;
  static Color get green => KPalette.current.green;
  static Color get red => KPalette.current.red;
}

/// Köşe yarıçapları (tek yerden ayarlanır).
class KRadius {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
}

/// Kartlar için ortak, modern yüzey dekorasyonu.
BoxDecoration kCardDecoration({bool soft = false, double radius = KRadius.lg}) {
  final dark = KPalette.current.isDark;
  return BoxDecoration(
    color: soft ? KColors.card.withOpacity(dark ? 0.6 : 0.8) : KColors.card,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: KColors.border),
    boxShadow: dark
        ? null
        : [
            BoxShadow(
              color: KColors.bg.withOpacity(0.05),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
  );
}

ThemeData buildTheme([KPalette? palette]) {
  final p = palette ?? KPalette.current;
  final base = p.isDark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);

  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(KRadius.md),
        borderSide: BorderSide(color: c, width: w),
      );

  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: p.accent2,
    onSecondary: Colors.white,
    error: p.red,
    onError: Colors.white,
    surface: p.card,
    onSurface: p.text,
    outline: p.border,
    outlineVariant: p.border,
    surfaceTint: Colors.transparent,
  );

  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(KRadius.md));

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.card,
    cardColor: p.card,
    dividerColor: p.border,
    splashFactory: InkRipple.splashFactory,
    textTheme: base.textTheme.apply(bodyColor: p.text, displayColor: p.text),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.isDark ? p.bg : p.bg.withOpacity(0.7),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: border(p.border),
      enabledBorder: border(p.border),
      focusedBorder: border(p.accent, 1.6),
      labelStyle: TextStyle(color: p.muted),
      helperStyle: TextStyle(color: p.muted, fontSize: 11),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.bg,
      modalBackgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: p.border,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(KRadius.xl)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        minimumSize: const Size(0, 48),
        shape: shape,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        side: BorderSide(color: p.border),
        minimumSize: const Size(0, 44),
        shape: shape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: p.accent, shape: shape),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: p.accentSoft,
      side: BorderSide(color: p.accent.withOpacity(0.35)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KRadius.lg)),
      labelStyle: TextStyle(color: p.accent, fontWeight: FontWeight.w700, fontSize: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.isDark ? p.card : p.text,
      contentTextStyle: TextStyle(color: p.isDark ? p.text : p.bg),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KRadius.md)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KRadius.md),
        side: BorderSide(color: p.border),
      ),
    ),
    dividerTheme: DividerThemeData(color: p.border, space: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent, linearTrackColor: p.border),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.onAccent : p.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.border,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
  );
}

/// Tema değişince tüm öğeleri yeniden kurar. Renkler [KColors] üzerinden okunduğu ve birçok widget
/// `const` olduğu için yalnızca MaterialApp'i yenilemek yetmez; gezinme yığını korunarak ağaç baştan çizilir.
void kRebuildAll() {
  void visit(Element e) {
    e.markNeedsBuild();
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
}
