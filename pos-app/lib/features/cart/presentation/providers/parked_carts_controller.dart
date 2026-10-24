// `parkedCartsProvider` SCR-23 (02 SCR-23.9): отложенные корзины с сервера (`GET /cart/parked?scope=own|all`, курсор,
// `limit=50`), без хранения в drift (07 §11.2). «Продолжить» — `POST /cart/parked/{id}/resume` через корзину
// (`CartController.resume`: сначала отправляется очередь активной корзины); «Удалить» — `DELETE /cart/parked/{id}`
// (ядро §19.2). Повторное нажатие во время запроса игнорируется (AC-UI-23-007, AC-UI-23-010).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:uuid/uuid.dart';

/// Исход «Продолжить».
enum ParkedResumeOutcome {
  /// Корзина стала активной.
  resumed,

  /// `409 ORDER_STATE_INVALID` (`active_not_empty`) — нужен диалог UI-23-010.
  activeNotEmpty,

  /// `404` — удалена по сроку / нет права (`parked_not_available`); список обновлён.
  notAvailable,

  /// Иная ошибка.
  failed,

  /// Повторное нажатие во время запроса.
  ignored,
}

/// Исход «Удалить».
enum ParkedDeleteOutcome { deleted, notAvailable, conflict, failed, ignored }

/// Состояние SCR-23.
final class ParkedCartsState {
  const ParkedCartsState({
    required this.scope,
    this.items = const <CartParkedSummary>[],
    this.loading = true,
    this.loadingMore = false,
    this.failure,
    this.nextCursor,
    this.hasMore = false,
    this.resuming,
    this.deleting = const <String>{},
    this.lastFailure,
  });

  final ParkedScope scope;
  final List<CartParkedSummary> items;
  final bool loading;
  final bool loadingMore;
  final Failure? failure;
  final String? nextCursor;
  final bool hasMore;

  /// Отложенная, которая продолжается (остальные «Продолжить» недоступны).
  final String? resuming;
  final Set<String> deleting;

  /// Ошибка последнего «Продолжить»/«Удалить» (для снекбара).
  final Failure? lastFailure;

  ParkedCartsState copyWith({
    ParkedScope? scope,
    List<CartParkedSummary>? items,
    bool? loading,
    bool? loadingMore,
    Failure? failure,
    bool clearFailure = false,
    String? nextCursor,
    bool? hasMore,
    String? resuming,
    bool clearResuming = false,
    Set<String>? deleting,
    Failure? lastFailure,
  }) => ParkedCartsState(
    scope: scope ?? this.scope,
    items: items ?? this.items,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    failure: clearFailure ? null : (failure ?? this.failure),
    nextCursor: nextCursor ?? this.nextCursor,
    hasMore: hasMore ?? this.hasMore,
    resuming: clearResuming ? null : (resuming ?? this.resuming),
    deleting: deleting ?? this.deleting,
    lastFailure: lastFailure ?? this.lastFailure,
  );
}

final parkedCartsProvider = NotifierProvider.autoDispose<ParkedCartsController, ParkedCartsState>(
  ParkedCartsController.new,
);

final class ParkedCartsController extends Notifier<ParkedCartsState> {
  String? _resumeKey;
  int _generation = 0;

  CartRepository get _repo => ref.read(cartRepositoryProvider);

  @override
  ParkedCartsState build() {
    final CartPermissions can = cartPermissionsFor(ref.watch(cartViewerRoleProvider));
    final ParkedScope scope = can.readOnlyParked ? ParkedScope.all : ParkedScope.own;
    scheduleMicrotask(() => unawaited(load(scope)));
    return ParkedCartsState(scope: scope);
  }

  /// Первая страница [scope] (смена вкладки сбрасывает список, AC-UI-23-013).
  Future<void> load(ParkedScope scope) async {
    final int gen = ++_generation;
    state = ParkedCartsState(scope: scope);
    final Result<PageResult<CartParkedSummary>> r = await _repo.listParked(scope: scope);
    if (!ref.mounted || gen != _generation) return;
    state = switch (r) {
      Success<PageResult<CartParkedSummary>>(:final PageResult<CartParkedSummary> value) => state.copyWith(
        items: value.items,
        loading: false,
        nextCursor: value.nextCursor,
        hasMore: value.hasMore,
        clearFailure: true,
      ),
      FailureResult<PageResult<CartParkedSummary>>(:final Failure failure) => state.copyWith(
        loading: false,
        failure: failure,
      ),
    };
  }

