// Вызовы API сессии (08 §4.1.4, §4.1.5, §4.1.7, §4.1.8; контракт — contracts/openapi/pos-api.v1.yaml):
// `POST /auth/unlock` (публичный, без Bearer), `POST /auth/step-up`, `POST /auth/logout`, `POST /auth/logout-all`.
// DTO разбираются вручную (ADR-085); PIN, OTP и токены не логируются и в исключения не попадают.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/interceptors/session_hooks.dart';
import 'package:optomstroy/core/network/models/auth_token_pair.dart';
import 'package:optomstroy/core/network/models/problem.dart';
import 'package:optomstroy/core/session/step_up_token_cache.dart';

/// Общие исходы ошибок сессионных вызовов.
sealed class SessionCallError {
  const SessionCallError();
}

/// `401 PIN_INVALID {attemptsLeft}` — остаток только из ответа сервера (клиент попытки не считает).
final class PinInvalidError extends SessionCallError {
  const PinInvalidError(this.attemptsLeft);

  final int? attemptsLeft;
}

/// `423 PIN_LOCKED` — 5 неверных подряд, дальше только OTP (BIO-020).
final class PinLockedError extends SessionCallError {
  const PinLockedError();
}

/// `403 FORBIDDEN {reason: pin_not_set}`.
final class PinNotSetError extends SessionCallError {
  const PinNotSetError();
}

/// `422 OTP_INVALID {attemptsLeft}`.
final class OtpInvalidError extends SessionCallError {
  const OtpInvalidError(this.attemptsLeft);

  final int? attemptsLeft;
}

/// `422 OTP_EXPIRED`.
final class OtpExpiredError extends SessionCallError {
  const OtpExpiredError();
}

/// `423 OTP_LOCKED` / `429 OTP_RATE_LIMITED` / `429 RATE_LIMITED`.
final class ThrottledError extends SessionCallError {
  const ThrottledError(this.code, this.retryAfter);

  final String code;
  final Duration? retryAfter;
}

/// `401 SESSION_REVOKED` / `409 DEVICE_MISMATCH` (`/auth/unlock` — публичный: интерсептор их не обрабатывает).
final class SessionRevokedError extends SessionCallError {
  const SessionRevokedError(this.signal);

  final SessionEndSignal signal;
}

/// `403 STEP_UP_REQUIRED` остался после StepUpDialog — пользователь отменил подтверждение.
final class StepUpDeclinedError extends SessionCallError {
  const StepUpDeclinedError();
}

/// `426 APP_UPDATE_REQUIRED` — SCR-90 «Требуется обновление» показывает AppVersionInterceptor.
final class UpdateRequiredError extends SessionCallError {
  const UpdateRequiredError();
}

/// Нет сети / таймаут (без автоповтора: PIN не хранится, повтор — вводом заново).
final class NetworkCallError extends SessionCallError {
  const NetworkCallError({required this.timeout});

  final bool timeout;
}

/// Прочее (`VALIDATION_FAILED`, `INTERNAL`, неожиданный ответ).
final class UnexpectedCallError extends SessionCallError {
  const UnexpectedCallError(this.code, {this.requestId});

  final String code;
  final String? requestId;
}

/// Итог `POST /auth/unlock`.
sealed class UnlockResponse {
  const UnlockResponse();
}

final class UnlockOk extends UnlockResponse {
  const UnlockOk(this.tokens);

  /// Новая пара; при `method=biometric` `refreshToken` — новый `biometric_refresh`.
  final AuthTokenPair tokens;
}

final class UnlockFailed extends UnlockResponse {
  const UnlockFailed(this.error);

  final SessionCallError error;
}

/// Итог `POST /auth/step-up`.
sealed class StepUpResponse {
  const StepUpResponse();
}

/// `200` — токен выдан.
final class StepUpGranted extends StepUpResponse {
  const StepUpGranted(this.grant);

  final StepUpGrant grant;
}

/// `202` — код отправлен (`method=otp`, шаг 1).
final class StepUpOtpSent extends StepUpResponse {
  const StepUpOtpSent({required this.challengeId, required this.resendAfter, required this.otpTtl});

  final String challengeId;
  final Duration resendAfter;
  final Duration otpTtl;

  @override
  String toString() => 'StepUpOtpSent(resendAfter: $resendAfter)';
}

final class StepUpFailed extends StepUpResponse {
  const StepUpFailed(this.error);

  final SessionCallError error;
}

final class SessionApi {
  SessionApi(this._dio);

  static const String unlockPath = '/auth/unlock';
  static const String stepUpPath = '/auth/step-up';
  static const String logoutPath = '/auth/logout';
  static const String logoutAllPath = '/auth/logout-all';

  final Dio _dio;

  /// `POST /auth/unlock {method: pin, refreshToken, pin, biometricInvalidated?}` (без Bearer).
  Future<UnlockResponse> unlockWithPin({
    required String refreshToken,
    required String pin,
    bool biometricInvalidated = false,
  }) => _unlock(<String, Object?>{
    'method': 'pin',
    'refreshToken': refreshToken,
    'pin': pin,
    if (biometricInvalidated) 'biometricInvalidated': true,
  });

