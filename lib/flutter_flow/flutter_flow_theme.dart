// ignore_for_file: overridden_fields, annotate_overrides

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:shared_preferences/shared_preferences.dart';

const kThemeModeKey = '__theme_mode__';

SharedPreferences? _prefs;

abstract class FlutterFlowTheme {
  static Future initialize() async =>
      _prefs = await SharedPreferences.getInstance();

  static ThemeMode get themeMode {
    final darkMode = _prefs?.getBool(kThemeModeKey);
    return darkMode == null
        ? ThemeMode.system
        : darkMode
            ? ThemeMode.dark
            : ThemeMode.light;
  }

  static void saveThemeMode(ThemeMode mode) => mode == ThemeMode.system
      ? _prefs?.remove(kThemeModeKey)
      : _prefs?.setBool(kThemeModeKey, mode == ThemeMode.dark);

  static FlutterFlowTheme of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? DarkModeTheme()
        : LightModeTheme();
  }

  @Deprecated('Use primary instead')
  Color get primaryColor => primary;
  @Deprecated('Use secondary instead')
  Color get secondaryColor => secondary;
  @Deprecated('Use tertiary instead')
  Color get tertiaryColor => tertiary;

  late Color primary;
  late Color secondary;
  late Color tertiary;
  late Color alternate;
  late Color primaryText;
  late Color secondaryText;
  late Color primaryBackground;
  late Color secondaryBackground;
  late Color accent1;
  late Color accent2;
  late Color accent3;
  late Color accent4;
  late Color success;
  late Color warning;
  late Color error;
  late Color info;

  late Color onPrimary;
  late Color primaryContainer;
  late Color onPrimaryContainer;
  late Color onSecondary;
  late Color secondaryContainer;
  late Color onSecondaryContainer;
  late Color onAccent;
  late Color accentContainer;
  late Color onAccentContainer;
  late Color onBackground;
  late Color onSurface;
  late Color surfaceVariant;
  late Color onSurfaceVariant;
  late Color onSuccess;
  late Color onWarning;
  late Color onError;
  late Color onInfo;
  late Color transparent;
  late Color fullContrast;
  late Color onInfo60;
  late Color onBackground90;
  late Color primary12;
  late Color onBackground10;
  late Color onPrimary20;
  late Color onPrimary80;
  late Color onPrimary30;
  late Color info20;
  late Color success10;
  late Color surface80;
  late Color primary10;
  late Color outline15;
  late Color outline30;
  late Color onPrimary10;
  late Color outline20;
  late Color outline40;
  late Color warning10;
  late Color onBackground5;

  FFDesignTokens get designToken => FFDesignTokens(this);

  @Deprecated('Use displaySmallFamily instead')
  String get title1Family => displaySmallFamily;
  @Deprecated('Use displaySmall instead')
  TextStyle get title1 => typography.displaySmall;
  @Deprecated('Use headlineMediumFamily instead')
  String get title2Family => typography.headlineMediumFamily;
  @Deprecated('Use headlineMedium instead')
  TextStyle get title2 => typography.headlineMedium;
  @Deprecated('Use headlineSmallFamily instead')
  String get title3Family => typography.headlineSmallFamily;
  @Deprecated('Use headlineSmall instead')
  TextStyle get title3 => typography.headlineSmall;
  @Deprecated('Use titleMediumFamily instead')
  String get subtitle1Family => typography.titleMediumFamily;
  @Deprecated('Use titleMedium instead')
  TextStyle get subtitle1 => typography.titleMedium;
  @Deprecated('Use titleSmallFamily instead')
  String get subtitle2Family => typography.titleSmallFamily;
  @Deprecated('Use titleSmall instead')
  TextStyle get subtitle2 => typography.titleSmall;
  @Deprecated('Use bodyMediumFamily instead')
  String get bodyText1Family => typography.bodyMediumFamily;
  @Deprecated('Use bodyMedium instead')
  TextStyle get bodyText1 => typography.bodyMedium;
  @Deprecated('Use bodySmallFamily instead')
  String get bodyText2Family => typography.bodySmallFamily;
  @Deprecated('Use bodySmall instead')
  TextStyle get bodyText2 => typography.bodySmall;

  String get displayLargeFamily => typography.displayLargeFamily;
  bool get displayLargeIsCustom => typography.displayLargeIsCustom;
  TextStyle get displayLarge => typography.displayLarge;
  String get displayMediumFamily => typography.displayMediumFamily;
  bool get displayMediumIsCustom => typography.displayMediumIsCustom;
  TextStyle get displayMedium => typography.displayMedium;
  String get displaySmallFamily => typography.displaySmallFamily;
  bool get displaySmallIsCustom => typography.displaySmallIsCustom;
  TextStyle get displaySmall => typography.displaySmall;
  String get headlineLargeFamily => typography.headlineLargeFamily;
  bool get headlineLargeIsCustom => typography.headlineLargeIsCustom;
  TextStyle get headlineLarge => typography.headlineLarge;
  String get headlineMediumFamily => typography.headlineMediumFamily;
  bool get headlineMediumIsCustom => typography.headlineMediumIsCustom;
  TextStyle get headlineMedium => typography.headlineMedium;
  String get headlineSmallFamily => typography.headlineSmallFamily;
  bool get headlineSmallIsCustom => typography.headlineSmallIsCustom;
  TextStyle get headlineSmall => typography.headlineSmall;
  String get titleLargeFamily => typography.titleLargeFamily;
  bool get titleLargeIsCustom => typography.titleLargeIsCustom;
  TextStyle get titleLarge => typography.titleLarge;
  String get titleMediumFamily => typography.titleMediumFamily;
  bool get titleMediumIsCustom => typography.titleMediumIsCustom;
  TextStyle get titleMedium => typography.titleMedium;
  String get titleSmallFamily => typography.titleSmallFamily;
  bool get titleSmallIsCustom => typography.titleSmallIsCustom;
  TextStyle get titleSmall => typography.titleSmall;
  String get labelLargeFamily => typography.labelLargeFamily;
  bool get labelLargeIsCustom => typography.labelLargeIsCustom;
  TextStyle get labelLarge => typography.labelLarge;
  String get labelMediumFamily => typography.labelMediumFamily;
  bool get labelMediumIsCustom => typography.labelMediumIsCustom;
  TextStyle get labelMedium => typography.labelMedium;
  String get labelSmallFamily => typography.labelSmallFamily;
  bool get labelSmallIsCustom => typography.labelSmallIsCustom;
  TextStyle get labelSmall => typography.labelSmall;
  String get bodyLargeFamily => typography.bodyLargeFamily;
  bool get bodyLargeIsCustom => typography.bodyLargeIsCustom;
  TextStyle get bodyLarge => typography.bodyLarge;
  String get bodyMediumFamily => typography.bodyMediumFamily;
  bool get bodyMediumIsCustom => typography.bodyMediumIsCustom;
  TextStyle get bodyMedium => typography.bodyMedium;
  String get bodySmallFamily => typography.bodySmallFamily;
  bool get bodySmallIsCustom => typography.bodySmallIsCustom;
  TextStyle get bodySmall => typography.bodySmall;

  Typography get typography => ThemeTypography(this);
}

