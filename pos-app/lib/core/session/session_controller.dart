// SessionController (06 §6.2 core/session; 09 §8, §8.8, §9.3; RM-D-009): восстановление сессии,
// вход (сохранение пары токенов), блокировка (холодный старт, idle 30 мин, фон 5 мин, вручную,
// `UNLOCK_REQUIRED`) и разблокировка `POST /auth/unlock`, выход / выход везде, завершение сервером.
//
// Хранение (ядро §18.2 п.2–3): access — только память (TokenStore), refresh и deviceId — secure storage;
// stepUpToken — память (StepUpTokenCache). Выход очищает секреты (кроме deviceId) и черновики пользователя
// по 07 §11.4 (корзина и outbox владельца сохраняются). PIN, OTP, токены и телефон не логируются.
// Офлайн-выход (RC-1/SS-07, ядро §19.4, 02 UI-41-005): refresh переносится в запись `pending_logout`
// (core/session/pending_logout.dart), в outbox владельца ставится `auth.logout` без токенов; доставка — по сети.
//
// Контроллер реализует [AuthSessionHooks] и подключается к AuthInterceptor основного Dio.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_providers.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/interceptors/access_token_claims.dart';
import 'package:optomstroy/core/network/interceptors/auth_interceptor.dart';
import 'package:optomstroy/core/session/idle_lock_monitor.dart';
import 'package:optomstroy/core/session/pending_logout.dart';
import 'package:optomstroy/core/session/session_api.dart';
import 'package:optomstroy/core/session/session_local_data.dart';
import 'package:optomstroy/core/session/session_policy.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/session/step_up_coordinator.dart';
import 'package:optomstroy/core/session/step_up_token_cache.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/sync/auth_logout_outbox.dart';
import 'package:optomstroy/core/sync/outbox_payloads.dart';

/// Дополнительная очистка при выходе / завершении сессии (например, `biometric_refresh` — RM-D-008).
typedef SessionCleanupHook = Future<void> Function();

/// Итог разблокировки.
sealed class UnlockOutcome {
  const UnlockOutcome();
}

final class UnlockSucceeded extends UnlockOutcome {
  const UnlockSucceeded({this.newBiometricRefresh});

  /// `method=biometric`: новый `biometric_refresh` — вызывающий шифрует его ключом Keystore/Keychain.
  final String? newBiometricRefresh;

  @override
  String toString() => 'UnlockSucceeded()';
}

final class UnlockRejected extends UnlockOutcome {
  const UnlockRejected(this.error);

  final SessionCallError error;

  @override
  String toString() => 'UnlockRejected(${error.runtimeType})';
}

/// Политика защиты сессии (платформа сборки).
final sessionPolicyProvider = Provider<SessionPolicy>((ref) => SessionPolicy.forPlatform(defaultTargetPlatform));

/// Координатор step-up и кэш токенов области (память процесса).
final stepUpCoordinatorProvider = Provider<StepUpCoordinator>(
  (ref) => StepUpCoordinator(
    StepUpTokenCache(clock: ref.watch(clockProvider), skew: ref.watch(sessionPolicyProvider).stepUpExpirySkew),
  ),
);

/// HTTP-вызовы сессии поверх основного Dio.
final sessionApiProvider = Provider<SessionApi>((ref) => SessionApi(ref.watch(dioProvider)));

/// Шаги очистки при завершении сессии (`_clearLocal`: logout, logout-all, `SESSION_REVOKED` и другие
/// серверные завершения). По умолчанию — удаление `biometric_refresh` вместе с ключом Keystore/Keychain
/// (`BiometricAuthenticator.clear`; ревью D-MN-04, 09 BIO-012/014): семья на сервере отозвана, секрет не должен
/// оставаться на устройстве. Композиционный корень может расширить список.
final sessionCleanupHooksProvider = Provider<List<SessionCleanupHook>>((ref) {
  final BiometricAuthenticator biometrics = ref.watch(biometricAuthenticatorProvider);
  return <SessionCleanupHook>[biometrics.clear];
});

