// Разбор `Cart` / `CartConflict` (08 §3.8) для фич-потребителей (checkout) без импорта cart/data (FL-06):
// `CheckoutPreview.conflicts[]`, `current` у `409 VERSION_CONFLICT` на `POST /orders`. Чистый Dart (FL-01).
import 'package:optomstroy/features/cart/domain/entities/cart.dart';

abstract interface class CartJsonDecoder {
  /// Корзина из JSON-объекта; не по контракту — исключение формата (вызов внутри `ErrorMapper.guard`).
  Cart cart(Map<String, dynamic> json);

  /// Конфликт строки корзины.
  CartConflict conflict(Map<String, dynamic> json);

  /// Конфликты из сырого списка (`conflicts[]`); элементы не по контракту пропускаются.
  List<CartConflict> conflicts(Object? raw);
}