class LightModeTheme extends FlutterFlowTheme {
  @Deprecated('Use primary instead')
  Color get primaryColor => primary;
  @Deprecated('Use secondary instead')
  Color get secondaryColor => secondary;
  @Deprecated('Use tertiary instead')
  Color get tertiaryColor => tertiary;

  late Color primary = const Color(0xFF228B22);
  late Color secondary = const Color(0xFF5D3A1A);
  late Color tertiary = const Color(0xFFE67E22);
  late Color alternate = const Color(0xFFE5DACE);
  late Color primaryText = const Color(0xFF2C2318);
  late Color secondaryText = const Color(0xFF544B3D);
  late Color primaryBackground = const Color(0xFFFDFBF7);
  late Color secondaryBackground = const Color(0xFFFFFFFF);
  late Color accent1 = const Color(0x4C4B39EF);
  late Color accent2 = const Color(0x4D39D2C0);
  late Color accent3 = const Color(0xFFA69B8D);
  late Color accent4 = const Color(0xCCFFFFFF);
  late Color success = const Color(0xFF2E7D32);
  late Color warning = const Color(0xFFF39C12);
  late Color error = const Color(0xFFC0392B);
  late Color info = const Color(0xFF87CEEB);

  late Color onPrimary = const Color(0xFFFFFFFF);
  late Color primaryContainer = const Color(0x1A228B22);
  late Color onPrimaryContainer = const Color(0xFF2C2318);
  late Color onSecondary = const Color(0xFFFFFFFF);
  late Color secondaryContainer = const Color(0x1A5D3A1A);
  late Color onSecondaryContainer = const Color(0xFF2C2318);
  late Color onAccent = const Color(0xFFFFFFFF);
  late Color accentContainer = const Color(0x1AE67E22);
  late Color onAccentContainer = const Color(0xFF2C2318);
  late Color onBackground = const Color(0xFF2C2318);
  late Color onSurface = const Color(0xFF2C2318);
  late Color surfaceVariant = const Color(0xFFE9E0D2);
  late Color onSurfaceVariant = const Color(0xFF544B3D);
  late Color onSuccess = const Color(0xFFFFFFFF);
  late Color onWarning = const Color(0xFFFFFFFF);
  late Color onError = const Color(0xFFFFFFFF);
  late Color onInfo = const Color(0xFF000000);
  late Color transparent = const Color(0x00000000);
  late Color fullContrast = const Color(0xFF000000);
  late Color onInfo60 = const Color(0x99000000);
  late Color onBackground90 = const Color(0xE62C2318);
  late Color primary12 = const Color(0x1F228B22);
  late Color onBackground10 = const Color(0x1A2C2318);
  late Color onPrimary20 = const Color(0x33FFFFFF);
  late Color onPrimary80 = const Color(0xCCFFFFFF);
  late Color onPrimary30 = const Color(0x4DFFFFFF);
  late Color info20 = const Color(0x3387CEEB);
  late Color success10 = const Color(0x1A2E7D32);
  late Color surface80 = const Color(0xCCFFFFFF);
  late Color primary10 = const Color(0x1A228B22);
  late Color outline15 = const Color(0x26D2B48C);
  late Color outline30 = const Color(0x4DD2B48C);
  late Color onPrimary10 = const Color(0x1AFFFFFF);
  late Color outline20 = const Color(0x33D2B48C);
  late Color outline40 = const Color(0x66D2B48C);
  late Color warning10 = const Color(0x1AF39C12);
  late Color onBackground5 = const Color(0x0D2C2318);
}

