// Список товаров SCR-10/11/12 (02 SCR-10.9 `catalogPageProvider(query)`, SCR-11.9 `searchProvider`):
// первая страница — из кэша drift (≤ 100 мс), затем сервер (`/catalog/products` или `/search/products`,
// `limit=40`, курсор); подгрузка следующей страницы — не более одного запроса; ответы устаревших
// запросов (смена ключа/повтор) отбрасываются по номеру поколения (SCR-10.11, SCR-11.11).
// Офлайн (`NetworkFailure`): кэш + метка возраста; кэша нет — состояние «Нет данных без сети».
import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/providers/category_tree_provider.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_filter_codec.dart';

/// Источник списка.
enum CatalogListKind {
  /// `GET /catalog/products` (SCR-10, SCR-12).
  catalog,

  /// `GET /search/products` (SCR-11).
  search,

  /// Подборка «Недавние» (`preset=recent`, C6).
  recent,
}

/// Ключ списка: источник + фильтры + сортировка (+ строка поиска).
@immutable
final class CatalogListKey {
  const CatalogListKey.catalog({required this.filter, required this.sort}) : kind = CatalogListKind.catalog, q = null;

  const CatalogListKey.search({required String this.q, required this.filter, required this.sort})
    : kind = CatalogListKind.search;

  /// Подборка «Недавние» (C6); в категории — в пределах категории и её подкатегорий (02 UI-12-007).
  CatalogListKey.recent({String? categoryId})
    : kind = CatalogListKind.recent,
      filter = categoryId == null ? const CatalogFilter() : CatalogFilter(categoryId: categoryId),
      sort = null,
      q = null;

  final CatalogListKind kind;
  final CatalogFilter filter;
  final CatalogSort? sort;
  final String? q;

  String get _signature =>
      '${kind.name}|${q ?? ''}|${sort?.value ?? ''}|${filter.categoryId ?? ''}|'
      '${CatalogFilterCodec.encode(filter, includeCategory: false) ?? ''}|${filter.priceListId ?? ''}';

  @override
  bool operator ==(Object other) => other is CatalogListKey && other._signature == _signature;

  @override
  int get hashCode => _signature.hashCode;

  @override
  String toString() => 'CatalogListKey($_signature)';
}

/// Фаза списка.
enum CatalogListPhase {
  /// Первая загрузка без данных — скелетон.
  loading,

  /// Есть товары (сеть или кэш).
  ready,

  /// `items=[]`.
  empty,

  /// Ошибка без данных — `ErrorState.fullScreen`.
  error,

  /// Нет сети и кэша — `EmptyState.offlineNoCache`.
  offlineNoCache,
}

@immutable
final class CatalogListState {
  const CatalogListState({
    this.phase = CatalogListPhase.loading,
    this.items = const <ProductSummary>[],
    this.refreshing = false,
    this.failure,
    this.offline = false,
    this.loadingMore = false,
    this.moreFailure,
    this.hasMore = false,
    this.nextCursor,
    this.total,
    this.isEstimate = false,
    this.source = DataSource.network,
    this.asOf,
    this.facets,
    this.matchTypes,
    this.suggestedQuery,
  });

  final CatalogListPhase phase;
  final List<ProductSummary> items;

  /// Показан кэш, идёт запрос к серверу (тонкий прогресс).
  final bool refreshing;

  /// Ошибка первой страницы (при показанном кэше — `ErrorState.inline`).
  final Failure? failure;

  /// Сервер недоступен — данные из кэша (метка «Нет сети. Показаны данные от …»).
  final bool offline;
  final bool loadingMore;

  /// Ошибка подгрузки — строка «Не удалось загрузить · Повторить» (UI-10-019).
  final Failure? moreFailure;
  final bool hasMore;
  final String? nextCursor;

  /// «Найдено: N».
  final int? total;
  final bool isEstimate;
  final DataSource source;
  final DateTime? asOf;
  final CatalogFacets? facets;
  final SearchMatchCounts? matchTypes;
  final String? suggestedQuery;

