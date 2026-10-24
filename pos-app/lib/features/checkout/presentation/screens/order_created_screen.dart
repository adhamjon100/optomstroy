// SCR-22 «Заказ создан / QR для оплаты» (`/orders/{id}/created?paymentId=`; маршрут — ветка «Заказы», экран — фича
// checkout: продолжение оформления, `QrPanel`, long-polling `GET /payments/{id}?wait=25`). RM-F-006, RM-F-013;
// 02 SCR-22; 03 §9.58.
//
// Зоны: A шапка; B результат (№ POS, № 1С / «Ожидает отправки в 1С», статус); C оплата по способу и роли (QR / «Передайте
// клиента в кассу» / «Принять оплату» / долг); D сводка; E документы; F действия.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/qr_panel.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/checkout/presentation/checkout_formats.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/order_created_controller.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// SCR-22.
class OrderCreatedScreen extends ConsumerStatefulWidget {
  /// Экран SCR-22.
  const OrderCreatedScreen({required this.orderId, this.paymentId, super.key});

  /// ID заказа (required).
  final String orderId;

  /// Платёж для ожидания оплаты (QR).
  final String? paymentId;

  /// Ключ заглушки (тесты маршрутов): `stub-SCR-22`.
  static const ValueKey<String> stubKey = ValueKey<String>('stub-SCR-22');

  /// Задержка перехода в SCR-24 после `received` (03 §9.58).
  static const Duration paidRedirect = Duration(seconds: 2);

  @override
  ConsumerState<OrderCreatedScreen> createState() => _OrderCreatedScreenState();
}

class _OrderCreatedScreenState extends ConsumerState<OrderCreatedScreen> with WidgetsBindingObserver {
  Timer? _ticker;
  Timer? _paidTimer;

  /// Экран виден: ветка навигации активна и не перекрыт непрозрачным маршрутом (`TickerMode`; диалоги поверх —
  /// «Показать клиенту», ручное подтверждение — ожидание не останавливают).
  bool _onScreen = true;

  /// Приложение на переднем плане (свёрнуто / скрыто — ожидание приостановлено).
  bool _foreground = true;

  OrderCreatedArgs get _args => (orderId: widget.orderId, paymentId: widget.paymentId);

  OrderCreatedController get _ctl => ref.read(orderCreatedControllerProvider(_args).notifier);

  RoleCode? get _role => ref.read(checkoutViewerRoleProvider);

  /// Роль видит QR (`payment.qr.show`): не `admin`; `customer` — только при `QR_PROVIDER=onec` (11 §4.4 №17).
  bool _seesQr(RoleCode? role, CheckoutQrMode qr) => switch (role) {
    RoleCode.admin || RoleCode.owner => false,
    RoleCode.customer => qr.provider == QrProviderMode.onec,
    _ => true,
  };

  bool _isCashier(RoleCode? role) => role == RoleCode.cashier || role == RoleCode.seniorSeller;

  /// AC-UI-22-011: long-polling оплаты идёт, только пока экран виден, приложение активно, сессия не заблокирована
  /// (idle-блокировка SCR-08) и есть сеть; иначе ожидающий запрос отменяется. Одновременно — не более одного запроса
  /// (`OrderCreatedController` держит одну подписку).
  bool get _watchAllowed =>
      _onScreen &&
      _foreground &&
      !ref.read(checkoutSessionLockedProvider) &&
      ref.read(checkoutOnlineProvider) &&
      _seesQr(_role, ref.read(checkoutQrModeProvider));

