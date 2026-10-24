import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';

/// Статус заказа (D-20) — `StatusChip` по таблице 03 §9.39 (`order.<значение>`): иконка + текст
/// `status_order_<code>` (A11Y-004), подпись для screen reader — сам статус.
///
/// Обёртка над [StatusChip] для SCR-22/24/25 (02 ч. C UI-24-002, UI-25-007): вариант и подпись выбираются
/// только здесь, экраны не повторяют сопоставление.
class OrderStatusChip extends StatelessWidget {
  /// Создаёт чип статуса заказа.
  const OrderStatusChip({super.key, required this.status, this.dense = false, this.tooltip});

  /// Статус заказа.
  final OrderStatus status;

  /// Высота 20 (строки списка на compact).
  final bool dense;

  /// Описание статуса (тултип на expanded).
  final String? tooltip;

  /// Подпись статуса (`status_order_<code>`).
  static String labelOf(AppLocalizations l10n, OrderStatus status) => switch (status) {
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

  /// Вариант по таблице 03 §9.39 (значение без строки — `neutral`, дефект ловит `T-DS-080`).
  static StatusChipVariant variantOf(OrderStatus status) =>
      StatusChipMapping.variantOf('order', status.value) ?? StatusChipVariant.neutral;

  @override
  Widget build(BuildContext context) {
    final String label = labelOf(AppLocalizations.of(context), status);
    return StatusChip(label: label, variant: variantOf(status), dense: dense, tooltip: tooltip);
  }
}

/// Статус платежа (D-21) — `StatusChip` по таблице 03 §9.39 (`payment.<значение>`), подпись
/// `status_payment_<code>`; [reviewReason] — дополнительный чип `warning` (`payment_review_<reason>`).
class PaymentStatusChip extends StatelessWidget {
  /// Создаёт чип статуса платежа.
  const PaymentStatusChip({super.key, required this.status, this.reviewReason, this.dense = false});

  /// Статус платежа.
  final PaymentStatus status;

  /// Причина проверки (атрибут, не статус — ядро §17.2).
  final ReviewReason? reviewReason;

  /// Высота 20.
  final bool dense;

  /// Подпись статуса (`status_payment_<code>`).
  static String labelOf(AppLocalizations l10n, PaymentStatus status) => switch (status) {
    PaymentStatus.initiated => l10n.status_payment_initiated,
    PaymentStatus.cashPending => l10n.status_payment_cash_pending,
    PaymentStatus.qrPending => l10n.status_payment_qr_pending,
    PaymentStatus.qrShown => l10n.status_payment_qr_shown,
    PaymentStatus.qrExpired => l10n.status_payment_qr_expired,
    PaymentStatus.manualConfirm => l10n.status_payment_manual_confirm,
    PaymentStatus.credit => l10n.status_payment_credit,
    PaymentStatus.received => l10n.status_payment_received,
    PaymentStatus.voided => l10n.status_payment_voided,
    PaymentStatus.refunded => l10n.status_payment_refunded,
  };

  /// Подпись причины проверки (`payment_review_<reason>`).
  static String reviewLabelOf(AppLocalizations l10n, ReviewReason reason) => switch (reason) {
    ReviewReason.amountMismatch => l10n.payment_review_amount_mismatch,
    ReviewReason.unknownReference => l10n.payment_review_unknown_reference,
    ReviewReason.noWebhook => l10n.payment_review_no_webhook,
    ReviewReason.latePayment => l10n.payment_review_late_payment,
  };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final StatusChip chip = StatusChip(
      label: labelOf(l10n, status),
      variant: StatusChipMapping.variantOf('payment', status.value) ?? StatusChipVariant.neutral,
      dense: dense,
    );
    final ReviewReason? reason = reviewReason;
    if (reason == null) return chip;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: <Widget>[
        chip,
        StatusChip(
          label: reviewLabelOf(l10n, reason),
          variant: StatusChipMapping.variantOf('payment_review', reason.value) ?? StatusChipVariant.warning,
          dense: dense,
        ),
      ],
    );
  }
}