  CatalogListState copyWith({
    CatalogListPhase? phase,
    List<ProductSummary>? items,
    bool? refreshing,
    Failure? failure,
    bool clearFailure = false,
    bool? offline,
    bool? loadingMore,
    Failure? moreFailure,
    bool clearMoreFailure = false,
    bool? hasMore,
    String? nextCursor,
    DataSource? source,
  }) => CatalogListState(
    phase: phase ?? this.phase,
    items: items ?? this.items,
    refreshing: refreshing ?? this.refreshing,
    failure: clearFailure ? null : (failure ?? this.failure),
    offline: offline ?? this.offline,
    loadingMore: loadingMore ?? this.loadingMore,
    moreFailure: clearMoreFailure ? null : (moreFailure ?? this.moreFailure),
    hasMore: hasMore ?? this.hasMore,
    nextCursor: nextCursor ?? this.nextCursor,
    total: total,
    isEstimate: isEstimate,
    source: source ?? this.source,
    asOf: asOf,
    facets: facets,
    matchTypes: matchTypes,
    suggestedQuery: suggestedQuery,
  );
}

/// Список по ключу; освобождается вместе с экраном.
final catalogListProvider = NotifierProvider.autoDispose
    .family<CatalogListController, CatalogListState, CatalogListKey>(CatalogListController.new);

/// Нормализованная страница (каталог / поиск / кэш).
final class _Page {
  const _Page({
    required this.items,
    required this.hasMore,
    this.nextCursor,
    this.total,
    this.isEstimate = false,
    this.asOf,
    this.facets,
    this.source = DataSource.network,
    this.matchTypes,
    this.suggestedQuery,
  });

  factory _Page.catalog(CatalogPage<ProductSummary> p) => _Page(
    items: p.items,
    hasMore: p.hasMore,
    nextCursor: p.nextCursor,
    total: p.totalEstimate,
    isEstimate: p.isEstimate,
    asOf: p.asOf,
    facets: p.facets,
    source: p.source,
  );

  factory _Page.search(SearchResult r) => _Page(
    items: r.items,
    hasMore: r.page.hasMore,
    nextCursor: r.page.nextCursor,
    total: r.page.totalEstimate,
    isEstimate: r.page.isEstimate,
    asOf: r.page.asOf,
    facets: r.page.facets,
    source: r.source,
    matchTypes: r.matchTypes,
    suggestedQuery: r.suggestedQuery,
  );

  final List<ProductSummary> items;
  final bool hasMore;
  final String? nextCursor;
  final int? total;
  final bool isEstimate;
  final DateTime? asOf;
  final CatalogFacets? facets;
  final DataSource source;
  final SearchMatchCounts? matchTypes;
  final String? suggestedQuery;

  CatalogListState toState({bool refreshing = false, bool offline = false, Failure? failure}) => CatalogListState(
    phase: items.isEmpty ? CatalogListPhase.empty : CatalogListPhase.ready,
    items: items,
    refreshing: refreshing,
    offline: offline,
    failure: failure,
    hasMore: hasMore && nextCursor != null,
    nextCursor: nextCursor,
    total: total ?? (hasMore ? null : items.length),
    isEstimate: isEstimate,
    source: source,
    asOf: asOf,
    facets: facets,
    matchTypes: matchTypes,
    suggestedQuery: suggestedQuery,
  );
}

final class CatalogListController extends Notifier<CatalogListState> {
  CatalogListController(this.key);

  final CatalogListKey key;
  int _generation = 0;

  /// Сколько раз запрошена сеть (для тестов «не чаще 1 раза» не используется — счёт у фейка).
  @override
  CatalogListState build() {
    unawaited(Future<void>.microtask(reload));
    return const CatalogListState();
  }

  bool _alive(int gen) => ref.mounted && gen == _generation;

  /// Ошибка реализации порта (в т. ч. `UnimplementedError` без привязки) — `UnknownFailure`, экран не падает.
  Future<Result<_Page>> _fetch({required bool cache, String? cursor}) async {
    try {
      return await _fetchUnsafe(cache: cache, cursor: cursor);
    } on Object catch (e) {
      return FailureResult<_Page>(UnknownFailure(cause: e));
    }
  }

  Future<Result<_Page>> _fetchUnsafe({required bool cache, String? cursor}) async {
    switch (key.kind) {
      case CatalogListKind.catalog:
        final CatalogQuery q = CatalogQuery(filter: key.filter, sort: key.sort, cursor: cursor);
        final Result<CatalogPage<ProductSummary>> r = cache
            ? await ref.read(catalogRepositoryProvider).cachedProducts(q)
            : await ref.read(catalogRepositoryProvider).products(q);
        return r.map(_Page.catalog);
      case CatalogListKind.search:
        final SearchQuery q = SearchQuery(
          q: key.q!,
          filter: key.filter,
          sort: key.sort ?? CatalogSort.relevanceDesc,
          cursor: cursor,
        );
        final Result<SearchResult> r = cache
            ? await ref.read(searchRepositoryProvider).searchCached(q)
            : await ref.read(searchRepositoryProvider).searchProducts(q);
        return r.map(_Page.search);
      case CatalogListKind.recent:
        final CatalogShelfPort? port = ref.read(catalogShelfPortProvider);
        if (port == null || cache) {
          return const Success<_Page>(_Page(items: <ProductSummary>[], hasMore: false));
        }
        final Result<List<RecentProduct>> r = await port.recentProducts(limit: 50);
        final Set<String>? scope = _recentScope(key.filter.categoryId);
        return r.map(
          (List<RecentProduct> list) => _Page(
            items: <ProductSummary>[
              for (final RecentProduct p in list)
                if (scope == null || scope.contains(p.product.categoryId)) p.product,
            ],
            hasMore: false,
          ),
        );
    }
  }

