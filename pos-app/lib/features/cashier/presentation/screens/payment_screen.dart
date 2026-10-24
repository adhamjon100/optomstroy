// SCR-38 «Приём оплаты» (`/payments/new?orderId=[&method=]` — по заказу; `?customerId=` — по долгу, условно Q-152;
// роли `cashier`, `senior_seller`, без `admin`/`owner` — D-15, ядро §18.2 п. 11). Владелец реализации — агент
// G-fe-cashier (RM-G-007, RM-G-012). Имя класса и параметры конструктора фиксированы маршрутом (routes.dart).
//
// Структура — 02 SCR-38.2: Z1 контекст и сумма · Z2 способ (`PaymentMethodCard` ×2: наличные, QR; плитки `credit`
// нет — версия 1.5) · Z3 наличные · Z4 QR · Z5 заказ в долг (только просмотр) · Z7 печать и CTA · Z8 результат.
// compact — экран с закреплённой CTA; medium+ — карточка 560/640 по центру (маршрут root-уровня, GQ-FECASH-05).
// Режим «по долгу» в R1 выключен (RM-G-013, `features.debtPaymentsFromPos=false`): маршрут закрывает guard, экран —
// состояние «Недоступно». Логика — [PaymentController]; ключи идемпотентности — только память (P-IDEMP).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/payment_method_card.dart';
import 'package:optomstroy/design_system/components/qr_panel.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/cashier/presentation/cashier_format.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/cashier/presentation/state/payment_controller.dart';
import 'package:optomstroy/features/cashier/presentation/widgets/payment_dialogs.dart';
import 'package:optomstroy/features/cashier/presentation/widgets/payment_sections.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// SCR-38. Приём оплаты `/payments/new?orderId=[&method=]` / `?customerId=` (cashier, senior_seller; не admin/owner — D-15).
class PaymentScreen extends ConsumerStatefulWidget {
  /// Экран SCR-38.
  const PaymentScreen({this.orderId, this.customerId, this.method, super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-38';

  /// Ключ корня экрана (тесты маршрутов).
  static const ValueKey<String> rootKey = ValueKey<String>('stub-SCR-38');

  /// Оплата по заказу (`?orderId=`).
  final String? orderId;

  /// Оплата долга без заказа (`?customerId=`) — только при `features.debtPaymentsFromPos` (RM-G-013; в R1 закрыто guard).
  final String? customerId;

  /// Предвыбор способа (`?method=cash|qr_bakai`).
  final String? method;

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> with WidgetsBindingObserver {
  final TextEditingController _received = TextEditingController();
  final FocusNode _receivedFocus = FocusNode();
  late bool _printReceipt = ref.read(cashierPrintReceiptByDefaultProvider);
  bool _confirmOpen = false;

  PaymentArgs get _args => (orderId: widget.orderId, customerId: widget.customerId, method: widget.method);

  PaymentController get _ctl => ref.read(paymentControllerProvider(_args).notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.orderId == null && widget.customerId == null) {
        // Без параметров — на SCR-30 (лист поиска заказа открывает кассир, 02 SCR-38.2).
        context.cashierGo(CashierLocations.dashboard);
        return;
      }
      unawaited(_ctl.open());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ctl.resumeWatch();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      unawaited(_ctl.pauseWatch());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _received.dispose();
    _receivedFocus.dispose();
    super.dispose();
  }

  Money? get _receivedMoney {
    final String t = _received.text.trim();
    if (t.isEmpty) return null;
    try {
      return Money.parseInput(t);
    } on Object {
      return null;
    }
  }

  DateTime _now() => ref.read(clockProvider).nowUtc();

  // ---------------------------------------------------------------------------------------------------------------
  // Действия.

  Future<void> _selectMethod(PaymentScreenState s, PaymentMethod m) async {
    if (s.method == m || s.busy) return;
    final Payment? qr = s.qrPayment;
    if (m == PaymentMethod.cash &&
        qr != null &&
        (qr.status == PaymentStatus.qrShown || qr.status == PaymentStatus.qrPending)) {
      final AppLocalizations l10n = AppLocalizations.of(context);
      final bool ok = await ConfirmDialog.show(
        context,
        title: l10n.payment_qr_switch_confirm,
        message: l10n.payment_qr_manual_note,
        confirmLabel: l10n.ds_button_apply,
      );
      if (!ok || !mounted) return;
    }
    await _ctl.selectMethod(m);
  }

  Future<void> _accept(PaymentScreenState s) async {
    if (_confirmOpen || s.submitting) return;
    final Money? received = _receivedMoney;
    if (received == null || received < s.due) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Order? o = s.order;
    final String customer = o?.customer?.displayName ?? o?.customer?.name ?? '';
    _confirmOpen = true;
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.payment_confirm_title,
      message: l10n.payment_confirm_body_cash(
        CashierFormat.money(s.due),
        CashierFormat.money(received - s.due),
        customer,
        CashierFormat.money(received),
      ),
      confirmLabel: l10n.payment_confirm_cta,
    );
    _confirmOpen = false;
    if (!ok || !mounted) return;
    await _ctl.acceptCash(received);
  }

  Future<void> _confirmManual(PaymentScreenState s) async {
    final Payment? p = s.qrPayment;
    if (p == null) return;
    final ConfirmManualRequest? request = await showManualConfirm(context, amount: p.amount, nowUtc: _now());
    if (request == null || !mounted) return;
    await _ctl.confirmManual(request);
  }

  Future<void> _void(PaymentScreenState s) async {
    final Payment? p = s.qrPayment;
    if (p == null) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final VoidPaymentRequest? request = await showVoidPayment(
      context,
      body: l10n.transaction_details_void_body(CashierFormat.money(p.amount), s.order?.publicNumber ?? ''),
    );
    if (request == null || !mounted) return;
    final bool ok = await _ctl.voidOpenPayment(request);
    if (ok && mounted) AppSnackbar.show(context, message: l10n.transaction_details_void_done);
  }

  Future<void> _discardUnknown() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.payment_unknown_discard,
      message: l10n.payment_unknown_discard_body,
      confirmLabel: l10n.payment_unknown_discard,
      variant: ConfirmDialogVariant.destructive,
    );
    if (ok && mounted) _ctl.discardUnknown();
  }

  Future<void> _showToCustomer(PaymentScreenState s) => showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => Dialog.fullscreen(
      backgroundColor: ctx.colors.surface,
      child: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  child: PaymentQrSection(
                    payment: s.qrPayment,
                    orderNumber: s.order?.publicNumber ?? '',
                    due: s.due,
                    nowUtc: _now,
                    creating: false,
                    unavailable: false,
                    bankDown: false,
                    actions: const <Widget>[],
                    variant: QrPanelVariant.fullscreen,
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(ctx.space.s4),
              child: AppButton(
                label: AppLocalizations.of(ctx).payment_done,
                size: AppButtonSize.l,
                expand: true,
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// «Назад»/«Закрыть» (02 SCR-38.4): подтверждение при введённых данных, показанном QR и неизвестном результате.
  Future<void> _close(PaymentScreenState s) async {
    if (s.busy) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    String? title;
    String message = '';
    if (s.unknown) {
      title = l10n.payment_unknown_close_confirm;
      message = l10n.payment_unknown;
    } else if (s.phase == PaymentPhase.ready) {
      final Payment? qr = s.qrPayment;
      if (qr != null && qr.status == PaymentStatus.qrShown) {
        title = l10n.payment_close_confirm;
        final DateTime? until = qr.qr?.expiresAt;
        message = until == null ? '' : l10n.payment_close_qr_note(DsBishkekTime.time(until));
      } else if (_received.text.trim().isNotEmpty) {
        title = l10n.payment_close_confirm;
      }
    }
    if (title != null) {
      final bool ok = await ConfirmDialog.show(
        context,
        title: title,
        message: message,
        confirmLabel: l10n.ds_button_close,
      );
      if (!ok || !mounted) return;
    }
    context.cashierClose();
  }

  void _openOrder() {
    final String? id = widget.orderId;
    if (id != null) context.cashierGo(CashierLocations.order(id));
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Разметка.

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final PaymentScreenState s = ref.watch(paymentControllerProvider(_args));
    final RoleCode? role = ref.watch(cashierViewerRoleProvider);
    final bool online = ref.watch(cashierOnlineProvider);
    ref.listen<bool>(cashierSessionLockedProvider, (bool? prev, bool locked) {
      if (locked) {
        unawaited(_ctl.pauseWatch());
      } else {
        _ctl.resumeWatch();
      }
    });
    ref.listen<PaymentScreenState>(paymentControllerProvider(_args), (
      PaymentScreenState? prev,
      PaymentScreenState next,
    ) {
      if (prev?.phase != PaymentPhase.success && next.phase == PaymentPhase.success && _printReceipt) {
        unawaited(_ctl.printReceipt());
      }
      if (prev?.print != ReceiptPrintState.failed && next.print == ReceiptPrintState.failed && mounted) {
        AppSnackbar.show(
          context,
          message: l10n.payment_print_failed,
          variant: AppSnackbarVariant.error,
          actionLabel: l10n.ds_button_retry,
          onAction: () => unawaited(_ctl.printReceipt()),
        );
      }
    });
    final WindowClass wc = context.windowClass;
    final bool compact = wc == WindowClass.compact;
    final bool allowedRole = CashierRoles.canAcceptPayment(
      role,
    ); // fail-closed: роль неизвестна — нет кассовых действий
    final Widget content = !allowedRole
        ? EmptyState(variant: EmptyStateVariant.noPermission, title: l10n.error_forbidden)
        : _content(context, l10n, s, online, compact);
    final Widget? bottom = allowedRole && compact ? _bottomBar(context, l10n, s, online) : null;
    final DsColors c = context.colors;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) unawaited(_close(s));
      },
      child: Scaffold(
        key: PaymentScreen.rootKey,
        backgroundColor: compact ? c.surface : c.background,
        appBar: AppBar(
          title: Text(l10n.payment_title),
          leading: IconButton(
            key: const ValueKey<String>('payment-back'),
            icon: const Icon(Icons.close_rounded),
            tooltip: l10n.ds_button_close,
            onPressed: () => unawaited(_close(s)),
          ),
        ),
        body: Column(
          children: <Widget>[
            if (!online) OfflineBanner(variant: OfflineBannerVariant.offline, message: l10n.payment_offline),
            Expanded(
              child: compact
                  ? SingleChildScrollView(padding: EdgeInsets.all(context.space.s4), child: content)
                  : SingleChildScrollView(
                      padding: EdgeInsets.all(context.space.s6),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: wc == WindowClass.medium ? 560 : 640),
                          child: Container(
                            padding: EdgeInsets.all(context.space.s6),
                            decoration: BoxDecoration(
                              color: c.surface,
                              borderRadius: BorderRadius.all(context.radii.lg),
                              border: Border.all(color: c.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                content,
                                if (allowedRole) ...<Widget>[
                                  SizedBox(height: context.space.s6),
                                  _ctaRow(context, l10n, s, online),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
        bottomNavigationBar: bottom,
      ),
    );
  }

  Widget _content(BuildContext context, AppLocalizations l10n, PaymentScreenState s, bool online, bool compact) {
    switch (s.phase) {
      case PaymentPhase.noContext:
        return const SizedBox.shrink();
      case PaymentPhase.debtUnavailable:
        // RM-G-013 выключена (Q-152): режима «по долгу» в R1 нет (P-FLAGS).
        return EmptyState(
          key: const ValueKey<String>('payment-debt-unavailable'),
          variant: EmptyStateVariant.noPermission,
          title: l10n.error_forbidden,
          actionLabel: l10n.payment_done,
          onAction: () => context.cashierClose(),
        );
      case PaymentPhase.forbidden:
        return EmptyState(variant: EmptyStateVariant.noPermission, title: l10n.error_forbidden);
      case PaymentPhase.error:
        final UiError e = UiErrorMapper.fromFailureDetailed(s.loadFailure ?? const UnknownFailure());
        return ErrorState.fullScreen(
          title: l10n.payment_title,
          message: ErrorTexts.message(l10n, e),
          requestId: e.requestId,
          onRetry: () => unawaited(_ctl.reload(initial: true)),
        );
      case PaymentPhase.loading:
        return PaymentOrderContext(due: s.due);
      case PaymentPhase.alreadyPaid:
        final Order o = s.order!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            PaymentOrderContext(order: o, due: s.due),
            SizedBox(height: context.space.s4),
            PaymentInfoBlock(
              icon: Icons.check_circle_outline_rounded,
              message: l10n.payment_already_paid(
                CashierFormat.money(o.paidAmount ?? Money.zero),
                CashierFormat.money(o.totalToPay ?? o.total),
              ),
              actions: _finalActions(l10n),
            ),
          ],
        );
      case PaymentPhase.notPayable:
        final Order o = s.order!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            PaymentOrderContext(order: o, due: s.due),
            SizedBox(height: context.space.s4),
            PaymentInfoBlock(
              message: l10n.payment_not_payable(OrderStatusChip.labelOf(l10n, o.status)),
              actions: _finalActions(l10n),
            ),
          ],
        );
      case PaymentPhase.creditOrder:
        // UI-38-013: заказ в долг — только просмотр; «Оплата долга» (Q-152) в R1 нет (RM-G-013).
        final Order o = s.order!;
        final DateTime? due = o.paymentDueDate;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            PaymentOrderContext(order: o, due: s.due),
            SizedBox(height: context.space.s4),
            PaymentInfoBlock(
              key: const ValueKey<String>('payment-credit-order'),
              icon: Icons.receipt_long_outlined,
              message: l10n.payment_credit_order_info(due == null ? '—' : CashierFormat.plainDate(due)),
              actions: _finalActions(l10n),
            ),
          ],
        );
      case PaymentPhase.success:
        final Payment p = s.result!;
        return PaymentSuccessView(
          payment: p,
          actions: <Widget>[
            if (ref.read(cashierReceiptPrinterProvider) != null)
              AppButton(
                key: const ValueKey<String>('payment-print'),
                label: l10n.transaction_details_action_print,
                icon: Icons.print_outlined,
                variant: AppButtonVariant.outlined,
                loading: s.print == ReceiptPrintState.printing,
                onPressed: s.print == ReceiptPrintState.printing ? null : () => unawaited(_ctl.printReceipt()),
              ),
            AppButton(
              key: const ValueKey<String>('payment-open-order'),
              label: l10n.transaction_details_action_open_order,
              variant: AppButtonVariant.text,
              onPressed: _openOrder,
            ),
            AppButton(
              key: const ValueKey<String>('payment-done'),
              label: l10n.payment_done,
              onPressed: () => context.cashierClose(),
            ),
          ],
        );
      case PaymentPhase.ready:
        return _ready(context, l10n, s, online);
    }
  }

  List<Widget> _finalActions(AppLocalizations l10n) => <Widget>[
    AppButton(
      key: const ValueKey<String>('payment-open-order'),
      label: l10n.transaction_details_action_open_order,
      variant: AppButtonVariant.outlined,
      onPressed: _openOrder,
    ),
    AppButton(
      key: const ValueKey<String>('payment-done'),
      label: l10n.payment_done,
      onPressed: () => context.cashierClose(),
    ),
  ];

  Widget _ready(BuildContext context, AppLocalizations l10n, PaymentScreenState s, bool online) {
    final Order o = s.order!;
    final DsColors c = context.colors;
    final bool qr = s.method == PaymentMethod.qrBakai;
    final bool cash = s.method == PaymentMethod.cash;
    final Payment? qrp = s.qrPayment;
    final RoleCode? role = ref.watch(cashierViewerRoleProvider);
    final bool canManual = CashierRoles.canConfirmManual(role);
    final DateTime now = _now();
    final QrPanelView view = PaymentQrSection.viewOf(
      qrp,
      creating: s.qrCreating,
      unavailable: s.qrUnavailable,
      now: now,
    );
    final bool lockedByUnknown = s.unknown;
    final List<Widget> qrActions = <Widget>[
      if (view == QrPanelView.expired || (view == QrPanelView.unavailable && qrp != null))
        AppButton(
          key: const ValueKey<String>('payment-qr-reissue'),
          label: l10n.payment_qr_reissue,
          variant: AppButtonVariant.outlined,
          loading: s.qrCreating,
          onPressed: online && !s.busy ? () => unawaited(_ctl.createQr(reissue: true)) : null,
        ),
      if (view == QrPanelView.unavailable)
        AppButton(
          key: const ValueKey<String>('payment-qr-manual-only'),
          label: l10n.ds_qr_retry_without_bank,
          variant: AppButtonVariant.outlined,
          loading: s.qrCreating,
          onPressed: online && !s.busy ? () => unawaited(_ctl.createQr(manualOnly: true)) : null,
        ),
      if (canManual &&
          qrp != null &&
          (view == QrPanelView.shown || view == QrPanelView.review) &&
          (qrp.qr?.autoConfirm != true ||
              view == QrPanelView.review ||
              s.qrActions.contains(PaymentAction.confirmManual)))
        AppButton(
          key: const ValueKey<String>('payment-confirm-manual'),
          label: l10n.transaction_details_action_confirm_manual,
          variant: AppButtonVariant.tonal,
          loading: s.confirming,
          onPressed: online && !s.busy && !lockedByUnknown ? () => unawaited(_confirmManual(s)) : null,
        ),
      if (canManual && qrp != null && (view == QrPanelView.review || s.openQrExists || view == QrPanelView.expired))
        AppButton(
          key: const ValueKey<String>('payment-void'),
          label: l10n.transaction_details_action_void,
          variant: AppButtonVariant.text,
          loading: s.voiding,
          onPressed: online && !s.busy && !lockedByUnknown ? () => unawaited(_void(s)) : null,
        ),
      if (view == QrPanelView.shown)
        AppButton(
          key: const ValueKey<String>('payment-qr-show-customer'),
          label: l10n.payment_qr_show_customer,
          icon: Icons.fullscreen_rounded,
          variant: AppButtonVariant.text,
          size: AppButtonSize.s,
          onPressed: () => unawaited(_showToCustomer(s)),
        ),
      if (s.qrFailure != null)
        AppButton(
          key: const ValueKey<String>('payment-qr-retry'),
          label: l10n.ds_button_retry,
          variant: AppButtonVariant.outlined,
          onPressed: online && !s.busy ? () => unawaited(_ctl.createQr()) : null,
        ),
      if (s.qrFailure != null || view == QrPanelView.unavailable)
        AppButton(
          key: const ValueKey<String>('payment-other-method'),
          label: l10n.payment_other_method,
          variant: AppButtonVariant.text,
          onPressed: _ctl.clearMethod,
        ),
    ];
    final Money? received = _receivedMoney;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PaymentOrderContext(order: o, due: s.due),
        if (s.unknown) ...<Widget>[
          SizedBox(height: context.space.s4),
          _UnknownBanner(
            pending: s.idempotencyPending,
            checking: s.submitting || s.confirming || s.voiding,
            online: online,
            onCheck: () => unawaited(_ctl.check()),
            onDiscard: () => unawaited(_discardUnknown()),
          ),
        ],
        if (s.creditBlock != null) ...<Widget>[
          SizedBox(height: context.space.s4),
          PaymentCreditBlock(
            error: s.creditBlock!,
            refreshing: s.refreshingDebt,
            online: online,
            dataAsOf: s.debtSnapshot?.asOf == null ? null : CashierFormat.stamp(s.debtSnapshot!.asOf!, now),
            onRefreshDebt: () => unawaited(_ctl.refreshDebt()),
            onSeniorHelp: () => unawaited(showSeniorApprovalHelp(context)),
            onOtherMethod: _ctl.clearMethod,
          ),
        ],
        if (s.debtSnapshot != null && s.creditBlock == null) ...<Widget>[
          SizedBox(height: context.space.s2),
          Text(
            l10n.ds_data_as_of(CashierFormat.stamp(s.debtSnapshot!.asOf ?? now, now)),
            key: const ValueKey<String>('payment-debt-refreshed'),
            style: context.text.caption.copyWith(color: c.textSecondary),
          ),
        ],
        SizedBox(height: context.space.s4),
        AppSectionHeader(title: l10n.payment_method_title, padding: EdgeInsets.zero),
        SizedBox(height: context.space.s2),
        LayoutBuilder(
          builder: (BuildContext ctx, BoxConstraints box) {
            final List<Widget> tiles = <Widget>[
              PaymentMethodCard(
                key: const ValueKey<String>('payment-tile-cash'),
                method: PaymentMethod.cash,
                title: l10n.payment_method_cash,
                subtitle: l10n.payment_method_cash_sub,
                selected: cash,
                onTap: online && !s.busy && !lockedByUnknown
                    ? () => unawaited(_selectMethod(s, PaymentMethod.cash))
                    : null,
                disabledReason: online ? null : l10n.payment_offline,
              ),
              PaymentMethodCard(
                key: const ValueKey<String>('payment-tile-qr'),
                method: PaymentMethod.qrBakai,
                title: l10n.payment_method_qr,
                subtitle: l10n.payment_method_qr_sub,
                selected: qr,
                loading: s.qrCreating && qrp == null,
                loadingLabel: l10n.payment_qr_creating,
                onTap: online && !s.busy && !lockedByUnknown
                    ? () => unawaited(_selectMethod(s, PaymentMethod.qrBakai))
                    : null,
                disabledReason: online ? null : l10n.payment_offline,
              ),
            ];
            if (box.maxWidth < 440) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  tiles[0],
                  SizedBox(height: context.space.s2),
                  tiles[1],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: tiles[0]),
                SizedBox(width: context.space.s3),
                Expanded(child: tiles[1]),
              ],
            );
          },
        ),
        if (s.openQrExists) ...<Widget>[
          SizedBox(height: context.space.s3),
          ErrorState.banner(
            key: const ValueKey<String>('payment-open-qr-exists'),
            message: l10n.payment_open_qr_exists,
            tone: ErrorStateTone.warning,
            onClose: _ctl.dismissMessages,
          ),
        ],
        if (s.manualMismatch) ...<Widget>[
          SizedBox(height: context.space.s3),
          ErrorState.banner(
            key: const ValueKey<String>('payment-manual-mismatch-banner'),
            message: l10n.payment_manual_mismatch,
            tone: ErrorStateTone.warning,
            onClose: _ctl.dismissMessages,
          ),
        ],
        if (s.stateChanged) ...<Widget>[
          SizedBox(height: context.space.s3),
          ErrorState.banner(
            key: const ValueKey<String>('payment-state-changed'),
            message: l10n.transaction_details_state_changed,
            tone: ErrorStateTone.info,
            onClose: _ctl.dismissMessages,
          ),
        ],
        if (cash) ...<Widget>[
          SizedBox(height: context.space.s4),
          PaymentCashForm(
            controller: _received,
            focusNode: _receivedFocus,
            due: s.due,
            received: received,
            serverLess: s.receivedLess,
            enabled: online && !s.submitting && !s.unknown,
            onChanged: (_) => setState(() {}),
            onQuick: (Money m) => setState(() => _received.text = PriceTextAmount.input(m)),
            onSubmit: () => unawaited(_accept(s)),
          ),
        ],
        if (qr) ...<Widget>[
          SizedBox(height: context.space.s4),
          PaymentQrSection(
            payment: qrp,
            orderNumber: o.publicNumber,
            due: s.due,
            nowUtc: _now,
            creating: s.qrCreating,
            unavailable: s.qrUnavailable,
            bankDown: s.qrBankDown,
            createFailed: s.qrFailure != null,
            actions: qrActions,
            // TTL истёк по часам приложения — перестроить действия («Обновить QR», AC-UI-38-007).
            onExpired: () {
              if (mounted) setState(() {});
            },
          ),
        ],
        if (s.failure != null) ...<Widget>[
          SizedBox(height: context.space.s3),
          ErrorState.inline(
            key: const ValueKey<String>('payment-failure'),
            message: ErrorTexts.message(l10n, UiErrorMapper.fromFailureDetailed(s.failure!)),
          ),
        ],
        if (cash) ...<Widget>[
          SizedBox(height: context.space.s4),
          AppCheckbox(
            key: const ValueKey<String>('payment-print-receipt'),
            value: _printReceipt && ref.watch(cashierReceiptPrinterProvider) != null,
            label: l10n.payment_print_receipt,
            onChanged: ref.watch(cashierReceiptPrinterProvider) == null
                ? null
                : (bool? v) => setState(() => _printReceipt = v ?? false),
          ),
        ],
      ],
    );
  }

  bool _ctaEnabled(PaymentScreenState s, bool online) {
    if (s.phase != PaymentPhase.ready || !online || s.busy || s.unknown) return false;
    if (s.method != PaymentMethod.cash) return false;
    final Money? r = _receivedMoney;
    return r != null && r >= s.due && !s.due.isZero;
  }

  Widget _cta(BuildContext context, AppLocalizations l10n, PaymentScreenState s, bool online) {
    if (s.unknown) {
      return AppButton(
        key: const ValueKey<String>('payment-check'),
        label: l10n.payment_check,
        size: AppButtonSize.l,
        expand: true,
        loading: s.busy,
        onPressed: online && !s.busy ? () => unawaited(_ctl.check()) : null,
      );
    }
    return AppButton(
      key: const ValueKey<String>('payment-cta'),
      label: l10n.payment_cta_accept(CashierFormat.money(s.due)),
      variant: AppButtonVariant.success,
      size: AppButtonSize.l,
      expand: true,
      loading: s.submitting,
      onPressed: _ctaEnabled(s, online) ? () => unawaited(_accept(s)) : null,
    );
  }

  Widget? _bottomBar(BuildContext context, AppLocalizations l10n, PaymentScreenState s, bool online) {
    if (s.phase != PaymentPhase.ready || (s.method != PaymentMethod.cash && !s.unknown)) return null;
    return SafeArea(
      child: Container(
        padding: EdgeInsets.all(context.space.s4),
        decoration: BoxDecoration(
          color: context.colors.surface,
          border: Border(top: BorderSide(color: context.colors.border)),
        ),
        child: _cta(context, l10n, s, online),
      ),
    );
  }

  Widget _ctaRow(BuildContext context, AppLocalizations l10n, PaymentScreenState s, bool online) {
    if (s.phase != PaymentPhase.ready || (s.method != PaymentMethod.cash && !s.unknown)) {
      return const SizedBox.shrink();
    }
    return Row(
      children: <Widget>[
        AppButton(
          label: l10n.ds_button_cancel,
          variant: AppButtonVariant.text,
          onPressed: s.busy ? null : () => unawaited(_close(s)),
        ),
        const Spacer(),
        Flexible(flex: 3, child: _cta(context, l10n, s, online)),
      ],
    );
  }
}

