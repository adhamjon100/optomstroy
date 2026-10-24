// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 7ecbb28dd87e801deb0bbceb2845ab534f53e844aa8f18b39bf05f36dee13ced)
// DsBreakpoints - ds.breakpoint.* (03 §7.2, §7.3, §8.4, §17.4; kernel §17.5)
// ignore_for_file: public_member_api_docs

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Window classes (03 §7.2).
enum WindowClass { compact, medium, expanded, large }

/// Breakpoints and layout sizes in logical pixels.
class DsBreakpoints {
  DsBreakpoints._();

  /// `ds.breakpoint.medium`: 600-1023 lp.
  static const double medium = 600;

  /// `ds.breakpoint.expanded`: 1024-1599 lp.
  static const double expanded = 1024;

  /// `ds.breakpoint.large`: >= 1600 lp.
  static const double large = 1600;

  static const double sidebarNarrow = 240;
  static const double sidebarWide = 292;
  static const double sidebarCollapsed = 72;
  static const double rail = 72;
  static const double cartNarrow = 320;
  static const double cartWide = 340;
  static const double productPanel = 400;
  static const double contentMaxLarge = 1200;
  static const double cardMinWidth = 160;
  static const int gridMinColumns = 2;
  static const int gridMaxColumns = 6;

  /// Window class by `MediaQuery.sizeOf(context).width`.
  static WindowClass of(BuildContext context) => forWidth(MediaQuery.sizeOf(context).width);

  /// Window class for a window width.
  static WindowClass forWidth(double width) {
    if (width >= large) {
      return WindowClass.large;
    }
    if (width >= expanded) {
      return WindowClass.expanded;
    }
    if (width >= medium) {
      return WindowClass.medium;
    }
    return WindowClass.compact;
  }

  /// Card grid columns (03 §7.3): max(2, min(6, floor((W + gap) / (160 + gap)))).
  /// [contentWidth] is the content zone WITHOUT side margins (on `large` - at most
  /// [contentMaxLarge], applied by the caller).
  static int gridColumns(double contentWidth, double gap) {
    final int n = ((contentWidth + gap) / (cardMinWidth + gap)).floor();
    return math.max(gridMinColumns, math.min(gridMaxColumns, n));
  }
}
