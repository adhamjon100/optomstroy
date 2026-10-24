// Блоки SCR-24 (02 SCR-24.2/24.3): A — шапка (номер, № 1С, статус, свежесть 1С), B — баннеры, C — история
// статусов, D — клиент и получение, E — состав, F — итоги и оплата, G — платежи. Только токены варианта B и строки
// ARB; суммы — расчёт сервера (D-23), клиент их только показывает.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/presentation/orders_format.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';

/// Карточка блока: `surface`, обводка `border`, радиус `md`, паддинг 16; заголовок `title`.
class OrderSection extends StatelessWidget {
  /// Создаёт блок.
  const OrderSection({super.key, this.title, required this.child, this.trailing});

  /// Заголовок блока.
  final String? title;

  /// Содержимое.
  final Widget child;

  /// Справа от заголовка.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Container(
      width: double.infinity, // money-double: allow — ширина блока (lp)
      padding: EdgeInsets.all(context.space.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.all(context.radii.md),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (title != null) ...<Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(title!, style: context.text.title.copyWith(color: c.textPrimary)),
                  ),
                ),
                ?trailing,
              ],
            ),
            SizedBox(height: context.space.s3),
          ],
          child,
        ],
      ),
    );
  }
}

/// Строка «подпись — значение» итогов.
class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.label, required this.value, this.strong = false, this.valueKey});

  final String label;
  final String value;
  final bool strong;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final TextStyle base = strong ? context.text.title : context.text.body;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.space.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(label, style: base.copyWith(color: strong ? c.textPrimary : c.textSecondary)),
          ),
          SizedBox(width: context.space.s3),
          Text(
            value,
            key: valueKey,
            style: base.copyWith(
              color: c.textPrimary,
              fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
              fontFeatures: DsTypography.numeric,
            ),
          ),
        ],
      ),
    );
  }
}

/// A — шапка заказа (UI-24-001, UI-24-002, UI-24-018, UI-24-014).
class OrderHeaderBlock extends StatelessWidget {
  /// Создаёт шапку.
  const OrderHeaderBlock({
    super.key,
    required this.order,
    required this.viewer,
    required this.nowUtc,
    this.refreshing = false,
    this.onRefreshOnec,
  });

  final Order order;
  final OrdersViewer viewer;
  final DateTime nowUtc;
  final bool refreshing;

  /// «Обновить» статус из 1С (staff; офлайн — `null`).
  final VoidCallback? onRefreshOnec;