/// Контроллер сессии.
final sessionControllerProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

final Logger _log = Logger('session');

class SessionController extends Notifier<SessionState> implements AuthSessionHooks {
  late TokenStore _tokens;
  late SecureStorage _storage;
  late StepUpCoordinator _stepUp;
  late SessionPolicy _policy;
  late IdleLockMonitor _idle;
  AuthInterceptor? _interceptor;
  Completer<bool>? _unlockWaiter;
  Future<SessionStatus>? _restoring;
  bool _ending = false;
  final Set<Timer> _timers = <Timer>{};

  /// `sid` текущей сессии (claim access-токена после входа/разблокировки) — для `pending_logout` и
  /// `DELETE /auth/sessions/{sid}` (AC-UI-41-014). На холодном старте до разблокировки неизвестен.
  String? _sessionId;

  /// Предел ожидания доставки `pending_logout` перед входом (02 UI-41-005 п. 5): дольше — вход продолжается,
  /// доставка завершается в фоне.
  static const Duration pendingLogoutBeforeLogin = Duration(seconds: 10);

  @override
  SessionState build() {
    _tokens = ref.watch(tokenStoreProvider);
    _storage = ref.watch(secureStorageProvider);
    _stepUp = ref.watch(stepUpCoordinatorProvider);
    _policy = ref.watch(sessionPolicyProvider);
    _idle = IdleLockMonitor(policy: _policy, clock: ref.watch(clockProvider), onLock: lock);
    _interceptor = _attachToDio();
    ref.onDispose(() {
      for (final timer in _timers) {
        timer.cancel();
      }
      _timers.clear();
      _idle.dispose();
      if (identical(_interceptor?.hooks, this)) _interceptor?.attachHooks(null);
      _completeWaiter(false);
    });
    return SessionState.initial;
  }

  AuthInterceptor? _attachToDio() {
    try {
      final interceptor = AuthInterceptor.of(ref.watch(dioProvider));
      interceptor?.attachHooks(this);
      return interceptor;
    } on Object catch (e) {
      // Без clientMetaProvider (bootstrap не прочитал метаданные, виджет-тест) Dio не создаётся:
      // сессия работает без сети, интерсептор подключится при пересоздании провайдера.
      _log.warning('dio недоступен: ${e.runtimeType}');
      return null;
    }
  }

  SessionApi get _api => ref.read(sessionApiProvider);

  // --- Восстановление и вход ---

  /// Холодный старт: есть refresh → сессия (заблокирована до SCR-08 `cold`), иначе — вход по телефону.
  /// Staff — всегда SCR-08; customer по ядру §24.2 обязан иметь PIN или биометрию — тоже SCR-08.
  Future<SessionStatus> restore() => _restoring ??= _restore();

  Future<SessionStatus> _restore() async {
    String? refresh;
    try {
      // Зависшее хранилище (нет плагина, сбой Keystore) не держит Splash бесконечно: по таймауту —
      // вход по телефону (OTP), сохранённый refresh останется до следующего запуска.
      refresh = await _withTimeout(_tokens.readRefreshToken(), _policy.storageTimeout);
    } on Exception catch (e) {
      _log.warning('secure storage недоступно: ${e.runtimeType}');
    }
    if (!ref.mounted) return SessionStatus.unknown;
    if (state.status != SessionStatus.unknown) return state.status;
    // Холодный старт: отложенный выход прежней сессии доставляется в фоне (для входа запись не используется).
    _kickPendingLogout();
    if (refresh == null) {
      state = const SessionState(status: SessionStatus.unauthenticated);
      return SessionStatus.unauthenticated;
    }
    state = const SessionState(status: SessionStatus.authenticated, lock: SessionLockReason.coldStart);
    return SessionStatus.authenticated;
  }

