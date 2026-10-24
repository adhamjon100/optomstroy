// Рабочее пространство каталога — общая реализация SCR-10 (корень), SCR-11 (поиск), SCR-12 (категория)
// по 02 ч. B: шапка (зона A), сайдбар (B), заголовок/инструменты/чипы (C), список (D) и CP (E);
// адаптивность D-18: compact — шапка 56 + строка поиска + полоса чипов (нижняя навигация — оболочка),
// medium — шапка 64 + чипы (rail — оболочка), expanded/large — 3 колонки: сайдбар 240/292 · контент
// [+ FilterPanel 320] · CartPanel 320/340. Повтор/«Назад»/перезапуск — 02 SCR-10.11, SCR-11.11, SCR-12.11.
import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/filter_panel.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/layout/content_region.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/presentation/catalog_paths.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_list_controller.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/providers/category_tree_provider.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_filters_screen.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_filter_codec.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';
import 'package:optomstroy/features/catalog/presentation/state/search_input_policy.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/all_categories_sheet.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/back_to_exit_scope.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_card_mapper.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_filter_form.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_formats.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logout.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_product_view.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_search_parts.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_sidebar.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_toolbar.dart';

/// Режим рабочего пространства.
enum CatalogScreenMode {
  /// SCR-10 `/catalog`.
  root,

  /// SCR-12 `/catalog/c/{id}`.
  category,

  /// SCR-11 `/catalog/search?q=`.
  search,
}

/// Склады для секции «Склад» фильтров (`GET /catalog/warehouses`).
final catalogWarehousesProvider = FutureProvider.autoDispose<List<Warehouse>>((ref) async {
  try {
    final Result<List<Warehouse>> r = await ref.read(catalogRepositoryProvider).warehouses();
    return r.valueOrNull ?? const <Warehouse>[];
  } on Object {
    return const <Warehouse>[];
  }
});

/// Фильтр чипов типа совпадения SCR-11 (UI-11-004): локальная фильтрация загруженных страниц.
enum SearchMatchFilter { all, barcode, sku, name }

class CatalogWorkspace extends ConsumerStatefulWidget {
  const CatalogWorkspace({
    super.key,
    required this.mode,
    this.categoryId,
    this.preset,
    this.view,
    this.sort,
    this.f,
    this.q,
  });

  final CatalogScreenMode mode;
  final String? categoryId;
  final String? preset;
  final String? view;
  final String? sort;
  final String? f;
  final String? q;

  @override
  ConsumerState<CatalogWorkspace> createState() => _CatalogWorkspaceState();
}

class _CatalogWorkspaceState extends ConsumerState<CatalogWorkspace> {
  static const Duration _navLockDuration = Duration(milliseconds: 300);

  ProductViewMode? _urlView;
  final Map<WindowClass, ProductViewMode> _prefViews = <WindowClass, ProductViewMode>{};
  CatalogSort? _sort;
  CatalogSort? _prefSort;
  bool _prefsLoaded = false;
  late CatalogFilter _filter;
  late bool _recent;
  bool _sidebarCollapsed = false;
  bool _filterPanelOpen = false;
  bool _showAllBrands = false;
  final Map<String, bool> _favoriteOverrides = <String, bool>{};
  late final TextEditingController _searchText;
  final FocusNode _searchFocus = FocusNode(debugLabel: 'catalog-search');
  late final SearchInputController _input;
  String _activeQuery = '';
  SearchMatchFilter _match = SearchMatchFilter.all;

  /// Область поиска SCR-11, начатого на SCR-12 (UI-11-009): `false` — «В категории …», `true` — «Во всех
  /// категориях». Параметр `categoryId` маршрута не меняется — «Назад» по-прежнему ведёт в категорию.
  bool _searchAllCategories = false;
  late CatalogFilterPriceControllers _price;
  Timer? _panelDebounce;
  CatalogFilter? _panelDraft;
  DateTime _navLockedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _isSearch => widget.mode == CatalogScreenMode.search;

  bool get _isCategory => widget.mode == CatalogScreenMode.category;

  @override
  void initState() {
    super.initState();
    _filter = _decodeFilter();
    _recent = widget.preset == 'recent';
    _sort = _parseSort(widget.sort);
    _urlView = ProductViewMode.tryParse(widget.view);
    _activeQuery = _isSearch ? SearchInputPolicy.normalize(widget.q ?? '') : '';
    _searchText = TextEditingController(text: _isSearch ? (widget.q ?? '') : '');
    _input = SearchInputController(onQuery: _onQuery)..reset(_activeQuery);
    _price = CatalogFilterPriceControllers(_filter);
    unawaited(_loadPrefs());
  }

