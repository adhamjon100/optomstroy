// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 31ea2b8fcd4858d3a96d8f15ebdd88453c981902ca331fe859ffb230f2f53d46)
// DsColors - ds.color.* (03 §5.3, §17.2); default palette B «Оранжевый», kernel v1.9 §24.1, ADR-111
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

/// Colour tokens `ds.color.*`. Field names follow kernel §8.1, §17.5, §18.2 item 15.
///
/// Palette B role rule (03 §5.9, DS-098): `primary` is a fill only, always with
/// `onPrimary`; text, prices, links and selection indicators use `primaryText`.
/// ADR-111: white `onPrimary` on `primary` #D9380F is 4.64:1 (AA); white text is forbidden
/// only on orange fills below 4.5:1, e.g. `brandAccent` #FF8700 (2.41:1).
@immutable
class DsColors extends ThemeExtension<DsColors> {
  const DsColors({
    required this.background,
    required this.border,
    required this.borderStrong,
    required this.brandAccent,
    required this.disabledBg,
    required this.disabledText,
    required this.error,
    required this.errorContainer,
    required this.favorite,
    required this.focus,
    required this.iconButtonPressed,
    required this.info,
    required this.infoContainer,
    required this.inverseSurface,
    required this.onBrandAccent,
    required this.onError,
    required this.onInverseSurface,
    required this.onPrimary,
    required this.onPrimaryContainer,
    required this.onSuccess,
    required this.overlay,
    required this.primary,
    required this.primaryContainer,
    required this.primaryContainerBorder,
    required this.primaryContainerPressed,
    required this.primaryHover,
    required this.primaryPressed,
    required this.primaryText,
    required this.skeletonBase,
    required this.skeletonHighlight,
    required this.success,
    required this.successContainer,
    required this.surface,
    required this.surfaceHover,
    required this.surfacePressed,
    required this.surfaceVariant,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.warning,
    required this.warningContainer,
  });

  final Color background;
  final Color border;
  final Color borderStrong;
  final Color brandAccent;
  final Color disabledBg;
  final Color disabledText;
  final Color error;
  final Color errorContainer;
  final Color favorite;
  final Color focus;
  final Color iconButtonPressed;
  final Color info;
  final Color infoContainer;
  final Color inverseSurface;
  final Color onBrandAccent;
  final Color onError;
  final Color onInverseSurface;
  final Color onPrimary;
  final Color onPrimaryContainer;
  final Color onSuccess;
  final Color overlay;
  final Color primary;
  final Color primaryContainer;
  final Color primaryContainerBorder;
  final Color primaryContainerPressed;
  final Color primaryHover;
  final Color primaryPressed;
  final Color primaryText;
  final Color skeletonBase;
  final Color skeletonHighlight;
  final Color success;
  final Color successContainer;
  final Color surface;
  final Color surfaceHover;
  final Color surfacePressed;
  final Color surfaceVariant;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color warning;
  final Color warningContainer;

  /// Palette B «Оранжевый» - main R1 palette (03 §5.3; kernel v1.9 §24.1; values ADR-111).
  static const DsColors lightB = DsColors(
    background: Color(0xFFF1F6FC), // #F1F6FC
    border: Color(0xFFE3E9F2), // #E3E9F2
    borderStrong: Color(0xFF7D879A), // #7D879A
    brandAccent: Color(0xFFFF8700), // #FF8700
    disabledBg: Color(0xFFEEF1F5), // #EEF1F5
    disabledText: Color(0xFF9CA3AF), // #9CA3AF
    error: Color(0xFFD21B1F), // #D21B1F
    errorContainer: Color(0xFFFDEAEA), // #FDEAEA
    favorite: Color(0xFFE2A93B), // #E2A93B
    focus: Color(0xFF1F5FA8), // #1F5FA8
    iconButtonPressed: Color(0xFFE3E9F2), // #E3E9F2
    info: Color(0xFF1F5FA8), // #1F5FA8
    infoContainer: Color(0xFFE0ECFB), // #E0ECFB
    inverseSurface: Color(0xFF0E1456), // #0E1456
    onBrandAccent: Color(0xFF0E1456), // #0E1456
    onError: Color(0xFFFFFFFF), // #FFFFFF
    onInverseSurface: Color(0xFFFFFFFF), // #FFFFFF
    onPrimary: Color(0xFFFFFFFF), // #FFFFFF
    onPrimaryContainer: Color(0xFFA82A09), // #A82A09
    onSuccess: Color(0xFFFFFFFF), // #FFFFFF
    overlay: Color.fromRGBO(14, 20, 86, 0.28), // rgba(14,20,86,0.28)
    primary: Color(0xFFD9380F), // #D9380F
    primaryContainer: Color(0xFFFDEEE9), // #FDEEE9
    primaryContainerBorder: Color(0xFFF5C6B6), // #F5C6B6
    primaryContainerPressed: Color(0xFFFCEAE4), // #FCEAE4
    primaryHover: Color(0xFFBF300B), // #BF300B
    primaryPressed: Color(0xFFA82A09), // #A82A09
    primaryText: Color(0xFFC9330C), // #C9330C
    skeletonBase: Color(0xFFEAF1FB), // #EAF1FB
    skeletonHighlight: Color(0xFFE3E9F2), // #E3E9F2
    success: Color(0xFF177245), // #177245
    successContainer: Color(0xFFDCFCE7), // #DCFCE7
    surface: Color(0xFFFFFFFF), // #FFFFFF
    surfaceHover: Color(0xFFF6F9FE), // #F6F9FE
    surfacePressed: Color(0xFFEAF1FB), // #EAF1FB
    surfaceVariant: Color(0xFFEAF1FB), // #EAF1FB
    textPrimary: Color(0xFF0E1456), // #0E1456
    textSecondary: Color(0xFF5B6478), // #5B6478
    textTertiary: Color(0xFF656E80), // #656E80
    warning: Color(0xFF8A5300), // #8A5300
    warningContainer: Color(0xFFFEF9C3), // #FEF9C3
  );

