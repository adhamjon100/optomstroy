// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 7ecbb28dd87e801deb0bbceb2845ab534f53e844aa8f18b39bf05f36dee13ced)
// DsSpacing - ds.space.1..10 (03 §7.1, §17.4)
// ignore_for_file: public_member_api_docs

import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Spacing `ds.space.1` ... `ds.space.10` (4 lp module, 03 §7.1).
@immutable
class DsSpacing extends ThemeExtension<DsSpacing> {
  const DsSpacing({
    required this.s1,
    required this.s2,
    required this.s3,
    required this.s4,
    required this.s5,
    required this.s6,
    required this.s7,
    required this.s8,
    required this.s9,
    required this.s10,
  });

  /// `ds.space.1` = 4 lp.
  final double s1;

  /// `ds.space.2` = 8 lp.
  final double s2;

  /// `ds.space.3` = 12 lp.
  final double s3;

  /// `ds.space.4` = 16 lp.
  final double s4;

  /// `ds.space.5` = 20 lp.
  final double s5;

  /// `ds.space.6` = 24 lp.
  final double s6;

  /// `ds.space.7` = 32 lp.
  final double s7;

  /// `ds.space.8` = 40 lp.
  final double s8;

  /// `ds.space.9` = 48 lp.
  final double s9;

  /// `ds.space.10` = 64 lp.
  final double s10;

  static const DsSpacing defaults = DsSpacing(
    s1: 4,
    s2: 8,
    s3: 12,
    s4: 16,
    s5: 20,
    s6: 24,
    s7: 32,
    s8: 40,
    s9: 48,
    s10: 64,
  );

  /// Side margins of window class `compact` (03 §7.2).
  EdgeInsets get pagePaddingCompact => const EdgeInsets.symmetric(horizontal: 16);

  /// Side margins of window class `medium` (03 §7.2).
  EdgeInsets get pagePaddingMedium => const EdgeInsets.symmetric(horizontal: 24);

  /// Side margins of window class `large` (03 §7.2).
  EdgeInsets get pagePaddingLarge => const EdgeInsets.symmetric(horizontal: 32);

  @override
  DsSpacing copyWith({
    double? s1,
    double? s2,
    double? s3,
    double? s4,
    double? s5,
    double? s6,
    double? s7,
    double? s8,
    double? s9,
    double? s10,
  }) {
    return DsSpacing(
      s1: s1 ?? this.s1,
      s2: s2 ?? this.s2,
      s3: s3 ?? this.s3,
      s4: s4 ?? this.s4,
      s5: s5 ?? this.s5,
      s6: s6 ?? this.s6,
      s7: s7 ?? this.s7,
      s8: s8 ?? this.s8,
      s9: s9 ?? this.s9,
      s10: s10 ?? this.s10,
    );
  }

  @override
  DsSpacing lerp(DsSpacing? other, double t) {
    if (other == null) {
      return this;
    }
    return DsSpacing(
      s1: lerpDouble(s1, other.s1, t)!,
      s2: lerpDouble(s2, other.s2, t)!,
      s3: lerpDouble(s3, other.s3, t)!,
      s4: lerpDouble(s4, other.s4, t)!,
      s5: lerpDouble(s5, other.s5, t)!,
      s6: lerpDouble(s6, other.s6, t)!,
      s7: lerpDouble(s7, other.s7, t)!,
      s8: lerpDouble(s8, other.s8, t)!,
      s9: lerpDouble(s9, other.s9, t)!,
      s10: lerpDouble(s10, other.s10, t)!,
    );
  }
}
