// SCR-25 «Список заказов» (`/orders?status=&from=&to=&customerId=&mine=`; seller и customer — свои, прочие staff —
// все). Владелец реализации — агент F-fe-orders (RM-F-006, RM-F-013: чипы `statusCounts`; RM-F-015: «Мои заказы»
// клиента).
//
// Структура — 02 SCR-25.2: заголовок и счётчик (`totalEstimate`) · поиск по номеру (debounce 300 мс; номер целиком
// и единственный результат — сразу SCR-24) · чипы групп статусов со счётчиками · период и «Мои / Все»
// (`order.read.all`) · «Фильтры» (клиент, способ оплаты, оплачен) и сортировка · список (compact 72 / medium 56) или
// таблица (expanded 48) · курсорная подгрузка. Смена фильтров — новый запрос с первой страницы; `status`, `from`,
// `to`, `customerId`, `mine` — в query маршрута. Имя класса и конструктор фиксированы основой (routes.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/search_bar.dart' as ds;
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/sort_menu.dart';
import 'package:optomstroy/design_system/components/status_count_chips.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/orders_format.dart';
import 'package:optomstroy/features/orders/presentation/orders_locations.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:optomstroy/features/orders/presentation/state/order_view_rules.dart';
import 'package:optomstroy/features/orders/presentation/state/orders_filters.dart';
import 'package:optomstroy/features/orders/presentation/state/orders_list_controller.dart';
import 'package:optomstroy/features/orders/presentation/widgets/order_documents.dart';
import 'package:optomstroy/features/orders/presentation/widgets/orders_filter_form.dart';
import 'package:optomstroy/features/orders/presentation/widgets/orders_list_rows.dart';

/// SCR-25 «Список заказов».
class OrdersScreen extends ConsumerStatefulWidget {
  /// Экран SCR-25.
  const OrdersScreen({this.status, this.from, this.to, this.customerId, this.mine, super.key});

  /// Статусы через запятую (значения `OrderStatus`).
  final String? status;

  /// Начало периода (ISO-8601).
  final String? from;

  /// Конец периода (ISO-8601).
  final String? to;

  /// Клиент.
  final String? customerId;

  /// `1` — только свои заказы.
  final String? mine;

  /// Ключ корня экрана (тесты маршрутов): `stub-SCR-25`.
  static const ValueKey<String> stubKey = ValueKey<String>('stub-SCR-25');

  /// Через сколько выборка считается устаревшей [НЕ ПОДТВЕРЖДЕНО, Q-176].
  static const Duration staleAfter = Duration(minutes: 5);

  /// Номер заказа целиком: POS (`POS-2026-000123`) или документ 1С (`УТ-0001234`).
  static final RegExp fullNumber = RegExp(r'^(POS-\d{4}-\d{6,}|[^\s-]{1,8}-\d{4,})$', caseSensitive: false);

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  late OrdersFilters _filters;
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;
  Timer? _ticker;
  AppLifecycleListener? _lifecycle;
  bool _panelOpen = false;
  bool _navigating = false;

  /// Поиск отправлен (Enter/скан): при единственном совпадении — сразу SCR-24 (AC-UI-25-004).
  String? _openOnSingle;

  DateTime get _now => ref.read(clockProvider).nowUtc();

  @override
  void initState() {
    super.initState();
    _filters = _fromRoute();
    _scroll.addListener(_onScroll);
    // Метка «Данные от {time}» появляется через 5 мин без действий пользователя.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_list.refresh()));
  }

  OrdersFilters _fromRoute() => OrdersFilters.fromRoute(
    nowUtc: _now,
    status: widget.status,
    from: widget.from,
    to: widget.to,
    customerId: widget.customerId,
    mine: widget.mine,
  );

