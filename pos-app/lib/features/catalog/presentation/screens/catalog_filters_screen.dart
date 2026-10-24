// SCR-13 Фильтры — маршрут-лист на compact/medium (`/catalog/filters?f=`, staff и customer; 02 ч. B):
// `FilterSheet` с черновиком: изменения не применяются до «Показать N товаров» (pop с новым `f`);
// «Назад»/крестик — закрыть без применения (AC-UI-13-005). N — `totalEstimate` запроса
// `GET /catalog/products?…&limit=1` через 300 мс после изменения (UI-13-011); 0 — «Нет товаров» disabled.
// EQ-CAT-12 (02 SCR-13.6: данные перехода `f`, `categoryId`, `q?`): лист, открытый из поиска SCR-11
// (`/catalog/filters?f=&q=`), считает N и фасеты с учётом строки поиска — `GET /search/products?q=…&limit=1`
// (офлайн — поиск по кэшу); без `q` — по каталогу, как раньше. `q` — конструктор, иначе query маршрута.
// На expanded фильтры — `FilterPanel` внутри SCR-10/11/12 без маршрута.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/filter_panel.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_filter_codec.dart';
import 'package:optomstroy/features/catalog/presentation/state/search_input_policy.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_filter_form.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_formats.dart';

/// SCR-13 — Фильтры — маршрут-лист на compact/medium.
class CatalogFiltersScreen extends ConsumerStatefulWidget {
  const CatalogFiltersScreen({this.f, this.q, super.key});

  /// ID экрана по 02 §4.1.
  static const String screenId = 'SCR-13';

  /// Сериализованные фильтры (черновик листа).
  final String? f;

  /// Строка поиска экрана-источника (SCR-11; EQ-CAT-12). `null` — взять `q` из location маршрута
  /// (`CatalogFiltersRoute(f, q)` передаёт в экран пока только `f`).
  final String? q;

  /// Параметр `q` текущего маршрута go_router (`null` — не go_router или параметра нет).
  static String? routeQuery(BuildContext context) {
    if (GoRouter.maybeOf(context) == null) {
      return null;
    }
    try {
      return GoRouterState.of(context).uri.queryParameters['q'];
    } on GoError {
      return null;
    }
  }

  @override
  ConsumerState<CatalogFiltersScreen> createState() => _CatalogFiltersScreenState();
}

class _CatalogFiltersScreenState extends ConsumerState<CatalogFiltersScreen> {
  late CatalogFilter _draft = CatalogFilterCodec.decode(widget.f);
  late final CatalogFilterPriceControllers _price = CatalogFilterPriceControllers(_draft);
  Timer? _debounce;
  int _generation = 0;
  bool _counting = true;
  int? _count;
  bool _countFailed = false;
  CatalogFacets? _facets;
  DateTime? _asOf;
  bool _offline = false;
  bool _showAllBrands = false;
  bool _applied = false;
  List<Warehouse> _warehouses = const <Warehouse>[];

