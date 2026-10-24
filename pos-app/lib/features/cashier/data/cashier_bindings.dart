// Привязка портов фичи cashier к реализациям data (06 §6.14, L-8). Подключение — `app/di/overrides.dart`.
// Вложенные `Customer` / `OrderSummary` / `Payment` разбирают кодеки фич customers и orders через их порты
// (`customerJsonDecoderProvider`, `orderJsonDecoderProvider`; DAG cashier → orders, customers; FL-06).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/cashier/cashier_providers.dart';
import 'package:optomstroy/features/cashier/data/dto/pos_dashboard_dtos.dart';
import 'package:optomstroy/features/cashier/data/repositories/dio_cashier_repository.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';

final List<Override> cashierBindings = <Override>[
  cashierRepositoryProvider.overrideWith((Ref ref) {
    final customer = ref.watch(customerJsonDecoderProvider);
    final order = ref.watch(orderJsonDecoderProvider);
    return DioCashierRepository(
      ref.watch(dioProvider),
      DashboardDecoders(customer: customer.decode, orderSummary: order.summary, payment: order.payment),
    );
  }),
];
