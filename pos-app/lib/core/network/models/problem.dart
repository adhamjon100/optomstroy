// DTO `Problem` (RFC 9457 problem+json) — contracts/openapi/pos-api.v1.yaml
// components.schemas.Problem, ProblemFieldError (08 §2.4, §3.3).
// Ручной freezed-DTO вместо openapi-generator (ADR-085): поля сверяет
// test/core/network/models/dto_schema_test.dart.
// Значения enum — строками: неизвестное значение не ломает разбор (08 §2.11).
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/models/money_dto.dart';

part 'problem.freezed.dart';
part 'problem.g.dart';

@freezed
abstract class Problem with _$Problem {
  const factory Problem({
    required String type,
    required String title,
    required int status,
    required String code,
    required String requestId,
    String? detail,
    String? instance,
    List<ProblemFieldError>? errors,

    /// `CartConflict[]` — типизирует фича cart (по мере фич, ADR-085). Разбор терпимый ([_objectList]).
    @JsonKey(fromJson: _objectList) List<Map<String, dynamic>>? conflicts,
    int? retryAfter,
    int? attemptsLeft,
    ProblemStepUp? stepUp,
    Map<String, dynamic>? current,
    String? currentStatus,
    List<String>? allowedActions,
    String? resource,
    String? reason,

    /// `423 PIN_LOCKED`: момент снятия блокировки PIN (ISO-8601, 08 §2.4; 09 §9.6; OpenAPI 1.1.0).
    DateTime? until,
    String? possibleDuplicateOrderId,

    /// `409 ORDER_STATE_INVALID reason=possible_duplicate`: номер POS и момент создания похожего заказа (UI-21-029;
    /// 08 §4.8.1 «Уточнения POST /orders» п. 4; OpenAPI 1.2.0). Сервер этапа F ещё не передаёт — `null`.
    /// Момент — строкой (date-time): неразбираемое значение не должно ломать разбор всей ошибки (08 §2.11).
    String? possibleDuplicatePublicNumber,
    String? possibleDuplicateCreatedAt,

    /// `422 PRICE_CHANGED` по `previewToken`: итог предпросмотра и текущий итог сервера (08 §2.4 «Уточнения кодов
    /// ошибок по реализации этапа F» п. 1; OpenAPI 1.2.0), вместе с `reason` (`preview_*`).
    MoneyDto? previewTotal,
    MoneyDto? total,
    String? openPaymentId,
    String? limitPercent,
    String? requiresRole,
    String? creditReason,
    MoneyDto? limitRemaining,
    MoneyDto? overdueAmount,
    DateTime? asOf,

    /// `409 CUSTOMER_DUPLICATE_SUSPECTED` (08 §4.11.2): разбор терпимый ([_objectList], FQ-FND-03).
    @JsonKey(fromJson: _objectList) List<Map<String, dynamic>>? candidates,
    String? runId,
    String? minVersion,
    String? storeUrl,
    ProblemOnec? onec,
  }) = _Problem;

  const Problem._();

  factory Problem.fromJson(Map<String, dynamic> json) => _$ProblemFromJson(json);

  /// Разбор тела ответа, если это problem+json с полем `code`; иначе `null`.
  static Problem? tryParse(Object? data) {
    if (data is! Map<String, dynamic> || data['code'] is! String) return null;
    try {
      return Problem.fromJson(data);
    } on Object {
      return null;
    }
  }

  /// Только `code` из тела (без полного разбора) — для интерсепторов.
  static String? codeOf(Object? data) => data is Map && data['code'] is String ? data['code'] as String : null;

  /// Код из словаря 08 §2.4; `null` — неизвестный (обрабатывается как INTERNAL того же класса).
  ProblemCode? get problemCode => ProblemCode.tryParse(code);

  /// Причина `401 UNLOCK_REQUIRED` (`reason`, `x-unlock-required-reasons`); у других кодов — `null`.
  UnlockRequiredReason? get unlockReason =>
      code == ProblemCode.unlockRequired.value ? UnlockRequiredReason.parse(reason) : null;
}

/// `Problem.reason` у `401 UNLOCK_REQUIRED` (08 §2.4; OpenAPI 1.1.0 `x-unlock-required-reasons`).
/// Поле в контракте — строка: неизвестное или отсутствующее значение — [unknown], клиент ведёт себя как при
/// любой разблокировке — overlay SCR-08 (08 §2.11).
enum UnlockRequiredReason {
  /// Простой сессии (Windows без `unlocked_until`, 09 §8.8).
  idleLock('idle_lock'),

  /// Повтор refresh в окне грации — подтвердить PIN/биометрией (09 §8.3).
  refreshReplay('refresh_replay'),

  /// Вход по аварийному коду администратора — нужен PIN (09 §6.13).
  emergencyCode('emergency_code'),

  /// Значение, неизвестное этой сборке.
  unknown('unknown');

  const UnlockRequiredReason(this.value);

  final String value;

  static UnlockRequiredReason parse(String? raw) =>
      values.firstWhere((UnlockRequiredReason r) => r.value == raw && r != unknown, orElse: () => unknown);
}

/// Терпимый разбор массива объектов расширения problem+json (`candidates[]`, `conflicts[]`; FQ-FND-03, 08 §2.11):
/// элементы, не являющиеся объектами, пропускаются — один неверный элемент не делает всю ошибку неразбираемой
/// (иначе `INTERNAL` вместо кода сервера). Не массив — `null`.
List<Map<String, dynamic>>? _objectList(Object? raw) => raw is List
    ? <Map<String, dynamic>>[
        for (final Object? e in raw)
          if (e is Map) <String, dynamic>{for (final MapEntry<Object?, Object?> f in e.entries) '${f.key}': f.value},
      ]
    : null;

@freezed
abstract class ProblemFieldError with _$ProblemFieldError {
  const factory ProblemFieldError({
    required String field,
    required String message,
    required String rule,
    Map<String, dynamic>? params,
  }) = _ProblemFieldError;

  factory ProblemFieldError.fromJson(Map<String, dynamic> json) => _$ProblemFieldErrorFromJson(json);
}

/// `Problem.stepUp` (08 §2.12).
@freezed
abstract class ProblemStepUp with _$ProblemStepUp {
  const factory ProblemStepUp({String? operation, List<String>? allowedMethods}) = _ProblemStepUp;

  factory ProblemStepUp.fromJson(Map<String, dynamic> json) => _$ProblemStepUpFromJson(json);
}

/// `Problem.onec` (ONEC_REJECTED).
@freezed
abstract class ProblemOnec with _$ProblemOnec {
  const factory ProblemOnec({String? code, String? message}) = _ProblemOnec;

  factory ProblemOnec.fromJson(Map<String, dynamic> json) => _$ProblemOnecFromJson(json);
}

/// `Warning` из `warnings[]` успешного ответа (операция применена, не повторять).
@freezed
abstract class ApiWarning with _$ApiWarning {
  const factory ApiWarning({required String code, required String message}) = _ApiWarning;

  const ApiWarning._();

  factory ApiWarning.fromJson(Map<String, dynamic> json) => _$ApiWarningFromJson(json);

  WarningCode? get warningCode => WarningCode.tryParse(code);
}