  void _syncWatch() {
    if (!mounted) return;
    if (_watchAllowed) {
      _ctl.resumeWatch();
    } else {
      unawaited(_ctl.pauseWatch());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool onScreen = TickerMode.of(context);
    if (onScreen != _onScreen) {
      _onScreen = onScreen;
      _syncWatch();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool foreground = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached => false,
    };
    if (foreground != _foreground) {
      _foreground = foreground;
      _syncWatch();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(orderCreatedControllerProvider(_args)).payment?.qr?.expiresAt != null) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Без сети ожидание оплаты не запускается (02 SCR-22.7) — начнётся при восстановлении сети.
      // После загрузки — сверка с текущими условиями (экран мог уйти в фон, пока шёл запрос заказа).
      unawaited(_ctl.open(watchPayment: _watchAllowed).then((_) => _syncWatch()));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _paidTimer?.cancel();
    super.dispose();
  }

  void _newOrder() => ref.read(checkoutNavigatorProvider).home(context);

  /// «Открыть восстановленную корзину» (UI-22-014, ORD-027): сервер восстановил состав заказа `submit_failed` в
  /// новую корзину — активную (SCR-20), если текущая была пуста, иначе отложенную (SCR-23).
  Future<void> _openRestoredCart() async {
    final Result<Cart> r = await ref.read(cartRepositoryProvider).fetch();
    if (!mounted) return;
    final Cart? active = r.valueOrNull;
    final CheckoutNavigator nav = ref.read(checkoutNavigatorProvider);
    if (active == null || active.restoredFromOrderId == widget.orderId) {
      nav.backToCart(context);
    } else {
      nav.parked(context);
    }
  }

  void _openOrder() => ref.read(checkoutNavigatorProvider).order(context, widget.orderId);

  void _acceptPayment({PaymentMethod? method}) =>
      ref.read(checkoutNavigatorProvider).acceptPayment(context, widget.orderId, method: method);

  Future<void> _confirmManual(Payment payment) async {
    final ConfirmManualRequest? request = await showDialog<ConfirmManualRequest>(
      context: context,
      builder: (BuildContext ctx) =>
          _ManualConfirmDialog(amount: payment.amount, now: ref.read(clockProvider).nowUtc()),
    );
    if (request == null || !mounted) return;
    await _ctl.confirmManual(request);
  }

  Future<void> _showToCustomer(Widget panel) => showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => Dialog.fullscreen(
      backgroundColor: ctx.colors.surface,
      child: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Center(child: SingleChildScrollView(child: panel)),
            ),
            Padding(
              padding: EdgeInsets.all(context.space.s4),
              child: AppButton(
                label: AppLocalizations.of(ctx).ds_button_ok,
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

  @override
  Widget build(BuildContext context) {
    final OrderCreatedState s = ref.watch(orderCreatedControllerProvider(_args));
    final RoleCode? role = ref.watch(checkoutViewerRoleProvider);
    final CheckoutQrMode qr = ref.watch(checkoutQrModeProvider);
    final bool online = ref.watch(checkoutOnlineProvider);
    // Нет сети (02 SCR-22.7): long-polling приостановлен; после восстановления — заказ и ожидание оплаты заново.
    ref.listen<bool>(checkoutOnlineProvider, (bool? prev, bool next) {
      if (next && prev == false) unawaited(_ctl.refresh());
      _syncWatch();
    });
    // Idle-блокировка (SCR-08): ожидание оплаты приостанавливается и возобновляется после разблокировки (AC-UI-22-011).
    ref.listen<bool>(checkoutSessionLockedProvider, (bool? prev, bool next) => _syncWatch());
    ref.listen<PaymentStatus?>(
      orderCreatedControllerProvider(_args).select((OrderCreatedState x) => x.payment?.status),
      (PaymentStatus? prev, PaymentStatus? next) {
        if (next == PaymentStatus.received && prev != PaymentStatus.received && prev != null) {
          _paidTimer?.cancel();
          _paidTimer = Timer(OrderCreatedScreen.paidRedirect, () {
            if (mounted) _openOrder();
          });
        }
      },
    );
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final WindowClass wc = context.windowClass;
    final Order? order = s.order;
    final Widget body;
    if (order == null) {
      body = s.loadFailure != null
          ? ErrorState.fullScreen(
              title: l10n.order_created_title,
              message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(s.loadFailure!)),
              onRetry: () => unawaited(_ctl.refresh()),
            )
          : Padding(
              padding: EdgeInsets.all(context.space.s9),
              child: const Center(child: AppProgress.circular(size: 32)),
            );
    } else {
      final Widget result = _result(context, l10n, s, order);
      final Widget pay = _payBlock(context, l10n, s, order, role, qr, online, wc);
      final Widget summary = _summary(context, l10n, order);
      final Widget docs = role == RoleCode.customer ? const SizedBox.shrink() : _documents(context, l10n, s, order);
      const Widget gap = SizedBox(height: 16);
      if (wc == WindowClass.expanded || wc == WindowClass.large) {
        body = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              flex: 5,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[result, gap, pay]),
            ),
            const SizedBox(width: 24),
            Expanded(
              flex: 4,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[summary, gap, docs]),
            ),
          ],
        );
      } else {
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[result, gap, pay, gap, summary, gap, docs],
        );
      }
    }
    final Widget footer = _footer(context, l10n, s, role);
    final Widget header = Padding(
      padding: EdgeInsets.fromLTRB(context.space.s6, context.space.s3, context.space.s3, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: Text(l10n.order_created_title, style: context.text.h3.copyWith(color: c.textPrimary)),
            ),
          ),
          AppIconButton(
            key: const ValueKey<String>('order-created-close'),
            icon: Icons.close_rounded,
            semanticLabel: l10n.ds_button_close,
            onPressed: _newOrder,
          ),
        ],
      ),
    );
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header,
        if (!online)
          Padding(
            padding: EdgeInsets.fromLTRB(context.space.s6, context.space.s3, context.space.s6, 0),
            child: const OfflineBanner(variant: OfflineBannerVariant.offline),
          ),
        Expanded(
          child: SingleChildScrollView(padding: EdgeInsets.all(context.space.s6), child: body),
        ),
        footer,
      ],
    );
    final Widget screen;
    if (wc == WindowClass.compact) {
      screen = Scaffold(
        key: const ValueKey<String>('order-created-screen'),
        backgroundColor: c.surface,
        body: SafeArea(child: content),
      );
    } else {
      final Size size = MediaQuery.sizeOf(context);
      final double width = wc == WindowClass.medium ? 560 : 820; // money-double: allow — геометрия UI, не деньги
      screen = Scaffold(
        key: const ValueKey<String>('order-created-screen'),
        backgroundColor: c.background,
        body: ColoredBox(
          color: c.overlay,
          child: Center(
            child: Container(
              width: width.clamp(0, size.width - 32),
              height: (size.height * 0.9).clamp(0, 760),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.all(context.radii.lg),
                boxShadow: context.elevation.e3,
              ),
              clipBehavior: Clip.antiAlias,
              child: content,
            ),
          ),
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _newOrder();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _newOrder,
          if (order?.onec?.number != null)
            const SingleActivator(LogicalKeyboardKey.keyP, control: true): () =>
                unawaited(_ctl.printDocument(OrderDocumentKind.invoice)),
        },
        child: Focus(autofocus: true, child: screen),
      ),
    );
  }

  // ---- B: результат ----

  Widget _result(BuildContext context, AppLocalizations l10n, OrderCreatedState s, Order order) {
    final DsColors c = context.colors;
    final bool failed = order.status == OrderStatus.submitFailed;
    final String? onecNumber = order.onec?.number;
    final List<Widget> banners = <Widget>[
      if (order.status == OrderStatus.submitting)
        ErrorState.banner(
          key: const ValueKey<String>('order-created-onec-pending'),
          message: l10n.order_created_banner_submitting,
          tone: ErrorStateTone.info,
        ),
      if (failed) ...<Widget>[
        ErrorState.banner(
          key: const ValueKey<String>('order-created-rejected'),
          message: l10n.order_banner_rejected(order.submitError?.message ?? ''),
        ),
        Padding(
          padding: EdgeInsets.symmetric(vertical: context.space.s2),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              key: const ValueKey<String>('order-created-open-restored-cart'),
              label: l10n.checkout_open_restored_cart,
              variant: AppButtonVariant.tonal,
              size: AppButtonSize.s,
              onPressed: ref.watch(checkoutOnlineProvider) ? () => unawaited(_openRestoredCart()) : null,
            ),
          ),
        ),
      ],
      if (order.onec?.status == 'dead') ErrorState.banner(message: l10n.order_created_banner_dead),
    ];
    return Column(
      key: const ValueKey<String>('order-created-result'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(shape: BoxShape.circle, color: failed ? c.error : c.success),
              child: Icon(
                failed ? Icons.error_outline_rounded : Icons.check_rounded,
                color: failed ? c.onError : c.onSuccess,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    l10n.order_created_number(order.publicNumber),
                    key: const ValueKey<String>('order-created-number'),
                    style: context.text.h2.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
                  ),
                  Text(
                    onecNumber == null
                        ? l10n.order_created_onec_pending
                        : l10n.order_onec_number(
                            order.onec?.date == null ? '' : CheckoutFormats.date(order.onec!.date!),
                            onecNumber,
                          ),
                    style: context.text.body.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
                  ),
                  const SizedBox(height: 4),
                  StatusChip(
                    label: orderStatusLabel(l10n, order.status),
                    variant: StatusChipMapping.variantOf('order', order.status.value) ?? StatusChipVariant.neutral,
                  ),
                ],
              ),
            ),
          ],
        ),
        for (final Widget b in banners)
          Padding(
            padding: EdgeInsets.only(top: context.space.s3),
            child: b,
          ),
      ],
    );
  }

  /// Подпись статуса заказа (`status_order_*`).
  static String orderStatusLabel(AppLocalizations l10n, OrderStatus s) => switch (s) {
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

  // ---- C: оплата ----

  Widget _payBlock(
    BuildContext context,
    AppLocalizations l10n,
    OrderCreatedState s,
    Order order,
    RoleCode? role,
    CheckoutQrMode qr,
    bool online,
    WindowClass wc,
  ) {
    final DsColors c = context.colors;
    final Money due = order.totalToPay ?? order.total;
    Widget info(String text, {IconData icon = Icons.point_of_sale_rounded, Key? key}) => Container(
      key: key,
      padding: EdgeInsets.all(context.space.s4),
      decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.md)),
      child: Row(
        children: <Widget>[
          Icon(icon, color: c.primaryText),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: context.text.bodyLg.copyWith(color: c.textPrimary)),
          ),
        ],
      ),
    );
    switch (order.paymentMethod) {
      case PaymentMethod.credit:
        return info(
          order.paymentDueDate == null
              ? l10n.order_created_credit_due_agreement
              : l10n.order_created_credit_due(CheckoutFormats.date(order.paymentDueDate!)),
          icon: Icons.receipt_long_outlined,
          key: const ValueKey<String>('order-created-credit'),
        );
      case PaymentMethod.cash:
        if (role == RoleCode.customer) {
          return info(
            l10n.order_created_customer_pay_on_pickup(order.publicNumber),
            key: const ValueKey<String>('order-created-customer-cash'),
          );
        }
        if (role == RoleCode.admin) {
          return info(
            l10n.order_created_admin_handoff(order.publicNumber),
            key: const ValueKey<String>('order-created-admin'),
          );
        }
        if (_isCashier(role)) {
          return order.isPaid
              ? info(l10n.order_created_paid, icon: Icons.check_circle_outline_rounded)
              : const SizedBox.shrink();
        }
        return info(
          l10n.order_created_cash_handoff(order.publicNumber, CheckoutFormats.money(due)),
          key: const ValueKey<String>('order-created-cash-handoff'),
        );
      case PaymentMethod.qrBakai:
        if (!_seesQr(role, qr)) {
          if (role == RoleCode.customer) {
            return info(
              l10n.order_created_customer_pay_hint,
              key: const ValueKey<String>('order-created-customer-pay-hint'),
            );
          }
          return info(
            l10n.order_created_admin_handoff(order.publicNumber),
            key: const ValueKey<String>('order-created-admin'),
          );
        }
        return _qrPanel(context, l10n, s, order, role, qr, online, wc);
    }
  }

  Widget _qrPanel(
    BuildContext context,
    AppLocalizations l10n,
    OrderCreatedState s,
    Order order,
    RoleCode? role,
    CheckoutQrMode qr,
    bool online,
    WindowClass wc, {
    QrPanelVariant variant = QrPanelVariant.inline,
  }) {
    final Payment? p = s.payment;
    final QrInfo? info = p?.qr;
    final bool customer = role == RoleCode.customer;
    final bool cashier = _isCashier(role);
    final Money amount = info?.amount ?? p?.amount ?? order.totalToPay ?? order.total;
    final DateTime now = ref.read(clockProvider).nowUtc();
    QrPanelView view;
    String? message;
    String? statusLabel;
    StatusChipVariant statusVariant = StatusChipVariant.info;
    bool busy = false;
    final PaymentStatus? status = p?.status;
    final bool unavailable = s.qrUnavailable && info == null;
    switch (status) {
      case null:
      case PaymentStatus.initiated:
      case PaymentStatus.qrPending:
      case PaymentStatus.cashPending:
      case PaymentStatus.credit:
        if (unavailable) {
          view = QrPanelView.unavailable;
          message = customer
              ? l10n.order_created_customer_pay_hint
              : (qr.provider == QrProviderMode.onec
                    ? l10n.order_created_qr_unavailable_onec
                    : l10n.order_created_qr_unavailable);
        } else {
          view = QrPanelView.loading;
        }
      case PaymentStatus.qrShown:
        final bool expired = info?.expiresAt != null && !info!.expiresAt!.isAfter(now);
        view = expired ? QrPanelView.expired : QrPanelView.shown;
        statusLabel = expired ? l10n.order_created_qr_expired : l10n.order_created_waiting_payment;
        statusVariant = expired ? StatusChipVariant.warning : StatusChipVariant.info;
        busy = !expired;
        if (info?.payload == null && info?.imageUrl == null) message = l10n.order_created_qr_none;
      case PaymentStatus.qrExpired:
        view = QrPanelView.expired;
        statusLabel = l10n.order_created_qr_expired;
        statusVariant = StatusChipVariant.warning;
      case PaymentStatus.manualConfirm:
        view = QrPanelView.review;
        statusVariant = StatusChipVariant.warning;
        statusLabel = switch (p!.reviewReason) {
          ReviewReason.amountMismatch => l10n.order_created_review_amount,
          ReviewReason.unknownReference => l10n.order_created_review_reference,
          ReviewReason.latePayment => l10n.order_created_review_late,
          ReviewReason.noWebhook || null => l10n.payment_review_no_webhook,
        };
      case PaymentStatus.received:
      case PaymentStatus.refunded:
        view = QrPanelView.received;
      case PaymentStatus.voided:
        view = QrPanelView.voided;
        statusLabel = l10n.status_payment_voided;
        statusVariant = StatusChipVariant.error;
    }
    final String? timer = info?.expiresAt == null || view != QrPanelView.shown
        ? (info?.expiresAt == null && view == QrPanelView.shown ? l10n.order_created_qr_static : null)
        : l10n.order_created_qr_valid_until(
            CheckoutFormats.countdown(info!.expiresAt!.difference(now)),
            CheckoutFormats.time(info.expiresAt!),
          );
    final bool timerWarning =
        info?.expiresAt != null && info!.expiresAt!.difference(now) <= const Duration(seconds: 60);
    final bool canConfirm =
        cashier &&
        (status == PaymentStatus.qrShown || status == PaymentStatus.manualConfirm) &&
        view != QrPanelView.expired &&
        (s.paymentActions.contains(PaymentAction.confirmManual) || info?.autoConfirm == false);
    final bool canReissue =
        (view == QrPanelView.expired || view == QrPanelView.unavailable) &&
        (!customer || qr.provider == QrProviderMode.onec);
    final List<Widget> actions = <Widget>[
      if (canReissue)
        AppButton(
          key: const ValueKey<String>('order-created-reissue'),
          label: l10n.order_created_qr_reissue,
          variant: AppButtonVariant.outlined,
          loading: s.reissuing,
          onPressed: online && !s.reissuing ? () => unawaited(_ctl.reissueQr()) : null,
        ),
      if (canConfirm)
        AppButton(
          key: const ValueKey<String>('order-created-confirm-manual'),
          label: l10n.order_created_manual_confirm,
          variant: AppButtonVariant.tonal,
          loading: s.confirming,
          onPressed: online && !s.confirming ? () => unawaited(_confirmManual(p!)) : null,
        ),
      // «Проверить» статус платежа (RM-F-013 п. 4): после перезапуска приложения ожидание продолжается только чтением
      // статуса; повторного приёма денег без действия кассира нет.
      if (cashier &&
          variant == QrPanelVariant.inline &&
          (view == QrPanelView.shown || view == QrPanelView.expired || view == QrPanelView.review))
        AppButton(
          key: const ValueKey<String>('order-created-check-payment'),
          label: l10n.payment_check,
          variant: AppButtonVariant.text,
          size: AppButtonSize.s,
          loading: s.checkingPayment,
          onPressed: online && !s.checkingPayment ? () => unawaited(_ctl.checkPayment()) : null,
        ),
      if (view == QrPanelView.shown && variant == QrPanelVariant.inline)
        AppButton(
          key: const ValueKey<String>('order-created-show-customer'),
          label: l10n.order_created_qr_show_customer,
          icon: Icons.fullscreen_rounded,
          variant: AppButtonVariant.text,
          size: AppButtonSize.s,
          onPressed: () => unawaited(
            _showToCustomer(
              _qrPanel(context, l10n, s, order, role, qr, online, wc, variant: QrPanelVariant.fullscreen),
            ),
          ),
        ),
      if (cashier && view != QrPanelView.received && variant == QrPanelVariant.inline)
        AppButton(
          key: const ValueKey<String>('order-created-other-method'),
          label: l10n.order_created_other_method,
          variant: AppButtonVariant.text,
          onPressed: _acceptPayment,
        ),
    ];
    final Widget panel = QrPanel(
      key: ValueKey<String>('order-created-qr-${view.name}'),
      variant: variant,
      view: view,
      title: l10n.order_created_qr_title,
      amountText: CheckoutFormats.money(amount),
      purpose: l10n.order_created_qr_purpose(order.publicNumber),
      payload: info?.payload,
      imageUrl: info?.imageUrl,
      timerText: timer,
      timerWarning: timerWarning,
      statusLabel: statusLabel,
      statusVariant: statusVariant,
      statusBusy: busy,
      message: message,
      loadingText: l10n.order_created_qr_forming,
      receivedText: l10n.order_created_paid,
      receivedNote: p?.confirmationKind == PaymentConfirmationKind.webhook
          ? l10n.order_created_paid_auto
          : (p?.confirmationKind == PaymentConfirmationKind.manual ? l10n.order_created_paid_manual : null),
      qrSemanticLabel: '${l10n.order_created_qr_title}. ${CheckoutFormats.money(amount)}. ${order.publicNumber}',
      actions: actions,
    );
    if (variant == QrPanelVariant.fullscreen) return panel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Center(child: panel),
        if (customer && view != QrPanelView.unavailable && view != QrPanelView.received)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: Text(
              l10n.order_created_customer_qr_hint,
              textAlign: TextAlign.center,
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
            ),
          ),
        if (role == RoleCode.seller && view != QrPanelView.received)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: Text(
              view == QrPanelView.unavailable
                  ? l10n.order_created_cash_handoff(order.publicNumber, CheckoutFormats.money(amount))
                  : l10n.order_created_other_method_seller,
              key: const ValueKey<String>('order-created-seller-hint'),
              textAlign: TextAlign.center,
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
            ),
          ),
        if (s.paymentStateChanged)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: ErrorState.banner(
              key: const ValueKey<String>('order-created-payment-changed'),
              message: l10n.order_created_payment_state_changed,
              tone: ErrorStateTone.info,
              onClose: _ctl.dismissPaymentMessage,
            ),
          ),
        if (s.paymentFailure != null)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: ErrorState.banner(
              key: const ValueKey<String>('order-created-payment-error'),
              message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(s.paymentFailure!)),
              onClose: _ctl.dismissPaymentMessage,
            ),
          ),
      ],
    );
  }

  // ---- D: сводка ----

  Widget _summary(BuildContext context, AppLocalizations l10n, Order order) {
    final DsColors c = context.colors;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: context.text.caption.copyWith(color: c.textSecondary)),
          Text(
            value,
            style: context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
          ),
        ],
      ),
    );
    final Delivery? d = order.delivery;
    final String delivery = d == null || d.method == DeliveryMethod.pickup
        ? l10n.checkout_pickup_title
        : <String>[
            l10n.checkout_delivery_title,
            ?d.address,
            if (d.timeFrom != null && d.timeTo != null) l10n.checkout_slot_value(d.timeFrom!, d.timeTo!),
          ].join(' · ');
    final String method = switch (order.paymentMethod) {
      PaymentMethod.cash => l10n.payment_method_cash,
      PaymentMethod.qrBakai => l10n.payment_method_qr,
      PaymentMethod.credit => l10n.payment_method_credit,
    };
    final Money total = order.totalToPay ?? order.total;
    return Column(
      key: const ValueKey<String>('order-created-summary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (order.customer != null) row(l10n.checkout_section_customer, order.customer!.title),
        row(l10n.checkout_section_delivery, delivery),
        row(l10n.payment_method_title, method),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(l10n.checkout_summary_total, style: context.text.title.copyWith(color: c.textPrimary)),
            ),
            Text(
              CheckoutFormats.money(total),
              key: const ValueKey<String>('order-created-total'),
              style: context.text.title.copyWith(
                color: c.primaryText,
                fontWeight: FontWeight.w700,
                fontFeatures: DsTypography.numeric,
              ),
            ),
          ],
        ),
        Text(
          l10n.order_paid_of(CheckoutFormats.money(order.paidAmount ?? Money.zero), CheckoutFormats.money(total)),
          style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
        ),
      ],
    );
  }

  // ---- E: документы ----

  Widget _documents(BuildContext context, AppLocalizations l10n, OrderCreatedState s, Order order) {
    final DsColors c = context.colors;
    Widget row(String title, Widget trailing, {Key? key}) => Container(
      key: key,
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(title, style: context.text.body.copyWith(color: c.textPrimary)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Align(alignment: Alignment.centerRight, child: trailing),
          ),
        ],
      ),
    );
    Widget status(String text, Color color) => Text(
      text,
      textAlign: TextAlign.right,
      style: context.text.caption.copyWith(color: color),
    );
    Widget printable(OrderDocumentKind kind) {
      final OrderDocState st = s.docs[kind] ?? OrderDocState.idle;
      return switch (st) {
        OrderDocState.queued => status(l10n.order_created_doc_queued, c.info),
        OrderDocState.printed => status(l10n.order_created_doc_printed, c.success),
        OrderDocState.failed => TextButton(
          key: ValueKey<String>('order-created-doc-retry-${kind.value}'),
          onPressed: () => unawaited(_ctl.printDocument(kind)),
          child: Text(l10n.order_created_doc_failed, style: context.text.caption.copyWith(color: c.error)),
        ),
        OrderDocState.idle => AppButton(
          key: ValueKey<String>('order-created-doc-print-${kind.value}'),
          label: l10n.order_doc_print,
          variant: AppButtonVariant.text,
          size: AppButtonSize.s,
          onPressed: () => unawaited(_ctl.printDocument(kind)),
        ),
      };
    }

    return Column(
      key: const ValueKey<String>('order-created-documents'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        row(
          l10n.checkout_print_invoice,
          order.onec?.number == null
              ? status(l10n.order_doc_waiting_number, c.textSecondary)
              : printable(OrderDocumentKind.invoice),
          key: const ValueKey<String>('order-created-doc-invoice'),
        ),
        row(
          l10n.checkout_print_receipt,
          order.isPaid ? printable(OrderDocumentKind.receipt) : status(l10n.order_doc_after_payment, c.textSecondary),
        ),
        row(l10n.checkout_print_waybill, status(l10n.order_doc_waybill_from_onec, c.textSecondary)),
      ],
    );
  }

  // ---- F: действия ----

  Widget _footer(BuildContext context, AppLocalizations l10n, OrderCreatedState s, RoleCode? role) {
    final DsColors c = context.colors;
    final Order? order = s.order;
    final bool acceptCash =
        order != null && order.paymentMethod == PaymentMethod.cash && _isCashier(role) && !order.isPaid;
    final bool compact = context.windowClass == WindowClass.compact;
    final Widget open = AppButton(
      key: const ValueKey<String>('order-created-open'),
      label: l10n.order_created_open_order,
      variant: AppButtonVariant.text,
      onPressed: order == null ? null : _openOrder,
    );
    final Widget accept = AppButton(
      key: const ValueKey<String>('order-created-accept'),
      label: l10n.order_created_accept_payment,
      autofocus: true,
      size: compact ? AppButtonSize.l : AppButtonSize.m,
      expand: compact,
      onPressed: () => _acceptPayment(method: PaymentMethod.cash),
    );
    final Widget newOrder = AppButton(
      key: const ValueKey<String>('order-created-new'),
      label: l10n.order_created_new_order,
      variant: acceptCash ? AppButtonVariant.outlined : AppButtonVariant.primary,
      size: AppButtonSize.l,
      expand: compact,
      autofocus: !acceptCash,
      onPressed: _newOrder,
    );
    return Container(
      padding: EdgeInsets.fromLTRB(context.space.s6, context.space.s3, context.space.s6, context.space.s3),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: compact
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (acceptCash) ...<Widget>[accept, const SizedBox(height: 8)],
                open,
                const SizedBox(height: 8),
                newOrder,
              ],
            )
          : Row(
              children: <Widget>[
                open,
                const Spacer(),
                if (acceptCash) ...<Widget>[accept, const SizedBox(width: 12)],
                newOrder,
              ],
            ),
    );
  }
}

