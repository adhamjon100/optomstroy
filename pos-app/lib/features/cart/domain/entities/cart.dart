// Серверная корзина (08 §3.8 `Cart`, `CartItem`, `CartConflict`, `CartParkedSummary`). Сервер — источник истины
// цен и итогов (D-23): суммы ([Cart.subtotal], [Cart.total], [CartLine.lineTotal] …) клиент только показывает,
// не пересчитывает. Деньги — `Money` (тыйыны), количества — `Qty` (milli-units), проценты — `Percent` (сотые), D-19.
// Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';

/// Вид конфликта корзины (`CartConflictKind`).
enum CartConflictKind {
  priceChanged('price_changed'),
  stockInsufficient('stock_insufficient'),
  variantUnavailable('variant_unavailable'),
  qtyNotMultiple('qty_not_multiple'),
  qtyBelowMin('qty_below_min');

  const CartConflictKind(this.value);

  final String value;

  static CartConflictKind? tryParse(String? value) {
    for (final CartConflictKind k in values) {
      if (k.value == value) return k;
    }
    return null;
  }
}

/// Пометка строки корзины (`CartItemWarning`).
enum CartItemWarning {
  priceChanged('price_changed'),
  stockInsufficient('stock_insufficient'),
  variantUnavailable('variant_unavailable'),
  qtyNotMultiple('qty_not_multiple');

  const CartItemWarning(this.value);

  final String value;

  static CartItemWarning? tryParse(String? value) {
    for (final CartItemWarning w in values) {
      if (w.value == value) return w;
    }
    return null;
  }
}

/// Агрегат наличия (`StockLevel`; клиенту при `customer_stock_display=status` — без количеств).
enum CartStockLevel {
  inStock('in_stock'),
  low('low'),
  out('out'),
  unknown('unknown');

  const CartStockLevel(this.value);

  final String value;

  static CartStockLevel? tryParse(String? value) {
    for (final CartStockLevel l in values) {
      if (l.value == value) return l;
    }
    return null;
  }
}

/// Миниатюра строки (`Image`): файл — `GET /images/{sha}/{size}` (URL содержит sha → immutable).
final class CartImage {
  const CartImage({required this.sha256, this.thumbUrl, this.cardUrl, this.fullUrl});

  final String sha256;
  final String? thumbUrl;
  final String? cardUrl;
  final String? fullUrl;
}

/// Упаковка строки (`Packaging`).
final class CartPackaging {
  const CartPackaging({
    required this.id,
    required this.unitId,
    required this.factor,
    this.name,
    this.isDefault,
    this.allowFraction,
    this.barcode,
  });

  final String id;
  final String unitId;
  final String? name;

  /// Сколько базовых единиц в упаковке.
  final Qty factor;
  final bool? isDefault;
  final bool? allowFraction;
  final String? barcode;
}

/// Строка корзины (`CartItem`). Пара (`variantId`, `packagingId`) уникальна (CART-002).
final class CartLine {
  const CartLine({
    required this.variantId,
    required this.quantity,
    this.productId,
    this.productName,
    this.variantName,
    this.sku,
    this.image,
    this.packaging,
    this.unitPrice,
    this.priceSnapshot,
    this.lineTotal,
    this.lineDiscount,
    this.available,
    this.remainingAvailable,
    this.warnings = const <CartItemWarning>[],
    this.addedAt,
  });

  final String variantId;
  final String? productId;
  final String? productName;
  final String? variantName;
  final String? sku;
  final CartImage? image;
  final LineQuantity quantity;
  final CartPackaging? packaging;

  /// Цена за единицу строки — расчёт сервера.
  final Money? unitPrice;

  /// Цена, которую видел пользователь при добавлении (только предупреждение `price_changed`).
  final Money? priceSnapshot;
  final Money? lineTotal;
  final Money? lineDiscount;

  /// Доступно на складе корзины (базовая единица; может быть отрицательным — EQ-CAT-12); `null` — скрыто
  /// (`customer` при `customer_stock_display=status`).
  final Qty? available;

  /// Сколько ещё можно добавить (базовая единица, ≥ 0); `null` — остаток неизвестен, добавление запрещено.
  final Qty? remainingAvailable;
  final List<CartItemWarning> warnings;
  final DateTime? addedAt;

  /// Упаковка строки (`quantity.packagingId`).
  String? get packagingId => quantity.packagingId;
}

/// Конфликт корзины (`CartConflict`: предупреждение `Cart.warnings[]`, `CheckoutPreview.conflicts[]`,
/// `conflicts[]` в problem+json `PRICE_CHANGED`/`STOCK_INSUFFICIENT`/`VARIANT_UNAVAILABLE`).
final class CartConflict {
  const CartConflict({
    required this.variantId,
    required this.rawKind,
    this.oldPrice,
    this.newPrice,
    this.requested,
    this.available,
    this.stockLevel,
    this.factor,
  });

