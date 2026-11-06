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
//
// Планшет магазина (`kind=kiosk`; P-002 §8.2 п. 5–8, §8.9; 09 §8.9; ADR-115 п. 12, п. 26; 13 TAB-2-10):
// - признак планшета (core/session/kiosk_marker.dart) — вне ключей сессии: холодный старт по признаку открывает
//   `/kiosk` без блокировки холодного старта и без сети (`userKind = kiosk`, `userId` из признака — кэш каталога);
//   признак без refresh-токена — SCR-51 «Планшет нужно подключить заново» (guard G-0a);
// - PIN нет: блокировка ([SessionController.lock]), idle и `Ctrl+L` к планшету не применяются — экран было бы нечем
//   разблокировать;
// - `401 SESSION_REVOKED` — токены удаляются, признак и закрепление остаются (G-0a), диалога SCR-90 C нет;
// - `401 KIOSK_REVOKED` и аварийный выход — [SessionController.endKiosk]: токены, признак и хэш аварийного кода
//   удаляются, закрепление снимается (`KioskLock.disable`), затем SCR-01;
// - заголовок `X-Kiosk-Lock: on|off` на каждом запросе сессии планшета — последний снимок `KioskLock.status`
//   (ClientMetaInterceptor основного Dio; до первого снимка заголовка нет — сервер значение не меняет);
// - подключение этого устройства планшетом (SCR-54, FLOW-043.S4–S6, A2; 13 TAB-2-02): сервер отзывает сессию
//   администратора в той же транзакции — до «Готово» её конец удерживается ([SessionController.holdForKioskEnrollment]);
//   [SessionController.becomeKiosk] удаляет данные администратора (ключи — по одному, кроме `device.id`; файл БД — после
//   закрытия), пишет признак, хэш кода и токены планшета без промежуточного `unauthenticated` (иначе G-1 → SCR-01) и
//   включает закрепление (`KioskLock.enable`).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_providers.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/hardware/kiosk_lock.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/interceptors/access_token_claims.dart';
import 'package:optomstroy/core/network/interceptors/auth_interceptor.dart';
import 'package:optomstroy/core/network/interceptors/client_meta_interceptor.dart';
import 'package:optomstroy/core/session/idle_lock_monitor.dart';
import 'package:optomstroy/core/session/kiosk_exit_code_hash.dart';
import 'package:optomstroy/core/session/kiosk_marker.dart';
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

class SessionController extends Notifier<SessionState> implements AuthSessionHooks, KioskSessionHooks {
  late TokenStore _tokens;
  late SecureStorage _storage;
  late StepUpCoordinator _stepUp;
  late SessionPolicy _policy;
  late IdleLockMonitor _idle;
  AuthInterceptor? _interceptor;
  ClientMetaInterceptor? _meta;
  Completer<bool>? _unlockWaiter;
  Future<SessionStatus>? _restoring;
  bool _ending = false;
  final Set<Timer> _timers = <Timer>{};

  /// Завершение сессии сервером в работе (`_endFromServer`) — конец режима планшета ждёт его итога.
  Future<void>? _serverEnding;

  /// Конец режима планшета в работе ([endKiosk]) и его итоговая причина (аварийный выход сильнее отзыва).
  Future<void>? _kioskEnding;
  SessionEndReason? _kioskEndReason;

  /// Значение `X-Kiosk-Lock` по последнему снимку `KioskLock.status`; `null` — снимка ещё не было.
  String? _kioskLockHeader;

  /// Подключение этого устройства планшетом в работе ([holdForKioskEnrollment]): конец сессии администратора
  /// удерживается до «Готово» ([becomeKiosk]) или отмены ([releaseKioskEnrollment]).
  bool _kioskEnrollment = false;

  /// Удержанный конец сессии администратора — выполняется, если подключение не состоялось.
  SessionEndReason? _heldEnd;

  /// Токены планшета сразу после подключения (память, [kioskSwitchGrace]): поздний `401` на запрос администратора,
  /// отправленный до «Готово», стирает токены в AuthInterceptor — сессия планшета восстанавливает их отсюда.
  ({String access, String refresh})? _switchTokens;
  DateTime? _switchedAt;

