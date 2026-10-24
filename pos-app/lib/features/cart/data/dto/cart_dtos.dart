// DTO-кодеки корзины (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): `Cart`, `CartItem`,
// `CartConflict`, `CartParkedSummary`, `CartParkResponse`, `Image`, `Packaging` и тела запросов
// `CartPutItemRequest`, `CartUpdateRequest`, `CartCustomerSetRequest`, `CartDiscountRequest`, `CartParkRequest`,
// `CartParkedResumeRequest`. Сверка ключей и разбор синтетических примеров — test/features/cart/data/.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';

/// Разбор вложенного клиента: фича cart не импортирует data фичи customers (FL-06), поэтому кодек клиента
/// передаётся извне (bindings) — по умолчанию минимальный (id, name, displayName, флаги).
typedef CustomerDecoder = Customer Function(JsonMap json);

/// Минимальный разбор `Customer` для корзины (полный кодек — customers/data, подставляется в bindings).
Customer minimalCustomer(JsonMap j) => Customer(
  id: jReq<String>(j, 'id'),
  name: jReq<String>(j, 'name'),
  displayName: jOpt<String>(j, 'displayName'),
  isRetailDefault: jBool(j, 'isRetailDefault') ?? false,
  creditAllowed: jBool(j, 'creditAllowed'),
  hasDebt: jBool(j, 'hasDebt'),
  isOverdue: jBool(j, 'isOverdue'),
  discountPercent: jPercent(j, 'discountPercent'),
  onecStatus: jEnum(j, 'onecStatus', CustomerOnecStatus.tryParse),
);

/// `Image`.
abstract final class CartImageDto {
  static const Set<String> jsonKeys = {'sha256', 'thumbUrl', 'cardUrl', 'fullUrl'};
  static const Set<String> ignoredKeys = {'isPrimary', 'width', 'height'};
  static const Set<String> requiredKeys = {'sha256'};

  static CartImage fromJson(JsonMap j) => CartImage(
    sha256: jReq<String>(j, 'sha256'),
    thumbUrl: jOpt<String>(j, 'thumbUrl'),
    cardUrl: jOpt<String>(j, 'cardUrl'),
    fullUrl: jOpt<String>(j, 'fullUrl'),
  );
}

/// `Packaging`.
abstract final class CartPackagingDto {
  static const Set<String> jsonKeys = {'id', 'unitId', 'name', 'factor', 'isDefault', 'allowFraction', 'barcode'};
  static const Set<String> requiredKeys = {'id', 'unitId', 'factor'};

  static CartPackaging fromJson(JsonMap j) => CartPackaging(
    id: jReq<String>(j, 'id'),
    unitId: jReq<String>(j, 'unitId'),
    name: jOpt<String>(j, 'name'),
    factor: jQty(j, 'factor') ?? (throw const DtoFormatException('factor')),
    isDefault: jBool(j, 'isDefault'),
    allowFraction: jBool(j, 'allowFraction'),
    barcode: jOpt<String>(j, 'barcode'),
  );
}

/// `CartItem`.
abstract final class CartItemDto {
  static const Set<String> jsonKeys = {
    'variantId',
    'productId',
    'productName',
    'variantName',
    'sku',
    'image',
    'quantity',
    'packaging',
    'unitPrice',
    'priceSnapshot',
    'lineTotal',
    'lineDiscount',
    'available',
    'remainingAvailable',
    'warnings',
    'addedAt',
  };
  static const Set<String> requiredKeys = {'variantId', 'quantity'};

  static CartLine fromJson(JsonMap j) {
    final JsonMap? image = jObject(j, 'image');
    final JsonMap? packaging = jObject(j, 'packaging');
    return CartLine(
      variantId: jReq<String>(j, 'variantId'),
      productId: jOpt<String>(j, 'productId'),
      productName: jOpt<String>(j, 'productName'),
      variantName: jOpt<String>(j, 'variantName'),
      sku: jOpt<String>(j, 'sku'),
      image: image == null ? null : CartImageDto.fromJson(image),
      quantity: QuantityDto.fromJson(jReqObject(j, 'quantity')),
      packaging: packaging == null ? null : CartPackagingDto.fromJson(packaging),
      unitPrice: jMoney(j, 'unitPrice'),
      priceSnapshot: jMoney(j, 'priceSnapshot'),
      lineTotal: jMoney(j, 'lineTotal'),
      lineDiscount: jMoney(j, 'lineDiscount'),
      available: jSignedQty(j, 'available'),
      remainingAvailable: jQty(j, 'remainingAvailable'),
      warnings: <CartItemWarning>[
        for (final String w in jStrings(j, 'warnings'))
          if (CartItemWarning.tryParse(w) case final CartItemWarning known) known,
      ],
      addedAt: jDate(j, 'addedAt'),
    );
  }
}

/// `CartConflict`.
abstract final class CartConflictDto {
  static const Set<String> jsonKeys = {
    'variantId',
    'kind',
    'oldPrice',
    'newPrice',
    'requested',
    'available',
    'stockLevel',
    'factor',
  };
  static const Set<String> requiredKeys = {'variantId', 'kind'};