abstract class Typography {
  String get displayLargeFamily;
  bool get displayLargeIsCustom;
  TextStyle get displayLarge;
  String get displayMediumFamily;
  bool get displayMediumIsCustom;
  TextStyle get displayMedium;
  String get displaySmallFamily;
  bool get displaySmallIsCustom;
  TextStyle get displaySmall;
  String get headlineLargeFamily;
  bool get headlineLargeIsCustom;
  TextStyle get headlineLarge;
  String get headlineMediumFamily;
  bool get headlineMediumIsCustom;
  TextStyle get headlineMedium;
  String get headlineSmallFamily;
  bool get headlineSmallIsCustom;
  TextStyle get headlineSmall;
  String get titleLargeFamily;
  bool get titleLargeIsCustom;
  TextStyle get titleLarge;
  String get titleMediumFamily;
  bool get titleMediumIsCustom;
  TextStyle get titleMedium;
  String get titleSmallFamily;
  bool get titleSmallIsCustom;
  TextStyle get titleSmall;
  String get labelLargeFamily;
  bool get labelLargeIsCustom;
  TextStyle get labelLarge;
  String get labelMediumFamily;
  bool get labelMediumIsCustom;
  TextStyle get labelMedium;
  String get labelSmallFamily;
  bool get labelSmallIsCustom;
  TextStyle get labelSmall;
  String get bodyLargeFamily;
  bool get bodyLargeIsCustom;
  TextStyle get bodyLarge;
  String get bodyMediumFamily;
  bool get bodyMediumIsCustom;
  TextStyle get bodyMedium;
  String get bodySmallFamily;
  bool get bodySmallIsCustom;
  TextStyle get bodySmall;
}

