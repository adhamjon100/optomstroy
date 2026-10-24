// Централизованная модель ошибок (06 §6.8, R3 §8; SRC-D-026).
//
// L-9 / FL-01: файл чистый Dart — без flutter, dio, drift, riverpod.
// Превращение DioException + problem+json в Failure — только
// core/network/error_mapper.dart (используется слоем data).
// Тексты для пользователя — только ARB (`error_<code>`, D-38); здесь
// хранятся машинные коды и requestId, без ПДн (NFR-LOG-001).
import 'package:optomstroy/core/enums.dart';

/// Ошибка поля из problem+json `errors[]` (08 §2.4, ProblemFieldError).
final class FieldError {
  const FieldError({required this.field, required this.rule, this.message = '', this.params = const {}});

  /// JSON-pointer-подобный путь (`items[1].quantity`).
  final String field;

  /// Машинное правило (`money_format`, `qty_multiple`, …), не локализуется.
  final String rule;

  /// Локализованное сервером сообщение (Accept-Language). Для логов не использовать.
  final String message;

  /// Параметры правила (например, `{factor: "6"}`).
  final Map<String, Object?> params;

  @override
  String toString() => 'FieldError($field, $rule)';
}

/// Базовый тип ошибки. Подтипы закрыты (sealed) — `switch` по ним исчерпывающий.
sealed class Failure {
  const Failure({this.requestId});

  /// `X-Request-Id` ответа (или запроса) — для поддержки (06 §6.7).
  final String? requestId;
}

/// Почему запрос не дошёл до сервера или ответ не получен.
enum NetworkFailureKind {
  /// Нет сетевого интерфейса или соединение не установлено → `offline`.
  offline,

  /// Таймаут ответа при живом соединении → `serverDown` (06 §6.7).
  timeout,

  /// `502/503/504` без problem+json — сервер недоступен.
  serverUnavailable,
}

/// Нет сети / таймаут / сервер недоступен.
final class NetworkFailure extends Failure {
  const NetworkFailure(this.kind, {this.outcomeUnknown = false, super.requestId});

  final NetworkFailureKind kind;

  /// Запрос мог дойти до сервера, а ответ потерян (таймаут ответа после отправки).
  /// Для операций с `Idempotency-Key` UI показывает «Результат операции не
  /// подтверждён» и «Проверить результат» тем же ключом (06 §6.7, 08 §2.10).
  final bool outcomeUnknown;

  @override
  String toString() => 'NetworkFailure(${kind.name}, outcomeUnknown: $outcomeUnknown, requestId: $requestId)';
}

/// Ошибка сервера с кодом из 08 §2.4, не попавшая в специализированные подтипы.
final class ServerFailure extends Failure {
  const ServerFailure({
    required this.code,
    required this.status,
    this.errors = const [],
    this.retryAfter,
    this.reason,
    this.details = const {},
    super.requestId,
  });

  /// Значение `Problem.code` как пришло (неизвестный код — как `INTERNAL`, 08 §2.4).
  final String code;

  /// HTTP-статус.
  final int status;
  final List<FieldError> errors;

  /// `Retry-After` / `retryAfter`, если сервер его прислал.
  final Duration? retryAfter;

  /// Машинная причина `Problem.reason`, если есть.
  final String? reason;

  /// Сырые поля problem+json для фичи-владельца (этап F: `limitPercent`, `requiresRole` у
  /// `DISCOUNT_LIMIT_EXCEEDED`; `creditReason`, `limitRemaining`, `asOf` у долга; `onec` у `ONEC_REJECTED`).
  /// Не логируется.
  final Map<String, Object?> details;

  /// Код из словаря 08 §2.4; `null` — неизвестный код (совместимость вперёд).
  ProblemCode? get problemCode => ProblemCode.tryParse(code);

  @override
  String toString() => 'ServerFailure($code, $status, requestId: $requestId)';
}

/// Причины ошибок аутентификации (08 §2.2, ядро §17.4, §18.2 п.5).
enum AuthReason {
  unauthenticated,
  tokenStale,
  sessionRevoked,
  deviceMismatch,
  stepUpRequired,
  otpInvalid,
  otpExpired,
  otpLocked,
  otpRateLimited,
  registrationTokenInvalid,
  pinInvalid,
  pinLocked,
  unlockRequired,
}

/// Ошибка аутентификации / сессии / OTP / PIN.
final class AuthFailure extends Failure {
  const AuthFailure(
    this.reason, {
    this.attemptsLeft,
    this.retryAfter,
    this.stepUpOperation,
    this.lockedUntil,
    this.unlockReason,
    super.requestId,
  });

  final AuthReason reason;

  /// `attemptsLeft` (OTP_INVALID, PIN_INVALID).
  final int? attemptsLeft;
  final Duration? retryAfter;

