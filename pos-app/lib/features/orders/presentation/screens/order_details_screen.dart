// SCR-24 «Заказ: детали и статус» (`/orders/{id}`; автор, cashier, senior_seller, admin, owner; customer — свой).
// Владелец реализации — агент F-fe-orders (RM-F-006; печать PDF — `printing`, RM-F-004; режим клиента — RM-F-015).
//
// Структура и раскладки — 02 SCR-24.2 (A шапка · B баннеры · C история · D клиент и получение · E состав · F итоги ·
// G платежи · H документы · I действия): compact — одна колонка (A → B → I → C → … → H), medium — 2 колонки,
// expanded/large — контент ≤ 1200 lp, справа колонка 320 «Действия и документы» (I + H + C). Кнопки — по
// `allowedActions` и роли (OrderViewRules); обновление — pull-to-refresh, «Обновить» из 1С (F5), возврат на экран,
// периодически раз в 60 с для незавершённых заказов (FQ-FEORD-07). Офлайн — `OfflineBanner`, последние данные из
// памяти, действия disabled (D-32). Имя класса и конструктор фиксированы основой (routes.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/document_actions.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/layout/route_activity.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/orders_format.dart';
import 'package:optomstroy/features/orders/presentation/orders_locations.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:optomstroy/features/orders/presentation/state/order_details_controller.dart';
import 'package:optomstroy/features/orders/presentation/state/order_view_rules.dart';
import 'package:optomstroy/features/orders/presentation/widgets/order_dialogs.dart';
import 'package:optomstroy/features/orders/presentation/widgets/order_documents.dart';
import 'package:optomstroy/features/orders/presentation/widgets/order_sections.dart';

/// SCR-24 «Заказ: детали и статус».
class OrderDetailsScreen extends ConsumerStatefulWidget {
  /// Экран SCR-24.
  const OrderDetailsScreen({required this.orderId, super.key});

  /// ID заказа (required).
  final String orderId;

  /// Ключ корня экрана (тесты маршрутов): `stub-SCR-24`.
  static const ValueKey<String> stubKey = ValueKey<String>('stub-SCR-24');

  /// Период тихого обновления незавершённого заказа [ДОПУЩЕНИЕ FQ-FEORD-07].
  static const Duration autoRefreshPeriod = Duration(seconds: 60);

  @override
  ConsumerState<OrderDetailsScreen> createState() => _OrderDetailsScreenState();
}

class _OrderDetailsScreenState extends ConsumerState<OrderDetailsScreen> {
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  final Set<String> _docBusy = <String>{};
  bool _actionBusy = false;
  ({int n, int count})? _repeatProgress;

  /// Экран был виден при последней проверке ([didChangeDependencies]); `null` — ещё не проверялся.
  bool? _onScreen;

  /// Возврат через [_pushAndReload] уже перечитал заказ — обновление по возврату на экран пропускается один раз.
  bool _returnRefreshed = false;

