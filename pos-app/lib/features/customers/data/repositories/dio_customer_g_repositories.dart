// Реализации портов клиентов этапа G поверх единственного Dio-клиента (core/network/dio_client.dart):
// справочник (SCR-31…SCR-33, SCR-35), долги (SCR-32/SCR-34, SCR-30), избранные клиенты (SCR-40, SCR-30).
// Ошибки → Failure только через ErrorMapper (06 §6.8); ответ не по контракту (`DtoFormatException`) → `UnknownFailure`.
// Массивы query (`include`, `linkStatus`) — повтор ключа (OpenAPI 1.2.0: style form, explode по умолчанию).
// Финансовые данные — только в [CustomerFinanceMemory] (память сессии, CASH-015); на диск не пишутся, не логируются.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/cancel_signal_dio.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/core/network/models/transaction_dtos.dart' show isoUtc;
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/features/customers/data/dto/customer_dtos.dart';
import 'package:optomstroy/features/customers/data/dto/customer_g_dtos.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_history.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/favorite_customers_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/receivables_repository.dart';

/// Пути API клиентов этапа G (08 §4.11–§4.14).
abstract final class CustomersGApiPaths {
  static const String customers = '/customers';
  static String customer(String id) => '/customers/${Uri.encodeComponent(id)}';
  static String history(String id) => '${customer(id)}/orders';
  static String discounts(String id) => '${customer(id)}/discounts';
  static String receivables(String id) => '${customer(id)}/receivables';
  static String receivablesRefresh(String id) => '${receivables(id)}/refresh';
  static const String overdue = '/receivables/overdue';
  static const String discountRules = '/discounts/rules';
  static const String favoriteCustomers = '/favorites/customers';
  static String favoriteCustomer(String id) => '$favoriteCustomers/${Uri.encodeComponent(id)}';
}

Options _opts({String? idempotencyKey, String? stepUpToken}) {
  final Options o = apiOptions(idempotencyKey: idempotencyKey);
  if (stepUpToken != null) o.headers![ApiHeaders.stepUpToken] = stepUpToken; // check-secrets: allow (имя заголовка)
  return o;
}

final class DioCustomerDirectoryRepository implements CustomerDirectoryRepository {
  DioCustomerDirectoryRepository(this._dio);

  final Dio _dio;

  @override
  Future<Result<PageResult<Customer>>> list(CustomersListQuery query, {CancelSignal? cancel}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.get<Object?>(
          CustomersGApiPaths.customers,
          queryParameters: <String, Object?>{
            if (query.q != null && query.q!.isNotEmpty) 'q': query.q,
            if (query.favoriteOnly) 'favorite': true,
            'hasDebt': ?query.hasDebt,
            'isOverdue': ?query.isOverdue,
            if (query.customerType != null) 'customerType': query.customerType!.value,
            if (query.linkStatuses.isNotEmpty) 'linkStatus': <String>[for (final s in query.linkStatuses) s.value],
            if (query.withReceivable) 'include': 'receivable',
            'limit': ?query.limit,
            'cursor': ?query.cursor,
            if (query.sort != null) 'sort': query.sort!.value,
          },
          options: _opts(),
          cancelToken: dioCancelToken(cancel),
        );
        return PageDto.fromJson(jsonObject(r.data), CustomerDto.fromJson);
      });

  @override
  Future<Result<Customer>> card(String customerId, {Set<CustomerInclude> include = const <CustomerInclude>{}}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.get<Object?>(
          CustomersGApiPaths.customer(customerId),
          queryParameters: <String, Object?>{
            if (include.isNotEmpty) 'include': <String>[for (final CustomerInclude i in include) i.value],
          },
          options: _opts(),
        );
        return CustomerDto.fromJson(jsonObject(r.data));
      });

  @override
  Future<Result<CustomerHistory>> history(String customerId, CustomerHistoryQuery query, {CancelSignal? cancel}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.get<Object?>(
          CustomersGApiPaths.history(customerId),
          queryParameters: <String, Object?>{
            if (query.from != null) 'from': isoUtc(query.from!),
            if (query.to != null) 'to': isoUtc(query.to!),
            if (query.source != null) 'source': query.source!.value,
            'limit': ?query.limit,
            'cursor': ?query.cursor,
          },
          options: _opts(),
          cancelToken: dioCancelToken(cancel),
        );
        return CustomerHistoryDto.fromJson(jsonObject(r.data));
      });

  @override
  Future<Result<CustomerDiscounts>> discounts(String customerId) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(CustomersGApiPaths.discounts(customerId), options: _opts());
    return CustomerDiscountsDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<DiscountRulesInfo>> discountRules({String? customerId, String? cartId}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      CustomersGApiPaths.discountRules,
      queryParameters: <String, Object?>{'customerId': ?customerId, 'cartId': ?cartId},
      options: _opts(),
    );
    return DiscountRulesDto.fromJson(jsonObject(r.data));
  });
}

