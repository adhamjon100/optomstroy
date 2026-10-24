// HTTP-вызовы авторизации (08 §4.1). Все маршруты публичные (`security: []`): без Bearer,
// с `X-Device-Id`/`X-App-Version`/`X-Platform` (ClientMetaInterceptor). Автоповтора нет:
// запрос кода и проверка не идемпотентны (повтор — только явной кнопкой, 02 §0.2).
// Тела запросов/ответов не логируются (LoggingInterceptor пишет только метод/путь/код).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/features/auth/data/dto/auth_dtos.dart';

final class AuthRemoteDataSource {
  const AuthRemoteDataSource(this._dio);

  static const String otpRequestPath = '/auth/otp/request';
  static const String otpVerifyPath = '/auth/otp/verify';
  static const String unlockPath = '/auth/unlock';

  /// `/auth/otp/challenges/{challengeId}`.
  static String challengePath(String challengeId) => '/auth/otp/challenges/${Uri.encodeComponent(challengeId)}';

  final Dio _dio;

  Options get _public => apiOptions(skipAuth: true, retry: RetryProfile.none);

  Future<OtpRequestResponseDto> requestOtp(OtpRequestRequestDto body) async {
    final Response<Map<String, dynamic>> r = await _dio.post<Map<String, dynamic>>(
      otpRequestPath,
      data: body.toJson(),
      options: _public,
    );
    return OtpRequestResponseDto.fromJson(_body(r));
  }

  Future<OtpVerifyResponseDto> verifyOtp(OtpVerifyRequestDto body) async {
    final Response<Map<String, dynamic>> r = await _dio.post<Map<String, dynamic>>(
      otpVerifyPath,
      data: body.toJson(),
      options: _public,
    );
    return OtpVerifyResponseDto.fromJson(_body(r));
  }

  /// Статус доставки: GET без автоповтора (опрос раз в 3 с ведёт экран).
  Future<OtpChallengeStatusDto> challengeStatus(String challengeId) async {
    final Response<Map<String, dynamic>> r = await _dio.get<Map<String, dynamic>>(
      challengePath(challengeId),
      options: _public,
    );
    return OtpChallengeStatusDto.fromJson(_body(r));
  }

  Future<AuthUnlockResponseDto> unlock(AuthUnlockRequestDto body) async {
    final Response<Map<String, dynamic>> r = await _dio.post<Map<String, dynamic>>(
      unlockPath,
      data: body.toJson(),
      options: _public,
    );
    return AuthUnlockResponseDto.fromJson(_body(r));
  }

  static Map<String, dynamic> _body(Response<Map<String, dynamic>> r) {
    final Map<String, dynamic>? data = r.data;
    if (data == null) {
      throw const DtoFormatException('body');
    }
    return data;
  }
}
