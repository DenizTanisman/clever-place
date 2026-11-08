import 'package:flutter/material.dart';

/// Dark (warm luxury) and Light (cream luxury) themes for the Material defaults the screens inherit
/// (dialogs, snack bars, the cube pages). The hub and game pages paint their own Lux palette.
class AppThemes {
  AppThemes._();

  // Dark
  static const _dPanel = Color(0xFF120C08);
  static const _dCard = Color(0xFF1C150D);
  static const _dInk = Color(0xFFF4ECD8);
  static const _dMuted = Color(0xFF9A8A6A);
  static const _dAccent = Color(0xFFD4AF37);
  static const _dLine = Color(0x29D4AF37); // rgba(212,175,55,.16)

  // Light
  static const _lCard = Color(0xFFFFFFFF);
  static const _lInk = Color(0xFF33280F);
  static const _lMuted = Color(0xFF937F4F);
  static const _lAccent = Color(0xFFB8902C);
  static const _lLine = Color(0x2E8C6E28); // rgba(140,110,40,.18)

  static ThemeData get dark => _build(
        brightness: Brightness.dark,
        scaffold: _dPanel,
        card: _dCard,
        ink: _dInk,
        muted: _dMuted,
        accent: _dAccent,
        line: _dLine,
      );

  static ThemeData get light => _build(
        brightness: Brightness.light,
        scaffold: const Color(0xFFF1E8D2),
        card: _lCard,
        ink: _lInk,
        muted: _lMuted,
        accent: _lAccent,
        line: _lLine,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color scaffold,
    required Color card,
    required Color ink,
    required Color muted,
    required Color accent,
    required Color line,
  }) {
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: scaffold,
      canvasColor: scaffold,
      cardColor: card,
      dividerColor: line,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
      ).copyWith(
        primary: accent,
        surface: card,
        onSurface: ink,
      ),
      textTheme: base.textTheme.apply(
        fontFamily: 'Jost',
        bodyColor: ink,
        displayColor: ink,
      ),
      iconTheme: IconThemeData(color: muted),
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: ink),
      ),
      listTileTheme: ListTileThemeData(iconColor: muted, textColor: ink),
      dividerTheme: DividerThemeData(color: line, space: 1),
    );
  }
}
