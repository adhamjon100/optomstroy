// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 9cbac28624a1540f8761044b1d6bc2c865186b343d294504be661658cfe83dd5)
// DsElevation - ds.elevation.0..3 (03 §7.6, §17.4; kernel §8.3) + component shadows (ADR-114)
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

/// Shadows `ds.elevation.*` (kernel §8.3 has priority over R4 §5.4, kernel §17.5).
///
/// Component shadows (ADR-114) are the prototype values on the `textPrimary` base rgba(14,20,86,a);
/// e0...e3 keep the kernel §8.3 values for the other screens.
@immutable
class DsElevation extends ThemeExtension<DsElevation> {
  const DsElevation({
    required this.e0,
    required this.e1,
    required this.e2,
    required this.e3,
    required this.cardHover,
    required this.ribbonArrow,
    required this.drawer,
    required this.toast,
    required this.overlay,
  });

  /// `ds.elevation.0`: 0 shadow(s); border `border` 1 px.
  final List<BoxShadow> e0;

  /// `ds.elevation.1`: 1 shadow(s); border `border` 1 px.
  final List<BoxShadow> e1;

  /// `ds.elevation.2`: 1 shadow(s); no border.
  final List<BoxShadow> e2;

  /// `ds.elevation.3`: 1 shadow(s); `overlay` scrim under the element.
  final List<BoxShadow> e3;

  /// `ds.elevation.cardHover` (ADR-114): hover of a product card and a list row; 0 6 18 0 rgba(14,20,86,0.1); base
  /// `textPrimary`; border `border` 1 px.
  final List<BoxShadow> cardHover;

  /// `ds.elevation.ribbonArrow` (ADR-114): subcategory ribbon arrows; 0 4 12 0 rgba(14,20,86,0.14); base `textPrimary`;
  /// border `border` 1 px.
  final List<BoxShadow> ribbonArrow;

  /// `ds.elevation.drawer` (ADR-114): cart drawer; -12 0 40 0 rgba(14,20,86,0.18); base `textPrimary`; `overlay` scrim
  /// under the element.
  final List<BoxShadow> drawer;

  /// `ds.elevation.toast` (ADR-114): catalog toast; 0 10 30 0 rgba(14,20,86,0.3); base `textPrimary`.
  final List<BoxShadow> toast;

  /// Scrim colour (= `DsColors.overlay`).
  final Color overlay;

  static const DsElevation defaults = DsElevation(
    e0: <BoxShadow>[],
    e1: <BoxShadow>[
      BoxShadow(color: Color.fromRGBO(27, 31, 42, 0.06), offset: Offset(0, 1), blurRadius: 2, spreadRadius: 0),
    ],
    e2: <BoxShadow>[
      BoxShadow(color: Color.fromRGBO(27, 31, 42, 0.08), offset: Offset(0, 2), blurRadius: 8, spreadRadius: 0),
    ],
    e3: <BoxShadow>[
      BoxShadow(color: Color.fromRGBO(27, 31, 42, 0.12), offset: Offset(0, 8), blurRadius: 24, spreadRadius: 0),
    ],
    cardHover: <BoxShadow>[
      BoxShadow(color: Color.fromRGBO(14, 20, 86, 0.1), offset: Offset(0, 6), blurRadius: 18, spreadRadius: 0),
    ],
    ribbonArrow: <BoxShadow>[
      BoxShadow(color: Color.fromRGBO(14, 20, 86, 0.14), offset: Offset(0, 4), blurRadius: 12, spreadRadius: 0),
    ],
    drawer: <BoxShadow>[
      BoxShadow(color: Color.fromRGBO(14, 20, 86, 0.18), offset: Offset(-12, 0), blurRadius: 40, spreadRadius: 0),
    ],
    toast: <BoxShadow>[
      BoxShadow(color: Color.fromRGBO(14, 20, 86, 0.3), offset: Offset(0, 10), blurRadius: 30, spreadRadius: 0),
    ],
    overlay: Color.fromRGBO(14, 20, 86, 0.28),
  );

  @override
  DsElevation copyWith({
    List<BoxShadow>? e0,
    List<BoxShadow>? e1,
    List<BoxShadow>? e2,
    List<BoxShadow>? e3,
    List<BoxShadow>? cardHover,
    List<BoxShadow>? ribbonArrow,
    List<BoxShadow>? drawer,
    List<BoxShadow>? toast,
    Color? overlay,
  }) {
    return DsElevation(
      e0: e0 ?? this.e0,
      e1: e1 ?? this.e1,
      e2: e2 ?? this.e2,
      e3: e3 ?? this.e3,
      cardHover: cardHover ?? this.cardHover,
      ribbonArrow: ribbonArrow ?? this.ribbonArrow,
      drawer: drawer ?? this.drawer,
      toast: toast ?? this.toast,
      overlay: overlay ?? this.overlay,
    );
  }

  @override
  DsElevation lerp(DsElevation? other, double t) {
    if (other == null) {
      return this;
    }
    return DsElevation(
      e0: BoxShadow.lerpList(e0, other.e0, t)!,
      e1: BoxShadow.lerpList(e1, other.e1, t)!,
      e2: BoxShadow.lerpList(e2, other.e2, t)!,
      e3: BoxShadow.lerpList(e3, other.e3, t)!,
      cardHover: BoxShadow.lerpList(cardHover, other.cardHover, t)!,
      ribbonArrow: BoxShadow.lerpList(ribbonArrow, other.ribbonArrow, t)!,
      drawer: BoxShadow.lerpList(drawer, other.drawer, t)!,
      toast: BoxShadow.lerpList(toast, other.toast, t)!,
      overlay: Color.lerp(overlay, other.overlay, t)!,
    );
  }
}
