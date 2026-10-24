// `CustomersRepository` поверх единственного Dio-клиента (core/network/dio_client.dart). Ошибки → Failure только
// через ErrorMapper (06 §6.8); ответ не по контракту (`DtoFormatException`) → `UnknownFailure`.
// Поиск клиентов — `Cache-Control: no-store` (ПДн): ответы не кэшируются и не логируются.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/cancel_signal_dio.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/features/customers/data/dto/customer_dtos.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/new_customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';

/// Пути API клиентов (08 §4.5.4, §4.11).
abstract final class CustomersApiPaths {
  static const String search = '/search/customers';
  static const String customers = '/customers';
  static String customer(String id) => '/customers/${Uri.encodeComponent(id)}';
}

final class DioCustomersRepository implements CustomersRepository {
  DioCustomersRepository(this._dio);

  final Dio _dio;

  @override
  Future<Result<PageResult<Customer>>> search(CustomerSearchQuery query, {CancelSignal? cancel}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.get<Object?>(
          CustomersApiPaths.search,
          queryParameters: <String, Object?>{
            'q': query.q,
            'limit': query.limit,
            if (query.favoriteOnly) 'favorite': true,
            if (query.withReceivable) 'include': 'receivable',
            'cursor': ?query.cursor,
          },
          options: apiOptions(),
          cancelToken: dioCancelToken(cancel),
        );
        return PageDto.fromJson(jsonObject(r.data), CustomerDto.fromJson);
      });

  @override
  Future<Result<Customer>> get(String customerId) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(CustomersApiPaths.customer(customerId), options: apiOptions());
    return CustomerDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<NewCustomerOutcome>> create(NewCustomerRequest request, {required String idempotencyKey}) async {
    final Result<NewCustomerOutcome> result = await ErrorMapper.guard<NewCustomerOutcome>(() async {
      final Response<Object?> r = await _dio.post<Object?>(
        CustomersApiPaths.customers,
        data: NewCustomerRequestDto.toJson(request),
        options: apiOptions(idempotencyKey: idempotencyKey),
      );
      final JsonMap body = jsonObject(r.data);
      return NewCustomerCreated(CustomerDto.fromJson(body), warningCodes: _warningCodes(body['warnings']));
    });
    if (result case FailureResult<NewCustomerOutcome>(
      failure: ConflictFailure(kind: ConflictKind.customerDuplicateSuspected, :final Map<String, Object?> details),
    )) {
      return Success<NewCustomerOutcome>(NewCustomerDuplicates(DuplicateCandidateDto.fromProblem(details)));
    }
    return result;
  }

  /// Коды `warnings[]` (`[{code, message}]`, 08 §2.4) — терпимо: элементы без строкового `code` пропускаются.
  static List<String> _warningCodes(Object? raw) => <String>[
    if (raw is List)
      for (final Object? w in raw)
        if (w is Map && w['code'] is String) w['code']! as String,
  ];
}
