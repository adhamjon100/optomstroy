// Разбор `Order` / `OrderItem` / `OrderSummary` (08 §3.9) для фич-потребителей (checkout, cashier, transactions,
// returns) без импорта orders/data (FL-06): ответ `POST /orders`, `CheckoutPreview.items[]`. Чистый Dart (FL-01).
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

abstract interface class OrderJsonDecoder {
  /// Заказ; не по контракту — исключение формата (вызов внутри `ErrorMapper.guard`).
  Order order(Map<String, dynamic> json);

  /// Строка заказа.
  OrderLine line(Map<String, dynamic> json);

  /// Строка списка заказов.
  OrderSummary summary(Map<String, dynamic> json);

  /// Платёж.
  Payment payment(Map<String, dynamic> json);
}
