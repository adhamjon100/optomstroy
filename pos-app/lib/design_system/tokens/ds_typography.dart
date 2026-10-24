// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 7ecbb28dd87e801deb0bbceb2845ab534f53e844aa8f18b39bf05f36dee13ced)
// DsTypography - ds.text.* (03 §6.2, §17.3)
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

/// Text scale `ds.text.*` (font family Inter, D-17). Sizes in logical pixels.
@immutable
class DsTypography extends ThemeExtension<DsTypography> {
  const DsTypography({
    required this.display,
    required this.h1,
    required this.h2,
    required this.h3,
    required this.title,
    required this.bodyLg,
    required this.body,
    required this.label,
    required this.caption,
    required this.micro,
  });

  /// 32/40/700, letter-spacing -0.2; contrast class: large.
  final TextStyle display;

  /// 28/36/700, letter-spacing -0.2; contrast class: large.
  final TextStyle h1;

  /// 24/32/600, letter-spacing -0.2; contrast class: large.
  final TextStyle h2;

  /// 20/28/600, letter-spacing 0; contrast class: normal.
  final TextStyle h3;

  /// 18/26/600, letter-spacing 0; contrast class: normal.
  final TextStyle title;

  /// 16/24/400, letter-spacing 0; contrast class: normal.
  final TextStyle bodyLg;

  /// 14/20/400, letter-spacing 0; contrast class: normal.
  final TextStyle body;

  /// 13/18/500, letter-spacing 0; contrast class: normal.
  final TextStyle label;

  /// 12/16/400, letter-spacing 0; contrast class: normal.
  final TextStyle caption;

  /// 11/14/600, letter-spacing 0; contrast class: normal.
  final TextStyle micro;

  /// Tabular figures for prices, stock, quantities, codes, OTP timers (03 §6.1).
  static const List<FontFeature> numeric = <FontFeature>[FontFeature.tabularFigures()];

  static const String fontFamily = 'Inter';

  /// Scale of 03 §6.2 with the Inter family.
  static const DsTypography inter = DsTypography(
    display: TextStyle(
      fontFamily: fontFamily,
      fontSize: 32,
      height: 40 / 32,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    h1: TextStyle(
      fontFamily: fontFamily,
      fontSize: 28,
      height: 36 / 28,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    h2: TextStyle(
      fontFamily: fontFamily,
      fontSize: 24,
      height: 32 / 24,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
    ),
    h3: TextStyle(fontFamily: fontFamily, fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w600, letterSpacing: 0),
    title: TextStyle(
      fontFamily: fontFamily,
      fontSize: 18,
      height: 26 / 18,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    bodyLg: TextStyle(
      fontFamily: fontFamily,
      fontSize: 16,
      height: 24 / 16,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    ),
    body: TextStyle(
      fontFamily: fontFamily,
      fontSize: 14,
      height: 20 / 14,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    ),
    label: TextStyle(
      fontFamily: fontFamily,
      fontSize: 13,
      height: 18 / 13,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    ),
    caption: TextStyle(
      fontFamily: fontFamily,
      fontSize: 12,
      height: 16 / 12,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    ),
    micro: TextStyle(
      fontFamily: fontFamily,
      fontSize: 11,
      height: 14 / 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
  );

  /// `bodyLg` with weight 500.
  TextStyle get bodyLgMedium => bodyLg.copyWith(fontWeight: FontWeight.w500);

  /// `body` with weight 500.
  TextStyle get bodyMedium => body.copyWith(fontWeight: FontWeight.w500);

  /// `caption` with weight 500.
  TextStyle get captionMedium => caption.copyWith(fontWeight: FontWeight.w500);

  /// Price: bodyLg/700 + tabular figures.
  TextStyle get price => priceOf(bodyLg);

  /// Any scale step as a price: weight and tabular figures (03 §6.2 rules).
  TextStyle priceOf(TextStyle base) => base.copyWith(fontWeight: FontWeight.w700, fontFeatures: numeric);

  @override
  DsTypography copyWith({
    TextStyle? display,
    TextStyle? h1,
    TextStyle? h2,
    TextStyle? h3,
    TextStyle? title,
    TextStyle? bodyLg,
    TextStyle? body,
    TextStyle? label,
    TextStyle? caption,
    TextStyle? micro,
  }) {
    return DsTypography(
      display: display ?? this.display,
      h1: h1 ?? this.h1,
      h2: h2 ?? this.h2,
      h3: h3 ?? this.h3,
      title: title ?? this.title,
      bodyLg: bodyLg ?? this.bodyLg,
      body: body ?? this.body,
      label: label ?? this.label,
      caption: caption ?? this.caption,
      micro: micro ?? this.micro,
    );
  }

  @override
  DsTypography lerp(DsTypography? other, double t) {
    if (other == null) {
      return this;
    }
    return DsTypography(
      display: TextStyle.lerp(display, other.display, t)!,
      h1: TextStyle.lerp(h1, other.h1, t)!,
      h2: TextStyle.lerp(h2, other.h2, t)!,
      h3: TextStyle.lerp(h3, other.h3, t)!,
      title: TextStyle.lerp(title, other.title, t)!,
      bodyLg: TextStyle.lerp(bodyLg, other.bodyLg, t)!,
      body: TextStyle.lerp(body, other.body, t)!,
      label: TextStyle.lerp(label, other.label, t)!,
      caption: TextStyle.lerp(caption, other.caption, t)!,
      micro: TextStyle.lerp(micro, other.micro, t)!,
    );
  }
}
