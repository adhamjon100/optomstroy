// Связь AuthInterceptor ↔ core/session (RM-D-009): сеть не знает о SessionController,
// контроллер подключается к интерсептору после создания Dio (`AuthInterceptor.attachHooks`).
//
// Через этот порт интерсептор:
// - ждёт разблокировки (idle/фон/вручную/`401 UNLOCK_REQUIRED`) — запросы под overlay SCR-08 не уходят;
// - сообщает о завершении сессии (`401 SESSION_REVOKED`, `409 DEVICE_MISMATCH`) с причиной;
// - получает `stepUpToken` для `403 STEP_UP_REQUIRED` (кэш области 15 мин или StepUpDialog).
//
// Значения токенов наружу (в логи) не попадают.

/// Завершение сессии сервером: машинный код и `Problem.reason` (без ПДн).
final class SessionEndSignal {
  const SessionEndSignal({required this.code, this.reason});

  /// `SESSION_REVOKED` | `DEVICE_MISMATCH` | `REFRESH_REJECTED` (refresh отклонён без тела).
  final String code;

  /// `reuse_detected`, `refresh_replay`, `admin`, `expired`, … (08 §2.4, 07 §5.9).
  final String? reason;

  /// Код для отказа `/auth/refresh` без разобранной причины.
  static const String refreshRejected = 'REFRESH_REJECTED';

  @override
  String toString() => 'SessionEndSignal($code, $reason)';
}

/// Требование step-up из `403 STEP_UP_REQUIRED` (08 §2.12).
final class StepUpChallenge {
  const StepUpChallenge({required this.operation, this.allowedMethods = const <String>['pin', 'otp']});

  /// `stepUp.operation` ответа — клиент передаёт его в `POST /auth/step-up` без изменений.
  final String operation;

  /// `stepUp.allowedMethods` (R1 — `pin`, `otp`).
  final List<String> allowedMethods;

  @override
  String toString() => 'StepUpChallenge($operation, $allowedMethods)';
}

/// Порт сессии для [AuthInterceptor] (реализует core/session).
abstract interface class AuthSessionHooks {
  /// Сессия заблокирована (SCR-08 overlay) — новые запросы ждут разблокировки.
  bool get isLocked;

  /// Дождаться разблокировки: `true` — разблокировано, `false` — сессия завершена.
  Future<bool> waitUntilUnlocked();

  /// Сервер ответил `UNLOCK_REQUIRED` (запрос или refresh): заблокировать и дождаться разблокировки.
  Future<bool> unlockRequired();

  /// Сервер завершил сессию; секреты уже удалены интерсептором (TokenStore.clearSession).
  void sessionEnded(SessionEndSignal signal);

  /// Действующий `stepUpToken`, область которого покрывает [operation] (или `null`).
  String? stepUpTokenFor(String operation);

  /// Сервер отверг [token] для [operation] (истёк / вне области / отозван) — убрать из кэша.
  void discardStepUpToken(String operation, String token);

  /// Показать StepUpDialog и вернуть новый `stepUpToken`; `null` — пользователь отменил.
  Future<String?> requestStepUp(StepUpChallenge challenge);
}

/// Ключи `RequestOptions.extra` сессионного слоя (дополняют `RequestExtra`).
abstract final class SessionRequestExtra {
  /// `operation` step-up, известная слою data заранее: интерсептор подставит действующий
  /// `X-Step-Up-Token` из кэша области без лишнего `403` (08 §2.12).
  static const String stepUpOperation = 'optomstroy.stepUpOperation';

  /// `true` — запрос не ждёт разблокировки (выход с экрана блокировки «Сменить аккаунт»).
  static const String bypassLock = 'optomstroy.bypassLock'; // check-secrets: allow — ключ Options.extra

  /// Служебные: число повторов после `STEP_UP_REQUIRED`, показан ли StepUpDialog, повтор после разблокировки.
  static const String stepUpAttempts = 'optomstroy.stepUpAttempts';
  static const String stepUpPrompted = 'optomstroy.stepUpPrompted';
  static const String unlockRetried = 'optomstroy.unlockRetried';
}
