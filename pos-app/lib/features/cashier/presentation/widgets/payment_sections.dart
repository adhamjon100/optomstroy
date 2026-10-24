// Блоки SCR-38 (02 SCR-38.3): Z1 контекст заказа и сумма (UI-38-001), Z3 наличные (UI-38-004, UI-38-005,
// UI-38-017), Z4 QR (UI-38-007, UI-38-008, UI-38-020, UI-38-022), отказ по долгу (fail-closed, PAY-031; CASH-007),
// Z8 результат (UI-38-016, UI-38-021). Логика — [PaymentController]; здесь только отображение.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/qr_panel.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/cashier/presentation/cashier_format.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// Z1: «Заказ № … · клиент», статус, «К оплате» и строка расчёта (UI-38-001).
class PaymentOrderContext extends StatelessWidget {
  /// Создаёт блок.
  const PaymentOrderContext({super.key, this.order, required this.due});

  /// Заказ; `null` — скелетон.
  final Order? order;

  /// К оплате (`totalToPay − paidAmount`).
  final Money due;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Order? o = order;
    final Widget body;
    if (o == null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SkeletonBox.text(width: 220),
          SizedBox(height: context.space.s3),
          const SkeletonBox(width: 180, height: 36),
        ],
      );
    } else {
      final String customer = o.customer?.displayName ?? o.customer?.name ?? '';
      final Money total = o.totalToPay ?? o.total;
      final String? breakdown = o.subtotal == null
          ? null
          : l10n.payment_breakdown(
              CashierFormat.money(o.discountTotal ?? Money.zero),
              CashierFormat.money(o.paidAmount ?? Money.zero),
              o.discountPercent == null ? '' : CashierFormat.percent(o.discountPercent!),
              CashierFormat.money(o.subtotal!),
              CashierFormat.money(total),
            );
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.payment_order_context(customer, o.publicNumber),
                  key: const ValueKey<String>('payment-order-context'),
                  style: context.text.bodyMedium.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
                ),
              ),
              SizedBox(width: context.space.s2),
              OrderStatusChip(status: o.status, dense: true),
            ],
          ),
          SizedBox(height: context.space.s3),
          Text(l10n.payment_to_pay, style: context.text.caption.copyWith(color: c.textSecondary)),
          Semantics(
            label: '${l10n.payment_to_pay}: ${CashierFormat.money(due)}',
            excludeSemantics: true,
            child: Text(
              CashierFormat.money(due),
              key: const ValueKey<String>('payment-due'),
              style: context.text.display.copyWith(
                color: c.textPrimary,
                fontWeight: FontWeight.w700,
                fontFeatures: DsTypography.numeric,
              ),
            ),
          ),
          if (breakdown != null)
            Text(
              breakdown,
              style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
            ),
        ],
      );
    }
    return Container(
      padding: EdgeInsets.all(context.space.s6),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.all(context.radii.md),
      ),
      child: body,
    );
  }
}

/// Быстрые суммы «Без сдачи» и округления вверх до 100 / 500 / 1000 сом (UI-38-005).
List<Money> quickAmounts(Money due) {
  final List<Money> out = <Money>[due];
  for (final int step in <int>[100, 500, 1000]) {
    final int unit = step * 100;
    final int up = ((due.tyiyn + unit - 1) ~/ unit) * unit;
    final Money m = Money(up);
    if (!out.contains(m) && m > due) out.add(m);
  }
  return out;
}

/// Z3: «Получено от клиента», быстрые суммы, сдача.
class PaymentCashForm extends StatelessWidget {
  /// Создаёт форму.
  const PaymentCashForm({
    super.key,
    required this.controller,
    required this.due,
    required this.received,
    required this.onChanged,
    required this.onQuick,
    required this.onSubmit,
    this.serverLess = false,
    this.enabled = true,
    this.focusNode,
  });

  final TextEditingController controller;
  final Money due;

