// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 31ea2b8fcd4858d3a96d8f15ebdd88453c981902ca331fe859ffb230f2f53d46)
// DsDensity (03 §8.1, §17.4; kernel §17.5)
// ignore_for_file: public_member_api_docs

import 'ds_breakpoints.dart';

/// Density (03 §8.1). Never lowers a touch target below 44/48 lp.
enum DsDensity { standard, compact }

/// Values of each density.
extension DsDensityValues on DsDensity {
  /// list row height: 56 / 48.
  double get rowHeight => switch (this) {
    DsDensity.standard => 56.0,
    DsDensity.compact => 48.0,
  };

  /// list row height with thumbnail: 72 / 64.
  double get rowHeightWithThumb => switch (this) {
    DsDensity.standard => 72.0,
    DsDensity.compact => 64.0,
  };

  /// card padding: 16 / 12.
  double get cardPadding => switch (this) {
    DsDensity.standard => 16.0,
    DsDensity.compact => 12.0,
  };

  /// icon size in a row: 24 / 20.
  double get rowIconSize => switch (this) {
    DsDensity.standard => 24.0,
    DsDensity.compact => 20.0,
  };

  /// card grid gap (03 §7.3): 16 / 12.
  double get gridGap => switch (this) {
    DsDensity.standard => 16.0,
    DsDensity.compact => 12.0,
  };

  /// compact/medium -> standard; expanded/large -> compact.
  static DsDensity forWindowClass(WindowClass c) => switch (c) {
    WindowClass.compact => DsDensity.standard,
    WindowClass.medium => DsDensity.standard,
    WindowClass.expanded => DsDensity.compact,
    WindowClass.large => DsDensity.compact,
  };
}
