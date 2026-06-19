import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class SaturnTheme {
  const SaturnTheme._();

  static const voidBg = Color(0xFF080808);
  static const surface = Color(0xFF0F0F0F);
  static const surfaceAlt = Color(0xFF161616);
  static const border = Color(0xFF1E1E1E);
  static const meshAccent = Color(0xFF00FFCC);
  static const cyan = Color(0xFF64C8FF);
  static const textPrimary = Color(0xFFF0F0F0);
  static const textSecondary = Color(0xFF888888);
  static const textMuted = Color(0xFF444444);
  static const error = Color(0xFFFF4D4D);

  static TextStyle get mono => const TextStyle(fontFamily: 'JetBrainsMono');

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    final textTheme = GoogleFonts.syneTextTheme(
      base.textTheme,
    ).apply(bodyColor: textPrimary, displayColor: textPrimary);

    return base.copyWith(
      scaffoldBackgroundColor: voidBg,
      colorScheme: const ColorScheme.dark(
        primary: meshAccent,
        secondary: cyan,
        surface: surface,
        error: error,
        onPrimary: voidBg,
        onSecondary: voidBg,
        onSurface: textPrimary,
        onError: textPrimary,
      ),
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleMedium?.copyWith(
          color: textPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceAlt,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        hintStyle: const TextStyle(color: textMuted),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: const BorderSide(color: meshAccent, width: 1.4),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: border,
        thickness: 1,
        space: 1,
      ),
      iconTheme: const IconThemeData(color: textSecondary),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: meshAccent,
        linearTrackColor: border,
        circularTrackColor: border,
      ),
    );
  }
}