  /// Данные 1С устарели (D-29): статус старше 15 мин [ТИПОВО].
  static bool isStale(DateTime? lastSyncAt, DateTime nowUtc) =>
      lastSyncAt != null && nowUtc.difference(lastSyncAt) > const Duration(minutes: 15);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final OrderOnecInfo? onec = order.onec;
    final Widget chips = Wrap(
      spacing: context.space.s2,
      runSpacing: context.space.s1,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        OrderStatusChip(key: const ValueKey<String>('order-status'), status: order.status),
        if (order.cancelRequested)
          StatusChip(
            key: const ValueKey<String>('order-cancel-requested'),
            label: l10n.order_cancel_requested_snackbar,
            variant: StatusChipVariant.info,
          ),
      ],
    );
    final DateTime? synced = onec?.lastSyncAt;
    final bool stale = isStale(synced, nowUtc);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        chips,
        if (onec?.number != null) ...<Widget>[
          SizedBox(height: context.space.s1),
          Text(
            l10n.order_onec_number(onec?.date == null ? '' : OrdersFormat.date(onec!.date!), onec!.number!),
            key: const ValueKey<String>('order-onec-number'),
            style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          ),
        ],
        // UI-24-001: момент создания и автор (`Order.audit.createdAt`, `audit.createdBy`; FQ-FEORD-02).
        if (order.createdAt != null || order.createdBy != null) ...<Widget>[
          SizedBox(height: context.space.s1),
          Text(
            <String>[
              if (order.createdAt != null) OrdersFormat.dateTime(order.createdAt!),
              if (order.createdBy != null) order.createdBy!.displayName,
            ].join(' · '),
            key: const ValueKey<String>('order-created-meta'),
            style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          ),
        ],
        if (viewer.isStaff && synced != null) ...<Widget>[
          SizedBox(height: context.space.s1),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                stale ? Icons.schedule_rounded : Icons.cloud_done_outlined,
                size: 16,
                color: stale ? c.warning : c.textSecondary,
              ),
              SizedBox(width: context.space.s1),
              // compact 360/390: длинная метка переносится, кнопка «Обновить» остаётся в строке (без переполнения).
              Flexible(
                child: Text(
                  l10n.order_onec_freshness(OrdersFormat.stamp(synced, nowUtc)).split(' · ').first,
                  style: context.text.caption.copyWith(color: stale ? c.warning : c.textSecondary),
                ),
              ),
              SizedBox(width: context.space.s1),
              AppButton(
                key: const ValueKey<String>('order-refresh-onec'),
                label: l10n.order_onec_refresh,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                loading: refreshing,
                onPressed: refreshing ? null : onRefreshOnec,
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Заголовок «Заказ № POS-…» (UI-24-001): номер POS копируется долгим нажатием / правым кликом («Скопировано»).
  static Widget numberTitle(BuildContext context, Order order) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    void copy() {
      unawaited(Clipboard.setData(ClipboardData(text: order.publicNumber)));
      AppSnackbar.show(context, message: l10n.ds_copied);
    }

    return GestureDetector(
      key: const ValueKey<String>('order-number'),
      onLongPress: copy,
      onSecondaryTap: copy,
      child: Text(
        l10n.order_title(order.publicNumber),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontFeatures: DsTypography.numeric),
      ),
    );
  }
}

/// B — баннеры заказа (UI-24-015).
class OrderBanners extends StatelessWidget {
  /// Создаёт баннеры.
  const OrderBanners({super.key, required this.order, required this.viewer, this.onOnecLink, this.onOpenRestoredCart});

  final Order order;
  final OrdersViewer viewer;

  /// «Открыть восстановленную корзину» у `submit_failed` (UI-24-015, ORD-027); `null` — кнопки нет.
  final VoidCallback? onOpenRestoredCart;

  /// Кнопка UI-24-021 в баннере неоднозначного сопоставления (только с правом).
  final VoidCallback? onOnecLink;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Widget> banners = <Widget>[
      if (order.status == OrderStatus.submitting && order.onecSyncState != OnecSyncState.ambiguous)
        ErrorState.banner(
          key: const ValueKey<String>('banner-submitting'),
          message: l10n.order_banner_submitting,
          tone: ErrorStateTone.info,
        ),
      if (order.status == OrderStatus.submitFailed) ...<Widget>[
        ErrorState.banner(
          key: const ValueKey<String>('banner-rejected'),
          message: l10n.order_banner_rejected(order.submitError?.message ?? order.submitError?.code ?? ''),
        ),
        if (onOpenRestoredCart != null)
          Padding(
            padding: EdgeInsets.symmetric(vertical: context.space.s2),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppButton(
                key: const ValueKey<String>('order-open-restored-cart'),
                label: l10n.checkout_open_restored_cart,
                variant: AppButtonVariant.tonal,
                size: AppButtonSize.s,
                onPressed: onOpenRestoredCart,
              ),
            ),
          ),
      ],
      // Неоднозначное сопоставление с 1С разбирает магазин (UI-24-021) — клиенту служебный баннер не показывается.
      if (order.onecSyncState == OnecSyncState.ambiguous && !viewer.isCustomer)
        ErrorState.banner(
          key: const ValueKey<String>('banner-match-ambiguous'),
          message: l10n.order_banner_match_ambiguous,
          tone: ErrorStateTone.warning,
        ),
      if (order.totalsDiffer && order.onecTotal != null)
        ErrorState.banner(
          key: const ValueKey<String>('banner-total-adjusted'),
          message: l10n.order_banner_total_adjusted(
            OrdersFormat.money(order.onecTotal!),
            OrdersFormat.money(order.total),
          ),
          tone: ErrorStateTone.info,
        ),
      if (order.cancelRequested)
        ErrorState.banner(
          key: const ValueKey<String>('banner-cancel-requested'),
          message: l10n.order_banner_cancel_requested(
            order.cancelRequestedAt == null ? '' : OrdersFormat.dateTime(order.cancelRequestedAt!),
          ),
          tone: ErrorStateTone.info,
        ),
    ];
    if (banners.isEmpty) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.all(context.radii.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: banners),
    );
  }
}

