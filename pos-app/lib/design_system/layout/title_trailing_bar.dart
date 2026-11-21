// `TitleTrailingBar` — заголовок у начала строки и элементы управления у её конца; не помещаются в одну строку —
// элементы переходят строкой ниже, к концу, а заголовок остаётся у начала (02 SCR-50.2 «Адаптивность», ред. 1.32:
// «Все товары» слева, вид и сортировка — у правого края; указание владельца 2026-11-18, 15 §5.8 (1)).
// `OverflowBar` так не умеет: в режиме переноса он применяет одно выравнивание ко всем детям. Арифметика — как у
// `OverflowBar`: оба ребёнка раскладываются со свободными ограничениями; сумма ширин с зазором помещается — одна строка
// (дети по центру по вертикали), иначе — две. Направление письма (RTL) учитывается.
// [TitleTrailingBar.minTitleWidth] (пакет own-server:GAP-APP): заголовок — текст, который может переноситься рядом с
// элементами (строка «Заказ № POS-… · клиент» и чип статуса SCR-38); в одну строку, если рядом помещается его самое
// длинное слово (номер заказа), — тогда заголовок переносится в оставшейся ширине; иначе элементы — строкой ниже, а
// номер не разрывается между цифрами. [TitleTrailingBar.alignTop] — в одну строку дети у верхнего края.
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Заголовок + элементы управления с переносом элементов к концу следующей строки.
class TitleTrailingBar extends MultiChildRenderObjectWidget {
  /// Создаёт строку.
  TitleTrailingBar({
    super.key,
    required Widget title,
    required Widget trailing,
    this.spacing = 0,
    this.overflowSpacing = 0,
    this.minTitleWidth,
    this.alignTop = false,
  }) : super(children: <Widget>[title, trailing]);

  /// Зазор между заголовком и элементами в одной строке.
  final double spacing; // money-double: allow — геометрия UI (lp)

  /// Зазор между строками при переносе.
  final double overflowSpacing; // money-double: allow — геометрия UI (lp)

  /// Наименьшая ширина заголовка рядом с элементами (обычно — его самое длинное слово, `dsLongestWordWidth`); `null` —
  /// заголовок рядом только во всю свою ширину (без переноса).
  final double? minTitleWidth; // money-double: allow — геометрия UI (lp)

  /// В одну строку — дети у верхнего края (иначе — по центру по вертикали).
  final bool alignTop;

  @override
  RenderTitleTrailingBar createRenderObject(BuildContext context) => RenderTitleTrailingBar(
    spacing: spacing,
    overflowSpacing: overflowSpacing,
    textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
    minTitleWidth: minTitleWidth,
    alignTop: alignTop,
  );

  @override
  void updateRenderObject(BuildContext context, RenderTitleTrailingBar renderObject) {
    renderObject
      ..spacing = spacing
      ..overflowSpacing = overflowSpacing
      ..textDirection = Directionality.maybeOf(context) ?? TextDirection.ltr
      ..minTitleWidth = minTitleWidth
      ..alignTop = alignTop;
  }
}

/// Данные ребёнка [RenderTitleTrailingBar].
class TitleTrailingBarParentData extends ContainerBoxParentData<RenderBox> {}

/// Раскладка [TitleTrailingBar].
class RenderTitleTrailingBar extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, TitleTrailingBarParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, TitleTrailingBarParentData> {
  /// Создаёт раскладку.
  RenderTitleTrailingBar({
    required double spacing, // money-double: allow — геометрия UI (lp)
    required double overflowSpacing, // money-double: allow — геометрия UI (lp)
    required TextDirection textDirection,
    double? minTitleWidth, // money-double: allow — геометрия UI (lp)
    bool alignTop = false,
  }) : _spacing = spacing,
       _overflowSpacing = overflowSpacing,
       _textDirection = textDirection,
       _minTitleWidth = minTitleWidth,
       _alignTop = alignTop;