/// Диалог ручного подтверждения оплаты по выписке (UI-22-017): референс 4–64, сумма (предзаполнена суммой платежа),
/// время поступления (сейчас), комментарий ≤ 200; при несовпадении суммы — предупреждение до отправки.
class _ManualConfirmDialog extends StatefulWidget {
  const _ManualConfirmDialog({required this.amount, required this.now});

  final Money amount;
  final DateTime now;

  @override
  State<_ManualConfirmDialog> createState() => _ManualConfirmDialogState();
}

class _ManualConfirmDialogState extends State<_ManualConfirmDialog> {
  final TextEditingController _ref = TextEditingController();
  late final TextEditingController _amount = TextEditingController(
    text: widget.amount.toApiString().replaceAll('.', ','),
  );
  late final TextEditingController _time = TextEditingController(text: CheckoutFormats.time(widget.now));
  final TextEditingController _comment = TextEditingController();
  bool _tried = false;

  @override
  void dispose() {
    _ref.dispose();
    _amount.dispose();
    _time.dispose();
    _comment.dispose();
    super.dispose();
  }

  Money? get _parsedAmount {
    try {
      return Money.parseInput(_amount.text);
    } on Object {
      return null;
    }
  }

  bool get _refOk {
    final int n = _ref.text.trim().length;
    return n >= 4 && n <= 64;
  }

