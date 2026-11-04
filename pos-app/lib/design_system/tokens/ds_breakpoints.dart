// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 9cbac28624a1540f8761044b1d6bc2c865186b343d294504be661658cfe83dd5)
// DsBreakpoints - ds.breakpoint.* (03 §7.2, §7.3, §8.4, §17.4; kernel §17.5); DsCatalogMetrics - catalog.* (ADR-114)
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
  /// [maxColumns] defaults to [gridMaxColumns]; `null` - no upper limit, as the prototype's
  /// `repeat(auto-fill, minmax(176px, 1fr))` of the staff catalog on medium+ (ADR-114,
  /// [DsCatalogMetrics.gridGap]). The lower limit [gridMinColumns] always applies.
  static int gridColumns(
    double contentWidth,
    double gap, {
    double minCardWidth = cardMinWidth,
    int? maxColumns = gridMaxColumns,
  }) {
    final int n = ((contentWidth + gap) / (minCardWidth + gap)).floor();
    return math.max(gridMinColumns, maxColumns == null ? n : math.min(maxColumns, n));
  }
}

/// Catalog geometry of SCR-10/11/12 for staff on medium+: prototype values without rounding
/// (ADR-114), in logical pixels.
class DsCatalogMetrics {
  DsCatalogMetrics._();

  /// Category column minimum width (= DsBreakpoints.catalogColumn); the real width is max(132, longest word + 46),
  /// whole lp: 132.
  static const double columnMinWidth = 132;

  /// Category column padding: top 20, right 14, bottom 24, left 18.
  static const EdgeInsets columnPadding = EdgeInsets.fromLTRB(18, 20, 14, 24);

  /// Gap between root category tiles: 10.
  static const double tileGap = 10;

  /// Root category tile minimum height: 88.
  static const double tileMinHeight = 88;

  /// Root category tile padding: top 10, right 6, bottom 8, left 6.
  static const EdgeInsets tilePadding = EdgeInsets.fromLTRB(6, 10, 6, 8);

  /// Root category tile picture box (contain): 46 x 40.
  static const Size tileArt = Size(46, 40);

  /// Subcategory ribbon card (grows to the longest word): 118 x 148.
  static const Size ribbonCard = Size(118, 148);

  /// Gap between ribbon cards: 10.
  static const double ribbonGap = 10;

  /// Ribbon inner padding: 2.
  static const double ribbonPad = 2;

  /// Cards moved by one ribbon arrow press: 3.
  static const int ribbonArrowStepCards = 3;

  /// Main content padding: top 18, right 24, bottom 40, left 8.
  static const EdgeInsets mainPadding = EdgeInsets.fromLTRB(8, 18, 24, 40);

  /// Grid card minimum width (= DsBreakpoints.catalogCardMinWidth): 176.
  static const double gridMinCard = 176;

  /// Grid gap: 14.
  static const double gridGap = 14;

  /// Grid card height: 340.
  static const double gridCardHeight = 340;

  /// Grid card height when «price + / шт» does not fit on one line: 360.
  static const double gridCardHeightWrapped = 360;

  /// Toolbar row height: 42.
  static const double toolbarHeight = 42;

  /// Toolbar chip height: 40.
  static const double chipHeight = 40;

  /// View segment button height: 32.
  static const double segmentHeight = 32;
}
