// Разбор вложенного `Customer` (08 §3.7) для фич-потребителей (cart, orders, checkout) без импорта
// customers/data (FL-06): `Cart.customer`, `Order.customer`, `CartParkedSummary.customer`. Чистый Dart (FL-01).
import 'package:optomstroy/features/customers/domain/entities/customer.dart';

abstract interface class CustomerJsonDecoder {
  /// Клиент из JSON-объекта ответа; ответ не по контракту — исключение формата (вызов внутри `ErrorMapper.guard`).
  Customer decode(Map<String, dynamic> json);
}
