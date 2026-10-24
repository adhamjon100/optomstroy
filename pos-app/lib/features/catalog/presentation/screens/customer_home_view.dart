// SCR-50 «Главный экран клиента» (`/home?view=&sort=`, только `customer`; 02 ч. E SCR-50, ядро v1.9 §24.2;
// RM-E-017). Содержимое экрана — часть фичи catalog (06 MOD-029: SCR-50 использует её провайдеры и
// карточки); фича home получает его через порт `customerHomeBodyProvider` (EQ-FEF-07, EQ-HOME-01).
//
// Раскладка D-18 (02 SCR-50.2, SCR-50.12):
// - compact — шапка 56 (логотип · поиск · колокольчик-точка) + `SearchBar` без камеры → баннер привязки →
//   «Мой кабинет» (лента карточек 140×96) → «Ваш вид цены» → категории `CategoryTile` 3 колонки →
//   «Недавние товары» → сетка товаров 2 колонки → `CartFab`; BNB — оболочка `AppShell`;
// - medium — шапка 64, колонка категорий 240 (`CatalogSidebar`) + контент (сетка 3 колонки), `CartFab`;
// - expanded — шапка 72 с кнопкой корзины и бейджем, SB 240 + контент (1280 lp → 5 колонок), без
//   постоянной корзины.
// Цены — как отдаёт сервер (вид цены клиента; `priceListId` не передаётся — CUST-021); наличие — по
// `customer_stock_display` (`status` — `StockBadge` без чисел; `quantity` — доступное количество без
// «остатка» и «резерва»; CUST-022). Таблицы складов, сканера, кассовых/отчётных/админ-разделов нет.
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/catalog_paths.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_list_controller.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/providers/category_tree_provider.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';
import 'package:optomstroy/features/catalog/presentation/state/search_input_policy.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/back_to_exit_scope.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_card_mapper.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_formats.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logo.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logout.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_product_view.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_sidebar.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_toolbar.dart';

/// Ключи элементов SCR-50 для тестов.
abstract final class CustomerHomeKeys {
  static const Key root = ValueKey<String>('scr-50');
  static const Key header = ValueKey<String>('home-header');
  static const Key linkBanner = ValueKey<String>('home-link-banner');
  static const Key cabinet = ValueKey<String>('home-cabinet');
  static const Key orders = ValueKey<String>('home-cabinet-orders');
  static const Key debt = ValueKey<String>('home-cabinet-debt');
  static const Key favorites = ValueKey<String>('home-cabinet-favorites');
  static const Key priceList = ValueKey<String>('home-price-list');
  static const Key categories = ValueKey<String>('home-categories');
  static const Key sidebar = ValueKey<String>('home-sidebar');
  static const Key recent = ValueKey<String>('home-recent');
  static const Key cartFab = ValueKey<String>('home-cart-fab');
  static const Key cartButton = ValueKey<String>('home-cart-button');
  static const Key serviceUnavailable = ValueKey<String>('home-service-unavailable');
  static const Key offlineBanner = ValueKey<String>('home-offline-banner');
}

/// Содержимое SCR-50 (подставляется в `CustomerHomeScreen` фичи home).
class CustomerHomeView extends ConsumerStatefulWidget {
  const CustomerHomeView({super.key, this.view, this.sort});

  /// Вид из маршрута: `grid|list|compact`.
  final String? view;

  /// Сортировка из маршрута — значение API.
  final String? sort;

  @override
  ConsumerState<CustomerHomeView> createState() => _CustomerHomeViewState();
}

class _CustomerHomeViewState extends ConsumerState<CustomerHomeView> {
  static const Duration _navLockDuration = Duration(milliseconds: 300);

  /// Баннер привязки закрыт крестиком — до следующего запуска (02 UI-50-003).
  static bool _linkBannerDismissed = false;