  static CartConflict fromJson(JsonMap j) => CartConflict(
    variantId: jReq<String>(j, 'variantId'),
    rawKind: jReq<String>(j, 'kind'),
    oldPrice: jMoney(j, 'oldPrice'),
    newPrice: jMoney(j, 'newPrice'),
    requested: QuantityDto.optional(j, 'requested'),
    available: jLenientQty(j, 'available'),
    stockLevel: jEnum(j, 'stockLevel', CartStockLevel.tryParse),
    factor: jLenientQty(j, 'factor'),
  );

  /// `conflicts[]` / `warnings[]`; элементы не по контракту пропускаются (предупреждения не ломают корзину).
  static List<CartConflict> listOf(Object? raw) {
    if (raw is! List) return const <CartConflict>[];
    final List<CartConflict> out = <CartConflict>[];
    for (final Object? item in raw) {
      if (item is! Map) continue;
      try {
        out.add(fromJson(item.cast<String, dynamic>()));
      } on DtoFormatException {
        continue;
      }
    }
    return out;
  }
}

/// `Cart`.
abstract final class CartDto {
  static const Set<String> jsonKeys = {
    'id',
    'status',
    'name',
    'ownerId',
    'customer',
    'receiver',
    'warehouseId',
    'priceListId',
    'items',
    'itemsCount',
    'unitsCount',
    'subtotal',
    'requestedDiscountPercent',
    'appliedDiscountPercent',
    'discountTotal',
    'customerDiscountPercent',
    'total',
    'discountLimitPercent',
    'warnings',
    'restoredFromOrderId',
    // OpenAPI 1.2.0 (08 §3.8 «Уточнения CheckoutPreview и Cart» п. 4): номер и причина отказа 1С для баннера.
    'restoredFromOrder',
    'rowVersion',
    'parkedAt',
    'expiresAt',
    // `audit.createdBy.id` — автор корзины (02 UI-20-033: override старшего в возобновлённой чужой корзине).
    'audit',
  };
  static const Set<String> ignoredKeys = <String>{};
  static const Set<String> requiredKeys = {'id', 'status', 'items', 'rowVersion'};

  static Cart fromJson(JsonMap j, {CustomerDecoder customer = minimalCustomer}) {
    final JsonMap? c = jObject(j, 'customer');
    final JsonMap? audit = jObject(j, 'audit');
    final JsonMap? createdBy = audit == null ? null : jObject(audit, 'createdBy');
    return Cart(
      id: jReq<String>(j, 'id'),
      status: jReqEnum(j, 'status', CartStatus.tryParse),
      name: jOpt<String>(j, 'name'),
      ownerId: jOpt<String>(j, 'ownerId'),
      customer: c == null ? null : customer(c),
      receiver: ReceiverDto.optional(j, 'receiver'),
      warehouseId: jOpt<String>(j, 'warehouseId'),
      priceListId: jOpt<String>(j, 'priceListId'),
      items: jObjects(j, 'items', CartItemDto.fromJson, required: true),
      itemsCount: jInt(j, 'itemsCount'),
      unitsCount: jQty(j, 'unitsCount'),
      subtotal: jMoney(j, 'subtotal'),
      requestedDiscountPercent: jPercent(j, 'requestedDiscountPercent'),
      appliedDiscountPercent: jPercent(j, 'appliedDiscountPercent'),
      discountTotal: jMoney(j, 'discountTotal'),
      customerDiscountPercent: jPercent(j, 'customerDiscountPercent'),
      total: jMoney(j, 'total'),
      discountLimitPercent: jPercent(j, 'discountLimitPercent'),
      warnings: CartConflictDto.listOf(j['warnings']),
      restoredFromOrderId: jOpt<String>(j, 'restoredFromOrderId'),
      restoredFromOrder: CartRestoredFromOrderDto.optional(j, 'restoredFromOrder'),
      rowVersion: jReqInt(j, 'rowVersion'),
      parkedAt: jDate(j, 'parkedAt'),
      expiresAt: jDate(j, 'expiresAt'),
      createdById: createdBy == null ? null : jOpt<String>(createdBy, 'id'),
    );
  }
}

/// `Cart.restoredFromOrder` (OpenAPI 1.2.0; nullable): `{number, reason}`. pos-api передаёт поле с закрытия этапа F
/// (`cart-dto.ts`, `restoredFromOrderDto`); `null` — корзина не восстановлена или номер заказа серверу неизвестен,
/// тогда баннер берёт номер из `Cart.name` (08 §3.8 «Уточнения» п. 4). Объект без `number` — не разбирается
/// (неполный объект не ломает разбор корзины, 08 §2.11).
abstract final class CartRestoredFromOrderDto {
  static const Set<String> jsonKeys = {'number', 'reason'};
  static const Set<String> requiredKeys = {'number'};

  static CartRestoredFromOrder? optional(JsonMap j, String key) {
    final JsonMap? o = jObject(j, key);
    if (o == null) return null;
    final String? number = jOpt<String>(o, 'number');
    if (number == null || number.isEmpty) return null;
    return CartRestoredFromOrder(number: number, reason: jOpt<String>(o, 'reason'));
  }
}

