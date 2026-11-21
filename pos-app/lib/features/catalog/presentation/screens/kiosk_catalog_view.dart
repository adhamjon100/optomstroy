// SCR-51 «Планшет магазина: витрина и корзина» (`/kiosk?c=`, роль `kiosk` — технический пользователь планшета;
// покупатель — без учётной записи; 02 ч. F SCR-51; P-002 §8.8; ADR-115 п. 8, 22, 23; 13 TAB-2-03). Содержимое экрана —
// часть фичи catalog (как SCR-50 `customer_home_view.dart`); экран режима `KioskShellScreen` фичи kiosk получает его
// через порт `kioskCatalogBodyProvider`, привязка — корень `app/router/shells/kiosk_mode_bindings.dart`.
//
// Экран выбора товаров ADR-114 в варианте покупателя из публичных частей рабочего пространства сотрудника (сам
// `CatalogWorkspace` не меняется — паритет функций, 01 GEN-256): шапка [KioskCatalogHeader] (логотип с аварийным
// выходом, поиск без сканера и без «Недавних запросов», «Обычные цены магазина», «Начать заново», кнопка корзины —
// drawer 420); колонка корневых категорий `CatalogSidebar.tiles` 144 без «Избранного» и «Недавних»; заголовок 30/800,
// лента подкатегорий `ScrollRibbon` + `CategoryTile.ribbon`; строка управления «Найдено» · вид · сортировка ·
// «Фильтры» без подборок; встроенная панель фильтров без склада и «Только избранное»; сетка `CatalogProductView` от
// 176 lp без звёзд, наличие — по `customer_stock_display` (при `status` — без чисел, 10 KIOSK-007).
//
// Состояние — только в памяти экрана (11 PRIV-033, 10 KIOSK-021): категория (выбрана всегда; при первом показе и после
// сброса — корень с наибольшим числом товаров, `catalogStartRoot` без `catalog_last_root`), поиск, фильтры, вид,
// сортировка, прокрутка. Ни история поиска, ни настройки каталога не пишутся (`searchHistoryProvider` и
// `catalogPrefsProvider` экран не читает). Адрес `/kiosk?c=<категория>` экран пишет сам заменой записи
// (`Router.neglect`, история браузера не растёт); строку поиска в адрес не пишет (02 ч. F, правило 3: поисковые
// запросы покупателя не пишутся в адрес). Адрес при первом показе не восстанавливается (02 SCR-51.11, deep links не
// исполняются); изменённый извне адрес (`go('/kiosk')` — сброс, другая категория) экран принимает.
//
// Карточка товара — слой [KioskProductSheet] поверх `/kiosk` без маршрута (порт `catalogKioskProductDetailsProvider`);
// «+ Добавить» — порт корзины `catalogCartPortProvider` (у планшета — прямой `PUT /cart/items/{variantId}`, без drift и
// очереди). Без связи (`catalogOnlineStatusProvider` — `offline` или `serverDown`: сеть есть, сервер не отвечает, как
// у корзины планшета и SCR-52; или ответ списка `NetworkFailure`) — баннер «Нет связи…» (UI-51-014), витрина из кэша,
// «+ Добавить» недоступна; так же при `426` и метке сброса без сети (`cartOrderingBlockedProvider`). Баннер UI-51-014 —
// один, под шапкой во всю ширину: при `426` (`catalogKioskUpdateNeededProvider`) — «Планшет нужно обновить» с иконкой
// `system_update`, иначе без связи — «Нет связи…» с иконкой `wifi_off`. Отметки времени данных покупателю нет (02
// SCR-51.7): ни на карточках (`CatalogCardContext.showsDataAge`), ни в панели фильтров. Связь вернулась —
// дерево и список перезапрашиваются, работа продолжается без перезапуска (AC-UI-51-008, 12 T-KIOSK-032).
//
// Окно уже 600 lp (compact; режим на нём не включается, SCR-54 отклоняет подключение) — раскладка medium с
// горизонтальной прокруткой [ТИПОВО] (02 SCR-51.2).
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
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
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/scroll_ribbon.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_list_controller.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/providers/category_tree_provider.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_filter_codec.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';
import 'package:optomstroy/features/catalog/presentation/state/search_input_policy.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_card_mapper.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_filter_form.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_product_view.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_sidebar.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_toolbar.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/category_icon.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/kiosk_catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/kiosk_product_sheet.dart';

/// Ключи элементов SCR-51 (тесты).
abstract final class KioskCatalogKeys {
  /// Корень экрана.
  static const Key root = ValueKey<String>('scr-51');

