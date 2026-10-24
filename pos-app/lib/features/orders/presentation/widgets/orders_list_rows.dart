// Строка заказа SCR-25 (02 UI-25-006…UI-25-009): compact — 72, medium — 56 (анатомия по образцу `TransactionRow`
// 03 §9.38: иконка `receipt` в круге 40, номер и клиент, дата, сумма и `StatusChip`), expanded — строка таблицы 48
// (№ POS / № 1С, дата, клиент, сумма, оплачено, статус, документы). «Оплачено» и статус — раздельно
// (SRC-E-168/169): «Оплачен», «X из Y» или «Долг» (`credit`).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/orders_format.dart';

/// Ширины колонок таблицы expanded (flex).
const List<int> _flex = <int>[3, 2, 3, 2, 2, 3];

/// Наименование клиента строки.
String? orderCustomerName(OrderHeader o) => o.customer?.displayName ?? o.customer?.name;

/// Дата строки (UI-25-006): создание заказа (`OrderSummary.audit.createdAt`, FQ-FEORD-02); без неё — дата документа
/// 1С; нет обеих — «—».
DateTime? orderRowDate(OrderHeader o) => o.createdAt ?? o.onec?.date;

/// «Оплачено» строки (UI-25-008).
class OrderPaidLabel extends StatelessWidget {
  /// Создаёт подпись.
  const OrderPaidLabel({super.key, required this.order, this.align = TextAlign.end});

  final OrderHeader order;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    if (order.paymentMethod == PaymentMethod.credit && !order.isPaid) {
      return StatusChip(label: l10n.orders_paid_credit, variant: StatusChipVariant.warning, dense: true);
    }
    final TextStyle base = context.text.caption.copyWith(fontFeatures: DsTypography.numeric);
    if (order.isPaid) {
      return Text(
        l10n.orders_paid_full,
        textAlign: align,
        style: base.copyWith(color: c.success, fontWeight: FontWeight.w600),
      );
    }
    final Money paid = order.paidAmount ?? Money.zero;
    final Money total = order.totalToPay ?? order.total;
    return Text(
      paid.isZero
          ? OrdersFormat.amount(paid)
          : l10n.orders_paid_partial(OrdersFormat.amount(paid), OrdersFormat.amount(total)),
      textAlign: align,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: base.copyWith(color: c.textSecondary),
    );
  }
}

/// Строка списка compact (72) / medium (56).
class OrdersListRow extends StatelessWidget {
  /// Создаёт строку.
  const OrdersListRow({super.key, required this.order, required this.onTap, this.dense = false});

  final OrderSummary order;
  final VoidCallback onTap;

  /// medium — 56.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final String? customer = orderCustomerName(order);
    final DateTime? date = orderRowDate(order);
    final String number = order.publicNumber;
    final String sub = <String>[?order.onec?.number, ?customer, if (date != null) OrdersFormat.date(date)].join(' · ');
    return Semantics(
      button: true,
      child: DsInteractive(
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) => AnimatedContainer(
          duration: context.motion.of(context.motion.fast),
          constraints: BoxConstraints(minHeight: dense ? 56 : 72),
          padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
          color: s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface),
          child: Row(
            children: <Widget>[
              if (!dense) ...<Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: c.primaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.receipt_outlined, size: 20, color: c.primaryText),
                ),
                SizedBox(width: context.space.s3),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      number,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodyMedium.copyWith(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontFeatures: DsTypography.numeric,
                      ),
                    ),
                    if (sub.isNotEmpty)
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.caption.copyWith(color: c.textSecondary),
                      ),
                    if (!dense) ...<Widget>[
                      SizedBox(height: context.space.s1),
                      OrderStatusChip(status: order.status, dense: true),
                    ],
                  ],
                ),
              ),
              SizedBox(width: context.space.s3),
              if (dense) ...<Widget>[
                OrderStatusChip(status: order.status, dense: true),
                SizedBox(width: context.space.s3),
              ],
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    OrdersFormat.money(order.total),
                    style: context.text.bodyMedium.copyWith(
                      color: c.primaryText,
                      fontWeight: FontWeight.w700,
                      fontFeatures: DsTypography.numeric,
                    ),
                  ),
                  OrderPaidLabel(order: order),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Заголовок таблицы expanded.
