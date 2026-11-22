import 'package:flutter/material.dart';

/// Six accent color presets inspired by Antigravity & DSH Go.
enum AgyAccentPreset {
  indigo('Antigravity Indigo', Color(0xFF4F6BFF)),
  cyan('Neon Cyan', Color(0xFF00B4D8)),
  violet('Argon Violet', Color(0xFF8B5CF6)),
  emerald('Hydrogen Emerald', Color(0xFF10B981)),
  slate('Carbon Slate', Color(0xFF64748B)),
  amber('Solar Amber', Color(0xFFF59E0B));

  const AgyAccentPreset(this.label, this.seed);

  final String label;
  final Color seed;
}

class AgyTheme {
  const AgyTheme._();

  static ThemeData build({
    required Brightness brightness,
    required AgyAccentPreset accent,
  }) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent.seed,
      brightness: brightness,
    );

    final scaffoldBg =
        isDark ? const Color(0xFF0B0E17) : const Color(0xFFF4F6FB);
    final cardBg =
        isDark ? const Color(0xFF131826) : const Color(0xFFFFFFFF);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBg,
      cardTheme: CardThemeData(
        color: cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: scheme.outlineVariant.withOpacity(isDark ? 0.28 : 0.5),
          ),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? const Color(0xFF1A2033)
            : const Color(0xFFEBEFF8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }
}
