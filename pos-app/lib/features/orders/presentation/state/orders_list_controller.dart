// Состояние SCR-25 (02 SCR-25.7): загрузка → список/пусто/ошибка; курсорная подгрузка (`limit=50`, `nextCursor`,
// D-37) — ошибка подгрузки не стирает строки (AC-UI-25-006), «Повторить» — тот же курсор; `cursor_sort_mismatch`
// → тихая перезагрузка первой страницы; `statusCounts` и `totalEstimate` — из первой страницы (AC-UI-25-012).
// Заказы в drift не кэшируются (07 §11.2) — только память провайдера `ordersListProvider(filters)`.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/repositories/orders_repository.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:optomstroy/features/orders/presentation/state/orders_filters.dart';

/// Фаза списка.
enum OrdersListPhase { loading, ready, empty, error }

/// Состояние списка заказов.
@immutable
final class OrdersListState {
  /// Создаёт состояние.
  const OrdersListState({
    this.phase = OrdersListPhase.loading,
    this.items = const <OrderSummary>[],
    this.statusCounts = const <OrderStatus, int>{},
    this.totalEstimate,
    this.nextCursor,
    this.loadingMore = false,
    this.loadMoreFailure,
    this.failure,
    this.loadedAt,
    this.refreshing = false,
  });

  final OrdersListPhase phase;
  final List<OrderSummary> items;

  /// Счётчики групп (пусто — сервер не прислал, чипы без чисел).
  final Map<OrderStatus, int> statusCounts;

  /// «Найдено: N за период».
  final int? totalEstimate;
  final String? nextCursor;
  final bool loadingMore;

  /// Ошибка подгрузки — строка «Не удалось загрузить · Повторить» внизу.
  final Failure? loadMoreFailure;

  /// Ошибка первой загрузки (`ErrorState`) или обновления (снекбар).
  final Failure? failure;

  /// Время ответа первой страницы (`SyncIndicator` «Данные от {time}» через 5 мин).
  final DateTime? loadedAt;

  /// Pull-to-refresh / F5 / тихое обновление.
  final bool refreshing;

  bool get hasMore => nextCursor != null;

  OrdersListState copyWith({
    OrdersListPhase? phase,
    List<OrderSummary>? items,
    Map<OrderStatus, int>? statusCounts,
    int? Function()? totalEstimate,
    String? Function()? nextCursor,
    bool? loadingMore,
    Failure? Function()? loadMoreFailure,
    Failure? Function()? failure,
    DateTime? loadedAt,
    bool? refreshing,
  }) => OrdersListState(
    phase: phase ?? this.phase,
    items: items ?? this.items,
    statusCounts: statusCounts ?? this.statusCounts,
    totalEstimate: totalEstimate == null ? this.totalEstimate : totalEstimate(),
    nextCursor: nextCursor == null ? this.nextCursor : nextCursor(),
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailure: loadMoreFailure == null ? this.loadMoreFailure : loadMoreFailure(),
    failure: failure == null ? this.failure : failure(),
    loadedAt: loadedAt ?? this.loadedAt,
    refreshing: refreshing ?? this.refreshing,
  );
}

/// Список по фильтрам; освобождается вместе с экраном. Смена фильтров — новый ключ (новый запрос с первой страницы,
/// результат прежнего запроса отбрасывается — 02 SCR-25.4, SCR-25.11).
final ordersListProvider = NotifierProvider.autoDispose.family<OrdersListController, OrdersListState, OrdersFilters>(
  OrdersListController.new,
);

/// Контроллер списка.
final class OrdersListController extends Notifier<OrdersListState> {
  /// Контроллер для [filters].
  OrdersListController(this.filters);

  final OrdersFilters filters;
  int _generation = 0;

  @override
  OrdersListState build() {
    ref.watch(ordersViewerProvider);
    unawaited(Future<void>.microtask(reload));
    return const OrdersListState();
  }

  OrdersRepository get _repo => ref.read(ordersRepositoryProvider);

  bool _alive(int gen) => ref.mounted && gen == _generation;

  Future<Result<OrdersPage>> _fetch(String? cursor) async {
    try {
      return await _repo.list(filters.toQuery(ref.read(ordersViewerProvider), cursor: cursor));
    } on Object catch (e) {
      return FailureResult<OrdersPage>(UnknownFailure(cause: e));
    }
  }

  /// Первая загрузка / «Повторить» в `ErrorState`.
  Future<void> reload() async {
    final int gen = ++_generation;
    if (!ref.mounted) return;
    state = const OrdersListState();
    await _loadFirst(gen, silent: false);
  }

  /// Pull-to-refresh, F5, возврат на экран, «Обновить» у метки устаревших данных: строки остаются видимыми.
  Future<void> refresh() async {
    if (state.phase == OrdersListPhase.loading) return;
    final int gen = ++_generation;
    state = state.copyWith(refreshing: true, failure: () => null);
    await _loadFirst(gen, silent: true);
  }

  Future<void> _loadFirst(int gen, {required bool silent}) async {
    final Result<OrdersPage> r = await _fetch(null);
    if (!_alive(gen)) return;
    switch (r) {
      case Success<OrdersPage>(:final OrdersPage value):
        state = OrdersListState(
          phase: value.page.items.isEmpty ? OrdersListPhase.empty : OrdersListPhase.ready,
          items: value.page.items,
          statusCounts: value.statusCounts,
          totalEstimate: value.page.totalEstimate,
          nextCursor: value.page.hasMore || value.page.nextCursor != null ? value.page.nextCursor : null,
          loadedAt: ref.read(clockProvider).nowUtc(),
        );
      case FailureResult<OrdersPage>(:final Failure failure):
        state = silent && state.items.isNotEmpty
            ? state.copyWith(refreshing: false, failure: () => failure)
            : OrdersListState(phase: OrdersListPhase.error, failure: failure);
    }
  }

  /// Следующая страница (конец списка или «Повторить» в строке ошибки подгрузки — тот же курсор).
  Future<void> loadMore() async {
    final String? cursor = state.nextCursor;
    if (cursor == null || state.loadingMore || state.phase != OrdersListPhase.ready) return;
    final int gen = _generation;
    state = state.copyWith(loadingMore: true, loadMoreFailure: () => null);
    final Result<OrdersPage> r = await _fetch(cursor);
    if (!_alive(gen)) return;
    switch (r) {
      case Success<OrdersPage>(:final OrdersPage value):
        state = state.copyWith(
          items: <OrderSummary>[...state.items, ...value.page.items],
          nextCursor: () => value.page.nextCursor,
          loadingMore: false,
        );
      case FailureResult<OrdersPage>(:final Failure failure):
        // Неверный курсор (`cursor_sort_mismatch`) — перезагрузка с первой страницы без сообщения (SCR-25.7).
        if (failure is ValidationFailure ||
            (failure is ServerFailure && failure.code == 'VALIDATION_FAILED' && failure.status == 400)) {
          await reload();
          return;
        }
        state = state.copyWith(loadingMore: false, loadMoreFailure: () => failure);
    }
  }

  /// Ошибка обновления показана (снекбар) — сбросить.
  void clearFailure() {
    if (state.phase != OrdersListPhase.error && state.failure != null) {
      state = state.copyWith(failure: () => null);
    }
  }
}
