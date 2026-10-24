// `POST /auth/refresh` (08 §4.1.3): ротация по непрозрачному refresh-токену в теле.
// Вызывается отдельным Dio без AuthInterceptor и RetryInterceptor (иначе — рекурсия
// и повтор refresh вне окна грации 30 с → reuse-detection на сервере).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/models/auth_token_pair.dart';
import 'package:optomstroy/core/network/models/problem.dart';

/// Итог попытки refresh.
sealed class RefreshResult {
  const RefreshResult();
}

final class RefreshSucceeded extends RefreshResult {
  const RefreshSucceeded(this.tokens);

  final AuthTokenPair tokens;
}

/// Сессия завершена сервером (`SESSION_REVOKED`, отказ в refresh) — нужен новый вход.
/// [code] и [reason] — `Problem.code`/`Problem.reason` ответа (D SS-03: причина для SCR-90); `null` — тела нет.
final class RefreshSessionEnded extends RefreshResult {
  const RefreshSessionEnded({this.code, this.reason});

  final String? code;
  final String? reason;
}

/// `UNLOCK_REQUIRED` — сессия жива, нужна разблокировка PIN/биометрией (SCR-08, D-48).
final class RefreshUnlockRequired extends RefreshResult {
  const RefreshUnlockRequired([this.reason = UnlockRequiredReason.unknown]);

  /// `Problem.reason` (OpenAPI 1.1.0); неизвестное — [UnlockRequiredReason.unknown], поведение то же (SCR-08).
  final UnlockRequiredReason reason;
}

/// Сеть/сервер недоступны — токены не трогаем, ошибку возвращаем вызывающему.
final class RefreshTransientFailure extends RefreshResult {
  const RefreshTransientFailure(this.error);

  final DioException error;
}

abstract interface class TokenRefresher {
  Future<RefreshResult> refresh(String refreshToken);
}

final class DioTokenRefresher implements TokenRefresher {
  DioTokenRefresher(this._dio);

  static const String path = '/auth/refresh';

  final Dio _dio;

  @override
  Future<RefreshResult> refresh(String refreshToken) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        path,
        data: {'refreshToken': refreshToken},
        options: apiOptions(skipAuth: true, retry: RetryProfile.none),
      );
      return RefreshSucceeded(AuthTokenPair.fromJson(response.data!));
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (e.type != DioExceptionType.badResponse || status == null || status >= 500 || status == 429) {
        return RefreshTransientFailure(e);
      }
      final Object? data = e.response?.data;
      final String? code = Problem.codeOf(data);
      final String? reason = data is Map && data['reason'] is String ? data['reason'] as String : null;
      if (code == 'UNLOCK_REQUIRED') return RefreshUnlockRequired(UnlockRequiredReason.parse(reason));
      return RefreshSessionEnded(code: code, reason: reason);
    }
  }
}