class OrdersTableHeader extends StatelessWidget {
  /// Создаёт заголовок.
  const OrdersTableHeader({super.key, required this.withDocuments});

  final bool withDocuments;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final TextStyle st = context.text.label.copyWith(color: c.textSecondary, fontWeight: FontWeight.w600);
    final List<String> cols = <String>[
      OrdersTexts.colNumber(l10n),
      OrdersTexts.colDate(l10n),
      OrdersTexts.colCustomer(l10n),
      OrdersTexts.colAmount(l10n),
      OrdersTexts.colPaid(l10n),
      OrdersTexts.colStatus(l10n),
    ];
    return Container(
      height: 40,
      padding: EdgeInsets.symmetric(horizontal: context.space.s4),
      decoration: BoxDecoration(
        color: c.surfaceVariant,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < cols.length; i++)
            Expanded(
              flex: _flex[i],
              child: Padding(
                padding: EdgeInsetsDirectional.only(end: context.space.s2),
                child: Text(
                  cols[i],
                  textAlign: i == 3 || i == 4 ? TextAlign.end : TextAlign.start,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: st,
                ),
              ),
            ),
          if (withDocuments) const SizedBox(width: 56),
        ],
      ),
    );
  }
}

/// Строка таблицы expanded (48).
class OrdersTableRow extends StatelessWidget {
  /// Создаёт строку.
  const OrdersTableRow({super.key, required this.order, required this.onTap, this.onPrint, this.printEnabled = true});

  final OrderSummary order;
  final VoidCallback onTap;

  /// Меню печати UI-25-009 (`null` — колонки нет: нет права).
  final ValueChanged<BuildContext>? onPrint;

  /// disabled для `submitting`/`submit_failed`.
  final bool printEnabled;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final TextStyle body = context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric);
    final DateTime? date = orderRowDate(order);
    Widget cell(int i, Widget child) => Expanded(
      flex: _flex[i],
      child: Padding(
        padding: EdgeInsetsDirectional.only(end: context.space.s2),
        child: child,
      ),
    );
    return Semantics(
      button: true,
      child: DsInteractive(
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) => AnimatedContainer(
          duration: context.motion.of(context.motion.fast),
          height: 48,
          padding: EdgeInsets.symmetric(horizontal: context.space.s4),
          decoration: BoxDecoration(
            color: s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface),
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: Row(
            children: <Widget>[
              cell(
                0,
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      order.publicNumber,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: body.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (order.onec?.number != null)
                      Text(
                        order.onec!.number!,
                        maxLines: 1,
                        style: context.text.caption.copyWith(color: c.textSecondary),
                      ),
                  ],
                ),
              ),
              cell(1, Text(date == null ? '—' : OrdersFormat.date(date), maxLines: 1, style: body)),
              cell(2, Text(orderCustomerName(order) ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: body)),
              cell(
                3,
                Text(
                  OrdersFormat.amount(order.total),
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  style: body.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              cell(
                4,
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: OrderPaidLabel(order: order),
                ),
              ),
              cell(
                5,
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OrderStatusChip(status: order.status, dense: true),
                ),
              ),
              if (onPrint != null)
                SizedBox(
                  width: 56,
                  child: Builder(
                    builder: (BuildContext btx) => AppIconButton(
                      key: ValueKey<String>('order-print-${order.id}'),
                      icon: Icons.print_outlined,
                      semanticLabel: l10n.order_doc_print,
                      tooltip: l10n.order_doc_print,
                      small: true,
                      onPressed: printEnabled ? () => onPrint!(btx) : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
