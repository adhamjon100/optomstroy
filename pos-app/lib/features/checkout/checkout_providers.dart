// Публичный контракт фичи checkout (06 §6.1 L-3 (2), §6.14; FL-07).
//
// Этап F (основа): оформление SCR-21 (`checkout-preview`, `POST /orders`, поиск заказа по ключу после перезапуска)
// и черновик `checkout_draft`. Реализации подключает `app/di/overrides.dart` списком `checkoutBindings`
// (data/checkout_bindings.dart, L-8). В widget-тестах — `checkoutRepositoryProvider.overrideWithValue(fake)`,
// `checkoutDraftRepositoryProvider.overrideWithValue(fake)`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/features/checkout/domain/repositories/checkout_repository.dart';

Never _unbound(String name) => throw UnimplementedError('$name: подключите checkoutBindings в app/di/overrides.dart');

/// Проверка и создание заказа (только онлайн).
final checkoutRepositoryProvider = Provider<CheckoutRepository>((ref) => _unbound('checkoutRepositoryProvider'));

/// Черновик оформления (drift `checkout_draft`, БД текущего пользователя).
final checkoutDraftRepositoryProvider = Provider<CheckoutDraftRepository>(
  (ref) => _unbound('checkoutDraftRepositoryProvider'),
);
