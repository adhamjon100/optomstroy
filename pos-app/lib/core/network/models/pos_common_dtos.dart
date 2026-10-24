// DTO-кодеки общих схем OpenAPI (contracts/openapi/pos-api.v1.yaml 1.1.0) для фич этапа F (ADR-085: вручную).
// Кодек схемы = набор ключей контракта ([jsonKeys], [requiredKeys]) + разбор в сущность / сборка тела запроса.
// Ключи, которые клиент получает, но не переносит в сущность, перечислены в `ignoredKeys` — сверка с OpenAPI
// (test/core/network/models/pos_common_dtos_contract_test.dart и тесты фич) требует jsonKeys ∪ ignoredKeys ==
// properties схемы. Деньги — `Money` (тыйыны), количества — `Qty` (milli-units).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/dto_json.dart';

/// `Page` + `items` конкретной схемы.
abstract final class PageDto {
  static const Set<String> jsonKeys = {'items', 'nextCursor', 'hasMore', 'totalEstimate', 'isEstimate', 'asOf'};
  static const Set<String> requiredKeys = {'items', 'nextCursor', 'hasMore'};

  static PageResult<T> fromJson<T>(JsonMap j, T Function(JsonMap item) item) => PageResult<T>(
    items: jObjects(j, 'items', item, required: true),
    nextCursor: jOpt<String>(j, 'nextCursor'),
    hasMore: jBool(j, 'hasMore') ?? false,
    totalEstimate: jInt(j, 'totalEstimate'),
    isEstimate: jBool(j, 'isEstimate') ?? false,
    asOf: jDate(j, 'asOf'),
  );
}

/// `Warning`.
abstract final class WarningDto {
  static const Set<String> jsonKeys = {'code', 'message'};
  static const Set<String> requiredKeys = {'code', 'message'};

  static ApiWarning fromJson(JsonMap j) =>
      ApiWarning(rawCode: jReq<String>(j, 'code'), message: jOpt<String>(j, 'message') ?? '');

  /// `warnings[]` ответа.
  static List<ApiWarning> listOf(JsonMap j, [String key = 'warnings']) => jObjects(j, key, fromJson);
}

/// `UserRef`.
abstract final class UserRefDto {
  static const Set<String> jsonKeys = {'id', 'displayName', 'role'};
  static const Set<String> requiredKeys = {'id', 'displayName'};

  static UserRef fromJson(JsonMap j) => UserRef(
    id: jReq<String>(j, 'id'),
    displayName: jReq<String>(j, 'displayName'),
    role: jEnum(j, 'role', RoleCode.tryParse),
  );

  static UserRef? optional(JsonMap j, String key) {
    final JsonMap? v = jObject(j, key);
    return v == null ? null : fromJson(v);
  }
}

/// `AuditMeta` — клиент не использует (служебные метки сервера); ключи — для сверки.
abstract final class AuditMetaDto {
  static const Set<String> jsonKeys = <String>{};
  static const Set<String> ignoredKeys = {'createdAt', 'createdBy', 'updatedAt', 'updatedBy', 'rowVersion', 'deviceId'};
  static const Set<String> requiredKeys = <String>{};
}

/// `Quantity`.
abstract final class QuantityDto {
  static const Set<String> jsonKeys = {'value', 'unitId', 'packagingId', 'baseValue'};
  static const Set<String> requiredKeys = {'value', 'unitId'};

  static LineQuantity fromJson(JsonMap j) => LineQuantity(
    value: jQty(j, 'value') ?? (throw const DtoFormatException('value')),
    unitId: jReq<String>(j, 'unitId'),
    packagingId: jOpt<String>(j, 'packagingId'),
    baseValue: jQty(j, 'baseValue'),
  );

  static LineQuantity? optional(JsonMap j, String key) {
    final JsonMap? v = jObject(j, key);
    return v == null ? null : fromJson(v);
  }

  /// Тело запроса: `baseValue` — readOnly, не передаётся.
  static JsonMap toJson(LineQuantity q) => <String, dynamic>{
    'value': q.value.toApiString(),
    'unitId': q.unitId,
    'packagingId': q.packagingId,
  };
}

/// `Receiver`.
abstract final class ReceiverDto {
  static const Set<String> jsonKeys = {'kind', 'name', 'phone'};
  static const Set<String> requiredKeys = {'kind'};

  static Receiver fromJson(JsonMap j) => Receiver(
    kind: jReqEnum(j, 'kind', ReceiverKind.tryParse),
    name: jOpt<String>(j, 'name'),
    phoneE164: jOpt<String>(j, 'phone'),
  );

  static Receiver? optional(JsonMap j, String key) {
    final JsonMap? v = jObject(j, key);
    return v == null ? null : fromJson(v);
  }

  /// `kind=customer` — только `kind` (name/phone получателя не передаются).
  static JsonMap toJson(Receiver r) => <String, dynamic>{
    'kind': r.kind.value,
    if (r.kind == ReceiverKind.otherPerson) 'name': r.name,
    if (r.kind == ReceiverKind.otherPerson) 'phone': r.phoneE164,
  };
}

/// `Delivery` (без `geo` — R2, Q-178: в R1 поле в теле → `VALIDATION_FAILED` forbidden_field).
abstract final class DeliveryDto {
  static const Set<String> jsonKeys = {
    'method',
    'address',
    'recipientPhone',
    'courierComment',
    'desiredDate',
    'timeFrom',
    'timeTo',
  };
  static const Set<String> requiredKeys = {'method'};

  static Delivery fromJson(JsonMap j) => Delivery(
    method: jReqEnum(j, 'method', DeliveryMethod.tryParse),
    address: jOpt<String>(j, 'address'),
    recipientPhoneE164: jOpt<String>(j, 'recipientPhone'),
    courierComment: jOpt<String>(j, 'courierComment'),
    desiredDate: jDate(j, 'desiredDate'),
    timeFrom: jOpt<String>(j, 'timeFrom'),
    timeTo: jOpt<String>(j, 'timeTo'),
  );

  static Delivery? optional(JsonMap j, String key) {
    final JsonMap? v = jObject(j, key);
    return v == null ? null : fromJson(v);
  }

  /// `additionalProperties: false`: пустые поля не передаются.
  static JsonMap toJson(Delivery d) => <String, dynamic>{
    'method': d.method.value,
    'address': ?d.address,
    'recipientPhone': ?d.recipientPhoneE164,
    'courierComment': ?d.courierComment,
    if (d.desiredDate != null) 'desiredDate': _date(d.desiredDate!),
    'timeFrom': ?d.timeFrom,
    'timeTo': ?d.timeTo,
  };

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// `PrintOptions`.
abstract final class PrintOptionsDto {
  static const Set<String> jsonKeys = {'invoice', 'waybill', 'receipt'};
  static const Set<String> requiredKeys = <String>{};

  static PrintOptions fromJson(JsonMap j) =>
      PrintOptions(invoice: jBool(j, 'invoice'), waybill: jBool(j, 'waybill'), receipt: jBool(j, 'receipt'));

  static PrintOptions? optional(JsonMap j, String key) {
    final JsonMap? v = jObject(j, key);
    return v == null ? null : fromJson(v);
  }

  static JsonMap toJson(PrintOptions p) => <String, dynamic>{
    'invoice': ?p.invoice,
    'waybill': ?p.waybill,
    'receipt': ?p.receipt,
  };
}