  /// Rollback alternatives.B_2026_10_21 (Оранжевый (до ADR-111)): AppTheme.light(colors: ...).
  static const DsColors lightB20261021 = DsColors(
    background: Color(0xFFF5F5F4), // #F5F5F4
    border: Color(0xFFDAD8D4), // #DAD8D4
    borderStrong: Color(0xFF7D8797), // #7D8797
    brandAccent: Color(0xFFFF8700), // #FF8700
    disabledBg: Color(0xFFE5E7EB), // #E5E7EB
    disabledText: Color(0xFF9CA3AF), // #9CA3AF
    error: Color(0xFFC62828), // #C62828
    errorContainer: Color(0xFFFDE2E2), // #FDE2E2
    favorite: Color(0xFFFEC50A), // #FEC50A
    focus: Color(0xFF1F5FA8), // #1F5FA8
    iconButtonPressed: Color(0xFFE6E4E1), // #E6E4E1
    info: Color(0xFF1F5FA8), // #1F5FA8
    infoContainer: Color(0xFFE0ECFB), // #E0ECFB
    inverseSurface: Color(0xFF1B1F2A), // #1B1F2A
    onBrandAccent: Color(0xFF1B1F2A), // #1B1F2A
    onError: Color(0xFFFFFFFF), // #FFFFFF
    onInverseSurface: Color(0xFFFFFFFF), // #FFFFFF
    onPrimary: Color(0xFF1B1F2A), // #1B1F2A
    onPrimaryContainer: Color(0xFFB04E00), // #B04E00
    onSuccess: Color(0xFFFFFFFF), // #FFFFFF
    overlay: Color.fromRGBO(27, 31, 42, 0.48), // rgba(27,31,42,0.48)
    primary: Color(0xFFFF8700), // #FF8700
    primaryContainer: Color(0xFFFFEFD9), // #FFEFD9
    primaryContainerBorder: Color(0xFFDAD8D4), // #DAD8D4
    primaryContainerPressed: Color(0xFFFFEAD1), // #FFEAD1
    primaryHover: Color(0xFFF07A00), // #F07A00
    primaryPressed: Color(0xFFD96A00), // #D96A00
    primaryText: Color(0xFFB04E00), // #B04E00
    skeletonBase: Color(0xFFEFEEEC), // #EFEEEC
    skeletonHighlight: Color(0xFFE6E4E1), // #E6E4E1
    success: Color(0xFF15803D), // #15803D
    successContainer: Color(0xFFDCFCE7), // #DCFCE7
    surface: Color(0xFFFFFFFF), // #FFFFFF
    surfaceHover: Color(0xFFF7F6F4), // #F7F6F4
    surfacePressed: Color(0xFFEFEEEC), // #EFEEEC
    surfaceVariant: Color(0xFFEFEEEC), // #EFEEEC
    textPrimary: Color(0xFF1B1F2A), // #1B1F2A
    textSecondary: Color(0xFF5A6373), // #5A6373
    textTertiary: Color(0xFF6B7484), // #6B7484
    warning: Color(0xFF8A6A00), // #8A6A00
    warningContainer: Color(0xFFFEF9C3), // #FEF9C3
  );

  /// Default theme colours (03 §17.2): palette B.
  static const DsColors light = lightB;