  @override
  void didUpdateWidget(covariant OrdersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status == widget.status &&
        oldWidget.from == widget.from &&
        oldWidget.to == widget.to &&
        oldWidget.customerId == widget.customerId &&
        oldWidget.mine == widget.mine) {
      return;
    }
    final OrdersFilters route = _fromRoute();
    final OrdersFilters merged = route.copyWith(
      paymentMethod: () => _filters.paymentMethod,
      paid: _filters.paid,
      q: _filters.q,
      sort: _filters.sort,
      customerName: () => route.customerId == _filters.customerId ? _filters.customerName : null,
    );
    if (merged != _filters) _filters = merged;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ticker?.cancel();
    _lifecycle?.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  OrdersListController get _list => ref.read(ordersListProvider(_filters).notifier);

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 400) unawaited(_list.loadMore());
  }

  void _setFilters(OrdersFilters next) {
    if (next == _filters) return;
    setState(() => _filters = next.copyWith());
    if (_scroll.hasClients) _scroll.jumpTo(0);
    // Фильтры — в query маршрута (восстановление после перезапуска и «Назад» из SCR-24, AC-UI-25-010).
    GoRouter.maybeOf(context)?.go(OrdersLocations.orders(next.toRouteQuery()));
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _setFilters(_filters.copyWith(q: text.trim()));
    });
  }

  void _onSearchSubmitted(String text) {
    _debounce?.cancel();
    final String q = text.trim();
    _openOnSingle = OrdersScreen.fullNumber.hasMatch(q) ? q : null;
    _setFilters(_filters.copyWith(q: q));
    // Тот же запрос уже загружен — проверить сразу.
    _maybeOpenSingle(ref.read(ordersListProvider(_filters)));
  }

  void _maybeOpenSingle(OrdersListState s) {
    final String? q = _openOnSingle;
    if (q == null || s.phase == OrdersListPhase.loading || _filters.q != q) return;
    _openOnSingle = null;
    if (s.phase == OrdersListPhase.ready && s.items.length == 1) {
      unawaited(_open(s.items.single.id));
    } else if (s.phase == OrdersListPhase.empty) {
      AppSnackbar.show(context, message: AppLocalizations.of(context).orders_scan_not_found(q));
    }
  }

  Future<void> _open(String orderId) async {
    if (_navigating) return; // двойной тап — один переход
    _navigating = true;
    try {
      await context.ordersPush(OrdersLocations.order(orderId));
    } finally {
      _navigating = false;
      // Возврат из SCR-24 — тихое обновление первой страницы с сохранением прокрутки.
      if (mounted) unawaited(_list.refresh());
    }
  }

  Future<void> _pickPeriod(OrdersPeriodPreset preset) async {
    if (preset != OrdersPeriodPreset.custom) {
      _setFilters(_filters.copyWith(period: OrdersPeriod.preset(preset, _now)));
      return;
    }
    final DateTime now = OrdersFormat.wall(_now);
    final DateTime from = OrdersFormat.wall(_filters.period.from);
    final DateTime to = OrdersFormat.wall(_filters.period.to.subtract(const Duration(minutes: 1)));
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: DateTimeRange(
        start: DateTime(from.year, from.month, from.day),
        end: DateTime(to.year, to.month, to.day),
      ),
    );
    if (range == null || !mounted) return;
    // Выбранные дни — дни Бишкека: полдень дня в UTC+6 → тот же день при переводе в UTC.
    DateTime dayUtc(DateTime d) => DateTime.utc(d.year, d.month, d.day, 12).subtract(OrdersFormat.bishkekOffset);
    _setFilters(_filters.copyWith(period: OrdersPeriod.days(dayUtc(range.start), dayUtc(range.end))));
  }

  Future<void> _openFilters(WindowClass wc, OrdersViewer viewer) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (wc == WindowClass.expanded || wc == WindowClass.large) {
      setState(() => _panelOpen = !_panelOpen);
      return;
    }
    Widget form() => OrdersFilterForm(filters: _filters, showCustomer: viewer.isStaff, onChanged: _setFilters);
    if (wc == WindowClass.compact) {
      await AppBottomSheet.show<void>(context, title: l10n.orders_filters, body: form());
    } else {
      await AppBottomSheet.showSide<void>(context, title: l10n.orders_filters, width: 320, body: form());
    }
  }

  Future<void> _printFromRow(BuildContext anchor, OrderSummary o, OrdersViewer viewer) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final RenderBox box = anchor.findRenderObject()! as RenderBox;
    final Offset at = box.localToGlobal(Offset(0, box.size.height));
    final OrderDocumentKind? kind = await showMenu<OrderDocumentKind>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: <PopupMenuEntry<OrderDocumentKind>>[
        PopupMenuItem<OrderDocumentKind>(
          key: const ValueKey<String>('row-print-invoice'),
          value: OrderDocumentKind.invoice,
          child: Text(OrdersTexts.invoice(l10n)),
        ),
        if (!viewer.isCustomer)
          PopupMenuItem<OrderDocumentKind>(
            key: const ValueKey<String>('row-print-receipt'),
            value: OrderDocumentKind.receipt,
            enabled: o.isPaid,
            child: Text(OrdersTexts.receipt(l10n)),
          ),
      ],
    );
    if (kind == null || !mounted) return;
    await runOrderDocument(context, ref, orderId: o.id, kind: kind, command: OrderDocCommand.print);
  }

  String _periodLabel(AppLocalizations l10n) {
    final OrdersPeriod p = _filters.period;
    return switch (p.preset) {
      OrdersPeriodPreset.today => l10n.orders_period_today,
      OrdersPeriodPreset.yesterday => l10n.orders_period_yesterday,
      OrdersPeriodPreset.days7 => l10n.orders_period_7_days,
      OrdersPeriodPreset.month => l10n.orders_period_month,
      OrdersPeriodPreset.last3Days || OrdersPeriodPreset.custom =>
        '${OrdersFormat.shortDate(p.from)} – ${OrdersFormat.shortDate(p.to.subtract(const Duration(minutes: 1)))}',
    };
  }

  String _groupLabel(AppLocalizations l10n, OrdersStatusGroup g) => switch (g) {
    OrdersStatusGroup.all => l10n.orders_chip_all,
    OrdersStatusGroup.inProgress => l10n.orders_chip_in_progress,
    OrdersStatusGroup.awaitingPayment => l10n.orders_chip_awaiting_payment,
    OrdersStatusGroup.shipped => l10n.orders_chip_shipped,
    OrdersStatusGroup.closed => l10n.orders_chip_closed,
    OrdersStatusGroup.cancelled => l10n.orders_chip_cancelled,
  };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final OrdersViewer viewer = ref.watch(ordersViewerProvider);
    final OnlineStatus online = ref.watch(ordersOnlineStatusProvider);
    final bool offline = online == OnlineStatus.offline || online == OnlineStatus.serverDown;
    final OrdersListState state = ref.watch(ordersListProvider(_filters));
    final WindowClass wc = context.windowClass;
    final bool wide = wc == WindowClass.expanded || wc == WindowClass.large;

    ref.listen<OrdersListState>(ordersListProvider(_filters), (OrdersListState? prev, OrdersListState next) {
      _maybeOpenSingle(next);
      final Failure? f = next.failure;
      if (f != null && next.phase != OrdersListPhase.error && prev?.failure == null) {
        AppSnackbar.show(context, message: l10n.orders_load_failed, variant: AppSnackbarVariant.error);
        _list.clearFailure();
      }
    });

    final String title = viewer.canReadAll ? l10n.orders_title : l10n.orders_title_mine;
    final double hPad = // money-double: allow — отступ (lp)
    wc == WindowClass.compact
        ? context.space.s4
        : context.space.s6;
    final DateTime now = _now;
    final DateTime? loadedAt = state.loadedAt;
    final bool stale = loadedAt != null && now.difference(loadedAt) >= OrdersScreen.staleAfter;

    final Widget header = Padding(
      padding: EdgeInsets.fromLTRB(hPad, context.space.s3, hPad, context.space.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (state.totalEstimate != null)
            Text(
              l10n.orders_found_count(state.totalEstimate!),
              key: const ValueKey<String>('orders-found-count'),
              style: context.text.caption.copyWith(color: c.textSecondary),
            ),
          SizedBox(height: context.space.s2),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 480 : double.infinity), // money-double: allow — ширина (lp)
              child: ds.SearchBar(
                key: const ValueKey<String>('orders-search'),
                variant: ds.SearchBarVariant.compact,
                controller: _search,
                focusNode: _searchFocus,
                placeholder: l10n.orders_search_hint,
                loading: state.refreshing || (state.phase == OrdersListPhase.loading && _filters.q.isNotEmpty),
                onChanged: _onSearchChanged,
                onSubmitted: _onSearchSubmitted,
              ),
            ),
          ),
        ],
      ),
    );

    final OrdersStatusGroup? group = _filters.group;
    final Widget chips = StatusCountChips<OrdersStatusGroup>(
      key: const ValueKey<String>('orders-status-chips'),
      padding: EdgeInsets.symmetric(horizontal: hPad),
      enabled: !offline,
      selected: group,
      countLabel: (String label, int count) => l10n.orders_chip_count(count, label),
      items: <StatusCountChipItem<OrdersStatusGroup>>[
        for (final OrdersStatusGroup g in OrdersStatusGroup.values)
          StatusCountChipItem<OrdersStatusGroup>(
            value: g,
            label: _groupLabel(l10n, g),
            count: g.countIn(state.statusCounts),
          ),
      ],
      onSelected: (OrdersStatusGroup g) => _setFilters(_filters.copyWith(statuses: g.statuses)),
    );

    final Widget periodButton = PopupMenuButton<OrdersPeriodPreset>(
      key: const ValueKey<String>('orders-period'),
      tooltip: l10n.orders_period_custom,
      enabled: !offline,
      onSelected: (OrdersPeriodPreset p) => unawaited(_pickPeriod(p)),
      itemBuilder: (BuildContext ctx) => <PopupMenuEntry<OrdersPeriodPreset>>[
        PopupMenuItem<OrdersPeriodPreset>(value: OrdersPeriodPreset.today, child: Text(l10n.orders_period_today)),
        PopupMenuItem<OrdersPeriodPreset>(
          value: OrdersPeriodPreset.yesterday,
          child: Text(l10n.orders_period_yesterday),
        ),
        PopupMenuItem<OrdersPeriodPreset>(value: OrdersPeriodPreset.days7, child: Text(l10n.orders_period_7_days)),
        PopupMenuItem<OrdersPeriodPreset>(value: OrdersPeriodPreset.month, child: Text(l10n.orders_period_month)),
        PopupMenuItem<OrdersPeriodPreset>(value: OrdersPeriodPreset.custom, child: Text(l10n.orders_period_custom)),
      ],
      child: IgnorePointer(
        child: AppButton(
          label: _periodLabel(l10n),
          variant: AppButtonVariant.outlined,
          size: AppButtonSize.s,
          icon: Icons.date_range_outlined,
          onPressed: offline ? null : () {},
        ),
      ),
    );

    // UI-25-005: «Мои / Все» — `AppTabs` в строке фильтров, вариант `segmented` (03 §9.49; FQ-FEORD-04).
    final Widget? scope = viewer.canReadAll
        ? AppTabs<bool>(
            variant: AppTabsVariant.segmented,
            value: _filters.mine,
            enabled: !offline,
            tabs: <AppTab<bool>>[
              AppTab<bool>(
                key: const ValueKey<String>('orders-scope-mine'),
                value: true,
                label: l10n.orders_scope_mine,
              ),
              AppTab<bool>(key: const ValueKey<String>('orders-scope-all'), value: false, label: l10n.orders_scope_all),
            ],
            onChanged: (bool mine) => _setFilters(_filters.copyWith(mine: mine)),
          )
        : null;

    final int panelCount = _filters.panelCount;
    final Widget filtersButton = AppButton(
      key: const ValueKey<String>('orders-filters'),
      label: panelCount == 0 ? l10n.orders_filters : '${l10n.orders_filters} · $panelCount',
      variant: panelCount == 0 ? AppButtonVariant.outlined : AppButtonVariant.tonal,
      size: AppButtonSize.s,
      icon: Icons.tune_rounded,
      onPressed: offline ? null : () => unawaited(_openFilters(wc, viewer)),
    );

    final Widget sort = SortMenu<OrdersSort>(
      key: const ValueKey<String>('orders-sort'),
      semanticLabel: switch (_filters.sort) {
        OrdersSort.createdAtDesc => l10n.orders_sort_newest,
        OrdersSort.totalDesc => l10n.orders_sort_total,
        OrdersSort.statusAsc => l10n.orders_sort_status,
      },
      iconOnly: wc == WindowClass.compact,
      selected: _filters.sort,
      options: <SortMenuOption<OrdersSort>>[
        SortMenuOption<OrdersSort>(value: OrdersSort.createdAtDesc, label: l10n.orders_sort_newest),
        SortMenuOption<OrdersSort>(value: OrdersSort.totalDesc, label: l10n.orders_sort_total),
        SortMenuOption<OrdersSort>(value: OrdersSort.statusAsc, label: l10n.orders_sort_status),
      ],
      onSelected: (OrdersSort s) => _setFilters(_filters.copyWith(sort: s)),
    );

    final Widget toolbar = Padding(
      padding: EdgeInsets.fromLTRB(hPad, context.space.s2, hPad, context.space.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Wrap(
              spacing: context.space.s2,
              runSpacing: context.space.s2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[periodButton, ?scope, filtersButton],
            ),
          ),
          SizedBox(width: context.space.s2),
          IntrinsicWidth(child: sort),
        ],
      ),
    );

    final Widget list = _buildList(context, l10n, state, viewer, wc, offline: offline);
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header,
        chips,
        toolbar,
        if (stale)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            child: Row(
              key: const ValueKey<String>('orders-stale'),
              children: <Widget>[
                Icon(Icons.schedule_rounded, size: 16, color: c.warning),
                SizedBox(width: context.space.s1),
                Text(
                  l10n.orders_stale(OrdersFormat.stamp(loadedAt, now)),
                  style: context.text.caption.copyWith(color: c.warning),
                ),
                AppButton(
                  label: l10n.orders_refresh,
                  variant: AppButtonVariant.text,
                  size: AppButtonSize.s,
                  onPressed: offline ? null : () => unawaited(_list.refresh()),
                ),
              ],
            ),
          ),
        Expanded(child: list),
      ],
    );

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f5): () => unawaited(_list.refresh()),
        const SingleActivator(LogicalKeyboardKey.f2): _searchFocus.requestFocus,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _searchFocus.requestFocus,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: OrdersScreen.stubKey,
          backgroundColor: c.background,
          appBar: AppBar(title: Text(title)),
          body: Column(
            children: <Widget>[
              OfflineBanner(
                variant: online == OnlineStatus.offline
                    ? OfflineBannerVariant.offline
                    : (online == OnlineStatus.serverDown ? OfflineBannerVariant.serverDown : null),
                dataAsOf: loadedAt,
                now: now,
              ),
              Expanded(
                child: wide && _panelOpen
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(child: content),
                          Container(
                            key: const ValueKey<String>('orders-filter-panel'),
                            width: 280,
                            decoration: BoxDecoration(
                              color: c.surface,
                              border: Border(left: BorderSide(color: c.border)),
                            ),
                            child: SingleChildScrollView(
                              padding: EdgeInsets.all(context.space.s4),
                              child: OrdersFilterForm(
                                filters: _filters,
                                showCustomer: viewer.isStaff,
                                onChanged: _setFilters,
                              ),
                            ),
                          ),
                        ],
                      )
                    : content,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    AppLocalizations l10n,
    OrdersListState state,
    OrdersViewer viewer,
    WindowClass wc, {
    required bool offline,
  }) {
    final bool wide = wc == WindowClass.expanded || wc == WindowClass.large;
    switch (state.phase) {
      case OrdersListPhase.loading:
        return ListView(
          key: const ValueKey<String>('orders-skeleton'),
          physics: const NeverScrollableScrollPhysics(),
          children: <Widget>[
            for (int i = 0; i < 6; i++) _SkeletonRow(height: wide ? 48 : (wc == WindowClass.medium ? 56 : 72)),
          ],
        );
      case OrdersListPhase.error:
        return ErrorState.fullScreen(
          key: const ValueKey<String>('orders-error'),
          title: l10n.orders_load_failed,
          message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(state.failure ?? const UnknownFailure())),
          requestId: state.failure?.requestId,
          onRetry: () => unawaited(_list.reload()),
        );
      case OrdersListPhase.empty:
        return RefreshIndicator(
          onRefresh: _list.refresh,
          child: LayoutBuilder(
            builder: (BuildContext ctx, BoxConstraints box) => SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: Center(child: _empty(l10n, viewer)),
              ),
            ),
          ),
        );
      case OrdersListPhase.ready:
        final bool canPrint = viewer.canPrint && wide && ref.watch(orderDocumentPrinterProvider) != null;
        final int extra = state.hasMore || state.loadMoreFailure != null ? 1 : 0;
        final Widget listView = ListView.builder(
          key: const ValueKey<String>('orders-list'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: state.items.length + extra,
          itemBuilder: (BuildContext ctx, int i) {
            if (i >= state.items.length) return _footer(l10n, state);
            final OrderSummary o = state.items[i];
            return wide
                ? OrdersTableRow(
                    key: ValueKey<String>('order-row-${o.id}'),
                    order: o,
                    onTap: () => unawaited(_open(o.id)),
                    printEnabled: !offline && OrderViewRules.rowPrintEnabled(o),
                    onPrint: canPrint ? (BuildContext anchor) => unawaited(_printFromRow(anchor, o, viewer)) : null,
                  )
                : Column(
                    key: ValueKey<String>('order-row-${o.id}'),
                    children: <Widget>[
                      OrdersListRow(order: o, dense: wc == WindowClass.medium, onTap: () => unawaited(_open(o.id))),
                      Divider(height: 1, thickness: 1, color: context.colors.border),
                    ],
                  );
          },
        );
        return RefreshIndicator(
          onRefresh: _list.refresh,
          child: wide
              ? Column(
                  children: <Widget>[
                    OrdersTableHeader(withDocuments: canPrint),
                    Expanded(child: listView),
                  ],
                )
              : listView,
        );
    }
  }

  Widget _footer(AppLocalizations l10n, OrdersListState state) {
    if (state.loadMoreFailure != null) {
      return Padding(
        padding: EdgeInsets.all(context.space.s2),
        child: ErrorState.inline(
          key: const ValueKey<String>('orders-load-more-error'),
          message: l10n.orders_load_failed,
          onRetry: () => unawaited(_list.loadMore()),
        ),
      );
    }
    // Конец списка в видимой области без прокрутки — подгрузить.
    if (!state.loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_list.loadMore());
      });
    }
    return const Column(
      key: ValueKey<String>('orders-load-more'),
      children: <Widget>[_SkeletonRow(height: 56), _SkeletonRow(height: 56)],
    );
  }

  Widget _empty(AppLocalizations l10n, OrdersViewer viewer) {
    final String q = _filters.q;
    void reset() {
      _search.clear();
      _setFilters(OrdersFilters.defaults(_now).copyWith(mine: _filters.mine));
    }

    if (q.isNotEmpty) {
      return EmptyState(
        key: const ValueKey<String>('orders-empty-search'),
        variant: EmptyStateVariant.search,
        title: l10n.orders_empty_search_title(q),
        body: l10n.orders_empty_search_body,
        actionLabel: l10n.orders_reset_filters,
        onAction: reset,
      );
    }
    if (_filters.differsFromDefaults(_now)) {
      return EmptyState(
        key: const ValueKey<String>('orders-empty-filtered'),
        variant: EmptyStateVariant.search,
        title: l10n.orders_empty_filtered_title,
        actionLabel: l10n.orders_reset_filters,
        onAction: reset,
      );
    }
    return EmptyState(
      key: const ValueKey<String>('orders-empty'),
      variant: EmptyStateVariant.orders,
      title: l10n.orders_empty_no_orders_title,
      actionLabel: viewer.canCreateOrder ? l10n.orders_empty_create : null,
      onAction: viewer.canCreateOrder
          ? () => context.ordersGo(
              context.windowClass == WindowClass.compact ? OrdersLocations.cart : OrdersLocations.catalog,
            )
          : null,
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow({required this.height});

  final double height; // money-double: allow — высота строки (lp)

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
      child: Row(
        children: <Widget>[
          if (height >= 72) ...<Widget>[const SkeletonBox.avatar(), SizedBox(width: context.space.s3)],
          const Expanded(child: SkeletonBox.text()),
          SizedBox(width: context.space.s6),
          const SkeletonBox.text(width: 96),
        ],
      ),
    ),
  );
}
