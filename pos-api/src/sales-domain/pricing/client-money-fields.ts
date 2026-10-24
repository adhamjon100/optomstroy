/**
 * Денежные поля, которые клиент **не передаёт** ни в корзину, ни в заказ (D-23; 10 ORD-020, DISC-011; 08 §2.14):
 * `price`, `unitPrice`, `lineTotal`, `subtotal`, `total`, `discountAmount`, `amount`. Запрос с любым из них —
 * `400 VALIDATION_FAILED` (rule `forbidden_field`) и аудит `price.override_attempt`. Единый перечень для модулей
 * `cart` и `orders` (ревью F-money-rules-6: в `POST /orders` не распознавались `lineTotal`, `discountAmount`).
 */
export const CLIENT_FORBIDDEN_MONEY_FIELDS: readonly string[] = Object.freeze([
  'price',
  'unitPrice',
  'lineTotal',
  'subtotal',
  'total',
  'discountAmount',
  'amount',
]);
