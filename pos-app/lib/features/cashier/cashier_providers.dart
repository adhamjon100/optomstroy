// Публичный контракт фичи cashier (06 §6.1 L-3 (2), §6.14; FL-07).
//
// Этап G (основа): порт дашборда SCR-30 и флаг оплаты долга без заказа (RM-G-013, условная; Q-152 по умолчанию
// «нет»): `features.debtPaymentsFromPos=false` — режима SCR-38 «по долгу» (`/payments/new?customerId=`) и перехода
// SCR-34 → SCR-38 нет; `POST /payments` сервер отклоняет `403` (08 API-087). Реализации подключает
// `app/di/overrides.dart` списком `cashierBindings` (data/cashier_bindings.dart, L-8). В widget-тестах —
// `cashierRepositoryProvider.overrideWithValue(fake)`, `debtPaymentsFromPosProvider.overrideWithValue(…)`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/features/cashier/domain/repositories/cashier_repository.dart';

/// Дашборд кассира (только онлайн).
final cashierRepositoryProvider = Provider<CashierRepository>(
  (ref) => throw UnimplementedError('cashierRepositoryProvider: подключите cashierBindings в app/di/overrides.dart'),
);

/// Оплата долга без заказа (`GET /settings/public` → `features.debtPaymentsFromPos`; env `DEBT_PAYMENTS_FROM_POS`,
/// по умолчанию `false`). До ответа сервера — `false` (fail-closed).
final debtPaymentsFromPosProvider = Provider<bool>(
  (ref) => ref.watch(publicFeatureFlagsProvider.select((PublicFeatureFlags f) => f.debtPaymentsFromPos)),
);
