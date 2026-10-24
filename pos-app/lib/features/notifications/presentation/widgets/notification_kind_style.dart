// Отображение видов `notification_kind` (02 SCR-44.3 «Сопоставление видов»: иконка / цвет / подпись ARB)
// и группы фильтра видов UI-44-006 («Синхронизация», «Заказы», «Корзина», «Оплата», «Возвраты», «Долг», «Система»).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';

/// Иконка и цвет вида.
final class NotificationKindStyle {
  const NotificationKindStyle(this.icon, this.color);

  final IconData icon;
  final Color color;

  static NotificationKindStyle of(BuildContext context, AppNotification n) {
    final DsColors c = context.colors;
    return switch (n.kind) {
      NotificationKind.syncError => NotificationKindStyle(Icons.sync_problem_rounded, c.error),
      NotificationKind.orderStatus => NotificationKindStyle(Icons.receipt_long_rounded, c.info),
      NotificationKind.cartPriceChanged => NotificationKindStyle(Icons.sell_rounded, c.warning),
      NotificationKind.cartStockChanged => NotificationKindStyle(Icons.inventory_2_rounded, c.warning),
      NotificationKind.creditBlocked => NotificationKindStyle(Icons.block_rounded, c.error),
      // Цвет — по `severity` (08 §3.13, ревью закрытия F RS-1): статус платежа в `payload.status` сервер не передаёт
      // (`status` у `payment_status` — только статус заказа вместе с `task: refund_or_advance`).
      NotificationKind.paymentStatus => NotificationKindStyle(Icons.payments_rounded, switch (n.severity) {
        NotificationSeverity.info => c.success,
        NotificationSeverity.warning => c.warning,
        NotificationSeverity.error => c.error,
      }),
      NotificationKind.returnStatus => NotificationKindStyle(Icons.undo_rounded, c.info),
      NotificationKind.system => NotificationKindStyle(Icons.info_outline_rounded, c.textSecondary),
      null => NotificationKindStyle(Icons.notifications_none_rounded, c.textSecondary),
    };
  }
}

/// Подписи и статусы.
abstract final class NotificationLabels {
  /// Подпись вида (`notification_kind_*`); неизвестный вид — заголовок экрана.
  static String kind(AppLocalizations l10n, NotificationKind? kind) => switch (kind) {
    NotificationKind.syncError => l10n.notification_kind_sync_error,
    NotificationKind.orderStatus => l10n.notification_kind_order_status,
    NotificationKind.cartPriceChanged => l10n.notification_kind_cart_price_changed,
    NotificationKind.cartStockChanged => l10n.notification_kind_cart_stock_changed,
    NotificationKind.creditBlocked => l10n.notification_kind_credit_blocked,
    NotificationKind.paymentStatus => l10n.notification_kind_payment_status,
    NotificationKind.returnStatus => l10n.notification_kind_return_status,
    NotificationKind.system => l10n.notification_kind_system,
    null => l10n.notifications_title,
  };

  /// `StatusChip` статуса заказа (`order_status`, `payload.status`); `null` — статуса нет или он неизвестен.
  static StatusChip? orderStatusChip(AppLocalizations l10n, AppNotification n) {
    if (n.kind != NotificationKind.orderStatus) return null;
    final OrderStatus? status = OrderStatus.tryParse(n.payload['status'] as String?);
    if (status == null) return null;
    final StatusChipVariant? variant = StatusChipMapping.variantOf('order', status.value);
    if (variant == null) return null;
    final String label = switch (status) {
      OrderStatus.draft => l10n.status_order_draft,
      OrderStatus.submitting => l10n.status_order_submitting,
      OrderStatus.submitFailed => l10n.status_order_submit_failed,
      OrderStatus.pendingApproval => l10n.status_order_pending_approval,
      OrderStatus.awaitingPayment => l10n.status_order_awaiting_payment,
      OrderStatus.approved => l10n.status_order_approved,
      OrderStatus.awaitingShipment => l10n.status_order_awaiting_shipment,
      OrderStatus.shipped => l10n.status_order_shipped,
      OrderStatus.partiallyReturned => l10n.status_order_partially_returned,
      OrderStatus.closed => l10n.status_order_closed,
      OrderStatus.cancelled => l10n.status_order_cancelled,
    };
    return StatusChip(label: label, variant: variant, dense: true);
  }
}

/// Группа фильтра видов UI-44-006.
enum NotificationKindGroup {
  sync({NotificationKind.syncError}),
  orders({NotificationKind.orderStatus}),
  cart({NotificationKind.cartPriceChanged, NotificationKind.cartStockChanged}),
  payment({NotificationKind.paymentStatus}),
  returns({NotificationKind.returnStatus}),
  debt({NotificationKind.creditBlocked}),
  system({NotificationKind.system});

  const NotificationKindGroup(this.kinds);

  final Set<NotificationKind> kinds;

  /// Подпись чипа фильтра видов (SCR-44.2; ключи `notifications_filter_kind_*`, 03 §16.8, FQ-NOTIF-01).
  String label(AppLocalizations l10n) => switch (this) {
    NotificationKindGroup.sync => l10n.notifications_filter_kind_sync,
    NotificationKindGroup.orders => l10n.notifications_filter_kind_orders,
    NotificationKindGroup.cart => l10n.notifications_filter_kind_cart,
    NotificationKindGroup.payment => l10n.notifications_filter_kind_payment,
    NotificationKindGroup.returns => l10n.notifications_filter_kind_returns,
    NotificationKindGroup.debt => l10n.notifications_filter_kind_debt,
    NotificationKindGroup.system => l10n.notifications_filter_kind_system,
  };

  /// Группа выбрана целиком.
  bool selectedIn(Set<NotificationKind> selected) => kinds.every(selected.contains);
}
