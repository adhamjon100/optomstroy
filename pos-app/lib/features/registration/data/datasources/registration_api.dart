// HTTP-вызовы регистрации и защиты входа (08 §4.2.1–§4.2.4, §4.3.5–§4.3.7, §4.1.4, §4.1.7).
// Заголовки X-Device-Id / X-App-Version / X-Platform / X-Request-Id добавляют интерсепторы core.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:uuid/uuid.dart';

final class RegistrationApi {
  RegistrationApi(this._dio, {String Function()? newKey}) : _newKey = newKey ?? const Uuid().v4;

  final Dio _dio;
  final String Function() _newKey;

  /// `POST /registration/complete` — публичный (без Bearer), `Idempotency-Key` обязателен.
  Future<Map<String, Object?>> complete(Map<String, Object?> body, {required String idempotencyKey}) async {
    final res = await _dio.post<Map<String, Object?>>(
      '/registration/complete',
      data: body,
      options: apiOptions(skipAuth: true, idempotencyKey: idempotencyKey),
    );
    return res.data ?? const <String, Object?>{};
  }

  Future<Map<String, Object?>> customerMatch() async {
    final res = await _dio.get<Map<String, Object?>>('/registration/customer-match', options: apiOptions());
    return res.data ?? const <String, Object?>{};
  }

  /// `confirm` / `reject` (идемпотентны по состоянию привязки; ключ — для повтора сетью).
  Future<Map<String, Object?>> resolveCustomerMatch(String linkId, {required bool confirm}) async {
    final res = await _dio.post<Map<String, Object?>>(
      confirm ? '/registration/customer-match/confirm' : '/registration/customer-match/reject',
      data: <String, Object?>{'linkId': linkId},
      options: apiOptions(idempotencyKey: _newKey()),
    );
    return res.data ?? const <String, Object?>{};
  }

  Future<Map<String, Object?>> biometrics(Map<String, Object?> body, {String? stepUpToken}) async {
    final res = await _dio.post<Map<String, Object?>>(
      '/me/biometrics',
      data: body,
      options: _withStepUp(apiOptions(retry: RetryProfile.none), stepUpToken),
    );
    return res.data ?? const <String, Object?>{};
  }

  /// `POST /auth/step-up` без автоповтора (PIN — попытки считает сервер).
  Future<Map<String, Object?>> stepUp(Map<String, Object?> body) async {
    final res = await _dio.post<Map<String, Object?>>(
      '/auth/step-up',
      data: body,
      options: apiOptions(retry: RetryProfile.none),
    );
    return res.data ?? const <String, Object?>{};
  }

  Future<void> setPin(String newPin, {String? stepUpToken}) async {
    await _dio.post<Object?>(
      '/me/pin',
      data: <String, Object?>{'newPin': newPin},
      options: _withStepUp(apiOptions(idempotencyKey: _newKey()), stepUpToken),
    );
  }

  Future<void> grantConsent({required String kind, required String version}) async {
    await _dio.post<Object?>(
      '/me/consents',
      data: <String, Object?>{'kind': kind, 'version': version, 'granted': true},
      options: apiOptions(),
    );
  }

  Future<Map<String, Object?>> me() async {
    final res = await _dio.get<Map<String, Object?>>('/me', options: apiOptions());
    return res.data ?? const <String, Object?>{};
  }

  Future<void> logout() async {
    await _dio.post<Object?>('/auth/logout', data: const <String, Object?>{'reason': 'user'}, options: apiOptions());
  }

  static Options _withStepUp(Options options, String? token) {
    if (token == null) return options;
    return options.copyWith(headers: <String, Object?>{...?options.headers, ApiHeaders.stepUpToken: token});
  }
}
