// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 7ecbb28dd87e801deb0bbceb2845ab534f53e844aa8f18b39bf05f36dee13ced)
// DsMotion - ds.motion.* (03 §11.1, §17.5; kernel §8.4, §17.5)
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

/// Durations and curves `ds.motion.*`. Widgets take durations through [of].
@immutable
class DsMotion extends ThemeExtension<DsMotion> {
  const DsMotion({
    required this.fast,
    required this.base,
    required this.slow,
    required this.splashLogo,
    required this.mascotTransition,
    required this.standard,
    required this.standardDecelerate,
    required this.standardAccelerate,
    required this.emphasized,
    required this.reduceMotion,
  });

  /// `ds.motion.fast` = 150 ms.
  final Duration fast;

  /// `ds.motion.base` = 200 ms.
  final Duration base;

  /// `ds.motion.slow` = 300 ms.
  final Duration slow;

  /// `ds.motion.splashLogo` = 600 ms.
  final Duration splashLogo;

  /// `ds.motion.mascotTransition` = 250 ms.
  final Duration mascotTransition;

  /// `ds.motion.curve.standard` = Cubic(0.2, 0, 0, 1).
  final Curve standard;

  /// `ds.motion.curve.standardDecelerate` = Cubic(0, 0, 0, 1).
  final Curve standardDecelerate;

  /// `ds.motion.curve.standardAccelerate` = Cubic(0.3, 0, 1, 1).
  final Curve standardAccelerate;

  /// `ds.motion.curve.emphasized` = Cubic(0.05, 0.7, 0.1, 1).
  final Curve emphasized;

  /// disableAnimations || OS reduce motion || SCR-42 setting (03 §11.1).
  final bool reduceMotion;

  static const DsMotion defaults = DsMotion(
    fast: Duration(milliseconds: 150),
    base: Duration(milliseconds: 200),
    slow: Duration(milliseconds: 300),
    splashLogo: Duration(milliseconds: 600),
    mascotTransition: Duration(milliseconds: 250),
    standard: Cubic(0.2, 0, 0, 1),
    standardDecelerate: Cubic(0, 0, 0, 1),
    standardAccelerate: Cubic(0.3, 0, 1, 1),
    emphasized: Cubic(0.05, 0.7, 0.1, 1),
    reduceMotion: false,
  );

  /// The only non-zero duration allowed under reduce motion (kernel §17.5).
  Duration get reducedCrossfade => const Duration(milliseconds: 80);

  /// Duration to use: zero when [reduceMotion] is on.
  Duration of(Duration d) => reduceMotion ? Duration.zero : d;

  /// Builds the motion tokens for [context] with the three reduce-motion sources.
  static DsMotion resolve(BuildContext context, {required bool userReduceMotion}) {
    final bool reduce =
        MediaQuery.disableAnimationsOf(context) ||
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion ||
        userReduceMotion;
    return defaults.copyWith(reduceMotion: reduce);
  }

  @override
  DsMotion copyWith({
    Duration? fast,
    Duration? base,
    Duration? slow,
    Duration? splashLogo,
    Duration? mascotTransition,
    Curve? standard,
    Curve? standardDecelerate,
    Curve? standardAccelerate,
    Curve? emphasized,
    bool? reduceMotion,
  }) {
    return DsMotion(
      fast: fast ?? this.fast,
      base: base ?? this.base,
      slow: slow ?? this.slow,
      splashLogo: splashLogo ?? this.splashLogo,
      mascotTransition: mascotTransition ?? this.mascotTransition,
      standard: standard ?? this.standard,
      standardDecelerate: standardDecelerate ?? this.standardDecelerate,
      standardAccelerate: standardAccelerate ?? this.standardAccelerate,
      emphasized: emphasized ?? this.emphasized,
      reduceMotion: reduceMotion ?? this.reduceMotion,
    );
  }

  @override
  DsMotion lerp(DsMotion? other, double t) {
    if (other == null) {
      return this;
    }
    return t < 0.5 ? this : other;
  }
}