  /// Нормализованная строка поиска для подсчёта (`''` — без поиска).
  String _query = '';
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    final String raw = widget.q ?? CatalogFiltersScreen.routeQuery(context) ?? '';
    _query = SearchInputPolicy.canSearch(raw) ? SearchInputPolicy.normalize(raw) : '';
    unawaited(_count0());
    unawaited(_loadWarehouses());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _price.dispose();
    super.dispose();
  }

  Future<void> _loadWarehouses() async {
    if (ref.read(catalogViewerRoleProvider) == RoleCode.customer) {
      return;
    }
    final Result<List<Warehouse>> r = await ref.read(catalogRepositoryProvider).warehouses();
    if (mounted && r is Success<List<Warehouse>>) {
      setState(() => _warehouses = r.value);
    }
  }

  /// Страница-счётчик: с `q` — поиск (SCR-11), без — каталог (SCR-10/12).
  Future<Result<CatalogPage<ProductSummary>>> _page({required bool cached}) async {
    if (_query.isEmpty) {
      final CatalogQuery q = CatalogQuery(filter: _draft, limit: 1);
      final CatalogRepository repo = ref.read(catalogRepositoryProvider);
      return cached ? repo.cachedProducts(q) : repo.products(q);
    }
    final SearchQuery q = SearchQuery(q: _query, filter: _draft, limit: 1);
    final SearchRepository repo = ref.read(searchRepositoryProvider);
    final Result<SearchResult> r = await (cached ? repo.searchCached(q) : repo.searchProducts(q));
    return r.map((SearchResult v) => v.page);
  }

  Future<void> _count0() async {
    final int gen = ++_generation;
    setState(() => _counting = true);
    Result<CatalogPage<ProductSummary>> r = await _page(cached: false);
    bool offline = false;
    if (r is FailureResult<CatalogPage<ProductSummary>> && r.failure is NetworkFailure) {
      // Офлайн — локальные счётчики по кэшу (UI-13-015).
      offline = true;
      r = await _page(cached: true);
    }
    if (!mounted || gen != _generation) {
      return;
    }
    setState(() {
      _counting = false;
      _offline = offline;
      switch (r) {
        case Success<CatalogPage<ProductSummary>>(:final CatalogPage<ProductSummary> value):
          _count = value.totalEstimate ?? value.items.length;
          _facets = value.facets ?? _facets;
          _asOf = value.asOf;
          _countFailed = false;
        case FailureResult<CatalogPage<ProductSummary>>():
          _countFailed = true;
      }
    });
  }

  void _onChanged(CatalogFilter next) {
    setState(() => _draft = next);
    _debounce?.cancel();
    if (priceRangeInvalid(next)) {
      return;
    }
    _debounce = Timer(SearchInputPolicy.debounce, () => unawaited(_count0()));
  }

  void _close([String? result]) {
    if (GoRouter.maybeOf(context) != null) {
      context.pop(result);
    } else {
      Navigator.of(context).pop(result);
    }
  }

  void _apply() {
    if (_applied) {
      return;
    }
    _applied = true;
    _close(CatalogFilterCodec.encode(_draft) ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool invalid = priceRangeInvalid(_draft);
    final int? count = _count;
    final bool none = !_counting && !_countFailed && count == 0;
    final String applyLabel = _countFailed || count == null
        ? l10n.filters_show_n(0).replaceAll('0', '…')
        : (none ? l10n.filters_no_results : l10n.filters_show_n(count));
    return Scaffold(
      key: const ValueKey<String>('stub-${CatalogFiltersScreen.screenId}'),
      body: SafeArea(
        child: FilterSheet(
          title: l10n.filters_title,
          activeCount: _draft.activeCount,
          resetLabel: l10n.ds_button_reset,
          closeLabel: l10n.ds_button_close,
          applyLabel: applyLabel,
          applyLoading: _counting,
          applyHint: none ? l10n.filters_no_results_hint : null,
          note: _offline ? l10n.filters_offline_note(CatalogFormats.time(_asOf ?? DateTime.now())) : null,
          onClose: _close,
          onReset: () {
            final CatalogFilter cleared = CatalogFilterCodec.cleared(_draft);
            _price.sync(cleared);
            _onChanged(cleared);
          },
          onApply: invalid || none || _counting ? null : _apply,
          sections: buildCatalogFilterSections(
            context: context,
            filter: _draft,
            onUpdate: (CatalogFilter Function(CatalogFilter current) update) => _onChanged(update(_draft)),
            price: _price,
            role: ref.watch(catalogViewerRoleProvider),
            facets: _facets,
            facetsLoading: _counting,
            facetsFailed: _countFailed && _facets == null,
            onRetryFacets: () => unawaited(_count0()),
            warehouses: _warehouses,
            showAllBrands: _showAllBrands,
            onToggleShowAllBrands: () => setState(() => _showAllBrands = !_showAllBrands),
          ),
        ),
      ),
    );
  }
}