  /// [future] или `TimeoutException` через [limit]; таймер снимается при dispose провайдера.
  Future<T> _withTimeout<T>(Future<T> future, Duration limit) {
    final completer = Completer<T>();
    final timer = Timer(limit, () {
      if (!completer.isCompleted) completer.completeError(TimeoutException('secure storage', limit));
    });
    _timers.add(timer);
    future
        .then(
          (value) {
            if (!completer.isCompleted) completer.complete(value);
          },
          onError: (Object e, StackTrace st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          },
        )
        .whenComplete(() {
          timer.cancel();
          _timers.remove(timer);
        })
        .ignore();
    return completer.future;
  }

  /// Вход выполнен (OTP, регистрация, приглашение): access — в память, refresh — в secure storage.
  Future<void> establish({required String accessToken, required String refreshToken}) async {
    // 02 UI-41-005 п. 5: перед входом (в т. ч. другого пользователя) — доставка отложенного выхода прежней сессии.
    await _deliverPendingLogout();
    final claims = AccessTokenClaims.tryParse(accessToken);
    final previousUserId = state.userId;
    final nextUserId = claims?.subject;
    if (previousUserId != null && nextUserId != null && previousUserId != nextUserId) {
      // Вход другого сотрудника после «Войти по номеру телефона» (07 §11.4 «Смена пользователя»): файл прежнего
      // пользователя ещё открыт — его notifications_cache, checkout_draft, registration_draft и settings(scope=user)
      // очищаются до закрытия; черновик корзины и очередь владельца остаются до его следующего входа.
      await _clearPreviousUserData(previousUserId);
    }
    await _tokens.saveTokens(accessToken: accessToken, refreshToken: refreshToken);
    _sessionId = claims?.sessionId;
    _stepUp.clear();
    _restoring = Future<SessionStatus>.value(SessionStatus.authenticated);
    _ending = false;
    state = SessionState(
      status: SessionStatus.authenticated,
      userKind: UserKind.tryParse(claims?.kind),
      userId: claims?.subject,
    );
    _completeWaiter(true);
    _startIdle();
  }

  // --- Активность и блокировка ---

  /// Ввод пользователя (касание, клавиатура, сканер) — сброс idle-таймера.
  void recordActivity() => _idle.activity();

  /// Приложение ушло в фон.
  void appBackgrounded() => _idle.backgrounded();

  /// Приложение вернулось из фона (Android/iOS: > 5 мин → блокировка).
  void appForegrounded() => _idle.foregrounded();

  /// Заблокировать экран: access очищается из памяти, stepUpToken — тоже; состояние экрана под overlay сохраняется.
  void lock(SessionLockReason reason) {
    if (!ref.mounted || !state.isAuthenticated) return;
    if (state.lock != null) return;
    _idle.stop();
    _tokens.clearAccessToken();
    _stepUp.clear();
    state = state.copyWith(lock: reason);
  }

