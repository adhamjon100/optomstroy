// Порт избранных клиентов (SCR-40 вкладка «Клиенты», SCR-30 «Избранные клиенты», SCR-31 фильтр, SCR-32 звезда;
// 08 §4.14 `/favorites/customers`; 10 FAV-; RM-G-004, RM-G-011: не более 12). Права — `favorites.customers.manage`
// (cashier, senior_seller, admin). Только онлайн (в outbox избранные клиенты не входят). Чистый Dart (FL-01).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';

/// Страница избранных клиентов (+ `count` для бейджа).
final class FavoriteCustomersPage {
  const FavoriteCustomersPage({required this.page, required this.count});

  final PageResult<Customer> page;
  final int count;
}

abstract interface class FavoriteCustomersRepository {
  /// Максимум избранных клиентов (RM-G-011; 13-й отклоняется сервером).
  static const int maxFavorites = 12;

  /// `GET /favorites/customers`.
  Future<Result<FavoriteCustomersPage>> list({int? limit, String? cursor});

  /// `PUT /favorites/customers/{id}` (идемпотентно).
  Future<Result<void>> add(String customerId, {String? idempotencyKey});

  /// `DELETE /favorites/customers/{id}`.
  Future<Result<void>> remove(String customerId);
}
