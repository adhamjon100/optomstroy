// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 7ecbb28dd87e801deb0bbceb2845ab534f53e844aa8f18b39bf05f36dee13ced)
// DsElevation - ds.elevation.0..3 (03 §7.6, §17.4; kernel §8.3)
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

/// Shadows `ds.elevation.*` (kernel §8.3 has priority over R4 §5.4, kernel §17.5).
@immutable
class DsElevation extends ThemeExtension<DsElevation> {
  const DsElevation({required this.e0, required this.e1, required this.e2, required this.e3, required this.overlay});

  /// `ds.elevation.0`: 0 shadow(s); border `border` 1 px.
  final List<BoxShadow> e0;

  /// `ds.elevation.1`: 1 shadow(s); border `border` 1 px.
  final List<BoxShadow> e1;

  /// `ds.elevation.2`: 1 shadow(s); no border.
  final List<BoxShadow> e2;

  /// `ds.elevation.3`: 1 shadow(s); `overlay` scrim under the element.
  final List<BoxShadow> e3;

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
    overlay: Color.fromRGBO(27, 31, 42, 0.48),
  );

  @override
  DsElevation copyWith({
    List<BoxShadow>? e0,
    List<BoxShadow>? e1,
    List<BoxShadow>? e2,
    List<BoxShadow>? e3,
    Color? overlay,
  }) {
    return DsElevation(
      e0: e0 ?? this.e0,
      e1: e1 ?? this.e1,
      e2: e2 ?? this.e2,
      e3: e3 ?? this.e3,
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
      overlay: Color.lerp(overlay, other.overlay, t)!,
    );
  }
}
