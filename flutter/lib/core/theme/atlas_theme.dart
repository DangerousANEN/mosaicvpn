import 'package:flutter/material.dart';

/// MosaicVPN Atlas theme — a cartographic/gazetteer aesthetic.
///
/// Inspired by vintage atlases: warm cream paper backgrounds,
/// dark sepia text, terracotta accents, and serif headings.
/// The UI reads like a field journal rather than a tech product.
class AtlasTheme {
  AtlasTheme._();

  // ── Backgrounds (paper tones) ──
  static const Color bgBase = Color(0xFFF4EFE6); // warm cream paper
  static const Color bgCard = Color(0xFFEDE5D6); // aged parchment
  static const Color bgElevated = Color(0xFFE4DAC6); // darker parchment
  static const Color bgInk = Color(0xFF2B2620); // dark ink panel
  static const Color bgHover = Color(0xFFD9CFB8); // hover highlight
  static const Color bgChild =
      Color(0xFFE4DAC6); // child input bg (alias of bgElevated)

  // ── Borders ──
  static const Color border = Color(0xFFC4B89E); // faded map border
  static const Color borderLight = Color(0xFFD4C9B0);
  static const Color borderInk = Color(0xFF5C4E3A); // dark ink border

  // ── Text ──
  static const Color textPrimary = Color(0xFF2B2620); // dark sepia ink
  static const Color textSecondary = Color(0xFF6B5D4A); // muted brown
  static const Color textMuted = Color(0xFF9A8B72); // faded text
  static const Color textOnInk = Color(0xFFF4EFE6); // light text on ink

  // ── Accent (terracotta) ──
  static const Color accent = Color(0xFFB85C38); // terracotta orange
  static const Color accentHover = Color(0xFFD4724A); // lighter terracotta
  static const Color accentDim = Color(0x26B85C38); // terracotta 15%

  // ── Status ──
  static const Color success = Color(0xFF5B7A3A); // olive green
  static const Color successDim = Color(0x265B7A3A);
  static const Color warning = Color(0xFFC47830); // amber brown
  static const Color warningDim = Color(0x26C47830);
  static const Color error = Color(0xFFA8442A); // rust red
  static const Color errorDim = Color(0x26A8442A);
  static const Color danger = Color(0xFFA8442A); // alias of error
  static const Color dangerDim = Color(0x26A8442A);
  static const Color info = Color(0xFF4B6B7A); // steel blue
  static const Color infoDim = Color(0x264B6B7A);

  // ── Radii ──
  static const double radiusSm = 4.0;
  static const double radiusMd = 8.0;
  static const double radiusLg = 12.0;

  // ── Typography ──
  static const String serifFamily = 'serif';
  static const String monoFamily = 'monospace';
  static const String sansFamily = 'sans-serif';

  // ── Dark mode overrides ──
  // Dark theme keeps the terracotta accent but inverts backgrounds to ink tones.
  static const Color darkBgBase = Color(0xFF1A1814);
  static const Color darkBgCard = Color(0xFF221F1A);
  static const Color darkBgElevated = Color(0xFF2B2722);
  static const Color darkBgInk = Color(0xFF100F0C);
  static const Color darkBgHover = Color(0xFF353029);
  static const Color darkBorder = Color(0xFF3D3830);
  static const Color darkBorderInk = Color(0xFF0A0908);
  static const Color darkTextPrimary = Color(0xFFE8DFD0);
  static const Color darkTextSecondary = Color(0xFFA89882);
  static const Color darkTextMuted = Color(0xFF6B5F50);
  static const Color darkTextOnInk = Color(0xFFE8DFD0);

  // ── Console / log output ──
  // The log console is an ink panel in BOTH themes, so these are not
  // light/dark pairs — they are the on-ink variants of the status hues.
  // The base status colors (error/warning/success) are tuned for parchment
  // and only reach 2.5:1–4.3:1 against ink, so reusing them here would be
  // unreadable. These are lightened to clear 4.5:1 on the lighter ink panel.
  static const Color consoleError = Color(0xFFE87A5C); // 5.26:1 on bgInk
  static const Color consoleWarning = Color(0xFFE8A552); // 7.09:1
  static const Color consoleSuccess = Color(0xFF9CBF6B); // 7.19:1
  static const Color consoleMuted = Color(0xFFA89882); // 5.34:1
  static const Color consoleText = Color(0xFFE8DFD0); // 11.35:1

  // Foreground for filled accent/danger buttons. The parchment cream
  // (textOnInk) only reaches 3.96:1 on the terracotta accent, so filled
  // buttons need a brighter foreground than panel text does.
  static const Color onAccent = Color(0xFFFFFDFA); // 4.51:1 on accent

