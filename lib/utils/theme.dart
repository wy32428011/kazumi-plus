import 'package:flutter/material.dart';
import 'package:kazumi/theme/kazumi_theme_tokens.dart';

ThemeData oledDarkTheme(ThemeData defaultDarkTheme) {
  final tokens =
      defaultDarkTheme.extension<KazumiThemeTokens>() ?? KazumiThemeTokens.dark;
  final oledTokens = KazumiThemeTokens.oled.copyWith(
    accent: tokens.accent,
    accentSoft: tokens.accentSoft,
    onAccent: tokens.onAccent,
  );
  return defaultDarkTheme.copyWith(
    scaffoldBackgroundColor: Colors.black,
    canvasColor: Colors.black,
    extensions: [oledTokens],
    colorScheme: defaultDarkTheme.colorScheme.copyWith(
      surface: Colors.black,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: oledTokens.surface1,
      surfaceContainer: oledTokens.surface1,
      surfaceContainerHigh: oledTokens.surface2,
      surfaceContainerHighest: oledTokens.surface3,
      onSurface: Colors.white,
    ),
  );
}