class ThemeTypography extends Typography {
  ThemeTypography(this.theme);

  final FlutterFlowTheme theme;

  String get displayLargeFamily => 'Cabin';
  bool get displayLargeIsCustom => false;
  TextStyle get displayLarge => GoogleFonts.cabin(
        color: theme.primaryText,
        fontWeight: FontWeight.bold,
        fontSize: 58.0,
        height: 1.1,
      );
  String get displayMediumFamily => 'Cabin';
  bool get displayMediumIsCustom => false;
  TextStyle get displayMedium => GoogleFonts.cabin(
        color: theme.primaryText,
        fontWeight: FontWeight.bold,
        fontSize: 46.0,
        height: 1.15,
      );
  String get displaySmallFamily => 'Cabin';
  bool get displaySmallIsCustom => false;
  TextStyle get displaySmall => GoogleFonts.cabin(
        color: theme.primaryText,
        fontWeight: FontWeight.bold,
        fontSize: 38.0,
        height: 1.2,
      );
  String get headlineLargeFamily => 'Cabin';
  bool get headlineLargeIsCustom => false;
  TextStyle get headlineLarge => GoogleFonts.cabin(
        color: theme.primaryText,
        fontWeight: FontWeight.bold,
        fontSize: 32.0,
        height: 1.2,
      );
  String get headlineMediumFamily => 'Cabin';
  bool get headlineMediumIsCustom => false;
  TextStyle get headlineMedium => GoogleFonts.cabin(
        color: theme.primaryText,
        fontWeight: FontWeight.w600,
        fontSize: 26.0,
        height: 1.25,
      );
  String get headlineSmallFamily => 'Cabin';
  bool get headlineSmallIsCustom => false;
  TextStyle get headlineSmall => GoogleFonts.cabin(
        color: theme.primaryText,
        fontWeight: FontWeight.w600,
        fontSize: 24.0,
        height: 1.3,
      );
  String get titleLargeFamily => 'Cabin';
  bool get titleLargeIsCustom => false;
  TextStyle get titleLarge => GoogleFonts.cabin(
        color: theme.primaryText,
        fontWeight: FontWeight.w600,
        fontSize: 20.0,
        height: 1.3,
      );
  String get titleMediumFamily => 'Cabin';
  bool get titleMediumIsCustom => false;
  TextStyle get titleMedium => GoogleFonts.cabin(
        color: theme.primaryText,
        fontWeight: FontWeight.w600,
        fontSize: 16.0,
        height: 1.4,
      );
  String get titleSmallFamily => 'Cabin';
  bool get titleSmallIsCustom => false;
  TextStyle get titleSmall => GoogleFonts.cabin(
        color: theme.primaryText,
        fontWeight: FontWeight.w600,
        fontSize: 14.0,
        height: 1.4,
      );
  String get labelLargeFamily => 'Source Sans 3';
  bool get labelLargeIsCustom => false;
  TextStyle get labelLarge => GoogleFonts.sourceSans3(
        color: theme.secondaryText,
        fontWeight: FontWeight.w600,
        fontSize: 14.0,
        height: 1.3,
      );
  String get labelMediumFamily => 'Source Sans 3';
  bool get labelMediumIsCustom => false;
  TextStyle get labelMedium => GoogleFonts.sourceSans3(
        color: theme.secondaryText,
        fontWeight: FontWeight.w600,
        fontSize: 12.0,
        height: 1.3,
      );
  String get labelSmallFamily => 'Source Sans 3';
  bool get labelSmallIsCustom => false;
  TextStyle get labelSmall => GoogleFonts.sourceSans3(
        color: theme.secondaryText,
        fontWeight: FontWeight.w600,
        fontSize: 10.0,
        height: 1.2,
      );
  String get bodyLargeFamily => 'Source Sans 3';
  bool get bodyLargeIsCustom => false;
  TextStyle get bodyLarge => GoogleFonts.sourceSans3(
        color: theme.primaryText,
        fontWeight: FontWeight.normal,
        fontSize: 16.0,
        height: 1.5,
      );
  String get bodyMediumFamily => 'Source Sans 3';
  bool get bodyMediumIsCustom => false;
  TextStyle get bodyMedium => GoogleFonts.sourceSans3(
        color: theme.primaryText,
        fontWeight: FontWeight.normal,
        fontSize: 14.0,
        height: 1.5,
      );
  String get bodySmallFamily => 'Source Sans 3';
  bool get bodySmallIsCustom => false;
  TextStyle get bodySmall => GoogleFonts.sourceSans3(
        color: theme.primaryText,
        fontWeight: FontWeight.normal,
        fontSize: 12.0,
        height: 1.4,
      );
}