  /// Поле поиска шапки (UI-51-003).
  static const Key searchField = ValueKey<String>('kiosk-search-field');

  /// Колонка корневых категорий (UI-51-007).
  static const Key sidebar = ValueKey<String>('kiosk-sidebar');

  /// Баннер «Нет связи…» (UI-51-014).
  static const Key offlineBanner = ValueKey<String>('kiosk-offline-banner');

  /// Баннер «Планшет нужно обновить» (`426`, UI-51-014) — вместо «Нет связи…».
  static const Key updateBanner = ValueKey<String>('kiosk-update-banner');

  /// Тонкая полоса загрузки над списком (смена категории, поиск, обновление из кэша).
  static const Key refreshBar = ValueKey<String>('kiosk-list-refreshing');
}

/// Тело витрины SCR-51 (подставляется в `KioskShellScreen` фичи kiosk).
class KioskCatalogView extends ConsumerStatefulWidget {
  const KioskCatalogView({super.key, this.categoryId});

  /// `c` адреса `/kiosk?c=`: при первом показе не применяется (стартовая категория, 02 SCR-51.11); изменение извне —
  /// выбор этой категории, голый `/kiosk` — сброс витрины к стартовой категории.
  final String? categoryId;

  /// Путь витрины (`app/router/kiosk_routes.dart` `KioskPaths.showcase`; catalog ↛ app — литерал).
  static const String path = '/kiosk';

  /// Адрес витрины с категорией [categoryId] (без строки поиска — правило 3 ч. F).
  static String locationFor(String? categoryId) =>
      categoryId == null ? path : '$path?c=${Uri.encodeQueryComponent(categoryId)}';

  @override
  ConsumerState<KioskCatalogView> createState() => _KioskCatalogViewState();
}

class _KioskCatalogViewState extends ConsumerState<KioskCatalogView> {
  /// Набор ленты «весь каталог» (корневые категории в поиске) — для сброса прокрутки ленты при смене набора.
  static const String _wholeRibbonId = '\u0000kiosk-all';

  /// Выбранная категория (корень или подкатегория); `null` — дерево ещё не пришло или пусто («Все товары»).
  String? _categoryId;

  /// Категория, которую экран сам записал в адрес (или принял из адреса) — изменение адреса извне отличается от своего.
  String? _locationCategory;

