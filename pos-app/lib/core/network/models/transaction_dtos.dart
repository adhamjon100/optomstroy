// DTO-кодеки общих схем этапа G (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): `Transaction`,
// `TransactionRelated`, `AuditRow`. Используются data-слоем фич cashier (SCR-30), transactions (SCR-36/37) и admin
// (SCR-47). Сверка ключей — test/core/network/models/g_common_dtos_contract_test.dart.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/audit_record.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';

/// `TransactionRelated`.
abstract final class TransactionRelatedDto {
  static const Set<String> jsonKeys = {'type', 'id', 'number', 'url'};
  static const Set<String> requiredKeys = {'type'};

  static TransactionRelated fromJson(JsonMap j) => TransactionRelated(
    type: TransactionRelatedType.tryParse(jReq<String>(j, 'type')),
    id: jOpt<String>(j, 'id'),
    number: jOpt<String>(j, 'number'),
    url: jOpt<String>(j, 'url'),
  );
}

/// `Transaction` (элемент `GET /transactions`, `PosDashboard.recentTransactions`).
abstract final class TransactionDto {
  static const Set<String> jsonKeys = {
    'id',
    'kind',
    'number',
    'occurredAt',
    'amount',
    'sign',
    'status',
    'statusGroup',
    'customer',
    'actor',
    'source',
    'related',
  };
  static const Set<String> requiredKeys = {'id', 'kind', 'number', 'occurredAt', 'amount', 'status', 'related'};

  static Transaction fromJson(JsonMap j) {
    final JsonMap? customer = jObject(j, 'customer');
    return Transaction(
      id: jReq<String>(j, 'id'),
      kind: TransactionKind.tryParse(jReq<String>(j, 'kind')),
      number: jReq<String>(j, 'number'),
      occurredAt: jReqDate(j, 'occurredAt'),
      amount: jReqMoney(j, 'amount'),
      sign: jEnum(j, 'sign', TransactionSign.tryParse),
      status: jReq<String>(j, 'status'),
      statusGroup: jEnum(j, 'statusGroup', TransactionStatusGroup.tryParse),
      customer: customer == null
          ? null
          : TransactionCustomerRef(
              id: jOpt<String>(customer, 'id'),
              displayName: jOpt<String>(customer, 'displayName'),
            ),
      actor: UserRefDto.optional(j, 'actor'),
      source: jEnum(j, 'source', TransactionSource.tryParse),
      related: jObjects(j, 'related', TransactionRelatedDto.fromJson, required: true),
    );
  }
}

/// `AuditRow`.
abstract final class AuditRowDto {
  static const Set<String> jsonKeys = {
    'id',
    'occurredAt',
    'requestId',
    'actor',
    'actorRole',
    'sessionId',
    'deviceId',
    'ip',
    'appVersion',
    'action',
    'entityType',
    'entityId',
    'onecRef',
    'before',
    'after',
    'result',
    'stepUpMethod',
    'reason',
    'rowHash',
    'chainOk',
  };
  static const Set<String> requiredKeys = {'id', 'occurredAt', 'action', 'result', 'chainOk'};

  static AuditRecord fromJson(JsonMap j) => AuditRecord(
    id: jReq<String>(j, 'id'),
    occurredAt: jReqDate(j, 'occurredAt'),
    action: jReq<String>(j, 'action'),
    result: AuditResult.tryParse(jReq<String>(j, 'result')),
    chainOk: jReq<bool>(j, 'chainOk'),
    requestId: jOpt<String>(j, 'requestId'),
    actor: UserRefDto.optional(j, 'actor'),
    actorRole: jEnum(j, 'actorRole', RoleCode.tryParse),
    sessionId: jOpt<String>(j, 'sessionId'),
    deviceId: jOpt<String>(j, 'deviceId'),
    ip: jOpt<String>(j, 'ip'),
    appVersion: jOpt<String>(j, 'appVersion'),
    entityType: jOpt<String>(j, 'entityType'),
    entityId: jOpt<String>(j, 'entityId'),
    onecRef: jOpt<String>(j, 'onecRef'),
    before: jObject(j, 'before'),
    after: jObject(j, 'after'),
    stepUpMethod: jEnum(j, 'stepUpMethod', StepUpMethod.tryParse),
    reason: jOpt<String>(j, 'reason'),
    rowHash: jOpt<String>(j, 'rowHash'),
  );
}

/// Формат даты-времени фильтров журналов (`from`/`to` — ISO-8601 UTC).
String isoUtc(DateTime value) => value.toUtc().toIso8601String();

/// Формат даты (`YYYY-MM-DD`) для параметров `format: date`.
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