class DarkModeTheme extends FlutterFlowTheme {
  @Deprecated('Use primary instead')
  Color get primaryColor => primary;
  @Deprecated('Use secondary instead')
  Color get secondaryColor => secondary;
  @Deprecated('Use tertiary instead')
  Color get tertiaryColor => tertiary;

  late Color primary = const Color(0xFF4CAF50);
  late Color secondary = const Color(0xFFD2B48C);
  late Color tertiary = const Color(0xFFF39C12);
  late Color alternate = const Color(0xFF3D342B);
  late Color primaryText = const Color(0xFFFDFBF7);
  late Color secondaryText = const Color(0xFFD2C8BC);
  late Color primaryBackground = const Color(0xFF1A1612);
  late Color secondaryBackground = const Color(0xFF2C261F);
  late Color accent1 = const Color(0x4C4B39EF);
  late Color accent2 = const Color(0x4D39D2C0);
  late Color accent3 = const Color(0xFF8C8276);
  late Color accent4 = const Color(0xB2262D34);
  late Color success = const Color(0xFF81C784);
  late Color warning = const Color(0xFFFFB74D);
  late Color error = const Color(0xFFE57373);
  late Color info = const Color(0xFF87CEEB);

  late Color onPrimary = const Color(0xFFFFFFFF);
  late Color primaryContainer = const Color(0x244CAF50);
  late Color onPrimaryContainer = const Color(0xFFFDFBF7);
  late Color onSecondary = const Color(0xFFFFFFFF);
  late Color secondaryContainer = const Color(0x24D2B48C);
  late Color onSecondaryContainer = const Color(0xFFFDFBF7);
  late Color onAccent = const Color(0xFFFFFFFF);
  late Color accentContainer = const Color(0x24F39C12);
  late Color onAccentContainer = const Color(0xFFFDFBF7);
  late Color onBackground = const Color(0xFFFDFBF7);
  late Color onSurface = const Color(0xFFFDFBF7);
  late Color surfaceVariant = const Color(0xFF3D342B);
  late Color onSurfaceVariant = const Color(0xFFD2C8BC);
  late Color onSuccess = const Color(0xFFFFFFFF);
  late Color onWarning = const Color(0xFF000000);
  late Color onError = const Color(0xFFFFFFFF);
  late Color onInfo = const Color(0xFF000000);
  late Color transparent = const Color(0x00000000);
  late Color fullContrast = const Color(0xFFFFFFFF);
  late Color onInfo60 = const Color(0x99000000);
  late Color onBackground90 = const Color(0xE6FDFBF7);
  late Color primary12 = const Color(0x1F4CAF50);
  late Color onBackground10 = const Color(0x1AFDFBF7);
  late Color onPrimary20 = const Color(0x33FFFFFF);
  late Color onPrimary80 = const Color(0xCCFFFFFF);
  late Color onPrimary30 = const Color(0x4DFFFFFF);
  late Color info20 = const Color(0x3387CEEB);
  late Color success10 = const Color(0x1A81C784);
  late Color surface80 = const Color(0xCC2C261F);
  late Color primary10 = const Color(0x1A4CAF50);
  late Color outline15 = const Color(0x265D3A1A);
  late Color outline30 = const Color(0x4D5D3A1A);
  late Color onPrimary10 = const Color(0x1AFFFFFF);
  late Color outline20 = const Color(0x335D3A1A);
  late Color outline40 = const Color(0x665D3A1A);
  late Color warning10 = const Color(0x1AFFB74D);
  late Color onBackground5 = const Color(0x0DFDFBF7);
}