  /// Действующая строка поиска (≥ 2 символов или цифры — `SearchInputPolicy`); пусто — категория.
  String _query = '';
  final TextEditingController _searchText = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'kiosk-search');
  late final SearchInputController _input = SearchInputController(onQuery: _onQuery);

  ProductViewMode? _view;
  CatalogSort? _catalogSort;
  CatalogSort? _searchSort;

  /// Фильтры без категории (категория — [_categoryId]; переживают смену категории, как у сотрудника).
  CatalogFilter _filter = const CatalogFilter();
  late final CatalogFilterPriceControllers _price = CatalogFilterPriceControllers(_filter);
  bool _filterPanelOpen = false;
  CatalogFilter? _panelDraft;
  Timer? _panelDebounce;
  bool _showAllBrands = false;

  /// Товары, для которых «+ Добавить» выполняется: повторные нажатия не уходят в корзину (SCR-51.11).
  final Set<String> _adding = <String>{};

  final ScrollController _listScroll = ScrollController();
  CatalogListKey? _scrolledKey;

  /// Последний показанный список с данными: при смене выборки прежние карточки остаются неактивными с тонкой
  /// полосой загрузки, пока не придут новые (как SCR-10, ADR-110).
  CatalogListState? _shownList;

  /// «Начать заново» выполняется (кнопка в загрузке, повтор игнорируется).
  bool _startingOver = false;

  bool get _searching => SearchInputPolicy.canSearch(_query);

  @override
  void initState() {
    super.initState();
    // Новый покупатель — первый показ и автосброс FLOW-045 (каркас режима строит тело заново, 13 TAB-2-05): общие
    // экземпляры каталога в памяти — заново, после кадра.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _dropSharedMemory();
    });
  }

  @override
  void didUpdateWidget(KioskCatalogView old) {
    super.didUpdateWidget(old);
    final String? c = widget.categoryId;
    if (c == old.categoryId || c == _locationCategory) {
      return;
    }
    // Адрес изменён не экраном: голый `/kiosk` (сброс FLOW-045, переход с SCR-53, G-15) — стартовая категория и
    // пустое состояние; другая категория — её выбор, если она есть в дереве. Правка состояния — после кадра (не во
    // время построения предка).
    _locationCategory = c;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      if (c == null) {
        _resetLocal();
        return;
      }
      final Category? target = ref.read(categoryTreeProvider).tree?.find(c);
      if (target != null) {
        _openCategory(target);
      } else {
        _writeLocation();
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

  // ---------------------------------------------------------------- адрес

  /// Записать `/kiosk?c=` заменой записи; только когда витрина сверху (над ней нет SCR-52, drawer, слоя): иначе
  /// `go` закрыл бы их.
  void _writeLocation() {
    if (!mounted) return;
    final GoRouter? r = GoRouter.maybeOf(context);
    if (r == null || ModalRoute.of(context)?.isCurrent == false) return;
    final String target = KioskCatalogView.locationFor(_categoryId);
    _locationCategory = _categoryId;
    if (r.routeInformationProvider.value.uri.toString() == target) return;
    Router.neglect(context, () => r.go(target));
  }

  void _scheduleWrite() => WidgetsBinding.instance.addPostFrameCallback((Duration _) => _writeLocation());

  // ---------------------------------------------------------------- категории и поиск

  void _clearSearch() {
    _query = '';
    _searchText.clear();
    _input.reset('');
  }

  void _openCategory(Category cat) {
    if (!_searching && cat.id == _categoryId) return;
    _panelDebounce?.cancel();
    setState(() {
      _categoryId = cat.id;
      _clearSearch();
      _panelDraft = null;
      _showAllBrands = false;
    });
    _scheduleWrite();
  }

  /// Ввод в поле поиска: короче минимума — снова категория (история запросов не показывается, KIOSK-021).
  void _onSearchChanged(String text) {
    if (_query.isNotEmpty && !SearchInputPolicy.canSearch(text)) {
      setState(() => _query = '');
      _input.reset('');
    }
    _input.changed(text);
  }

  /// Запрос поиска (debounce 300 мс или Enter): результаты — в зоне D этого же экрана; в `search_history` не
  /// пишется (02 UI-51-003, AC-UI-51-004).
  void _onQuery(String q) {
    if (!mounted) return;
    setState(() => _query = q);
  }

  // ---------------------------------------------------------------- вид, сортировка, фильтры (только память)

  ProductViewMode _effectiveView(WindowClass wc) => _view ?? CatalogDefaults.viewFor(wc);

  CatalogSort get _effectiveSort =>
      _searching ? (_searchSort ?? CatalogDefaults.searchSort) : (_catalogSort ?? CatalogDefaults.catalogSort);

  void _setView(ProductViewMode mode) => setState(() => _view = mode);

  void _setSort(CatalogSort sort) => setState(() {
    if (_searching) {
      _searchSort = sort;
    } else {
      _catalogSort = sort;
    }
  });

  void _applyFilter(CatalogFilter next) {
    final CatalogFilter f = rebuildFilter(next, categoryId: null);
    if (priceRangeInvalid(f) || CatalogFilterCodec.same(f, _filter)) return;
    _panelDebounce?.cancel();
    setState(() {
      _filter = f;
      _panelDraft = null;
    });
    _price.sync(f);
  }

  /// Изменение во встроенной панели фильтров: применение через 300 мс (02 SCR-13.4).
  void _onPanelChanged(CatalogFilter draft) {
    setState(() => _panelDraft = draft);
    _panelDebounce?.cancel();
    _panelDebounce = Timer(SearchInputPolicy.debounce, () {
      if (!mounted) return;
      final CatalogFilter? d = _panelDraft;
      if (d != null && !priceRangeInvalid(d)) _applyFilter(d);
    });
  }

  void _toggleFilters() => setState(() {
    _filterPanelOpen = !_filterPanelOpen;
    _panelDraft = null;
  });

  CatalogListKey? _listKey({required bool awaitingStart}) {
    if (_searching) {
      // Поиск планшета — по всему каталогу (как SCR-11 из каталога), без склада и вида цены (KIOSK-006, KIOSK-007).
      return CatalogListKey.search(q: _query, filter: _filter, sort: _effectiveSort);
    }
    if (awaitingStart) return null;
    return CatalogListKey.catalog(
      filter: rebuildFilter(_filter, categoryId: _categoryId),
      sort: _effectiveSort,
    );
  }

  // ---------------------------------------------------------------- «Начать заново» (FLOW-045.S3–S4)

  /// Состояние витрины — как у нового покупателя: стартовая категория, пустой поиск, фильтры, вид и сортировка по
  /// умолчанию, прокрутка к началу, закрытая панель фильтров (02 UI-51-005, AC-UI-51-002, AC-UI-51-015).
  void _resetLocal() {
    _panelDebounce?.cancel();
    final CategoryTreeState tree = ref.read(categoryTreeProvider);
    setState(() {
      _clearSearch();
      _filter = const CatalogFilter();
      _panelDraft = null;
      _filterPanelOpen = false;
      _showAllBrands = false;
      _view = null;
      _catalogSort = null;
      _searchSort = null;
      _shownList = null;
      _categoryId = catalogStartRoot(tree.tree?.roots ?? const <Category>[])?.id;
    });
    _price.sync(_filter);
    _searchFocus.unfocus();
    _dropSharedMemory();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _listScroll.hasClients && _listScroll.offset != 0) _listScroll.jumpTo(0);
    });
    _scheduleWrite();
  }

  /// Общие экземпляры каталога в памяти процесса — заново: настройки (`catalogPrefsProvider`) и история поиска
  /// (`searchHistoryProvider`). Экран их не читает и не пишет, хранилища настроек у планшета нет; сброс — защита на
  /// случай ошибки: следующему покупателю не достаётся ничего от прежнего (02 UI-51-005; 10 KIOSK-021; 11 PRIV-033).
  void _dropSharedMemory() {
    ref
      ..invalidate(catalogPrefsProvider)
      ..invalidate(searchHistoryProvider);
  }

  /// «Начать заново» без подтверждения (02 SCR-51.4): сразу — состояние витрины, затем сброс планшета
  /// ([catalogKioskStartOverProvider]: новая корзина, буфер обмена); повторное нажатие во время сброса игнорируется.
  Future<void> _startOver() async {
    if (_startingOver) return;
    final Future<void> Function()? reset = ref.read(catalogKioskStartOverProvider);
    _resetLocal();
    if (reset == null) return;
    setState(() => _startingOver = true);
    try {
      await reset();
    } on Object {
      // Сбой сброса показывает и повторяет оркестратор сброса (метка сброса без сети); витрина уже сброшена.
    } finally {
      if (mounted) setState(() => _startingOver = false);
    }
  }

  // ---------------------------------------------------------------- карточки

  /// Слой карточки товара (UI-51-011); второе нажатие, пока слой открыт, слой не открывает повторно
  /// ([KioskProductSheet.show]).
  void _openProduct(ProductSummary p) {
    final CatalogKioskProductBuilder? builder = ref.read(catalogKioskProductDetailsProvider);
    if (builder == null) return;
    final CatalogKioskProductArgs args = (productId: p.id, variantId: p.hasVariants ? null : p.defaultVariantId);
    unawaited(KioskProductSheet.show(context, semanticLabel: p.name, body: (BuildContext ctx) => builder(ctx, args)));
  }

  /// «+ Добавить» (UI-51-010): прямой запрос корзины планшета; нажатия во время запроса игнорируются; отказ — снекбар
  /// (без связи — «Корзина не сохранена»), успех — короткий тост «Добавлено: …» внизу справа (итог — на кнопке
  /// корзины в шапке).
  Future<void> _onCardAction(ProductSummary p, {required bool addDisabled}) async {
    final CatalogCartPort? cart = ref.read(catalogCartPortProvider);
    if (p.hasVariants || cart == null) {
      // SCR-15 (выбор варианта) и «+ Добавить» без корзины — через карточку товара.
      _openProduct(p);
      return;
    }
    if (addDisabled || _adding.contains(p.id)) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
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
    if (!mounted) return;
    if (r case FailureResult<void>(:final failure)) {
      AppSnackbar.show(
        context,
        message: cart.rejectionText(failure, l10n) ?? l10n.error_internal,
        variant: AppSnackbarVariant.error,
      );
    } else {
      AppSnackbar.show(
        context,
        message: l10n.catalog_added_toast(p.name),
        variant: AppSnackbarVariant.success,
        brief: true,
        placement: AppSnackbarPlacement.bottomEnd,
      );
    }
  }

  // ---------------------------------------------------------------- построение

  /// Новая выборка показана — к началу списка (02 SCR-10.11).
  void _syncScroll(CatalogListKey? key, CatalogListState shown) {
    if (key == _scrolledKey || shown.phase == CatalogListPhase.loading) return;
    final bool first = _scrolledKey == null;
    _scrolledKey = key;
    if (first) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _listScroll.hasClients && _listScroll.offset != 0) _listScroll.jumpTo(0);
    });
  }

  /// «Нет связи» витрины (UI-51-014): сети нет или сервер не отвечает (`serverDown` — таймауты, `502`–`504`). Только
  /// SCR-51: каталог сотрудника и SCR-50 при `serverDown` работают из кэша с очередью, как прежде.
  static bool _noLink(OnlineStatus s) => s == OnlineStatus.offline || s == OnlineStatus.serverDown;

  void _reloadAfterReconnect() {
    final CategoryTreeState tree = ref.read(categoryTreeProvider);
    if (!tree.authoritative) unawaited(ref.read(categoryTreeProvider.notifier).refresh());
    final CatalogListKey? key = _listKey(awaitingStart: _categoryId == null && tree.loading);
    if (key != null) unawaited(ref.read(catalogListProvider(key).notifier).reload());
  }

  @override
  Widget build(BuildContext context) {
    // Связь вернулась — без перезапуска: свежее дерево и список (AC-UI-51-008).
    ref.listen<OnlineStatus>(catalogOnlineStatusProvider, (OnlineStatus? prev, OnlineStatus next) {
      if (prev != null && _noLink(prev) && next == OnlineStatus.online) _reloadAfterReconnect();
    });
    final MediaQueryData mq = MediaQuery.of(context);
    if (mq.size.width >= DsBreakpoints.medium) {
      return KeyedSubtree(key: KioskCatalogKeys.root, child: _content(context));
    }
    // compact: раскладка medium 600 с горизонтальной прокруткой [ТИПОВО] (02 SCR-51.2).
    const Size medium = Size(DsBreakpoints.medium, 0);
    return KeyedSubtree(
      key: KioskCatalogKeys.root,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: medium.width,
            height: box.maxHeight,
            child: MediaQuery(
              data: mq.copyWith(size: Size(medium.width, mq.size.height)),
              child: Builder(builder: _content),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final WindowClass wc = context.windowClass;
    final CategoryTreeState tree = ref.watch(categoryTreeProvider);
    final List<Category> roots = tree.tree?.roots ?? const <Category>[];

    // Категория выбрана всегда (02 UI-51-007): при первом показе, после сброса и если выбранная исчезла из дерева —
    // корень с наибольшим числом товаров. Дерева нет и не будет (ошибка без кэша, пустое) — «Все товары».
    if (_categoryId != null && tree.authoritative && tree.tree?.find(_categoryId!) == null) {
      _categoryId = null;
    }
    if (_categoryId == null) {
      final Category? start = catalogStartRoot(roots);
      if (start != null) {
        _categoryId = start.id;
        _scheduleWrite();
      }
    }
    final bool awaitingStart = _categoryId == null && tree.loading;
    final CatalogListKey? key = _listKey(awaitingStart: awaitingStart);
    final CatalogListState fresh = key == null ? const CatalogListState() : ref.watch(catalogListProvider(key));
    final bool switching =
        fresh.phase == CatalogListPhase.loading && _shownList != null && _shownList!.items.isNotEmpty;
    final CatalogListState list = switching ? _shownList! : fresh;
    if (fresh.phase != CatalogListPhase.loading) _shownList = fresh;
    _syncScroll(key, fresh);

    final OnlineStatus online = ref.watch(catalogOnlineStatusProvider);
    final bool offline = list.offline || _noLink(online);
    final bool updateNeeded = ref.watch(catalogKioskUpdateNeededProvider);
    // «+ Добавить» недоступна без связи, при `426`, полноэкранных состояниях и метке сброса без сети (UI-51-010).
    final bool addDisabled = offline || ref.watch(cartOrderingBlockedProvider);
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final Category? category = _categoryId == null ? null : tree.tree?.find(_categoryId!);
    final List<Category> path = _categoryId == null || tree.tree == null
        ? const <Category>[]
        : tree.tree!.pathTo(_categoryId!);

    final CatalogCardContext cardContext = CatalogCardContext(
      l10n: l10n,
      now: now,
      // Роль витрины — всегда покупатель планшета (как SCR-50 — `customer`): без чисел остатка при `status`.
      role: RoleCode.kiosk,
      offline: offline,
      showMatch: _searching,
      customerStockDisplay: ref.watch(catalogCustomerStockDisplayProvider),
      busyIds: Set<String>.unmodifiable(_adding),
      addDisabled: addDisabled,
    );

    final Widget searchField = CatalogSearchField(
      fieldKey: KioskCatalogKeys.searchField,
      controller: _searchText,
      focusNode: _searchFocus,
      windowClass: wc,
      onChanged: _onSearchChanged,
      onSubmitted: _input.submit,
      loading: _searching && (list.refreshing || switching),
    );
    final Widget header = KioskCatalogHeader(
      windowClass: wc,
      search: searchField,
      onStartOver: () => unawaited(_startOver()),
      startingOver: _startingOver,
    );

    const EdgeInsets main = DsCatalogMetrics.mainPadding;
    final EdgeInsets hPad = EdgeInsets.only(left: main.left, right: main.right);
    final EdgeInsets listPadding = EdgeInsets.fromLTRB(main.left, context.space.s2, main.right, main.bottom);

    // Лента: в категории — дети категории, в листовой подкатегории — её соседи с выбранной текущей; в поиске —
    // корневые категории с выбранной «Все товары» (нажатие корня — выход из поиска в категорию).
    final Category? ribbonParent = _searching || category == null
        ? null
        : (_ribbonParent(tree.tree, category) ?? category);
    final String? selectedSub = category == null || category.id == ribbonParent?.id ? null : category.id;
    final Widget? ribbon = ribbonParent != null
        ? _ribbon(
            l10n,
            padding: hPad,
            setId: ribbonParent.id,
            items: ribbonParent.children,
            // Предки карточек ленты (иконка подкатегории без своей — по родителю, затем выше).
            ancestors: tree.tree?.pathTo(ribbonParent.id) ?? const <Category>[],
            selectedId: selectedSub,
            allCount: ribbonParent.productCount,
            allName: ribbonParent.name,
            onAll: () => _openCategory(ribbonParent),
          )
        : (_searching && roots.isNotEmpty
              ? _ribbon(
                  l10n,
                  padding: hPad,
                  setId: _wholeRibbonId,
                  items: roots,
                  selectedId: null,
                  allCount: roots.fold<int>(0, (int sum, Category r) => sum + r.productCount),
                  allName: null,
                  onAll: () {},
                )
              : null);
    final String? title = _searching
        ? l10n.catalog_search_title_query(_query)
        : (awaitingStart ? null : (ribbonParent?.name ?? category?.name ?? l10n.catalog_title_all));
    final String? found = _foundText(l10n, list);

    Widget controlsFor(bool showViewText) => CatalogToolbarControls(
      view: _effectiveView(wc),
      onView: _setView,
      sort: _effectiveSort,
      onSort: _setSort,
      searchMode: _searching,
      filterCount: _filter.activeCount,
      onFilters: _toggleFilters,
      compact: false,
      showViewText: showViewText,
      filtersOpen: _filterPanelOpen,
      toolbarStyle: true,
    );

    final List<Widget> headerSlivers = <Widget>[
      SliverToBoxAdapter(
        key: const ValueKey<String>('kiosk-sliver-title'),
        child: Padding(
          padding: EdgeInsets.fromLTRB(main.left, main.top + 4, main.right, 14),
          child: CatalogTitleBlock(title: title, found: found, showFound: false),
        ),
      ),
      if (ribbon != null)
        SliverToBoxAdapter(
          key: const ValueKey<String>('kiosk-sliver-ribbon'),
          child: Padding(padding: const EdgeInsets.only(bottom: 7), child: ribbon),
        ),
      PinnedHeaderSliver(
        key: const ValueKey<String>('kiosk-sliver-toolbar'),
        child: ColoredBox(
          color: c.background,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.fromLTRB(main.left, context.space.s2, main.right, context.space.s1 - 1),
                child: CatalogToolbarRow(
                  // Подборок «Новые», «Избранные», «Недавние» у планшета нет (02 UI-51-009, ADR-115 п. 8).
                  presets: null,
                  controls: controlsFor,
                  viewLabels: <String>[l10n.catalog_view_grid, l10n.catalog_view_list, l10n.catalog_view_compact],
                  sortLabel: catalogSortLabel(l10n, _effectiveSort, search: _searching),
                  filtersLabel: l10n.catalog_filters_button,
                  found: found,
                  filterCount: _filter.activeCount,
                ),
              ),
              CatalogActiveFilters(filter: _filter, onChanged: _applyFilter, padding: hPad),
            ],
          ),
        ),
      ),
      SliverToBoxAdapter(
        key: const ValueKey<String>('kiosk-sliver-filters'),
        child: _filterPanelOpen
            ? Padding(
                padding: EdgeInsets.fromLTRB(main.left, 4, main.right, 6),
                child: _inlineFilters(l10n, list, loading: switching),
              )
            : const SizedBox.shrink(),
      ),
    ];

    final Widget products = CatalogProductView(
      key: const ValueKey<String>('kiosk-product-view'),
      scrollController: _listScroll,
      state: list,
      items: list.items,
      view: _effectiveView(wc),
      windowClass: wc,
      cardContext: cardContext,
      padding: listPadding,
      headerSlivers: headerSlivers,
      inert: switching,
      // Сетка — как SCR-10.2 (ADR-114): от 176, зазор 14; колонок не больше предела класса окна (03 §7.3,
      // уточнение 2026-11-18).
      minCardWidth: DsBreakpoints.catalogCardMinWidth,
      gridGap: DsCatalogMetrics.gridGap,
      callbacks: CatalogProductCallbacks(
        onOpen: _openProduct,
        // Избранного на общем устройстве нет (звёзды скрыты, `favoritesEnabled: false`).
        onFavorite: (ProductSummary p, bool v) {},
        onAction: (ProductSummary p) => unawaited(_onCardAction(p, addDisabled: addDisabled)),
      ),
      onLoadMore: () {
        if (key != null) unawaited(ref.read(catalogListProvider(key).notifier).loadMore());
      },
      onRetry: () {
        if (key != null) unawaited(ref.read(catalogListProvider(key).notifier).reload());
      },
      errorTitle: l10n.catalog_error_title,
      empty: _emptyState(l10n, list),
    );
    final Widget listArea = Stack(
      children: <Widget>[
        Positioned.fill(child: products),
        if (switching || fresh.refreshing)
          Positioned(
            top: 0,
            left: main.left,
            right: main.right,
            child: AppProgress.linear(key: KioskCatalogKeys.refreshBar, thin: true, semanticLabel: l10n.ds_loading),
          ),
      ],
    );

    final Widget sidebar = SizedBox(
      width: CatalogSidebar.widthFor(context, roots, selected: path.isEmpty ? null : path.first.id),
      child: CatalogSidebar(
        key: KioskCatalogKeys.sidebar,
        layout: CatalogSidebarLayout.tiles,
        // В поиске по всему каталогу плитка корня не выбрана; заголовок «Каталог» не нажимается — категория
        // выбрана всегда (02 UI-51-007).
        selectedCategoryId: _searching ? null : _categoryId,
        onCategory: _openCategory,
        onFavorites: () {},
      ),
    );

    return SafeArea(
      child: ColoredBox(
        color: c.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            header,
            // UI-51-014: один баннер под шапкой — `426` важнее «Нет связи».
            if (updateNeeded)
              ErrorState.banner(
                key: KioskCatalogKeys.updateBanner,
                message: l10n.kiosk_update_needed,
                tone: ErrorStateTone.warning,
                icon: Icons.system_update_rounded,
              )
            else if (offline)
              ErrorState.banner(
                key: KioskCatalogKeys.offlineBanner,
                message: l10n.kiosk_offline,
                tone: ErrorStateTone.warning,
                icon: Icons.wifi_off_rounded,
              ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  sidebar,
                  Expanded(child: listArea),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _foundText(AppLocalizations l10n, CatalogListState list) {
    if (list.phase == CatalogListPhase.loading) return null;
    if (list.phase == CatalogListPhase.error || list.phase == CatalogListPhase.offlineNoCache) return '';
    final int count = list.total ?? list.items.length;
    if (_searching) {
      return list.isEstimate ? l10n.search_found_estimate(count, _query) : l10n.search_found_count(count, _query);
    }
    return _categoryId == null ? l10n.catalog_found_count(count) : l10n.category_found_count(count);
  }

  /// Родитель ленты подкатегорий: текущая категория с непустыми детьми, иначе её родитель (лента соседей).
  static Category? _ribbonParent(CategoryTree? t, Category? cat) {
    if (t == null || cat == null) return null;
    bool visible(Category p) => p.children.any((Category ch) => ch.productCount > 0);
    if (cat.children.isNotEmpty) return visible(cat) ? cat : null;
    final String? parentId = cat.parentId;
    final Category? parent = parentId == null ? null : t.find(parentId);
    return parent != null && visible(parent) ? parent : null;
  }

  /// Лента подкатегорий ADR-114 (как SCR-10/12): «Все товары» + непустые [items]; карточки 118×148; без картинки —
  /// иконка категории (своя, иначе предка из [ancestors] — путь от корня до родителя ленты; «Все товары» — глиф
  /// «четыре квадрата»); число товаров — в подсказке и `Semantics`. [selectedId] `null` — выбрана «Все товары».
  Widget _ribbon(
    AppLocalizations l10n, {
    required EdgeInsets padding,
    required String setId,
    required List<Category> items,
    List<Category> ancestors = const <Category>[],
    required String? selectedId,
    required int allCount,
    required String? allName,
    required VoidCallback onAll,
  }) {
    final List<Category> children = items.where((Category ch) => ch.productCount > 0).toList();
    final int found = selectedId == null ? 0 : children.indexWhere((Category ch) => ch.id == selectedId) + 1;
    final int? index = selectedId == null || found > 0 ? found : null;
    String labelOf(int i) => i == 0 ? l10n.catalog_title_all : children[i - 1].name;
    return ScrollRibbon(
      key: const ValueKey<String>('kiosk-subcategory-ribbon'),
      setId: setId,
      itemCount: children.length + 1,
      itemSize: CategoryTile.ribbonSize,
      itemWidthOf: (int i) => CategoryTile.ribbonWidthFor(context, labelOf(i), selected: i == index),
      selectedIndex: index,
      previousLabel: l10n.category_ribbon_prev,
      nextLabel: l10n.category_ribbon_next,
      padding: padding,
      itemBuilder: (BuildContext context, int i) {
        if (i == 0) {
          return CategoryTile(
            key: const ValueKey<String>('chip-sub-all'),
            variant: CategoryTileVariant.ribbon,
            label: l10n.catalog_title_all,
            selected: index == 0,
            countLabel: '$allCount',
            semanticLabel: allName == null
                ? l10n.category_tile_a11y(allCount, l10n.catalog_title_all)
                : l10n.category_ribbon_all_a11y(allCount, allName),
            placeholderGlyph: DsGlyphKind.gridOutline,
            onTap: onAll,
          );
        }
        final Category ch = children[i - 1];
        return CategoryTile(
          key: ValueKey<String>('chip-sub-${ch.id}'),
          variant: CategoryTileVariant.ribbon,
          label: ch.name,
          imageUrl: ch.imageUrl,
          iconKey: ch.iconKey,
          icon: categoryIcon(ch, path: ancestors),
          selected: index == i,
          countLabel: '${ch.productCount}',
          semanticLabel: l10n.category_tile_a11y(ch.productCount, ch.name),
          onTap: () => _openCategory(ch),
        );
      },
    );
  }

  /// Пустой список: белая карточка прототипа на месте сетки (ADR-114); тексты — SCR-10/11 (UI-51-019).
  Widget _emptyState(AppLocalizations l10n, CatalogListState list) {
    final bool filtered = _filter.activeCount > 0;
    if (_searching) {
      final String? suggested = list.suggestedQuery;
      return EmptyState(
        key: const ValueKey<String>('kiosk-empty'),
        variant: EmptyStateVariant.search,
        appearance: EmptyStateAppearance.card,
        title: l10n.ds_empty_search_title(_query),
        body: l10n.search_empty_body,
        actionLabel: filtered ? l10n.ds_button_reset : null,
        onAction: filtered ? () => _applyFilter(CatalogFilterCodec.cleared(_filter)) : null,
        secondaryActionLabel: suggested == null ? null : l10n.search_suggested_query(suggested),
        onSecondaryAction: suggested == null
            ? null
            : () {
                _searchText.text = suggested;
                _input.submit(suggested);
              },
      );
    }
    if (filtered) {
      return EmptyState(
        key: const ValueKey<String>('kiosk-empty'),
        variant: EmptyStateVariant.category,
        appearance: EmptyStateAppearance.card,
        title: l10n.catalog_empty_filtered_title,
        body: l10n.catalog_empty_filtered_body,
        actionLabel: l10n.ds_button_reset,
        onAction: () => _applyFilter(CatalogFilterCodec.cleared(_filter)),
      );
    }
    return EmptyState(
      key: const ValueKey<String>('kiosk-empty'),
      variant: EmptyStateVariant.category,
      appearance: EmptyStateAppearance.card,
      title: l10n.catalog_empty_category_title,
      body: l10n.category_empty_body,
    );
  }

  /// Встроенная панель фильтров (как SCR-10): без склада и «Только избранное» (роль `kiosk`, 02 UI-51-009).
  Widget _inlineFilters(AppLocalizations l10n, CatalogListState list, {required bool loading}) {
    final CatalogFilter draft = _panelDraft ?? _filter;
    return buildCatalogFilterInline(
      context: context,
      filter: draft,
      onUpdate: (CatalogFilter Function(CatalogFilter current) update) =>
          _onPanelChanged(update(_panelDraft ?? _filter)),
      price: _price,
      role: RoleCode.kiosk,
      facets: list.facets,
      facetsLoading: loading || list.phase == CatalogListPhase.loading || list.refreshing,
      warehouses: const <Warehouse>[],
      showAllBrands: _showAllBrands,
      onToggleShowAllBrands: () => setState(() => _showAllBrands = !_showAllBrands),
      onReset: () {
        final CatalogFilter cleared = CatalogFilterCodec.cleared(draft);
        _panelDebounce?.cancel();
        _price.sync(cleared);
        setState(() => _panelDraft = null);
        _applyFilter(cleared);
      },
      // Без отметки времени для покупателя (02 SCR-51.7): «Нет связи» объясняет баннер UI-51-014 над витриной.
      offlineNote: null,
    );
  }
}
