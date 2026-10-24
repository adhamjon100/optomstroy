// Полезные нагрузки записей `outbox_actions` этапа F (07 §11.2; ядро §19.4). Секреты и ПДн в `payload_json` не
// пишутся: токены — только secure storage / память (07 §11.1 п.4), имена и телефоны — нигде.
//
// `cart.sync` — контракт 07 §11.2 (`payload_json.op` → запрос API):
//   set_item       {localCartId, variantId, packagingId|null, unitId, quantityMilli} → PUT /cart/items/{variantId} (mode=set)
//   delete_item    {localCartId, variantId, packagingId|null}                         → DELETE /cart/items/{variantId}?packagingId=
//   set_warehouse  {localCartId, warehouseId}                                          → PATCH /cart
//   set_customer   {localCartId, customerId}                                           → POST /cart/customer
//   clear_customer {localCartId}                                                       → DELETE /cart/customer
//   set_discount   {localCartId, discountPercentHundredths}                            → POST /cart/discount
// Правила (07 §11.2): `mode=increment` в очереди нет; сжатие — новая `set_item`/`delete_item` той же пары заменяет
// прежнюю `pending` ([CartSyncPayload.coalesceKey]); цепочка `rowVersion` — строго последовательно.
//
// `auth.logout` — отложенный `POST /auth/logout` после офлайн-выхода (перенос RM-E RC-1/SS-07): в полезной нагрузке
// только идентификатор сессии и время; refresh-токен для отправки хранится в secure storage до восстановления сети.
import 'package:optomstroy/core/utils/qty.dart';

/// Операция записи `cart.sync`.
enum CartSyncOp {
  setItem('set_item'),
  deleteItem('delete_item'),
  setWarehouse('set_warehouse'),
  setCustomer('set_customer'),
  clearCustomer('clear_customer'),
  setDiscount('set_discount');

  const CartSyncOp(this.value);

  final String value;

  static CartSyncOp? tryParse(Object? value) {
    for (final CartSyncOp op in values) {
      if (op.value == value) return op;
    }
    return null;
  }
}

/// Полезная нагрузка `cart.sync` (07 §11.2).
final class CartSyncPayload {
  const CartSyncPayload._(this.op, this.fields);

  /// Целевое количество строки (не приращение).
  factory CartSyncPayload.setItem({
    required String localCartId,
    required String variantId,
    required String unitId,
    required Qty quantity,
    String? packagingId,
  }) => CartSyncPayload._(CartSyncOp.setItem, <String, Object?>{
    'localCartId': localCartId,
    'variantId': variantId,
    'packagingId': packagingId,
    'unitId': unitId,
    'quantityMilli': quantity.milli,
  });

  factory CartSyncPayload.deleteItem({required String localCartId, required String variantId, String? packagingId}) =>
      CartSyncPayload._(CartSyncOp.deleteItem, <String, Object?>{
        'localCartId': localCartId,
        'variantId': variantId,
        'packagingId': packagingId,
      });

  factory CartSyncPayload.setWarehouse({required String localCartId, required String warehouseId}) => CartSyncPayload._(
    CartSyncOp.setWarehouse,
    <String, Object?>{'localCartId': localCartId, 'warehouseId': warehouseId},
  );

  factory CartSyncPayload.setCustomer({required String localCartId, required String customerId}) => CartSyncPayload._(
    CartSyncOp.setCustomer,
    <String, Object?>{'localCartId': localCartId, 'customerId': customerId},
  );

  factory CartSyncPayload.clearCustomer({required String localCartId}) =>
      CartSyncPayload._(CartSyncOp.clearCustomer, <String, Object?>{'localCartId': localCartId});

  factory CartSyncPayload.setDiscount({required String localCartId, required int discountPercentHundredths}) =>
      CartSyncPayload._(CartSyncOp.setDiscount, <String, Object?>{
        'localCartId': localCartId,
        'discountPercentHundredths': discountPercentHundredths,
      });

  /// Разбор `payload_json` записи; неизвестная операция / нет обязательного поля → `null` (запись — `dead`).
  static CartSyncPayload? tryParse(Map<String, Object?> json) {
    final CartSyncOp? op = CartSyncOp.tryParse(json['op']);
    if (op == null || json['localCartId'] is! String) return null;
    final Map<String, Object?> fields = Map<String, Object?>.of(json)..remove('op');
    final bool ok = switch (op) {
      CartSyncOp.setItem =>
        fields['variantId'] is String && fields['unitId'] is String && fields['quantityMilli'] is int,
      CartSyncOp.deleteItem => fields['variantId'] is String,
      CartSyncOp.setWarehouse => fields['warehouseId'] is String,
      CartSyncOp.setCustomer => fields['customerId'] is String,
      CartSyncOp.clearCustomer => true,
      CartSyncOp.setDiscount => fields['discountPercentHundredths'] is int,
    };
    return ok ? CartSyncPayload._(op, Map<String, Object?>.unmodifiable(fields)) : null;
  }

  final CartSyncOp op;
  final Map<String, Object?> fields;

  String get localCartId => fields['localCartId']! as String;
  String? get variantId => fields['variantId'] as String?;
  String? get packagingId => fields['packagingId'] as String?;
  String? get unitId => fields['unitId'] as String?;
  Qty? get quantity => fields['quantityMilli'] is int ? Qty(fields['quantityMilli']! as int) : null;

  /// JSON записи (`payload_json`).
  Map<String, Object?> toJson() => <String, Object?>{'op': op.value, ...fields};

  /// Цель для сжатия очереди: записи с одинаковым ключом в статусе `pending` заменяются новой
  /// (`delete_item` поглощает `set_item` той же пары; склад/клиент/скидка — по типу операции).
  String get coalesceKey => switch (op) {
    CartSyncOp.setItem || CartSyncOp.deleteItem => 'item:$localCartId:$variantId:${packagingId ?? ''}',
    CartSyncOp.setWarehouse => 'warehouse:$localCartId',
    CartSyncOp.setCustomer || CartSyncOp.clearCustomer => 'customer:$localCartId',
    CartSyncOp.setDiscount => 'discount:$localCartId',
  };
}

/// Полезная нагрузка `auth.logout` — без токенов (07 §11.2).
final class AuthLogoutPayload {
  const AuthLogoutPayload({required this.requestedAt, this.sessionId});

  static AuthLogoutPayload? tryParse(Map<String, Object?> json) {
    final Object? at = json['requestedAt'];
    final DateTime? requestedAt = at is String ? DateTime.tryParse(at) : null;
    if (requestedAt == null) return null;
    final Object? sid = json['sessionId'];
    return AuthLogoutPayload(requestedAt: requestedAt.toUtc(), sessionId: sid is String ? sid : null);
  }

  /// Идентификатор серверной сессии (`sid`), если известен — запасной путь `DELETE /auth/sessions/{sid}`.
  final String? sessionId;

  /// Момент офлайн-выхода (UTC).
  final DateTime requestedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'requestedAt': requestedAt.toUtc().toIso8601String(),
    'sessionId': ?sessionId,
  };
}