class FFDesignTokens {
  const FFDesignTokens(this.theme);
  final FlutterFlowTheme theme;
  FFSpacing get spacing => const FFSpacing();
  FFRadius get radius => const FFRadius();
  FFShadows get shadow => FFShadows(theme);
}

class FFSpacing {
  const FFSpacing();
  double get none => 0.0;
  double get xs => 4.0;
  double get sm => 8.0;
  double get md => 16.0;
  double get lg => 24.0;
  double get xl => 32.0;
  double get xxl => 48.0;
  double get xxxl => 64.0;
}

class FFRadius {
  const FFRadius();
  double get none => 0.0;
  double get xs => 4.0;
  double get sm => 8.0;
  double get md => 12.0;
  double get lg => 16.0;
  double get xl => 24.0;
  double get xxl => 32.0;
  double get full => 9999.0;
}

class FFShadows {
  const FFShadows(this.theme);
  final FlutterFlowTheme theme;
  BoxShadow get none => const BoxShadow(
      blurRadius: 0.0,
      color: const Color(0x00000000),
      offset: const Offset(0.0, 0.0),
      spreadRadius: 0.0);
  BoxShadow get xs => const BoxShadow(
      blurRadius: 2.0,
      color: const Color(0x142C2318),
      offset: const Offset(0.0, 1.0),
      spreadRadius: 0.0);
  BoxShadow get sm => const BoxShadow(
      blurRadius: 4.0,
      color: const Color(0x1A2C2318),
      offset: const Offset(0.0, 2.0),
      spreadRadius: 0.0);
  BoxShadow get md => const BoxShadow(
      blurRadius: 8.0,
      color: const Color(0x1F2C2318),
      offset: const Offset(0.0, 4.0),
      spreadRadius: -1.0);
  BoxShadow get lg => const BoxShadow(
      blurRadius: 16.0,
      color: const Color(0x262C2318),
      offset: const Offset(0.0, 8.0),
      spreadRadius: -2.0);
  BoxShadow get xl => const BoxShadow(
      blurRadius: 24.0,
      color: const Color(0x262C2318),
      offset: const Offset(0.0, 12.0),
      spreadRadius: -4.0);
  BoxShadow get xxl => const BoxShadow(
      blurRadius: 32.0,
      color: const Color(0x332C2318),
      offset: const Offset(0.0, 16.0),
      spreadRadius: -6.0);
}

extension TextStyleHelper on TextStyle {
  TextStyle override({
    TextStyle? font,
    String? fontFamily,
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
    FontStyle? fontStyle,
    bool useGoogleFonts = false,
    TextDecoration? decoration,
    double? lineHeight,
    List<Shadow>? shadows,
    String? package,
  }) {
    if (useGoogleFonts && fontFamily != null && fontFamily.isNotEmpty) {
      font = GoogleFonts.getFont(fontFamily,
          fontWeight: fontWeight ?? this.fontWeight,
          fontStyle: fontStyle ?? this.fontStyle);
    }

    return font != null
        ? font.copyWith(
            color: color ?? this.color,
            fontSize: fontSize ?? this.fontSize,
            letterSpacing: letterSpacing ?? this.letterSpacing,
            fontWeight: fontWeight ?? this.fontWeight,
            fontStyle: fontStyle ?? this.fontStyle,
            decoration: decoration,
            height: lineHeight,
            shadows: shadows,
          )
        : copyWith(
            fontFamily: fontFamily,
            package: package,
            color: color,
            fontSize: fontSize,
            letterSpacing: letterSpacing,
            fontWeight: fontWeight,
            fontStyle: fontStyle,
            decoration: decoration,
            height: lineHeight,
            shadows: shadows,
          );
  }
}
