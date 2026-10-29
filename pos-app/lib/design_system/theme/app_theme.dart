// Тема приложения (RM-C-003; 03 §17.7). Только светлая тема, палитра B «Оранжевый»
// (ядро v1.9 §24.1; значения по утверждённому прототипу — ADR-111); тёмной темы нет (D-43, 03 DS-010 — R2).
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_elevation.dart';
import 'package:optomstroy/design_system/tokens/ds_motion.dart';
import 'package:optomstroy/design_system/tokens/ds_radii.dart';
import 'package:optomstroy/design_system/tokens/ds_spacing.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Тема приложения.
abstract final class AppTheme {
  /// Светлая тема (единственная в R1). [colors] — палитра (по умолчанию B, 03 §17.7).
  /// Откат палитры ADR-111 — `AppTheme.light(colors: DsColors.lightB20261021)` (генерируется
  /// всегда); возврат к исторической A+ — `AppTheme.light(colors: DsColors.lightA)` при генерации
  /// токенов с `--with-alternative-a` (03 §5.9 п. 8).
  ///
  /// Палитра B (ADR-111): `ColorScheme.primary` (#D9380F) — только заливка с белым `onPrimary`
  /// (4.64:1); как текст он проходит AA лишь на `surface`, поэтому Material-виджеты, рисующие его
  /// текстом или единственной обводкой, на экранах напрямую не применяются — только компоненты
  /// `design_system/components` с ролями 03 §5.9 (DS-098). Те роли Material, которые всё же рисуют
  /// «акцент» текстом/обводкой (`secondary`, курсор, выделение), направлены на `primaryText`;
  /// текст на тинте `primaryContainer` — `onPrimaryContainer`.
  static ThemeData light({DsColors colors = DsColors.lightB}) {
    const DsTypography text = DsTypography.inter;
    final ColorScheme scheme = colorSchemeOf(colors);
    final TextTheme textTheme = textThemeOf(text, colors);
    final RoundedRectangleBorder smShape = RoundedRectangleBorder(borderRadius: BorderRadius.all(DsRadii.defaults.sm));

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      fontFamily: DsTypography.fontFamily,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      scaffoldBackgroundColor: colors.background,
      canvasColor: colors.surface,
      cardColor: colors.surface,
      dividerColor: colors.border,
      disabledColor: colors.disabledText,
      focusColor: colors.focus.withValues(alpha: 0.12),
      hoverColor: colors.surfaceHover,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      // Pressed рисуется токенами компонентов, «чернильного» всплеска нет (03 §17.7).
      splashFactory: NoSplash.splashFactory,
      visualDensity: VisualDensity.standard,
      // Тач-цель 48 lp (03 §7.4, A11Y).
      materialTapTargetSize: MaterialTapTargetSize.padded,
      iconTheme: IconThemeData(color: colors.textSecondary, size: 24),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colors.primaryText,
        selectionColor: colors.primaryContainer,
        selectionHandleColor: colors.primaryText,
      ),
      dividerTheme: DividerThemeData(color: colors.border, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.title.copyWith(color: colors.textPrimary),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        barrierColor: colors.overlay,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(DsRadii.defaults.lg)),
        titleTextStyle: text.h3.copyWith(color: colors.textPrimary),
        contentTextStyle: text.body.copyWith(color: colors.textSecondary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: colors.overlay,
        shape: RoundedRectangleBorder(borderRadius: DsRadii.defaults.sheetTop),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.inverseSurface,
        contentTextStyle: text.body.copyWith(color: colors.onInverseSurface),
        actionTextColor: colors.primaryContainer,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(DsRadii.defaults.md)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: colors.inverseSurface, borderRadius: BorderRadius.all(DsRadii.defaults.sm)),
        textStyle: text.captionMedium.copyWith(color: colors.onInverseSurface),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        waitDuration: const Duration(milliseconds: 500),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.primaryText,
        linearTrackColor: colors.primaryContainer,
        circularTrackColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surface,
        hintStyle: text.bodyLg.copyWith(color: colors.textTertiary),
        labelStyle: text.label.copyWith(color: colors.textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(DsRadii.defaults.sm),
          borderSide: BorderSide(color: colors.borderStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(DsRadii.defaults.sm),
          borderSide: BorderSide(color: colors.borderStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(DsRadii.defaults.sm),
          borderSide: BorderSide(color: colors.primaryText, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(DsRadii.defaults.sm),
          borderSide: BorderSide(color: colors.error, width: 2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(DsRadii.defaults.sm),
          borderSide: BorderSide(color: colors.error, width: 2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(DsRadii.defaults.sm),
          borderSide: BorderSide(color: colors.disabledText),
        ),
      ),
      // Material-кнопки, если всё же окажутся на экране, получают роли палитры B:
      // заливка primary только с onPrimary (белый, 4.64:1 — ADR-111); текстовые — primaryText.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: colors.onPrimary,
          disabledBackgroundColor: colors.disabledBg,
          disabledForegroundColor: colors.disabledText,
          shape: smShape,
          textStyle: text.body.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.primaryText,
          shape: smShape,
          textStyle: text.body.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.primaryText,
          side: BorderSide(color: colors.primaryText, width: 1.5),
          shape: smShape,
          textStyle: text.body.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      extensions: <ThemeExtension<dynamic>>[
        colors,
        text,
        DsSpacing.defaults,
        DsRadii.defaults,
        DsElevation.defaults,
        DsMotion.defaults,
      ],
    );
  }

  /// Material `ColorScheme` из `DsColors` (03 §17.7): primary←primary, onPrimary←onPrimary,
  /// surface←surface, error←error, onError←onError, outline←borderStrong,
  /// outlineVariant←border, surfaceContainerHighest←surfaceVariant,
  /// onPrimaryContainer←onPrimaryContainer (ADR-111); текстовые «акценты» — `primaryText`
  /// (палитра B, DS-098).
  static ColorScheme colorSchemeOf(DsColors c) {
    return ColorScheme(
      brightness: Brightness.light,
      primary: c.primary,
      onPrimary: c.onPrimary,
      primaryContainer: c.primaryContainer,
      onPrimaryContainer: c.onPrimaryContainer,
      primaryFixed: c.primaryContainer,
      primaryFixedDim: c.primaryContainerPressed,
      onPrimaryFixed: c.textPrimary,
      onPrimaryFixedVariant: c.primaryText,
      secondary: c.primaryText,
      onSecondary: c.surface,
      secondaryContainer: c.primaryContainer,
      onSecondaryContainer: c.textPrimary,
      tertiary: c.info,
      onTertiary: c.surface,
      tertiaryContainer: c.infoContainer,
      onTertiaryContainer: c.textPrimary,
      error: c.error,
      onError: c.onError,
      errorContainer: c.errorContainer,
      onErrorContainer: c.textPrimary,
      surface: c.surface,
      onSurface: c.textPrimary,
      onSurfaceVariant: c.textSecondary,
      surfaceDim: c.background,
      surfaceBright: c.surface,
      surfaceContainerLowest: c.surface,
      surfaceContainerLow: c.surfaceHover,
      surfaceContainer: c.background,
      surfaceContainerHigh: c.surfacePressed,
      surfaceContainerHighest: c.surfaceVariant,
      outline: c.borderStrong,
      outlineVariant: c.border,
      shadow: c.inverseSurface,
      scrim: c.overlay,
      inverseSurface: c.inverseSurface,
      onInverseSurface: c.onInverseSurface,
      inversePrimary: c.primaryContainer,
      surfaceTint: Colors.transparent,
    );
  }

  /// Material `TextTheme` из `DsTypography` (03 §17.3): displaySmall←display, headlineMedium←h1,
  /// headlineSmall←h2, titleLarge←h3, titleMedium←title, bodyLarge←bodyLg, bodyMedium←body,
  /// labelLarge←label, bodySmall←caption, labelSmall←micro. Цвет — `textPrimary`
  /// (caption — `textSecondary`: 03 §6.2 «только textSecondary или темнее»).
  static TextTheme textThemeOf(DsTypography t, DsColors c) {
    TextStyle p(TextStyle s) => s.copyWith(color: c.textPrimary);
    return TextTheme(
      displayLarge: p(t.display),
      displayMedium: p(t.display),
      displaySmall: p(t.display),
      headlineLarge: p(t.h1),
      headlineMedium: p(t.h1),
      headlineSmall: p(t.h2),
      titleLarge: p(t.h3),
      titleMedium: p(t.title),
      titleSmall: p(t.bodyMedium),
      bodyLarge: p(t.bodyLg),
      bodyMedium: p(t.body),
      bodySmall: t.caption.copyWith(color: c.textSecondary),
      labelLarge: p(t.label),
      labelMedium: p(t.label),
      labelSmall: p(t.micro),
    );
  }
}