final class DioReceivablesRepository implements ReceivablesRepository {
  DioReceivablesRepository(this._dio, this._memory);

  final Dio _dio;
  final CustomerFinanceMemory _memory;

  @override
  Future<Result<Receivable>> get(
    String customerId, {
    bool withDocuments = false,
    bool refresh = false,
    String? stepUpToken,
  }) => _remember(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      CustomersGApiPaths.receivables(customerId),
      queryParameters: <String, Object?>{if (withDocuments) 'include': 'documents', if (refresh) 'refresh': true},
      options: _opts(stepUpToken: stepUpToken),
    );
    return ReceivableDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<Receivable>> refresh(
    String customerId, {
    bool withDocuments = false,
    String? idempotencyKey,
    String? stepUpToken,
  }) => _remember(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      CustomersGApiPaths.receivablesRefresh(customerId),
      queryParameters: <String, Object?>{if (withDocuments) 'include': 'documents'},
      options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return ReceivableDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<OverdueReceivablesPage>> overdue(OverdueReceivablesQuery query) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      CustomersGApiPaths.overdue,
      queryParameters: <String, Object?>{
        'minOverdueDays': ?query.minOverdueDays,
        if (query.minAmount != null) 'minAmount': query.minAmount!.toApiString(),
        'limit': ?query.limit,
        'cursor': ?query.cursor,
        if (query.sort != null) 'sort': query.sort!.value,
      },
      options: _opts(),
    );
    return OverdueReceivableDto.pageFromJson(jsonObject(r.data));
  });

  Future<Result<Receivable>> _remember(Future<Receivable> Function() call) async {
    final Result<Receivable> result = await ErrorMapper.guard(call);
    if (result case Success<Receivable>(:final Receivable value)) _memory.putReceivable(value);
    return result;
  }
}

final class DioFavoriteCustomersRepository implements FavoriteCustomersRepository {
  DioFavoriteCustomersRepository(this._dio);

  final Dio _dio;

  @override
  Future<Result<FavoriteCustomersPage>> list({int? limit, String? cursor}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      CustomersGApiPaths.favoriteCustomers,
      queryParameters: <String, Object?>{'limit': ?limit, 'cursor': ?cursor},
      options: _opts(),
    );
    final (PageResult<Customer> page, int count) = FavoriteCustomersPageDto.fromJson(jsonObject(r.data));
    return FavoriteCustomersPage(page: page, count: count);
  });

  @override
  Future<Result<void>> add(String customerId, {String? idempotencyKey}) => ErrorMapper.guard<void>(() async {
    await _dio.put<Object?>(
      CustomersGApiPaths.favoriteCustomer(customerId),
      options: _opts(idempotencyKey: idempotencyKey),
    );
  });

  @override
  Future<Result<void>> remove(String customerId) => ErrorMapper.guard<void>(() async {
    await _dio.delete<Object?>(CustomersGApiPaths.favoriteCustomer(customerId), options: _opts());
  });
}
