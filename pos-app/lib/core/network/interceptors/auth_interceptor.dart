// Bearer-аутентификация, обновление access и сессионные ответы сервера (06 §6.7; 08 §2.2, §2.10, §2.12;
// 09 §8.3, §8.8; RM-D-009):
// - access — из памяти ([TokenStore]); refresh — из secure storage;
// - заблаговременный refresh при `exp − now < 60 с` (09 §8.3) и на холодном старте (access нет);
// - 401 `UNAUTHENTICATED` / `TOKEN_STALE` → single-flight `POST /auth/refresh`
//   (параллельные 401 ждут один refresh), затем один повтор исходного запроса;
// - 401 `SESSION_REVOKED`, 409 `DEVICE_MISMATCH` → очистка токенов (кроме deviceId), событие выхода
//   с причиной (`Problem.reason`) → SCR-01 / SCR-90 «Сессия завершена»;
// - 401 `UNLOCK_REQUIRED` (запрос или refresh) → SCR-08 overlay, ожидание `POST /auth/unlock`, повтор;
// - 403 `STEP_UP_REQUIRED` → `stepUpToken` из кэша области (15 мин) или StepUpDialog, повтор
//   с `X-Step-Up-Token` и тем же `Idempotency-Key`;
// - 401 `PIN_INVALID` / 423 `PIN_LOCKED` → refresh не вызывается (ядро §18.2 п.5);
// - 426 `APP_UPDATE_REQUIRED` здесь не обрабатывается (AppVersionInterceptor → SCR-90 «Требуется обновление»);
// - пока сессия заблокирована, новые запросы ждут разблокировки (данные под overlay не читаются).
// Сессионные действия (ожидание разблокировки, StepUpDialog) — через [AuthSessionHooks] core/session;
// без подключённых хуков поведение — как на этапе C (ошибка уходит вызывающему).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/auth/token_refresher.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/interceptors/access_token_claims.dart';
import 'package:optomstroy/core/network/interceptors/session_hooks.dart';
import 'package:optomstroy/core/network/models/problem.dart';

export 'package:optomstroy/core/network/interceptors/session_hooks.dart';

/// События сессии для `core/session` (SessionController, RM-D-*).
enum SessionEvent {
  /// Сессия завершена сервером или refresh отклонён — переход на `/auth/phone`.
  ended,

  /// Нужна разблокировка PIN/биометрией (SCR-08), сессия не отозвана.
  unlockRequired,
}

/// Запрос отменён, потому что сессия завершилась, пока он ждал разблокировки.
final class SessionEndedWhileLocked implements Exception {
  const SessionEndedWhileLocked();

  @override
  String toString() => 'SessionEndedWhileLocked';
}

