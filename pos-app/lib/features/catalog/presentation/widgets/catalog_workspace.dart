// Рабочее пространство каталога — общая реализация SCR-10 (корень), SCR-11 (поиск), SCR-12 (категория)
// по 02 ч. B: шапка (зона A), сайдбар (B), заголовок/инструменты/чипы (C), список (D); корзина (E) на medium и шире —
// кнопка-итог в шапке и drawer 420 поверх экрана (порт `catalogCartButtonProvider`, ADR-112), на compact — `CartFab`;
// адаптивность D-18: compact — шапка 56 + строка поиска + полоса чипов (нижняя навигация — оболочка); medium и
// шире — одна раскладка по прототипу 2026-10-29 (ADR-112): шапка, баннер офлайна, колонка плиток корневых категорий
// 132 (`CatalogSidebar.tiles`; у `customer` на expanded/large — прежний сайдбар-список 240/292, D6) · контент; колонка
// сворачивается до 72 кнопкой внизу, выбор сохраняется в настройках пользователя (`sidebarCollapsed`). После
// «+ Добавить» на medium и шире — тост «Добавлено: {name}» внизу справа (≈ 2 с; у `customer` — с действием «Открыть»:
// кнопки корзины в его шапке нет), на compact — снекбар «Добавлено · Открыть». Повтор/«Назад»/перезапуск — 02 SCR-10.11,
// SCR-11.11, SCR-12.11. Над списком (medium+) прокручиваются вместе с ним: заголовок h1, лента подкатегорий
// `ScrollRibbon` 118×148, закреплённая строка управления («Новые», «Избранные», «Недавние», «Найдено: N» | вид,
// сортировка, «Фильтры») и встроенная панель фильтров — блоки с постоянными ключами (без пересоздания при смене
// выборки; панель фильтров всегда в дереве, закрытая — нулевой высоты).
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/scroll_ribbon.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/layout/content_region.dart';
import 'package:optomstroy/design_system/layout/shell_scope.dart';
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
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_product_view.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_profile_menu.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_search_parts.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_sidebar.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_toolbar.dart';

/// Позиция прокрутки списка выборки [key]: смещение в логических пикселях, не деньги.
typedef _ScrollMark = ({CatalogListKey? key, double offset}); // money-double: allow — смещение прокрутки в lp

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

/// Память сеанса экрана по экземпляру [CatalogPrefs] (память процесса; экземпляр меняется со сменой пользователя):
/// последние прочитанные настройки и последний показанный список с его ключом. Новый экземпляр (`push` на compact)
/// строит список сразу — без кадра скелетона из-за асинхронного чтения drift `settings`; прежние карточки он берёт
/// только для той же выборки ([lastShownKey]), иначе — скелетон до своей выборки (товары другой категории или
/// прежнего поиска под новым заголовком не показываются). Пишет только рабочее пространство — значения согласованы.
final class _PrefsMemo {
  CatalogSort? catalogSort;
  CatalogSort? searchSort;
  bool sidebarCollapsed = false;
  final Map<WindowClass, ProductViewMode> views = <WindowClass, ProductViewMode>{};
  CatalogListKey? lastShownKey;
  CatalogListState? lastShown;
}

final Expando<_PrefsMemo> _prefsMemo = Expando<_PrefsMemo>('catalog-prefs');

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
    this.stackDepth,
  });

  final CatalogScreenMode mode;
  final String? categoryId;
  final String? preset;
  final String? view;
  final String? sort;
  final String? f;
  final String? q;

  /// medium+ (один экран семейства в странице `/catalog`): число записей `push` семейства над записью `go`
  /// (0 — запись `go`; 1 — SCR-11 поверх SCR-12 или подкатегория поверх категории на medium). `null` — экран на
  /// своей странице (compact): вложенность записи определяется по стеку роутера.
  final int? stackDepth;

  /// Постоянный ключ для всех режимов (root/category/search): смена адреса обновляет экземпляр, а не меняет его.
  static const Key stableKey = ValueKey<String>('catalog-workspace');

  /// Тонкая полоса загрузки в области списка (смена категории/обновление из кэша — 02 SCR-10.7).
  static const Key refreshBarKey = ValueKey<String>('catalog-list-refreshing');

  @override
  ConsumerState<CatalogWorkspace> createState() => _CatalogWorkspaceState();
}

class _CatalogWorkspaceState extends ConsumerState<CatalogWorkspace> {
  static const Duration _navLockDuration = Duration(milliseconds: 300);

  ProductViewMode? _urlView;
  final Map<WindowClass, ProductViewMode> _prefViews = <WindowClass, ProductViewMode>{};
  CatalogSort? _sort;
  CatalogSort? _prefSortCatalog;
  CatalogSort? _prefSortSearch;
  bool _prefsLoaded = false;
  late CatalogFilter _filter;
  late bool _recent;

  /// Колонка категорий свёрнута до 72 (medium+; настройка пользователя `sidebarCollapsed`, паритет функций ADR-112).
  bool _sidebarCollapsed = false;

  /// Встроенная панель фильтров (medium+) открыта; переживает смену категории.
  bool _filterPanelOpen = false;
  bool _showAllBrands = false;
  final Map<String, bool> _favoriteOverrides = <String, bool>{};

  /// Товары, для которых «+ Добавить» выполняется: кнопка сразу в загрузке, повторные нажатия не уходят в корзину
  /// (без лишних запросов и количеств; поведение корзины — прежнее, `CatalogCartPort.add`).
  final Set<String> _adding = <String>{};