  double? _minTitleWidth; // money-double: allow — геометрия UI (lp)
  double? get minTitleWidth => _minTitleWidth; // money-double: allow — геометрия UI (lp)
  set minTitleWidth(double? value) {
    // money-double: allow — геометрия UI (lp)
    if (value == _minTitleWidth) return;
    _minTitleWidth = value;
    markNeedsLayout();
  }

  bool _alignTop;
  bool get alignTop => _alignTop;
  set alignTop(bool value) {
    if (value == _alignTop) return;
    _alignTop = value;
    markNeedsLayout();
  }

  double _spacing; // money-double: allow — геометрия UI (lp)
  double get spacing => _spacing; // money-double: allow — геометрия UI (lp)
  set spacing(double value) {
    // money-double: allow — геометрия UI (lp)
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  double _overflowSpacing; // money-double: allow — геометрия UI (lp)
  double get overflowSpacing => _overflowSpacing; // money-double: allow — геометрия UI (lp)
  set overflowSpacing(double value) {
    // money-double: allow — геометрия UI (lp)
    if (value == _overflowSpacing) return;
    _overflowSpacing = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  TextDirection get textDirection => _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  /// Последняя раскладка — в две строки (элементы под заголовком).
  bool get overflowed => _overflowed;
  bool _overflowed = false;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! TitleTrailingBarParentData) {
      child.parentData = TitleTrailingBarParentData();
    }
  }

  RenderBox? get _title => firstChild;
  RenderBox? get _trailing => firstChild == null ? null : childAfter(firstChild!);

  Size _arrange(BoxConstraints constraints, {required bool dry}) {
    final RenderBox? title = _title;
    final RenderBox? trailing = _trailing;
    final BoxConstraints loose = constraints.loosen();
    Size measure(RenderBox? child, BoxConstraints c) {
      if (child == null) return Size.zero;
      if (dry) return child.getDryLayout(c);
      child.layout(c, parentUsesSize: true);
      return child.size;
    }

    final Size r = measure(trailing, loose);
    final double? minTitle = minTitleWidth; // money-double: allow — геометрия UI (lp)
    final Size t;
    final bool row;
    final double width; // money-double: allow — геометрия UI (lp)
    if (minTitle == null || !constraints.hasBoundedWidth) {
      t = measure(title, loose);
      final double sum = t.width + spacing + r.width; // money-double: allow — геометрия UI (lp)
      width = constraints.hasBoundedWidth ? constraints.maxWidth : sum;
      row = sum <= width;
    } else {
      // Заголовок переносится рядом с элементами, если там помещается его самое длинное слово.
      width = constraints.maxWidth;
      row = minTitle + spacing + r.width <= width;
      t = measure(title, row ? loose.copyWith(maxWidth: math.max(0, width - spacing - r.width)) : loose);
    }
    final double height =
        row // money-double: allow — геометрия UI (lp)
        ? math.max(t.height, r.height)
        : t.height + overflowSpacing + r.height;
    final Size size = constraints.constrain(Size(width, height));
    if (!dry) {
      _overflowed = !row;
      final bool rtl = textDirection == TextDirection.rtl;
      if (title != null) {
        (title.parentData! as TitleTrailingBarParentData).offset = Offset(
          rtl ? size.width - t.width : 0,
          row && !alignTop ? (height - t.height) / 2 : 0,
        );
      }
      if (trailing != null) {
        (trailing.parentData! as TitleTrailingBarParentData).offset = Offset(
          rtl ? 0 : size.width - r.width,
          row ? (alignTop ? 0 : (height - r.height) / 2) : t.height + overflowSpacing,
        );
      }
    }
    return size;
  }

  @override
  void performLayout() {
    size = _arrange(constraints, dry: false);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) => _arrange(constraints, dry: true);

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.max(_title?.getMinIntrinsicWidth(height) ?? 0, _trailing?.getMinIntrinsicWidth(height) ?? 0);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      (_title?.getMaxIntrinsicWidth(height) ?? 0) + spacing + (_trailing?.getMaxIntrinsicWidth(height) ?? 0);

  @override
  double computeMinIntrinsicHeight(double width) => _arrange(BoxConstraints(maxWidth: width), dry: true).height;

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
