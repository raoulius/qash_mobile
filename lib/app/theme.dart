// theme.dart
//
// Material 3 Expressive tokens shared by every screen, built on the real
// Qash brand palette (from Qash-is-King's resources/css/app.css :root vars
// --mainColorOrange / --mainColorBlue) instead of a generic seed color, so
// this app matches the web backoffice it mirrors.

import 'package:flutter/material.dart';

class AppTheme {
  static const _brandOrange = Color(0xFFF97316); // --mainColorOrange
  static const _brandNavy = Color(0xFF142566); // --mainColorBlue

  /// Brand logo for the current brightness: [kind] is 'main_logo' (mark +
  /// wordmark, stacked) or 'logotype' (wordmark). Files in assets/brand/.
  static String logo(BuildContext context, String kind) =>
      'assets/brand/${kind}_${Theme.of(context).brightness == Brightness.dark ? 'white' : 'navy'}.png';

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _brandOrange,
      brightness: brightness,
    ).copyWith(
      primary: _brandOrange,
      onPrimary: Colors.white,
      secondary: _brandNavy,
      onSecondary: Colors.white,
      tertiary: _brandNavy,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorShape: const StadiumBorder(),
        height: 72,
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        color: scheme.surfaceContainerLow,
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        backgroundColor: scheme.surfaceContainerHigh,
      ),
      textTheme: Typography.material2021(platform: TargetPlatform.android)
          .englishLike
          .apply(
            bodyColor: scheme.onSurface,
            displayColor: scheme.onSurface,
          )
          .copyWith(
            headlineSmall: const TextStyle(fontWeight: FontWeight.w700),
            titleLarge: const TextStyle(fontWeight: FontWeight.w700),
            titleMedium: const TextStyle(fontWeight: FontWeight.w600),
          ),
    );
  }
}
