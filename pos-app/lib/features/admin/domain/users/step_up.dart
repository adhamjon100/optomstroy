// Step-up для критических действий SCR-45 (08 §2.12, §4.1.7; ядро §18.2 п.6, §19.3; 02 §0.5).
//
// Порт: UI получает токен через `AdminStepUpPrompter` (admin_providers.dart) — StepUpDialog из
// core/session, когда он появится (RM-D-007/009); до того — резервный диалог фичи.
// Токен многоразовый 15 мин в области операции; хранится только в памяти экрана, не логируется.
// Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';

/// Значения `operation` (`StepUpOperation` OpenAPI), которые использует SCR-45.
abstract final class AdminStepUpOperations {
  static const String rolesAssign = 'users.roles.assign';
  static const String usersManage = 'users.manage';
  static const String pinReset = 'users.pin.reset';
  static const String emergencyCode = 'users.emergency_code.issue';
  static const String sessionRevokeAny = 'session.revoke.any';
  static const String invitationsManage = 'invitations.manage';
  static const String linkResolve = 'customer.link.resolve';
}

/// Запрос подтверждения: `operation` — из `403 STEP_UP_REQUIRED.stepUp.operation` без изменений.
/// Методы R1 — [StepUpMethod.pin], [StepUpMethod.otp] (биометрия — R2, ядро §19.3).
final class StepUpChallenge {
  const StepUpChallenge({
    required this.operation,
    this.allowedMethods = const [StepUpMethod.pin, StepUpMethod.otp],
    this.beforeRequest = false,
  });

  final String operation;
  final List<StepUpMethod> allowedMethods;

  /// Подтверждение запрашивается ДО запроса (аварийный код, UI-45-023), а не по ответу `403`.
  /// По ответу `403` при смонтированном StepUpDialog core/session диалог уже показал AuthInterceptor.
  final bool beforeRequest;

  @override
  bool operator ==(Object other) =>
      other is StepUpChallenge &&
      other.operation == operation &&
      other.beforeRequest == beforeRequest &&
      other.allowedMethods.length == allowedMethods.length &&
      other.allowedMethods.every(allowedMethods.contains);

  @override
  int get hashCode => Object.hash(operation, beforeRequest, Object.hashAll(allowedMethods));

  @override
  String toString() => 'StepUpChallenge($operation, ${allowedMethods.map((m) => m.value).toList()})';
}

/// Выданный `stepUpToken` (`AuthStepUpToken`).
final class StepUpGrant {
  const StepUpGrant({required this.token, required this.expiresAt, this.method});

  final String token;
  final DateTime expiresAt;
  final StepUpMethod? method;

  /// Запас 5 с до истечения, чтобы не отправлять почти просроченный токен.
  bool isValidAt(DateTime nowUtc) => expiresAt.toUtc().isAfter(nowUtc.add(const Duration(seconds: 5)));

  @override
  String toString() => 'StepUpGrant(***, ${method?.value})';
}

/// Шаг 1 OTP-подтверждения (`202 AuthOtpChallengeIssued`).
final class StepUpOtpChallenge {
  const StepUpOtpChallenge({required this.challengeId, this.resendAfterSec = 60, this.otpTtlSec = 300});

  final String challengeId;
  final int resendAfterSec;
  final int otpTtlSec;

  @override
  String toString() => 'StepUpOtpChallenge($challengeId)';
}

/// `POST /auth/step-up` (порт data-слоя; используется резервным диалогом фичи).
abstract interface class StepUpGateway {
  Future<Result<StepUpGrant>> withPin(String operation, String pin);

  Future<Result<StepUpOtpChallenge>> requestOtp(String operation);

  Future<Result<StepUpGrant>> withOtp(String operation, {required String challengeId, required String code});
}

/// Итог действия с подтверждением.
sealed class AdminActionResult<T> {
  const AdminActionResult();