  /// `POST /auth/unlock {method: pin}` (09 §8.8): `PIN_INVALID` — без `/auth/refresh` (ядро §18.2 п.5).
  Future<UnlockOutcome> unlockWithPin(String pin, {bool biometricInvalidated = false}) async {
    final refresh = await _tokens.readRefreshToken();
    if (refresh == null) {
      await _endFromServer(SessionEndReason.revoked);
      return const UnlockRejected(SessionRevokedError(SessionEndSignal(code: SessionEndSignal.refreshRejected)));
    }
    final response = await _api.unlockWithPin(
      refreshToken: refresh,
      pin: pin,
      biometricInvalidated: biometricInvalidated,
    );
    switch (response) {
      case UnlockOk(:final tokens):
        await _tokens.saveTokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken);
        _unlocked(tokens.accessToken);
        return const UnlockSucceeded();
      case UnlockFailed(:final error):
        return _unlockFailed(error);
    }
  }

  /// `POST /auth/unlock {method: biometric}` с расшифрованным `biometric_refresh` (Android/iOS; RM-D-008).
  /// Стандартный refresh в secure storage сохраняется; новый `biometric_refresh` возвращается вызывающему.
  Future<UnlockOutcome> unlockWithBiometric(String biometricRefresh) async {
    final standard = await _tokens.readRefreshToken();
    if (standard == null) {
      await _endFromServer(SessionEndReason.revoked);
      return const UnlockRejected(SessionRevokedError(SessionEndSignal(code: SessionEndSignal.refreshRejected)));
    }
    final response = await _api.unlockWithBiometric(biometricRefresh: biometricRefresh);
    switch (response) {
      case UnlockOk(:final tokens):
        await _tokens.saveTokens(accessToken: tokens.accessToken, refreshToken: standard);
        _unlocked(tokens.accessToken);
        return UnlockSucceeded(newBiometricRefresh: tokens.refreshToken);
      case UnlockFailed(:final error):
        return _unlockFailed(error);
    }
  }

  Future<UnlockOutcome> _unlockFailed(SessionCallError error) async {
    if (error is SessionRevokedError) {
      await _tokens.clearSession();
      await _endFromServer(SessionEndReason.fromServer(error.signal.code, error.signal.reason));
    }
    return UnlockRejected(error);
  }

  void _unlocked(String accessToken) {
    if (!ref.mounted) return;
    final claims = AccessTokenClaims.tryParse(accessToken);
    _sessionId = claims?.sessionId ?? _sessionId;
    state = state.copyWith(
      status: SessionStatus.authenticated,
      clearLock: true,
      clearEndReason: true,
      endAcknowledged: false,
      userKind: UserKind.tryParse(claims?.kind),
      userId: claims?.subject,
    );
    _completeWaiter(true);
    _startIdle();
  }

  // --- Step-up (для StepUpDialog) ---

  /// `POST /auth/step-up {method: pin}`.
  Future<StepUpResponse> stepUpWithPin(String operation, String pin) =>
      _api.stepUpWithPin(operation: operation, pin: pin);

  /// `POST /auth/step-up {method: otp}` → код отправлен.
  Future<StepUpResponse> requestStepUpOtp(String operation) => _api.requestStepUpOtp(operation: operation);

  /// `POST /auth/step-up {method: otp, challengeId, code}`.
  Future<StepUpResponse> stepUpWithOtp(String operation, String challengeId, String code) =>
      _api.stepUpWithOtp(operation: operation, challengeId: challengeId, code: code);

  // --- Выход ---

  /// Неотправленные локальные изменения владельца (предупреждение перед «Выйти», FLOW-009.E1).
  Future<PendingLocalChanges> pendingLocalChanges() async {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return PendingLocalChanges.none;
    return SessionLocalData(db).pending(state.userId);
  }

  /// «Выйти» / «Сменить аккаунт» (09 §8.6): `POST /auth/logout`, затем очистка. Без ответа сервера (нет сети,
  /// таймаут, `5xx`) — отложенный выход (02 UI-41-005 «офлайн»): refresh — в запись `pending_logout`, в outbox
  /// владельца — `auth.logout` без токенов; локальная очистка выполняется сразу, [SessionState.serverLogoutPending]
  /// — для снекбара `profile_logout_offline_done` (UI-41-014).
  Future<void> logout() async {
    var deferred = false;
    try {
      await _api.logout(bypassLock: true);
    } on DioException catch (e) {
      // Сессия уже недействительна (`401`) — только локальный выход; нет ответа сервера — и отложенный отзыв.
      _log.info('logout: ${e.type.name} ${e.response?.statusCode ?? '-'}');
      deferred = _noServerAnswer(e);
    }
    if (deferred) deferred = await _deferServerLogout();
    await _clearLocal(SessionEndReason.logout, serverLogoutPending: deferred);
    if (deferred) _kickPendingLogout();
  }

  /// Запрос не дошёл до сервера или сервер не ответил по существу: сессия на сервере, вероятно, жива.
  static bool _noServerAnswer(DioException e) {
    if (e.error is SessionEndedWhileLocked) return false;
    if (e.type != DioExceptionType.badResponse) return e.type != DioExceptionType.cancel;
    final status = e.response?.statusCode ?? 0;
    return status >= 500 || status == 429 || status == 408;
  }

  /// Шаги 1–2 офлайн-выхода (02 UI-41-005): запись `pending_logout` и `auth.logout` в outbox владельца.
  /// `false` — refresh нет (сохранять нечего) или запись не удалась.
  Future<bool> _deferServerLogout() async {
    try {
      final refresh = await _tokens.readRefreshToken();
      if (refresh == null) return false;
      final clock = ref.read(clockProvider);
      final at = DateTime.fromMillisecondsSinceEpoch(clock.nowUtc().millisecondsSinceEpoch, isUtc: true);
      final sid = _sessionId;
      await ref
          .read(pendingLogoutServiceProvider)
          .remember(PendingLogoutEntry(refreshToken: refresh, createdAt: at, sessionId: sid));
      final db = ref.read(appDatabaseProvider);
      final owner = state.userId;
      if (db != null && owner != null) {
        try {
          await enqueueAuthLogout(
            db: db,
            ownerUserId: owner,
            payload: AuthLogoutPayload(requestedAt: at, sessionId: sid),
            clock: clock,
          );
        } on Exception catch (e) {
          // Запись outbox — повтор из сессии владельца; доставку без сессии выполняет pending_logout.
          _log.warning('auth.logout в outbox: ${e.runtimeType}');
        }
      }
      return true;
    } on Object catch (e) {
      _log.warning('pending_logout не сохранён: ${e.runtimeType}');
      return false;
    }
  }

  /// Фоновая доставка `pending_logout` (исключений не бросает).
  void _kickPendingLogout() {
    try {
      unawaited(ref.read(pendingLogoutServiceProvider).deliver());
    } on Object catch (e) {
      _log.fine('pending_logout недоступен: ${e.runtimeType}');
    }
  }

  /// Доставка `pending_logout` перед входом (не дольше [pendingLogoutBeforeLogin]; дальше — в фоне).
  Future<void> _deliverPendingLogout() async {
    try {
      final service = ref.read(pendingLogoutServiceProvider);
      if (!await service.hasPending().timeout(_policy.storageTimeout)) return;
      await service.deliver().timeout(pendingLogoutBeforeLogin);
    } on Object catch (e) {
      _log.info('pending_logout перед входом: ${e.runtimeType}');
    }
  }

  /// «Выйти на всех устройствах» (`POST /auth/logout-all`, step-up `session.logout_all`):
  /// `null` — выполнено (локальная сессия завершена), иначе — ошибка (сессия остаётся).
  Future<SessionCallError?> logoutAll() async {
    try {
      await _api.logoutAll();
    } on DioException catch (e) {
      return SessionApi.mapError(e);
    }
    await _clearLocal(SessionEndReason.logoutAll);
    return null;
  }

  /// SCR-08 «Войти по номеру телефона» / «Войти по SMS» (`PIN_LOCKED`): уход на SCR-01, токены
  /// сохраняются до успешного входа (09 §9.3; 02 UI-08-016).
  void leaveToPhoneLogin({SessionEndReason reason = SessionEndReason.phoneLogin}) {
    assert(!reason.isServerSide, 'leaveToPhoneLogin: только pinLocked / pinReset / phoneLogin');
    if (!ref.mounted) return;
    _idle.stop();
    _stepUp.clear();
    _tokens.clearAccessToken();
    state = SessionState(
      status: SessionStatus.unauthenticated,
      endReason: reason,
      userKind: state.userKind,
      userId: state.userId,
    );
    _completeWaiter(false);
  }

  /// Диалог SCR-90 «Сессия завершена» закрыт («Войти снова»).
  void acknowledgeEnded() {
    if (ref.mounted && state.showSessionEnded) state = state.copyWith(endAcknowledged: true);
  }

  Future<void> _clearLocal(SessionEndReason reason, {bool serverLogoutPending = false}) async {
    final userId = state.userId;
    _sessionId = null;
    _idle.stop();
    _stepUp.clear();
    await _tokens.clearSession();
    await _storage.deleteAll(SecureKey.registration);
    for (final hook in ref.read(sessionCleanupHooksProvider)) {
      try {
        await hook();
      } on Exception catch (e) {
        _log.warning('cleanup hook: ${e.runtimeType}');
      }
    }
    final db = ref.read(appDatabaseProvider);
    if (db != null) {
      try {
        await SessionLocalData(db).clearOnSessionEnd(userId);
      } on Exception catch (e) {
        _log.warning('очистка локальных данных: ${e.runtimeType}');
      }
    }
    if (!ref.mounted) return;
    _restoring = Future<SessionStatus>.value(SessionStatus.unauthenticated);
    state = SessionState(
      status: SessionStatus.unauthenticated,
      endReason: reason,
      serverLogoutPending: serverLogoutPending,
    );
    _completeWaiter(false);
  }

  Future<void> _clearPreviousUserData(String userId) async {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    try {
      await SessionLocalData(db).clearOnSessionEnd(userId);
    } on Exception catch (e) {
      _log.warning('очистка данных прежнего пользователя: ${e.runtimeType}');
    }
  }

  Future<void> _endFromServer(SessionEndReason reason) async {
    // Уже завершена (сервером или своим выходом) — повторные сигналы параллельных запросов игнорируются;
    // после ухода на SCR-01 с сохранёнными токенами (pinLocked / pinReset / phoneLogin) — очистка нужна.
    final ended =
        state.status == SessionStatus.unauthenticated &&
        (state.endReason?.isServerSide == true ||
            state.endReason == SessionEndReason.logout ||
            state.endReason == SessionEndReason.logoutAll);
    if (_ending || ended) return;
    _ending = true;
    try {
      await _clearLocal(reason);
    } finally {
      _ending = false;
    }
  }

  void _startIdle() {
    if (state.userKind == UserKind.customer && !_policy.idleLockForCustomer) {
      _idle.stop();
    } else {
      _idle.start();
    }
  }

  void _completeWaiter(bool unlocked) {
    final waiter = _unlockWaiter;
    _unlockWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(unlocked);
  }

  // --- AuthSessionHooks (AuthInterceptor) ---

  @override
  bool get isLocked => ref.mounted && state.isLocked;

  @override
  Future<bool> waitUntilUnlocked() {
    if (!ref.mounted || !state.isAuthenticated) return Future<bool>.value(false);
    if (state.lock == null) return Future<bool>.value(true);
    return (_unlockWaiter ??= Completer<bool>()).future;
  }

  @override
  Future<bool> unlockRequired() {
    if (!ref.mounted || !state.isAuthenticated) return Future<bool>.value(false);
    lock(SessionLockReason.unlockRequired);
    return waitUntilUnlocked();
  }

  @override
  void sessionEnded(SessionEndSignal signal) {
    unawaited(_endFromServer(SessionEndReason.fromServer(signal.code, signal.reason)));
  }

  @override
  String? stepUpTokenFor(String operation) => _stepUp.tokenFor(operation);

  @override
  void discardStepUpToken(String operation, String token) => _stepUp.discard(token);

  @override
  Future<String?> requestStepUp(StepUpChallenge challenge) {
    if (!isLocked && state.isAuthenticated) return _stepUp.obtain(challenge);
    return Future<String?>.value();
  }
}
