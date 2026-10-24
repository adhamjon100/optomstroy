import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Раскладка строки документа взаиморасчётов.
enum ReceivableDocumentRowLayout {
  /// compact/medium — строка 72: тип+№ и дата слева, сумма и остаток справа, статус под датой.
  list,

  /// expanded — строка таблицы 48: Дата · Документ · Статус · Сумма · Оплачено · Остаток · Срок оплаты · Просрочка.
  table,
}

/// Строка детализации долга `ReceivableDocumentRow` (02 SCR-34 UI-34-005; 10 DEBT-003). Значения — готовыми
/// строками из ответа 1С (FL-05; суммы не вычисляются): платежи и возвраты приходят со знаком «−» ([negative] —
/// иконка и цвет `textPrimary`), просрочка — `StatusChip.error`.
class ReceivableDocumentRow extends StatelessWidget {
  /// Строка документа.
  const ReceivableDocumentRow({
    super.key,
    required this.icon,
    required this.title,
    required this.amount,
    this.date,
    this.statusLabel,
    this.statusVariant = StatusChipVariant.neutral,
    this.paid,
    this.remaining,
    this.due,
    this.overdueLabel,
    this.negative = false,
    this.layout = ReceivableDocumentRowLayout.list,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
  });

  /// Иконка вида (`receipt_long` реализация, `payments` платёж, `undo` возврат, `percent` скидка, `tune` корректировка).
  final IconData icon;

  /// «Реализация № УТ-001234».
  final String title;

  /// Дата документа «22.10.2026».
  final String? date;

  /// Статус («Оплачен», «Ожидает оплаты до 25.10.2026»).
  final String? statusLabel;

  /// Вариант чипа статуса.
  final StatusChipVariant statusVariant;

  /// Сумма документа.
  final String amount;

  /// Оплачено.
  final String? paid;

  /// Остаток.
  final String? remaining;

  /// Срок оплаты.
  final String? due;

  /// «Просрочен 12 дн.» (`error`).
  final String? overdueLabel;

  /// Платёж / возврат (уменьшает долг).
  final bool negative;

  /// Раскладка.
  final ReceivableDocumentRowLayout layout;

  /// Тап (SCR-37 или лист «Документ 1С»).
  final VoidCallback? onTap;

  /// Долгое нажатие («Скопировать номер документа»).
  final VoidCallback? onLongPress;

  /// Подпись для диктора.
  final String? semanticLabel;

  /// Высота строки списка.
  static const double listHeight = 72;

  /// Высота строки таблицы.
  static const double tableHeight = 48;

  /// Доли колонок таблицы (сумма 16).
  static const List<int> columnFlex = <int>[2, 3, 3, 2, 2, 2, 2, 2];

  /// Шапка таблицы (expanded): [labels] — 8 подписей колонок.
  static Widget header(BuildContext context, List<String> labels) {
    final DsColors c = context.colors;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.surfaceVariant,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < labels.length && i < columnFlex.length; i++)
            Expanded(
              flex: columnFlex[i],
              child: Padding(
                padding: EdgeInsets.only(left: i == 6 ? 12 : 0),
                child: Text(
                  labels[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: i >= 3 && i <= 5 ? TextAlign.end : TextAlign.start,
                  style: context.text.caption.copyWith(color: c.textSecondary, fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final TextStyle num = context.text.body.copyWith(fontFeatures: DsTypography.numeric, color: c.textPrimary);
    final Widget content = layout == ReceivableDocumentRowLayout.table
        ? _table(context, c, num)
        : _list(context, c, num);
    return Semantics(
      container: true,
      button: onTap != null,
      label: semanticLabel ?? <String>[title, ?date, amount, ?remaining, ?statusLabel, ?overdueLabel].join(', '),
      excludeSemantics: true,
      child: DsInteractive(
        onTap: onTap,
        onLongPress: onLongPress,
        enabled: onTap != null || onLongPress != null,
        builder: (BuildContext context, DsInteractionState s) => Container(
          decoration: BoxDecoration(
            color: s.pressed ? c.surfacePressed : (s.hovered || s.focused ? c.surfaceHover : c.surface),
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: content,
        ),
      ),
    );
  }

  Widget _icon(DsColors c) => Icon(icon, size: 20, color: negative ? c.success : c.textSecondary);

  Widget _list(BuildContext context, DsColors c, TextStyle num) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: listHeight),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _icon(c),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.body.copyWith(fontWeight: FontWeight.w500, color: c.textPrimary),
                ),
                if (date != null)
                  Text(
                    date!,
                    style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
                  ),
                if (overdueLabel != null || statusLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: <Widget>[
                        if (overdueLabel != null)
                          StatusChip(label: overdueLabel!, variant: StatusChipVariant.error, dense: true)
                        else if (statusLabel != null)
                          StatusChip(label: statusLabel!, variant: statusVariant, dense: true),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                amount,
                style: context.text.bodyLg.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: DsTypography.numeric,
                  color: c.textPrimary,
                ),
              ),
              if (remaining != null)
                Text(
                  remaining!,
                  style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _table(BuildContext context, DsColors c, TextStyle num) {
    Widget cell(int i, Widget child) => Expanded(flex: columnFlex[i], child: child);
    Text t(String? v, {TextAlign align = TextAlign.start, Color? color}) => Text(
      v ?? '—',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: num.copyWith(color: color ?? c.textPrimary),
    );
    return SizedBox(
      height: tableHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: <Widget>[
            cell(0, t(date)),
            cell(
              1,
              Row(
                children: <Widget>[
                  _icon(c),
                  const SizedBox(width: 8),
                  Expanded(child: t(title)),
                ],
              ),
            ),
            cell(
              2,
              Align(
                alignment: Alignment.centerLeft,
                child: statusLabel == null
                    ? t(null)
                    : StatusChip(label: statusLabel!, variant: statusVariant, dense: true),
              ),
            ),
            cell(3, t(amount, align: TextAlign.end)),
            cell(4, t(paid, align: TextAlign.end)),
            cell(5, t(remaining, align: TextAlign.end)),
            cell(6, Padding(padding: const EdgeInsets.only(left: 12), child: t(due))),
            cell(
              7,
              Align(
                alignment: Alignment.centerLeft,
                child: overdueLabel == null
                    ? t(null)
                    : StatusChip(label: overdueLabel!, variant: StatusChipVariant.error, dense: true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