  /// Разобранное «Получено» (`null` — пусто или неверный ввод).
  final Money? received;
  final ValueChanged<String> onChanged;
  final ValueChanged<Money> onQuick;
  final VoidCallback onSubmit;

  /// Сервер ответил `received_less_than_due`.
  final bool serverLess;
  final bool enabled;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Money? r = received;
    final bool less = serverLess || (r != null && r < due);
    final Money? change = r != null && r >= due ? r - due : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppTextField(
          key: const ValueKey<String>('payment-received'),
          controller: controller,
          focusNode: focusNode,
          autofocus: true,
          enabled: enabled,
          label: l10n.payment_received_label,
          variant: AppTextFieldVariant.number,
          textInputAction: TextInputAction.done,
          errorText: less ? l10n.payment_received_less : null,
          suffix: Padding(
            padding: EdgeInsetsDirectional.only(end: context.space.s3),
            child: Text(PriceText.currency, style: context.text.body.copyWith(color: c.textSecondary)),
          ),
          textStyle: context.text.h3.copyWith(
            color: c.textPrimary,
            fontWeight: FontWeight.w700,
            fontFeatures: DsTypography.numeric,
          ),
          onChanged: onChanged,
          onSubmitted: (_) => onSubmit(),
        ),
        SizedBox(height: context.space.s2),
        Wrap(
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: <Widget>[
            for (final Money m in quickAmounts(due))
              // `CategoryChip` растягивается по ширине `Wrap` — сужаем до содержимого.
              IntrinsicWidth(
                child: CategoryChip(
                  key: ValueKey<String>('payment-quick-${m.tyiyn}'),
                  label: m == due ? l10n.payment_quick_exact : PriceText.formatAmount(m),
                  variant: CategoryChipVariant.choice,
                  selected: r == m,
                  enabled: enabled,
                  onTap: () => onQuick(m),
                ),
              ),
          ],
        ),
        if (change != null) ...<Widget>[
          SizedBox(height: context.space.s3),
          Text(
            l10n.payment_change(CashierFormat.money(change)),
            key: const ValueKey<String>('payment-change'),
            style: context.text.h3.copyWith(
              color: c.textPrimary,
              fontWeight: FontWeight.w700,
              fontFeatures: DsTypography.numeric,
            ),
          ),
        ],
      ],
    );
  }
}

/// Текст причины отказа по долгу: суммы `MoneyAmount` из ответа — в формате «4 200,00 сом» (02 §0.1).
String creditMessage(AppLocalizations l10n, UiError error) {
  String money(Object? raw) {
    if (raw is! String || raw.isEmpty) return '';
    try {
      return CashierFormat.money(Money.fromString(raw));
    } on Object {
      return raw;
    }
  }

  return switch (error.messageKey) {
    ErrorKeys.creditOverdue => l10n.checkout_credit_reason_overdue(money(error.params['amount'])),
    ErrorKeys.creditLimit => l10n.checkout_credit_reason_limit(money(error.params['remaining'])),
    _ => ErrorTexts.message(l10n, error),
  };
}

/// Блок отказа по долгу (fail-closed, PAY-031; ядро §22.4, §23 п. 5): причина по `creditReason` (ключи 02 §7) и
/// действия «Обновить долг» (`stale_snapshot` / `RECEIVABLES_STALE`) и «Как получить разрешение старшего»
/// (`overdue` / `limit_exceeded` — снимаются только старшим в собственной сессии, CASH-007).
class PaymentCreditBlock extends StatelessWidget {
  /// Создаёт блок.
  const PaymentCreditBlock({
    super.key,
    required this.error,
    required this.onRefreshDebt,
    required this.onSeniorHelp,
    required this.onOtherMethod,
    this.refreshing = false,
    this.dataAsOf,
    this.online = true,
  });

  /// Отказ (детальный ключ — `UiErrorMapper.detailed`).
  final UiError error;
  final VoidCallback onRefreshDebt;
  final VoidCallback onSeniorHelp;
  final VoidCallback onOtherMethod;
  final bool refreshing;

