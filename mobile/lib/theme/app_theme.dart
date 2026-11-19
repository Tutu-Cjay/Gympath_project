import 'package:flutter/material.dart';

class AppTheme {
  static const Color neonGreen = Color(0xFF00FF88);
  static const Color neonGreenDim = Color(0xFF00CC6A);
  static const Color darkBg = Color(0xFF0D0D0D);
  static const Color cardBg = Color(0xFF1A1A1A);
  static const Color cardBgLight = Color(0xFF252525);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB0B0B0);
  static const Color textMuted = Color(0xFF6B6B6B);

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: false,
      fontFamily: 'Roboto',
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBg,
      primaryColor: neonGreen,
      colorScheme: const ColorScheme.dark(
        primary: neonGreen,
        secondary: neonGreenDim,
        surface: cardBg,
        error: Color(0xFFFF4444),
        onPrimary: Colors.black,
        onSecondary: Colors.black,
        onSurface: textPrimary,
        onError: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      // Choice chips (plan days, map modes, leaderboard sorting): the chosen
      // one in green.
      chipTheme: const ChipThemeData(
        backgroundColor: cardBgLight,
        selectedColor: neonGreen,
        secondarySelectedColor: neonGreen,
        labelStyle: TextStyle(color: textPrimary, fontSize: 13),
        secondaryLabelStyle: TextStyle(
            color: Colors.black, fontSize: 13, fontWeight: FontWeight.w700),
        showCheckmark: false,
      ),
      cardTheme: CardThemeData(
        color: cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: neonGreen,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: cardBg,
        selectedItemColor: neonGreen,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}