/// Сумма для поля ввода «16 100,00».
abstract final class PriceTextAmount {
  /// Строка ввода из [m].
  static String input(Money m) => m.toApiString().replaceAll('.', ',');
}

/// «Связь прервалась. Проверьте результат — деньги не принимайте повторно» · «Проверить» · «Отменить операцию»
/// (UI-38-018; `ds_idempotency_pending` — после 3 повторов `IDEMPOTENCY_IN_PROGRESS`).
class _UnknownBanner extends StatelessWidget {
  const _UnknownBanner({
    required this.pending,
    required this.checking,
    required this.online,
    required this.onCheck,
    required this.onDiscard,
  });

  final bool pending;
  final bool checking;
  final bool online;
  final VoidCallback onCheck;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    return Container(
      key: const ValueKey<String>('payment-unknown'),
      padding: EdgeInsets.all(context.space.s4),
      decoration: BoxDecoration(color: c.warningContainer, borderRadius: BorderRadius.all(context.radii.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.warning_amber_rounded, size: 20, color: c.warning),
              SizedBox(width: context.space.s2),
              Expanded(
                child: Text(
                  pending ? l10n.ds_idempotency_pending : l10n.payment_unknown,
                  style: context.text.body.copyWith(color: c.textPrimary),
                ),
              ),
            ],
          ),
          SizedBox(height: context.space.s2),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: context.space.s2,
            children: <Widget>[
              AppButton(
                key: const ValueKey<String>('payment-unknown-discard'),
                label: l10n.payment_unknown_discard,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                onPressed: checking ? null : onDiscard,
              ),
              AppButton(
                key: const ValueKey<String>('payment-unknown-check'),
                label: l10n.payment_check,
                variant: AppButtonVariant.outlined,
                size: AppButtonSize.s,
                loading: checking,
                onPressed: online && !checking ? onCheck : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