  OrderDetailsController get _ctrl => ref.read(orderDetailsProvider(widget.orderId).notifier);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(OrderDetailsScreen.autoRefreshPeriod, (_) => _autoRefresh());
    _lifecycle = AppLifecycleListener(onResume: _autoRefresh);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 02 SCR-24 «Загрузка»: при возврате на экран (из SCR-38/39/22) — повторная загрузка. SCR-22
    // `/orders/{id}/created` — дочерний маршрут SCR-24: экран строится под ним в момент создания заказа (до номера 1С
    // и оплаты) и становится верхним без пересоздания — «Открыть заказ», автопереход после «Оплата получена» (uiA-02).
    // Виден — ветка оболочки на экране и не закрыт непрозрачным маршрутом (`TickerMode`), над страницей нет другой
    // страницы навигатора. Меню, листы и диалоги поверх (маршруты без страницы) экран не закрывают: их закрытие —
    // не возврат (ревью RP-01, как SCR-25).
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    final bool onScreen = TickerMode.of(context) && (route?.settings is! Page<Object?> || dsRouteIsCurrent(context));
    final bool returned = _onScreen == false && onScreen;
    if (!onScreen) _returnRefreshed = false;
    _onScreen = onScreen;
    if (returned) WidgetsBinding.instance.addPostFrameCallback((_) => _refreshOnReturn());
  }

  void _refreshOnReturn() {
    if (!mounted || _onScreen != true) return;
    if (_returnRefreshed) {
      _returnRefreshed = false;
      return;
    }
    if (_offline) return;
    unawaited(_ctrl.refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  bool get _offline {
    final OnlineStatus s = ref.read(ordersOnlineStatusProvider);
    return s == OnlineStatus.offline || s == OnlineStatus.serverDown;
  }

  void _autoRefresh() {
    if (!mounted || _offline) return;
    final OrderDetailsState s = ref.read(orderDetailsProvider(widget.orderId));
    final OrderStatus? status = s.details?.order.status;
    if (s.phase != OrderDetailsPhase.loaded || status == OrderStatus.cancelled || status == OrderStatus.closed) {
      return;
    }
    unawaited(_ctrl.refresh());
  }

  void _snack(String message, {AppSnackbarVariant variant = AppSnackbarVariant.info}) {
    if (!mounted) return;
    AppSnackbar.show(context, message: message, variant: variant);
  }

  String _failureText(Failure f) => ErrorTexts.message(AppLocalizations.of(context), UiErrorMapper.fromFailure(f));

  Future<void> _refreshOnec() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final OnecRefreshOutcome r = await _ctrl.refreshFromOnec();
    if (!mounted) return;
    if (r == OnecRefreshOutcome.onecUnavailable) {
      final OrderDetailsState s = ref.read(orderDetailsProvider(widget.orderId));
      final DateTime? at = s.details?.order.onec?.lastSyncAt ?? s.loadedAt;
      final DateTime now = ref.read(clockProvider).nowUtc();
      _snack(l10n.order_onec_unavailable_snackbar(at == null ? '—' : OrdersFormat.stamp(at, now)));
    } else if (r == OnecRefreshOutcome.failed) {
      _snack(l10n.orders_load_failed, variant: AppSnackbarVariant.error);
    }
  }

  Future<void> _pushAndReload(String location) async {
    await context.ordersPush(location);
    if (mounted) {
      _returnRefreshed = true;
      unawaited(_ctrl.refresh());
    }
  }

  Future<void> _cancel(Order order, OrderActionsView actions) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final OrderDialogOutcome? outcome = await OrderCancelDialog.show(
      context,
      order: order,
      isRequest: actions.cancelIsRequest,
      withRefundIntent: OrderViewRules.hasReceivedMoney(order),
      onSubmit: (OrderCancelRequest request, String key) => _ctrl.cancel(request, idempotencyKey: key),
    );
    if (outcome == null || !mounted) return;
    final Order? done = outcome.order;
    final Failure? failure = outcome.failure;
    if (done != null) {
      _snack(
        done.status == OrderStatus.cancelled ? l10n.order_cancelled_snackbar : l10n.order_cancel_requested_snackbar,
      );
    } else if (failure is ConflictFailure && failure.kind == ConflictKind.orderStateInvalid) {
      final OrderStatus status = OrderStatus.tryParse(failure.currentStatus) ?? order.status;
      _snack(l10n.order_cancel_unavailable(OrderStatusChip.labelOf(l10n, status)), variant: AppSnackbarVariant.error);
    } else if (failure != null) {
      _snack(_failureText(failure), variant: AppSnackbarVariant.error);
      unawaited(_ctrl.refresh());
    }
  }

  Future<void> _onecLink(Order order) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final OrdersStepUp stepUp = ref.read(ordersStepUpProvider);
    final OrderDialogOutcome? outcome = await OrderOnecLinkDialog.show(
      context,
      order: order,
      onSubmit: (OrderOnecLinkRequest request, String key) async {
        final OrdersStepUpResult step = await stepUp('order.onec_link');
        if (step.cancelled) return const FailureResult<Order>(AuthFailure(AuthReason.stepUpRequired));
        return _ctrl.linkOnec(request, idempotencyKey: key, stepUpToken: step.token);
      },
    );
    if (outcome == null || !mounted) return;
    final Order? done = outcome.order;
    final Failure? failure = outcome.failure;
    if (done != null) {
      _snack(l10n.order_onec_link_done(done.onec?.number ?? ''), variant: AppSnackbarVariant.success);
    } else if (failure != null) {
      _snack(_failureText(failure), variant: AppSnackbarVariant.error);
    }
  }

  Future<void> _repeat(Order order, OrderRepeatPort port) async {
    if (_actionBusy) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    setState(() => _actionBusy = true);
    try {
      final Result<int> count = await port.activeCartItemsCount();
      if (!mounted) return;
      final int inCart = count.valueOrNull ?? 0;
      if (inCart > 0) {
        final _RepeatChoice? choice = await showDialog<_RepeatChoice>(
          context: context,
          builder: (BuildContext ctx) => _RepeatDialog(count: inCart),
        );
        if (!mounted || choice == null) return;
        if (choice == _RepeatChoice.parkAndNew) {
          final Result<void> parked = await port.parkActiveCart(idempotencyKey: newOrderIdempotencyKey());
          if (!mounted) return;
          final Failure? f = parked.failureOrNull;
          if (f != null) {
            _snack(_failureText(f), variant: AppSnackbarVariant.error);
            return;
          }
        }
      }
      int skipped = 0;
      final List<OrderLine> lines = order.items;
      for (int i = 0; i < lines.length; i++) {
        if (!mounted) return;
        setState(() => _repeatProgress = (n: i + 1, count: lines.length));
        final Result<bool> added = await port.addLine(lines[i], idempotencyKey: newOrderIdempotencyKey());
        if (added.valueOrNull != true) skipped++;
      }
      if (!mounted) return;
      if (skipped > 0) _snack(l10n.order_repeat_skipped(skipped), variant: AppSnackbarVariant.info);
      context.ordersGo(OrdersLocations.cart);
    } finally {
      if (mounted) {
        setState(() {
          _actionBusy = false;
          _repeatProgress = null;
        });
      }
    }
  }

  Future<void> _doc(String orderId, String kind, OrderDocCommand command) async {
    final OrderDocumentKind docKind = kind == 'receipt' ? OrderDocumentKind.receipt : OrderDocumentKind.invoice;
    if (_docBusy.contains(kind)) return;
    setState(() => _docBusy.add(kind));
    try {
      await runOrderDocument(context, ref, orderId: orderId, kind: docKind, command: command);
    } finally {
      if (mounted) setState(() => _docBusy.remove(kind));
    }
  }

  void _printShortcut(OrderDetails d, OrdersViewer viewer) {
    final List<OrderDocView> docs = OrderViewRules.documents(d, viewer);
    for (final OrderDocView doc in docs) {
      if (doc.available && (doc.kind == 'invoice' || doc.kind == 'receipt')) {
        unawaited(_doc(d.order.id, doc.kind, OrderDocCommand.print));
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final OrderDetailsState state = ref.watch(orderDetailsProvider(widget.orderId));
    final OrdersViewer viewer = ref.watch(ordersViewerProvider);
    final OnlineStatus online = ref.watch(ordersOnlineStatusProvider);
    final bool offline = online == OnlineStatus.offline || online == OnlineStatus.serverDown;
    final OrderDetails? details = state.details;
    final DsColors c = context.colors;
    final OrderNotificationBannerBuilder? notificationBanner = ref.watch(orderNotificationBannerProvider);

    final Widget body = switch (state.phase) {
      OrderDetailsPhase.loading => const _DetailsSkeleton(),
      OrderDetailsPhase.notFound => Center(
        child: EmptyState(
          key: const ValueKey<String>('order-not-found'),
          variant: EmptyStateVariant.orders,
          title: l10n.order_not_found,
        ),
      ),
      OrderDetailsPhase.error => ErrorState.fullScreen(
        key: const ValueKey<String>('order-error'),
        title: _failureText(state.failure ?? const UnknownFailure()),
        message: '',
        requestId: state.failure?.requestId,
        onRetry: _ctrl.load,
      ),
      OrderDetailsPhase.loaded => _loaded(
        context,
        details!,
        viewer,
        offline: offline,
        now: ref.read(clockProvider).nowUtc(),
      ),
    };

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f5): () =>
            viewer.isStaff && !offline ? unawaited(_refreshOnec()) : unawaited(_ctrl.refresh()),
        const SingleActivator(LogicalKeyboardKey.keyP, control: true): () {
          if (details != null && !offline && ref.read(orderDocumentPrinterProvider) != null) {
            _printShortcut(details, viewer);
          }
        },
        const SingleActivator(LogicalKeyboardKey.escape): () => unawaited(Navigator.of(context).maybePop()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: OrderDetailsScreen.stubKey,
          backgroundColor: c.background,
          appBar: AppBar(
            title: details == null ? Text(l10n.orders_title) : OrderHeaderBlock.numberTitle(context, details.order),
          ),
          body: Column(
            children: <Widget>[
              OfflineBanner(
                variant: online == OnlineStatus.offline
                    ? OfflineBannerVariant.offline
                    : (online == OnlineStatus.serverDown ? OfflineBannerVariant.serverDown : null),
                dataAsOf: state.loadedAt,
                now: ref.read(clockProvider).nowUtc(),
              ),
              ?notificationBanner?.call(context, widget.orderId),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loaded(
    BuildContext context,
    OrderDetails d,
    OrdersViewer viewer, {
    required bool offline,
    required DateTime now,
  }) {
    final Order o = d.order;
    final WindowClass wc = context.windowClass;
    final OrderRepeatPort? repeatPort = ref.watch(orderRepeatPortProvider);
    final OrderActionsView actions = OrderViewRules.actions(d, viewer, repeatAvailable: repeatPort != null);
    final OrderDetailsState s = ref.watch(orderDetailsProvider(widget.orderId));

    final Widget header = OrderHeaderBlock(
      order: o,
      viewer: viewer,
      nowUtc: now,
      refreshing: s.refreshingFromOnec,
      onRefreshOnec: offline ? null : _refreshOnec,
    );
    final OrderRestoredCartLocator? restoredCart = ref.watch(orderRestoredCartLocatorProvider);
    final Widget banners = OrderBanners(
      order: o,
      viewer: viewer,
      onOpenRestoredCart: restoredCart == null || offline
          ? null
          : () async {
              final String location = await restoredCart(o.id);
              if (context.mounted) context.ordersGo(location);
            },
    );
    final Widget? actionsBlock = actions.any
        ? _ActionsBlock(
            actions: actions,
            offline: offline,
            busy: _actionBusy,
            repeatProgress: _repeatProgress,
            expand: wc == WindowClass.compact,
            onPay: () => _pushAndReload(OrdersLocations.acceptPayment(o.id)),
            onShowQr: actions.showQrPaymentId == null
                ? null
                : () => _pushAndReload(OrdersLocations.showQr(o.id, actions.showQrPaymentId!)),
            onOnecLink: () => _onecLink(o),
            onRepeat: repeatPort == null ? null : () => _repeat(o, repeatPort),
            onReturn: () => _pushAndReload(OrdersLocations.returnRequest(o.id)),
            onCancel: () => _cancel(o, actions),
          )
        : null;
    final Widget history = OrderHistoryBlock(order: o, collapsible: wc == WindowClass.compact);
    final Widget customer = OrderCustomerBlock(
      order: o,
      viewer: viewer,
      onOpenCustomer: o.customer == null ? null : () => context.ordersGo(OrdersLocations.customer(o.customer!.id)),
    );
    final bool table = wc == WindowClass.expanded || wc == WindowClass.large;
    final Widget items = OrderItemsBlock(
      order: o,
      table: table,
      onOpenProduct: (String id) => unawaited(context.ordersPush(OrdersLocations.product(id))),
    );
    final Widget totals = OrderTotalsBlock(order: o, viewer: viewer);
    final Widget payments = OrderPaymentsBlock(
      order: o,
      customerMode: viewer.isCustomer,
      onOpenTransaction: (String id) => unawaited(context.ordersPush(OrdersLocations.transaction(id))),
    );
    final Widget documents = _documents(context, d, viewer, offline: offline);

    final double gap = context.space.s4; // money-double: allow — отступ (lp)
    List<Widget> spaced(List<Widget?> ws) {
      final List<Widget> out = <Widget>[];
      for (final Widget? w in ws) {
        if (w == null) continue;
        if (out.isNotEmpty) out.add(SizedBox(height: gap));
        out.add(w);
      }
      return out;
    }

    final EdgeInsets pad = EdgeInsets.all(wc == WindowClass.compact ? context.space.s4 : context.space.s6);
    final Widget content = switch (wc) {
      WindowClass.compact => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: spaced(<Widget?>[
          header,
          banners,
          actionsBlock,
          history,
          customer,
          items,
          totals,
          payments,
          documents,
        ]),
      ),
      WindowClass.medium => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ...spaced(<Widget?>[header, banners]),
          SizedBox(height: gap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: spaced(<Widget?>[history, customer]),
                ),
              ),
              SizedBox(width: gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: spaced(<Widget?>[items, totals, payments, documents, actionsBlock]),
                ),
              ),
            ],
          ),
        ],
      ),
      WindowClass.expanded || WindowClass.large => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: DsBreakpoints.contentMaxLarge),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: spaced(<Widget?>[header, banners, items, totals, customer, payments]),
                ),
              ),
              SizedBox(width: gap),
              SizedBox(
                width: 320,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: spaced(<Widget?>[actionsBlock, documents, history]),
                ),
              ),
            ],
          ),
        ),
      ),
    };
    return RefreshIndicator(
      onRefresh: () async {
        final Failure? f = await _ctrl.refresh();
        if (f != null && mounted) _snack(_failureText(f), variant: AppSnackbarVariant.error);
      },
      child: SingleChildScrollView(
        key: const ValueKey<String>('order-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: pad,
        child: content,
      ),
    );
  }

  Widget _documents(BuildContext context, OrderDetails d, OrdersViewer viewer, {required bool offline}) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<OrderDocView> docs = OrderViewRules.documents(d, viewer);
    if (docs.isEmpty) return const SizedBox.shrink();
    final bool canSave = ref.watch(orderDocumentSaverProvider) != null;
    final bool canPrint = ref.watch(orderDocumentPrinterProvider) != null;
    String? reason(DocUnavailable? r) => switch (r) {
      DocUnavailable.waitingNumber => l10n.order_doc_waiting_number,
      DocUnavailable.afterPayment => l10n.order_doc_after_payment,
      DocUnavailable.fromOnec => l10n.order_doc_waybill_from_onec,
      DocUnavailable.notAllowed || null => null,
    };
    return OrderSection(
      key: const ValueKey<String>('order-documents'),
      title: OrdersTexts.sectionDocuments(l10n),
      child: DocumentActions(
        previewLabel: l10n.order_doc_preview,
        printLabel: l10n.order_doc_print,
        downloadLabel: l10n.order_doc_download,
        enabled: !offline,
        items: <DocumentActionItem>[
          for (final OrderDocView doc in docs)
            DocumentActionItem(
              id: doc.kind,
              title: switch (doc.kind) {
                'invoice' => OrdersTexts.invoice(l10n),
                'receipt' => OrdersTexts.receipt(l10n),
                _ => OrdersTexts.waybill(l10n),
              },
              subtitle: switch (doc.kind) {
                'invoice' => OrdersTexts.invoiceHint(l10n),
                'receipt' => OrdersTexts.receiptHint(l10n),
                _ => null,
              },
              icon: doc.kind == 'receipt' ? Icons.receipt_long_outlined : Icons.description_outlined,
              available: doc.available,
              unavailableReason: reason(doc.reason),
              busy: _docBusy.contains(doc.kind),
              onPreview: doc.kind == 'waybill' || !canPrint
                  ? null
                  : () => _doc(d.order.id, doc.kind, OrderDocCommand.preview),
              onPrint: doc.kind == 'waybill' || !canPrint
                  ? null
                  : () => _doc(d.order.id, doc.kind, OrderDocCommand.print),
              onDownload: doc.kind == 'waybill' || !canSave
                  ? null
                  : () => _doc(d.order.id, doc.kind, OrderDocCommand.download),
            ),
        ],
      ),
    );
  }
}

