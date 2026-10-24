// Звезда избранного клиента (SCR-31 UI-31-003, SCR-32 UI-32-003, SCR-40 UI-40-003; 08 §4.14 `PUT/DELETE
// /favorites/customers/{id}`; FAV-006, RM-G-004). Оптимистичное переключение (ANIM-009): цель меняется сразу,
// запрос уходит через 400 мс после последнего нажатия — отправляется последнее состояние; ошибка — откат к последнему
// подтверждённому состоянию (снекбар показывает экран). Только онлайн: избранные клиенты в `outbox_actions` не входят
// (основа G, customers_providers.dart). Лимит 12 (RM-G-011) проверяет сервер.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/session/session_controller.dart' show sessionControllerProvider;
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_controller.dart'
    show newCustomerKeyFactoryProvider;

/// Исход переключения.
sealed class FavoriteOutcome {
  const FavoriteOutcome();
}

/// Сохранено (или итоговое состояние совпало с сервером).
final class FavoriteSaved extends FavoriteOutcome {
  const FavoriteSaved(this.value);

  /// Итоговое состояние.
  final bool value;
}

/// Ошибка — откат.
final class FavoriteFailed extends FavoriteOutcome {
  const FavoriteFailed(this.failure);

  final Failure failure;
}

/// Цели звезды по клиентам текущей сессии (`id → в избранном`), поверх значений из ответов сервера.
final customerFavoritesProvider = NotifierProvider<CustomerFavoritesController, Map<String, bool>>(
  CustomerFavoritesController.new,
);

/// Контроллер звезды.
final class CustomerFavoritesController extends Notifier<Map<String, bool>> {
  /// Пауза перед отправкой (02 SCR-31.4, SCR-32.4).
  static const Duration debounce = Duration(milliseconds: 400);

  final Map<String, Timer> _timers = <String, Timer>{};
  final Map<String, bool> _confirmed = <String, bool>{};
  final Map<String, Completer<FavoriteOutcome>> _waiters = <String, Completer<FavoriteOutcome>>{};

  @override
  Map<String, bool> build() {
    ref.watch(sessionControllerProvider.select((s) => s.userId));
    ref.onDispose(() {
      for (final Timer t in _timers.values) {
        t.cancel();
      }
      _timers.clear();
    });
    return const <String, bool>{};
  }

  /// Текущее (целевое) состояние: локальная цель или значение сервера.
  bool valueOf(String customerId, {bool? server}) => state[customerId] ?? server ?? false;

  /// Сервер прислал значение (список/карточка) — запомнить как подтверждённое, если локальной цели нет.
  void seed(String customerId, bool? server) {
    if (server == null || _timers.containsKey(customerId)) return;
    _confirmed[customerId] = server;
  }

  /// Переключить звезду клиента [customerId] в [value]; результат — после отправки последнего состояния.
  Future<FavoriteOutcome> set(String customerId, bool value, {bool? server}) {
    _confirmed.putIfAbsent(customerId, () => server ?? !value);
    state = <String, bool>{...state, customerId: value};
    _timers[customerId]?.cancel();
    final Completer<FavoriteOutcome> waiter = _waiters[customerId] ??= Completer<FavoriteOutcome>();
    _timers[customerId] = Timer(debounce, () => unawaited(_send(customerId)));
    return waiter.future;
  }

  Future<void> _send(String customerId) async {
    _timers.remove(customerId);
    final Completer<FavoriteOutcome>? waiter = _waiters.remove(customerId);
    final bool target = state[customerId] ?? false;
    if (_confirmed[customerId] == target) {
      waiter?.complete(FavoriteSaved(target));
      return;
    }
    final Result<void> r = target
        ? await ref
              .read(favoriteCustomersRepositoryProvider)
              .add(customerId, idempotencyKey: ref.read(newCustomerKeyFactoryProvider)())
        : await ref.read(favoriteCustomersRepositoryProvider).remove(customerId);
    if (!ref.mounted) return;
    switch (r) {
      case Success<void>():
        _confirmed[customerId] = target;
        waiter?.complete(FavoriteSaved(target));
      case FailureResult<void>(:final Failure failure):
        // Пока шёл запрос, могло прийти новое нажатие — его отправит свой таймер; иначе откат.
        if (!_timers.containsKey(customerId)) {
          state = <String, bool>{...state, customerId: _confirmed[customerId] ?? !target};
        }
        waiter?.complete(FavoriteFailed(failure));
    }
  }
}