  final String variantId;

  /// Вид как пришёл (неизвестный сохраняется).
  final String rawKind;
  final Money? oldPrice;
  final Money? newPrice;
  final LineQuantity? requested;

  /// Доступно (базовая единица; со знаком); `null` — неизвестно / скрыто.
  final Qty? available;
  final CartStockLevel? stockLevel;
  final Qty? factor;

  CartConflictKind? get kind => CartConflictKind.tryParse(rawKind);
}

/// Активная или отложенная корзина (`Cart`).
final class Cart {
  const Cart({
    required this.id,
    required this.status,
    required this.items,
    required this.rowVersion,
    this.name,
    this.ownerId,
    this.customer,
    this.receiver,
    this.warehouseId,
    this.priceListId,
    this.itemsCount,
    this.unitsCount,
    this.subtotal,
    this.requestedDiscountPercent,
    this.appliedDiscountPercent,
    this.discountTotal,
    this.customerDiscountPercent,
    this.total,
    this.discountLimitPercent,
    this.warnings = const <CartConflict>[],
    this.restoredFromOrderId,
    this.restoredFromOrder,
    this.parkedAt,
    this.expiresAt,
    this.createdById,
  });

  /// Предел строк корзины (`items.maxItems`).
  static const int maxItems = 200;

  final String id;
  final CartStatus status;
  final String? name;
  final String? ownerId;

  /// Ролевое представление клиента без сумм долга (только флаги).
  final Customer? customer;
  final Receiver? receiver;
  final String? warehouseId;
  final String? priceListId;
  final List<CartLine> items;
  final int? itemsCount;
  final Qty? unitsCount;
  final Money? subtotal;
  final Percent? requestedDiscountPercent;
  final Percent? appliedDiscountPercent;
  final Money? discountTotal;
  final Percent? customerDiscountPercent;
  final Money? total;

  /// Лимит ручной скидки роли (`role_discount_limits`).
  final Percent? discountLimitPercent;
  final List<CartConflict> warnings;

  /// Корзина восстановлена из заказа (отказ 1С, отмена) — баннер `cart_banner_restored_from_order`.
  final String? restoredFromOrderId;

  /// Номер заказа и причина отказа 1С для баннера (`Cart.restoredFromOrder`, OpenAPI 1.2.0); `null` — номер заказа
  /// серверу неизвестен (тогда номер — из [name], причина опускается; 08 §3.8 «Уточнения» п. 4).
  final CartRestoredFromOrder? restoredFromOrder;

  /// Версия для оптимистической блокировки (цепочка `cart.sync`, 07 §11.2).
  final int rowVersion;
  final DateTime? parkedAt;
  final DateTime? expiresAt;

  /// Автор корзины (`audit.createdBy.id`): корзина возобновлена из чужой отложенной, если автор — не текущий
  /// пользователь (02 UI-20-033).
  final String? createdById;

  bool get isEmpty => items.isEmpty;
}

/// Заказ, из которого восстановлена корзина (`Cart.restoredFromOrder`, 08 §3.8; 10 ORD-027).
final class CartRestoredFromOrder {
  const CartRestoredFromOrder({required this.number, this.reason});

  /// Номер заказа POS (`publicNumber`).
  final String number;

  /// Причина отказа 1С (без внутренних данных 1С); `null` — неизвестна.
  final String? reason;
}

/// Элемент списка отложенных (`CartParkedSummary`) — без строк.
final class CartParkedSummary {
  const CartParkedSummary({
    required this.id,
    required this.status,
    required this.rowVersion,
    this.name,
    this.ownerId,
    this.owner,
    this.customer,
    this.warehouseId,
    this.priceListId,
    this.itemsCount,
    this.unitsCount,
    this.subtotal,
    this.discountTotal,
    this.total,
    this.restoredFromOrderId,
    this.parkedAt,
    this.expiresAt,
  });

  final String id;
  final CartStatus status;
  final String? name;
  final String? ownerId;

  /// Владелец (для `scope=all`).
  final UserRef? owner;
  final Customer? customer;
  final String? warehouseId;
  final String? priceListId;
  final int? itemsCount;
  final Qty? unitsCount;
  final Money? subtotal;
  final Money? discountTotal;
  final Money? total;
  final String? restoredFromOrderId;
  final int rowVersion;
  final DateTime? parkedAt;
  final DateTime? expiresAt;
}

/// Ответ `POST /cart/park` (`CartParkResponse`).
final class CartParkResult {
  const CartParkResult({required this.parked, required this.active});

  final Cart parked;
  final Cart active;
}