  /// Light ThemeData (default — warm cream paper aesthetic).
  static ThemeData get themeData => ThemeData.light().copyWith(
        scaffoldBackgroundColor: bgBase,
        colorScheme: const ColorScheme.light(
          surface: bgBase,
          primary: accent,
          secondary: accentHover,
          error: error,
          onSurface: textPrimary,
          onPrimary: textOnInk,
        ),
        cardColor: bgCard,
        dividerColor: border,
        appBarTheme: const AppBarTheme(
          backgroundColor: bgBase,
          foregroundColor: textPrimary,
          elevation: 0,
          centerTitle: false,
        ),
        textTheme: const TextTheme(
          // Display / Headlines — serif
          displayLarge: TextStyle(
            fontFamily: serifFamily,
            fontSize: 32,
            fontWeight: FontWeight.w700,
            color: textPrimary,
            letterSpacing: -0.5,
          ),
          displayMedium: TextStyle(
            fontFamily: serifFamily,
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: textPrimary,
          ),
          displaySmall: TextStyle(
            fontFamily: serifFamily,
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: textPrimary,
          ),
          headlineLarge: TextStyle(
            fontFamily: serifFamily,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: textPrimary,
          ),
          headlineMedium: TextStyle(
            fontFamily: serifFamily,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: textPrimary,
          ),
          headlineSmall: TextStyle(
            fontFamily: serifFamily,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: textSecondary,
          ),
          bodyLarge: TextStyle(
            fontFamily: sansFamily,
            fontSize: 15,
            color: textPrimary,
          ),
          bodyMedium: TextStyle(
            fontFamily: sansFamily,
            fontSize: 13,
            color: textSecondary,
          ),
          bodySmall: TextStyle(
            fontFamily: sansFamily,
            fontSize: 11,
            color: textMuted,
          ),
          labelLarge: TextStyle(
            fontFamily: sansFamily,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: textPrimary,
          ),
          labelMedium: TextStyle(
            fontFamily: sansFamily,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: textSecondary,
          ),
          labelSmall: TextStyle(
            fontFamily: sansFamily,
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: textMuted,
            letterSpacing: 0.5,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: bgInk,
            foregroundColor: textOnInk,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSm),
            ),
            textStyle: const TextStyle(
              fontFamily: sansFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: accent,
            side: const BorderSide(color: accent, width: 1.5),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSm),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: accent,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: bgCard,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusSm),
            borderSide: const BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusSm),
            borderSide: const BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusSm),
            borderSide: const BorderSide(color: accent, width: 1.5),
          ),
          labelStyle: const TextStyle(
            fontFamily: sansFamily,
            fontSize: 13,
            color: textSecondary,
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return accent;
            return textMuted;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return accentDim;
            return border;
          }),
        ),
        dividerTheme: const DividerThemeData(
          color: border,
          thickness: 1,
          space: 1,
        ),
        iconTheme: const IconThemeData(color: textPrimary, size: 20),
      );

  /// Dark ThemeData (q8) — ink-toned dark version of the Atlas palette.
  static ThemeData get lightThemeData => themeData;

  /// Dark ThemeData (q8) — reversed ink/charcoal palette.
  static ThemeData get darkThemeData => ThemeData.dark().copyWith(
        scaffoldBackgroundColor: darkBgBase,
        colorScheme: ColorScheme.dark(
          surface: darkBgBase,
          primary: accent,
          secondary: accentHover,
          error: error,
          onSurface: darkTextPrimary,
          onPrimary: textOnInk,
        ),
        cardColor: darkBgCard,
        dividerColor: darkBorder,
        appBarTheme: const AppBarTheme(
          backgroundColor: darkBgBase,
          foregroundColor: darkTextPrimary,
          elevation: 0,
          centerTitle: false,
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(
              fontFamily: serifFamily,
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: darkTextPrimary,
              letterSpacing: -0.5),
          displayMedium: TextStyle(
              fontFamily: serifFamily,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: darkTextPrimary),
          displaySmall: TextStyle(
              fontFamily: serifFamily,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: darkTextPrimary),
          headlineLarge: TextStyle(
              fontFamily: serifFamily,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: darkTextPrimary),
          headlineMedium: TextStyle(
              fontFamily: serifFamily,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: darkTextPrimary),
          headlineSmall: TextStyle(
              fontFamily: serifFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: darkTextSecondary),
          bodyLarge: TextStyle(
              fontFamily: sansFamily, fontSize: 15, color: darkTextPrimary),
          bodyMedium: TextStyle(
              fontFamily: sansFamily, fontSize: 13, color: darkTextSecondary),
          bodySmall: TextStyle(
              fontFamily: sansFamily, fontSize: 11, color: darkTextMuted),
          labelLarge: TextStyle(
              fontFamily: sansFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: darkTextPrimary),
          labelMedium: TextStyle(
              fontFamily: sansFamily,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: darkTextSecondary),
          labelSmall: TextStyle(
              fontFamily: sansFamily,
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: darkTextMuted,
              letterSpacing: 0.5),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: darkBgInk,
            foregroundColor: darkTextOnInk,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radiusSm)),
            textStyle: const TextStyle(
                fontFamily: sansFamily,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: accent,
            side: const BorderSide(color: accent, width: 1.5),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radiusSm)),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: accent),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: darkBgCard,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(radiusSm),
              borderSide: const BorderSide(color: darkBorder)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(radiusSm),
              borderSide: const BorderSide(color: darkBorder)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(radiusSm),
              borderSide: const BorderSide(color: accent, width: 1.5)),
          labelStyle: const TextStyle(
              fontFamily: sansFamily, fontSize: 13, color: darkTextSecondary),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return accent;
            return darkTextMuted;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return accentDim;
            return darkBorder;
          }),
        ),
        dividerTheme:
            const DividerThemeData(color: darkBorder, thickness: 1, space: 1),
        iconTheme: const IconThemeData(color: darkTextPrimary, size: 20),
      );
}