/// C — история статусов (UI-24-003): лента с источником; compact — свёрнута до последних 3 событий.
class OrderHistoryBlock extends StatefulWidget {
  /// Создаёт ленту.
  const OrderHistoryBlock({super.key, required this.order, this.collapsible = false});

  final Order order;
  final bool collapsible;

  /// Ожидаемая цепочка статусов (D-20) — будущие шаги рисуются контуром как ориентир.
  static const List<OrderStatus> chain = <OrderStatus>[
    OrderStatus.submitting,
    OrderStatus.pendingApproval,
    OrderStatus.approved,
    OrderStatus.awaitingShipment,
    OrderStatus.shipped,
    OrderStatus.closed,
  ];

  @override
  State<OrderHistoryBlock> createState() => _OrderHistoryBlockState();
}

class _OrderHistoryBlockState extends State<OrderHistoryBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final List<OrderStatusEntry> all = List<OrderStatusEntry>.of(widget.order.history)
      ..sort((OrderStatusEntry a, OrderStatusEntry b) => a.at.compareTo(b.at));
    final bool collapse = widget.collapsible && !_expanded && all.length > 3;
    final List<OrderStatusEntry> shown = collapse ? all.sublist(all.length - 3) : all;
    final int current = OrderHistoryBlock.chain.indexOf(widget.order.status);
    final List<OrderStatus> future = current < 0
        ? const <OrderStatus>[]
        : OrderHistoryBlock.chain
              .sublist(current + 1)
              .where((OrderStatus s) => s != OrderStatus.awaitingShipment)
              .toList();
    return OrderSection(
      title: OrdersTexts.sectionHistory(l10n),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _maybeAnimated(
            context,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final OrderStatusEntry e in shown) _entry(context, l10n, e),
                for (final OrderStatus s in future) _future(context, l10n, s),
              ],
            ),
          ),
          if (widget.collapsible && all.length > 3)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppButton(
                key: const ValueKey<String>('history-toggle'),
                label: _expanded ? l10n.order_history_collapse : l10n.order_history_show_all,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ),
          if (all.isEmpty && future.isEmpty) Text('—', style: context.text.body.copyWith(color: c.textSecondary)),
        ],
      ),
    );
  }

  /// Раскрытие истории — `AnimatedSize` 200 мс; reduce motion — мгновенно (без анимации размера).
  Widget _maybeAnimated(BuildContext context, Widget child) => context.motion.reduceMotion
      ? child
      : AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: context.motion.standard,
          alignment: Alignment.topCenter,
          child: child,
        );

  Widget _rail(BuildContext context, {required bool done}) {
    final DsColors c = context.colors;
    return SizedBox(
      width: 24,
      child: Column(
        children: <Widget>[
          Icon(
            done ? Icons.circle : Icons.radio_button_unchecked_rounded,
            size: 12,
            color: done ? c.primaryText : c.borderStrong,
          ),
          Expanded(child: Container(width: 2, color: c.border)),
        ],
      ),
    );
  }

  Widget _entry(BuildContext context, AppLocalizations l10n, OrderStatusEntry e) {
    final DsColors c = context.colors;
    final bool fromOnec = e.source == StatusChangeSource.onecSync || e.source == StatusChangeSource.onecResponse;
    final String source = fromOnec ? l10n.order_history_source_onec : l10n.order_history_source_app;
    final String who = e.source == StatusChangeSource.posUser && e.by != null ? ' · ${e.by!.displayName}' : '';
    return SizedBox(
      key: ValueKey<String>('history-${e.status.value}-${e.at.toIso8601String()}'),
      height: 48,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(padding: const EdgeInsets.only(top: 6), child: _rail(context, done: true)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                OrderStatusChip(status: e.status, dense: true),
                Text(
                  '${OrdersFormat.dateTime(e.at)} · $source$who',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _future(BuildContext context, AppLocalizations l10n, OrderStatus s) {
    final DsColors c = context.colors;
    return SizedBox(
      height: 40,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(top: context.space.s1),
            child: _rail(context, done: false),
          ),
          Expanded(
            child: Text(OrderStatusChip.labelOf(l10n, s), style: context.text.body.copyWith(color: c.textTertiary)),
          ),
        ],
      ),
    );
  }
}