  /// Сортировка до включения «Сначала новые» кнопкой панели управления — к ней возвращает повторное нажатие.
  CatalogSort? _sortBeforeNewest;
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

  /// Прокрутка списка: сбрасывается к началу при смене выборки (категория, фильтры, сортировка, поиск).
  final ScrollController _listScroll = ScrollController();

  /// Ключ списка, для которого показан текущий набор карточек (сброс прокрутки при смене).
  CatalogListKey? _scrolledKey;

  /// Последнее показанное состояние списка с данными: при смене выборки прежние карточки остаются на месте
  /// (неактивные, [CatalogProductView.inert]) с тонкой полосой загрузки, пока не придут новые (кэш или сеть) — без
  /// полносеточного скелетона.
  CatalogListState? _shownList;

  /// Прокрутка списка под записью `push` (глубина → ключ выборки и смещение): «Назад» из SCR-11, открытого в
  /// категории, или из подкатегории (medium) возвращает к прежней позиции (02 SCR-11.6).
  final Map<int, _ScrollMark> _stackOffsets = <int, _ScrollMark>{};

  /// Позиция, к которой вернуться при показе выборки после «Назад».
  _ScrollMark? _pendingRestore;

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
    final _PrefsMemo? memo = _prefsMemo[ref.read(catalogPrefsProvider)];
    if (memo != null) {
      _applyPrefs(memo);
      _prefsLoaded = true;
      // Прежние карточки — только той же выборки (иначе скелетон до своей): не товары другой категории/поиска.
      final CatalogListKey? key = _listKey;
      if (key != null && key == memo.lastShownKey) {
        _shownList = memo.lastShown;
      }
    } else {
      unawaited(_loadPrefs());
    }
  }

  /// Смена адреса без пересоздания экрана (категория, режим root/category/search, параметры URL): состояние,
  /// зависящее от выборки, сбрасывается здесь — черновик фильтров, область поиска, подборка «Недавние»,
  /// прокрутка (при показе новой выборки, [_syncScroll]); шапка, сайдбар, CP и вид остаются.
  @override
  void didUpdateWidget(CatalogWorkspace old) {
    super.didUpdateWidget(old);
    final bool modeChanged = widget.mode != old.mode;
    final bool scopeChanged = modeChanged || widget.categoryId != old.categoryId;
    if (_isSearch) {
      final String q = SearchInputPolicy.normalize(widget.q ?? '');
      if (modeChanged || q != _activeQuery) {
        _activeQuery = q;
        // Набранный текст (и курсор) не трогаем, если он уже соответствует запросу (поиск из шапки SCR-10).
        if (SearchInputPolicy.normalize(_searchText.text) != q) {
          _searchText.text = widget.q ?? '';
        }
        _input.reset(q);
        _match = SearchMatchFilter.all;
      }
    } else if (old.mode == CatalogScreenMode.search) {
      // Из SCR-11 в каталог/категорию — строка поиска пустая, как на новом экране (02 SCR-10.11).
      _activeQuery = '';
      _searchText.clear();
      _input.reset('');
      _match = SearchMatchFilter.all;
    }
    if (scopeChanged) {
      _searchAllCategories = false;
      _showAllBrands = false;
      _panelDebounce?.cancel();
      _panelDraft = null;
    }
    if (scopeChanged || widget.f != old.f) {
      final CatalogFilter next = _decodeFilter();
      if (!CatalogFilterCodec.same(next, _filter)) {
        _filter = next;
        _price.sync(_filter);
      }
    }
    if (modeChanged) {
      // Сортировки каталога и поиска различаются (UI-11-008): из URL нового режима, иначе — сохранённая.
      _sort = _parseSort(widget.sort);
    } else if (widget.sort != old.sort) {
      final CatalogSort? s = _parseSort(widget.sort);
      if (s != null) {
        _sort = s;
      }
    }
    if (modeChanged) {
      _urlView = ProductViewMode.tryParse(widget.view) ?? _urlView;
    } else if (widget.view != old.view) {
      final ProductViewMode? v = ProductViewMode.tryParse(widget.view);
      if (v != null) {
        _urlView = v;
      }
    }
    if (scopeChanged || widget.preset != old.preset) {
      _recent = widget.preset == 'recent';
    }
    final int? depth = widget.stackDepth;
    final int? oldDepth = old.stackDepth;
    if (depth != null && oldDepth != null && depth != oldDepth) {
      if (depth > oldDepth) {
        // `push` поверх: запомнить, где был список нижней записи.
        _stackOffsets[oldDepth] = (key: _scrolledKey, offset: _listScroll.hasClients ? _listScroll.offset : 0);
        _pendingRestore = null;
      } else {
        // «Назад»: вернуться к позиции записи, в которую вернулись (если выборка та же).
        _pendingRestore = _stackOffsets.remove(depth);
        _stackOffsets.removeWhere((int d, _) => d > depth);
      }
    }
  }

  /// Новая выборка показана — к началу списка (как на новом экране; 02 SCR-10.11 «позиция прокрутки — к началу»).
  /// После «Назад» в запись под `push` — к её прежней позиции ([_stackOffsets]).
  void _syncScroll(CatalogListKey? key, CatalogListState shown) {
    if (key == _scrolledKey || shown.phase == CatalogListPhase.loading) {
      return;
    }
    final bool first = _scrolledKey == null;
    _scrolledKey = key;
    final _ScrollMark? mark = _pendingRestore;
    _pendingRestore = null;
    if (first) {
      return;
    }
    final double target = mark != null && mark.key == key ? mark.offset : 0; // money-double: allow — lp-смещение
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !_listScroll.hasClients) {
        return;
      }
      final double to = target.clamp(0, _listScroll.position.maxScrollExtent); // money-double: allow — lp-смещение
      if (_listScroll.offset != to) {
        _listScroll.jumpTo(to);
      }
    });
  }

  @override
  void dispose() {
    _panelDebounce?.cancel();
    _input.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    _price.dispose();
    _listScroll.dispose();
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
    final _PrefsMemo memo = _PrefsMemo()
      ..catalogSort = await prefs.sort(search: false)
      ..searchSort = await prefs.sort(search: true)
      ..sidebarCollapsed = await prefs.sidebarCollapsed() ?? false;
    for (final WindowClass wc in WindowClass.values) {
      final ProductViewMode? v = await prefs.viewMode(wc);
      if (v != null) {
        memo.views[wc] = v;
      }
    }
    _prefsMemo[prefs] = memo;
    if (!mounted) {
      return;
    }
    setState(() {
      _applyPrefs(memo);
      _prefsLoaded = true;
    });
  }

  void _applyPrefs(_PrefsMemo memo) {
    final CatalogSort? catalogSort = memo.catalogSort;
    final CatalogSort? searchSort = memo.searchSort;
    _prefSortCatalog = catalogSort != null && catalogSort.forCatalog ? catalogSort : null;
    _prefSortSearch = searchSort != null && searchSort.forSearch ? searchSort : null;
    _sidebarCollapsed = memo.sidebarCollapsed;
    _prefViews
      ..clear()
      ..addAll(memo.views);
  }

  /// Запоминает запись настройки в памяти процесса ([_PrefsMemo]) — следующий экземпляр стартует с ней.
  void _rememberPrefs(void Function(_PrefsMemo memo) update) {
    final _PrefsMemo? memo = _prefsMemo[ref.read(catalogPrefsProvider)];
    if (memo != null) {
      update(memo);
    }
  }

  CatalogSort get _effectiveSort =>
      _sort ??
      (_isSearch ? _prefSortSearch : _prefSortCatalog) ??
      (_isSearch ? CatalogDefaults.searchSort : CatalogDefaults.catalogSort);

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

  /// Запись экрана открыта `push` (SCR-11 поверх SCR-12, категория поверх каталога на compact): по составу стека
  /// роутера (`ImperativeRouteMatch`), а не по формату ключа страницы.
  bool get _pushedEntry {
    final int? depth = widget.stackDepth;
    if (depth != null) {
      return depth > 0;
    }
    final GoRouter? r = _router;
    if (r == null) {
      return false;
    }
    final ValueKey<String> pageKey;
    try {
      pageKey = GoRouterState.of(context).pageKey;
    } on GoError {
      return false; // экран вне маршрута go_router (тесты виджета)
    }
    bool found = false;
    void visit(List<RouteMatchBase> matches) {
      for (final RouteMatchBase m in matches) {
        if (m is ImperativeRouteMatch && m.pageKey == pageKey) {
          found = true;
        } else if (m is ShellRouteMatch) {
          visit(m.matches);
        }
      }
    }

    visit(r.routerDelegate.currentConfiguration.matches);
    return found;
  }

  /// Текущий location отражает вид/сортировку/фильтры (navigation.md §3): у записи `push` — замена этой записи
  /// (`replace`, «Назад» по-прежнему к записи под ней), у записи `go` — `go`.
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
      if (_pushedEntry) {
        // Например, поиск поверх SCR-12 (`push`): замена верхней записи с тем же ключом страницы — категория
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
    if (_isCategory && c.id == widget.categoryId) {
      return;
    }
    final WindowClass wc = context.windowClass;
    final String location = _categoryLocation(c.id);
    // compact — `push` (история родитель → дочерняя, «Назад» системой); блокировка 300 мс — от двойного `push`.
    if (wc == WindowClass.compact) {
      if (!_navLocked()) {
        _push(location);
      }
      return;
    }
    // medium (системная «Назад» Android-планшета): подкатегория — `push` (02 SCR-12.6, navigation.md SCR-12); запись
    // рисует тот же экран (страница `/catalog`), «Назад» — к родителю с его прокруткой. Соседняя подкатегория —
    // замена записи, «Все» (родитель) — «Назад». expanded/large — `go`, путь к родителю — крошки (02 SCR-12.4;
    // CQ-STAB-01). Корни и прочие переходы — `go`: идемпотентен, быстрый выбор подряд не теряется (SCR-10.11).
    final GoRouter? r = _router;
    if (wc == WindowClass.medium && _isCategory && r != null) {
      final Category? current = ref.read(categoryTreeProvider).tree?.find(widget.categoryId!);
      final bool pushed = (widget.stackDepth ?? 0) > 0;
      if (c.parentId != null && c.parentId == widget.categoryId) {
        if (!_navLocked()) {
          unawaited(r.push<Object?>(location));
        }
        return;
      }
      if (pushed && current != null && current.parentId != null) {
        if (current.parentId == c.id && r.canPop()) {
          r.pop();
          return;
        }
        if (current.parentId == c.parentId) {
          unawaited(r.replace<Object?>(location));
          return;
        }
      }
    }
    _go(location);
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

  void _onScan() => handleCatalogScanButton(context, _searchFocus);

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
    _rememberPrefs((_PrefsMemo m) => m.views[wc] = mode);
    savePref(ref.read(catalogPrefsProvider).setViewMode(wc, mode));
    _writeLocation();
  }

  void _setSort(CatalogSort sort) {
    if (sort == _effectiveSort) {
      return;
    }
    setState(() => _sort = sort);
    final bool search = _isSearch;
    _rememberPrefs((_PrefsMemo m) => search ? m.searchSort = sort : m.catalogSort = sort);
    savePref(ref.read(catalogPrefsProvider).setSort(sort, search: search));
    _writeLocation();
  }

  void _applyFilter(CatalogFilter next) {
    if (priceRangeInvalid(next) || CatalogFilterCodec.same(next, _filter)) {
      return;
    }
    // Черновик панели применён или заменён (сброс из пустого состояния, чип активного фильтра) — панель показывает
    // действующий фильтр.
    _panelDebounce?.cancel();
    setState(() {
      _filter = next;
      _panelDraft = null;
    });
    _price.sync(next);
    _writeLocation();
  }

  /// Изменение во встроенной панели фильтров (medium+): применение через 300 мс (02 SCR-13.4).
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
    if (wc != WindowClass.compact) {
      // medium+: встроенная панель под строкой управления (прототип 2026-10-29); compact — лист SCR-13.
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

  /// Свернуть / развернуть колонку категорий (кнопка внизу колонки): настройка пользователя сохраняется.
  void _toggleSidebar() {
    final bool next = !_sidebarCollapsed;
    setState(() => _sidebarCollapsed = next);
    _rememberPrefs((_PrefsMemo m) => m.sidebarCollapsed = next);
    savePref(ref.read(catalogPrefsProvider).setSidebarCollapsed(next));
  }

  void _togglePresetRecent() {
    setState(() => _recent = !_recent);
    _writeLocation();
  }

  /// «Новые» строки управления: в проекте «новые» — сортировка `updatedAt:desc` (02 SCR-10.4 «Сортировка»,
  /// 08 §4.4.2; пресета «новые поступления» нет, ADR-112). Включает её; повторное нажатие возвращает прежнюю.
  void _toggleNewest() {
    final CatalogSort current = _effectiveSort;
    if (current == CatalogSort.updatedAtDesc) {
      final CatalogSort back = _sortBeforeNewest ?? CatalogDefaults.catalogSort;
      _sortBeforeNewest = null;
      _setSort(back == CatalogSort.updatedAtDesc ? CatalogDefaults.catalogSort : back);
    } else {
      _sortBeforeNewest = current;
      _setSort(CatalogSort.updatedAtDesc);
    }
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
    if (_adding.contains(p.id)) {
      return;
    }
    final AppLocalizations l10n = AppLocalizations.of(context);
    final WindowClass wc = context.windowClass;
    setState(() => _adding.add(p.id));
    final Result<void> r;
    try {
      r = await cart.add(p);
    } finally {
      if (mounted) {
        setState(() => _adding.remove(p.id));
      } else {
        _adding.remove(p.id);
      }
    }
    if (!mounted) {
      return;
    }
    if (r case FailureResult<void>(:final failure)) {
      AppSnackbar.show(
        context,
        message: cart.rejectionText(failure, l10n) ?? l10n.error_internal,
        variant: AppSnackbarVariant.error,
      );
    } else if (wc == WindowClass.compact) {
      final (String msg, String? action) = CatalogFormats.splitAction(l10n.catalog_added_snackbar);
      AppSnackbar.show(context, message: msg, actionLabel: action, onAction: () => _go('/cart'));
    } else {
      // medium и шире (прототип 2026-10-29, ADR-112): короткий тост внизу справа, ≈ 2 с (8 с при экранном чтении);
      // итог и число позиций видны на кнопке корзины в шапке. У `customer` кнопки корзины в шапке нет — в тосте
      // остаётся действие «Открыть» (как прежний снекбар, паритет функций ADR-112).
      final bool customer = ref.read(catalogViewerRoleProvider) == RoleCode.customer;
      final (String _, String? open) = CatalogFormats.splitAction(l10n.catalog_added_snackbar);
      AppSnackbar.show(
        context,
        message: l10n.catalog_added_toast(p.name),
        variant: AppSnackbarVariant.success,
        brief: !customer,
        placement: AppSnackbarPlacement.bottomEnd,
        actionLabel: customer ? open : null,
        onAction: customer ? () => _go('/cart') : null,
      );
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

  /// Меню аватара (02 SCR-10.3 A9, ADR-112): Профиль · Настройки · Синхронизация · Заблокировать · Выйти.
  Future<void> _openProfileMenu(BuildContext anchor) =>
      showCatalogProfileMenu(context: context, anchor: anchor, ref: ref, onNavigate: _push);

  /// «Бургер» шапки medium+ (02 SCR-10.3 A1, ADR-112): drawer навигации оболочки; вне оболочки — кнопки нет.
  /// Колонку категорий и лист «Все категории» «бургер» больше не открывает (D3).
  VoidCallback? _onMenu() => DsShellScope.maybeOf(context)?.openNavigation;

  /// Фокус в поле поиска по запросу шапки оболочки (поиск начат на другой ветке): курсор — в конец строки.
  void _focusSearchFromShell() {
    if (!mounted) {
      return;
    }
    _searchFocus.requestFocus();
    _searchText.selection = TextSelection.collapsed(offset: _searchText.text.length);
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
    ref.listen<int>(catalogSearchFocusRequestProvider, (int? _, int _) => _focusSearchFromShell());
    final CatalogListKey? key = _prefsLoaded ? _listKey : null;
    final CatalogListState fresh = key == null ? const CatalogListState() : ref.watch(catalogListProvider(key));
    // Смена выборки: пока новая загружается (ещё нет ни кэша, ни ответа сети), остаются прежние карточки и
    // тонкая полоса в области списка; полносеточный скелетон — только при самой первой загрузке (02 SCR-10.7).
    // Прежний пустой список не держится (иначе на время загрузки мелькнуло бы «Нет товаров») — скелетон.
    final bool switching =
        fresh.phase == CatalogListPhase.loading && _shownList != null && _shownList!.items.isNotEmpty;
    final CatalogListState list = switching ? _shownList! : fresh;
    if (fresh.phase != CatalogListPhase.loading) {
      _shownList = fresh;
      _prefsMemo[ref.read(catalogPrefsProvider)]
        ?..lastShown = fresh
        ..lastShownKey = key;
    }
    _syncScroll(key, fresh);
    final OnlineStatus online = ref.watch(catalogOnlineStatusProvider);
    final RoleCode? role = ref.watch(catalogViewerRoleProvider);
    final CatalogShelfPort? shelf = ref.watch(catalogShelfPortProvider);
    final Set<String> favIds = ref.watch(catalogFavoriteIdsProvider).value ?? const <String>{};
    // Переопределение звезды нужно только до ответа и для отката при ошибке: подтверждённое избранным снимается. Иначе
    // при долгоживущем экземпляре (`stableKey`) звезда расходится с избранным, изменённым на SCR-14 или SCR-40.
    _favoriteOverrides.removeWhere((String id, bool on) => favIds.contains(id) == on);
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
      busyIds: Set<String>.unmodifiable(_adding),
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
        loading: _isSearch && (list.refreshing || switching),
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
        onMenu: compact || role == RoleCode.customer ? null : _onMenu(),
        onScan: _onScan,
        onNotifications: () => openCatalogNotifications(context, ref, wc),
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

    // Поля контента: compact — 16 с обеих сторон; medium+ — 16 от колонки категорий (у неё свои поля) и 24 справа.
    final double side = compact ? context.space.s4 : context.space.s6; // money-double: allow — геометрия UI (lp)
    final double start = context.space.s4; // money-double: allow — геометрия UI (lp)
    final EdgeInsets listPadding = EdgeInsets.fromLTRB(start, context.space.s2, side, side);

    // ---- заголовок, лента подкатегорий, строка управления
    final EdgeInsets hPad = EdgeInsets.only(left: start, right: side);
    final List<Category> path = _isCategory && tree.tree != null
        ? tree.tree!.pathTo(widget.categoryId!)
        : const <Category>[];
    // Лента подкатегорий (medium+, макет заказчика): дети текущей категории, а в листовой подкатегории — её
    // соседи с выбранной текущей; заголовок раздела — родитель ленты (02 SCR-12.3: «Все» + подкатегории).
    final Category? ribbonParent = compact ? null : _ribbonParent(tree.tree, category);
    final String? title = switch (widget.mode) {
      CatalogScreenMode.root =>
        _recent
            ? l10n.catalog_recent_title
            : (_filter.favorite == true ? l10n.catalog_sidebar_favorites : l10n.catalog_title_all),
      CatalogScreenMode.category => ribbonParent?.name ?? category?.name,
      CatalogScreenMode.search => l10n.search_title,
    };
    // На время смены выборки — прежнее «Найдено: N» (как и карточки), без мигания полосы-скелетона подзаголовка.
    final String? found = _foundText(l10n, list, tooShort);
    final Widget? crumbs = path.length >= 2
        ? CatalogBreadcrumbs(
            path: path,
            onRoot: () => _go(_rootLocation(view: _urlView?.value, sort: _sort?.value)),
            onCategory: (Category c) => _go(_categoryLocation(c.id)),
          )
        : null;
    // «Сетка / Список / Компакт» с подписями — на medium+, когда строка помещается (прототип); compact — иконки с
    // тултипом. medium+ — стиль строки управления (`toolbar`).
    Widget controlsFor(bool showViewText) => CatalogToolbarControls(
      view: _effectiveView(wc),
      onView: _setView,
      sort: _effectiveSort,
      onSort: _setSort,
      searchMode: _isSearch,
      filterCount: _filter.activeCount,
      onFilters: () => unawaited(_onFiltersButton()),
      compact: compact,
      showViewText: showViewText,
      filtersOpen: !compact && _filterPanelOpen,
      toolbarStyle: !compact,
    );
    final Widget activeFilters = CatalogActiveFilters(filter: _filter, onChanged: _applyFilter, padding: hPad);
    final Widget? searchNote = _isSearch && offline
        ? Padding(
            padding: EdgeInsets.fromLTRB(compact ? side : start, 0, side, context.space.s1),
            child: Text(
              l10n.search_offline_note(dataTime),
              key: const ValueKey<String>('search-offline-note'),
              style: context.text.caption.copyWith(color: c.warning),
            ),
          )
        : null;

    // compact — прежняя полоса чипов (категории/подкатегории/подборки); medium+ — только чипы поиска (SCR-11):
    // корни — колонка категорий, подкатегории — лента, подборки — строка управления (прототип 2026-10-29).
    final List<CatalogStripChip> chips = compact
        ? _chips(l10n, tree, category, list, compact: true)
        : (_isSearch ? _chips(l10n, tree, category, list, compact: false) : const <CatalogStripChip>[]);
    final Widget? strip = chips.isEmpty
        ? null
        : CatalogChipStrip(
            chips: chips,
            padding: hPad,
            loading: compact && _isCategory && tree.tree == null && tree.loading,
          );

    // ---- список / особые состояния
    final Widget listArea;
    final bool productsShown = !categoryMissing && !tooShort;
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
      // medium+: заголовок, лента и строка управления прокручиваются вместе со списком (больше места карточкам),
      // строка управления закреплена сверху, под ней — встроенная панель фильтров (всегда в дереве, закрытая —
      // нулевой высоты: состав slivers не меняется); у каждого блока свой ключ — блоки не пересоздаются при смене
      // выборки.
      final List<Widget> headerSlivers = compact
          ? const <Widget>[]
          : <Widget>[
              SliverToBoxAdapter(
                key: const ValueKey<String>('catalog-sliver-title'),
                child: Padding(
                  // Прототип: поле контента 18 + отступ заголовка 4 сверху → 22; снизу 14 до ленты, у которой поле 2,
                  // а у [ScrollRibbon] — 4 (кольцо фокуса) → 12. Карточка ленты — на 74 от низа шапки, как в прототипе.
                  padding: EdgeInsets.fromLTRB(start, context.space.s5 + 2, side, context.space.s3),
                  child: CatalogTitleBlock(title: title, found: found, breadcrumbs: crumbs, showFound: false),
                ),
              ),
              if (ribbonParent != null)
                SliverToBoxAdapter(
                  key: const ValueKey<String>('catalog-sliver-ribbon'),
                  child: Padding(
                    // Прототип: карточка ленты → кнопки строки управления 21 (поле ленты 2 + 18 + 1 — строка 42 с
                    // кнопками 40): 4 поля [ScrollRibbon], 5 здесь, 8 поля строки и 4 поля цели 48.
                    padding: EdgeInsets.only(bottom: context.space.s1 + 1),
                    child: _subcategoryRibbon(l10n, ribbonParent, hPad),
                  ),
                ),
              if (_isSearch && strip != null)
                SliverToBoxAdapter(key: const ValueKey<String>('catalog-sliver-chips'), child: strip),
              PinnedHeaderSliver(
                key: const ValueKey<String>('catalog-sliver-toolbar'),
                child: ColoredBox(
                  color: c.background,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        // Прототип: кнопки строки управления → сетка 15 (1 до края строки 42 + 14): 4 поля цели 48,
                        // 3 здесь и 8 сверху у списка.
                        padding: EdgeInsets.fromLTRB(start, context.space.s2, side, context.space.s1 - 1),
                        child: CatalogToolbarRow(
                          presets: _presets(l10n, list),
                          controls: controlsFor,
                          viewLabels: <String>[
                            l10n.catalog_view_grid,
                            l10n.catalog_view_list,
                            l10n.catalog_view_compact,
                          ],
                          sortLabel: catalogSortLabel(l10n, _effectiveSort, search: _isSearch),
                          filtersLabel: l10n.catalog_filters_button,
                          found: found,
                          filterCount: _filter.activeCount,
                        ),
                      ),
                      activeFilters,
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                key: const ValueKey<String>('catalog-sliver-filters'),
                child: _filterPanelOpen
                    ? Padding(
                        padding: EdgeInsets.fromLTRB(start, 0, side, context.space.s2),
                        child: _inlineFilters(l10n, list, role, loading: switching),
                      )
                    : const SizedBox.shrink(),
              ),
            ];
      final List<ProductSummary> items = _isSearch ? _matchFiltered(list.items) : list.items;
      final Widget products = CatalogProductView(
        // Ключ постоянный: смена выборки не пересоздаёт список и фото карточек (карточки — по id товара).
        key: const ValueKey<String>('catalog-product-view'),
        scrollController: _listScroll,
        state: list,
        items: items,
        view: _effectiveView(wc),
        windowClass: wc,
        cardContext: cardContext,
        padding: listPadding,
        headerSlivers: headerSlivers,
        inert: switching,
        // Сетка SCR-10/11/12 по прототипу: карточка от 176, зазор 16 (SCR-50 — прежние 160).
        minCardWidth: DsBreakpoints.catalogCardMinWidth,
        gridGap: context.space.s4,
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
      listArea = Stack(
        children: <Widget>[
          Positioned.fill(child: products),
          if (switching || fresh.refreshing)
            Positioned(
              top: 0,
              left: compact ? side : start,
              right: side,
              child: AppProgress.linear(
                key: CatalogWorkspace.refreshBarKey,
                thin: true,
                semanticLabel: l10n.ds_loading,
              ),
            ),
        ],
      );
    }

    final Widget body;
    if (compact) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          header,
          ?banner,
          ?strip,
          if (productsShown)
            Padding(
              padding: hPad,
              child: SizedBox(
                height: 48,
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: CatalogTitleBlock(title: title, found: found, compact: true),
                    ),
                    controlsFor(false),
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
          // Без списка (категория удалена, запрос короче минимума) заголовок — над областью сообщения.
          if (!productsShown)
            Padding(
              padding: EdgeInsets.fromLTRB(start, context.space.s6, side, context.space.s2),
              child: CatalogTitleBlock(
                title: categoryMissing ? '' : title,
                found: found,
                breadcrumbs: crumbs,
                showFound: false,
              ),
            ),
          ?searchNote,
          Expanded(child: listArea),
        ],
      );
      // Корзина сотрудника на medium и шире — кнопка-итог в шапке и drawer 420 (ADR-112), постоянной CP нет.
      // `CartFab` над нижней кромкой (02 UI-20-019 редакции 1.16) — только у `customer` на medium (D6; корзина
      // клиента — по кнопке, не закреплена, 02 SCR-50.2 E). Пустая корзина — построитель возвращает пустой виджет.
      final WidgetBuilder? fab = !expanded && role == RoleCode.customer ? ref.watch(catalogCartFabProvider) : null;
      // medium и шире — одна раскладка (прототип 2026-10-29): колонка категорий 132 на фоне страницы · контент.
      // `customer` на expanded/large — прежний сайдбар-список 240/292 со счётчиками, «★ Избранное N» и «Недавние
      // товары» (D6: структура режима клиента сохраняется). Колонка сворачивается до 72 (настройка пользователя).
      final bool customerList = expanded && role == RoleCode.customer;
      final Widget sidebar = CatalogSidebar(
        key: const ValueKey<String>('catalog-sidebar-column'),
        layout: customerList ? CatalogSidebarLayout.list : CatalogSidebarLayout.tiles,
        selectedCategoryId: widget.categoryId,
        collapsed: _sidebarCollapsed,
        onToggleCollapsed: _toggleSidebar,
        onCategory: _openCategory,
        onFavorites: () => _go(CatalogPaths.favorites),
        onRecentProduct: _openProductId,
        onClearRecent: _clearRecent,
      );
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          header,
          ?banner,
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (customerList)
                  Container(
                    // Свёрнутый — 72; иначе 292 в окне от 1280 и 240 уже (как до ADR-112).
                    width: _sidebarCollapsed
                        ? CatalogSidebar.collapsedWidth
                        : (MediaQuery.sizeOf(context).width >= 1280
                              ? DsBreakpoints.sidebarWide
                              : DsBreakpoints.sidebarNarrow),
                    decoration: BoxDecoration(
                      color: c.surface,
                      border: Border(right: BorderSide(color: c.border)),
                    ),
                    child: sidebar,
                  )
                else
                  SizedBox(
                    width: _sidebarCollapsed ? CatalogSidebar.collapsedWidth : CatalogSidebar.tilesWidth,
                    child: sidebar,
                  ),
                // Якорь панели SCR-14 поверх контент-колонки (колонка категорий видна — 02 SCR-14.2, EQ-PD-05).
                Expanded(child: DsContentRegion(child: content)),
              ],
            ),
          ),
          ?fab?.call(context),
        ],
      );
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
          // Постоянный ключ: смена режима root/category/search не пересоздаёт поддерево экрана.
          key: const ValueKey<String>('catalog-workspace-scaffold'),
          backgroundColor: c.background,
          body: Stack(
            fit: StackFit.passthrough,
            children: <Widget>[
              SafeArea(child: body),
              // Невидимый маркер экрана (ключи `stub-SCR-10/11/12` с этапа основы маршрутов; тесты и
              // integration_test опираются на них) — без смены ключа предков.
              Positioned(left: 0, top: 0, child: SizedBox.shrink(key: ValueKey<String>('stub-${_screenId()}'))),
            ],
          ),
        ),
      ),
    );
  }

  String _screenId() => switch (widget.mode) {
    CatalogScreenMode.root => 'SCR-10',
    CatalogScreenMode.search => 'SCR-11',
    CatalogScreenMode.category => 'SCR-12',
  };

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

  /// Родитель ленты подкатегорий: текущая категория, если у неё есть непустые дети; иначе родитель текущей
  /// (лента соседей с выбранной текущей). Пустые подкатегории (0 товаров) в ленту не входят, как в полосе чипов.
  static Category? _ribbonParent(CategoryTree? t, Category? cat) {
    if (t == null || cat == null) {
      return null;
    }
    bool visible(Category p) => p.children.any((Category ch) => ch.productCount > 0);
    if (cat.children.isNotEmpty) {
      return visible(cat) ? cat : null;
    }
    final String? parentId = cat.parentId;
    final Category? parent = parentId == null ? null : t.find(parentId);
    return parent != null && visible(parent) ? parent : null;
  }

  /// Лента подкатегорий (прототип 2026-10-29): «Все товары» (родитель, нейтральная иконка-сетка — не картинка
  /// родителя) + подкатегории; карточки 118×148 с картинкой категории из данных, без неё — нейтральная заглушка DS.
  /// Смена подкатегории — `go` на expanded (тот же экран, меняется только список), `push` на medium.
  Widget _subcategoryRibbon(AppLocalizations l10n, Category parent, EdgeInsets padding) {
    final List<Category> children = parent.children.where((Category ch) => ch.productCount > 0).toList();
    final String? current = widget.categoryId;
    final int index = current == parent.id ? 0 : children.indexWhere((Category ch) => ch.id == current) + 1;
    return ScrollRibbon(
      key: const ValueKey<String>('catalog-subcategory-ribbon'),
      // Лента другой категории начинается с начала (прокрутка прежней не переносится).
      setId: parent.id,
      itemCount: children.length + 1,
      itemSize: CategoryTile.ribbonSize,
      selectedIndex: index > 0 || current == parent.id ? index : null,
      previousLabel: l10n.category_ribbon_prev,
      nextLabel: l10n.category_ribbon_next,
      padding: padding,
      itemBuilder: (BuildContext context, int i) {
        if (i == 0) {
          return CategoryTile(
            key: const ValueKey<String>('chip-sub-all'),
            variant: CategoryTileVariant.ribbon,
            label: l10n.catalog_title_all,
            selected: current == parent.id,
            countLabel: '${parent.productCount}',
            // Видимая подпись «Все товары» входит в доступное имя (WCAG 2.5.3): «Все товары: Сантехника, 124 товара».
            semanticLabel: l10n.category_ribbon_all_a11y(parent.productCount, parent.name),
            onTap: () => _openCategory(parent),
          );
        }
        final Category ch = children[i - 1];
        return CategoryTile(
          key: ValueKey<String>('chip-sub-${ch.id}'),
          variant: CategoryTileVariant.ribbon,
          label: ch.name,
          imageUrl: ch.imageUrl,
          iconKey: ch.iconKey,
          selected: current == ch.id,
          // Число товаров подкатегории — пилюлей в углу карточки (паритет функций ADR-112: прежние чипы со счётчиком).
          countLabel: '${ch.productCount}',
          semanticLabel: l10n.category_tile_a11y(ch.productCount, ch.name),
          onTap: () => _openCategory(ch),
        );
      },
    );
  }

  /// Подборки строки управления (прототип 2026-10-29: «Новые», «Избранные»; 02 C6 — «Недавние»): «Новые» —
  /// сортировка `updatedAt:desc` (недоступна в подборке «Недавние»: там порядок просмотра; признака «новинка» API не
  /// даёт — Q-335), «Избранные» — фильтр `favorite`, «Недавние» — подборка недавних товаров с действием «Очистить»
  /// (B6). Выбранная — залитая иконка. SCR-11 — только «Избранные» (прототип: фильтр работает и при поиске; «Новые» —
  /// нет: поиск не сортирует по `updatedAt`, «Недавние» — подборка каталога).
  CatalogPresetBarData? _presets(AppLocalizations l10n, CatalogListState list) {
    final CatalogStripChip favorites = CatalogStripChip(
      key: 'preset-favorites',
      label: l10n.catalog_preset_favorites_toolbar,
      icon: Icons.star_outline_rounded,
      selectedIcon: Icons.star_rounded,
      selected: _filter.favorite == true && !_recent,
      reselect: true,
      onTap: _togglePresetFavorites,
    );
    if (_isSearch) {
      return CatalogPresetBarData(chips: <CatalogStripChip>[favorites]);
    }
    final bool shelf = ref.read(catalogShelfPortProvider) != null;
    return CatalogPresetBarData(
      chips: <CatalogStripChip>[
        CatalogStripChip(
          key: 'preset-newest',
          label: l10n.catalog_preset_newest,
          icon: Icons.schedule_rounded,
          selectedIcon: Icons.access_time_filled_rounded,
          selected: !_recent && _effectiveSort == CatalogSort.updatedAtDesc,
          enabled: !_recent,
          reselect: true,
          onTap: _toggleNewest,
        ),
        favorites,
        if (shelf)
          CatalogStripChip(
            key: 'preset-recent',
            label: l10n.catalog_preset_recent,
            icon: Icons.history_rounded,
            selectedIcon: Icons.history_toggle_off_rounded,
            selected: _recent,
            reselect: true,
            // Узкая строка (1280 lp): «Недавние» — иконкой с тултипом, подписи вида остаются (02 П.3 п. 4).
            collapsible: true,
            onTap: _togglePresetRecent,
          ),
      ],
      clearRecentLabel: shelf && _recent ? l10n.catalog_recent_clear : null,
      onClearRecent: shelf && _recent && list.items.isNotEmpty ? () => unawaited(_clearRecent()) : null,
    );
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
      // compact — лист «Все категории»; medium+ — корень (категории — в колонке слева).
      onAction: () =>
          context.windowClass == WindowClass.compact ? unawaited(_openAllCategories()) : _go(_rootLocation()),
    );
  }

  /// Встроенная панель фильтров medium+ (прототип 2026-10-29): черновик [_panelDraft], применение через 300 мс
  /// ([_onPanelChanged]); «Сбросить фильтры» — сразу.
  Widget _inlineFilters(AppLocalizations l10n, CatalogListState list, RoleCode? role, {required bool loading}) {
    final CatalogFilter draft = _panelDraft ?? _filter;
    final List<Warehouse> warehouses = role == RoleCode.customer
        ? const <Warehouse>[]
        : (ref.watch(catalogWarehousesProvider).value ?? const <Warehouse>[]);
    return buildCatalogFilterInline(
      context: context,
      filter: draft,
      onUpdate: (CatalogFilter Function(CatalogFilter current) update) =>
          _onPanelChanged(update(_panelDraft ?? _filter)),
      price: _price,
      role: role,
      facets: list.facets,
      facetsLoading: loading || list.phase == CatalogListPhase.loading || list.refreshing,
      warehouses: warehouses,
      showAllBrands: _showAllBrands,
      onToggleShowAllBrands: () => setState(() => _showAllBrands = !_showAllBrands),
      onReset: () {
        final CatalogFilter cleared = CatalogFilterCodec.cleared(draft);
        _panelDebounce?.cancel();
        _price.sync(cleared);
        setState(() => _panelDraft = null);
        _applyFilter(cleared);
        // «Сбросить фильтры» снимает и «Новые» (прототип: `resetFilters` сбрасывает «в наличии», «Новые» и
        // «Избранные»): «Новые» подсвечены при любом источнике сортировки `updatedAt:desc` — кнопка в этом экземпляре,
        // сохранённая настройка, ссылка `?sort=updatedAt:desc`, пункт «Сначала новые» меню сортировки. Возврат — к
        // сортировке до «Новых», если её включили кнопкой здесь, иначе — к сортировке по умолчанию (по названию А–Я).
        if (!_isSearch && _effectiveSort == CatalogSort.updatedAtDesc) {
          _toggleNewest();
        }
      },
      offlineNote: list.offline
          ? l10n.filters_offline_note(CatalogFormats.time(list.asOf ?? ref.read(clockProvider).nowUtc()))
          : null,
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