  /// «данные 1С от HH:MM» после «Обновить долг».
  final String? dataAsOf;
  final bool online;

  /// Снимок устарел — помогает «Обновить долг».
  bool get stale => error.creditReason == CreditReason.staleSnapshot || error.code == ProblemCode.receivablesStale;

  /// Блокировка шага 2 (просрочка, лимит) — снимает только старший в своей сессии (PAY-032).
  bool get seniorCanApprove =>
      error.creditReason == CreditReason.overdue || error.creditReason == CreditReason.limitExceeded;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    return Container(
      key: const ValueKey<String>('payment-credit-block'),
      padding: EdgeInsets.all(context.space.s4),
      decoration: BoxDecoration(color: c.errorContainer, borderRadius: BorderRadius.all(context.radii.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.block_rounded, size: 20, color: c.error),
              SizedBox(width: context.space.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l10n.error_credit_blocked,
                      style: context.text.bodyMedium.copyWith(color: c.textPrimary, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      creditMessage(l10n, error),
                      key: const ValueKey<String>('payment-credit-reason'),
                      style: context.text.body.copyWith(color: c.textPrimary),
                    ),
                    if (dataAsOf != null)
                      Text(l10n.ds_data_as_of(dataAsOf!), style: context.text.caption.copyWith(color: c.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: context.space.s3),
          Wrap(
            spacing: context.space.s2,
            runSpacing: context.space.s2,
            children: <Widget>[
              if (stale)
                AppButton(
                  key: const ValueKey<String>('payment-refresh-debt'),
                  label: l10n.receivables_refresh,
                  icon: Icons.refresh_rounded,
                  variant: AppButtonVariant.outlined,
                  size: AppButtonSize.s,
                  loading: refreshing,
                  onPressed: online && !refreshing ? onRefreshDebt : null,
                ),
              if (seniorCanApprove)
                AppButton(
                  key: const ValueKey<String>('payment-senior-help'),
                  label: l10n.checkout_credit_how_to_approve,
                  variant: AppButtonVariant.outlined,
                  size: AppButtonSize.s,
                  onPressed: onSeniorHelp,
                ),
              AppButton(
                key: const ValueKey<String>('payment-credit-other'),
                label: l10n.payment_other_method,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                onPressed: onOtherMethod,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Z4: QR-панель по статусу платежа (03 §9.58; автомат 07 §6.4), таймер TTL (последние 60 с — `warning`).
class PaymentQrSection extends StatefulWidget {
  /// Создаёт блок.
  const PaymentQrSection({
    super.key,
    required this.payment,
    required this.orderNumber,
    required this.due,
    required this.nowUtc,
    required this.creating,
    required this.unavailable,
    required this.bankDown,
    required this.actions,
    this.createFailed = false,
    this.variant = QrPanelVariant.inline,
    this.onExpired,
  });

  final Payment? payment;
  final String orderNumber;
  final Money due;

  /// «Сейчас» (часы приложения) — точка отсчёта таймера.
  final DateTime Function() nowUtc;
  final bool creating;
  final bool unavailable;
  final bool bankDown;
  final bool createFailed;

  /// Кнопки под панелью.
  final List<Widget> actions;
  final QrPanelVariant variant;

  /// TTL показанного QR истёк по часам приложения (таймер блока): экран перестраивает [actions] — «Обновить QR»
  /// (AC-UI-38-007), не дожидаясь ответа сервера о статусе `qr_expired`.
  final VoidCallback? onExpired;

  /// Представление панели по статусу платежа.
  static QrPanelView viewOf(Payment? p, {required bool creating, required bool unavailable, required DateTime now}) {
    if (creating && p == null) return QrPanelView.loading;
    if (p == null) return unavailable ? QrPanelView.unavailable : QrPanelView.loading;
    if (unavailable && p.qr == null) return QrPanelView.unavailable;
    return switch (p.status) {
      PaymentStatus.qrShown =>
        p.qr?.expiresAt != null && !p.qr!.expiresAt!.isAfter(now) ? QrPanelView.expired : QrPanelView.shown,
      PaymentStatus.qrExpired => QrPanelView.expired,
      PaymentStatus.manualConfirm => QrPanelView.review,
      PaymentStatus.received || PaymentStatus.refunded => QrPanelView.received,
      PaymentStatus.voided => QrPanelView.voided,
      _ => QrPanelView.loading,
    };
  }

  @override
  State<PaymentQrSection> createState() => _PaymentQrSectionState();
}

class _PaymentQrSectionState extends State<PaymentQrSection> {
  Timer? _tick;

  /// Срок QR, об истечении которого уже сообщено ([PaymentQrSection.onExpired] — один раз на выпуск QR).
  DateTime? _expiredNotified;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant PaymentQrSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final bool ticking = widget.payment?.status == PaymentStatus.qrShown && widget.payment?.qr?.expiresAt != null;
    if (ticking && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        _notifyExpired();
      });
    } else if (!ticking) {
      _tick?.cancel();
      _tick = null;
    }
  }

  void _notifyExpired() {
    final DateTime? expires = widget.payment?.qr?.expiresAt;
    if (expires == null || _expiredNotified == expires) return;
    final QrPanelView view = PaymentQrSection.viewOf(
      widget.payment,
      creating: widget.creating,
      unavailable: widget.unavailable,
      now: widget.nowUtc(),
    );
    if (view != QrPanelView.expired) return;
    _expiredNotified = expires;
    widget.onExpired?.call();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DateTime now = widget.nowUtc();
    final Payment? p = widget.payment;
    final QrInfo? info = p?.qr;
    final QrPanelView view = PaymentQrSection.viewOf(
      p,
      creating: widget.creating,
      unavailable: widget.unavailable,
      now: now,
    );
    final DateTime? expires = info?.expiresAt;
    String? timer;
    bool timerWarning = false;
    if (view == QrPanelView.shown && expires != null) {
      final Duration left = expires.difference(now);
      timer =
          '${l10n.payment_qr_valid_until(widget.orderNumber, DsBishkekTime.time(expires))} · '
          '${CashierFormat.countdown(left)}';
      timerWarning = left <= const Duration(seconds: 60);
    }
    final (String? status, StatusChipVariant variant, bool busy) = switch (view) {
      QrPanelView.shown => (l10n.payment_qr_waiting, StatusChipVariant.info, true),
      QrPanelView.expired => (l10n.payment_qr_expired, StatusChipVariant.warning, false),
      QrPanelView.review => (
        p?.reviewReason == null
            ? l10n.payment_review_no_webhook
            : PaymentStatusChip.reviewLabelOf(l10n, p!.reviewReason!),
        StatusChipVariant.warning,
        false,
      ),
      QrPanelView.voided => (l10n.status_payment_voided, StatusChipVariant.error, false),
      _ => (null, StatusChipVariant.info, false),
    };
    final String? message = switch (view) {
      QrPanelView.unavailable => widget.bankDown ? l10n.payment_qr_unavailable : l10n.payment_qr_unavailable_onec,
      QrPanelView.shown when info?.payload == null && info?.imageUrl == null => l10n.ds_qr_static_plate_hint,
      _ => null,
    };
    final Money amount = info?.amount ?? p?.amount ?? widget.due;
    final String? note = view == QrPanelView.shown
        ? (info?.autoConfirm == true ? l10n.payment_qr_auto_note : l10n.payment_qr_manual_note)
        : null;
    if (widget.createFailed && p == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _QrError(message: l10n.payment_qr_create_error),
          SizedBox(height: context.space.s2),
          Wrap(spacing: context.space.s2, runSpacing: context.space.s2, children: widget.actions),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Center(
          child: QrPanel(
            key: ValueKey<String>('payment-qr-${view.name}'),
            variant: widget.variant,
            view: view,
            title: l10n.payment_method_qr,
            amountText: CashierFormat.money(amount),
            payload: info?.payload,
            imageUrl: info?.imageUrl,
            timerText: timer,
            timerWarning: timerWarning,
            statusLabel: status,
            statusVariant: variant,
            statusBusy: busy,
            message: message,
            loadingText: l10n.payment_qr_creating,
            receivedText: l10n.payment_success(CashierFormat.money(amount)),
            qrSemanticLabel: '${l10n.payment_method_qr}. ${CashierFormat.money(amount)}. ${widget.orderNumber}',
            actions: widget.actions,
          ),
        ),
        if (note != null)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: Text(
              note,
              key: const ValueKey<String>('payment-qr-note'),
              textAlign: TextAlign.center,
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
            ),
          ),
      ],
    );
  }
}

class _QrError extends StatelessWidget {
  const _QrError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Row(
      key: const ValueKey<String>('payment-qr-error'),
      children: <Widget>[
        Icon(Icons.error_outline_rounded, color: c.error, size: 20),
        SizedBox(width: context.space.s2),
        Expanded(
          child: Text(message, style: context.text.body.copyWith(color: c.error)),
        ),
      ],
    );
  }
}

/// Z8: «Принято 16 007,50 сом · Сдача 92,50», отражение в 1С (UI-38-016, UI-38-021).
class PaymentSuccessView extends StatelessWidget {
  /// Создаёт экран успеха.
  const PaymentSuccessView({super.key, required this.payment, required this.actions});

  final Payment payment;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Money amount = payment.amount;
    final Money? change = payment.changeAmount;
    final OutboxStatus? onec = payment.onec?.status;
    final (String onecLabel, StatusChipVariant onecVariant) = switch (onec) {
      null => (l10n.payment_onec_manual, StatusChipVariant.warning),
      OutboxStatus.confirmed || OutboxStatus.sent => (l10n.payment_onec_confirmed, StatusChipVariant.success),
      OutboxStatus.failed || OutboxStatus.dead => (l10n.transactions_status_onec_error, StatusChipVariant.error),
      _ => (l10n.payment_onec_pending, StatusChipVariant.info),
    };
    return Column(
      key: const ValueKey<String>('payment-success'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.check_circle_rounded, size: 96, color: c.success),
        SizedBox(height: context.space.s4),
        Text(
          l10n.payment_success(CashierFormat.money(amount)),
          textAlign: TextAlign.center,
          style: context.text.h2.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
        ),
        if (change != null && !change.isZero)
          Text(
            l10n.payment_success_change(CashierFormat.money(change)),
            key: const ValueKey<String>('payment-success-change'),
            style: context.text.bodyLg.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          ),
        SizedBox(height: context.space.s3),
        StatusChip(label: onecLabel, variant: onecVariant),
        SizedBox(height: context.space.s6),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: actions,
        ),
      ],
    );
  }
}

/// Информационный блок с иконкой (AlreadyPaid, NotPayable, CreditOrder).
class PaymentInfoBlock extends StatelessWidget {
  /// Создаёт блок.
  const PaymentInfoBlock({super.key, required this.message, required this.actions, this.icon = Icons.info_outline});

  final String message;
  final List<Widget> actions;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: EdgeInsets.all(context.space.s4),
          decoration: BoxDecoration(color: c.infoContainer, borderRadius: BorderRadius.all(context.radii.md)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 20, color: c.info),
              SizedBox(width: context.space.s2),
              Expanded(
                child: Text(
                  message,
                  key: const ValueKey<String>('payment-info'),
                  style: context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: context.space.s4),
        Wrap(alignment: WrapAlignment.end, spacing: context.space.s2, runSpacing: context.space.s2, children: actions),
      ],
    );
  }
}
