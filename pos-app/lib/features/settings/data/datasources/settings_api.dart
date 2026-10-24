// HTTP-вызовы SCR-42 (08 §4.1.6, §4.3.4–§4.3.7; контракт — contracts/openapi/pos-api.v1.yaml).
// Заголовки X-Device-Id / X-App-Version / X-Platform / X-Request-Id и Bearer добавляют интерсепторы core.
// Операции со step-up помечаются `SessionRequestExtra.stepUpOperation`: AuthInterceptor подставит
// действующий `X-Step-Up-Token` из кэша области или покажет StepUpDialog на `403 STEP_UP_REQUIRED`.
// PIN и токены не логируются и в исключения не попадают.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/interceptors/session_hooks.dart';
import 'package:uuid/uuid.dart';

/// Операции step-up (08 §2.12, `x-step-up-operation`).
abstract final class SettingsStepUpOperations {
  static const String revokeOtherSession = 'session.revoke.other';
  static const String pinSet = 'profile.pin.set';
  static const String biometricsToggle = 'profile.biometrics.toggle';
}

final class SettingsApi {
  SettingsApi(this._dio, {String Function()? newKey}) : _newKey = newKey ?? const Uuid().v4;

  final Dio _dio;
  final String Function() _newKey;

  static Options _stepUp(Options options, String operation) {
    options.extra![SessionRequestExtra.stepUpOperation] = operation;
    return options;
  }

  /// `GET /auth/sessions` → `AuthSessionList.items`.
  Future<List<Map<String, Object?>>> sessions() async {
    final Response<Map<String, Object?>> res = await _dio.get<Map<String, Object?>>(
      '/auth/sessions',
      options: apiOptions(),
    );
    final Object? items = res.data?['items'];
    if (items is! List) throw const FormatException('auth/sessions: нет items');
    return <Map<String, Object?>>[for (final Object? i in items) Map<String, Object?>.from(i! as Map)];
  }

  /// `DELETE /auth/sessions/{id}` (другая сессия — step-up `session.revoke.other`; повтор → 204).
  Future<void> revokeSession(String sessionId) async {
    await _dio.delete<Object?>(
      '/auth/sessions/${Uri.encodeComponent(sessionId)}',
      options: _stepUp(apiOptions(retry: RetryProfile.none), SettingsStepUpOperations.revokeOtherSession),
    );
  }

  /// `PATCH /auth/sessions/{id} {deviceName}` → `Session`.
  Future<Map<String, Object?>> renameSession(String sessionId, String deviceName) async {
    final Response<Map<String, Object?>> res = await _dio.patch<Map<String, Object?>>(
      '/auth/sessions/${Uri.encodeComponent(sessionId)}',
      data: <String, Object?>{'deviceName': deviceName},
      options: apiOptions(),
    );
    return res.data ?? const <String, Object?>{};
  }

  /// `GET /me`.
  Future<Map<String, Object?>> me() async {
    final Response<Map<String, Object?>> res = await _dio.get<Map<String, Object?>>('/me', options: apiOptions());
    return res.data ?? const <String, Object?>{};
  }

  /// `GET /me/consents` → `MeConsentList`.
  Future<Map<String, Object?>> consents() async {
    final Response<Map<String, Object?>> res = await _dio.get<Map<String, Object?>>(
      '/me/consents',
      options: apiOptions(),
    );
    return res.data ?? const <String, Object?>{};
  }

  /// `POST /me/pin {newPin}` (step-up `profile.pin.set`; `Idempotency-Key` — повтор сетью).
  Future<void> setPin(String newPin) async {
    await _dio.post<Object?>(
      '/me/pin',
      data: <String, Object?>{'newPin': newPin},
      options: _stepUp(apiOptions(idempotencyKey: _newKey()), SettingsStepUpOperations.pinSet),
    );
  }

  /// `DELETE /me/pin` (только `customer` при биометрии с криптопривязкой; step-up `profile.pin.set`).
  Future<void> deletePin() async {
    await _dio.delete<Object?>(
      '/me/pin',
      options: _stepUp(apiOptions(retry: RetryProfile.none), SettingsStepUpOperations.pinSet),
    );
  }

  /// `POST /me/biometrics` (step-up `profile.biometrics.toggle`; без автоповтора — повтор выдаёт новый токен).
  Future<Map<String, Object?>> biometrics(Map<String, Object?> body) async {
    final Response<Map<String, Object?>> res = await _dio.post<Map<String, Object?>>(
      '/me/biometrics',
      data: body,
      options: _stepUp(apiOptions(retry: RetryProfile.none), SettingsStepUpOperations.biometricsToggle),
    );
    return res.data ?? const <String, Object?>{};
  }

  /// `PUT /me/settings` (полная замена с `rowVersion`) → `Settings`.
  Future<Map<String, Object?>> putSettings(
    Map<String, Object?> body, {
    String? idempotencyKey,
    RetryProfile retry = RetryProfile.interactive,
  }) async {
    final Response<Map<String, Object?>> res = await _dio.put<Map<String, Object?>>(
      '/me/settings',
      data: body,
      options: apiOptions(idempotencyKey: idempotencyKey ?? _newKey(), retry: retry),
    );
    return res.data ?? const <String, Object?>{};
  }
}
