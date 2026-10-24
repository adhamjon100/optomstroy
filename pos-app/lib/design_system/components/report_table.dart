// `ReportTable` — таблица отчёта SCR-48 (02 UI-48-005, UI-48-011; 03 §16.4 «финансовые контексты»): шапка
// `caption textSecondary`, числа `tnum` с выравниванием вправо, итоговая строка `body 600`, сортировка по колонке
// (стрелка `arrow_upward`/`arrow_downward`, 03 §7.7), подсветка строк `warningContainer` (QR в `manual_confirm`).
// На узкой ширине таблица прокручивается по горизонтали внутри себя — страница по горизонтали не прокручивается
// (02 SCR-48.12). Значения ячеек — уже отформатированные строки: компонент не знает денег и домена.
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Колонка таблицы.
@immutable
class ReportColumn {
  /// Создаёт колонку.
  const ReportColumn({required this.label, this.numeric = false, this.flex = 1, this.minWidth = 96});

  /// Заголовок.
  final String label;

  /// Число: `tnum`, выравнивание вправо.
  final bool numeric;

  /// Доля ширины.
  final int flex;

  /// Минимальная ширина (для горизонтальной прокрутки на compact).
  final double minWidth;
}

/// Таблица отчёта.
class ReportTable extends StatelessWidget {
  /// Создаёт таблицу.
  const ReportTable({
    super.key,
    required this.columns,
    required this.rows,
    this.totals,
    this.highlightedRows = const <int>{},
    this.onRowTap,
    this.sortColumn,
    this.sortAscending = true,
    this.onSort,
    this.rowKey,
  });

  /// Колонки.
  final List<ReportColumn> columns;

  /// Строки (по ячейке на колонку).
  final List<List<String>> rows;

  /// Итоговая строка.
  final List<String>? totals;

  /// Индексы строк с фоном `warningContainer`.
  final Set<int> highlightedRows;

  /// Тап по строке (индекс в [rows]).
  final ValueChanged<int>? onRowTap;

  /// Колонка сортировки.
  final int? sortColumn;

  /// Направление сортировки.
  final bool sortAscending;

  /// Нажатие на заголовок колонки.
  final ValueChanged<int>? onSort;

  /// Ключ строки для тестов.
  final Key Function(int index)? rowKey;

  /// Высота строки.
  static const double rowHeight = 44;

  @override
  Widget build(BuildContext context) {
    final double minWidth = columns.fold<double>(0, (double acc, ReportColumn c) => acc + c.minWidth);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool scroll = constraints.hasBoundedWidth && constraints.maxWidth < minWidth;
        final Widget table = SizedBox(width: scroll ? minWidth : null, child: _table(context));
        if (!scroll) return table;
        return SingleChildScrollView(scrollDirection: Axis.horizontal, child: table);
      },
    );
  }

  Widget _table(BuildContext context) {
    final DsColors c = context.colors;
    final DsTypography t = context.text;
    final TextStyle cell = t.body.copyWith(color: c.textPrimary);
    final TextStyle head = t.caption.copyWith(color: c.textSecondary, fontWeight: FontWeight.w500);

    Widget line(List<Widget> cells, {Color? color, VoidCallback? onTap, Key? key, bool header = false}) {
      final Widget row = Container(
        key: key,
        constraints: const BoxConstraints(minHeight: rowHeight),
        padding: EdgeInsets.symmetric(horizontal: context.space.s3),
        decoration: BoxDecoration(
          color: color,
          border: Border(bottom: BorderSide(color: header ? c.borderStrong : c.border)),
        ),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < columns.length; i++)
              Expanded(
                flex: columns[i].flex,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.space.s1, vertical: context.space.s2),
                  child: i < cells.length ? cells[i] : const SizedBox.shrink(),
                ),
              ),
          ],
        ),
      );
      if (onTap == null) return row;
      return Material(
        color: Colors.transparent,
        child: InkWell(onTap: onTap, hoverColor: c.surfaceHover, child: row),
      );
    }

    Text text(String value, int col, TextStyle style) {
      final bool numeric = columns[col].numeric;
      return Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: numeric ? TextAlign.end : TextAlign.start,
        style: numeric ? style.copyWith(fontFeatures: DsTypography.numeric) : style,
      );
    }

    Widget headerCell(int i) {
      final Widget label = text(columns[i].label, i, head);
      if (onSort == null) return label;
      final bool active = sortColumn == i;
      return InkWell(
        onTap: () => onSort!(i),
        child: Row(
          mainAxisAlignment: columns[i].numeric ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: <Widget>[
            Flexible(child: label),
            if (active)
              Icon(
                sortAscending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                size: 14,
                color: c.textSecondary,
              ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        line(<Widget>[for (int i = 0; i < columns.length; i++) headerCell(i)], header: true),
        for (int r = 0; r < rows.length; r++)
          line(
            <Widget>[for (int i = 0; i < rows[r].length && i < columns.length; i++) text(rows[r][i], i, cell)],
            color: highlightedRows.contains(r) ? c.warningContainer : null,
            onTap: onRowTap == null ? null : () => onRowTap!(r),
            key: rowKey?.call(r),
          ),
        if (totals != null)
          line(<Widget>[
            for (int i = 0; i < totals!.length && i < columns.length; i++)
              text(totals![i], i, cell.copyWith(fontWeight: FontWeight.w600)),
          ], color: c.surfaceVariant),
      ],
    );
  }
}