final class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required Dio dio,
    required TokenStore tokens,
    required TokenRefresher refresher,
    void Function(SessionEvent event)? onSessionEvent,
    AuthSessionHooks? hooks,
    DateTime Function()? now,
  }) : _dio = dio,
       _tokens = tokens,
       _refresher = refresher,
       _onSessionEvent = onSessionEvent,
       _hooks = hooks,
       _now = now ?? _utcNow;

  final Dio _dio;
  final TokenStore _tokens;
  final TokenRefresher _refresher;
  final void Function(SessionEvent event)? _onSessionEvent;
  final DateTime Function() _now;
  AuthSessionHooks? _hooks;
  Future<RefreshResult>? _inflight;

  static const String _bearer = 'Bearer ';

  /// Refresh заранее, если до `exp` access-токена меньше этого (09 §8.3).
  static const Duration refreshMargin = Duration(seconds: 60);

  /// Повторов исходного запроса после `STEP_UP_REQUIRED` (кэш + диалог) — защита от цикла.
  static const int maxStepUpAttempts = 2;

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// Интерсептор клиента [dio] (создаётся DioClient) — для подключения хуков сессии.
  static AuthInterceptor? of(Dio dio) {
    for (final interceptor in dio.interceptors) {
      if (interceptor is AuthInterceptor) return interceptor;
    }
    return null;
  }

  /// Подключить (или снять — `null`) хуки core/session.
  void attachHooks(AuthSessionHooks? hooks) => _hooks = hooks;

  /// Подключённые хуки (для проверок).
  AuthSessionHooks? get hooks => _hooks;

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (options.skipAuth) return handler.next(options);
    final hooks = _hooks;
    final bypassLock = options.extra[SessionRequestExtra.bypassLock] == true;
    if (hooks != null && hooks.isLocked && !bypassLock) {
      // Под overlay SCR-08 запросы не уходят: ждём разблокировки (или конца сессии).
      if (!await hooks.waitUntilUnlocked()) {
        return handler.reject(_endedWhileLocked(options));
      }
    }
    var access = _tokens.accessToken;
    final stale = access != null && (AccessTokenClaims.tryParse(access)?.expiresWithin(refreshMargin, _now()) ?? false);
    if ((access == null || stale) && await _tokens.readRefreshToken() != null) {
      // Холодный старт (access в памяти нет) или access вот-вот истечёт — сначала refresh.
      final result = await refreshOnce();
      if (result is RefreshUnlockRequired && hooks != null && !bypassLock) {
        if (!await hooks.unlockRequired()) return handler.reject(_endedWhileLocked(options));
      }
      access = _tokens.accessToken;
    }
    if (access != null) options.headers[ApiHeaders.authorization] = '$_bearer$access';
    _attachCachedStepUp(options);
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final status = err.response?.statusCode;
    if (options.skipAuth || status == null) return handler.next(err);
    final data = err.response?.data;
    final code = Problem.codeOf(data);
    if (status == 403 && code == 'STEP_UP_REQUIRED') return _onStepUpRequired(err, handler);
    if (status == 409 && code == 'DEVICE_MISMATCH') {
      await _endSession(SessionEndSignal(code: code!, reason: Problem.tryParse(data)?.reason));
      return handler.next(err);
    }
    if (status != 401) return handler.next(err);
    switch (code) {
      case 'SESSION_REVOKED':
        await _endSession(SessionEndSignal(code: code!, reason: Problem.tryParse(data)?.reason));
        return handler.next(err);
      case 'UNLOCK_REQUIRED':
        _tokens.clearAccessToken();
        _onSessionEvent?.call(SessionEvent.unlockRequired);
        return _retryAfterUnlock(err, handler);
      case 'PIN_INVALID' || 'PIN_LOCKED':
        return handler.next(err);
    }
    if (options.extra[RequestExtra.authRetried] == true) return handler.next(err);
    final sent = options.headers[ApiHeaders.authorization];
    final current = _tokens.accessToken;
    // Токен уже обновлён параллельным запросом — повторяем с ним без нового refresh.
    final alreadyRefreshed = current != null && sent != '$_bearer$current';
    if (!alreadyRefreshed) {
      final result = await refreshOnce();
      if (result is RefreshUnlockRequired) return _retryAfterUnlock(err, handler);
      if (result is! RefreshSucceeded) return handler.next(err);
    }
    options
      ..headers[ApiHeaders.authorization] = '$_bearer${_tokens.accessToken}'
      ..extra[RequestExtra.authRetried] = true;
    await _retry(options, handler);
  }

  /// Single-flight refresh: параллельные вызовы получают один результат (08 §2.10).
  Future<RefreshResult> refreshOnce() => _inflight ??= _refresh().whenComplete(() => _inflight = null);

  Future<RefreshResult> _refresh() async {
    final refreshToken = await _tokens.readRefreshToken();
    final result = refreshToken == null ? const RefreshSessionEnded() : await _refresher.refresh(refreshToken);
    switch (result) {
      case RefreshSucceeded(:final tokens):
        await _tokens.saveTokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken);
      case RefreshSessionEnded(:final String? code, :final String? reason):
        // Причина сервера (`SESSION_REVOKED` + `reason`, D SS-03) — для текста SCR-90; без тела — «refresh отклонён».
        await _endSession(
          code == 'SESSION_REVOKED' || code == 'DEVICE_MISMATCH'
              ? SessionEndSignal(code: code!, reason: reason)
              : SessionEndSignal(code: SessionEndSignal.refreshRejected, reason: reason),
        );
      case RefreshUnlockRequired():
        _tokens.clearAccessToken();
        _onSessionEvent?.call(SessionEvent.unlockRequired);
      case RefreshTransientFailure():
        break;
    }
    return result;
  }

  Future<void> _endSession(SessionEndSignal signal) async {
    await _tokens.clearSession();
    _onSessionEvent?.call(SessionEvent.ended);
    _hooks?.sessionEnded(signal);
  }

  /// `UNLOCK_REQUIRED`: SCR-08 → `POST /auth/unlock` → один повтор исходного запроса.
  Future<void> _retryAfterUnlock(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final hooks = _hooks;
    if (hooks == null ||
        options.extra[SessionRequestExtra.unlockRetried] == true ||
        options.extra[SessionRequestExtra.bypassLock] == true) {
      return handler.next(err);
    }
    if (!await hooks.unlockRequired()) return handler.next(err);
    final access = _tokens.accessToken;
    if (access == null) return handler.next(err);
    options
      ..headers[ApiHeaders.authorization] = '$_bearer$access'
      ..extra[SessionRequestExtra.unlockRetried] = true;
    await _retry(options, handler);
  }

  /// `STEP_UP_REQUIRED` (08 §2.12): токен области из кэша или StepUpDialog → повтор
  /// с `X-Step-Up-Token` и тем же `Idempotency-Key` (заголовки исходного запроса сохраняются).
  Future<void> _onStepUpRequired(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final hooks = _hooks;
    final stepUp = Problem.tryParse(err.response?.data)?.stepUp;
    final operation = stepUp?.operation;
    final attempts = options.extra[SessionRequestExtra.stepUpAttempts] as int? ?? 0;
    if (hooks == null || operation == null || attempts >= maxStepUpAttempts) return handler.next(err);
    final sent = options.headers[ApiHeaders.stepUpToken];
    if (sent is String) hooks.discardStepUpToken(operation, sent);
    var token = hooks.stepUpTokenFor(operation);
    if (token == null || token == sent) {
      // Диалог — не больше одного на запрос: если сервер отверг и свежий токен, ошибка уходит вызывающему.
      if (options.extra[SessionRequestExtra.stepUpPrompted] == true) return handler.next(err);
      options.extra[SessionRequestExtra.stepUpPrompted] = true;
      final methods = stepUp?.allowedMethods;
      token = await hooks.requestStepUp(
        StepUpChallenge(
          operation: operation,
          allowedMethods: methods == null || methods.isEmpty ? const <String>['pin', 'otp'] : methods,
        ),
      );
    }
    if (token == null) return handler.next(err);
    options
      ..headers[ApiHeaders.stepUpToken] = token
      ..extra[SessionRequestExtra.stepUpAttempts] = attempts + 1;
    await _retry(options, handler);
  }

  void _attachCachedStepUp(RequestOptions options) {
    final operation = options.extra[SessionRequestExtra.stepUpOperation];
    final hooks = _hooks;
    if (operation is! String || hooks == null || options.headers.containsKey(ApiHeaders.stepUpToken)) return;
    final token = hooks.stepUpTokenFor(operation);
    if (token != null) options.headers[ApiHeaders.stepUpToken] = token;
  }

  Future<void> _retry(RequestOptions options, ErrorInterceptorHandler handler) async {
    try {
      handler.resolve(await _dio.fetch<dynamic>(options));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  static DioException _endedWhileLocked(RequestOptions options) => DioException(
    requestOptions: options,
    type: DioExceptionType.cancel,
    error: const SessionEndedWhileLocked(),
    message: 'session ended while locked',
  );
}