  DateTime _receivedAt() {
    final int? minutes = CheckoutFormats.minutesOf(_time.text.trim());
    if (minutes == null) return widget.now;
    final DateTime b = CheckoutFormats.bishkek(widget.now);
    return DateTime.utc(b.year, b.month, b.day, minutes ~/ 60, minutes % 60).subtract(CheckoutFormats.bishkekOffset);
  }

  void _submit() {
    setState(() => _tried = true);
    final Money? amount = _parsedAmount;
    if (!_refOk || amount == null) return;
    final String comment = _comment.text.trim();
    Navigator.of(context).pop(
      ConfirmManualRequest(
        bankReference: _ref.text.trim(),
        receivedAmount: amount,
        receivedAt: _receivedAt(),
        comment: comment.isEmpty ? null : comment,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Money? amount = _parsedAmount;
    final bool mismatch = amount != null && amount != widget.amount;
    return Dialog(
      backgroundColor: c.surface,
      surfaceTintColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(context.radii.lg)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(context.space.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l10n.order_created_manual_confirm, style: context.text.title.copyWith(color: c.textPrimary)),
              const SizedBox(height: 16),
              AppTextField(
                key: const ValueKey<String>('manual-ref'),
                controller: _ref,
                autofocus: true,
                label: l10n.order_created_manual_ref_label,
                maxLength: 64,
                errorText: _tried && !_refOk ? l10n.order_created_manual_ref_required : null,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              AppTextField(
                key: const ValueKey<String>('manual-amount'),
                controller: _amount,
                label: l10n.order_created_manual_amount_label,
                variant: AppTextFieldVariant.number,
                onChanged: (_) => setState(() {}),
              ),
              if (mismatch)
                Padding(
                  padding: EdgeInsets.only(top: context.space.s2),
                  child: ErrorState.banner(
                    key: const ValueKey<String>('manual-mismatch'),
                    message: l10n.order_created_manual_amount_mismatch,
                    tone: ErrorStateTone.warning,
                  ),
                ),
              const SizedBox(height: 12),
              AppTextField(
                key: const ValueKey<String>('manual-time'),
                controller: _time,
                label: l10n.order_created_manual_time_label,
              ),
              const SizedBox(height: 12),
              AppTextField(
                key: const ValueKey<String>('manual-comment'),
                controller: _comment,
                label: l10n.order_created_manual_comment_label,
                variant: AppTextFieldVariant.multiline,
                maxLength: 200,
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  AppButton(
                    label: l10n.ds_button_cancel,
                    variant: AppButtonVariant.text,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  AppButton(
                    key: const ValueKey<String>('manual-submit'),
                    label: l10n.order_created_manual_confirm,
                    onPressed: _submit,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
