// Состояние SCR-36 (02 SCR-36.7): Loading → List / Empty / Error; смена фильтров — Filtering (старый список виден,
// приглушён; новый запрос отменяет предыдущий по номеру); курсорная подгрузка (`limit=50`, D-37) без дублей
// (AC-UI-36-010); ошибка подгрузки строки не стирает. Без сети уже загруженный список остаётся с меткой времени,
// без данных — Offline («Журнал операций недоступен без сети»). Данные — только память провайдера (CASH-015).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/presentation/state/transactions_filters.dart';
import 'package:optomstroy/features/transactions/transactions_providers.dart';

/// Фаза списка.
enum TransactionsPhase { loading, list, empty, error, offline }

/// Состояние журнала.
@immutable
final class TransactionsListState {
  /// Создаёт состояние.
  const TransactionsListState({
    this.phase = TransactionsPhase.loading,
    this.items = const <Transaction>[],
    this.summary,
    this.nextCursor,
    this.loadingMore = false,
    this.loadMoreFailure,
    this.failure,
    this.filtering = false,
    this.filterFailed = false,
    this.offline = false,
    this.loadedAt,
    this.sort = TransactionsSort.occurredAtDesc,
  });

  final TransactionsPhase phase;
  final List<Transaction> items;
  final TransactionsSummary? summary;
  final String? nextCursor;
  final bool loadingMore;
  final Failure? loadMoreFailure;
  final Failure? failure;

  /// Идёт запрос по новым фильтрам при показанном списке.
  final bool filtering;

  /// «Не удалось применить фильтр · Повторить».
  final bool filterFailed;

  /// Нет сети — показан список из памяти («Нет сети. Показаны данные от HH:MM»).
  final bool offline;
  final DateTime? loadedAt;
  final TransactionsSort sort;

  bool get hasMore => nextCursor != null;

  TransactionsListState copyWith({
    TransactionsPhase? phase,
    List<Transaction>? items,
    TransactionsSummary? Function()? summary,
    String? Function()? nextCursor,
    bool? loadingMore,
    Failure? Function()? loadMoreFailure,
    Failure? Function()? failure,
    bool? filtering,
    bool? filterFailed,
    bool? offline,
    DateTime? loadedAt,
    TransactionsSort? sort,
  }) => TransactionsListState(
    phase: phase ?? this.phase,
    items: items ?? this.items,
    summary: summary == null ? this.summary : summary(),
    nextCursor: nextCursor == null ? this.nextCursor : nextCursor(),
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailure: loadMoreFailure == null ? this.loadMoreFailure : loadMoreFailure(),
    failure: failure == null ? this.failure : failure(),
    filtering: filtering ?? this.filtering,
    filterFailed: filterFailed ?? this.filterFailed,
    offline: offline ?? this.offline,
    loadedAt: loadedAt ?? this.loadedAt,
    sort: sort ?? this.sort,
  );
}

/// Журнал SCR-36 (память экрана).
final transactionsListControllerProvider =
    NotifierProvider.autoDispose<TransactionsListController, TransactionsListState>(TransactionsListController.new);

/// Логика списка.
final class TransactionsListController extends Notifier<TransactionsListState> {
  TransactionsFilters? _filters;
  int _seq = 0;
  bool _disposed = false;

  @override
  TransactionsListState build() {
    ref.onDispose(() => _disposed = true);
    return const TransactionsListState();
  }

  void _set(TransactionsListState s) {
    if (!_disposed) state = s;
  }

  /// Применить фильтры (первая страница); одинаковые фильтры без [force] — без запроса.
  Future<void> apply(TransactionsFilters filters, {bool force = false}) async {
    if (!force && filters == _filters && state.phase != TransactionsPhase.loading) return;
    _filters = filters;
    final int seq = ++_seq;
    final bool shown = state.items.isNotEmpty;
    _set(
      state.copyWith(
        phase: shown ? state.phase : TransactionsPhase.loading,
        filtering: shown,
        filterFailed: false,
        loadMoreFailure: () => null,
      ),
    );
    final Result<TransactionsPage> r = await ref
        .read(transactionsRepositoryProvider)
        .list(filters.toQuery(sort: state.sort));
    if (_disposed || seq != _seq) return;
    final DateTime now = ref.read(clockProvider).nowUtc();
    switch (r) {
      case Success<TransactionsPage>(:final TransactionsPage value):
        final List<Transaction> items = value.page.items;
        _set(
          state.copyWith(
            phase: items.isEmpty ? TransactionsPhase.empty : TransactionsPhase.list,
            items: items,
            summary: () => value.summary,
            nextCursor: () => value.page.nextCursor,
            filtering: false,
            offline: false,
            failure: () => null,
            loadedAt: now,
          ),
        );
      case FailureResult<TransactionsPage>(:final Failure failure):
        final bool network = failure is NetworkFailure;
        if (shown) {
          _set(state.copyWith(filtering: false, filterFailed: !network, offline: network));
        } else {
          _set(
            state.copyWith(
              phase: network ? TransactionsPhase.offline : TransactionsPhase.error,
              filtering: false,
              failure: () => failure,
            ),
          );
        }
    }
  }

  /// Обновить (pull-to-refresh / F5 / «Повторить»).
  Future<void> refresh() async {
    final TransactionsFilters? f = _filters;
    if (f != null) await apply(f, force: true);
  }

  /// Сортировка по колонке «Сумма»/«Дата» (expanded).
  Future<void> setSort(TransactionsSort sort) async {
    if (sort == state.sort) return;
    _set(state.copyWith(sort: sort));
    await refresh();
  }

  /// Следующая страница по курсору; дубли по `id` отбрасываются.
  Future<void> loadMore() async {
    final TransactionsFilters? f = _filters;
    final String? cursor = state.nextCursor;
    if (f == null || cursor == null || state.loadingMore || state.filtering) return;
    final int seq = _seq;
    _set(state.copyWith(loadingMore: true, loadMoreFailure: () => null));
    final Result<TransactionsPage> r = await ref
        .read(transactionsRepositoryProvider)
        .list(f.toQuery(cursor: cursor, sort: state.sort));
    if (_disposed || seq != _seq) return;
    switch (r) {
      case Success<TransactionsPage>(:final TransactionsPage value):
        final Set<String> known = <String>{for (final Transaction t in state.items) t.id};
        _set(
          state.copyWith(
            items: <Transaction>[...state.items, ...value.page.items.where((Transaction t) => !known.contains(t.id))],
            nextCursor: () => value.page.nextCursor,
            loadingMore: false,
          ),
        );
      case FailureResult<TransactionsPage>(:final Failure failure):
        _set(state.copyWith(loadingMore: false, loadMoreFailure: () => failure, offline: failure is NetworkFailure));
    }
  }
}
