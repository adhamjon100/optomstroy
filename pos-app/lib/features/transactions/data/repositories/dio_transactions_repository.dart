// `TransactionsRepository` поверх единственного Dio-клиента. Ошибки → Failure только через ErrorMapper (06 §6.8).
// Массивы `status`/`kind` — повтор ключа (OpenAPI 1.2.0: style form, explode по умолчанию).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/transaction_dtos.dart';
import 'package:optomstroy/features/transactions/data/dto/transactions_dtos.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/domain/repositories/transactions_repository.dart';

/// Пути API журнала операций (08 §4.16).
abstract final class TransactionsApiPaths {
  static const String transactions = '/transactions';
  static String transaction(String id) => '/transactions/${Uri.encodeComponent(id)}';
}

final class DioTransactionsRepository implements TransactionsRepository {
  DioTransactionsRepository(this._dio);

  final Dio _dio;

  /// Query `GET /transactions` (вынесено для теста).
  static Map<String, Object?> queryOf(TransactionsQuery q) => <String, Object?>{
    'from': isoUtc(q.period.from),
    'to': isoUtc(q.period.to),
    'customerId': ?q.customerId,
    if (q.statuses.isNotEmpty) 'status': <String>[for (final s in q.statuses) s.value],
    if (q.kinds.isNotEmpty) 'kind': <String>[for (final k in q.kinds) k.value],
    if (q.source != null) 'source': q.source!.value,
    if (q.mine) 'mine': true,
    'actorId': ?q.actorId,
    if (q.paymentMethod != null) 'paymentMethod': q.paymentMethod!.value,
    if (q.amountMin != null) 'amountMin': q.amountMin!.toApiString(),
    if (q.amountMax != null) 'amountMax': q.amountMax!.toApiString(),
    if (q.q != null && q.q!.isNotEmpty) 'q': q.q,
    'limit': ?q.limit,
    'cursor': ?q.cursor,
    'sort': q.sort.value,
  };

  @override
  Future<Result<TransactionsPage>> list(TransactionsQuery query) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      TransactionsApiPaths.transactions,
      queryParameters: queryOf(query),
      options: apiOptions(),
    );
    return TransactionsPageDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<TransactionDetail>> get(String transactionId) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      TransactionsApiPaths.transaction(transactionId),
      options: apiOptions(),
    );
    return TransactionDetailDto.fromJson(jsonObject(r.data));
  });
}