  /// Сколько после подключения поздний отказ запроса администратора не завершает сессию планшета.
  static const Duration kioskSwitchGrace = Duration(seconds: 30);

  /// Источник `X-Kiosk-Lock` для ClientMetaInterceptor (одна ссылка — чтобы отключать только свой источник).
  late final String? Function() _kioskLockSource = _kioskLockHeaderValue;

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
      if (identical(_meta?.kioskLock, _kioskLockSource)) _meta?.attachKioskLock(null);
      _completeWaiter(false);
    });
    return SessionState.initial;
  }

  AuthInterceptor? _attachToDio() {
    try {
      final dio = ref.watch(dioProvider);
      final interceptor = AuthInterceptor.of(dio);
      interceptor?.attachHooks(this);
      _meta = ClientMetaInterceptor.of(dio)?..attachKioskLock(_kioskLockSource);
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
  /// Признак планшета магазина: сессия `kind=kiosk` без блокировки (PIN нет), без refresh — «Подключите заново» (G-0a).
  Future<SessionStatus> restore() => _restoring ??= _restore();

  Future<SessionStatus> _restore() async {
    // Зависшее хранилище (нет плагина, сбой Keystore) не держит Splash бесконечно: по таймауту — вход по телефону
    // (OTP), сохранённый refresh останется до следующего запуска. Refresh и признак планшета читаются параллельно —
    // у сотрудника и покупателя холодный старт ждёт не дольше одного [SessionPolicy.storageTimeout], как до режима
    // планшета (02 SCR-00; 10 KIOSK-029).
    final (String? refresh, KioskMarker? kiosk) = await (
      _readBounded<String>(_tokens.readRefreshToken, 'secure storage недоступно'),
      _readBounded<KioskMarker>(ref.read(kioskMarkerStoreProvider).read, 'признак планшета не прочитан'),
    ).wait;
    if (!ref.mounted) return SessionStatus.unknown;
    if (state.status != SessionStatus.unknown) return state.status;
    if (kiosk != null) return _restoreKiosk(kiosk, hasRefresh: refresh != null);
    // Холодный старт: отложенный выход прежней сессии доставляется в фоне (для входа запись не используется).
    _kickPendingLogout();
    if (refresh == null) {
      state = const SessionState(status: SessionStatus.unauthenticated);
      return SessionStatus.unauthenticated;
    }
    state = const SessionState(status: SessionStatus.authenticated, lock: SessionLockReason.coldStart);
    return SessionStatus.authenticated;
  }

  /// Чтение защищённого хранилища не дольше [SessionPolicy.storageTimeout]; сбой или таймаут — `null` (в журнал — только
  /// тип ошибки).
  Future<T?> _readBounded<T>(Future<T?> Function() read, String what) async {
    try {
      return await _withTimeout<T?>(read(), _policy.storageTimeout);
    } on Exception catch (e) {
      _log.warning('$what: ${e.runtimeType}');
      return null;
    }
  }

  /// Холодный старт планшета магазина (P-002 §15; navigation.md §7.2): `/kiosk` без SCR-08 и без сети. Вид и
  /// пользователь — из признака, поэтому БД `pos_<user>.db` с кэшем каталога открывается сразу; access выдаст первый
  /// refresh (`401 KIOSK_REVOKED` → [endKiosk], `401 SESSION_REVOKED` → «Подключите заново»).
  SessionStatus _restoreKiosk(KioskMarker marker, {required bool hasRefresh}) {
    final status = hasRefresh ? SessionStatus.authenticated : SessionStatus.unauthenticated;
    // Склад планшета для кэша каталога — из признака; `GET /me` уточнит его на первом экране режима (без сети здесь).
    ref.read(kioskTabletWarehouseProvider.notifier).set(marker.warehouseId);
    _kioskTabletChecked = false;
    _kioskTabletTriedAt = null;
    state = SessionState(
      status: status,
      userKind: UserKind.kiosk,
      userId: marker.userId,
      kioskTabletId: marker.tabletId,
      // Без сессии — как после `SESSION_REVOKED` по сроку: «Планшет нужно подключить заново».
      endReason: hasRefresh ? null : SessionEndReason.expired,
    );
    if (hasRefresh) unawaited(refreshKioskLockStatus());
    return status;
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

  /// Сессия планшета магазина на этом устройстве (SCR-54: подключение и подключение заново — FLOW-043.S6; вызывает
  /// `becomeKiosk` корня). Хэш аварийного кода (своя соль) и признак планшета — в защищённое хранилище вне ключей
  /// сессии, токены планшета — как при входе; режим — `kind=kiosk` без idle-блокировки. Сам код не сохраняется. Данные
  /// администратора на устройстве удаляет вызывающий до этого вызова, закрепление включает он же (`KioskLock.enable`).
  Future<void> establishKiosk({
    required String tabletId,
    String? tabletName,
    String? warehouseId,
    required String exitCode,
    required String accessToken,
    required String refreshToken,
  }) async {
    final claims = AccessTokenClaims.tryParse(accessToken);
    final userId = claims?.subject;
    if (claims?.kind != UserKind.kiosk.value || userId == null) {
      throw ArgumentError('establishKiosk: access-токен не технического пользователя планшета');
    }
    await ref.read(kioskExitCodeStoreProvider).remember(code: exitCode, tabletId: tabletId);
    await ref
        .read(kioskMarkerStoreProvider)
        .write(KioskMarker(tabletId: tabletId, tabletName: tabletName, userId: userId, warehouseId: warehouseId));
    await _tokens.saveTokens(accessToken: accessToken, refreshToken: refreshToken);
    _sessionId = claims?.sessionId;
    _stepUp.clear();
    _restoring = Future<SessionStatus>.value(SessionStatus.authenticated);
    _ending = false;
    if (!ref.mounted) return;
    ref.read(kioskAccessProvider.notifier).clear();
    ref.read(kioskTabletWarehouseProvider.notifier).set(warehouseId);
    // Склад известен из ответа подключения — `GET /me` до следующего запуска не нужен.
    _kioskTabletChecked = warehouseId != null;
    state = SessionState(
      status: SessionStatus.authenticated,
      userKind: UserKind.kiosk,
      userId: userId,
      kioskTabletId: tabletId,
    );
    _completeWaiter(true);
    _startIdle();
    unawaited(refreshKioskLockStatus());
  }

  // --- Активность и блокировка ---

  /// Ввод пользователя (касание, клавиатура, сканер) — сброс idle-таймера.
  void recordActivity() => _idle.activity();

  /// Приложение ушло в фон.
  void appBackgrounded() => _idle.backgrounded();

  /// Приложение вернулось из фона (Android/iOS: > 5 мин → блокировка).
  void appForegrounded() => _idle.foregrounded();

  /// Заблокировать экран: access очищается из памяти, stepUpToken — тоже; состояние экрана под overlay сохраняется.
  /// Планшету магазина — без действия: PIN нет, блокировку было бы нечем снять (P-002 §8.2; navigation.md §9, §14.1).
  void lock(SessionLockReason reason) {
    if (!ref.mounted || !state.isAuthenticated) return;
    if (_isKiosk || _kioskEnrollment) return;
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
    // Планшет магазина: признак переживает всё, кроме конца режима ([endKiosk]) — `SESSION_REVOKED` ведёт на G-0a.
    final kioskTabletId = reason.isKiosk ? null : state.kioskTabletId;
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
    final keepsKiosk = kioskTabletId != null;
    state = SessionState(
      status: SessionStatus.unauthenticated,
      endReason: reason,
      serverLogoutPending: serverLogoutPending,
      // «Подключите заново» и «Планшет отключён» — ещё режим планшета (`AppMode.kiosk`; без SCR-90 C и SCR-08).
      userKind: keepsKiosk || reason == SessionEndReason.kioskRevoked ? UserKind.kiosk : null,
      userId: keepsKiosk ? userId : null,
      kioskTabletId: kioskTabletId,
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
    final run = _clearLocal(reason);
    _serverEnding = run;
    try {
      await run;
    } finally {
      _ending = false;
      _serverEnding = null;
    }
  }

  void _startIdle() {
    if (_isKiosk || (state.userKind == UserKind.customer && !_policy.idleLockForCustomer)) {
      // Планшет магазина: вместо idle-блокировки — автосброс FLOW-045 режима планшета (navigation.md §4.3).
      _idle.stop();
    } else {
      _idle.start();
    }
  }

  /// Режим планшета магазина: сессия `kind=kiosk` или признак на устройстве.
  bool get _isKiosk => state.userKind == UserKind.kiosk || state.isKioskDevice;

  // --- Планшет магазина: конец режима, закрепление, доступ ---

  /// Конец режима планшета магазина ([reason] — `kioskRevoked`, `kioskExited`, `kioskExitedOffline`): токены, признак,
  /// хэш, счётчик и пауза аварийного кода удаляются, закрепление и ограничения Device Owner снимаются
  /// (`KioskLock.disable` — без исключений; без Device Owner ничего не делает), локальные данные сессии очищаются.
  /// Отзыв — SCR-51 «Планшет отключён администратором», затем SCR-01 ([acknowledgeKioskRevoked]); выход — сразу
  /// SCR-01. Повторные сигналы параллельных запросов очистку не повторяют; аварийный выход поверх отзыва (повтор
  /// `POST /kiosk/exit` после потерянного `200` → `401 KIOSK_REVOKED`) завершает режим как выход.
  Future<void> endKiosk(SessionEndReason reason) {
    assert(reason.isKiosk, 'endKiosk: только kioskRevoked / kioskExited / kioskExitedOffline');
    if (!ref.mounted) return Future<void>.value();
    final inflight = _kioskEnding;
    if (inflight != null) {
      if (reason != SessionEndReason.kioskRevoked) _kioskEndReason = reason;
      return inflight;
    }
    _kioskEndReason = reason;
    final run = _runEndKiosk().whenComplete(() {
      _kioskEnding = null;
      _kioskEndReason = null;
    });
    _kioskEnding = run;
    return run;
  }

  Future<void> _runEndKiosk() async {
    // Завершение сессии сервером в работе (`SESSION_REVOKED` параллельного запроса) — сначала его итог.
    final serverEnding = _serverEnding;
    if (serverEnding != null) await serverEnding;
    if (!ref.mounted) return;
    final reason = _kioskEndReason ?? SessionEndReason.kioskRevoked;
    // Повтор отзыва, пока SCR-51 «Планшет отключён» на экране, ничего не меняет.
    if (reason == SessionEndReason.kioskRevoked && state.kioskRevokedNotice) return;
    if (!_isKiosk) {
      final ended = state.endReason;
      if (ended != null && ended.isKiosk) {
        // Режим уже завершён: остаётся только сменить уведомление об отзыве на выход.
        if (reason != SessionEndReason.kioskRevoked && ended == SessionEndReason.kioskRevoked) {
          state = SessionState(status: SessionStatus.unauthenticated, endReason: reason);
        }
        return;
      }
      // Код пришёл не планшету — обычное завершение сессии сервером.
      if (reason == SessionEndReason.kioskRevoked) return _endFromServer(SessionEndReason.revoked);
    }
    await _endKiosk();
  }

  Future<void> _endKiosk() async {
    _ending = true;
    try {
      try {
        await ref.read(kioskMarkerStoreProvider).clear();
      } on Object catch (e) {
        _log.warning('признак планшета не удалён: ${e.runtimeType}');
      }
      try {
        await ref.read(kioskLockProvider).disable();
      } on Object catch (e) {
        _log.warning('закрепление не снято: ${e.runtimeType}');
      }
      _kioskLockHeader = null;
      if (ref.mounted) {
        ref.read(kioskAccessProvider.notifier).clear();
        ref.read(kioskTabletWarehouseProvider.notifier).set(null);
      }
      _kioskTabletChecked = false;
      _kioskTabletTriedAt = null;
      await _clearLocal(_kioskEndReason ?? SessionEndReason.kioskRevoked);
    } finally {
      _ending = false;
    }
  }

  // --- Планшет магазина: подключение этого устройства (SCR-54) ---

  /// SCR-54: подключение или подключение заново этого устройства начинается (перед `POST /admin/store-tablets` и
  /// `…/reconnect`; FLOW-043.S4, A2). Сервер в той же транзакции отзывает сессию администратора на устройстве, поэтому
  /// до «Готово» на диалоге аварийного кода сигналы конца сессии (`401 SESSION_REVOKED` фоновых запросов, отказ
  /// refresh) не уводят на SCR-01 и не закрывают диалог; idle-блокировки нет. Первый сигнал запоминается и выполняется,
  /// если подключение не состоялось ([releaseKioskEnrollment]).
  void holdForKioskEnrollment() {
    if (!ref.mounted || !state.isAuthenticated || _isKiosk) return;
    _kioskEnrollment = true;
    _idle.stop();
  }

  /// Подключение не состоялось (ошибка, отмена): удержанный конец сессии выполняется, иначе — idle как прежде.
  void releaseKioskEnrollment() {
    if (!_kioskEnrollment) return;
    _kioskEnrollment = false;
    final SessionEndReason? held = _heldEnd;
    _heldEnd = null;
    if (!ref.mounted) return;
    if (held != null) {
      unawaited(_endFromServer(held));
    } else if (state.isAuthenticated && state.lock == null) {
      _startIdle();
    }
  }

  /// «Готово» после аварийного кода (SCR-54 UI-54-014; FLOW-043.S6, A2; 09 §8.9 п. 1, п. 6, п. 7; 11 SEC-133 —
  /// исключение ADR-115): это устройство становится планшетом магазина.
  /// 1. Данные администратора: ключи защищённого хранилища — по одному (общий `deleteAll` плагина не вызывается),
  ///    кроме `device.id`; refresh перезаписывает токен планшета (без момента «нет refresh»); `biometric_refresh` и
  ///    ключ Keystore — хуки очистки; step-up и `sid` — из памяти.
  /// 2. Хэш аварийного кода, признак планшета и токены планшета — [establishKiosk]: администратор → планшет без
  ///    промежуточного `unauthenticated` (G-1 увёл бы на SCR-01); G-15 открывает SCR-51.
  /// 3. Файл БД администратора `pos_<admin>.db`: корень открывает БД планшета и закрывает прежнюю — после закрытия файл
  ///    удаляется ([AppDatabase.deleteUserDatabase]).
  /// 4. Закрепление (`KioskLock.enable`; без Device Owner, на Windows и в вебе — без действия: SCR-54 покажет
  ///    «Закрепление не включено») и снимок для `X-Kiosk-Lock`.
  /// Сам аварийный код не сохраняется. Access не `kind=kiosk` → `ArgumentError`, данные администратора не трогаются.
  Future<void> becomeKiosk({
    required String tabletId,
    String? tabletName,
    String? warehouseId,
    required String exitCode,
    required String accessToken,
    required String refreshToken,
  }) async {
    final claims = AccessTokenClaims.tryParse(accessToken);
    final String? kioskUserId = claims?.subject;
    if (claims?.kind != UserKind.kiosk.value || kioskUserId == null) {
      throw ArgumentError('becomeKiosk: access-токен не технического пользователя планшета');
    }
    final String? adminUserId = state.userId;
    final AppDatabase? adminDb = ref.read(appDatabaseProvider);
    _kioskEnrollment = true;
    _idle.stop();
    _stepUp.clear();
    _sessionId = null;
    for (final SecureKey key in SecureKey.values) {
      // `device.id` — устройство то же (08 §2.2); refresh перезапишет токен планшета.
      if (key == SecureKey.deviceId || key == SecureKey.refreshToken) continue;
      try {
        await _storage.delete(key);
      } on Object catch (e) {
        _log.warning('ключ администратора не удалён: ${e.runtimeType}');
      }
    }
    for (final hook in ref.read(sessionCleanupHooksProvider)) {
      try {
        await hook();
      } on Exception catch (e) {
        _log.warning('cleanup hook: ${e.runtimeType}');
      }
    }
    try {
      await establishKiosk(
        tabletId: tabletId,
        tabletName: tabletName,
        warehouseId: warehouseId,
        exitCode: exitCode,
        accessToken: accessToken,
        refreshToken: refreshToken,
      );
    } finally {
      _kioskEnrollment = false;
      _heldEnd = null;
    }
    if (!ref.mounted) return;
    _switchTokens = (access: accessToken, refresh: refreshToken);
    _switchedAt = ref.read(clockProvider).nowUtc();
    if (adminUserId != null && adminUserId != kioskUserId) await _deleteUserDatabase(adminUserId, adminDb);
    if (!ref.mounted) return;
    try {
      await ref.read(kioskLockProvider).enable();
    } on Object catch (e) {
      _log.warning('закрепление не включено: ${e.runtimeType}');
    }
    await refreshKioskLockStatus();
  }

  /// Файл БД [userId] после закрытия: корень (`userDatabase`) открывает БД нового пользователя сессии и закрывает
  /// прежнюю после такта — повторный [AppDatabase.close] ждёт того же закрытия. Пока прежняя БД ещё выдаётся
  /// (`appDatabaseProvider` не перешёл на нового пользователя) — открытый файл не удаляется.
  Future<void> _deleteUserDatabase(String userId, AppDatabase? db) async {
    if (!AppDatabase.isUserId(userId)) return;
    if (db != null) {
      for (int i = 0; i < 20 && ref.mounted && identical(ref.read(appDatabaseProvider), db); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      if (!ref.mounted) return;
      if (identical(ref.read(appDatabaseProvider), db)) {
        _log.warning('БД прежнего пользователя ещё открыта — файл не удалён');
        return;
      }
      await Future<void>.delayed(Duration.zero);
      try {
        await db.close();
      } on Object catch (e) {
        _log.warning('БД прежнего пользователя не закрыта: ${e.runtimeType}');
        return;
      }
    }
    try {
      if (!await AppDatabase.deleteUserDatabase(userId)) _log.warning('файл БД прежнего пользователя удалён не весь');
    } on Object catch (e) {
      _log.warning('файл БД прежнего пользователя не удалён: ${e.runtimeType}');
    }
  }

  /// Поздний отказ запроса администратора сразу после подключения ([kioskSwitchGrace]): токены планшета, стёртые
  /// AuthInterceptor, восстанавливаются, сессия планшета продолжается. `false` — окна нет (обычная обработка).
  bool _absorbStaleAdminEnd() {
    final ({String access, String refresh})? tokens = _switchTokens;
    final DateTime? at = _switchedAt;
    if (tokens == null || at == null) return false;
    if (!state.isKioskSession || ref.read(clockProvider).nowUtc().difference(at) > kioskSwitchGrace) {
      _switchTokens = null;
      _switchedAt = null;
      return false;
    }
    unawaited(_restoreSwitchTokens(tokens));
    return true;
  }

  Future<void> _restoreSwitchTokens(({String access, String refresh}) tokens) async {
    try {
      if (await _tokens.readRefreshToken() == null) {
        await _tokens.saveTokens(accessToken: tokens.access, refreshToken: tokens.refresh);
      }
    } on Object catch (e) {
      _log.warning('токены планшета не восстановлены: ${e.runtimeType}');
    }
  }

  /// SCR-51 «Планшет отключён администратором» показан — дальше SCR-01 (G-1, без `returnTo`).
  void acknowledgeKioskRevoked() {
    if (!ref.mounted || !state.kioskRevokedNotice) return;
    state = const SessionState(
      status: SessionStatus.unauthenticated,
      endReason: SessionEndReason.kioskRevoked,
      endAcknowledged: true,
    );
  }

  /// Перечитать состояние закрепления (`KioskLock.status`) для заголовка `X-Kiosk-Lock`: после восстановления и
  /// подключения, затем по heartbeat режима планшета. Исключений не бросает.
  Future<void> refreshKioskLockStatus() async {
    try {
      final status = await ref.read(kioskLockProvider).status();
      if (ref.mounted && _isKiosk) _kioskLockHeader = status.headerValue;
    } on Object catch (e) {
      _log.fine('KioskLock.status: ${e.runtimeType}');
    }
  }

  /// Склад планшета подтверждён `GET /me` (или ответом подключения) в этом процессе.
  bool _kioskTabletChecked = false;
  Future<void>? _kioskTabletCheck;

  /// Последняя попытка `GET /me` склада планшета: не чаще [kioskTabletRetry].
  DateTime? _kioskTabletTriedAt;

  /// Пауза между попытками `GET /me` склада планшета, пока склад не подтверждён.
  static const Duration kioskTabletRetry = Duration(seconds: 60);

  /// `GET /me` → `tablet.warehouseId` (SCR-54 мог сменить склад): склад для чтения кэша каталога и признак на
  /// устройстве обновляются. Вызывается после первого успешного запроса по складу планшета (первый экран режима,
  /// возврат связи), пока склад не подтверждён; без сессии планшета и после подтверждения — без запроса; попытки — не
  /// чаще [kioskTabletRetry]. Ошибки не бросает. Склад в запросы не подставляется.
  Future<void> refreshKioskTablet() {
    if (!ref.mounted || !state.isKioskSession || _kioskTabletChecked) return Future<void>.value();
    final Future<void>? running = _kioskTabletCheck;
    if (running != null) return running;
    final DateTime now = ref.read(clockProvider).nowUtc();
    final DateTime? tried = _kioskTabletTriedAt;
    if (tried != null && now.difference(tried) < kioskTabletRetry) return Future<void>.value();
    _kioskTabletTriedAt = now;
    return _kioskTabletCheck = _refreshKioskTablet().whenComplete(() => _kioskTabletCheck = null);
  }

  Future<void> _refreshKioskTablet() async {
    final String? warehouseId = await _api.kioskTabletWarehouseId();
    if (warehouseId == null || !ref.mounted || !state.isKioskSession) return;
    _kioskTabletChecked = true;
    ref.read(kioskTabletWarehouseProvider.notifier).set(warehouseId);
    try {
      final KioskMarkerStore store = ref.read(kioskMarkerStoreProvider);
      final KioskMarker? marker = await store.read();
      if (marker != null && marker.warehouseId != warehouseId) await store.write(marker.withWarehouse(warehouseId));
    } on Object catch (e) {
      _log.warning('склад планшета не записан: ${e.runtimeType}');
    }
  }

  /// `X-Kiosk-Lock` запроса: только у сессии планшета и только после первого снимка закрепления.
  String? _kioskLockHeaderValue() {
    if (!ref.mounted || !state.isKioskSession) return null;
    return _kioskLockHeader;
  }

  // --- KioskSessionHooks (AuthInterceptor) ---

  @override
  bool get isKioskSession => ref.mounted && state.isKioskSession;

  @override
  void kioskForbidden(String code, String? reason) {
    if (!ref.mounted || !_isKiosk) return;
    final access = KioskAccess.fromForbidden(code, reason);
    if (access != null) ref.read(kioskAccessProvider.notifier).denied(access);
  }

  @override
  void kioskRequestSucceeded(String path) {
    if (!ref.mounted || !state.isKioskSession) return;
    // «Склад планшета недоступен» снимает только запрос по складу (02 SCR-51.7): `GET /settings/public` heartbeat,
    // `/me`, единицы и склады склад не проверяют.
    ref.read(kioskAccessProvider.notifier).succeeded(warehouseScoped: kioskWarehouseScopedPath(path));
    // Запрос по складу планшета прошёл (первый экран режима, возврат связи), а склад ещё не подтверждён в этом процессе
    // (холодный старт без сети) — `GET /me`. Heartbeat и прочие запросы его не вызывают: их успех при отказе прочих
    // маршрутов не должен менять состояние SCR-51.
    if (!_kioskTabletChecked && kioskWarehouseScopedPath(path)) unawaited(refreshKioskTablet());
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
    final reason = SessionEndReason.fromServer(signal.code, signal.reason);
    // Подключение этого устройства планшетом (SCR-54): сессию администратора отозвал сам сервер — до «Готово» конец
    // удерживается; сразу после подключения поздний отказ запроса администратора сессию планшета не завершает.
    if (_kioskEnrollment) {
      _heldEnd ??= reason == SessionEndReason.kioskRevoked ? SessionEndReason.revoked : reason;
      return;
    }
    if (reason != SessionEndReason.kioskRevoked && _absorbStaleAdminEnd()) return;
    // `401 KIOSK_REVOKED` (запрос или `/auth/refresh`): конец режима планшета, а не «Подключите заново».
    if (reason == SessionEndReason.kioskRevoked) {
      unawaited(endKiosk(reason));
      return;
    }
    unawaited(_endFromServer(reason));
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