/// I — действия (UI-24-010…013, UI-24-019, UI-24-021): основное — первым, отмена — последней за разделителем.
class _ActionsBlock extends StatelessWidget {
  const _ActionsBlock({
    required this.actions,
    required this.offline,
    required this.busy,
    required this.repeatProgress,
    required this.expand,
    required this.onPay,
    required this.onShowQr,
    required this.onOnecLink,
    required this.onRepeat,
    required this.onReturn,
    required this.onCancel,
  });

  final OrderActionsView actions;
  final bool offline;
  final bool busy;
  final ({int n, int count})? repeatProgress;
  final bool expand;
  final VoidCallback onPay;
  final VoidCallback? onShowQr;
  final VoidCallback onOnecLink;
  final VoidCallback? onRepeat;
  final VoidCallback onReturn;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    VoidCallback? on(VoidCallback? f) => offline || busy ? null : f;
    final List<Widget> main = <Widget>[
      if (actions.pay)
        AppButton(
          key: const ValueKey<String>('action-pay'),
          label: l10n.order_action_pay,
          size: AppButtonSize.l,
          icon: Icons.payments_outlined,
          expand: true,
          onPressed: on(onPay),
        ),
      if (actions.showQrPaymentId != null)
        AppButton(
          key: const ValueKey<String>('action-show-qr'),
          label: l10n.order_action_show_qr,
          variant: AppButtonVariant.outlined,
          icon: Icons.qr_code_2_rounded,
          expand: true,
          onPressed: on(onShowQr),
        ),
      if (actions.onecLink)
        AppButton(
          key: const ValueKey<String>('action-onec-link'),
          label: l10n.order_onec_link_action,
          variant: AppButtonVariant.outlined,
          icon: Icons.link_rounded,
          expand: true,
          onPressed: on(onOnecLink),
        ),
      if (actions.repeat)
        AppButton(
          key: const ValueKey<String>('action-repeat'),
          label: repeatProgress == null
              ? l10n.order_action_repeat
              : l10n.order_repeat_progress(repeatProgress!.count, repeatProgress!.n),
          variant: AppButtonVariant.outlined,
          icon: Icons.replay_rounded,
          loading: repeatProgress != null,
          expand: true,
          onPressed: on(onRepeat),
        ),
      if (repeatProgress != null)
        AppProgress.linear(value: repeatProgress!.n / repeatProgress!.count), // money-double: allow — доля прогресса
      if (actions.returnRequest)
        AppButton(
          key: const ValueKey<String>('action-return'),
          label: l10n.order_action_return,
          variant: AppButtonVariant.outlined,
          icon: Icons.assignment_return_outlined,
          expand: true,
          onPressed: on(onReturn),
        ),
    ];
    final List<Widget> children = <Widget>[];
    for (final Widget w in main) {
      if (children.isNotEmpty) children.add(SizedBox(height: context.space.s2));
      children.add(w);
    }
    if (actions.cancel) {
      if (children.isNotEmpty) {
        children
          ..add(SizedBox(height: context.space.s4))
          ..add(Divider(height: 1, thickness: 1, color: c.border))
          ..add(SizedBox(height: context.space.s4));
      }
      children.add(
        AppButton(
          key: const ValueKey<String>('action-cancel'),
          label: actions.cancelIsRequest ? l10n.order_action_cancel_request : l10n.order_action_cancel,
          variant: AppButtonVariant.danger,
          icon: Icons.cancel_outlined,
          expand: true,
          onPressed: actions.cancelPending ? null : on(onCancel),
        ),
      );
    }
    return OrderSection(
      key: const ValueKey<String>('order-actions'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

enum _RepeatChoice { add, parkAndNew }

/// UI-24-020 «Корзина не пуста».
class _RepeatDialog extends StatelessWidget {
  const _RepeatDialog({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    return Dialog(
      backgroundColor: c.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: EdgeInsets.all(context.space.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l10n.order_action_repeat, style: context.text.h3.copyWith(color: c.textPrimary)),
              SizedBox(height: context.space.s3),
              Text(l10n.order_repeat_dialog_body(count), style: context.text.body.copyWith(color: c.textSecondary)),
              SizedBox(height: context.space.s6),
              AppButton(
                key: const ValueKey<String>('repeat-add'),
                label: l10n.order_repeat_add,
                expand: true,
                onPressed: () => Navigator.of(context).pop(_RepeatChoice.add),
              ),
              SizedBox(height: context.space.s2),
              AppButton(
                key: const ValueKey<String>('repeat-park'),
                label: l10n.order_repeat_park_and_new,
                variant: AppButtonVariant.outlined,
                expand: true,
                onPressed: () => Navigator.of(context).pop(_RepeatChoice.parkAndNew),
              ),
              SizedBox(height: context.space.s2),
              AppButton(
                key: const ValueKey<String>('repeat-cancel'),
                label: l10n.ds_button_cancel,
                variant: AppButtonVariant.text,
                autofocus: true,
                expand: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Скелетоны шапки, состава и итогов (ANIM-013).
class _DetailsSkeleton extends StatelessWidget {
  const _DetailsSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    key: const ValueKey<String>('order-skeleton'),
    padding: EdgeInsets.all(context.space.s4),
    children: <Widget>[
      const SkeletonBox.text(width: 220, height: 28),
      SizedBox(height: context.space.s2),
      const SkeletonBox(width: 140, height: 24),
      SizedBox(height: context.space.s6),
      for (int i = 0; i < 4; i++) ...<Widget>[const SkeletonBox(height: 56), SizedBox(height: context.space.s2)],
      SizedBox(height: context.space.s4),
      const SkeletonBox(height: 96),
    ],
  );
}
