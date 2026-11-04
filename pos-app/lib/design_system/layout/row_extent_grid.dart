// Сетка с высотой каждого ряда по его содержимому (`SliverGridDelegate`): как `SliverGridDelegateWithFixedCrossAxisCount`
// (колонки одной ширины, зазор по обеим осям), но ряд r — своей высоты. Экран выбора товаров: ряд CSS-сетки прототипа
// растягивается по самой высокой карточке — 360 только у ряда, где «цена / шт» переносится (ревью V-01).
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// Сетка карточек с высотой каждого ряда [rowExtents] и зазором [gap] по обеим осям (как
/// `SliverGridDelegateWithFixedCrossAxisCount`, но с разной высотой рядов; ревью V-01). Ряды сверх списка —
/// [fallbackExtent].
final class DsRowExtentGridDelegate extends SliverGridDelegate {
  /// Создаёт делегат.
  const DsRowExtentGridDelegate({
    required this.columns,
    required this.gap,
    required this.rowExtents,
    required this.fallbackExtent,
  });

  /// Число колонок.
  final int columns;

  /// Зазор между колонками и между рядами.
  final double gap;

  /// Высота каждого ряда по порядку.
  final List<double> rowExtents;

  /// Высота рядов сверх [rowExtents].
  final double fallbackExtent;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final double usable = math.max(0, constraints.crossAxisExtent - gap * (columns - 1));
    return _RowExtentGridLayout(
      columns: columns,
      gap: gap,
      childCrossExtent: usable / columns,
      crossAxisExtent: constraints.crossAxisExtent,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
      rowExtents: rowExtents,
      fallbackExtent: fallbackExtent,
    );
  }

  @override
  bool shouldRelayout(DsRowExtentGridDelegate oldDelegate) =>
      oldDelegate.columns != columns ||
      oldDelegate.gap != gap ||
      oldDelegate.fallbackExtent != fallbackExtent ||
      !listEquals(oldDelegate.rowExtents, rowExtents);
}

/// Раскладка [DsRowExtentGridDelegate]: ряд r начинается на сумме высот предыдущих рядов и зазоров; ряд вместе с зазором
/// после него — как шаг `SliverGridRegularTileLayout`.
final class _RowExtentGridLayout extends SliverGridLayout {
  _RowExtentGridLayout({
    required this.columns,
    required this.gap,
    required this.childCrossExtent,
    required this.crossAxisExtent,
    required this.reverseCrossAxis,
    required this.rowExtents,
    required this.fallbackExtent,
  }) : _starts = _startsOf(rowExtents, gap);

  final int columns;
  final double gap;
  final double childCrossExtent;
  final double crossAxisExtent;
  final bool reverseCrossAxis;
  final List<double> rowExtents;
  final double fallbackExtent;

  /// Начала рядов `0…rowExtents.length` (последнее — за последним рядом и его зазором).
  final List<double> _starts;

  static List<double> _startsOf(List<double> rows, double gap) {
    final List<double> starts = List<double>.filled(rows.length + 1, 0);
    for (int r = 0; r < rows.length; r++) {
      starts[r + 1] = starts[r] + rows[r] + gap;
    }
    return starts;
  }

  double _start(int row) => row <= rowExtents.length
      ? _starts[row]
      : _starts[rowExtents.length] + (row - rowExtents.length) * (fallbackExtent + gap);

  double _extentOf(int row) => row < rowExtents.length ? rowExtents[row] : fallbackExtent;

  /// Ряд, которому принадлежит [offset] (с зазором после ряда): наибольший r, у которого начало ≤ [offset].
  int _rowAt(double offset) {
    if (offset <= 0) {
      return 0;
    }
    final int known = rowExtents.length;
    if (offset >= _starts[known]) {
      return known + ((offset - _starts[known]) / (fallbackExtent + gap)).floor();
    }
    int lo = 0;
    int hi = known - 1;
    while (lo < hi) {
      final int mid = (lo + hi + 1) >> 1;
      if (_starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) => columns * _rowAt(scrollOffset);

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    // Как `SliverGridRegularTileLayout`: ряды, которые начинаются раньше [scrollOffset].
    final int row = _rowAt(scrollOffset);
    final int rows = _start(row) < scrollOffset ? row + 1 : row;
    return math.max(0, columns * rows - 1);
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    final int row = index ~/ columns;
    final double cross = (index % columns) * (childCrossExtent + gap);
    return SliverGridGeometry(
      scrollOffset: _start(row),
      crossAxisOffset: reverseCrossAxis ? crossAxisExtent - cross - childCrossExtent : cross,
      mainAxisExtent: _extentOf(row),
      crossAxisExtent: childCrossExtent,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) {
    if (childCount <= 0) {
      return 0;
    }
    final int last = (childCount - 1) ~/ columns;
    return _start(last) + _extentOf(last);
  }
}