  /// Повторить загрузку текущей вкладки.
  Future<void> reload() => load(state.scope);

  /// Следующая страница (курсор, UI-23-011).
  Future<void> loadMore() async {
    if (!state.hasMore || state.loadingMore || state.nextCursor == null) return;
    final int gen = _generation;
    state = state.copyWith(loadingMore: true);
    final Result<PageResult<CartParkedSummary>> r = await _repo.listParked(
      scope: state.scope,
      cursor: state.nextCursor,
    );
    if (!ref.mounted || gen != _generation) return;
    state = switch (r) {
      Success<PageResult<CartParkedSummary>>(:final PageResult<CartParkedSummary> value) => state.copyWith(
        items: <CartParkedSummary>[...state.items, ...value.items],
        loadingMore: false,
        nextCursor: value.nextCursor,
        hasMore: value.hasMore,
      ),
      FailureResult<PageResult<CartParkedSummary>>() => state.copyWith(loadingMore: false),
    };
  }

  /// «Продолжить» (UI-23-006); [replaceActive] — после подтверждения UI-23-010.
  Future<ParkedResumeOutcome> resume(CartParkedSummary cart, {bool replaceActive = false}) async {
    if (state.resuming != null) return ParkedResumeOutcome.ignored;
    state = state.copyWith(resuming: cart.id);
    final String key = _resumeKey ??= const Uuid().v4();
    final Failure? f = await ref
        .read(cartControllerProvider.notifier)
        .resume(cart.id, replaceActive: replaceActive, idempotencyKey: key);
    if (!ref.mounted) return ParkedResumeOutcome.ignored;
    if (f == null) {
      _resumeKey = null;
      state = state.copyWith(clearResuming: true);
      return ParkedResumeOutcome.resumed;
    }
    if (f is ConflictFailure && f.kind == ConflictKind.orderStateInvalid) {
      // Новое тело запроса (`replaceActive: true`) — новый ключ (08 §2.7).
      _resumeKey = null;
      state = state.copyWith(clearResuming: true);
      return ParkedResumeOutcome.activeNotEmpty;
    }
    if (f is! NetworkFailure) _resumeKey = null;
    state = state.copyWith(clearResuming: true, lastFailure: f);
    if (_isNotFound(f)) {
      await reload();
      return ParkedResumeOutcome.notAvailable;
    }
    return ParkedResumeOutcome.failed;
  }

  /// «Удалить» (UI-23-007/013) после подтверждения.
  Future<ParkedDeleteOutcome> delete(CartParkedSummary cart) async {
    if (state.deleting.contains(cart.id)) return ParkedDeleteOutcome.ignored;
    state = state.copyWith(deleting: <String>{...state.deleting, cart.id});
    final Result<void> r = await _repo.deleteParked(cart.id);
    if (!ref.mounted) return ParkedDeleteOutcome.ignored;
    final Set<String> deleting = <String>{...state.deleting}..remove(cart.id);
    switch (r) {
      case Success<void>():
        state = state.copyWith(
          deleting: deleting,
          items: <CartParkedSummary>[
            for (final CartParkedSummary c in state.items)
              if (c.id != cart.id) c,
          ],
        );
        ref.invalidate(cartParkedCountProvider);
        return ParkedDeleteOutcome.deleted;
      case FailureResult<void>(:final Failure failure):
        state = state.copyWith(deleting: deleting, lastFailure: failure);
        if (_isNotFound(failure)) {
          await reload();
          return ParkedDeleteOutcome.notAvailable;
        }
        if (failure is ConflictFailure) {
          await reload();
          return ParkedDeleteOutcome.conflict;
        }
        return ParkedDeleteOutcome.failed;
    }
  }

  static bool _isNotFound(Failure f) => f is ServerFailure && (f.status == 404 || f.code == 'NOT_FOUND');
}