  /// `stepUp.operation` для `STEP_UP_REQUIRED` — передаётся в `/auth/step-up` без изменений.
  final String? stepUpOperation;

  /// `Problem.until` у `423 PIN_LOCKED` — момент снятия блокировки PIN (UTC); до него вход только по OTP.
  final DateTime? lockedUntil;

  /// `Problem.reason` у `401 UNLOCK_REQUIRED` (`idle_lock` | `refresh_replay` | `emergency_code`); строка контракта,
  /// неизвестное значение сохраняется как есть — обработка та же (SCR-08).
  final String? unlockReason;

  @override
  String toString() => 'AuthFailure(${reason.name}, requestId: $requestId)';
}

/// `VALIDATION_FAILED` (400/422).
final class ValidationFailure extends Failure {
  const ValidationFailure({this.errors = const [], super.requestId});

  final List<FieldError> errors;

  @override
  String toString() => 'ValidationFailure(${errors.length} errors, requestId: $requestId)';
}

/// Виды конфликтов (06 §6.8).
enum ConflictKind {
  versionConflict,
  priceChanged,
  stockInsufficient,
  variantUnavailable,
  qtyNotMultiple,
  qtyBelowMin,
  orderStateInvalid,
  paymentStateInvalid,
  idempotencyKeyReused,
  idempotencyInProgress,
  customerLinkConflict,
  customerDuplicateSuspected,
  syncAlreadyRunning,
  phoneAlreadyRegistered,
}

/// Конфликт состояния: версия, цены/остатки, статус документа, идемпотентность.
final class ConflictFailure extends Failure {
  const ConflictFailure(
    this.kind, {
    this.currentStatus,
    this.reason,
    this.retryAfter,
    this.details = const {},
    super.requestId,
  });

  final ConflictKind kind;

  /// `currentStatus` (ORDER_STATE_INVALID / PAYMENT_STATE_INVALID).
  final String? currentStatus;

  /// `reason` (например, `possible_duplicate`).
  final String? reason;
  final Duration? retryAfter;

  /// Сырые поля problem+json для фичи-владельца (`current`, `conflicts`,
  /// `possibleDuplicateOrderId`, …). Не логируется.
  final Map<String, Object?> details;

  @override
  String toString() => 'ConflictFailure(${kind.name}, requestId: $requestId)';
}

/// `ONEC_UNAVAILABLE` — 1С не ответила (08 §2.10).
final class OnecUnavailableFailure extends Failure {
  const OnecUnavailableFailure({this.retryAfter, this.reason, super.requestId});

  final Duration? retryAfter;

  /// `Problem.reason` (например, [catalogNotLoadedReason]); `null` — не передан.
  final String? reason;

  /// `503 ONEC_UNAVAILABLE reason=catalog_not_loaded` корзины (08 §4.7.1 «Уточнения» п. 2; OpenAPI 1.2.0):
  /// реплика каталога 1С не загружена, `Retry-After: 60`.
  static const String catalogNotLoadedReason = 'catalog_not_loaded';

  bool get catalogNotLoaded => reason == catalogNotLoadedReason;

  @override
  String toString() => 'OnecUnavailableFailure(requestId: $requestId)';
}

/// Причина отказа в доступе (06 §6.11 noPermission).
enum PermissionReason {
  /// `403 FORBIDDEN` — роль/право.
  role,

  /// Отказ ОС (камера, биометрия) — выставляет слой платформы.
  osPermission,
}

/// `FORBIDDEN` или отказ ОС в разрешении.
final class PermissionFailure extends Failure {
  const PermissionFailure({this.reason = PermissionReason.role, this.serverReason, super.requestId});

  final PermissionReason reason;

  /// `Problem.reason` (например, `pin_not_set`).
  final String? serverReason;

  @override
  String toString() => 'PermissionFailure(${reason.name}, requestId: $requestId)';
}

/// `426 APP_UPDATE_REQUIRED` — блокирующий SCR-90 (D-46, RM-C-015).
final class AppUpdateRequiredFailure extends Failure {
  const AppUpdateRequiredFailure({this.minVersion, super.requestId});

  /// Минимальная версия для платформы клиента (`X-Min-App-Version` / `minVersion`).
  final String? minVersion;

  @override
  String toString() => 'AppUpdateRequiredFailure($minVersion, requestId: $requestId)';
}

/// Непредвиденная ошибка (в том числе ошибка разбора ответа).
final class UnknownFailure extends Failure {
  const UnknownFailure({this.cause, super.requestId});

  /// Исходная ошибка — только для отладки; в лог пишется тип, не текст.
  final Object? cause;

  @override
  String toString() => 'UnknownFailure(${cause.runtimeType}, requestId: $requestId)';
}