  T? get valueOrNull => switch (this) {
    ActionDone<T>(:final value) => value,
    _ => null,
  };

  Failure? get failureOrNull => switch (this) {
    ActionFailed<T>(:final failure) => failure,
    _ => null,
  };
}

final class ActionDone<T> extends AdminActionResult<T> {
  const ActionDone(this.value);

  final T value;
}

final class ActionFailed<T> extends AdminActionResult<T> {
  const ActionFailed(this.failure);

  final Failure failure;
}

/// Пользователь закрыл StepUpDialog — запрос не отправлялся или не повторялся.
final class ActionCancelled<T> extends AdminActionResult<T> {
  const ActionCancelled();
}

/// Получить токен у пользователя (`null` — отмена).
typedef StepUpObtainer = Future<StepUpGrant?> Function(StepUpChallenge challenge);

/// Выполняет вызов API с step-up (02 SCR-45.4, диаграмма «смена роли»):
/// 1) действующий токен области — из памяти; при [proactive] без токена — сначала StepUpDialog;
/// 2) `403 STEP_UP_REQUIRED` → StepUpDialog с `operation` из ответа → один повтор ТЕМ ЖЕ вызовом
///    (тот же `Idempotency-Key` — его фиксирует вызывающий);
/// 3) `409 IDEMPOTENCY_IN_PROGRESS` → ожидание `Retry-After` (по умолчанию 2 с) и один повтор (SCR-45.11).
final class StepUpRunner {
  StepUpRunner({required DateTime Function() nowUtc, Future<void> Function(Duration delay)? sleep})
    : _now = nowUtc,
      _sleep = sleep ?? Future<void>.delayed;

  final DateTime Function() _now;
  final Future<void> Function(Duration delay) _sleep;
  final Map<String, StepUpGrant> _grants = {};

  /// Действующий токен области [operation] или `null`.
  String? tokenFor(String operation) {
    final grant = _grants[operation];
    if (grant == null) return null;
    if (!grant.isValidAt(_now())) {
      _grants.remove(operation);
      return null;
    }
    return grant.token;
  }

  /// Забыть все токены (смена пользователя, уход с экрана, сворачивание).
  void clear() => _grants.clear();

  Future<AdminActionResult<T>> run<T>({
    required String operation,
    required Future<Result<T>> Function(String? stepUpToken) call,
    required StepUpObtainer obtain,
    bool proactive = false,
    List<StepUpMethod> methods = const [StepUpMethod.pin, StepUpMethod.otp],
  }) async {
    var token = tokenFor(operation);
    if (token == null && proactive) {
      final grant = await obtain(StepUpChallenge(operation: operation, allowedMethods: methods, beforeRequest: true));
      if (grant == null) return const ActionCancelled();
      _grants[operation] = grant;
      token = grant.token;
    }
    var result = await _callOnce(call, token);
    final failure = result.failureOrNull;
    if (failure is AuthFailure && failure.reason == AuthReason.stepUpRequired) {
      final serverOperation = failure.stepUpOperation ?? operation;
      _grants
        ..remove(operation)
        ..remove(serverOperation);
      final grant = await obtain(StepUpChallenge(operation: serverOperation, allowedMethods: methods));
      if (grant == null) return const ActionCancelled();
      _grants[serverOperation] = grant;
      result = await _callOnce(call, grant.token);
    }
    return switch (result) {
      Success<T>(:final value) => ActionDone<T>(value),
      FailureResult<T>(:final failure) => ActionFailed<T>(failure),
    };
  }

  Future<Result<T>> _callOnce<T>(Future<Result<T>> Function(String? token) call, String? token) async {
    final result = await call(token);
    final failure = result.failureOrNull;
    if (failure is ConflictFailure && failure.kind == ConflictKind.idempotencyInProgress) {
      await _sleep(failure.retryAfter ?? const Duration(seconds: 2));
      return call(token);
    }
    return result;
  }
}
