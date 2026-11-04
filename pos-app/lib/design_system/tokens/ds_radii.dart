// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 9cbac28624a1540f8761044b1d6bc2c865186b343d294504be661658cfe83dd5)
// DsRadii - ds.radius.{xs,sm,md,lg,xl,full} (03 §7.5, §17.4) + prototype radii (ADR-114)
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

/// Corner radii `ds.radius.*`. `xl` - only the form card of SCR-01...SCR-04 and SCR-08
/// (kernel §18.2 item 15); SCR-06, SCR-07 use `lg`. The prototype radii (ADR-114) are for the goods
/// selection screen SCR-10/11/12, the staff header and the cart drawer only.
@immutable
class DsRadii extends ThemeExtension<DsRadii> {
  const DsRadii({
    required this.xs,
    required this.sm,
    required this.md,
    required this.lg,
    required this.xl,
    required this.full,
    required this.segment,
    required this.badge,
    required this.control,
    required this.catalogCard,
    required this.star,
    required this.arrow,
    required this.avatar,
    required this.circle,
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

  /// `ds.radius.segment` = 7 lp (ADR-114): view segment button.
  final Radius segment;

  /// `ds.radius.badge` = 9 lp (ADR-114): badges 17-18 lp, cart quantity stepper.
  final Radius badge;

  /// `ds.radius.control` = 10 lp (ADR-114): search field, chips, sort, segment group, card and drawer buttons, cart
  /// chip, bell, photo placeholder.
  final Radius control;

  /// `ds.radius.catalogCard` = 14 lp (ADR-114): product grid card and catalog empty state (`card` is the BorderRadius
  /// getter of 03 §17.4).
  final Radius catalogCard;

  /// `ds.radius.star` = 17 lp (ADR-114): favourite star button 34 lp.
  final Radius star;

  /// `ds.radius.arrow` = 19 lp (ADR-114): ribbon arrows 38 lp.
  final Radius arrow;

  /// `ds.radius.avatar` = 19 lp (ADR-114): header avatar 38 lp.
  final Radius avatar;

  /// `ds.radius.circle` = 28 lp (ADR-114): ribbon placeholder circle 56 lp.
  final Radius circle;

  static const DsRadii defaults = DsRadii(
    xs: Radius.circular(4),
    sm: Radius.circular(8),
    md: Radius.circular(12),
    lg: Radius.circular(16),
    xl: Radius.circular(20),
    full: Radius.circular(999),
    segment: Radius.circular(7),
    badge: Radius.circular(9),
    control: Radius.circular(10),
    catalogCard: Radius.circular(14),
    star: Radius.circular(17),
    arrow: Radius.circular(19),
    avatar: Radius.circular(19),
    circle: Radius.circular(28),
  );

  /// Card corners (`md`).
  BorderRadius get card => BorderRadius.all(md);

  /// Bottom sheet top corners (`lg`).
  BorderRadius get sheetTop => BorderRadius.vertical(top: lg);

  @override
  DsRadii copyWith({
    Radius? xs,
    Radius? sm,
    Radius? md,
    Radius? lg,
    Radius? xl,
    Radius? full,
    Radius? segment,
    Radius? badge,
    Radius? control,
    Radius? catalogCard,
    Radius? star,
    Radius? arrow,
    Radius? avatar,
    Radius? circle,
  }) {
    return DsRadii(
      xs: xs ?? this.xs,
      sm: sm ?? this.sm,
      md: md ?? this.md,
      lg: lg ?? this.lg,
      xl: xl ?? this.xl,
      full: full ?? this.full,
      segment: segment ?? this.segment,
      badge: badge ?? this.badge,
      control: control ?? this.control,
      catalogCard: catalogCard ?? this.catalogCard,
      star: star ?? this.star,
      arrow: arrow ?? this.arrow,
      avatar: avatar ?? this.avatar,
      circle: circle ?? this.circle,
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
      segment: Radius.lerp(segment, other.segment, t)!,
      badge: Radius.lerp(badge, other.badge, t)!,
      control: Radius.lerp(control, other.control, t)!,
      catalogCard: Radius.lerp(catalogCard, other.catalogCard, t)!,
      star: Radius.lerp(star, other.star, t)!,
      arrow: Radius.lerp(arrow, other.arrow, t)!,
      avatar: Radius.lerp(avatar, other.avatar, t)!,
      circle: Radius.lerp(circle, other.circle, t)!,
    );
  }
}