/// Extension for easy color access via context.
extension AtlasThemeExtension on BuildContext {
  ThemeData get atlas => Theme.of(this);
}

/// Theme-aware color accessor — resolves light/dark palette automatically.
///
/// Usage: `final c = ThemeColors.of(context);` then `c.bgBase`, `c.textPrimary`, etc.
/// All screens should migrate from `AtlasTheme.darkBgBase` / `AtlasTheme.bgBase`
/// to `ThemeColors.of(context).bgBase` so they work in both themes.
class ThemeColors {
  final bool isDark;
  const ThemeColors._(this.isDark);

  factory ThemeColors.of(BuildContext context) =>
      ThemeColors._(Theme.of(context).brightness == Brightness.dark);

  // ── Backgrounds ──
  Color get bgBase => isDark ? AtlasTheme.darkBgBase : AtlasTheme.bgBase;
  Color get bgCard => isDark ? AtlasTheme.darkBgCard : AtlasTheme.bgCard;
  Color get bgElevated =>
      isDark ? AtlasTheme.darkBgElevated : AtlasTheme.bgElevated;
  Color get bgInk => isDark ? AtlasTheme.darkBgInk : AtlasTheme.bgInk;
  Color get bgHover => isDark ? AtlasTheme.darkBgHover : AtlasTheme.bgHover;

  // ── Borders ──
  Color get border => isDark ? AtlasTheme.darkBorder : AtlasTheme.border;
  Color get borderInk =>
      isDark ? AtlasTheme.darkBorderInk : AtlasTheme.borderInk;
  Color get borderLight =>
      isDark ? AtlasTheme.darkBorder : AtlasTheme.borderLight;

  // ── Text ──
  Color get textPrimary =>
      isDark ? AtlasTheme.darkTextPrimary : AtlasTheme.textPrimary;
  Color get textSecondary =>
      isDark ? AtlasTheme.darkTextSecondary : AtlasTheme.textSecondary;
  Color get textMuted =>
      isDark ? AtlasTheme.darkTextMuted : AtlasTheme.textMuted;
  Color get textOnInk =>
      isDark ? AtlasTheme.darkTextOnInk : AtlasTheme.textOnInk;

  // ── Accent (shared — same in both themes) ──
  Color get accent => AtlasTheme.accent;
  Color get accentHover => AtlasTheme.accentHover;
  Color get accentDim => AtlasTheme.accentDim;

  // ── Status (shared) ──
  Color get success => AtlasTheme.success;
  Color get successDim => AtlasTheme.successDim;
  Color get warning => AtlasTheme.warning;
  Color get warningDim => AtlasTheme.warningDim;
  Color get error => AtlasTheme.error;
  Color get errorDim => AtlasTheme.errorDim;
  Color get danger => AtlasTheme.danger;
  Color get dangerDim => AtlasTheme.dangerDim;
  Color get info => AtlasTheme.info;
  Color get infoDim => AtlasTheme.infoDim;

  Color get bgChild => isDark ? AtlasTheme.darkBgElevated : AtlasTheme.bgChild;

  // ── Console (ink panel in both themes — intentionally not a light/dark pair) ──
  Color get consoleBg => isDark ? AtlasTheme.darkBgInk : AtlasTheme.bgInk;
  Color get consoleError => AtlasTheme.consoleError;
  Color get consoleWarning => AtlasTheme.consoleWarning;
  Color get consoleSuccess => AtlasTheme.consoleSuccess;
  Color get consoleMuted => AtlasTheme.consoleMuted;
  Color get consoleText => AtlasTheme.consoleText;

  /// Foreground for filled accent/danger buttons (same in both themes —
  /// the fill color is the same, so the contrast requirement is too).
  Color get onAccent => AtlasTheme.onAccent;
}