  /// Категория и её подкатегории (по дереву; дерева нет — только сама категория); `null` — без ограничения.
  Set<String>? _recentScope(String? categoryId) {
    if (categoryId == null) {
      return null;
    }
    final Category? node = ref.read(categoryTreeProvider).tree?.find(categoryId);
    if (node == null) {
      return <String>{categoryId};
    }
    final Set<String> ids = <String>{};
    void walk(Category c) {
      ids.add(c.id);
      c.children.forEach(walk);
    }

    walk(node);
    return ids;
  }

  /// Первая страница: кэш → сеть. Повтор после ошибки и «тянуть для обновления» — тот же вызов.
  Future<void> reload() async {
    final int gen = ++_generation;
    final bool hadItems = state.items.isNotEmpty;
    state = state.copyWith(
      phase: hadItems ? CatalogListPhase.ready : CatalogListPhase.loading,
      refreshing: hadItems,
      clearFailure: true,
      clearMoreFailure: true,
    );
    if (!hadItems && key.kind != CatalogListKind.recent) {
      final Result<_Page> cached = await _fetch(cache: true);
      if (!_alive(gen)) {
        return;
      }
      final _Page? page = cached.valueOrNull;
      if (page != null && page.items.isNotEmpty) {
        state = page.toState(refreshing: true);
      }
    }
    final Result<_Page> network = await _fetch(cache: false);
    if (!_alive(gen)) {
      return;
    }
    switch (network) {
      case Success<_Page>(:final _Page value):
        state = value.toState();
      case FailureResult<_Page>(:final Failure failure):
        final bool net = failure is NetworkFailure;
        if (state.items.isNotEmpty) {
          state = state.copyWith(
            phase: CatalogListPhase.ready,
            refreshing: false,
            offline: net,
            failure: net ? null : failure,
            source: DataSource.cache,
          );
        } else {
          state = CatalogListState(
            phase: net ? CatalogListPhase.offlineNoCache : CatalogListPhase.error,
            failure: failure,
            offline: net,
          );
        }
    }
  }

  /// Следующая страница (за 2 ряда до конца — у вызывающего); не более одного запроса.
  Future<void> loadMore() async {
    final CatalogListState s = state;
    if (s.loadingMore || !s.hasMore || s.nextCursor == null || s.phase != CatalogListPhase.ready) {
      return;
    }
    final int gen = _generation;
    state = s.copyWith(loadingMore: true, clearMoreFailure: true);
    final Result<_Page> r = await _fetch(cache: s.source == DataSource.cache, cursor: s.nextCursor);
    if (!_alive(gen)) {
      return;
    }
    switch (r) {
      case Success<_Page>(:final _Page value):
        final Set<String> seen = <String>{for (final ProductSummary p in state.items) p.id};
        final List<ProductSummary> merged = <ProductSummary>[
          ...state.items,
          for (final ProductSummary p in value.items)
            if (seen.add(p.id)) p,
        ];
        state = CatalogListState(
          phase: CatalogListPhase.ready,
          items: merged,
          offline: state.offline,
          hasMore: value.hasMore && value.nextCursor != null,
          nextCursor: value.nextCursor,
          total: state.total ?? value.total,
          isEstimate: state.isEstimate,
          source: state.source,
          asOf: state.asOf ?? value.asOf,
          facets: state.facets,
          matchTypes: state.matchTypes,
          suggestedQuery: state.suggestedQuery,
        );
      case FailureResult<_Page>(:final Failure failure):
        state = state.copyWith(loadingMore: false, moreFailure: failure);
    }
  }

  /// Локальная правка товара (избранное) без перезапроса.
  void patch(String productId, ProductSummary Function(ProductSummary p) update) {
    state = state.copyWith(
      items: <ProductSummary>[for (final ProductSummary p in state.items) p.id == productId ? update(p) : p],
    );
  }
}