/// D — клиент и получение (UI-24-004, UI-24-005).
class OrderCustomerBlock extends StatelessWidget {
  /// Создаёт блок.
  const OrderCustomerBlock({super.key, required this.order, required this.viewer, this.onOpenCustomer});

  final Order order;
  final OrdersViewer viewer;

  /// «Карточка ›» → SCR-32 (staff).
  final VoidCallback? onOpenCustomer;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final String? name = order.customer?.displayName ?? order.customer?.name;
    final Delivery? d = order.delivery;
    final Receiver? r = order.receiver;
    final List<String> deliveryParts = <String>[
      if (d?.address != null && d!.address!.isNotEmpty) d.address!,
      if (d?.desiredDate != null)
        <String>[
          OrdersFormat.plainDate(d!.desiredDate!),
          if (d.timeFrom != null || d.timeTo != null) '${d.timeFrom ?? ''}–${d.timeTo ?? ''}',
        ].join(', '),
      if (r != null && r.kind == ReceiverKind.otherPerson && (r.name != null || r.phoneE164 != null))
        <String>[?r.name, ?r.phoneE164].join(', '),
      if (d?.courierComment != null && d!.courierComment!.isNotEmpty) '«${d.courierComment}»',
    ];
    return OrderSection(
      title: OrdersTexts.sectionCustomer(l10n),
      trailing: viewer.canOpenCustomerCard && order.customer != null && onOpenCustomer != null
          ? AppButton(
              key: const ValueKey<String>('order-customer-card'),
              label: l10n.order_customer_card_link,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
              onPressed: onOpenCustomer,
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (name != null) Text(name, style: context.text.bodyMedium.copyWith(color: c.textPrimary)),
          if (order.customer?.phoneMasked != null)
            Text(order.customer!.phoneMasked!, style: context.text.caption.copyWith(color: c.textSecondary)),
          SizedBox(height: context.space.s3),
          Text(OrdersTexts.sectionDelivery(l10n), style: context.text.label.copyWith(color: c.textSecondary)),
          SizedBox(height: context.space.s1),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                d?.method == DeliveryMethod.delivery ? Icons.local_shipping_outlined : Icons.storefront_outlined,
                size: 20,
                color: c.textSecondary,
              ),
              SizedBox(width: context.space.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      d?.method == DeliveryMethod.delivery ? OrdersTexts.delivery(l10n) : OrdersTexts.pickup(l10n),
                      style: context.text.body.copyWith(color: c.textPrimary),
                    ),
                    if (deliveryParts.isNotEmpty)
                      Text(deliveryParts.join(' · '), style: context.text.caption.copyWith(color: c.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// E — состав (UI-24-006): снимок наименования и артикула; expanded — таблица.
class OrderItemsBlock extends StatelessWidget {
  /// Создаёт блок.
  const OrderItemsBlock({super.key, required this.order, this.table = false, this.onOpenProduct});

  final Order order;
  final bool table;

  /// Тап по строке → SCR-14 (текущая карточка товара).
  final ValueChanged<String>? onOpenProduct;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    return OrderSection(
      title: OrdersTexts.sectionItems(l10n),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < order.items.length; i++) ...<Widget>[
            if (i > 0) Divider(height: 1, thickness: 1, color: c.border),
            _line(context, order.items[i]),
          ],
        ],
      ),
    );
  }

