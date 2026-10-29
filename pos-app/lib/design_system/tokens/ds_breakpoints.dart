// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 31ea2b8fcd4858d3a96d8f15ebdd88453c981902ca331fe859ffb230f2f53d46)
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
  static const double topBarHeight = 68;
  static const double navDrawer = 320;
  static const double cartDrawer = 420;
  static const double catalogColumn = 132;
  static const double catalogCardMinWidth = 176;
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

  /// Card grid columns (03 §7.3): max(2, min(6, floor((W + gap) / (minCardWidth + gap)))).
  /// [contentWidth] is the content zone WITHOUT side margins (on `large` - at most
  /// [contentMaxLarge], applied by the caller). [minCardWidth] defaults to [cardMinWidth];
  /// the catalog grid SCR-10/11/12 passes [catalogCardMinWidth] (ADR-111).
  static int gridColumns(double contentWidth, double gap, {double minCardWidth = cardMinWidth}) {
    final int n = ((contentWidth + gap) / (minCardWidth + gap)).floor();
    return math.max(gridMinColumns, math.min(gridMaxColumns, n));
  }
}
