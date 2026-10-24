// Привязка портов фичи orders к реализациям data (06 §6.14, L-8). Подключение — `app/di/overrides.dart`.
// Вложенный `Customer` разбирает кодек фичи customers (`customerJsonDecoderProvider`; DAG orders → customers).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/orders/data/dto/order_dtos.dart';
import 'package:optomstroy/features/orders/data/repositories/dio_orders_repository.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/domain/repositories/order_json_decoder.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';

/// [OrderJsonDecoder] на кодеках `OrderDto`/`OrderItemDto`/`OrderSummaryDto`/`PaymentDto`.
final class OrderDtoDecoder implements OrderJsonDecoder {
  const OrderDtoDecoder({this.customer = minimalOrderCustomer});

  final OrderCustomerDecoder customer;

  @override
  Order order(Map<String, dynamic> json) => OrderDto.fromJson(json, customer: customer);

  @override
  OrderLine line(Map<String, dynamic> json) => OrderItemDto.fromJson(json);

  @override
  OrderSummary summary(Map<String, dynamic> json) => OrderSummaryDto.fromJson(json, customer: customer);

  @override
  Payment payment(Map<String, dynamic> json) => PaymentDto.fromJson(json);
}

final List<Override> ordersBindings = <Override>[
  ordersRepositoryProvider.overrideWith(
    (Ref ref) => DioOrdersRepository(ref.watch(dioProvider), customer: ref.watch(customerJsonDecoderProvider).decode),
  ),
  paymentsRepositoryProvider.overrideWith((Ref ref) => DioPaymentsRepository(ref.watch(dioProvider))),
  orderJsonDecoderProvider.overrideWith(
    (Ref ref) => OrderDtoDecoder(customer: ref.watch(customerJsonDecoderProvider).decode),
  ),
];