  Widget _line(BuildContext context, OrderLine line) {
    final DsColors c = context.colors;
    final String title = <String>[?line.productName, ?line.variantName].join(' · ');
    final String qty = OrdersFormat.qty(line.quantity.value);
    final String price = line.unitPrice == null ? '' : ' × ${OrdersFormat.amount(line.unitPrice!)}';
    final Money? discount = line.discountAmount;
    final Widget main = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title.isEmpty ? line.variantId : title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.text.body.copyWith(color: c.textPrimary),
        ),
        if (line.sku != null) Text(line.sku!, style: context.text.caption.copyWith(color: c.textSecondary)),
        if (!table)
          Text(
            '$qty$price${discount == null || discount.isZero ? '' : ' · −${OrdersFormat.amount(discount)}'}',
            style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          ),
        if (line.shippedQuantity != null && line.shippedQuantity! < line.quantity.value)
          Text(
            '${OrdersFormat.qty(line.shippedQuantity!)} / $qty',
            style: context.text.caption.copyWith(color: c.warning, fontFeatures: DsTypography.numeric),
          ),
      ],
    );
    final TextStyle numStyle = context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric);
    final Widget total = Text(
      line.lineTotal == null ? '' : OrdersFormat.amount(line.lineTotal!),
      style: numStyle.copyWith(fontWeight: FontWeight.w600),
    );
    final Widget row = table
        ? Row(
            children: <Widget>[
              Expanded(flex: 5, child: main),
              Expanded(
                child: Text(qty, textAlign: TextAlign.end, style: numStyle),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  line.unitPrice == null ? '' : OrdersFormat.amount(line.unitPrice!),
                  textAlign: TextAlign.end,
                  style: numStyle,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  discount == null || discount.isZero ? '' : '−${OrdersFormat.amount(discount)}',
                  textAlign: TextAlign.end,
                  style: numStyle.copyWith(color: c.textSecondary),
                ),
              ),
              Expanded(
                flex: 2,
                child: Align(alignment: AlignmentDirectional.centerEnd, child: total),
              ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: main),
              SizedBox(width: context.space.s3),
              total,
            ],
          );
    final String? productId = line.productId;
    return InkWell(
      key: ValueKey<String>('order-line-${line.lineNo}'),
      onTap: productId == null || onOpenProduct == null ? null : () => onOpenProduct!(productId),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.space.s2),
        child: row,
      ),
    );
  }
}

/// F — итоги и оплата (UI-24-007, UI-24-016): «Оплачено X из Y» — агрегат, не статус (AC-UI-24-002).
class OrderTotalsBlock extends StatelessWidget {
  /// Создаёт блок.
  const OrderTotalsBlock({super.key, required this.order, required this.viewer});

  final Order order;
  final OrdersViewer viewer;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Money total = order.totalToPay ?? order.total;
    final Money paid = order.paidAmount ?? Money.zero;
    final bool credit = order.paymentMethod == PaymentMethod.credit;
    final Money? customerDiscount = order.customerDiscountTotal;
    final Money? discount = order.discountTotal;
    return OrderSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (order.subtotal != null)
            _KeyValue(label: OrdersTexts.subtotal(l10n), value: OrdersFormat.amount(order.subtotal!)),
          if (customerDiscount != null && !customerDiscount.isZero)
            _KeyValue(label: OrdersTexts.customerDiscount(l10n), value: '−${OrdersFormat.amount(customerDiscount)}'),
          if (discount != null && !discount.isZero)
            _KeyValue(
              label: OrdersTexts.discount(l10n, order.discountPercent),
              value: '−${OrdersFormat.amount(discount)}',
            ),
          _KeyValue(
            label: OrdersTexts.total(l10n),
            value: OrdersFormat.money(order.total),
            strong: true,
            valueKey: const ValueKey<String>('order-total'),
          ),
          SizedBox(height: context.space.s1),
          Text(
            credit && order.onec?.lastSyncAt != null
                ? l10n.order_credit_paid_of(
                    OrdersFormat.amount(paid),
                    OrdersFormat.dateTime(order.onec!.lastSyncAt!),
                    OrdersFormat.amount(total),
                  )
                : l10n.order_paid_of(OrdersFormat.amount(paid), OrdersFormat.money(total)),
            key: const ValueKey<String>('order-paid-of'),
            style: context.text.bodyMedium.copyWith(
              color: order.isPaid ? c.success : c.textPrimary,
              fontFeatures: DsTypography.numeric,
            ),
          ),
          if (order.paymentDueDate != null && (viewer.isStaff || viewer.isCustomer)) ...<Widget>[
            SizedBox(height: context.space.s1),
            Text(
              l10n.order_due_date(OrdersFormat.plainDate(order.paymentDueDate!)),
              style: context.text.caption.copyWith(color: c.warning),
            ),
          ],
        ],
      ),
    );
  }
}

