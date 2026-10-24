// Состояние SCR-24 (02 SCR-24.7): загрузка → заказ / не найден (`404 NOT_FOUND`, в т. ч. чужой заказ — AC-UI-24-010)
// / ошибка; «Обновить» из 1С (`refreshFromOnec=true`, повторное нажатие во время запроса игнорируется; 1С
// недоступна — последний снимок + снекбар, AC-UI-24-011); тихое обновление (возврат на экран, периодически);
// отмена и привязка к 1С — с `Idempotency-Key`, созданным при подтверждении в диалоге (повтор — тот же ключ,
// ORD-053, AC-UI-24-016). Заказ — только память (07 §11.2).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/repositories/orders_repository.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';

/// Фаза экрана заказа.
enum OrderDetailsPhase { loading, loaded, notFound, error }

/// Итог «Обновить» из 1С.
enum OnecRefreshOutcome { updated, onecUnavailable, failed, ignored }

/// Состояние SCR-24.
@immutable
final class OrderDetailsState {
  const OrderDetailsState({
    this.phase = OrderDetailsPhase.loading,
    this.details,
    this.failure,
    this.refreshingFromOnec = false,
    this.loadedAt,
  });

  final OrderDetailsPhase phase;
  final OrderDetails? details;
  final Failure? failure;
  final bool refreshingFromOnec;

  /// Время последнего ответа (офлайн — «данные от»).
  final DateTime? loadedAt;

  OrderDetailsState copyWith({
    OrderDetailsPhase? phase,
    OrderDetails? details,
    Failure? Function()? failure,
    bool? refreshingFromOnec,
    DateTime? loadedAt,
  }) => OrderDetailsState(
    phase: phase ?? this.phase,
    details: details ?? this.details,
    failure: failure == null ? this.failure : failure(),
    refreshingFromOnec: refreshingFromOnec ?? this.refreshingFromOnec,
    loadedAt: loadedAt ?? this.loadedAt,
  );
}

/// `orderDetailsProvider(orderId)` (02 SCR-24.9).
final orderDetailsProvider = NotifierProvider.autoDispose.family<OrderDetailsController, OrderDetailsState, String>(
  OrderDetailsController.new,
);

/// Контроллер заказа.
final class OrderDetailsController extends Notifier<OrderDetailsState> {
  /// Контроллер заказа [orderId].
  OrderDetailsController(this.orderId);

  final String orderId;
  int _generation = 0;

  @override
  OrderDetailsState build() {
    unawaited(Future<void>.microtask(load));
    return const OrderDetailsState();
  }

  OrdersRepository get _repo => ref.read(ordersRepositoryProvider);

  bool _alive(int gen) => ref.mounted && gen == _generation;

  static bool isNotFound(Failure f) => f is ServerFailure && (f.status == 404 || f.code == 'NOT_FOUND');

  Future<Result<OrderDetails>> _get({bool refreshFromOnec = false}) async {
    try {
      return await _repo.get(orderId, refreshFromOnec: refreshFromOnec);
    } on Object catch (e) {
      return FailureResult<OrderDetails>(UnknownFailure(cause: e));
    }
  }

  /// Загрузка (первая и «Повторить»).
  Future<void> load() async {
    final int gen = ++_generation;
    if (!ref.mounted) return;
    state = const OrderDetailsState();
    final Result<OrderDetails> r = await _get();
    if (!_alive(gen)) return;
    state = switch (r) {
      Success<OrderDetails>(:final OrderDetails value) => OrderDetailsState(
        phase: OrderDetailsPhase.loaded,
        details: value,
        loadedAt: ref.read(clockProvider).nowUtc(),
      ),
      FailureResult<OrderDetails>(:final Failure failure) => OrderDetailsState(
        phase: isNotFound(failure) ? OrderDetailsPhase.notFound : OrderDetailsPhase.error,
        failure: failure,
      ),
    };
  }

  /// Тихое обновление (pull-to-refresh, возврат на экран, период): ошибка не скрывает данные.
  Future<Failure?> refresh() async {
    if (state.phase != OrderDetailsPhase.loaded) {
      await load();
      return state.failure;
    }
    final int gen = ++_generation;
    final Result<OrderDetails> r = await _get();
    if (!_alive(gen)) return null;
    switch (r) {
      case Success<OrderDetails>(:final OrderDetails value):
        state = state.copyWith(details: value, loadedAt: ref.read(clockProvider).nowUtc(), failure: () => null);
        return null;
      case FailureResult<OrderDetails>(:final Failure failure):
        if (isNotFound(failure)) state = OrderDetailsState(phase: OrderDetailsPhase.notFound, failure: failure);
        return failure;
    }
  }

  /// «Обновить» статус из 1С (UI-24-014, staff).
  Future<OnecRefreshOutcome> refreshFromOnec() async {
    if (state.refreshingFromOnec || state.phase != OrderDetailsPhase.loaded) return OnecRefreshOutcome.ignored;
    final int gen = ++_generation;
    state = state.copyWith(refreshingFromOnec: true);
    final Result<OrderDetails> r = await _get(refreshFromOnec: true);
    if (!_alive(gen)) return OnecRefreshOutcome.ignored;
    switch (r) {
      case Success<OrderDetails>(:final OrderDetails value):
        state = state.copyWith(details: value, refreshingFromOnec: false, loadedAt: ref.read(clockProvider).nowUtc());
        return OnecRefreshOutcome.updated;
      case FailureResult<OrderDetails>(:final Failure failure):
        state = state.copyWith(refreshingFromOnec: false);
        return failure is OnecUnavailableFailure ? OnecRefreshOutcome.onecUnavailable : OnecRefreshOutcome.failed;
    }
  }

  /// Принять заказ из ответа действия (отмена, привязка) — `allowedActions` перечитываются [refresh].
  void _applyOrder(Order order) {
    final OrderDetails? d = state.details;
    state = state.copyWith(
      details: OrderDetails(order: order, allowedActions: d?.allowedActions ?? const <OrderAction>{}),
    );
    unawaited(refresh());
  }

  /// `POST /orders/{id}/cancel` (step-up — по ответу `403 STEP_UP_REQUIRED`, AuthInterceptor, тот же ключ).
  Future<Result<Order>> cancel(OrderCancelRequest request, {required String idempotencyKey}) async {
    final Result<Order> r = await _guard(() => _repo.cancel(orderId, request, idempotencyKey: idempotencyKey));
    if (!ref.mounted) return r;
    switch (r) {
      case Success<Order>(:final Order value):
        _applyOrder(value);
      case FailureResult<Order>(:final Failure failure):
        if (failure is ConflictFailure) unawaited(refresh());
    }
    return r;
  }

  /// `POST /orders/{id}/onec-link` (step-up обязателен; [stepUpToken] — если получен заранее).
  Future<Result<Order>> linkOnec(
    OrderOnecLinkRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    final Result<Order> r = await _guard(
      () => _repo.linkOnec(orderId, request, idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    if (!ref.mounted) return r;
    switch (r) {
      case Success<Order>(:final Order value):
        _applyOrder(value);
      case FailureResult<Order>(:final Failure failure):
        if (failure is ConflictFailure) unawaited(refresh());
    }
    return r;
  }

  Future<Result<T>> _guard<T>(Future<Result<T>> Function() run) async {
    try {
      return await run();
    } on Object catch (e) {
      return FailureResult<T>(UnknownFailure(cause: e));
    }
  }
}
