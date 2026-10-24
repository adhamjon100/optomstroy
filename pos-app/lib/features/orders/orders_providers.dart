// Публичный контракт фичи orders (06 §6.1 L-3 (2), §6.14; FL-07).
//
// Этап F (основа): порты заказов (SCR-24, SCR-25, печать PDF) и платежей (SCR-22 ожидание оплаты, SCR-38 этапа G).
// Реализации подключает `app/di/overrides.dart` списком `ordersBindings` (data/orders_bindings.dart, L-8).
// В widget-тестах — `ordersRepositoryProvider.overrideWithValue(fake)`, `paymentsRepositoryProvider.overrideWithValue(fake)`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/features/orders/domain/repositories/order_json_decoder.dart';
import 'package:optomstroy/features/orders/domain/repositories/orders_repository.dart';

Never _unbound(String name) => throw UnimplementedError('$name: подключите ordersBindings в app/di/overrides.dart');

/// Заказы: список, деталь, отмена, документы, привязка к 1С (только онлайн).
final ordersRepositoryProvider = Provider<OrdersRepository>((ref) => _unbound('ordersRepositoryProvider'));

/// Платежи: приём по заказу, long-polling статуса, ручное подтверждение, аннулирование (только онлайн).
final paymentsRepositoryProvider = Provider<PaymentsRepository>((ref) => _unbound('paymentsRepositoryProvider'));

/// Разбор `Order`/`OrderItem`/`OrderSummary`/`Payment` для фич-потребителей (checkout, cashier, …) без импорта
/// orders/data (FL-06).
final orderJsonDecoderProvider = Provider<OrderJsonDecoder>((ref) => _unbound('orderJsonDecoderProvider'));
