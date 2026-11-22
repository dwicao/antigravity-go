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

/// WCAG-verified semantic palette modeled on DSH-Go's `DshColors` so code wells,
/// inline code, quotes, tables, tool chips, and diff blocks stay readable in both
/// Dark and Light themes.
class AgySemanticColors extends ThemeExtension<AgySemanticColors> {
  const AgySemanticColors({
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.codeWellBg,
    required this.codeWellHeader,
    required this.codeWellFg,
    required this.codeWellBorder,
    required this.inlineCodeBg,
    required this.inlineCodeFg,
    required this.quoteBar,
    required this.quoteText,
    required this.tableHeaderBg,
    required this.tableStripeBg,
    required this.tableBorder,
    required this.diffAddBg,
    required this.diffAddFg,
    required this.diffDelBg,
    required this.diffDelFg,
    required this.diffHunkFg,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.warningContainer,
    required this.onWarningContainer,
  });

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color codeWellBg;
  final Color codeWellHeader;
  final Color codeWellFg;
  final Color codeWellBorder;
  final Color inlineCodeBg;
  final Color inlineCodeFg;
  final Color quoteBar;
  final Color quoteText;
  final Color tableHeaderBg;
  final Color tableStripeBg;
  final Color tableBorder;
  final Color diffAddBg;
  final Color diffAddFg;
  final Color diffDelBg;
  final Color diffDelFg;
  final Color diffHunkFg;
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color warningContainer;
  final Color onWarningContainer;

  static AgySemanticColors of(BuildContext context) {
    final ext = Theme.of(context).extension<AgySemanticColors>();
    if (ext != null) return ext;
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }

