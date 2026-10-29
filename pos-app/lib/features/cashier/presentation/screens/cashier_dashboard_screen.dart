// SCR-30 «Дашборд кассира» (`/cashier`; главный экран `cashier`; `senior_seller` — полный; `admin`, `owner` —
// просмотр без кассовых действий). Владелец реализации — агент G-fe-cashier (RM-G-007). Имя класса и конструктор
// фиксированы маршрутом (routes.dart).
//
// Раскладка — 02 SCR-30.2: compact — одна колонка (Z1 → Z2 → Z4 → Z3 → Z5 → Z6 → Z7 → Z8), pull-to-refresh;
// medium — 2 колонки (Z2, Z3, Z4 | Z5, Z6, Z7, Z8); expanded — 3 колонки (Z2 + Z3 + Z4 | Z5 | Z6 + Z7 + Z8);
// large — контент ≤ 1200. Обновление — при открытии, возврате на экран и каждые 60 с (не в фоне и не при
// блокировке; один запрос одновременно); F5 — обновить, F2 — поиск клиента, F7 — «Принять оплату», Ctrl+K — лист
// «Найти заказ». Финансовые данные — только память (CASH-015).
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/awaiting_payment_list.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/shift_summary_card.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/cashier/cashier_providers.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/cashier/presentation/cashier_format.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/cashier/presentation/state/cashier_dashboard_controller.dart';
import 'package:optomstroy/features/cashier/presentation/state/unfinished_operations.dart';
import 'package:optomstroy/features/cashier/presentation/widgets/cashier_sheets.dart';
import 'package:optomstroy/features/cashier/presentation/widgets/dashboard_sections.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// SCR-30. Дашборд кассира `/cashier` (главный для `cashier`; `admin`/`owner` — просмотр без кассовых кнопок).
class CashierDashboardScreen extends ConsumerStatefulWidget {
  /// Экран SCR-30.
  const CashierDashboardScreen({super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-30';

  /// Ключ корня экрана (тесты маршрутов).
  static const ValueKey<String> rootKey = ValueKey<String>('stub-SCR-30');

  /// Заголовок раздела «Касса» на medium и шире (тесты).
  static const ValueKey<String> titleKey = ValueKey<String>('cashier-page-title');

  @override
  ConsumerState<CashierDashboardScreen> createState() => _CashierDashboardScreenState();
}

class _CashierDashboardScreenState extends ConsumerState<CashierDashboardScreen> with WidgetsBindingObserver {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _poll;
  Timer? _clock;
  bool _tooShort = false;
  bool _lookupOpen = false;
  bool _navigating = false;
  bool _foreground = true;

  CashierDashboardController get _ctl => ref.read(cashierDashboardControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_ctl.load());
      _restartPoll();
    });
    _scheduleClock();
  }

  /// Перерисовка по времени: таймеры TTL QR в «Ожидают оплаты» (UI-30-004) — раз в секунду, пока в `qrPending` есть
  /// показанный QR (`qr_shown`), иначе — по границе следующей минуты (относительное время в списках). Часы и дата
  /// шапки (UI-30-013) на medium и шире — в шапке оболочки (`StaffShellHeader`, свой таймер по границе минуты).
  void _scheduleClock() {
    _clock?.cancel();
    final PosDashboard? d = ref.read(cashierDashboardControllerProvider).dashboard;
    final bool qrShown = d != null && d.qrPending.any((Payment p) => p.status == PaymentStatus.qrShown);
    final int ms = ref.read(clockProvider).nowUtc().millisecondsSinceEpoch;
    final Duration delay = qrShown
        ? const Duration(seconds: 1)
        : Duration(milliseconds: Duration.millisecondsPerMinute - ms % Duration.millisecondsPerMinute);
    _clock = Timer(delay, () {
      if (!mounted) return;
      setState(() {});
      _scheduleClock();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(_ctl.load());
    }
    _restartPoll();
  }

  void _restartPoll() {
    _poll?.cancel();
    _poll = null;
    final Duration? period = ref.read(cashierDashboardPollProvider);
    if (period == null || !_foreground || ref.read(cashierSessionLockedProvider)) return;
    _poll = Timer.periodic(period, (_) {
      if (mounted && _foreground && !ref.read(cashierSessionLockedProvider)) unawaited(_ctl.load());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _clock?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  DateTime get _now => ref.read(clockProvider).nowUtc();

  // ---------------------------------------------------------------------------------------------------------------
  // Переходы.

  Future<void> _push(String location) async {
    if (_navigating) return;
    _navigating = true;
    try {
      await context.cashierPush(location);
    } finally {
      _navigating = false;
    }
    if (mounted) unawaited(_ctl.load());
  }

  void _go(String location) => context.cashierGo(location);

  void _submitSearch(String text) {
    final String q = text.trim();
    if (q.length < 2) {
      setState(() => _tooShort = true);
      return;
    }
    setState(() => _tooShort = false);
    _go(CashierLocations.customers(q));
  }

  Future<void> _openLookup({CashierLookupMode mode = CashierLookupMode.payment}) async {
    if (_lookupOpen) return;
    _lookupOpen = true;
    final CashierLookupResult? r = await showCashierLookup(
      context,
      mode: mode,
      debtTab: ref.read(debtPaymentsFromPosProvider),
    );
    _lookupOpen = false;
    if (r == null || !mounted) return;
    switch (r) {
      case LookupOrder(:final String orderId):
        await _push(
          mode == CashierLookupMode.payment ? CashierLocations.payOrder(orderId) : CashierLocations.returnNew(orderId),
        );
      case LookupCustomer(:final String customerId):
        await _push(CashierLocations.payDebt(customerId));
    }
  }

  Future<void> _favoriteMenu(Customer c, Offset? position, RoleCode? role) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final RenderBox overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final Offset at = position ?? overlay.size.center(Offset.zero);
    final bool debt = CashierRoles.canAcceptPayment(role) && c.onecRef != null && ref.read(debtPaymentsFromPosProvider);
    final String? choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'open', child: Text(l10n.ds_button_open)),
        if (debt) PopupMenuItem<String>(value: 'debt', child: Text(l10n.cashier_action_accept_payment)),
        if (CashierRoles.canManageFavorites(role))
          PopupMenuItem<String>(
            key: const ValueKey<String>('cashier-favorite-remove'),
            value: 'remove',
            child: Text(l10n.favorites_star_remove_tooltip),
          ),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'open':
        _go(CashierLocations.customer(c.id));
      case 'debt':
        await _push(CashierLocations.payDebt(c.id));
      case 'remove':
        await _removeFavorite(c);
    }
  }

  Future<void> _removeFavorite(Customer c) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Failure? f = await _ctl.removeFavorite(c.id);
    if (!mounted) return;
    if (f != null) {
      AppSnackbar.show(
        context,
        message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(f)),
        variant: AppSnackbarVariant.error,
      );
      return;
    }
    AppSnackbar.show(
      context,
      message: l10n.cashier_favorite_removed,
      actionLabel: l10n.ds_button_undo,
      onAction: () => unawaited(_ctl.restoreFavorite(c.id)),
    );
  }

  /// `isStale` сущности `receivables` из `GET /sync/status` (порог — серверная настройка); `null` — нет данных.
  static bool? _receivablesStale(SyncServerStatus? status) {
    if (status == null) return null;
    for (final SyncServerEntity e in status.entities) {
      if (e.entityValue == SyncEntity.receivables.value) return e.isStale;
    }
    return null;
  }

  /// Меню аватара шапки (UI-30-013): Профиль, Настройки, Заблокировать, Выйти.
  Future<void> _profileMenu(BuildContext anchor) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final RenderBox box = anchor.findRenderObject()! as RenderBox;
    final RenderBox overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final Offset bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
    final VoidCallback? lock = ref.read(cashierLockProvider);
    final CashierLogout? logout = ref.read(cashierLogoutProvider);
    final String? picked = await showMenu<String>(
      context: context,
      color: context.colors.surface,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 240),
      position: RelativeRect.fromLTRB(bottomRight.dx - 240, bottomRight.dy + 4, overlay.size.width - bottomRight.dx, 0),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          key: const ValueKey<String>('cashier-menu-profile'),
          value: CashierLocations.profile,
          height: 44,
          child: Text(l10n.profile_title),
        ),
        PopupMenuItem<String>(
          key: const ValueKey<String>('cashier-menu-settings'),
          value: CashierLocations.settings,
          height: 44,
          child: Text(l10n.profile_menu_settings),
        ),
        if (lock != null)
          PopupMenuItem<String>(
            key: const ValueKey<String>('cashier-menu-lock'),
            value: _menuLock,
            height: 44,
            child: Text(l10n.profile_menu_lock),
          ),
        if (logout != null)
          PopupMenuItem<String>(
            key: const ValueKey<String>('cashier-menu-logout'),
            value: _menuLogout,
            height: 44,
            child: Text(l10n.profile_logout),
          ),
      ],
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case _menuLock:
        lock?.call();
      case _menuLogout:
        await logout?.call(context, ref);
      default:
        _go(picked);
    }
  }

  static const String _menuLock = 'lock';
  static const String _menuLogout = 'logout';

  String _unfinishedDescription(AppLocalizations l10n, UnfinishedOperation op) => switch (op.kind) {
    UnfinishedKind.orderPayment => l10n.cashier_unfinished_desc_order(
      op.amount == null ? '' : CashierFormat.money(op.amount!),
      op.orderNumber ?? '',
    ),
    UnfinishedKind.confirmManual => l10n.cashier_unfinished_desc_confirm(op.orderNumber ?? ''),
    UnfinishedKind.voidPayment => l10n.cashier_unfinished_desc_void(op.orderNumber ?? ''),
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Разметка.

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CashierDashboardState s = ref.watch(cashierDashboardControllerProvider);
    // Появился/пропал показанный QR — период часов меняется сразу (1 с ↔ граница минуты).
    ref.listen<bool>(
      cashierDashboardControllerProvider.select(
        (CashierDashboardState x) =>
            x.dashboard?.qrPending.any((Payment p) => p.status == PaymentStatus.qrShown) ?? false,
      ),
      (bool? prev, bool next) {
        if (prev != next) _scheduleClock();
      },
    );
    final RoleCode? role = ref.watch(cashierViewerRoleProvider);
    final bool online = ref.watch(cashierOnlineProvider) && !s.offline;
    final WindowClass wc = context.windowClass;
    ref.listen<bool>(cashierSessionLockedProvider, (bool? a, bool b) => _restartPoll());
    final DsColors c = context.colors;
    final bool canPay = CashierRoles.canAcceptPayment(role);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f5): () => unawaited(_ctl.load()),
        const SingleActivator(LogicalKeyboardKey.f2): _searchFocus.requestFocus,
        if (canPay) const SingleActivator(LogicalKeyboardKey.f7): () => unawaited(_openLookup()),
        if (canPay) const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => unawaited(_openLookup()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: CashierDashboardScreen.rootKey,
          backgroundColor: c.background,
          // medium+ — шапку даёт оболочка (`StaffShellHeader`, ADR-112): своя шапка только на compact.
          appBar: wc == WindowClass.compact ? _header(context, l10n, s, wc) : null,
          body: Column(
            children: <Widget>[
              if (!online && s.dashboard != null)
                OfflineBanner(variant: OfflineBannerVariant.offline, dataAsOf: s.fetchedAt, now: _now),
              Expanded(child: _body(context, l10n, s, role, online, wc)),
            ],
          ),
        ),
      ),
    );
  }

  /// Шапка compact (на medium+ шапку даёт оболочка): логотип, заголовок, синхронизация, аватар, колокольчик.
  PreferredSizeWidget _header(BuildContext context, AppLocalizations l10n, CashierDashboardState s, WindowClass wc) {
    final int unread = s.dashboard?.notificationsUnread ?? 0;
    final DashboardSyncOverall? overall = s.dashboard?.sync.overall;
    final RoleCode? role = ref.watch(cashierViewerRoleProvider);
    final String roleText = CashierRoles.label(l10n, role);
    final String? name = ref.watch(cashierViewerNameProvider);
    final WidgetBuilder? logo = ref.watch(cashierLogoProvider);
    final WidgetBuilder? syncIndicator = ref.watch(cashierSyncIndicatorProvider);
    return TopAppBarPos(
      variant: TopAppBarVariant.compact,
      windowClass: wc,
      logo: logo == null ? null : Builder(builder: logo),
      title: l10n.cashier_title,
      actions: <Widget>[
        if (syncIndicator != null)
          KeyedSubtree(
            key: const ValueKey<String>('cashier-header-sync'),
            child: Builder(builder: syncIndicator),
          )
        else if (s.dashboard != null)
          AppIconButton(
            key: const ValueKey<String>('cashier-header-sync'),
            icon: overall == DashboardSyncOverall.ok ? Icons.sync_rounded : Icons.sync_problem_rounded,
            semanticLabel: l10n.cashier_sync_title,
            tooltip: l10n.cashier_sync_title,
            onPressed: () => _go(CashierLocations.sync()),
          ),
        // Пользователь «Имя · Кассир» (AppAvatar + RoleBadge); тап — меню (Профиль, Настройки, Заблокировать, Выйти).
        Builder(
          builder: (BuildContext anchor) => TopAppBarUser(
            key: const ValueKey<String>('cashier-header-user'),
            name: name ?? roleText,
            role: name == null ? '' : roleText,
            // compact: только аватар; имя и роль — в меню и `Semantics`.
            showText: false,
            onTap: () => unawaited(_profileMenu(anchor)),
          ),
        ),
        NotificationBell(
          unreadCount: unread,
          semanticLabel: l10n.notifications_bell_a11y(unread),
          syncError: overall == DashboardSyncOverall.failed,
          onPressed: () => _go(CashierLocations.notifications),
        ),
      ],
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    CashierDashboardState s,
    RoleCode? role,
    bool online,
    WindowClass wc,
  ) {
    switch (s.phase) {
      case CashierDashboardPhase.forbidden:
        return _titled(
          context,
          l10n,
          wc,
          EmptyState(variant: EmptyStateVariant.noPermission, title: l10n.error_forbidden),
        );
      case CashierDashboardPhase.error:
        final UiError e = UiErrorMapper.fromFailure(s.failure ?? const UnknownFailure());
        return _titled(
          context,
          l10n,
          wc,
          ErrorState.fullScreen(
            key: const ValueKey<String>('cashier-error'),
            title: l10n.cashier_load_error,
            message: ErrorTexts.message(l10n, e),
            requestId: e.requestId,
            onRetry: () => unawaited(_ctl.load()),
          ),
        );
      case CashierDashboardPhase.offlineNoData:
        return _titled(
          context,
          l10n,
          wc,
          EmptyState(
            key: const ValueKey<String>('cashier-offline'),
            variant: EmptyStateVariant.offlineNoCache,
            title: l10n.cashier_offline_no_data,
            actionLabel: l10n.ds_button_retry,
            onAction: () => unawaited(_ctl.load()),
            secondaryActionLabel: l10n.cashier_action_catalog,
            onSecondaryAction: () => _go(CashierLocations.catalog),
          ),
        );
      case CashierDashboardPhase.loading:
      case CashierDashboardPhase.ready:
        break;
    }
    final bool loading = s.phase == CashierDashboardPhase.loading;
    final PosDashboard? d = s.dashboard;
    final DateTime now = _now;
    final bool canPay = CashierRoles.canAcceptPayment(role);
    final bool compact = wc == WindowClass.compact;
    final List<UnfinishedOperation> unfinished = ref.watch(cashierUnfinishedOperationsProvider);

    // Z1.
    final List<Widget> z1 = <Widget>[
      if (s.refreshFailed && s.fetchedAt != null)
        ErrorState.banner(
          key: const ValueKey<String>('cashier-refresh-failed'),
          message: l10n.cashier_refresh_failed(DsBishkekTime.stamp(s.fetchedAt!, now)),
          tone: ErrorStateTone.warning,
          onRetry: () => unawaited(_ctl.load()),
          retrying: s.refreshing,
        ),
      if (d != null && d.sync.overall != DashboardSyncOverall.ok)
        DashboardSyncBanner(
          overall: d.sync.overall,
          status: s.sync,
          onOpen: (String? entity) => _go(CashierLocations.sync(entity: entity)),
        ),
      if (unfinished.isNotEmpty && canPay)
        DashboardUnfinishedBanner(
          description: _unfinishedDescription(l10n, unfinished.last),
          onCheck: () => unawaited(_push(CashierLocations.payOrder(unfinished.last.orderId))),
        ),
    ];

    // Z2.
    final bool returns = ref.watch(publicFeatureFlagsProvider.select((PublicFeatureFlags f) => f.returnsFromPos));
    final Widget z2 = DashboardQuickActions(
      searchController: _search,
      searchFocus: _searchFocus,
      onSearch: _submitSearch,
      onSearchChanged: (_) {
        if (_tooShort) setState(() => _tooShort = false);
      },
      searchTooShort: _tooShort,
      online: online,
      onAcceptPayment: canPay ? () => unawaited(_openLookup()) : null,
      onCatalog: () => _go(CashierLocations.catalog),
      onNewCustomer: CashierRoles.canCreateCustomer(role) ? () => unawaited(_push(CashierLocations.newCustomer)) : null,
      onReturn: CashierRoles.canStartReturn(role) && returns
          ? () => unawaited(_openLookup(mode: CashierLookupMode.returnRequest))
          : null,
      onParked: CashierRoles.canOpenParked(role) ? () => _go(CashierLocations.parked) : null,
    );

    // Z3 (у `owner` не рендерится — FAV-006).
    final Widget? z3 = role == RoleCode.owner
        ? null
        : DashboardFavorites(
            customers: s.favorites,
            loading: loading,
            horizontal: compact,
            onOpen: (Customer cu) => _go(CashierLocations.customer(cu.id)),
            onAll: () => _go(CashierLocations.favoriteCustomers),
            onMenu: (Customer cu, Offset? at) => unawaited(_favoriteMenu(cu, at, role)),
          );

    // Z4.
    final List<Widget> z4 = d == null
        ? const <Widget>[]
        : <Widget>[
            AwaitingPaymentList(
              key: const ValueKey<String>('cashier-awaiting'),
              title: l10n.cashier_awaiting_title(d.awaitingPayment.length),
              compactWindow: compact,
              entries: awaitingEntries(
                l10n,
                d,
                now,
                onTap: canPay && online ? (OrderSummary o) => unawaited(_push(CashierLocations.payOrder(o.id))) : null,
              ),
            ),
            AwaitingPaymentList(
              key: const ValueKey<String>('cashier-review'),
              title: l10n.cashier_review_title(d.manualConfirmCount),
              icon: Icons.warning_amber_rounded,
              compactWindow: compact,
              maxRows: 10,
              entries: reviewEntries(
                l10n,
                d,
                onTap: (Payment p) {
                  final String? tx = p.transactionId;
                  if (tx != null) {
                    _go(CashierLocations.transaction(tx));
                  } else if (p.orderId != null) {
                    _go(CashierLocations.order(p.orderId!));
                  }
                },
              ),
            ),
          ];

    // Z5.
    final DateTime dayFrom = DsBishkekTime.startOfDayUtc(now);
    final DateTime dayTo = DsBishkekTime.endOfDayUtc(now);
    String journal(PaymentMethod? m) => CashierLocations.transactions(
      from: dayFrom,
      to: dayTo,
      kind: m == null ? null : TransactionKind.paymentReceived.value,
      paymentMethod: m?.value,
    );
    final PosDashboardTotals? totals = d?.totals;
    final List<Transaction> recent = d?.recentTransactions ?? const <Transaction>[];
    final Widget z5 = DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ShiftSummaryCard(
            key: const ValueKey<String>('cashier-totals'),
            title: l10n.cashier_totals_title,
            loading: loading,
            trailing: s.fetchedAt == null
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        l10n.cashier_updated_at(DsBishkekTime.time(s.fetchedAt!)),
                        key: const ValueKey<String>('cashier-updated-at'),
                        style: context.text.caption.copyWith(
                          color: context.colors.textSecondary,
                          fontFeatures: DsTypography.numeric,
                        ),
                      ),
                      if (!compact)
                        AppIconButton(
                          key: const ValueKey<String>('cashier-refresh'),
                          icon: Icons.refresh_rounded,
                          semanticLabel: l10n.receivables_refresh,
                          small: true,
                          loading: s.refreshing,
                          onPressed: s.refreshing ? null : () => unawaited(_ctl.load()),
                        ),
                    ],
                  ),
            tiles: <ShiftSummaryTile>[
              ShiftSummaryTile(
                key: const ValueKey<String>('cashier-total-cash'),
                label: l10n.cashier_totals_cash,
                amount: totals?.cash ?? Money.zero,
                onTap: () => _go(journal(PaymentMethod.cash)),
              ),
              ShiftSummaryTile(
                key: const ValueKey<String>('cashier-total-qr'),
                label: l10n.cashier_totals_qr,
                amount: totals?.qr ?? Money.zero,
                onTap: () => _go(journal(PaymentMethod.qrBakai)),
              ),
              ShiftSummaryTile(
                key: const ValueKey<String>('cashier-total-credit'),
                label: l10n.cashier_totals_credit,
                amount: totals?.credit ?? Money.zero,
                onTap: () => _go(journal(PaymentMethod.credit)),
              ),
            ],
            footer: totals == null
                ? null
                : l10n.cashier_totals_counts('${totals.ordersCount}', '${totals.paymentsCount}'),
          ),
          SizedBox(height: context.space.s4),
          AppSectionHeader(title: l10n.cashier_recent_title, padding: EdgeInsets.zero),
          if (loading)
            for (int i = 0; i < 3; i++)
              Padding(
                padding: EdgeInsets.only(top: context.space.s2),
                child: const SkeletonBox(height: 56),
              )
          else if (recent.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.space.s3),
              child: Text(
                l10n.cashier_recent_empty,
                key: const ValueKey<String>('cashier-recent-empty'),
                style: context.text.body.copyWith(color: context.colors.textSecondary),
              ),
            )
          else
            ClipRRect(
              borderRadius: BorderRadius.all(context.radii.sm),
              child: Column(
                children: <Widget>[
                  for (final Transaction t in recent.take(compact ? 5 : 10))
                    recentRow(
                      context,
                      l10n,
                      t,
                      compactWindow: compact,
                      onTap: () => _go(CashierLocations.transaction(t.id)),
                    ),
                ],
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: AppButton(
              key: const ValueKey<String>('cashier-recent-all'),
              label: l10n.cashier_recent_all,
              variant: AppButtonVariant.text,
              trailingIcon: Icons.chevron_right_rounded,
              onPressed: () => _go(journal(null)),
            ),
          ),
        ],
      ),
    );

    // Z6, Z7, Z8.
    final Widget z6 = loading
        ? const DashboardCard(child: SkeletonBox(height: 96))
        : DashboardDebts(
            overdue: d?.overdue ?? const <PosDashboardOverdueItem>[],
            asOf: d?.sync.receivablesAsOf,
            nowUtc: now,
            maxRows: compact ? 3 : 10,
            serverStale: _receivablesStale(s.sync),
            refreshing: s.refreshing,
            onRefresh: online ? () => unawaited(_ctl.load()) : null,
            onOpen: (String id) => _go(CashierLocations.receivables(id)),
            onAll: () =>
                unawaited(OverdueSheet.show(context, onOpen: (String id) => _go(CashierLocations.receivables(id)))),
          );
    final Widget z7 = DashboardDiscounts(
      info: s.rules,
      failed: s.rulesFailed,
      onMore: s.rules == null ? null : () => unawaited(showDiscountRulesSheet(context, s.rules!)),
    );
    final Widget z8 = DashboardSyncCard(
      overall: d?.sync.overall,
      status: s.sync,
      stockAsOf: d?.sync.stockAsOf,
      receivablesAsOf: d?.sync.receivablesAsOf,
      onOpen: () => _go(CashierLocations.sync()),
    );

    final bool narrow = wc == WindowClass.compact;
    final double gap = narrow ? context.space.s4 : context.space.s6; // money-double: allow — отступ, lp
    final double maxContent = wc == WindowClass.large ? 1200 : double.infinity; // money-double: allow — ширина, lp
    Widget column(List<Widget?> items) {
      final List<Widget> list = <Widget>[for (final Widget? w in items) ?w];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < list.length; i++) ...<Widget>[if (i > 0) SizedBox(height: gap), list[i]],
        ],
      );
    }

    final List<Widget> z4Shown = <Widget>[
      if (d != null && d.awaitingPayment.isNotEmpty) z4[0],
      if (d != null && d.manualConfirm.isNotEmpty) z4[1],
    ];
    final Widget content;
    switch (wc) {
      case WindowClass.compact:
        content = column(<Widget?>[...z1, z2, ...z4Shown, z3, z5, z6, z7, z8]);
      case WindowClass.medium:
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _pageTitle(context, l10n),
            if (z1.isNotEmpty) ...<Widget>[column(z1), SizedBox(height: gap)],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: column(<Widget?>[z2, z3, ...z4Shown])),
                SizedBox(width: context.space.s4),
                Expanded(child: column(<Widget?>[z5, z6, z7, z8])),
              ],
            ),
          ],
        );
      case WindowClass.expanded:
      case WindowClass.large:
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _pageTitle(context, l10n),
            if (z1.isNotEmpty) ...<Widget>[column(z1), SizedBox(height: gap)],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: column(<Widget?>[z2, z3, ...z4Shown])),
                SizedBox(width: gap),
                Expanded(child: z5),
                SizedBox(width: gap),
                Expanded(child: column(<Widget?>[z6, z7, z8])),
              ],
            ),
          ],
        );
    }
    final EdgeInsets pad = EdgeInsets.all(compact ? context.space.s4 : context.space.s6);
    final Widget scroll = SingleChildScrollView(
      key: const ValueKey<String>('cashier-scroll'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: pad,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxContent),
          child: content,
        ),
      ),
    );
    return RefreshIndicator(onRefresh: _ctl.load, child: scroll);
  }

  /// Заголовок раздела «Касса» на medium и шире (UI-30-013; паритет функций ADR-112): своей шапки у SCR-30 там нет —
  /// название раздела стоит над сводкой, в стиле заголовка категории каталога (`h1 700`, прототип 2026-10-29).
  Widget _pageTitle(BuildContext context, AppLocalizations l10n) => Padding(
    padding: EdgeInsets.only(bottom: context.space.s4),
    child: Semantics(
      header: true,
      child: Text(
        l10n.cashier_title,
        key: CashierDashboardScreen.titleKey,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.text.h1.copyWith(fontWeight: FontWeight.w700, color: context.colors.textPrimary),
      ),
    ),
  );

  /// Состояние без данных (ошибка, нет прав, офлайн без кэша) — на medium и шире под заголовком раздела.
  Widget _titled(BuildContext context, AppLocalizations l10n, WindowClass wc, Widget child) {
    if (wc == WindowClass.compact) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(context.space.s6, context.space.s6, context.space.s6, 0),
          child: _pageTitle(context, l10n),
        ),
        Expanded(child: child),
      ],
    );
  }
}
