// Прогон ширин окна для сеток товаров (12 T-CAT-038, ред. 1.20; 03 §7.3 ред. 1.25; 15 ADR-114, уточнение 2026-11-18 —
// указание владельца «при зуме или наоборот сетка товаров должна меняться — 3 или 4, 5 и так далее, но поставь
// ограничения»). Окно меняется так же, как при изменении размера окна, повороте планшета и масштабе страницы в браузере
// (масштаб меняет логическую ширину). На каждой ширине: без переполнения; колонок первого ряда — от 2 до предела класса
// окна (и предела экрана); карточка не шире 280 и не уже минимума (кроме вынужденных 2 колонок); колонки — по формуле
// от измеренной ширины сетки; в пределах класса окна колонок не становится меньше при расширении.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

/// Ширины прогона: 320…2560 с шагом 40 (телефон, планшет в обеих ориентациях, окна Windows, отдаление в браузере) и
/// границы классов окна и частые окна: 412, 599, 1023, 1366, 1536, 1599 — по возрастанию.
final List<double> kGridSweepWidths = <double>{
  for (double w = 320; w <= 2560; w += 40) w,
  412,
  599,
  1023,
  1366,
  1536,
  1599,
}.toList()..sort();

/// Ширины сильного отдаления в браузере (1920 при 67 % и 50 %, 4K без масштаба): здесь срабатывает предел ширины
/// области товаров — карточки ровно 280, остаток справа пустой.
const List<double> kGridZoomOutWidths = <double>[2880, 3200, 3840];

/// Прямоугольники карточек сетки (`ProductCardGrid` — во всю ячейку) первого ряда, слева направо.
List<Rect> firstGridRow(WidgetTester tester) {
  final List<Rect> cards = <Rect>[
    for (final Element e in find.byType(ProductCardGrid).evaluate())
      if (e.renderObject case final RenderBox box when box.hasSize) box.localToGlobal(Offset.zero) & box.size,
  ];
  if (cards.isEmpty) {
    return cards;
  }
  final double top = cards.map((Rect r) => r.top).reduce((double a, double b) => a < b ? a : b);
  return cards.where((Rect r) => (r.top - top).abs() < 0.01).toList()
    ..sort((Rect a, Rect b) => a.left.compareTo(b.left));
}

/// Итог одной ширины.
typedef GridSweepRow = ({double width, WindowClass windowClass, int columns, double card});

/// Проверки прогона сетки одного экрана; [check] — после того, как экран построен при ширине [width].
final class GridSweep {
  GridSweep({required this.label, required this.minCardWidth, this.maxColumns});

  /// Экран (для сообщений).
  final String label;

  /// Минимум карточки экрана: 176 (SCR-10/11/12, SCR-51) или 160 (SCR-50).
  final double minCardWidth;

  /// Свой предел колонок экрана (SCR-50 — 6); `null` — только предел класса окна.
  final int? maxColumns;

  /// Строки по ширинам, где на экране есть сетка.
  final List<GridSweepRow> rows = <GridSweepRow>[];

  /// Проверить экран при ширине окна [width]; [tester] уже построил его.
  void check(WidgetTester tester, double width, {String? note}) {
    final String at = '$label, ${width.toInt()} lp${note == null ? '' : ', $note'}';
    expect(tester.takeException(), isNull, reason: '$at: без переполнения и ошибок раскладки');
    final List<Rect> row = firstGridRow(tester);
    if (row.isEmpty) {
      return;
    }
    final WindowClass wc = DsBreakpoints.forWidth(width);
    final int cap = DsBreakpoints.gridColumnsCap(wc, maxColumns: maxColumns);
    final int cols = row.length;
    final double card = row.first.width;
    expect(cols, inInclusiveRange(DsBreakpoints.gridMinColumns, cap), reason: '$at: колонок от 2 до предела ($cap)');
    for (final Rect r in row) {
      expect(r.width, closeTo(card, 0.01), reason: '$at: карточки ряда одной ширины');
    }
    expect(card, lessThanOrEqualTo(DsBreakpoints.gridCardMaxWidth + 0.01), reason: '$at: карточка не шире 280');
    if (cols > DsBreakpoints.gridMinColumns) {
      expect(card, greaterThanOrEqualTo(minCardWidth - 0.01), reason: '$at: карточка не уже ${minCardWidth.toInt()}');
    }
    expect(row.last.right, lessThanOrEqualTo(width + 0.01), reason: '$at: ряд в окне');
    if (cols > 1) {
      // Колонки — по формуле 03 §7.3 от измеренной ширины сетки (карточки и зазоры заполняют её целиком).
      final double gap = row[1].left - row[0].right;
      final double content = row.last.right - row.first.left;
      expect(
        DsBreakpoints.gridColumns(content, gap, windowClass: wc, minCardWidth: minCardWidth, maxColumns: maxColumns),
        cols,
        reason: '$at: колонки по формуле (ширина сетки ${content.toStringAsFixed(1)}, зазор ${gap.toStringAsFixed(1)})',
      );
    }
    rows.add((width: width, windowClass: wc, columns: cols, card: card));
  }

  /// После прогона: в пределах класса окна колонок не меньше при большей ширине; [expectGridIn] — классы окна, где
  /// сетка обязана быть.
  void expectMonotonic({Set<WindowClass> expectGridIn = const <WindowClass>{}}) {
    for (final WindowClass wc in expectGridIn) {
      expect(
        rows.where((GridSweepRow r) => r.windowClass == wc),
        isNotEmpty,
        reason: '$label: сетка в классе ${wc.name}',
      );
    }
    for (int i = 1; i < rows.length; i++) {
      final GridSweepRow a = rows[i - 1];
      final GridSweepRow b = rows[i];
      if (a.windowClass == b.windowClass && b.width > a.width) {
        expect(
          b.columns,
          greaterThanOrEqualTo(a.columns),
          reason: '$label: ${a.width.toInt()} → ${b.width.toInt()} lp (${a.windowClass.name}) — колонок не меньше',
        );
      }
    }
  }

  /// Таблица прогона для сообщения теста: «ширина: колонки × карточка».
  String describe() =>
      rows.map((GridSweepRow r) => '${r.width.toInt()}:${r.columns}×${r.card.toStringAsFixed(0)}').join(' ');
}