  @override
  void didUpdateWidget(CatalogWorkspace old) {
    super.didUpdateWidget(old);
    if (_isSearch && widget.q != old.q) {
      final String q = SearchInputPolicy.normalize(widget.q ?? '');
      if (q != _activeQuery) {
        _activeQuery = q;
        _searchText.text = widget.q ?? '';
        _input.reset(q);
        _match = SearchMatchFilter.all;
      }
    }
    if (widget.categoryId != old.categoryId || widget.f != old.f) {
      final CatalogFilter next = _decodeFilter();
      if (!CatalogFilterCodec.same(next, _filter)) {
        _filter = next;
        _price.sync(_filter);
      }
    }
    if (widget.sort != old.sort) {
      final CatalogSort? s = _parseSort(widget.sort);
      if (s != null) {
        _sort = s;
      }
    }
    if (widget.view != old.view) {
      final ProductViewMode? v = ProductViewMode.tryParse(widget.view);
      if (v != null) {
        _urlView = v;
      }
    }
    if (widget.preset != old.preset) {
      _recent = widget.preset == 'recent';
    }
  }

  @override
  void dispose() {
    _panelDebounce?.cancel();
    _input.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    _price.dispose();
    super.dispose();
  }

  CatalogFilter _decodeFilter() =>
      CatalogFilterCodec.decode(widget.f, categoryId: _isCategory ? widget.categoryId : null);

  CatalogSort? _parseSort(String? raw) {
    final CatalogSort? s = CatalogSort.tryParse(raw);
    if (s == null) {
      return null;
    }
    return (_isSearch ? s.forSearch : s.forCatalog) ? s : null;
  }

  Future<void> _loadPrefs() async {
    final CatalogPrefs prefs = ref.read(catalogPrefsProvider);
    final CatalogSort? sort = await prefs.sort(search: _isSearch);
    final bool? collapsed = await prefs.sidebarCollapsed();
    final Map<WindowClass, ProductViewMode> views = <WindowClass, ProductViewMode>{};
    for (final WindowClass wc in WindowClass.values) {
      final ProductViewMode? v = await prefs.viewMode(wc);
      if (v != null) {
        views[wc] = v;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _prefSort = sort != null && (_isSearch ? sort.forSearch : sort.forCatalog) ? sort : null;
      _sidebarCollapsed = collapsed ?? false;
      _prefViews.addAll(views);
      _prefsLoaded = true;
    });
  }

  CatalogSort get _effectiveSort =>
      _sort ?? _prefSort ?? (_isSearch ? CatalogDefaults.searchSort : CatalogDefaults.catalogSort);

  ProductViewMode _effectiveView(WindowClass wc) => _urlView ?? _prefViews[wc] ?? CatalogDefaults.viewFor(wc);

  CatalogListKey? get _listKey {
    if (_isSearch) {
      return SearchInputPolicy.canSearch(_activeQuery)
          ? CatalogListKey.search(q: _activeQuery, filter: _searchFilter, sort: _effectiveSort)
          : null;
    }
    if (_recent) {
      return CatalogListKey.recent(categoryId: _isCategory ? widget.categoryId : null);
    }
    return CatalogListKey.catalog(filter: _filter, sort: _effectiveSort);
  }

  /// Фильтр поиска с областью UI-11-009: поиск с SCR-12 ограничен категорией (с подкатегориями), пока
  /// пользователь не выберет «Во всех категориях».
  CatalogFilter get _searchFilter {
    final String? scope = widget.categoryId;
    if (scope == null || _searchAllCategories) {
      return _filter;
    }
    return rebuildFilter(_filter, categoryId: scope, includeSubcategories: true);
  }

  GoRouter? get _router => GoRouter.maybeOf(context);

  bool get _isCustomer => ref.read(catalogViewerRoleProvider) == RoleCode.customer;

