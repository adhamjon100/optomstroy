// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 31ea2b8fcd4858d3a96d8f15ebdd88453c981902ca331fe859ffb230f2f53d46)
// DsRadii - ds.radius.{xs,sm,md,lg,xl,full} (03 §7.5, §17.4)
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

/// Corner radii `ds.radius.*`. `xl` - only the form card of SCR-01...SCR-04 and SCR-08
/// (kernel §18.2 item 15); SCR-06, SCR-07 use `lg`.
@immutable
class DsRadii extends ThemeExtension<DsRadii> {
  const DsRadii({
    required this.xs,
    required this.sm,
    required this.md,
    required this.lg,
    required this.xl,
    required this.full,
  });

  /// `ds.radius.xs` = 4 lp.
  final Radius xs;

  /// `ds.radius.sm` = 8 lp.
  final Radius sm;

  /// `ds.radius.md` = 12 lp.
  final Radius md;

  /// `ds.radius.lg` = 16 lp.
  final Radius lg;

  /// `ds.radius.xl` = 20 lp.
  final Radius xl;

  /// `ds.radius.full` = 999 lp.
  final Radius full;

  static const DsRadii defaults = DsRadii(
    xs: Radius.circular(4),
    sm: Radius.circular(8),
    md: Radius.circular(12),
    lg: Radius.circular(16),
    xl: Radius.circular(20),
    full: Radius.circular(999),
  );

  /// Card corners (`md`).
  BorderRadius get card => BorderRadius.all(md);

  /// Bottom sheet top corners (`lg`).
  BorderRadius get sheetTop => BorderRadius.vertical(top: lg);

  @override
  DsRadii copyWith({Radius? xs, Radius? sm, Radius? md, Radius? lg, Radius? xl, Radius? full}) {
    return DsRadii(
      xs: xs ?? this.xs,
      sm: sm ?? this.sm,
      md: md ?? this.md,
      lg: lg ?? this.lg,
      xl: xl ?? this.xl,
      full: full ?? this.full,
    );
  }

  @override
  DsRadii lerp(DsRadii? other, double t) {
    if (other == null) {
      return this;
    }
    return DsRadii(
      xs: Radius.lerp(xs, other.xs, t)!,
      sm: Radius.lerp(sm, other.sm, t)!,
      md: Radius.lerp(md, other.md, t)!,
      lg: Radius.lerp(lg, other.lg, t)!,
      xl: Radius.lerp(xl, other.xl, t)!,
      full: Radius.lerp(full, other.full, t)!,
    );
  }
}
