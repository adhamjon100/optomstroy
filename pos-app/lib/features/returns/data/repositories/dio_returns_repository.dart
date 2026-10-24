// `ReturnsRepository` поверх единственного Dio-клиента. Ошибки → Failure только через ErrorMapper (06 §6.8):
// `ORDER_STATE_INVALID` (`resource: return_request`, `reason: invalid_transition|already_in_onec|order_not_shipped`) —
// `ConflictFailure`, `RETURN_QTY_EXCEEDED` — `ServerFailure` (UiErrorMapper даёт ключи 02 §7).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/transaction_dtos.dart' show isoUtc;
import 'package:optomstroy/features/returns/data/dto/return_dtos.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';
import 'package:optomstroy/features/returns/domain/repositories/returns_repository.dart';

/// Пути API заявок на возврат (08 §4.15).
abstract final class ReturnsApiPaths {
  static const String returns = '/returns';
  static String returnRequest(String id) => '/returns/${Uri.encodeComponent(id)}';
  static String submit(String id) => '${returnRequest(id)}/submit';
  static String accept(String id) => '${returnRequest(id)}/accept';
  static String reject(String id) => '${returnRequest(id)}/reject';
}

final class DioReturnsRepository implements ReturnsRepository {
  DioReturnsRepository(this._dio);

  final Dio _dio;

  static Options _opts({String? idempotencyKey, String? stepUpToken, RetryProfile retry = RetryProfile.interactive}) {
    final Options o = apiOptions(idempotencyKey: idempotencyKey, retry: retry);
    if (stepUpToken != null) o.headers![ApiHeaders.stepUpToken] = stepUpToken; // check-secrets: allow (имя заголовка)
    return o;
  }

  @override
  Future<Result<PageResult<ReturnRequest>>> list(ReturnsQuery query) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      ReturnsApiPaths.returns,
      queryParameters: <String, Object?>{
        if (query.status != null) 'status': query.status!.value,
        'orderId': ?query.orderId,
        'customerId': ?query.customerId,
        if (query.from != null) 'from': isoUtc(query.from!),
        if (query.to != null) 'to': isoUtc(query.to!),
        'limit': ?query.limit,
        'cursor': ?query.cursor,
      },
      options: _opts(),
    );
    return ReturnsPageDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<ReturnRequest>> get(String returnId) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(ReturnsApiPaths.returnRequest(returnId), options: _opts());
    return ReturnRequestDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<ReturnRequest>> create(ReturnDraftInput input, {required String idempotencyKey}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.post<Object?>(
          ReturnsApiPaths.returns,
          data: ReturnCreateRequestDto.toJson(input),
          options: _opts(idempotencyKey: idempotencyKey),
        );
        return ReturnRequestDto.fromJson(jsonObject(r.data));
      });

  @override
  Future<Result<ReturnRequest>> update(String returnId, ReturnDraftPatch patch, {String? idempotencyKey}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.patch<Object?>(
          ReturnsApiPaths.returnRequest(returnId),
          data: ReturnUpdateRequestDto.toJson(patch),
          options: _opts(idempotencyKey: idempotencyKey),
        );
        return ReturnRequestDto.fromJson(jsonObject(r.data));
      });

  @override
  Future<Result<void>> delete(String returnId, {required int rowVersion}) => ErrorMapper.guard<void>(() async {
    await _dio.delete<Object?>(
      ReturnsApiPaths.returnRequest(returnId),
      queryParameters: <String, Object?>{'rowVersion': rowVersion},
      options: _opts(),
    );
  });

  @override
  Future<Result<ReturnRequest>> submit(
    String returnId, {
    required int rowVersion,
    required String idempotencyKey,
    String? comment,
    String? stepUpToken,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      ReturnsApiPaths.submit(returnId),
      data: ReturnSubmitRequestDto.toJson(rowVersion: rowVersion, comment: comment),
      options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return ReturnRequestDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<ReturnRequest>> accept(
    String returnId, {
    required int rowVersion,
    required String idempotencyKey,
    String? comment,
    String? stepUpToken,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      ReturnsApiPaths.accept(returnId),
      data: ReturnAcceptRequestDto.toJson(rowVersion: rowVersion, comment: comment),
      options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return ReturnRequestDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<ReturnRequest>> reject(
    String returnId, {
    required String reason,
    required int rowVersion,
    required String idempotencyKey,
    String? stepUpToken,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      ReturnsApiPaths.reject(returnId),
      data: ReturnRejectRequestDto.toJson(reason: reason, rowVersion: rowVersion),
      options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return ReturnRequestDto.fromJson(jsonObject(r.data));
  });
}
