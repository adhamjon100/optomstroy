// DTO-кодеки заявок на возврат (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): `ReturnRequest`,
// `ReturnRequestItem`, `ReturnsItemInput`, `ReturnsCreateRequest`, `ReturnsUpdateRequest`, `ReturnsSubmitRequest`,
// `ReturnsAcceptRequest`, `ReturnsRejectRequest` (тела — `additionalProperties: false`).
// Сверка ключей — test/features/returns/data/return_dtos_contract_test.dart.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';

/// `ReturnRequestItem`.
abstract final class ReturnRequestItemDto {
  static const Set<String> jsonKeys = {'orderLineNo', 'variantId', 'quantity', 'maxReturnable', 'amount'};
  static const Set<String> requiredKeys = {'orderLineNo', 'variantId', 'quantity'};

  static ReturnRequestItem fromJson(JsonMap j) => ReturnRequestItem(
    orderLineNo: jReqInt(j, 'orderLineNo'),
    variantId: jReq<String>(j, 'variantId'),
    quantity: QuantityDto.fromJson(jReqObject(j, 'quantity')),
    maxReturnable: jLenientQty(j, 'maxReturnable'),
    amount: jMoney(j, 'amount'),
  );
}

/// `ReturnRequest`.
abstract final class ReturnRequestDto {
  static const Set<String> jsonKeys = {
    'id',
    'publicNumber',
    'status',
    'orderId',
    'shipmentRef',
    'shipmentNumber',
    'customerId',
    'reasonCode',
    'reasonComment',
    'items',
    'totalAmount',
    'refundKind',
    'approvalReason',
    'onec',
    'rowVersion',
    'audit',
  };
  static const Set<String> requiredKeys = {'id', 'status', 'orderId', 'items', 'rowVersion'};

  static ReturnRequest fromJson(JsonMap j) {
    final JsonMap? onec = jObject(j, 'onec');
    final JsonMap? audit = jObject(j, 'audit');
    return ReturnRequest(
      id: jReq<String>(j, 'id'),
      publicNumber: jOpt<String>(j, 'publicNumber'),
      status: ReturnRequestStatus.tryParse(jReq<String>(j, 'status')),
      orderId: jReq<String>(j, 'orderId'),
      shipmentRef: jOpt<String>(j, 'shipmentRef'),
      shipmentNumber: jOpt<String>(j, 'shipmentNumber'),
      customerId: jOpt<String>(j, 'customerId'),
      reasonCode: jEnum(j, 'reasonCode', ReturnReason.tryParse),
      reasonComment: jOpt<String>(j, 'reasonComment'),
      items: jObjects(j, 'items', ReturnRequestItemDto.fromJson, required: true),
      totalAmount: jMoney(j, 'totalAmount'),
      refundKind: jEnum(j, 'refundKind', PaymentMethod.tryParse),
      approvalReason: jEnum(j, 'approvalReason', ReturnApprovalReason.tryParse),
      onecRef: onec == null ? null : jOpt<String>(onec, 'ref'),
      onecStatus: onec == null ? null : jOpt<String>(onec, 'status'),
      rowVersion: jReqInt(j, 'rowVersion'),
      createdBy: audit == null ? null : UserRefDto.optional(audit, 'createdBy'),
      createdAt: audit == null ? null : jDate(audit, 'createdAt'),
      updatedAt: audit == null ? null : jDate(audit, 'updatedAt'),
    );
  }
}

/// `ReturnsItemInput`.
abstract final class ReturnItemInputDto {
  static const Set<String> jsonKeys = {'orderLineNo', 'quantity'};

  static JsonMap toJson(ReturnItemInput i) => <String, dynamic>{
    'orderLineNo': i.orderLineNo,
    'quantity': QuantityDto.toJson(i.quantity),
  };
}

/// `ReturnsCreateRequest`.
abstract final class ReturnCreateRequestDto {
  static const Set<String> jsonKeys = {'orderId', 'reasonCode', 'reasonComment', 'items', 'refundKind'};
  static const Set<String> requiredKeys = {'orderId', 'reasonCode', 'items'};

  static JsonMap toJson(ReturnDraftInput r) => <String, dynamic>{
    'orderId': r.orderId,
    'reasonCode': r.reasonCode.value,
    if (r.reasonComment != null && r.reasonComment!.isNotEmpty) 'reasonComment': r.reasonComment,
    'items': <JsonMap>[for (final ReturnItemInput i in r.items) ReturnItemInputDto.toJson(i)],
    if (r.refundKind != null) 'refundKind': r.refundKind!.value,
  };
}

/// `ReturnsUpdateRequest`.
abstract final class ReturnUpdateRequestDto {
  static const Set<String> jsonKeys = {'reasonCode', 'reasonComment', 'items', 'refundKind', 'rowVersion'};
  static const Set<String> requiredKeys = {'rowVersion'};

  static JsonMap toJson(ReturnDraftPatch p) => <String, dynamic>{
    if (p.reasonCode != null) 'reasonCode': p.reasonCode!.value,
    'reasonComment': ?p.reasonComment,
    if (p.items != null) 'items': <JsonMap>[for (final ReturnItemInput i in p.items!) ReturnItemInputDto.toJson(i)],
    if (p.refundKind != null) 'refundKind': p.refundKind!.value else if (p.clearRefundKind) 'refundKind': null,
    'rowVersion': p.rowVersion,
  };
}

/// `ReturnsSubmitRequest`.
abstract final class ReturnSubmitRequestDto {
  static const Set<String> jsonKeys = {'rowVersion', 'comment'};
  static const Set<String> requiredKeys = {'rowVersion'};

  static JsonMap toJson({required int rowVersion, String? comment}) => <String, dynamic>{
    'rowVersion': rowVersion,
    if (comment != null && comment.isNotEmpty) 'comment': comment,
  };
}

/// `ReturnsAcceptRequest`.
abstract final class ReturnAcceptRequestDto {
  static const Set<String> jsonKeys = {'comment', 'rowVersion'};
  static const Set<String> requiredKeys = {'rowVersion'};

  static JsonMap toJson({required int rowVersion, String? comment}) => <String, dynamic>{
    if (comment != null && comment.isNotEmpty) 'comment': comment,
    'rowVersion': rowVersion,
  };
}

/// `ReturnsRejectRequest`.
abstract final class ReturnRejectRequestDto {
  static const Set<String> jsonKeys = {'reason', 'rowVersion'};
  static const Set<String> requiredKeys = {'reason', 'rowVersion'};

  static JsonMap toJson({required String reason, required int rowVersion}) => <String, dynamic>{
    'reason': reason,
    'rowVersion': rowVersion,
  };
}

/// Страница `GET /returns`.
abstract final class ReturnsPageDto {
  static PageResult<ReturnRequest> fromJson(JsonMap j) => PageDto.fromJson(j, ReturnRequestDto.fromJson);
}