  /// `POST /auth/unlock {method: biometric, refreshToken: <расшифрованный biometric_refresh>}` (Android/iOS).
  Future<UnlockResponse> unlockWithBiometric({required String biometricRefresh}) =>
      _unlock(<String, Object?>{'method': 'biometric', 'refreshToken': biometricRefresh});

  Future<UnlockResponse> _unlock(Map<String, Object?> body) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        unlockPath,
        data: body,
        options: apiOptions(skipAuth: true, retry: RetryProfile.none),
      );
      return UnlockOk(AuthTokenPair.fromJson(response.data!));
    } on DioException catch (e) {
      return UnlockFailed(mapError(e));
    }
  }

  /// `POST /auth/step-up {method: pin, pin, operation}`.
  Future<StepUpResponse> stepUpWithPin({required String operation, required String pin}) =>
      _stepUp(operation, <String, Object?>{'method': 'pin', 'pin': pin, 'operation': operation});

  /// `POST /auth/step-up {method: otp, operation}` → `202` (код отправлен).
  Future<StepUpResponse> requestStepUpOtp({required String operation}) =>
      _stepUp(operation, <String, Object?>{'method': 'otp', 'operation': operation});

  /// `POST /auth/step-up {method: otp, challengeId, code, operation}` → `200`.
  Future<StepUpResponse> stepUpWithOtp({
    required String operation,
    required String challengeId,
    required String code,
  }) => _stepUp(operation, <String, Object?>{
    'method': 'otp',
    'challengeId': challengeId,
    'code': code,
    'operation': operation,
  });

  Future<StepUpResponse> _stepUp(String operation, Map<String, Object?> body) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        stepUpPath,
        data: body,
        options: apiOptions(retry: RetryProfile.none),
      );
      final json = response.data!;
      if (response.statusCode == 202) {
        return StepUpOtpSent(
          challengeId: json['challengeId'] as String,
          resendAfter: Duration(
            seconds:
                (json['resendAfterSec'] as num?)?.toInt() ?? 60, // money-double: allow — JSON-число → int (не деньги)
          ),
          otpTtl: Duration(
            seconds: (json['otpTtlSec'] as num?)?.toInt() ?? 300, // money-double: allow — JSON-число → int (не деньги)
          ),
        );
      }
      return StepUpGranted(StepUpGrant.fromJson(json, operation: operation));
    } on DioException catch (e) {
      return StepUpFailed(mapError(e));
    }
  }

  /// `POST /auth/logout` (Bearer). [bypassLock] — с экрана блокировки («Сменить аккаунт»).
  Future<void> logout({bool bypassLock = false}) async {
    final options = apiOptions(retry: RetryProfile.none);
    options.extra![SessionRequestExtra.bypassLock] = bypassLock;
    await _dio.post<Object?>(logoutPath, options: options);
  }

  /// `POST /auth/logout-all` (Bearer + step-up `session.logout_all`; StepUpDialog — через AuthInterceptor).
  Future<void> logoutAll() async {
    final options = apiOptions(retry: RetryProfile.none);
    options.extra![SessionRequestExtra.stepUpOperation] = 'session.logout_all';
    await _dio.post<Object?>(logoutAllPath, options: options);
  }

  /// Ошибка Dio → [SessionCallError].
  static SessionCallError mapError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError || DioExceptionType.connectionTimeout:
        return const NetworkCallError(timeout: false);
      case DioExceptionType.sendTimeout || DioExceptionType.receiveTimeout:
        return const NetworkCallError(timeout: true);
      case DioExceptionType.badResponse:
        break;
      case DioExceptionType.transformTimeout ||
          DioExceptionType.cancel ||
          DioExceptionType.badCertificate ||
          DioExceptionType.unknown:
        return UnexpectedCallError(e.type.name);
    }
    final response = e.response!;
    final status = response.statusCode ?? 0;
    final problem = Problem.tryParse(response.data);
    final code = problem?.code ?? (status == 426 ? 'APP_UPDATE_REQUIRED' : 'HTTP_$status');
    final retryAfter = retryAfterOf(response);
    return switch (code) {
      'PIN_INVALID' => PinInvalidError(problem?.attemptsLeft),
      'PIN_LOCKED' => const PinLockedError(),
      'FORBIDDEN' when problem?.reason == 'pin_not_set' => const PinNotSetError(),
      'OTP_INVALID' => OtpInvalidError(problem?.attemptsLeft),
      'OTP_EXPIRED' => const OtpExpiredError(),
      'OTP_LOCKED' || 'OTP_RATE_LIMITED' || 'RATE_LIMITED' => ThrottledError(code, retryAfter),
      'SESSION_REVOKED' ||
      'DEVICE_MISMATCH' => SessionRevokedError(SessionEndSignal(code: code, reason: problem?.reason)),
      'APP_UPDATE_REQUIRED' => const UpdateRequiredError(),
      'STEP_UP_REQUIRED' => const StepUpDeclinedError(),
      _ when status == 502 || status == 503 || status == 504 => const NetworkCallError(timeout: false),
      _ => UnexpectedCallError(code, requestId: problem?.requestId),
    };
  }
}
