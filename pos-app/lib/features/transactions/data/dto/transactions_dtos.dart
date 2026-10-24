// DTO-кодеки журнала операций (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): ответ `GET /transactions`
// (Page + `summary`), `TransactionsSummary`, `TransactionsDetail`. `Transaction`/`AuditRow` — core/network/models.
// Сверка ключей — test/features/transactions/data/transactions_dtos_contract_test.dart.
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/core/network/models/transaction_dtos.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';

/// `TransactionsSummary`.
abstract final class TransactionsSummaryDto {
  static const Set<String> jsonKeys = {'count', 'sumIn', 'sumOut'};
  static const Set<String> requiredKeys = {'count', 'sumIn', 'sumOut'};

  static TransactionsSummary fromJson(JsonMap j) =>
      TransactionsSummary(count: jReqInt(j, 'count'), sumIn: jReqMoney(j, 'sumIn'), sumOut: jReqMoney(j, 'sumOut'));
}

/// Ответ `GET /transactions`.
abstract final class TransactionsPageDto {
  static const Set<String> jsonKeys = {...PageDto.jsonKeys, 'summary'};

  static TransactionsPage fromJson(JsonMap j) {
    final JsonMap? summary = jObject(j, 'summary');
    return TransactionsPage(
      page: PageDto.fromJson(j, TransactionDto.fromJson),
      summary: summary == null ? null : TransactionsSummaryDto.fromJson(summary),
    );
  }
}

/// `TransactionsDetail` (= Transaction + `audit`).
abstract final class TransactionDetailDto {
  static const Set<String> jsonKeys = {...TransactionDto.jsonKeys, 'audit'};
  static const Set<String> requiredKeys = TransactionDto.requiredKeys;

  static TransactionDetail fromJson(JsonMap j) =>
      TransactionDetail(transaction: TransactionDto.fromJson(j), audit: jObjects(j, 'audit', AuditRowDto.fromJson));
}
