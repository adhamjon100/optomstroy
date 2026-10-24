// Публичный контракт фичи customers (06 §6.1 L-3 (2), §6.14; FL-07).
//
// Этап F (основа): порт клиентов для CustomerPicker/CustomerCard (SCR-21) и SCR-26 «Новый клиент», разбор вложенного
// `Customer` для cart/orders/checkout. Реализации подключает `app/di/overrides.dart` списком `customersBindings`
// (data/customers_bindings.dart, L-8). В widget-тестах — `customersRepositoryProvider.overrideWithValue(fake)`.
//
// Этап G (основа): справочник клиентов (SCR-31…SCR-33, SCR-35), долги (SCR-32/SCR-34, SCR-30) с памятью финансов
// сессии (CASH-015), избранные клиенты (SCR-40, SCR-30). В widget-тестах — `<x>RepositoryProvider.overrideWithValue`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_json_decoder.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/favorite_customers_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/receivables_repository.dart';

Never _unbound(String name) => throw UnimplementedError('$name: подключите customersBindings в app/di/overrides.dart');

/// Клиенты: поиск, карточка, создание (только онлайн).
final customersRepositoryProvider = Provider<CustomersRepository>((ref) => _unbound('customersRepositoryProvider'));

/// Разбор вложенного `Customer` для фич-потребителей (cart, orders, checkout).
final customerJsonDecoderProvider = Provider<CustomerJsonDecoder>((ref) => _unbound('customerJsonDecoderProvider'));

/// Справочник клиентов этапа G: список, карточка с `include`, история, скидки (только онлайн).
final customerDirectoryRepositoryProvider = Provider<CustomerDirectoryRepository>(
  (ref) => _unbound('customerDirectoryRepositoryProvider'),
);

/// Долги клиента (снимок 1С, детализация со step-up, «Обновить», просрочка). Только онлайн; ответ — в
/// [customerFinanceMemoryProvider].
final receivablesRepositoryProvider = Provider<ReceivablesRepository>(
  (ref) => _unbound('receivablesRepositoryProvider'),
);

/// Избранные клиенты (≤ 12). Только онлайн.
final favoriteCustomersRepositoryProvider = Provider<FavoriteCustomersRepository>(
  (ref) => _unbound('favoriteCustomersRepositoryProvider'),
);

/// Финансовые данные клиентов текущей сессии (CASH-015): только память процесса; новая память — при смене
/// пользователя сессии (вход другого сотрудника, выход). Офлайн экраны показывают только её содержимое.
final customerFinanceMemoryProvider = Provider<CustomerFinanceMemory>((ref) {
  ref.watch(sessionControllerProvider.select((s) => s.userId));
  final InMemoryCustomerFinanceMemory memory = InMemoryCustomerFinanceMemory();
  ref.onDispose(memory.clear);
  return memory;
});
