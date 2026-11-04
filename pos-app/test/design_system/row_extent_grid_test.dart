// `DsRowExtentGridDelegate`: сетка с высотой каждого ряда по содержимому (ряд CSS-сетки прототипа — по самой высокой
// карточке; ревью V-01): смещения и высоты рядов, индексы для прокрутки, обратный порядок колонок (RTL).
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/layout/row_extent_grid.dart';

SliverConstraints _constraints({double cross = 600, AxisDirection crossDirection = AxisDirection.right}) =>
    SliverConstraints(
      axisDirection: AxisDirection.down,
      growthDirection: GrowthDirection.forward,
      userScrollDirection: ScrollDirection.idle,
      scrollOffset: 0,
      precedingScrollExtent: 0,
      overlap: 0,
      remainingPaintExtent: 900,
      crossAxisExtent: cross,
      crossAxisDirection: crossDirection,
      viewportMainAxisExtent: 900,
      remainingCacheExtent: 1500,
      cacheOrigin: 0,
    );

void main() {
  const DsRowExtentGridDelegate delegate = DsRowExtentGridDelegate(
    columns: 3,
    gap: 14,
    rowExtents: <double>[340, 360, 340],
    fallbackExtent: 340,
  );

  test('ряды своей высоты: смещения 0 / 354 / 728, высоты 340 / 360 / 340, ширина колонки (600 − 28) / 3', () {
    final SliverGridLayout layout = delegate.getLayout(_constraints());
    final SliverGridGeometry first = layout.getGeometryForChildIndex(0);
    expect(first.scrollOffset, 0);
    expect(first.mainAxisExtent, 340);
    expect(first.crossAxisExtent, closeTo(572 / 3, 1e-9));
    expect(layout.getGeometryForChildIndex(2).crossAxisOffset, closeTo(2 * (572 / 3 + 14), 1e-9));
    final SliverGridGeometry second = layout.getGeometryForChildIndex(4);
    expect(second.scrollOffset, 354);
    expect(second.mainAxisExtent, 360);
    expect(layout.getGeometryForChildIndex(6).scrollOffset, 728);
    expect(layout.getGeometryForChildIndex(6).mainAxisExtent, 340);
    // Ряд сверх списка — высота по умолчанию.
    expect(layout.getGeometryForChildIndex(9).scrollOffset, 728 + 340 + 14);
    expect(layout.computeMaxScrollOffset(7), 728 + 340);
    expect(layout.computeMaxScrollOffset(0), 0);
  });

  test('индексы для прокрутки — как у SliverGridRegularTileLayout (ряд вместе с зазором после него)', () {
    final SliverGridLayout layout = delegate.getLayout(_constraints());
    expect(layout.getMinChildIndexForScrollOffset(0), 0);
    expect(layout.getMinChildIndexForScrollOffset(353.9), 0);
    expect(layout.getMinChildIndexForScrollOffset(354), 3);
    expect(layout.getMinChildIndexForScrollOffset(728), 6);
    expect(layout.getMinChildIndexForScrollOffset(728 + 354), 9);
    expect(layout.getMaxChildIndexForScrollOffset(0), 0);
    expect(layout.getMaxChildIndexForScrollOffset(354), 2, reason: 'ряд 1 начинается ровно на 354');
    expect(layout.getMaxChildIndexForScrollOffset(355), 5);
    expect(layout.getMaxChildIndexForScrollOffset(5000), greaterThan(8));
  });

  test('обратный порядок колонок (RTL) и пересчёт только при смене рядов', () {
    final SliverGridLayout rtl = delegate.getLayout(_constraints(crossDirection: AxisDirection.left));
    expect(rtl.getGeometryForChildIndex(0).crossAxisOffset, closeTo(600 - 572 / 3, 1e-9));
    expect(delegate.shouldRelayout(delegate), isFalse);
    expect(
      delegate.shouldRelayout(
        const DsRowExtentGridDelegate(columns: 3, gap: 14, rowExtents: <double>[340, 340, 340], fallbackExtent: 340),
      ),
      isTrue,
    );
  });
}
