// DioException + problem+json → Failure (06 §6.8). Единственное место такого
// преобразования; используется только слоем data (L-1, L-6, L-9).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/models/problem.dart';

abstract final class ErrorMapper {
  /// Преобразовать ошибку запроса в [Failure].
  static Failure fromDio(DioException error) {
    final requestId = _requestId(error);
    switch (error.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
        return NetworkFailure(NetworkFailureKind.offline, requestId: requestId);
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        // Запрос мог быть обработан сервером: для записи результат неизвестен.
        final method = error.requestOptions.method.toUpperCase();
        return NetworkFailure(
          NetworkFailureKind.timeout,
          outcomeUnknown: method != 'GET' && method != 'HEAD',
          requestId: requestId,
        );
      case DioExceptionType.badResponse:
        return fromResponse(error.response!, requestId: requestId);
      case DioExceptionType.transformTimeout:
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return UnknownFailure(cause: error.type, requestId: requestId);
    }
  }

  /// Ответ с HTTP-статусом ошибки.
  static Failure fromResponse(Response<Object?> response, {String? requestId}) {
    final status = response.statusCode ?? 0;
    final problem = Problem.tryParse(response.data);
    final rid = problem?.requestId ?? requestId;
    final retryAfter = retryAfterOf(response);
    if (problem == null) {
      if (status == 502 || status == 503 || status == 504) {
        return NetworkFailure(NetworkFailureKind.serverUnavailable, requestId: rid);
      }
      if (status == 426) return AppUpdateRequiredFailure(requestId: rid);
      return ServerFailure(code: ProblemCode.internal.value, status: status, retryAfter: retryAfter, requestId: rid);
    }
    final fieldErrors = [
      for (final e in problem.errors ?? const <ProblemFieldError>[])
        FieldError(field: e.field, rule: e.rule, message: e.message, params: e.params ?? const {}),
    ];
    final code = problem.problemCode;
    final auth = code == null ? null : _authReasons[code];
    if (auth != null) {
      return AuthFailure(
        auth,
        attemptsLeft: problem.attemptsLeft,
        retryAfter: retryAfter,
        stepUpOperation: problem.stepUp?.operation,
        lockedUntil: problem.until?.toUtc(),
        unlockReason: auth == AuthReason.unlockRequired ? problem.reason : null,
        requestId: rid,
      );
    }
    final conflict = code == null ? null : _conflictKinds[code];
    if (conflict != null) {
      return ConflictFailure(
        conflict,
        currentStatus: problem.currentStatus,
        reason: problem.reason,
        retryAfter: retryAfter,
        details: _details(response.data),
        requestId: rid,
      );
    }
    return switch (code) {
      ProblemCode.validationFailed => ValidationFailure(errors: fieldErrors, requestId: rid),
      ProblemCode.forbidden => PermissionFailure(serverReason: problem.reason, requestId: rid),
      ProblemCode.onecUnavailable => OnecUnavailableFailure(
        retryAfter: retryAfter,
        reason: problem.reason,
        requestId: rid,
      ),
      ProblemCode.appUpdateRequired => AppUpdateRequiredFailure(minVersion: problem.minVersion, requestId: rid),
      _ => ServerFailure(
        code: problem.code,
        status: status,
        errors: fieldErrors,
        retryAfter: retryAfter,
        reason: problem.reason,
        details: _details(response.data),
        requestId: rid,
      ),
    };
  }

  /// Выполнить вызов API и вернуть [Result]; ошибки разбора ответа → [UnknownFailure].
  static Future<Result<T>> guard<T>(Future<T> Function() call) async {
    try {
      return Success<T>(await call());
    } on DioException catch (e) {
      return FailureResult<T>(fromDio(e));
    } on Object catch (e) {
      return FailureResult<T>(UnknownFailure(cause: e.runtimeType));
    }
  }

  static const Map<ProblemCode, AuthReason> _authReasons = {
    ProblemCode.unauthenticated: AuthReason.unauthenticated,
    ProblemCode.tokenStale: AuthReason.tokenStale,
    ProblemCode.sessionRevoked: AuthReason.sessionRevoked,
    ProblemCode.deviceMismatch: AuthReason.deviceMismatch,
    ProblemCode.stepUpRequired: AuthReason.stepUpRequired,
    ProblemCode.otpInvalid: AuthReason.otpInvalid,
    ProblemCode.otpExpired: AuthReason.otpExpired,
    ProblemCode.otpLocked: AuthReason.otpLocked,
    ProblemCode.otpRateLimited: AuthReason.otpRateLimited,
    ProblemCode.registrationTokenInvalid: AuthReason.registrationTokenInvalid,
    ProblemCode.pinInvalid: AuthReason.pinInvalid,
    ProblemCode.pinLocked: AuthReason.pinLocked,
    ProblemCode.unlockRequired: AuthReason.unlockRequired,
  };

  static const Map<ProblemCode, ConflictKind> _conflictKinds = {
    ProblemCode.versionConflict: ConflictKind.versionConflict,
    ProblemCode.priceChanged: ConflictKind.priceChanged,
    ProblemCode.stockInsufficient: ConflictKind.stockInsufficient,
    ProblemCode.variantUnavailable: ConflictKind.variantUnavailable,
    ProblemCode.qtyNotMultiple: ConflictKind.qtyNotMultiple,
    ProblemCode.qtyBelowMin: ConflictKind.qtyBelowMin,
    ProblemCode.orderStateInvalid: ConflictKind.orderStateInvalid,
    ProblemCode.paymentStateInvalid: ConflictKind.paymentStateInvalid,
    ProblemCode.idempotencyKeyReused: ConflictKind.idempotencyKeyReused,
    ProblemCode.idempotencyInProgress: ConflictKind.idempotencyInProgress,
    ProblemCode.customerLinkConflict: ConflictKind.customerLinkConflict,
    ProblemCode.customerDuplicateSuspected: ConflictKind.customerDuplicateSuspected,
    ProblemCode.syncAlreadyRunning: ConflictKind.syncAlreadyRunning,
    ProblemCode.phoneAlreadyRegistered: ConflictKind.phoneAlreadyRegistered,
  };

  static Map<String, Object?> _details(Object? data) =>
      data is Map<String, dynamic> ? Map.unmodifiable(data) : const {};

  static String? _requestId(DioException error) {
    final fromResponse = error.response?.headers.value(ApiHeaders.requestId);
    if (fromResponse != null) return fromResponse;
    final sent = error.requestOptions.headers[ApiHeaders.requestId];
    return sent is String ? sent : null;
  }
}

/// `Retry-After` из ответа ошибки (заголовок в секундах или `retryAfter` тела).
Duration? retryAfterOf(Response<Object?>? response) {
  if (response == null) return null;
  final header = int.tryParse(response.headers.value(ApiHeaders.retryAfter) ?? '');
  final body = response.data;
  final seconds = header ?? (body is Map && body['retryAfter'] is int ? body['retryAfter'] as int : null);
  return seconds == null ? null : Duration(seconds: seconds);
}