/// G — платежи заказа (UI-24-008).
class OrderPaymentsBlock extends StatelessWidget {
  /// Создаёт блок.
  const OrderPaymentsBlock({super.key, required this.order, this.onOpenTransaction, this.customerMode = false});

  final Order order;

  /// Режим клиента (10 CUST-024; RM-G-014): `manual_confirm` — «Оплата проверяется магазином» без причины разбора,
  /// без сотрудника, подтвердившего платёж, и без перехода в журнал операций.
  final bool customerMode;

  /// Тап по платежу → SCR-37 (транзакция платежа, UI-24-008); вызывается только для платежа с `transactionId`
  /// (OpenAPI 1.2.0; пока сервер поле не передаёт — строка не нажимается).
  final ValueChanged<String>? onOpenTransaction;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    return OrderSection(
      title: OrdersTexts.sectionPayments(l10n),
      child: order.payments.isEmpty
          ? Text(
              l10n.order_payments_empty,
              key: const ValueKey<String>('order-payments-empty'),
              style: context.text.body.copyWith(color: c.textSecondary),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int i = 0; i < order.payments.length; i++) ...<Widget>[
                  if (i > 0) Divider(height: 1, thickness: 1, color: c.border),
                  _row(context, l10n, order.payments[i]),
                ],
              ],
            ),
    );
  }

  Widget _row(BuildContext context, AppLocalizations l10n, Payment p) {
    final DsColors c = context.colors;
    final String when = p.confirmedAt == null ? '' : OrdersFormat.dateTime(p.confirmedAt!);
    final String who = customerMode ? '' : (p.confirmedBy?.displayName ?? '');
    final String? transactionId = p.transactionId;
    final ValueChanged<String>? open = customerMode ? null : onOpenTransaction;
    final Widget row = ConstrainedBox(
      key: ValueKey<String>('payment-${p.id}'),
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.space.s2),
        child: Row(
          children: <Widget>[
            Icon(
              p.method == PaymentMethod.qrBakai
                  ? Icons.qr_code_2_rounded
                  : (p.method == PaymentMethod.credit ? Icons.schedule_rounded : Icons.payments_outlined),
              size: 24,
              color: c.textSecondary,
            ),
            SizedBox(width: context.space.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    OrdersTexts.paymentMethod(l10n, p.method),
                    style: context.text.body.copyWith(color: c.textPrimary),
                  ),
                  if (when.isNotEmpty || who.isNotEmpty)
                    Text(
                      <String>[if (when.isNotEmpty) when, if (who.isNotEmpty) who].join(' · '),
                      style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
                    ),
                  SizedBox(height: context.space.s1),
                  if (customerMode)
                    StatusChip(
                      key: ValueKey<String>('payment-status-customer-${p.id}'),
                      label: OrdersTexts.customerPaymentStatus(l10n, p.status),
                      variant: p.status == PaymentStatus.manualConfirm
                          ? StatusChipVariant.info
                          : (StatusChipMapping.variantOf('payment', p.status.value) ?? StatusChipVariant.neutral),
                      dense: true,
                    )
                  else
                    PaymentStatusChip(status: p.status, reviewReason: p.reviewReason, dense: true),
                ],
              ),
            ),
            Text(
              OrdersFormat.amount(p.amount),
              style: context.text.bodyMedium.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
            ),
          ],
        ),
      ),
    );
    if (transactionId == null || open == null) return row;
    return InkWell(key: ValueKey<String>('payment-open-${p.id}'), onTap: () => open(transactionId), child: row);
  }
}