  @override
  DsColors copyWith({
    Color? background,
    Color? border,
    Color? borderStrong,
    Color? brandAccent,
    Color? disabledBg,
    Color? disabledText,
    Color? error,
    Color? errorContainer,
    Color? favorite,
    Color? focus,
    Color? iconButtonPressed,
    Color? info,
    Color? infoContainer,
    Color? inverseSurface,
    Color? onBrandAccent,
    Color? onError,
    Color? onInverseSurface,
    Color? onPrimary,
    Color? onPrimaryContainer,
    Color? onSuccess,
    Color? overlay,
    Color? primary,
    Color? primaryContainer,
    Color? primaryContainerBorder,
    Color? primaryContainerPressed,
    Color? primaryHover,
    Color? primaryPressed,
    Color? primaryText,
    Color? skeletonBase,
    Color? skeletonHighlight,
    Color? success,
    Color? successContainer,
    Color? surface,
    Color? surfaceHover,
    Color? surfacePressed,
    Color? surfaceVariant,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? warning,
    Color? warningContainer,
  }) {
    return DsColors(
      background: background ?? this.background,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      brandAccent: brandAccent ?? this.brandAccent,
      disabledBg: disabledBg ?? this.disabledBg,
      disabledText: disabledText ?? this.disabledText,
      error: error ?? this.error,
      errorContainer: errorContainer ?? this.errorContainer,
      favorite: favorite ?? this.favorite,
      focus: focus ?? this.focus,
      iconButtonPressed: iconButtonPressed ?? this.iconButtonPressed,
      info: info ?? this.info,
      infoContainer: infoContainer ?? this.infoContainer,
      inverseSurface: inverseSurface ?? this.inverseSurface,
      onBrandAccent: onBrandAccent ?? this.onBrandAccent,
      onError: onError ?? this.onError,
      onInverseSurface: onInverseSurface ?? this.onInverseSurface,
      onPrimary: onPrimary ?? this.onPrimary,
      onPrimaryContainer: onPrimaryContainer ?? this.onPrimaryContainer,
      onSuccess: onSuccess ?? this.onSuccess,
      overlay: overlay ?? this.overlay,
      primary: primary ?? this.primary,
      primaryContainer: primaryContainer ?? this.primaryContainer,
      primaryContainerBorder: primaryContainerBorder ?? this.primaryContainerBorder,
      primaryContainerPressed: primaryContainerPressed ?? this.primaryContainerPressed,
      primaryHover: primaryHover ?? this.primaryHover,
      primaryPressed: primaryPressed ?? this.primaryPressed,
      primaryText: primaryText ?? this.primaryText,
      skeletonBase: skeletonBase ?? this.skeletonBase,
      skeletonHighlight: skeletonHighlight ?? this.skeletonHighlight,
      success: success ?? this.success,
      successContainer: successContainer ?? this.successContainer,
      surface: surface ?? this.surface,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      surfacePressed: surfacePressed ?? this.surfacePressed,
      surfaceVariant: surfaceVariant ?? this.surfaceVariant,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
    );
  }

  @override
  DsColors lerp(DsColors? other, double t) {
    if (other == null) {
      return this;
    }
    return DsColors(
      background: Color.lerp(background, other.background, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      brandAccent: Color.lerp(brandAccent, other.brandAccent, t)!,
      disabledBg: Color.lerp(disabledBg, other.disabledBg, t)!,
      disabledText: Color.lerp(disabledText, other.disabledText, t)!,
      error: Color.lerp(error, other.error, t)!,
      errorContainer: Color.lerp(errorContainer, other.errorContainer, t)!,
      favorite: Color.lerp(favorite, other.favorite, t)!,
      focus: Color.lerp(focus, other.focus, t)!,
      iconButtonPressed: Color.lerp(iconButtonPressed, other.iconButtonPressed, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoContainer: Color.lerp(infoContainer, other.infoContainer, t)!,
      inverseSurface: Color.lerp(inverseSurface, other.inverseSurface, t)!,
      onBrandAccent: Color.lerp(onBrandAccent, other.onBrandAccent, t)!,
      onError: Color.lerp(onError, other.onError, t)!,
      onInverseSurface: Color.lerp(onInverseSurface, other.onInverseSurface, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      onPrimaryContainer: Color.lerp(onPrimaryContainer, other.onPrimaryContainer, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      overlay: Color.lerp(overlay, other.overlay, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      primaryContainer: Color.lerp(primaryContainer, other.primaryContainer, t)!,
      primaryContainerBorder: Color.lerp(primaryContainerBorder, other.primaryContainerBorder, t)!,
      primaryContainerPressed: Color.lerp(primaryContainerPressed, other.primaryContainerPressed, t)!,
      primaryHover: Color.lerp(primaryHover, other.primaryHover, t)!,
      primaryPressed: Color.lerp(primaryPressed, other.primaryPressed, t)!,
      primaryText: Color.lerp(primaryText, other.primaryText, t)!,
      skeletonBase: Color.lerp(skeletonBase, other.skeletonBase, t)!,
      skeletonHighlight: Color.lerp(skeletonHighlight, other.skeletonHighlight, t)!,
      success: Color.lerp(success, other.success, t)!,
      successContainer: Color.lerp(successContainer, other.successContainer, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceHover: Color.lerp(surfaceHover, other.surfaceHover, t)!,
      surfacePressed: Color.lerp(surfacePressed, other.surfacePressed, t)!,
      surfaceVariant: Color.lerp(surfaceVariant, other.surfaceVariant, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer: Color.lerp(warningContainer, other.warningContainer, t)!,
    );
  }
}