  /// Корень каталога роли: `customer` — SCR-50 `/home` (у клиента нет SCR-10, G-7), staff — `/catalog`.
  String _rootLocation({String? view, String? sort}) =>
      _isCustomer ? CatalogPaths.home(view: view, sort: sort) : CatalogPaths.catalog(view: view, sort: sort);

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
    final GoRouter? r = _router;
    if (r != null) {
      unawaited(r.push<Object?>(location));
    }
  }

  void _go(String location) => _router?.go(location);

  /// Текущий location отражает вид/сортировку/фильтры (navigation.md §3) — замена записи (`go`).
  void _writeLocation() {
    final GoRouter? r = _router;
    if (r == null) {
      return;
    }
    final String? view = _urlView?.value ?? _prefViews[context.windowClass]?.value;
    final String? sort = _sort?.value;
    final String location = switch (widget.mode) {
      CatalogScreenMode.root => CatalogPaths.catalog(preset: _recent ? 'recent' : null, view: view, sort: sort),
      CatalogScreenMode.category => CatalogPaths.category(
        widget.categoryId!,
        view: view,
        sort: sort,
        f: CatalogFilterCodec.encode(_filter, includeCategory: false),
      ),
      CatalogScreenMode.search => CatalogPaths.search(
        q: _activeQuery.isEmpty ? null : _activeQuery,
        categoryId: widget.categoryId,
        view: view,
        sort: sort,
      ),
    };
    if (r.routeInformationProvider.value.uri.toString() != location) {
      if (_isSearch && widget.categoryId != null) {
        // Поиск открыт поверх SCR-12 (`push`): замена верхней записи с тем же ключом страницы — категория
        // остаётся под ним с прокруткой, «Назад» возвращает в неё (02 SCR-11.6, AC-UI-11-009).
        unawaited(r.replace<Object?>(location));
      } else {
        r.go(location);
      }
    }
  }

  String _categoryLocation(String id) => CatalogPaths.category(
    id,
    view: _urlView?.value,
    sort: _sort?.value,
    f: CatalogFilterCodec.encode(rebuildFilter(_filter, categoryId: null), includeCategory: false),
  );

  void _openCategory(Category c) {
    if ((_isCategory && c.id == widget.categoryId) || _navLocked()) {
      return;
    }
    final String location = _categoryLocation(c.id);
    if (context.windowClass == WindowClass.compact || (_isCategory && _isDescendant(c))) {
      _push(location);
    } else {
      _go(location);
    }
  }

  bool _isDescendant(Category c) {
    final Category? current = ref.read(categoryTreeProvider).tree?.find(widget.categoryId ?? '');
    return current != null && current.children.any((Category ch) => ch.id == c.id);
  }

  void _openProduct(ProductSummary p) {
    if (_navLocked()) {
      return;
    }
    _push(CatalogPaths.product(p.id, variantId: p.hasVariants ? null : p.defaultVariantId));
  }

  void _openProductId(String id) {
    if (!_navLocked()) {
      _push(CatalogPaths.product(id));
    }
  }

  // ---------------------------------------------------------------- поиск

  void _onQuery(String q) {
    ref.read(searchHistoryProvider.notifier).add(q);
    if (_isSearch) {
      setState(() {
        _activeQuery = q;
        _match = SearchMatchFilter.all;
      });
      _writeLocation();
    } else if (_isCategory) {
      // Из SCR-12 — поверх категории: «Назад» (один pop) возвращает в неё с прокруткой (02 SCR-11.6).
      _push(CatalogPaths.search(q: q, categoryId: widget.categoryId, view: _urlView?.value));
    } else {
      _go(CatalogPaths.search(q: q, view: _urlView?.value));
    }
  }

  void _onSearchChanged(String text) {
    if (_isSearch) {
      setState(() {});
    }
    _input.changed(text);
  }

  void _onScan() {
    if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
      _push(CatalogPaths.scan());
      return;
    }
    // Windows: камеры нет (D-42) — подсказка HID-сканера и фокус в поле (UI-10-044).
    _searchFocus.requestFocus();
    AppSnackbar.show(context, message: AppLocalizations.of(context).catalog_scanner_hid_hint);
  }

  void _useHistoryQuery(String q) {
    _searchText.text = q;
    _input.submit(q);
  }

  // ---------------------------------------------------------------- вид, сортировка, фильтры

  void _setView(ProductViewMode mode) {
    final WindowClass wc = context.windowClass;
    if (mode == _effectiveView(wc)) {
      return;
    }
    setState(() {
      _urlView = null;
      _prefViews[wc] = mode;
    });
    savePref(ref.read(catalogPrefsProvider).setViewMode(wc, mode));
    _writeLocation();
  }

  void _setSort(CatalogSort sort) {
    if (sort == _effectiveSort) {
      return;
    }
    setState(() => _sort = sort);
    savePref(ref.read(catalogPrefsProvider).setSort(sort, search: _isSearch));
    _writeLocation();
  }

  void _applyFilter(CatalogFilter next) {
    if (priceRangeInvalid(next) || CatalogFilterCodec.same(next, _filter)) {
      return;
    }
    setState(() => _filter = next);
    _price.sync(next);
    _writeLocation();
  }

  /// Изменение в `FilterPanel` (expanded): применение через 300 мс (02 SCR-13.4).
  void _onPanelChanged(CatalogFilter draft) {
    setState(() => _panelDraft = draft);
    _panelDebounce?.cancel();
    _panelDebounce = Timer(SearchInputPolicy.debounce, () {
      if (!mounted) {
        return;
      }
      final CatalogFilter? d = _panelDraft;
      if (d != null && !priceRangeInvalid(d)) {
        _applyFilter(d);
      }
    });
  }

  Future<void> _onFiltersButton() async {
    final WindowClass wc = context.windowClass;
    if (wc == WindowClass.expanded || wc == WindowClass.large) {
      setState(() {
        _filterPanelOpen = !_filterPanelOpen;
        _panelDraft = null;
      });
      return;
    }
    final String f = CatalogFilterCodec.encode(_filter) ?? '';
    // EQ-CAT-12: из поиска лист считает «Показать N» с учётом строки поиска (02 SCR-13.6).
    final String? q = _isSearch && _activeQuery.isNotEmpty ? _activeQuery : null;
    final GoRouter? r = _router;
    final Future<String?> pending = r != null
        ? r.push<String>(CatalogPaths.filters(f: f.isEmpty ? null : f, q: q))
        : Navigator.of(context).push<String>(
            MaterialPageRoute<String>(
              builder: (BuildContext context) => CatalogFiltersScreen(f: f.isEmpty ? null : f, q: q),
            ),
          );
    final String? result = await pending;
    if (!mounted || result == null) {
      return;
    }
    final CatalogFilter next = CatalogFilterCodec.decode(result, categoryId: _isCategory ? widget.categoryId : null);
    _applyFilter(_isCategory ? rebuildFilter(next, categoryId: widget.categoryId) : next);
  }

  void _togglePresetRecent() {
    setState(() => _recent = !_recent);
    _writeLocation();
  }

  void _togglePresetFavorites() {
    setState(() => _recent = false);
    _applyFilter(rebuildFilter(_filter, favorite: _filter.favorite == true ? null : true));
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

  Future<void> _onCardAction(ProductSummary p) async {
    final CatalogCartPort? cart = ref.read(catalogCartPortProvider);
    if (p.hasVariants || cart == null) {
      // SCR-15 (выбор варианта) и «+ Добавить» без корзины — через карточку товара (EQ-CAT-04).
      _openProduct(p);
      return;
    }
    final AppLocalizations l10n = AppLocalizations.of(context);
    final WindowClass wc = context.windowClass;
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
    } else if (wc == WindowClass.compact || wc == WindowClass.medium) {
      final (String msg, String? action) = CatalogFormats.splitAction(l10n.catalog_added_snackbar);
      AppSnackbar.show(context, message: msg, actionLabel: action, onAction: () => _go('/cart'));
    }
  }

  Future<void> _clearRecent() async {
    final CatalogShelfPort? port = ref.read(catalogShelfPortProvider);
    if (port == null) {
      return;
    }
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.catalog_recent_clear_confirm_title,
      message: l10n.catalog_recent_clear_confirm_body,
      confirmLabel: l10n.catalog_recent_clear,
    );
    if (!ok || !mounted) {
      return;
    }
    final Result<void> r = await port.clearRecent();
    if (!mounted) {
      return;
    }
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
    } else if (_recent && _listKey != null) {
      unawaited(ref.read(catalogListProvider(_listKey!).notifier).reload());
    }
  }

  Future<void> _openProfileMenu(BuildContext anchor) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final RenderBox box = anchor.findRenderObject()! as RenderBox;
    final RenderBox overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final Offset bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
    final String? picked = await showMenu<String>(
      context: context,
      color: c.surface,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 240),
      position: RelativeRect.fromLTRB(bottomRight.dx - 240, bottomRight.dy + 4, overlay.size.width - bottomRight.dx, 0),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: CatalogPaths.profile, height: 44, child: Text(l10n.profile_title)),
        PopupMenuItem<String>(value: CatalogPaths.settings, height: 44, child: Text(l10n.profile_menu_settings)),
        if (ref.read(catalogViewerRoleProvider) != RoleCode.customer)
          PopupMenuItem<String>(value: CatalogPaths.sync, height: 44, child: Text(l10n.profile_menu_sync)),
        // «Выйти» → ConfirmDialog «Выйти из аккаунта?» (фокус на «Отмена») → POST /auth/logout (UI-10-033).
        PopupMenuItem<String>(
          key: const ValueKey<String>('profile-menu-logout'),
          value: _logoutMenuValue,
          height: 44,
          child: Text(l10n.profile_logout),
        ),
      ],
    );
    if (picked == _logoutMenuValue && mounted) {
      await confirmCatalogLogout(context, ref);
    } else if (picked != null && mounted) {
      _push(picked);
    }
  }

  static const String _logoutMenuValue = 'logout';

  void _onMenu() {
    final WindowClass wc = context.windowClass;
    if (wc == WindowClass.expanded || wc == WindowClass.large) {
      setState(() => _sidebarCollapsed = !_sidebarCollapsed);
      savePref(ref.read(catalogPrefsProvider).setSidebarCollapsed(_sidebarCollapsed));
    } else {
      unawaited(_openAllCategories());
    }
  }

  Future<void> _openAllCategories() async {
    final Category? picked = await showAllCategoriesSheet(context, selectedId: widget.categoryId);
    if (picked != null && mounted) {
      _openCategory(picked);
    }
  }

  // ---------------------------------------------------------------- построение

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final WindowClass wc = context.windowClass;
    final CatalogListKey? key = _prefsLoaded ? _listKey : null;
    final CatalogListState list = key == null ? const CatalogListState() : ref.watch(catalogListProvider(key));
    final OnlineStatus online = ref.watch(catalogOnlineStatusProvider);
    final RoleCode? role = ref.watch(catalogViewerRoleProvider);
    final CatalogShelfPort? shelf = ref.watch(catalogShelfPortProvider);
    final Set<String> favIds = ref.watch(catalogFavoriteIdsProvider).value ?? const <String>{};
    final CategoryTreeState tree = ref.watch(categoryTreeProvider);
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final bool offline = list.offline || online == OnlineStatus.offline;
    final Category? category = _isCategory ? tree.tree?.find(widget.categoryId!) : null;
    final bool categoryMissing = _isCategory && category == null && tree.authoritative;

    final CatalogCardContext cardContext = CatalogCardContext(
      l10n: l10n,
      now: now,
      role: role,
      favoriteIds: favIds,
      favoriteOverrides: _favoriteOverrides,
      favoritesEnabled: shelf != null,
      offline: offline,
      showMatch: _isSearch,
      customerStockDisplay: role == RoleCode.customer
          ? ref.watch(catalogCustomerStockDisplayProvider)
          : CustomerStockDisplay.status,
    );

    final bool expanded = wc == WindowClass.expanded || wc == WindowClass.large;
    final bool compact = wc == WindowClass.compact;
    final bool tooShort = _isSearch && !SearchInputPolicy.canSearch(_searchText.text);

    // Панель SCR-14 на expanded пропускает клик в SearchBar и закрывается (02 SCR-14.2, navigation.md §5).
    final Widget searchField = DsPanelPassThrough(
      closesPanel: true,
      child: CatalogSearchField(
        controller: _searchText,
        focusNode: _searchFocus,
        windowClass: wc,
        onChanged: _onSearchChanged,
        onSubmitted: _input.submit,
        onScan: role == RoleCode.customer ? null : _onScan,
        loading: _isSearch && list.refreshing,
        autofocus: _isSearch && (widget.q ?? '').isEmpty,
      ),
    );
    final Widget header = CatalogHeader(
      windowClass: wc,
      search: searchField,
      compactTitle: _isCategory ? (category?.name ?? '') : l10n.category_breadcrumb_root,
      searchInTopBar: _isSearch,
      actions: CatalogHeaderActions(
        onLogo: () => _go(_rootLocation()),
        // У клиента «бургера» нет (TopAppBarPos `customer`, 02 UI-50-001): категории — полоса чипов / SB.
        onMenu: compact || role == RoleCode.customer ? null : _onMenu,
        onScan: _onScan,
        onNotifications: () {
          final Future<void> Function(BuildContext)? popover = ref.read(catalogNotificationsPopoverProvider);
          final bool wide = wc == WindowClass.expanded || wc == WindowClass.large;
          if (wide && popover != null) {
            unawaited(popover(context));
          } else {
            _push(CatalogPaths.notifications);
          }
        },
        onProfileMenu: (BuildContext anchor) => unawaited(_openProfileMenu(anchor)),
        onBack: compact && widget.mode != CatalogScreenMode.root ? _back : null,
        onSearchIcon: compact && _isCategory ? () => _push(CatalogPaths.search(categoryId: widget.categoryId)) : null,
      ),
    );

    final String dataTime = CatalogFormats.time(list.asOf ?? tree.tree?.asOf ?? now);
    final Widget? banner = offline && !_isSearch
        ? KeyedSubtree(
            key: const ValueKey<String>('catalog-offline-banner'),
            child: OfflineBanner(
              variant: OfflineBannerVariant.offline,
              dataAsOf: list.asOf ?? tree.tree?.asOf,
              now: now,
            ),
          )
        : null;

    final double side = compact ? context.space.s4 : context.space.s6; // money-double: allow — геометрия UI (lp)
    final EdgeInsets listPadding = EdgeInsets.fromLTRB(side, context.space.s2, side, side);

    // ---- список / особые состояния
    final Widget listArea;
    if (categoryMissing) {
      listArea = Center(
        child: EmptyState(
          key: const ValueKey<String>('category-not-found'),
          variant: EmptyStateVariant.category,
          title: l10n.category_not_found_title,
          actionLabel: l10n.category_not_found_action,
          onAction: () => _go(_rootLocation()),
        ),
      );
    } else if (tooShort) {
      listArea = SearchTooShortPanel(
        text: _searchText.text,
        onQuery: _useHistoryQuery,
        onProduct: _openProductId,
        padding: listPadding,
      );
    } else {
      final List<ProductSummary> items = _isSearch ? _matchFiltered(list.items) : list.items;
      listArea = CatalogProductView(
        key: ValueKey<String>('list-${key?.hashCode}'),
        state: list,
        items: items,
        view: _effectiveView(wc),
        windowClass: wc,
        cardContext: cardContext,
        padding: listPadding,
        callbacks: CatalogProductCallbacks(
          onOpen: _openProduct,
          onFavorite: (ProductSummary p, bool v) => unawaited(_toggleFavorite(p, v)),
          onAction: (ProductSummary p) => unawaited(_onCardAction(p)),
        ),
        onLoadMore: () {
          if (key != null) {
            unawaited(ref.read(catalogListProvider(key).notifier).loadMore());
          }
        },
        onRetry: () {
          if (key != null) {
            unawaited(ref.read(catalogListProvider(key).notifier).reload());
          }
        },
        errorTitle: _isCategory ? l10n.category_error_title : l10n.catalog_error_title,
        empty: _emptyState(l10n, list),
        footer: _isSearch ? SearchNotFoundHint(onScan: role == RoleCode.customer ? null : _onScan) : null,
      );
    }

    // ---- заголовок и инструменты
    final String? title = switch (widget.mode) {
      CatalogScreenMode.root =>
        _recent
            ? l10n.catalog_recent_title
            : (_filter.favorite == true ? l10n.catalog_sidebar_favorites : l10n.catalog_title_all),
      CatalogScreenMode.category => category?.name,
      CatalogScreenMode.search => l10n.search_title,
    };
    final String? found = _foundText(l10n, list, tooShort);
    final List<Category> path = _isCategory && tree.tree != null
        ? tree.tree!.pathTo(widget.categoryId!)
        : const <Category>[];
    final Widget? crumbs = path.length >= 2
        ? CatalogBreadcrumbs(
            path: path,
            onRoot: () => _go(_rootLocation(view: _urlView?.value, sort: _sort?.value)),
            onCategory: (Category c) => _go(_categoryLocation(c.id)),
          )
        : null;
    final Widget controls = CatalogToolbarControls(
      view: _effectiveView(wc),
      onView: _setView,
      sort: _effectiveSort,
      onSort: _setSort,
      searchMode: _isSearch,
      filterCount: _filter.activeCount,
      onFilters: () => unawaited(_onFiltersButton()),
      compact: compact,
      showViewText: wc == WindowClass.large,
      filtersOpen: _filterPanelOpen,
    );
    final EdgeInsets hPad = EdgeInsets.symmetric(horizontal: side);
    final List<CatalogStripChip> chips = _chips(l10n, tree, category, list, compact: !expanded);
    final Widget? strip = chips.isEmpty
        ? null
        : CatalogChipStrip(chips: chips, padding: hPad, loading: _isCategory && tree.tree == null && tree.loading);
    final Widget activeFilters = CatalogActiveFilters(filter: _filter, onChanged: _applyFilter, padding: hPad);
    final Widget? searchNote = _isSearch && offline
        ? Padding(
            padding: EdgeInsets.fromLTRB(side, 0, side, context.space.s1),
            child: Text(
              l10n.search_offline_note(dataTime),
              key: const ValueKey<String>('search-offline-note'),
              style: context.text.caption.copyWith(color: c.warning),
            ),
          )
        : null;

    final Widget body;
    if (compact) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          header,
          ?banner,
          ?strip,
          if (!tooShort && !categoryMissing)
            Padding(
              padding: hPad,
              child: SizedBox(
                height: 48,
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: CatalogTitleBlock(title: title, found: found, compact: true),
                    ),
                    controls,
                  ],
                ),
              ),
            ),
          ?searchNote,
          activeFilters,
          Expanded(child: listArea),
        ],
      );
    } else {
      final Widget content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(side, expanded ? side : context.space.s4, side, context.space.s2),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.end,
              runSpacing: context.space.s2,
              spacing: context.space.s4,
              children: <Widget>[
                CatalogTitleBlock(title: categoryMissing ? '' : title, found: found, breadcrumbs: crumbs),
                if (!tooShort && !categoryMissing) controls,
              ],
            ),
          ),
          ?searchNote,
          ?strip,
          activeFilters,
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: listArea),
                if (expanded && _filterPanelOpen) _filterPanel(l10n, list, role),
              ],
            ),
          ),
        ],
      );
      if (expanded) {
        final double width = MediaQuery.sizeOf(context).width; // money-double: allow — геометрия UI (lp)
        // `owner` — без корзины; `customer` — корзина overlay по кнопке, не постоянная CP (02 SCR-50.2 E).
        final bool showCart = role != RoleCode.owner && role != RoleCode.customer;
        final CatalogCartPanelBuilder? cartBuilder = ref.watch(catalogCartPanelProvider);
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            header,
            ?banner,
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(
                    width: _sidebarCollapsed
                        ? DsBreakpoints.sidebarCollapsed
                        : (width >= 1280 ? DsBreakpoints.sidebarWide : DsBreakpoints.sidebarNarrow),
                    decoration: BoxDecoration(
                      color: c.surface,
                      border: Border(right: BorderSide(color: c.border)),
                      boxShadow: context.elevation.e1,
                    ),
                    child: CatalogSidebar(
                      selectedCategoryId: widget.categoryId,
                      collapsed: _sidebarCollapsed,
                      onCategory: _openCategory,
                      onFavorites: () => _go(CatalogPaths.favorites),
                      onRecentProduct: _openProductId,
                      onClearRecent: _clearRecent,
                    ),
                  ),
                  // Якорь панели SCR-14 поверх контент-колонки (SB и CP видимы — 02 SCR-14.2, EQ-PD-05).
                  Expanded(child: DsContentRegion(child: content)),
                  // CP — постоянная соседняя область: открытая панель SCR-14 её клики не перехватывает
                  // (02 SCR-14.2, AC-UI-14-001).
                  if (showCart)
                    DsPanelPassThrough(
                      child: Container(
                        key: const ValueKey<String>('catalog-cart-panel'),
                        width: width >= 1280 ? DsBreakpoints.cartWide : DsBreakpoints.cartNarrow,
                        decoration: BoxDecoration(
                          color: c.surface,
                          border: Border(left: BorderSide(color: c.border)),
                        ),
                        child: cartBuilder?.call(context) ?? const CatalogCartPlaceholder(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      } else {
        // compact/medium: `CartFab` над нижней навигацией (02 UI-20-019; RM-F-005) — строит корень (фича cart);
        // `owner` — без корзины. Пустая корзина — построитель возвращает пустой виджет.
        final WidgetBuilder? fab = role == RoleCode.owner ? null : ref.watch(catalogCartFabProvider);
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            header,
            ?banner,
            Expanded(child: content),
            ?fab?.call(context),
          ],
        );
      }
    }

    // SCR-10.11: «Назад» на корне каталога — выход по двойному нажатию с подсказкой (Android).
    return BackToExitScope(
      enabled: widget.mode == CatalogScreenMode.root,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.f2): _focusSearch,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): _focusSearch,
        },
        child: Scaffold(
          key: ValueKey<String>('catalog-workspace-${widget.mode.name}'),
          backgroundColor: c.background,
          body: SafeArea(child: body),
        ),
      ),
    );
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchText.selection = TextSelection(baseOffset: 0, extentOffset: _searchText.text.length);
  }

  void _back() {
    final GoRouter? r = _router;
    if (r != null && r.canPop()) {
      r.pop();
    } else {
      _go(_rootLocation());
    }
  }

  List<ProductSummary> _matchFiltered(List<ProductSummary> items) => switch (_match) {
    SearchMatchFilter.all => items,
    SearchMatchFilter.barcode => items.where((ProductSummary p) => p.matchType == MatchType.barcode).toList(),
    SearchMatchFilter.sku => items.where((ProductSummary p) => p.matchType == MatchType.sku).toList(),
    SearchMatchFilter.name =>
      items.where((ProductSummary p) => p.matchType == MatchType.fts || p.matchType == MatchType.trgm).toList(),
  };

  String? _foundText(AppLocalizations l10n, CatalogListState list, bool tooShort) {
    if (tooShort) {
      return '';
    }
    if (list.phase == CatalogListPhase.loading) {
      return null;
    }
    if (list.phase == CatalogListPhase.error || list.phase == CatalogListPhase.offlineNoCache) {
      return '';
    }
    final int count = list.total ?? list.items.length;
    return switch (widget.mode) {
      CatalogScreenMode.search =>
        list.isEstimate
            ? l10n.search_found_estimate(count, _activeQuery)
            : l10n.search_found_count(count, _activeQuery),
      CatalogScreenMode.category => l10n.category_found_count(count),
      CatalogScreenMode.root => l10n.catalog_found_count(count),
    };
  }

  List<CatalogStripChip> _chips(
    AppLocalizations l10n,
    CategoryTreeState tree,
    Category? category,
    CatalogListState list, {
    required bool compact,
  }) {
    if (_isSearch) {
      // UI-11-009: чип области — только для поиска, начатого внутри категории (SCR-12 → SCR-11).
      final String? scopeId = widget.categoryId;
      final String? scopeName = scopeId == null ? null : tree.tree?.find(scopeId)?.name;
      final CatalogStripChip? scope = scopeId == null
          ? null
          : CatalogStripChip(
              key: 'search-scope',
              label: _searchAllCategories || scopeName == null
                  ? l10n.search_scope_all
                  : l10n.search_scope_category(scopeName),
              icon: Icons.category_rounded,
              chevron: true,
              // Чип-переключатель области: выбранный чип полосы не нажимается, поэтому без `selected`.
              onTap: () => setState(() {
                _searchAllCategories = !_searchAllCategories;
                _match = SearchMatchFilter.all;
              }),
            );
      final SearchMatchCountsView? m = list.matchTypes == null ? null : SearchMatchCountsView(list.matchTypes!);
      if (m == null || list.phase != CatalogListPhase.ready) {
        return <CatalogStripChip>[?scope];
      }
      CatalogStripChip chip(SearchMatchFilter f, String label, int count) => CatalogStripChip(
        key: 'match-${f.name}',
        label: label,
        count: count,
        selected: _match == f,
        onTap: () => setState(() => _match = _match == f ? SearchMatchFilter.all : f),
      );
      return <CatalogStripChip>[
        chip(SearchMatchFilter.all, l10n.search_match_all, m.total),
        chip(SearchMatchFilter.barcode, l10n.search_match_barcode, m.barcode),
        chip(SearchMatchFilter.sku, l10n.search_match_sku, m.sku),
        chip(SearchMatchFilter.name, l10n.search_match_name, m.name),
        // Справа от чипов типа совпадения (02 SCR-11.3 п. 5).
        ?scope,
      ];
    }
    final List<CatalogStripChip> chips = <CatalogStripChip>[];
    if (compact) {
      chips.add(
        CatalogStripChip(
          key: 'all-categories',
          label: l10n.category_all_categories,
          icon: Icons.category_rounded,
          chevron: true,
          onTap: () => unawaited(_openAllCategories()),
        ),
      );
      if (!_isCategory) {
        for (final Category root in tree.tree?.roots ?? const <Category>[]) {
          chips.add(
            CatalogStripChip(
              key: 'cat-${root.id}',
              label: root.name,
              count: root.productCount,
              onTap: () => _openCategory(root),
            ),
          );
        }
      }
    }
    if (_isCategory && category != null && category.hasChildren && category.children.isNotEmpty) {
      chips.add(
        CatalogStripChip(
          key: 'sub-all',
          label: l10n.category_all_chip,
          count: category.productCount,
          selected: true,
          onTap: () {},
        ),
      );
      for (final Category ch in category.children.where((Category ch) => ch.productCount > 0)) {
        chips.add(
          CatalogStripChip(key: 'sub-${ch.id}', label: ch.name, count: ch.productCount, onTap: () => _openCategory(ch)),
        );
      }
    }
    // Подборки C6 видимы всегда, в том числе в листовой категории (UI-10-036, AC-UI-12-001); в категории
    // «Недавние» действуют в её пределах (UI-12-007).
    if (ref.read(catalogShelfPortProvider) != null) {
      chips.add(
        CatalogStripChip(
          key: 'preset-recent',
          label: l10n.catalog_preset_recent,
          icon: Icons.history_rounded,
          selected: _recent,
          onTap: _togglePresetRecent,
        ),
      );
    }
    chips.add(
      CatalogStripChip(
        key: 'preset-favorites',
        label: l10n.catalog_preset_favorites,
        icon: Icons.star_outline_rounded,
        selected: _filter.favorite == true && !_recent,
        onTap: _togglePresetFavorites,
      ),
    );
    return chips;
  }

  Widget _emptyState(AppLocalizations l10n, CatalogListState list) {
    final bool filtered = _filter.activeCount > 0;
    if (_isSearch) {
      final String? suggested = list.suggestedQuery;
      return EmptyState(
        key: const ValueKey<String>('catalog-empty'),
        variant: EmptyStateVariant.search,
        title: l10n.ds_empty_search_title(_activeQuery),
        body: l10n.search_empty_body,
        actionLabel: filtered ? l10n.ds_button_reset : null,
        onAction: filtered ? () => _applyFilter(CatalogFilterCodec.cleared(_filter)) : null,
        secondaryActionLabel: suggested == null ? null : l10n.search_suggested_query(suggested),
        onSecondaryAction: suggested == null ? null : () => _useHistoryQuery(suggested),
      );
    }
    if (filtered) {
      return EmptyState(
        key: const ValueKey<String>('catalog-empty'),
        variant: EmptyStateVariant.category,
        title: l10n.catalog_empty_filtered_title,
        body: l10n.catalog_empty_filtered_body,
        actionLabel: l10n.ds_button_reset,
        onAction: () => _applyFilter(CatalogFilterCodec.cleared(_filter)),
      );
    }
    return EmptyState(
      key: const ValueKey<String>('catalog-empty'),
      variant: EmptyStateVariant.category,
      title: l10n.catalog_empty_category_title,
      body: _isCategory ? l10n.category_empty_body : l10n.catalog_empty_category_body,
      actionLabel: l10n.category_all_categories,
      onAction: () => context.windowClass == WindowClass.compact || context.windowClass == WindowClass.medium
          ? unawaited(_openAllCategories())
          : _go(_rootLocation()),
    );
  }

  Widget _filterPanel(AppLocalizations l10n, CatalogListState list, RoleCode? role) {
    final CatalogFilter draft = _panelDraft ?? _filter;
    final List<Warehouse> warehouses = role == RoleCode.customer
        ? const <Warehouse>[]
        : (ref.watch(catalogWarehousesProvider).value ?? const <Warehouse>[]);
    return FilterPanel(
      key: const ValueKey<String>('catalog-filter-panel'),
      title: l10n.filters_title,
      activeCount: draft.activeCount,
      resetLabel: l10n.ds_button_reset,
      closeLabel: l10n.ds_button_close,
      onReset: () {
        final CatalogFilter cleared = CatalogFilterCodec.cleared(draft);
        _price.sync(cleared);
        setState(() => _panelDraft = null);
        _applyFilter(cleared);
      },
      onClose: () => setState(() => _filterPanelOpen = false),
      note: list.offline ? l10n.filters_offline_note(CatalogFormats.time(list.asOf ?? DateTime.now())) : null,
      sections: buildCatalogFilterSections(
        context: context,
        filter: draft,
        onUpdate: (CatalogFilter Function(CatalogFilter current) update) =>
            _onPanelChanged(update(_panelDraft ?? _filter)),
        price: _price,
        role: role,
        facets: list.facets,
        facetsLoading: list.phase == CatalogListPhase.loading || list.refreshing,
        facetsFailed: false,
        onRetryFacets: () {},
        warehouses: warehouses,
        showAllBrands: _showAllBrands,
        onToggleShowAllBrands: () => setState(() => _showAllBrands = !_showAllBrands),
      ),
    );
  }
}

/// Пустая CP до подключения корзины (SCR-20, RM-F-005): заголовок «Корзина» + `EmptyState.cart`.
class CatalogCartPlaceholder extends StatelessWidget {
  const CatalogCartPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          height: 56,
          padding: EdgeInsets.symmetric(horizontal: context.space.s4),
          alignment: AlignmentDirectional.centerStart,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: Text(
            l10n.cart_title,
            style: context.text.title.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
          ),
        ),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: EmptyState(
                variant: EmptyStateVariant.cart,
                title: l10n.cart_empty_title,
                body: l10n.cart_empty_body,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Счётчики чипов совпадений: «Название» = fts + trgm (UI-11-004).
final class SearchMatchCountsView {
  const SearchMatchCountsView(this._m);

  final SearchMatchCounts _m;

  int get barcode => _m.barcode;
  int get sku => _m.sku;
  int get name => _m.fts + _m.trgm;
  int get total => barcode + sku + name;
}
