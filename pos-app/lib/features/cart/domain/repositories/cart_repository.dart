// Порт серверной корзины (08 §4.7; 13 RM-F-001, RM-F-012). Клиент цены не передаёт (D-23, 08 §2.14): только
// количество, упаковку, `rowVersion` и (для предупреждения) `priceSnapshot`. Офлайн-изменения строк, склада, клиента
// и скидки идут через outbox `cart.sync` (07 §11.2) — его обработчик вызывает этот же порт. Чистый Dart (FL-01).
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';

/// Режим `PUT /cart/items/{variantId}`.
enum CartPutMode {
  /// Установить количество (0 — удалить строку). Повтор идемпотентен; единственный режим очереди `cart.sync`.
  set('set'),

  /// Прибавить (только онлайн «+ Добавить»; `Idempotency-Key` обязателен).
  increment('increment');

  const CartPutMode(this.value);

  final String value;
}

/// Тело `PUT /cart/items/{variantId}` (`CartPutItemRequest`).
final class CartItemPut {
  const CartItemPut({
    required this.quantity,
    required this.rowVersion,
    this.mode = CartPutMode.set,
    this.priceSnapshot,
  });

  /// Количество (`baseValue` не передаётся — считает сервер).
  final LineQuantity quantity;
  final int rowVersion;
  final CartPutMode mode;

  /// Цена, которую видел пользователь (только для предупреждения).
  final Money? priceSnapshot;
}

/// Запрос ручной скидки (`CartDiscountRequest`); [overrideReason] — подтверждение сверх лимита из своей сессии
/// (`discount.approve.over_limit` + step-up).
final class CartDiscountInput {
  const CartDiscountInput({required this.percent, required this.rowVersion, this.ruleId, this.overrideReason});

  final Percent percent;
  final int rowVersion;
  final String? ruleId;
  final String? overrideReason;
}

/// Чьи отложенные корзины (`GET /cart/parked?scope=`).
enum ParkedScope {
  own('own'),

  /// Все — `cart.parked.read.all` (senior_seller, admin, owner — просмотр).
  all('all');

  const ParkedScope(this.value);

  final String value;
}

abstract interface class CartRepository {
  /// Активная корзина (`GET /cart`; всегда 200 — при отсутствии сервер создаёт пустую `active`).
  Future<Result<Cart>> fetch({bool revalidate = true});

  /// Установить/увеличить количество позиции (`PUT /cart/items/{variantId}`).
  Future<Result<Cart>> putItem(String variantId, CartItemPut put, {String? idempotencyKey});

  /// Удалить строку (`DELETE /cart/items/{variantId}?packagingId=`); без [packagingId] — все строки варианта.
  Future<Result<Cart>> deleteItem(String variantId, {String? packagingId, String? idempotencyKey});

  /// Очистить активную корзину (`DELETE /cart?rowVersion=`).
  Future<Result<Cart>> clear({required int rowVersion});

  /// Сменить склад (`PATCH /cart {warehouseId, rowVersion}` — единственное назначение PATCH).
  Future<Result<Cart>> setWarehouse(String warehouseId, {required int rowVersion, String? idempotencyKey});

  /// Привязать клиента (`POST /cart/customer`); [receiver] `other_person` требует имя и телефон.
  Future<Result<Cart>> setCustomer(
    String customerId, {
    required int rowVersion,
    Receiver? receiver,
    String? idempotencyKey,
  });

  /// Отвязать клиента (`DELETE /cart/customer`).
  Future<Result<Cart>> clearCustomer({String? idempotencyKey});

  /// Ручная скидка (`POST /cart/discount`); [stepUpToken] — только при `overrideReason`.
  Future<Result<Cart>> applyDiscount(CartDiscountInput input, {String? idempotencyKey, String? stepUpToken});

  /// «Отложить заказ» (`POST /cart/park`, `Idempotency-Key` обязателен) → отложенная + новая пустая активная.
  Future<Result<CartParkResult>> park({required int rowVersion, String? name, required String idempotencyKey});

  /// Отложенные корзины (`GET /cart/parked`).
  Future<Result<PageResult<CartParkedSummary>>> listParked({
    ParkedScope scope = ParkedScope.own,
    String? cursor,
    int limit = 50,
  });

  /// Возобновить отложенную (`POST /cart/parked/{id}/resume`); [replaceActive] — текущая непустая паркуется
  /// как «Автосохранение <время>», иначе `409 ORDER_STATE_INVALID` (`active_not_empty`).
  Future<Result<Cart>> resumeParked(String cartId, {bool replaceActive = false, String? idempotencyKey});

  /// Удалить отложенную (`DELETE /cart/parked/{id}` → 204).
  Future<Result<void>> deleteParked(String cartId);

  /// Серверная корзина из `409 VERSION_CONFLICT` (`current`) — для диалога «Применить мои / Оставить серверную»
  /// (ядро §22.6); `null` — в ответе нет `current` или это не конфликт корзины.
  Cart? conflictCurrent(Failure failure);

  /// Конфликты строк из problem+json (`conflicts[]` у `PRICE_CHANGED` / `STOCK_INSUFFICIENT` /
  /// `VARIANT_UNAVAILABLE`).
  List<CartConflict> problemConflicts(Failure failure);
}