  static const light = AgySemanticColors(
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF334155),
    textTertiary: Color(0xFF64748B),
    codeWellBg: Color(0xFFEDF0F6),
    codeWellHeader: Color(0xFFE2E7F0),
    codeWellFg: Color(0xFF1E232E),
    codeWellBorder: Color(0xFFD5DCE6),
    inlineCodeBg: Color(0xFFE7ECF4),
    inlineCodeFg: Color(0xFF172033),
    quoteBar: Color(0xFF94A3B8),
    quoteText: Color(0xFF334155),
    tableHeaderBg: Color(0xFFE7ECF4),
    tableStripeBg: Color(0xFFF6F8FC),
    tableBorder: Color(0xFFCBD5E1),
    diffAddBg: Color(0xFFDCF4E3),
    diffAddFg: Color(0xFF1F613C),
    diffDelBg: Color(0xFFFFE4E2),
    diffDelFg: Color(0xFF923A37),
    diffHunkFg: Color(0xFF4F5562),
    success: Color(0xFF2E7D5B),
    warning: Color(0xFF9A6319),
    danger: Color(0xFFB33A36),
    info: Color(0xFF2563EB),
    warningContainer: Color(0xFFF9E9CE),
    onWarningContainer: Color(0xFF55350D),
  );

  static const dark = AgySemanticColors(
    textPrimary: Color(0xFFF1F5F9),
    textSecondary: Color(0xFFCBD5E1),
    textTertiary: Color(0xFF94A3B8),
    codeWellBg: Color(0xFF111622),
    codeWellHeader: Color(0xFF192133),
    codeWellFg: Color(0xFFE6E9F0),
    codeWellBorder: Color(0xFF2F3952),
    inlineCodeBg: Color(0xFF1D263B),
    inlineCodeFg: Color(0xFFE6ECF7),
    quoteBar: Color(0xFF64748B),
    quoteText: Color(0xFFCBD5E1),
    tableHeaderBg: Color(0xFF1A2234),
    tableStripeBg: Color(0xFF131928),
    tableBorder: Color(0xFF334155),
    diffAddBg: Color(0xFF1C3424),
    diffAddFg: Color(0xFF98D5AC),
    diffDelBg: Color(0xFF422423),
    diffDelFg: Color(0xFFF2A7A1),
    diffHunkFg: Color(0xFFA0C6FF),
    success: Color(0xFF8BCCA6),
    warning: Color(0xFFE6BD7C),
    danger: Color(0xFFF28B82),
    info: Color(0xFF8CBDE8),
    warningContainer: Color(0xFF4C371D),
    onWarningContainer: Color(0xFFF4E2C3),
  );

  @override
  AgySemanticColors copyWith({
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? codeWellBg,
    Color? codeWellHeader,
    Color? codeWellFg,
    Color? codeWellBorder,
    Color? inlineCodeBg,
    Color? inlineCodeFg,
    Color? quoteBar,
    Color? quoteText,
    Color? tableHeaderBg,
    Color? tableStripeBg,
    Color? tableBorder,
    Color? diffAddBg,
    Color? diffAddFg,
    Color? diffDelBg,
    Color? diffDelFg,
    Color? diffHunkFg,
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? warningContainer,
    Color? onWarningContainer,
  }) {
    return AgySemanticColors(
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      codeWellBg: codeWellBg ?? this.codeWellBg,
      codeWellHeader: codeWellHeader ?? this.codeWellHeader,
      codeWellFg: codeWellFg ?? this.codeWellFg,
      codeWellBorder: codeWellBorder ?? this.codeWellBorder,
      inlineCodeBg: inlineCodeBg ?? this.inlineCodeBg,
      inlineCodeFg: inlineCodeFg ?? this.inlineCodeFg,
      quoteBar: quoteBar ?? this.quoteBar,
      quoteText: quoteText ?? this.quoteText,
      tableHeaderBg: tableHeaderBg ?? this.tableHeaderBg,
      tableStripeBg: tableStripeBg ?? this.tableStripeBg,
      tableBorder: tableBorder ?? this.tableBorder,
      diffAddBg: diffAddBg ?? this.diffAddBg,
      diffAddFg: diffAddFg ?? this.diffAddFg,
      diffDelBg: diffDelBg ?? this.diffDelBg,
      diffDelFg: diffDelFg ?? this.diffDelFg,
      diffHunkFg: diffHunkFg ?? this.diffHunkFg,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      info: info ?? this.info,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
    );
  }

  @override
  AgySemanticColors lerp(covariant ThemeExtension<AgySemanticColors>? other, double t) {
    if (other is! AgySemanticColors) return this;
    return AgySemanticColors(
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t) ?? textPrimary,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t) ?? textSecondary,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t) ?? textTertiary,
      codeWellBg: Color.lerp(codeWellBg, other.codeWellBg, t) ?? codeWellBg,
      codeWellHeader: Color.lerp(codeWellHeader, other.codeWellHeader, t) ?? codeWellHeader,
      codeWellFg: Color.lerp(codeWellFg, other.codeWellFg, t) ?? codeWellFg,
      codeWellBorder: Color.lerp(codeWellBorder, other.codeWellBorder, t) ?? codeWellBorder,
      inlineCodeBg: Color.lerp(inlineCodeBg, other.inlineCodeBg, t) ?? inlineCodeBg,
      inlineCodeFg: Color.lerp(inlineCodeFg, other.inlineCodeFg, t) ?? inlineCodeFg,
      quoteBar: Color.lerp(quoteBar, other.quoteBar, t) ?? quoteBar,
      quoteText: Color.lerp(quoteText, other.quoteText, t) ?? quoteText,
      tableHeaderBg: Color.lerp(tableHeaderBg, other.tableHeaderBg, t) ?? tableHeaderBg,
      tableStripeBg: Color.lerp(tableStripeBg, other.tableStripeBg, t) ?? tableStripeBg,
      tableBorder: Color.lerp(tableBorder, other.tableBorder, t) ?? tableBorder,
      diffAddBg: Color.lerp(diffAddBg, other.diffAddBg, t) ?? diffAddBg,
      diffAddFg: Color.lerp(diffAddFg, other.diffAddFg, t) ?? diffAddFg,
      diffDelBg: Color.lerp(diffDelBg, other.diffDelBg, t) ?? diffDelBg,
      diffDelFg: Color.lerp(diffDelFg, other.diffDelFg, t) ?? diffDelFg,
      diffHunkFg: Color.lerp(diffHunkFg, other.diffHunkFg, t) ?? diffHunkFg,
      success: Color.lerp(success, other.success, t) ?? success,
      warning: Color.lerp(warning, other.warning, t) ?? warning,
      danger: Color.lerp(danger, other.danger, t) ?? danger,
      info: Color.lerp(info, other.info, t) ?? info,
      warningContainer: Color.lerp(warningContainer, other.warningContainer, t) ?? warningContainer,
      onWarningContainer: Color.lerp(onWarningContainer, other.onWarningContainer, t) ?? onWarningContainer,
    );
  }
}