  ProductViewMode? _view;
  CatalogSort? _sort;
  final Map<String, bool> _favoriteOverrides = <String, bool>{};
  final TextEditingController _searchText = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'home-search');
  final ScrollController _scroll = ScrollController();
  late final SearchInputController _input;
  DateTime _navLockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _clearingRecent = false;

  @override
  void initState() {
    super.initState();
    _view = ProductViewMode.tryParse(widget.view);
    _sort = _parseSort(widget.sort);
    _input = SearchInputController(onQuery: _onQuery);
  }

  @override
  void didUpdateWidget(CustomerHomeView old) {
    super.didUpdateWidget(old);
    if (widget.view != old.view) {
      _view = ProductViewMode.tryParse(widget.view) ?? _view;
    }
    if (widget.sort != old.sort) {
      _sort = _parseSort(widget.sort) ?? _sort;
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  static CatalogSort? _parseSort(String? raw) {
    final CatalogSort? s = CatalogSort.tryParse(raw);
    return s != null && s.forCatalog ? s : null;
  }

  CatalogSort get _effectiveSort => _sort ?? CatalogDefaults.catalogSort;

  /// Вид по умолчанию на SCR-50 — сетка карточек на всех классах окна (02 SCR-50.2).
  ProductViewMode get _effectiveView => _view ?? ProductViewMode.grid;

  /// Каталог клиента: без `priceListId` и склада — их определяет сервер (CUST-021, 08 §3.6).
  CatalogListKey get _listKey => CatalogListKey.catalog(filter: const CatalogFilter(), sort: _effectiveSort);

  GoRouter? get _router => GoRouter.maybeOf(context);

  // ---------------------------------------------------------------- навигация

  bool _navLocked() {
    final DateTime now = DateTime.now();
    if (now.isBefore(_navLockedUntil)) {
      return true;
    }
    _navLockedUntil = now.add(_navLockDuration);
    return false;
  }

  void _push(String location) {
    if (_navLocked()) {
      return;
    }
    final GoRouter? r = _router;
    if (r != null) {
      unawaited(r.push<Object?>(location));
    }
  }

  /// Переход с переключением ветки оболочки («Мой кабинет», избранное, корзина).
  void _go(String location) {
    if (!_navLocked()) {
      _router?.go(location);
    }
  }

  void _writeLocation() {
    final GoRouter? r = _router;
    if (r == null) {
      return;
    }
    final String location = CatalogPaths.home(view: _view?.value, sort: _sort?.value);
    if (r.routeInformationProvider.value.uri.toString() != location) {
      r.go(location);
    }
  }

  void _openProduct(ProductSummary p) =>
      _push(CatalogPaths.product(p.id, variantId: p.hasVariants ? null : p.defaultVariantId));

  void _openCategory(Category c) => _push(CatalogPaths.category(c.id));

  void _toTop() {
    if (!_scroll.hasClients) {
      return;
    }
    final Duration d = context.motion.of(context.motion.base);
    if (d == Duration.zero) {
      _scroll.jumpTo(0);
    } else {
      unawaited(_scroll.animateTo(0, duration: d, curve: Curves.easeOut));
    }
  }

  // ---------------------------------------------------------------- поиск (UI-50-002)

  /// Ввод ≥ 2 символов (debounce 300 мс) или Enter → SCR-11; штрихкод ищется тем же поиском (D-31).
  void _onQuery(String q) {
    ref.read(searchHistoryProvider.notifier).add(q);
    _searchText.clear();
    _input.reset('');
    _searchFocus.unfocus();
    _push(CatalogPaths.search(q: q));
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchText.selection = TextSelection(baseOffset: 0, extentOffset: _searchText.text.length);
  }

  // ---------------------------------------------------------------- вид и сортировка

  void _setView(ProductViewMode mode) {
    if (mode == _effectiveView) {
      return;
    }
    setState(() => _view = mode);
    _writeLocation();
  }

  void _setSort(CatalogSort sort) {
    if (sort == _effectiveSort) {
      return;
    }
    setState(() => _sort = sort);
    _writeLocation();
  }

  // ---------------------------------------------------------------- избранное, корзина, недавние

  Future<void> _toggleFavorite(ProductSummary p, bool value) async {
    final CatalogShelfPort? port = ref.read(catalogShelfPortProvider);
    if (port == null) {
      return;
    }
    final AppLocalizations l10n = AppLocalizations.of(context);
    setState(() => _favoriteOverrides[p.id] = value);
    final Result<void> r = await port.setFavorite(p.id, favorite: value);
    if (!mounted) {
      return;
    }
    if (r is FailureResult<void>) {
      setState(() => _favoriteOverrides[p.id] = !value);
      final (String msg, String? action) = CatalogFormats.splitAction(l10n.catalog_favorite_error);
      AppSnackbar.show(
        context,
        message: msg,
        variant: AppSnackbarVariant.error,
        actionLabel: action,
        onAction: () => unawaited(_toggleFavorite(p, value)),
      );
      return;
    }
    final (String msg, String? action) = CatalogFormats.splitAction(
      value ? l10n.catalog_favorite_added : l10n.catalog_favorite_removed,
    );
    AppSnackbar.show(context, message: msg, actionLabel: action, onAction: () => unawaited(_toggleFavorite(p, !value)));
  }

  /// «+ Добавить» (UI-50-009): корзина клиента — тот же порт, что у SCR-10; цену клиент не передаёт
  /// (SRC-C-114). Без порта и для товара с вариантами — карточка SCR-14 (там черновик корзины).
  Future<void> _onCardAction(ProductSummary p) async {
    final CatalogCartPort? cart = ref.read(catalogCartPortProvider);
    if (p.hasVariants || cart == null) {
      _openProduct(p);
      return;
    }
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Result<void> r = await cart.add(p);
    if (!mounted) {
      return;
    }
    if (r case FailureResult<void>(:final failure)) {
      AppSnackbar.show(
        context,
        message: cart.rejectionText(failure, l10n) ?? l10n.error_internal,
        variant: AppSnackbarVariant.error,
      );
    } else {
      final (String msg, String? action) = CatalogFormats.splitAction(l10n.catalog_added_snackbar);
      AppSnackbar.show(context, message: msg, actionLabel: action, onAction: () => _go(CatalogPaths.cart));
    }
  }

  /// «Очистить» недавние (UI-50-010): `ConfirmDialog` → `DELETE /catalog/products/recent`; повтор во время
  /// запроса игнорируется (SCR-50.11).
  Future<void> _clearRecent() async {
    final CatalogShelfPort? port = ref.read(catalogShelfPortProvider);
    if (port == null || _clearingRecent) {
      return;
    }
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.catalog_recent_clear_confirm_title,
      message: l10n.catalog_recent_clear_confirm_body,
      confirmLabel: l10n.home_recent_clear,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _clearingRecent = true);
    final Result<void> r = await port.clearRecent();
    if (!mounted) {
      return;
    }
    setState(() => _clearingRecent = false);
    ref.invalidate(catalogRecentProductsProvider);
    if (r is FailureResult<void>) {
      final (String msg, String? action) = CatalogFormats.splitAction(l10n.catalog_recent_clear_error);
      AppSnackbar.show(
        context,
        message: msg,
        variant: AppSnackbarVariant.error,
        actionLabel: action,
        onAction: () => unawaited(_clearRecent()),
      );
    }
  }

  /// Pull-to-refresh / `F5`: статус привязки и счётчики, категории, первая страница каталога.
  Future<void> _refresh() async {
    ref
      ..invalidate(customerHomeSummaryProvider)
      ..invalidate(catalogRecentProductsProvider);
    await Future.wait(<Future<void>>[
      ref.read(catalogListProvider(_listKey).notifier).reload(),
      ref.read(categoryTreeProvider.notifier).refresh(),
    ]);
  }

  // ---------------------------------------------------------------- UI-50-015

  Future<void> _contactShop() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    List<String> contacts = const <String>[];
    try {
      contacts = <String>[
        for (final SupportContact s in ref.read(publicSettingsProvider).settings.supportContacts ?? const [])
          s.label == null ? s.value : '${s.label}: ${s.value}',
      ];
    } on Object {
      contacts = const <String>[];
    }
    await AppBottomSheet.show<void>(
      context,
      title: l10n.link_contact_shop,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (contacts.isEmpty) Text(l10n.auth_support_fallback, style: context.text.body),
          for (final String line in contacts)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.space.s1),
              child: SelectableText(line, style: context.text.body),
            ),
        ],
      ),
    );
  }

  /// «Выйти» с предупреждением о неотправленных изменениях (FLOW-009.E1).
  Future<void> _logout() => confirmCatalogLogout(context, ref);

  // ---------------------------------------------------------------- построение

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final WindowClass wc = context.windowClass;
    final bool compact = wc == WindowClass.compact;
    final bool expanded = wc == WindowClass.expanded || wc == WindowClass.large;
    final CatalogListKey key = _listKey;
    final CatalogListState list = ref.watch(catalogListProvider(key));
    final bool selfService = ref.watch(catalogCustomerSelfServiceProvider);

    // UI-50-015: режим клиента выключен (`features.customerSelfService=false`) или `403 FORBIDDEN`.
    if (!selfService || list.failure is PermissionFailure) {
      return Scaffold(
        key: CustomerHomeKeys.root,
        backgroundColor: c.background,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(context.space.s4),
              child: EmptyState(
                key: CustomerHomeKeys.serviceUnavailable,
                variant: EmptyStateVariant.noPermission,
                title: l10n.customer_mode_disabled,
                body: l10n.customer_mode_disabled_body,
                actionLabel: l10n.link_contact_shop,
                onAction: () => unawaited(_contactShop()),
                secondaryActionLabel: l10n.profile_logout,
                onSecondaryAction: () => unawaited(_logout()),
              ),
            ),
          ),
        ),
      );
    }

    final OnlineStatus online = ref.watch(catalogOnlineStatusProvider);
    final CatalogShelfPort? shelf = ref.watch(catalogShelfPortProvider);
    final Set<String> favIds = ref.watch(catalogFavoriteIdsProvider).value ?? const <String>{};
    final CategoryTreeState tree = ref.watch(categoryTreeProvider);
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final CustomerHomeSummary? summary = ref.watch(customerHomeSummaryProvider).value;
    final int cartCount = ref.watch(catalogCartDraftCountProvider).value ?? 0;
    final bool offline = list.offline || online == OnlineStatus.offline;

    final CatalogCardContext cardContext = CatalogCardContext(
      l10n: l10n,
      now: now,
      // SCR-50 — только `customer`: числа остатков — строго по `customer_stock_display` (CUST-022).
      role: RoleCode.customer,
      favoriteIds: favIds,
      favoriteOverrides: _favoriteOverrides,
      favoritesEnabled: shelf != null,
      offline: offline,
      customerStockDisplay: ref.watch(catalogCustomerStockDisplayProvider),
    );

    final double side = compact ? context.space.s4 : context.space.s6; // money-double: allow — геометрия UI (lp)

    final List<Widget> header = <Widget>[
      if (_linkBanner(l10n, summary) case final Widget banner) SliverToBoxAdapter(child: banner),
      if (offline)
        SliverToBoxAdapter(
          child: KeyedSubtree(
            key: CustomerHomeKeys.offlineBanner,
            child: OfflineBanner(
              variant: OfflineBannerVariant.offline,
              dataAsOf: list.asOf ?? tree.tree?.asOf,
              now: now,
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(side, context.space.s4, side, 0),
          child: _cabinet(l10n, summary, favoritesCount: shelf == null ? null : favIds.length, offline: offline),
        ),
      ),
      if (_priceListName(list) case final String name)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, context.space.s3, side, 0),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              // UI-50-007: тултип «Цены показаны по вашему виду цены».
              child: AppTooltip(
                message: l10n.home_price_list_tooltip,
                child: StatusChip(
                  key: CustomerHomeKeys.priceList,
                  label: l10n.home_price_list_label(name),
                  variant: StatusChipVariant.priceList,
                ),
              ),
            ),
          ),
        ),
      if (compact) ..._compactCategories(l10n, tree, side),
      if (compact) ..._compactRecent(l10n, side),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(side, context.space.s4, side, context.space.s2),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.catalog_title_all,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (compact ? context.text.title : context.text.h3).copyWith(
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
              ),
              CatalogToolbarControls(
                view: _effectiveView,
                onView: _setView,
                sort: _effectiveSort,
                onSort: _setSort,
                searchMode: false,
                filterCount: 0,
                onFilters: null,
                compact: compact,
                showViewText: wc == WindowClass.large,
              ),
            ],
          ),
        ),
      ),
    ];

    final Widget products = RefreshIndicator(
      color: c.primaryText,
      backgroundColor: c.surface,
      onRefresh: _refresh,
      child: CatalogProductView(
        key: ValueKey<String>('home-list-${key.hashCode}'),
        state: list,
        items: list.items,
        view: _effectiveView,
        windowClass: wc,
        cardContext: cardContext,
        padding: EdgeInsets.fromLTRB(side, 0, side, compact ? 88 : side),
        scrollController: _scroll,
        headerSlivers: header,
        callbacks: CatalogProductCallbacks(
          onOpen: _openProduct,
          onFavorite: (ProductSummary p, bool v) => unawaited(_toggleFavorite(p, v)),
          onAction: (ProductSummary p) => unawaited(_onCardAction(p)),
        ),
        onLoadMore: () => unawaited(ref.read(catalogListProvider(key).notifier).loadMore()),
        onRetry: () => unawaited(ref.read(catalogListProvider(key).notifier).reload()),
        errorTitle: l10n.catalog_error_title,
        empty: EmptyState(
          key: const ValueKey<String>('catalog-empty'),
          variant: EmptyStateVariant.categories,
          title: l10n.catalog_empty_category_title,
          body: l10n.catalog_empty_category_body,
        ),
      ),
    );

    final Widget body;
    if (compact) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(l10n, wc, cartCount),
          Expanded(child: products),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(l10n, wc, cartCount),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  key: CustomerHomeKeys.sidebar,
                  // Как SB SCR-10: 240 до 1280 lp, шире — 292 (03 §7.3; длинные названия категорий — FIX-EF-13).
                  width:
                      MediaQuery.sizeOf(context).width >=
                          1280 // money-double: allow — геометрия UI (lp)
                      ? DsBreakpoints.sidebarWide
                      : DsBreakpoints.sidebarNarrow,
                  decoration: BoxDecoration(
                    color: c.surface,
                    border: Border(right: BorderSide(color: c.border)),
                    boxShadow: context.elevation.e1,
                  ),
                  child: CatalogSidebar(
                    selectedCategoryId: null,
                    onCategory: _openCategory,
                    onFavorites: () => _go(CatalogPaths.favorites),
                    onRecentProduct: (String id) => _push(CatalogPaths.product(id)),
                    onClearRecent: _clearRecent,
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.topStart,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: wc == WindowClass.large
                            ? DsBreakpoints.contentMaxLarge
                            : double.infinity, // money-double: allow — геометрия UI (lp)
                      ),
                      child: products,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // SCR-50.11: «Назад» на корне — выход по двойному нажатию с подсказкой `home_back_to_exit` (Android).
    return BackToExitScope(
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): _focusSearch,
          const SingleActivator(LogicalKeyboardKey.f5): () => unawaited(_refresh()),
        },
        child: Scaffold(
          key: CustomerHomeKeys.root,
          backgroundColor: c.background,
          body: SafeArea(child: body),
          floatingActionButton: !expanded && cartCount > 0 ? _cartFab(l10n, cartCount) : null,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- шапка (UI-50-001, UI-50-002)

  Widget _header(AppLocalizations l10n, WindowClass wc, int cartCount) {
    final int unread = ref.watch(catalogUnreadNotificationsProvider);
    final bool syncError = ref.watch(catalogSyncErrorNotificationProvider);
    final bool compact = wc == WindowClass.compact;
    final bool expanded = wc == WindowClass.expanded || wc == WindowClass.large;
    final Widget bell = NotificationBell(
      unreadCount: unread,
      syncError: syncError,
      variant: compact ? NotificationBellVariant.dot : NotificationBellVariant.header,
      semanticLabel: unread > 0 ? l10n.notifications_bell_a11y(unread) : l10n.notifications_title,
      onPressed: () => _push(CatalogPaths.notifications),
    );
    // Без кнопки камеры: сканер SCR-17 у `customer` закрыт (ядро §9; 02 SCR-17 п. 10).
    final Widget search = CatalogSearchField(
      controller: _searchText,
      focusNode: _searchFocus,
      windowClass: wc,
      onChanged: _input.changed,
      onSubmitted: _input.submit,
    );
    if (compact) {
      return KeyedSubtree(
        key: CustomerHomeKeys.header,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TopAppBarPos(
              variant: TopAppBarVariant.compact,
              windowClass: wc,
              logo: CatalogLogo(markSize: 28, wordmark: false, onTap: _toTop),
              title: l10n.category_breadcrumb_root,
              actions: <Widget>[
                AppIconButton(icon: Icons.search_rounded, semanticLabel: l10n.search_title, onPressed: _focusSearch),
                bell,
              ],
            ),
            ColoredBox(
              color: context.colors.surface,
              child: Padding(
                padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s1, context.space.s4, context.space.s2),
                child: search,
              ),
            ),
          ],
        ),
      );
    }
    return KeyedSubtree(
      key: CustomerHomeKeys.header,
      child: TopAppBarPos(
        windowClass: wc,
        logo: CatalogLogo(onTap: _toTop),
        search: search,
        actions: <Widget>[
          if (expanded && cartCount > 0)
            AppIconButton(
              key: CustomerHomeKeys.cartButton,
              icon: Icons.shopping_cart_outlined,
              semanticLabel: l10n.cart_fab_a11y_nototal(cartCount),
              tooltip: l10n.cart_title,
              onPressed: () => _go(CatalogPaths.cart),
              badge: AppBadge(count: cartCount, tone: AppBadgeTone.cart),
            ),
        ],
        user: bell,
      ),
    );
  }

  Widget _cartFab(AppLocalizations l10n, int count) {
    final DsColors c = context.colors;
    return Semantics(
      button: true,
      // Суммы корзины на этапе E нет — «Открыть корзину, N позиций» (`cart_fab_a11y_nototal`, EQ-HOME-04).
      label: l10n.cart_fab_a11y_nototal(count),
      excludeSemantics: true,
      child: FloatingActionButton(
        key: CustomerHomeKeys.cartFab,
        heroTag: 'home-cart-fab',
        backgroundColor: c.primary,
        foregroundColor: c.onPrimary,
        onPressed: () => _go(CatalogPaths.cart),
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            const Icon(Icons.shopping_cart_outlined),
            PositionedDirectional(
              top: -10,
              end: -12,
              // Контрастный счётчик на заливке `primary` (03 §9.27): `surface`/`primaryText`, не тон `cart`.
              child: AppBadge(count: count, tone: AppBadgeTone.onPrimary),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- баннер привязки (UI-50-003)

  Widget? _linkBanner(AppLocalizations l10n, CustomerHomeSummary? s) {
    if (s == null || _linkBannerDismissed) {
      return null;
    }
    final DsColors c = context.colors;
    final (String text, Color bg, Color fg, IconData icon, bool action) = switch (s.linkStatus) {
      CustomerLinkStatus.proposed => (
        l10n.home_link_proposed(s.linkName ?? ''),
        c.infoContainer,
        c.info,
        Icons.info_outline_rounded,
        true,
      ),
      CustomerLinkStatus.conflict => (
        l10n.home_link_conflict,
        c.warningContainer,
        c.warning,
        Icons.warning_amber_rounded,
        false,
      ),
      CustomerLinkStatus.rejected => (
        l10n.home_link_rejected,
        c.surfaceVariant,
        c.textSecondary,
        Icons.info_outline_rounded,
        false,
      ),
      CustomerLinkStatus.confirmed || null => ('', c.surface, c.textPrimary, Icons.info_outline_rounded, false),
    };
    if (text.isEmpty) {
      return null;
    }
    final double side = // money-double: allow — геометрия UI (lp)
    context.windowClass == WindowClass.compact
        ? context.space.s4
        : context.space.s6;
    return Padding(
      key: CustomerHomeKeys.linkBanner,
      padding: EdgeInsets.fromLTRB(side, context.space.s3, side, 0),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: EdgeInsetsDirectional.fromSTEB(context.space.s3, context.space.s2, context.space.s1, context.space.s2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.all(context.radii.md)),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: fg),
            SizedBox(width: context.space.s2),
            Expanded(
              child: Text(text, style: context.text.label.copyWith(color: c.textPrimary)),
            ),
            if (action)
              TextButton(
                onPressed: () => _push(CatalogPaths.customerLink),
                child: Text(
                  l10n.home_link_proposed_action,
                  style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.primaryText),
                ),
              ),
            AppIconButton(
              icon: Icons.close_rounded,
              small: true,
              semanticLabel: l10n.ds_button_close,
              onPressed: () => setState(() => _linkBannerDismissed = true),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- «Мой кабинет» (UI-50-004…006, 014)

  Widget _cabinet(
    AppLocalizations l10n,
    CustomerHomeSummary? s, {
    required int? favoritesCount,
    required bool offline,
  }) {
    final DsColors c = context.colors;
    final TextStyle number = context.text.title.copyWith(
      fontWeight: FontWeight.w700,
      color: c.textPrimary,
      fontFeatures: DsTypography.numeric,
    );
    final TextStyle caption = context.text.caption.copyWith(color: c.textSecondary);

    final String? ordersText = switch (s) {
      // UI-50-004: заказов в работе нет — «Заказов нет».
      CustomerHomeSummary(activeOrders: 0, hasActiveOrders: false) => l10n.home_my_orders_empty,
      CustomerHomeSummary(:final int activeOrders) => l10n.home_my_orders_active(activeOrders),
      CustomerHomeSummary(hasActiveOrders: true) => l10n.home_my_orders_active_nocount,
      _ => null,
    };
    final Widget orders = _CabinetCard(
      key: CustomerHomeKeys.orders,
      icon: Icons.inventory_2_outlined,
      title: l10n.home_my_orders,
      value: ordersText == null ? null : Text(ordersText, maxLines: 2, style: caption.copyWith(color: c.textPrimary)),
      onTap: () => _go(CatalogPaths.myOrders),
    );

    // «Мой долг»: только при `confirmed`; офлайн скрыт (финансы не кэшируются); до привязки — UI-50-014.
    final Widget? debt;
    if (offline) {
      debt = null;
    } else if (s != null && s.linked) {
      final String? customerId = s.customerId;
      debt = _CabinetCard(
        key: CustomerHomeKeys.debt,
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.home_my_debt,
        value: s.debt == null
            ? Text(l10n.home_my_debt_no_data, maxLines: 2, style: caption)
            : FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: PriceText(amount: s.debt, variant: PriceTextVariant.list),
              ),
        footnote: s.debt != null && s.debtAsOf != null ? l10n.ds_data_as_of(CatalogFormats.time(s.debtAsOf!)) : null,
        onTap: customerId == null ? null : () => _go(CatalogPaths.receivables(customerId)),
      );
    } else {
      debt = _CabinetCard(
        key: CustomerHomeKeys.debt,
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.home_my_debt,
        value: Text(l10n.home_my_debt_unavailable, maxLines: 3, style: caption),
      );
    }

    final Widget favorites = _CabinetCard(
      key: CustomerHomeKeys.favorites,
      icon: Icons.star_outline_rounded,
      title: l10n.home_favorites,
      value: favoritesCount == null ? null : Text('$favoritesCount', style: number),
      onTap: () => _go(CatalogPaths.favorites),
    );

    final List<Widget> cards = <Widget>[orders, ?debt, favorites];
    if (context.windowClass == WindowClass.compact) {
      return SizedBox(
        key: CustomerHomeKeys.cabinet,
        height: 96,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          itemCount: cards.length,
          separatorBuilder: (BuildContext context, int i) => SizedBox(width: context.space.s3),
          itemBuilder: (BuildContext context, int i) => SizedBox(width: 140, child: cards[i]),
        ),
      );
    }
    return SizedBox(
      key: CustomerHomeKeys.cabinet,
      height: 96,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < cards.length; i++) ...<Widget>[
            if (i > 0) SizedBox(width: context.space.s3),
            Expanded(child: cards[i]),
          ],
        ],
      ),
    );
  }

  /// Вид цены клиента (UI-50-007) — из ответа каталога (`price.priceListName`), его выбирает сервер.
  static String? _priceListName(CatalogListState list) {
    for (final ProductSummary p in list.items) {
      final String? name = p.price?.priceListName;
      if (name != null && name.trim().isNotEmpty) {
        return name.trim();
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- compact: категории и недавние

  List<Widget> _compactCategories(
    AppLocalizations l10n,
    CategoryTreeState tree,
    double /* money-double: allow — геометрия UI */ side,
  ) {
    final List<Category> roots = tree.tree?.roots ?? const <Category>[];
    final bool loading = tree.tree == null && tree.loading;
    if (!loading && roots.isEmpty) {
      return const <Widget>[];
    }
    final double gap = context.space.s3; // money-double: allow — геометрия UI (lp)
    return <Widget>[
      SliverPadding(
        key: CustomerHomeKeys.categories,
        padding: EdgeInsets.fromLTRB(side, context.space.s4, side, 0),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            mainAxisExtent: 148,
          ),
          delegate: SliverChildListDelegate(<Widget>[
            if (loading)
              for (int i = 0; i < 3; i++) const SkeletonBox(height: 148)
            else
              for (final Category cat in roots)
                CategoryTile(
                  key: ValueKey<String>('home-category-${cat.id}'),
                  label: cat.name,
                  countLabel: '${cat.productCount}',
                  imageUrl: cat.imageUrl,
                  iconKey: cat.iconKey,
                  semanticLabel: l10n.category_tile_a11y(cat.productCount, cat.name),
                  onTap: () => _openCategory(cat),
                ),
          ]),
        ),
      ),
    ];
  }

  List<Widget> _compactRecent(AppLocalizations l10n, double /* money-double: allow — геометрия UI */ side) {
    if (ref.watch(catalogShelfPortProvider) == null) {
      return const <Widget>[];
    }
    final List<RecentProduct> recent = ref.watch(catalogRecentProductsProvider).value ?? const <RecentProduct>[];
    if (recent.isEmpty) {
      return const <Widget>[];
    }
    final CatalogCardContext ctx = CatalogCardContext(
      l10n: l10n,
      now: ref.watch(clockProvider).nowUtc(),
      role: RoleCode.customer,
      customerStockDisplay: ref.watch(catalogCustomerStockDisplayProvider),
    );
    final DsColors c = context.colors;
    return <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          key: CustomerHomeKeys.recent,
          padding: EdgeInsets.fromLTRB(side, context.space.s4, side, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AppSectionHeader(
                title: l10n.home_recent_title,
                actionLabel: l10n.home_recent_clear,
                onAction: _clearingRecent ? null : () => unawaited(_clearRecent()),
                padding: EdgeInsets.zero,
              ),
              SizedBox(height: context.space.s2),
              SizedBox(
                height: 66,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: recent.length,
                  separatorBuilder: (BuildContext context, int i) => SizedBox(width: context.space.s2),
                  itemBuilder: (BuildContext context, int i) {
                    final ProductSummary p = recent[i].product;
                    final ProductCardData data = CatalogCardMapper.map(ctx, p);
                    return Container(
                      key: ValueKey<String>('home-recent-${p.id}'),
                      width: 280,
                      decoration: BoxDecoration(
                        border: Border.all(color: c.border),
                        borderRadius: BorderRadius.all(context.radii.md),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: ProductCardCompact(
                        data: data.copyWithHiddenAction(),
                        variant: ProductCardCompactVariant.strip,
                        callbacks: ProductCardCallbacks(onOpen: () => _openProduct(p)),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }
}

/// Карточка ленты «Мой кабинет» 140×96 (`surface`, `ds.radius.md`; 02 UI-50-004…006).
class _CabinetCard extends StatelessWidget {
  const _CabinetCard({super.key, required this.icon, required this.title, this.value, this.footnote, this.onTap});

  final IconData icon;
  final String title;
  final Widget? value;
  final String? footnote;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      button: onTap != null,
      container: true,
      child: DsInteractive(
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) => Container(
          padding: EdgeInsets.all(context.space.s3),
          decoration: BoxDecoration(
            color: s.hovered || s.pressed ? c.surfaceHover : c.surface,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.all(context.radii.md),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(icon, size: 20, color: c.primaryText),
                  SizedBox(width: context.space.s2),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              ?value,
              if (footnote != null)
                Text(
                  footnote!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.micro.copyWith(color: c.textTertiary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Лента «Недавние» — только открыть карточку (без контролов корзины в строке 48).
extension on ProductCardData {
  ProductCardData copyWithHiddenAction() => ProductCardData(
    id: id,
    name: name,
    skuLabel: skuLabel,
    skuMissing: skuMissing,
    variantsLabel: variantsLabel,
    imageUrl: imageUrl,
    thumbUrl: thumbUrl,
    price: price,
    pricePrefix: pricePrefix,
    priceUnit: priceUnit,
    priceMissingLabel: priceMissingLabel,
    unitLabel: unitLabel,
    stockLevel: stockLevel,
    stockLabel: stockLabel,
    stockAsOf: stockAsOf,
    isFavorite: isFavorite,
    favoriteLabel: favoriteLabel,
    showFavorite: false,
    semanticLabel: semanticLabel,
  );
}
