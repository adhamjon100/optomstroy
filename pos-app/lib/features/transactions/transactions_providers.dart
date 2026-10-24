// Публичный контракт фичи transactions (06 §6.1 L-3 (2), §6.14; FL-07).
//
// Этап G (основа): порт журнала операций SCR-36/SCR-37. Реализацию подключает `app/di/overrides.dart` списком
// `transactionsBindings` (data/transactions_bindings.dart, L-8). В widget-тестах —
// `transactionsRepositoryProvider.overrideWithValue(fake)`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/features/transactions/domain/repositories/transactions_repository.dart';

/// Журнал операций (только онлайн).
final transactionsRepositoryProvider = Provider<TransactionsRepository>(
  (ref) => throw UnimplementedError(
    'transactionsRepositoryProvider: подключите transactionsBindings в app/di/overrides.dart',
  ),
);