class AgyTheme {
  const AgyTheme._();

  static ThemeData build({
    required Brightness brightness,
    required AgyAccentPreset accent,
  }) {
    final isDark = brightness == Brightness.dark;
    final semantic = isDark ? AgySemanticColors.dark : AgySemanticColors.light;
    final baseScheme = ColorScheme.fromSeed(
      seedColor: accent.seed,
      brightness: brightness,
    );

    final scaffoldBg =
        isDark ? const Color(0xFF0B0E17) : const Color(0xFFF4F6FB);
    final cardBg =
        isDark ? const Color(0xFF131826) : const Color(0xFFFFFFFF);
    final elevatedBg =
        isDark ? const Color(0xFF1A2234) : const Color(0xFFEBEFF8);

    // Anchor onSurface / onSurfaceVariant to high-contrast WCAG colors so neither
    // Flutter widgets nor GptMarkdown ever fall back to low-contrast grays.
    final scheme = baseScheme.copyWith(
      surface: cardBg,
      onSurface: semantic.textPrimary,
      onSurfaceVariant: semantic.textSecondary,
      surfaceContainerLow: scaffoldBg,
      surfaceContainer: cardBg,
      surfaceContainerHigh: elevatedBg,
      surfaceContainerHighest: isDark ? const Color(0xFF212B40) : const Color(0xFFE2E8F2),
      outlineVariant: isDark ? const Color(0xFF2B354C) : const Color(0xFFCBD5E1),
      primary: isDark ? const Color(0xFF8AA2FF) : baseScheme.primary,
    );

    final baseTextTheme =
        (isDark ? ThemeData.dark() : ThemeData.light()).textTheme.apply(
              bodyColor: semantic.textPrimary,
              displayColor: semantic.textPrimary,
            );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBg,
      textTheme: baseTextTheme.copyWith(
        bodyLarge: baseTextTheme.bodyLarge?.copyWith(color: semantic.textPrimary),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(color: semantic.textPrimary),
        bodySmall: baseTextTheme.bodySmall?.copyWith(color: semantic.textSecondary),
        titleMedium: baseTextTheme.titleMedium?.copyWith(color: semantic.textPrimary),
        titleSmall: baseTextTheme.titleSmall?.copyWith(color: semantic.textPrimary),
        labelLarge: baseTextTheme.labelLarge?.copyWith(color: semantic.textPrimary),
        labelMedium: baseTextTheme.labelMedium?.copyWith(color: semantic.textSecondary),
        labelSmall: baseTextTheme.labelSmall?.copyWith(color: semantic.textTertiary),
      ),
      extensions: [semantic],
      cardTheme: CardThemeData(
        color: cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: scheme.outlineVariant.withOpacity(isDark ? 0.55 : 0.65),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        textColor: semantic.textPrimary,
        iconColor: semantic.textSecondary,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        textColor: semantic.textPrimary,
        collapsedTextColor: semantic.textPrimary,
        iconColor: semantic.textSecondary,
        collapsedIconColor: semantic.textSecondary,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: elevatedBg,
        textStyle: TextStyle(color: semantic.textPrimary),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardBg,
        titleTextStyle: TextStyle(
          color: semantic.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(
          color: semantic.textSecondary,
          fontSize: 14,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: semantic.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: semantic.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: elevatedBg,
        hintStyle: TextStyle(color: semantic.textTertiary),
        labelStyle: TextStyle(color: semantic.textSecondary),
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
