// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'problem.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Problem _$ProblemFromJson(Map<String, dynamic> json) => _Problem(
  type: json['type'] as String,
  title: json['title'] as String,
  status: (json['status'] as num).toInt(),
  code: json['code'] as String,
  requestId: json['requestId'] as String,
  detail: json['detail'] as String?,
  instance: json['instance'] as String?,
  errors: (json['errors'] as List<dynamic>?)
      ?.map((e) => ProblemFieldError.fromJson(e as Map<String, dynamic>))
      .toList(),
  conflicts: _objectList(json['conflicts']),
  retryAfter: (json['retryAfter'] as num?)?.toInt(),
  attemptsLeft: (json['attemptsLeft'] as num?)?.toInt(),
  stepUp: json['stepUp'] == null
      ? null
      : ProblemStepUp.fromJson(json['stepUp'] as Map<String, dynamic>),
  current: json['current'] as Map<String, dynamic>?,
  currentStatus: json['currentStatus'] as String?,
  allowedActions: (json['allowedActions'] as List<dynamic>?)
      ?.map((e) => e as String)
      .toList(),
  resource: json['resource'] as String?,
  reason: json['reason'] as String?,
  until: json['until'] == null ? null : DateTime.parse(json['until'] as String),
  possibleDuplicateOrderId: json['possibleDuplicateOrderId'] as String?,
  possibleDuplicatePublicNumber:
      json['possibleDuplicatePublicNumber'] as String?,
  possibleDuplicateCreatedAt: json['possibleDuplicateCreatedAt'] as String?,
  previewTotal: json['previewTotal'] == null
      ? null
      : MoneyDto.fromJson(json['previewTotal'] as Map<String, dynamic>),
  total: json['total'] == null
      ? null
      : MoneyDto.fromJson(json['total'] as Map<String, dynamic>),
  openPaymentId: json['openPaymentId'] as String?,
  limitPercent: json['limitPercent'] as String?,
  requiresRole: json['requiresRole'] as String?,
  creditReason: json['creditReason'] as String?,
  limitRemaining: json['limitRemaining'] == null
      ? null
      : MoneyDto.fromJson(json['limitRemaining'] as Map<String, dynamic>),
  overdueAmount: json['overdueAmount'] == null
      ? null
      : MoneyDto.fromJson(json['overdueAmount'] as Map<String, dynamic>),
  asOf: json['asOf'] == null ? null : DateTime.parse(json['asOf'] as String),
  candidates: _objectList(json['candidates']),
  runId: json['runId'] as String?,
  minVersion: json['minVersion'] as String?,
  storeUrl: json['storeUrl'] as String?,
  onec: json['onec'] == null
      ? null
      : ProblemOnec.fromJson(json['onec'] as Map<String, dynamic>),
);

Map<String, dynamic> _$ProblemToJson(_Problem instance) => <String, dynamic>{
  'type': instance.type,
  'title': instance.title,
  'status': instance.status,
  'code': instance.code,
  'requestId': instance.requestId,
  'detail': instance.detail,
  'instance': instance.instance,
  'errors': instance.errors,
  'conflicts': instance.conflicts,
  'retryAfter': instance.retryAfter,
  'attemptsLeft': instance.attemptsLeft,
  'stepUp': instance.stepUp,
  'current': instance.current,
  'currentStatus': instance.currentStatus,
  'allowedActions': instance.allowedActions,
  'resource': instance.resource,
  'reason': instance.reason,
  'until': instance.until?.toIso8601String(),
  'possibleDuplicateOrderId': instance.possibleDuplicateOrderId,
  'possibleDuplicatePublicNumber': instance.possibleDuplicatePublicNumber,
  'possibleDuplicateCreatedAt': instance.possibleDuplicateCreatedAt,
  'previewTotal': instance.previewTotal,
  'total': instance.total,
  'openPaymentId': instance.openPaymentId,
  'limitPercent': instance.limitPercent,
  'requiresRole': instance.requiresRole,
  'creditReason': instance.creditReason,
  'limitRemaining': instance.limitRemaining,
  'overdueAmount': instance.overdueAmount,
  'asOf': instance.asOf?.toIso8601String(),
  'candidates': instance.candidates,
  'runId': instance.runId,
  'minVersion': instance.minVersion,
  'storeUrl': instance.storeUrl,
  'onec': instance.onec,
};

_ProblemFieldError _$ProblemFieldErrorFromJson(Map<String, dynamic> json) =>
    _ProblemFieldError(
      field: json['field'] as String,
      message: json['message'] as String,
      rule: json['rule'] as String,
      params: json['params'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$ProblemFieldErrorToJson(_ProblemFieldError instance) =>
    <String, dynamic>{
      'field': instance.field,
      'message': instance.message,
      'rule': instance.rule,
      'params': instance.params,
    };

_ProblemStepUp _$ProblemStepUpFromJson(Map<String, dynamic> json) =>
    _ProblemStepUp(
      operation: json['operation'] as String?,
      allowedMethods: (json['allowedMethods'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$ProblemStepUpToJson(_ProblemStepUp instance) =>
    <String, dynamic>{
      'operation': instance.operation,
      'allowedMethods': instance.allowedMethods,
    };

_ProblemOnec _$ProblemOnecFromJson(Map<String, dynamic> json) => _ProblemOnec(
  code: json['code'] as String?,
  message: json['message'] as String?,
);

Map<String, dynamic> _$ProblemOnecToJson(_ProblemOnec instance) =>
    <String, dynamic>{'code': instance.code, 'message': instance.message};

_ApiWarning _$ApiWarningFromJson(Map<String, dynamic> json) => _ApiWarning(
  code: json['code'] as String,
  message: json['message'] as String,
);

Map<String, dynamic> _$ApiWarningToJson(_ApiWarning instance) =>
    <String, dynamic>{'code': instance.code, 'message': instance.message};