/// `CartParkedSummary`.
abstract final class CartParkedSummaryDto {
  static const Set<String> jsonKeys = {
    'id',
    'status',
    'name',
    'ownerId',
    'owner',
    'customer',
    'warehouseId',
    'priceListId',
    'itemsCount',
    'unitsCount',
    'subtotal',
    'discountTotal',
    'total',
    'restoredFromOrderId',
    'rowVersion',
    'parkedAt',
    'expiresAt',
  };
  static const Set<String> ignoredKeys = {'audit'};
  static const Set<String> requiredKeys = {'id', 'status', 'rowVersion'};

  static CartParkedSummary fromJson(JsonMap j, {CustomerDecoder customer = minimalCustomer}) {
    final JsonMap? c = jObject(j, 'customer');
    return CartParkedSummary(
      id: jReq<String>(j, 'id'),
      status: jReqEnum(j, 'status', CartStatus.tryParse),
      name: jOpt<String>(j, 'name'),
      ownerId: jOpt<String>(j, 'ownerId'),
      owner: UserRefDto.optional(j, 'owner'),
      customer: c == null ? null : customer(c),
      warehouseId: jOpt<String>(j, 'warehouseId'),
      priceListId: jOpt<String>(j, 'priceListId'),
      itemsCount: jInt(j, 'itemsCount'),
      unitsCount: jQty(j, 'unitsCount'),
      subtotal: jMoney(j, 'subtotal'),
      discountTotal: jMoney(j, 'discountTotal'),
      total: jMoney(j, 'total'),
      restoredFromOrderId: jOpt<String>(j, 'restoredFromOrderId'),
      rowVersion: jReqInt(j, 'rowVersion'),
      parkedAt: jDate(j, 'parkedAt'),
      expiresAt: jDate(j, 'expiresAt'),
    );
  }
}

/// `CartParkResponse`.
abstract final class CartParkResponseDto {
  static const Set<String> jsonKeys = {'parked', 'active'};
  static const Set<String> requiredKeys = {'parked', 'active'};

  static CartParkResult fromJson(JsonMap j, {CustomerDecoder customer = minimalCustomer}) => CartParkResult(
    parked: CartDto.fromJson(jReqObject(j, 'parked'), customer: customer),
    active: CartDto.fromJson(jReqObject(j, 'active'), customer: customer),
  );
}

/// Тела запросов корзины (все — `additionalProperties: false`).
abstract final class CartRequestDto {
  /// `CartPutItemRequest`.
  static const Set<String> putItemKeys = {'quantity', 'priceSnapshot', 'rowVersion', 'mode'};
  static const Set<String> putItemRequired = {'quantity', 'rowVersion'};

  static JsonMap putItem(CartItemPut p) => <String, dynamic>{
    'quantity': QuantityDto.toJson(p.quantity),
    if (p.priceSnapshot != null) 'priceSnapshot': moneyJson(p.priceSnapshot!),
    'rowVersion': p.rowVersion,
    'mode': p.mode.value,
  };

  /// `CartUpdateRequest`.
  static const Set<String> updateKeys = {'warehouseId', 'rowVersion'};
  static const Set<String> updateRequired = {'warehouseId', 'rowVersion'};

  static JsonMap update(String warehouseId, int rowVersion) => <String, dynamic>{
    'warehouseId': warehouseId,
    'rowVersion': rowVersion,
  };

  /// `CartCustomerSetRequest`.
  static const Set<String> customerKeys = {'customerId', 'receiver', 'rowVersion'};
  static const Set<String> customerRequired = {'customerId', 'rowVersion'};

  static JsonMap customer(String customerId, int rowVersion, Receiver? receiver) => <String, dynamic>{
    'customerId': customerId,
    if (receiver != null) 'receiver': ReceiverDto.toJson(receiver),
    'rowVersion': rowVersion,
  };

  /// `CartDiscountRequest`.
  static const Set<String> discountKeys = {'percent', 'ruleId', 'rowVersion', 'override'};
  static const Set<String> discountRequired = {'percent', 'rowVersion'};

  static JsonMap discount(CartDiscountInput d) => <String, dynamic>{
    'percent': d.percent.toApiString(),
    'ruleId': ?d.ruleId,
    'rowVersion': d.rowVersion,
    if (d.overrideReason != null) 'override': <String, dynamic>{'reason': d.overrideReason},
  };

  /// `CartParkRequest`.
  static const Set<String> parkKeys = {'name', 'rowVersion'};
  static const Set<String> parkRequired = {'rowVersion'};

  static JsonMap park(int rowVersion, String? name) => <String, dynamic>{
    if (name != null && name.isNotEmpty) 'name': name,
    'rowVersion': rowVersion,
  };

  /// `CartParkedResumeRequest`.
  static const Set<String> resumeKeys = {'replaceActive'};

  static JsonMap resume({required bool replaceActive}) => <String, dynamic>{'replaceActive': replaceActive};
}
