// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'problem.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Problem {

 String get type; String get title; int get status; String get code; String get requestId; String? get detail; String? get instance; List<ProblemFieldError>? get errors;/// `CartConflict[]` — типизирует фича cart (по мере фич, ADR-085). Разбор терпимый ([_objectList]).
@JsonKey(fromJson: _objectList) List<Map<String, dynamic>>? get conflicts; int? get retryAfter; int? get attemptsLeft; ProblemStepUp? get stepUp; Map<String, dynamic>? get current; String? get currentStatus; List<String>? get allowedActions; String? get resource; String? get reason;/// `423 PIN_LOCKED`: момент снятия блокировки PIN (ISO-8601, 08 §2.4; 09 §9.6; OpenAPI 1.1.0).
 DateTime? get until; String? get possibleDuplicateOrderId;/// `409 ORDER_STATE_INVALID reason=possible_duplicate`: номер POS и момент создания похожего заказа (UI-21-029;
/// 08 §4.8.1 «Уточнения POST /orders» п. 4; OpenAPI 1.2.0). Сервер этапа F ещё не передаёт — `null`.
/// Момент — строкой (date-time): неразбираемое значение не должно ломать разбор всей ошибки (08 §2.11).
 String? get possibleDuplicatePublicNumber; String? get possibleDuplicateCreatedAt;/// `422 PRICE_CHANGED` по `previewToken`: итог предпросмотра и текущий итог сервера (08 §2.4 «Уточнения кодов
/// ошибок по реализации этапа F» п. 1; OpenAPI 1.2.0), вместе с `reason` (`preview_*`).
 MoneyDto? get previewTotal; MoneyDto? get total; String? get openPaymentId; String? get limitPercent; String? get requiresRole; String? get creditReason; MoneyDto? get limitRemaining; MoneyDto? get overdueAmount; DateTime? get asOf;/// `409 CUSTOMER_DUPLICATE_SUSPECTED` (08 §4.11.2): разбор терпимый ([_objectList], FQ-FND-03).
@JsonKey(fromJson: _objectList) List<Map<String, dynamic>>? get candidates; String? get runId; String? get minVersion; String? get storeUrl; ProblemOnec? get onec;
/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProblemCopyWith<Problem> get copyWith => _$ProblemCopyWithImpl<Problem>(this as Problem, _$identity);

  /// Serializes this Problem to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Problem&&(identical(other.type, type) || other.type == type)&&(identical(other.title, title) || other.title == title)&&(identical(other.status, status) || other.status == status)&&(identical(other.code, code) || other.code == code)&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.detail, detail) || other.detail == detail)&&(identical(other.instance, instance) || other.instance == instance)&&const DeepCollectionEquality().equals(other.errors, errors)&&const DeepCollectionEquality().equals(other.conflicts, conflicts)&&(identical(other.retryAfter, retryAfter) || other.retryAfter == retryAfter)&&(identical(other.attemptsLeft, attemptsLeft) || other.attemptsLeft == attemptsLeft)&&(identical(other.stepUp, stepUp) || other.stepUp == stepUp)&&const DeepCollectionEquality().equals(other.current, current)&&(identical(other.currentStatus, currentStatus) || other.currentStatus == currentStatus)&&const DeepCollectionEquality().equals(other.allowedActions, allowedActions)&&(identical(other.resource, resource) || other.resource == resource)&&(identical(other.reason, reason) || other.reason == reason)&&(identical(other.until, until) || other.until == until)&&(identical(other.possibleDuplicateOrderId, possibleDuplicateOrderId) || other.possibleDuplicateOrderId == possibleDuplicateOrderId)&&(identical(other.possibleDuplicatePublicNumber, possibleDuplicatePublicNumber) || other.possibleDuplicatePublicNumber == possibleDuplicatePublicNumber)&&(identical(other.possibleDuplicateCreatedAt, possibleDuplicateCreatedAt) || other.possibleDuplicateCreatedAt == possibleDuplicateCreatedAt)&&(identical(other.previewTotal, previewTotal) || other.previewTotal == previewTotal)&&(identical(other.total, total) || other.total == total)&&(identical(other.openPaymentId, openPaymentId) || other.openPaymentId == openPaymentId)&&(identical(other.limitPercent, limitPercent) || other.limitPercent == limitPercent)&&(identical(other.requiresRole, requiresRole) || other.requiresRole == requiresRole)&&(identical(other.creditReason, creditReason) || other.creditReason == creditReason)&&(identical(other.limitRemaining, limitRemaining) || other.limitRemaining == limitRemaining)&&(identical(other.overdueAmount, overdueAmount) || other.overdueAmount == overdueAmount)&&(identical(other.asOf, asOf) || other.asOf == asOf)&&const DeepCollectionEquality().equals(other.candidates, candidates)&&(identical(other.runId, runId) || other.runId == runId)&&(identical(other.minVersion, minVersion) || other.minVersion == minVersion)&&(identical(other.storeUrl, storeUrl) || other.storeUrl == storeUrl)&&(identical(other.onec, onec) || other.onec == onec));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,type,title,status,code,requestId,detail,instance,const DeepCollectionEquality().hash(errors),const DeepCollectionEquality().hash(conflicts),retryAfter,attemptsLeft,stepUp,const DeepCollectionEquality().hash(current),currentStatus,const DeepCollectionEquality().hash(allowedActions),resource,reason,until,possibleDuplicateOrderId,possibleDuplicatePublicNumber,possibleDuplicateCreatedAt,previewTotal,total,openPaymentId,limitPercent,requiresRole,creditReason,limitRemaining,overdueAmount,asOf,const DeepCollectionEquality().hash(candidates),runId,minVersion,storeUrl,onec]);

@override
String toString() {
  return 'Problem(type: $type, title: $title, status: $status, code: $code, requestId: $requestId, detail: $detail, instance: $instance, errors: $errors, conflicts: $conflicts, retryAfter: $retryAfter, attemptsLeft: $attemptsLeft, stepUp: $stepUp, current: $current, currentStatus: $currentStatus, allowedActions: $allowedActions, resource: $resource, reason: $reason, until: $until, possibleDuplicateOrderId: $possibleDuplicateOrderId, possibleDuplicatePublicNumber: $possibleDuplicatePublicNumber, possibleDuplicateCreatedAt: $possibleDuplicateCreatedAt, previewTotal: $previewTotal, total: $total, openPaymentId: $openPaymentId, limitPercent: $limitPercent, requiresRole: $requiresRole, creditReason: $creditReason, limitRemaining: $limitRemaining, overdueAmount: $overdueAmount, asOf: $asOf, candidates: $candidates, runId: $runId, minVersion: $minVersion, storeUrl: $storeUrl, onec: $onec)';
}


}

/// @nodoc
abstract mixin class $ProblemCopyWith<$Res>  {
  factory $ProblemCopyWith(Problem value, $Res Function(Problem) _then) = _$ProblemCopyWithImpl;
@useResult
$Res call({
 String type, String title, int status, String code, String requestId, String? detail, String? instance, List<ProblemFieldError>? errors,@JsonKey(fromJson: _objectList) List<Map<String, dynamic>>? conflicts, int? retryAfter, int? attemptsLeft, ProblemStepUp? stepUp, Map<String, dynamic>? current, String? currentStatus, List<String>? allowedActions, String? resource, String? reason, DateTime? until, String? possibleDuplicateOrderId, String? possibleDuplicatePublicNumber, String? possibleDuplicateCreatedAt, MoneyDto? previewTotal, MoneyDto? total, String? openPaymentId, String? limitPercent, String? requiresRole, String? creditReason, MoneyDto? limitRemaining, MoneyDto? overdueAmount, DateTime? asOf,@JsonKey(fromJson: _objectList) List<Map<String, dynamic>>? candidates, String? runId, String? minVersion, String? storeUrl, ProblemOnec? onec
});


$ProblemStepUpCopyWith<$Res>? get stepUp;$MoneyDtoCopyWith<$Res>? get previewTotal;$MoneyDtoCopyWith<$Res>? get total;$MoneyDtoCopyWith<$Res>? get limitRemaining;$MoneyDtoCopyWith<$Res>? get overdueAmount;$ProblemOnecCopyWith<$Res>? get onec;

}
/// @nodoc
class _$ProblemCopyWithImpl<$Res>
    implements $ProblemCopyWith<$Res> {
  _$ProblemCopyWithImpl(this._self, this._then);

  final Problem _self;
  final $Res Function(Problem) _then;

/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? type = null,Object? title = null,Object? status = null,Object? code = null,Object? requestId = null,Object? detail = freezed,Object? instance = freezed,Object? errors = freezed,Object? conflicts = freezed,Object? retryAfter = freezed,Object? attemptsLeft = freezed,Object? stepUp = freezed,Object? current = freezed,Object? currentStatus = freezed,Object? allowedActions = freezed,Object? resource = freezed,Object? reason = freezed,Object? until = freezed,Object? possibleDuplicateOrderId = freezed,Object? possibleDuplicatePublicNumber = freezed,Object? possibleDuplicateCreatedAt = freezed,Object? previewTotal = freezed,Object? total = freezed,Object? openPaymentId = freezed,Object? limitPercent = freezed,Object? requiresRole = freezed,Object? creditReason = freezed,Object? limitRemaining = freezed,Object? overdueAmount = freezed,Object? asOf = freezed,Object? candidates = freezed,Object? runId = freezed,Object? minVersion = freezed,Object? storeUrl = freezed,Object? onec = freezed,}) {
  return _then(_self.copyWith(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as int,code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String,requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,detail: freezed == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String?,instance: freezed == instance ? _self.instance : instance // ignore: cast_nullable_to_non_nullable
as String?,errors: freezed == errors ? _self.errors : errors // ignore: cast_nullable_to_non_nullable
as List<ProblemFieldError>?,conflicts: freezed == conflicts ? _self.conflicts : conflicts // ignore: cast_nullable_to_non_nullable
as List<Map<String, dynamic>>?,retryAfter: freezed == retryAfter ? _self.retryAfter : retryAfter // ignore: cast_nullable_to_non_nullable
as int?,attemptsLeft: freezed == attemptsLeft ? _self.attemptsLeft : attemptsLeft // ignore: cast_nullable_to_non_nullable
as int?,stepUp: freezed == stepUp ? _self.stepUp : stepUp // ignore: cast_nullable_to_non_nullable
as ProblemStepUp?,current: freezed == current ? _self.current : current // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>?,currentStatus: freezed == currentStatus ? _self.currentStatus : currentStatus // ignore: cast_nullable_to_non_nullable
as String?,allowedActions: freezed == allowedActions ? _self.allowedActions : allowedActions // ignore: cast_nullable_to_non_nullable
as List<String>?,resource: freezed == resource ? _self.resource : resource // ignore: cast_nullable_to_non_nullable
as String?,reason: freezed == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String?,until: freezed == until ? _self.until : until // ignore: cast_nullable_to_non_nullable
as DateTime?,possibleDuplicateOrderId: freezed == possibleDuplicateOrderId ? _self.possibleDuplicateOrderId : possibleDuplicateOrderId // ignore: cast_nullable_to_non_nullable
as String?,possibleDuplicatePublicNumber: freezed == possibleDuplicatePublicNumber ? _self.possibleDuplicatePublicNumber : possibleDuplicatePublicNumber // ignore: cast_nullable_to_non_nullable
as String?,possibleDuplicateCreatedAt: freezed == possibleDuplicateCreatedAt ? _self.possibleDuplicateCreatedAt : possibleDuplicateCreatedAt // ignore: cast_nullable_to_non_nullable
as String?,previewTotal: freezed == previewTotal ? _self.previewTotal : previewTotal // ignore: cast_nullable_to_non_nullable
as MoneyDto?,total: freezed == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as MoneyDto?,openPaymentId: freezed == openPaymentId ? _self.openPaymentId : openPaymentId // ignore: cast_nullable_to_non_nullable
as String?,limitPercent: freezed == limitPercent ? _self.limitPercent : limitPercent // ignore: cast_nullable_to_non_nullable
as String?,requiresRole: freezed == requiresRole ? _self.requiresRole : requiresRole // ignore: cast_nullable_to_non_nullable
as String?,creditReason: freezed == creditReason ? _self.creditReason : creditReason // ignore: cast_nullable_to_non_nullable
as String?,limitRemaining: freezed == limitRemaining ? _self.limitRemaining : limitRemaining // ignore: cast_nullable_to_non_nullable
as MoneyDto?,overdueAmount: freezed == overdueAmount ? _self.overdueAmount : overdueAmount // ignore: cast_nullable_to_non_nullable
as MoneyDto?,asOf: freezed == asOf ? _self.asOf : asOf // ignore: cast_nullable_to_non_nullable
as DateTime?,candidates: freezed == candidates ? _self.candidates : candidates // ignore: cast_nullable_to_non_nullable
as List<Map<String, dynamic>>?,runId: freezed == runId ? _self.runId : runId // ignore: cast_nullable_to_non_nullable
as String?,minVersion: freezed == minVersion ? _self.minVersion : minVersion // ignore: cast_nullable_to_non_nullable
as String?,storeUrl: freezed == storeUrl ? _self.storeUrl : storeUrl // ignore: cast_nullable_to_non_nullable
as String?,onec: freezed == onec ? _self.onec : onec // ignore: cast_nullable_to_non_nullable
as ProblemOnec?,
  ));
}
/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ProblemStepUpCopyWith<$Res>? get stepUp {
    if (_self.stepUp == null) {
    return null;
  }

  return $ProblemStepUpCopyWith<$Res>(_self.stepUp!, (value) {
    return _then(_self.copyWith(stepUp: value));
  });
}/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MoneyDtoCopyWith<$Res>? get previewTotal {
    if (_self.previewTotal == null) {
    return null;
  }

  return $MoneyDtoCopyWith<$Res>(_self.previewTotal!, (value) {
    return _then(_self.copyWith(previewTotal: value));
  });
}/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MoneyDtoCopyWith<$Res>? get total {
    if (_self.total == null) {
    return null;
  }

  return $MoneyDtoCopyWith<$Res>(_self.total!, (value) {
    return _then(_self.copyWith(total: value));
  });
}/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MoneyDtoCopyWith<$Res>? get limitRemaining {
    if (_self.limitRemaining == null) {
    return null;
  }

  return $MoneyDtoCopyWith<$Res>(_self.limitRemaining!, (value) {
    return _then(_self.copyWith(limitRemaining: value));
  });
}/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MoneyDtoCopyWith<$Res>? get overdueAmount {
    if (_self.overdueAmount == null) {
    return null;
  }

  return $MoneyDtoCopyWith<$Res>(_self.overdueAmount!, (value) {
    return _then(_self.copyWith(overdueAmount: value));
  });
}/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ProblemOnecCopyWith<$Res>? get onec {
    if (_self.onec == null) {
    return null;
  }

  return $ProblemOnecCopyWith<$Res>(_self.onec!, (value) {
    return _then(_self.copyWith(onec: value));
  });
}
}


/// Adds pattern-matching-related methods to [Problem].
extension ProblemPatterns on Problem {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Problem value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Problem() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Problem value)  $default,){
final _that = this;
switch (_that) {
case _Problem():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Problem value)?  $default,){
final _that = this;
switch (_that) {
case _Problem() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String type,  String title,  int status,  String code,  String requestId,  String? detail,  String? instance,  List<ProblemFieldError>? errors, @JsonKey(fromJson: _objectList)  List<Map<String, dynamic>>? conflicts,  int? retryAfter,  int? attemptsLeft,  ProblemStepUp? stepUp,  Map<String, dynamic>? current,  String? currentStatus,  List<String>? allowedActions,  String? resource,  String? reason,  DateTime? until,  String? possibleDuplicateOrderId,  String? possibleDuplicatePublicNumber,  String? possibleDuplicateCreatedAt,  MoneyDto? previewTotal,  MoneyDto? total,  String? openPaymentId,  String? limitPercent,  String? requiresRole,  String? creditReason,  MoneyDto? limitRemaining,  MoneyDto? overdueAmount,  DateTime? asOf, @JsonKey(fromJson: _objectList)  List<Map<String, dynamic>>? candidates,  String? runId,  String? minVersion,  String? storeUrl,  ProblemOnec? onec)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Problem() when $default != null:
return $default(_that.type,_that.title,_that.status,_that.code,_that.requestId,_that.detail,_that.instance,_that.errors,_that.conflicts,_that.retryAfter,_that.attemptsLeft,_that.stepUp,_that.current,_that.currentStatus,_that.allowedActions,_that.resource,_that.reason,_that.until,_that.possibleDuplicateOrderId,_that.possibleDuplicatePublicNumber,_that.possibleDuplicateCreatedAt,_that.previewTotal,_that.total,_that.openPaymentId,_that.limitPercent,_that.requiresRole,_that.creditReason,_that.limitRemaining,_that.overdueAmount,_that.asOf,_that.candidates,_that.runId,_that.minVersion,_that.storeUrl,_that.onec);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String type,  String title,  int status,  String code,  String requestId,  String? detail,  String? instance,  List<ProblemFieldError>? errors, @JsonKey(fromJson: _objectList)  List<Map<String, dynamic>>? conflicts,  int? retryAfter,  int? attemptsLeft,  ProblemStepUp? stepUp,  Map<String, dynamic>? current,  String? currentStatus,  List<String>? allowedActions,  String? resource,  String? reason,  DateTime? until,  String? possibleDuplicateOrderId,  String? possibleDuplicatePublicNumber,  String? possibleDuplicateCreatedAt,  MoneyDto? previewTotal,  MoneyDto? total,  String? openPaymentId,  String? limitPercent,  String? requiresRole,  String? creditReason,  MoneyDto? limitRemaining,  MoneyDto? overdueAmount,  DateTime? asOf, @JsonKey(fromJson: _objectList)  List<Map<String, dynamic>>? candidates,  String? runId,  String? minVersion,  String? storeUrl,  ProblemOnec? onec)  $default,) {final _that = this;
switch (_that) {
case _Problem():
return $default(_that.type,_that.title,_that.status,_that.code,_that.requestId,_that.detail,_that.instance,_that.errors,_that.conflicts,_that.retryAfter,_that.attemptsLeft,_that.stepUp,_that.current,_that.currentStatus,_that.allowedActions,_that.resource,_that.reason,_that.until,_that.possibleDuplicateOrderId,_that.possibleDuplicatePublicNumber,_that.possibleDuplicateCreatedAt,_that.previewTotal,_that.total,_that.openPaymentId,_that.limitPercent,_that.requiresRole,_that.creditReason,_that.limitRemaining,_that.overdueAmount,_that.asOf,_that.candidates,_that.runId,_that.minVersion,_that.storeUrl,_that.onec);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String type,  String title,  int status,  String code,  String requestId,  String? detail,  String? instance,  List<ProblemFieldError>? errors, @JsonKey(fromJson: _objectList)  List<Map<String, dynamic>>? conflicts,  int? retryAfter,  int? attemptsLeft,  ProblemStepUp? stepUp,  Map<String, dynamic>? current,  String? currentStatus,  List<String>? allowedActions,  String? resource,  String? reason,  DateTime? until,  String? possibleDuplicateOrderId,  String? possibleDuplicatePublicNumber,  String? possibleDuplicateCreatedAt,  MoneyDto? previewTotal,  MoneyDto? total,  String? openPaymentId,  String? limitPercent,  String? requiresRole,  String? creditReason,  MoneyDto? limitRemaining,  MoneyDto? overdueAmount,  DateTime? asOf, @JsonKey(fromJson: _objectList)  List<Map<String, dynamic>>? candidates,  String? runId,  String? minVersion,  String? storeUrl,  ProblemOnec? onec)?  $default,) {final _that = this;
switch (_that) {
case _Problem() when $default != null:
return $default(_that.type,_that.title,_that.status,_that.code,_that.requestId,_that.detail,_that.instance,_that.errors,_that.conflicts,_that.retryAfter,_that.attemptsLeft,_that.stepUp,_that.current,_that.currentStatus,_that.allowedActions,_that.resource,_that.reason,_that.until,_that.possibleDuplicateOrderId,_that.possibleDuplicatePublicNumber,_that.possibleDuplicateCreatedAt,_that.previewTotal,_that.total,_that.openPaymentId,_that.limitPercent,_that.requiresRole,_that.creditReason,_that.limitRemaining,_that.overdueAmount,_that.asOf,_that.candidates,_that.runId,_that.minVersion,_that.storeUrl,_that.onec);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Problem extends Problem {
  const _Problem({required this.type, required this.title, required this.status, required this.code, required this.requestId, this.detail, this.instance, final  List<ProblemFieldError>? errors, @JsonKey(fromJson: _objectList) final  List<Map<String, dynamic>>? conflicts, this.retryAfter, this.attemptsLeft, this.stepUp, final  Map<String, dynamic>? current, this.currentStatus, final  List<String>? allowedActions, this.resource, this.reason, this.until, this.possibleDuplicateOrderId, this.possibleDuplicatePublicNumber, this.possibleDuplicateCreatedAt, this.previewTotal, this.total, this.openPaymentId, this.limitPercent, this.requiresRole, this.creditReason, this.limitRemaining, this.overdueAmount, this.asOf, @JsonKey(fromJson: _objectList) final  List<Map<String, dynamic>>? candidates, this.runId, this.minVersion, this.storeUrl, this.onec}): _errors = errors,_conflicts = conflicts,_current = current,_allowedActions = allowedActions,_candidates = candidates,super._();
  factory _Problem.fromJson(Map<String, dynamic> json) => _$ProblemFromJson(json);

@override final  String type;
@override final  String title;
@override final  int status;
@override final  String code;
@override final  String requestId;
@override final  String? detail;
@override final  String? instance;
 final  List<ProblemFieldError>? _errors;
@override List<ProblemFieldError>? get errors {
  final value = _errors;
  if (value == null) return null;
  if (_errors is EqualUnmodifiableListView) return _errors;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

/// `CartConflict[]` — типизирует фича cart (по мере фич, ADR-085). Разбор терпимый ([_objectList]).
 final  List<Map<String, dynamic>>? _conflicts;
/// `CartConflict[]` — типизирует фича cart (по мере фич, ADR-085). Разбор терпимый ([_objectList]).
@override@JsonKey(fromJson: _objectList) List<Map<String, dynamic>>? get conflicts {
  final value = _conflicts;
  if (value == null) return null;
  if (_conflicts is EqualUnmodifiableListView) return _conflicts;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

@override final  int? retryAfter;
@override final  int? attemptsLeft;
@override final  ProblemStepUp? stepUp;
 final  Map<String, dynamic>? _current;
@override Map<String, dynamic>? get current {
  final value = _current;
  if (value == null) return null;
  if (_current is EqualUnmodifiableMapView) return _current;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(value);
}

@override final  String? currentStatus;
 final  List<String>? _allowedActions;
@override List<String>? get allowedActions {
  final value = _allowedActions;
  if (value == null) return null;
  if (_allowedActions is EqualUnmodifiableListView) return _allowedActions;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

@override final  String? resource;
@override final  String? reason;
/// `423 PIN_LOCKED`: момент снятия блокировки PIN (ISO-8601, 08 §2.4; 09 §9.6; OpenAPI 1.1.0).
@override final  DateTime? until;
@override final  String? possibleDuplicateOrderId;
/// `409 ORDER_STATE_INVALID reason=possible_duplicate`: номер POS и момент создания похожего заказа (UI-21-029;
/// 08 §4.8.1 «Уточнения POST /orders» п. 4; OpenAPI 1.2.0). Сервер этапа F ещё не передаёт — `null`.
/// Момент — строкой (date-time): неразбираемое значение не должно ломать разбор всей ошибки (08 §2.11).
@override final  String? possibleDuplicatePublicNumber;
@override final  String? possibleDuplicateCreatedAt;
/// `422 PRICE_CHANGED` по `previewToken`: итог предпросмотра и текущий итог сервера (08 §2.4 «Уточнения кодов
/// ошибок по реализации этапа F» п. 1; OpenAPI 1.2.0), вместе с `reason` (`preview_*`).
@override final  MoneyDto? previewTotal;
@override final  MoneyDto? total;
@override final  String? openPaymentId;
@override final  String? limitPercent;
@override final  String? requiresRole;
@override final  String? creditReason;
@override final  MoneyDto? limitRemaining;
@override final  MoneyDto? overdueAmount;
@override final  DateTime? asOf;
/// `409 CUSTOMER_DUPLICATE_SUSPECTED` (08 §4.11.2): разбор терпимый ([_objectList], FQ-FND-03).
 final  List<Map<String, dynamic>>? _candidates;
/// `409 CUSTOMER_DUPLICATE_SUSPECTED` (08 §4.11.2): разбор терпимый ([_objectList], FQ-FND-03).
@override@JsonKey(fromJson: _objectList) List<Map<String, dynamic>>? get candidates {
  final value = _candidates;
  if (value == null) return null;
  if (_candidates is EqualUnmodifiableListView) return _candidates;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

@override final  String? runId;
@override final  String? minVersion;
@override final  String? storeUrl;
@override final  ProblemOnec? onec;

/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProblemCopyWith<_Problem> get copyWith => __$ProblemCopyWithImpl<_Problem>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ProblemToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Problem&&(identical(other.type, type) || other.type == type)&&(identical(other.title, title) || other.title == title)&&(identical(other.status, status) || other.status == status)&&(identical(other.code, code) || other.code == code)&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.detail, detail) || other.detail == detail)&&(identical(other.instance, instance) || other.instance == instance)&&const DeepCollectionEquality().equals(other._errors, _errors)&&const DeepCollectionEquality().equals(other._conflicts, _conflicts)&&(identical(other.retryAfter, retryAfter) || other.retryAfter == retryAfter)&&(identical(other.attemptsLeft, attemptsLeft) || other.attemptsLeft == attemptsLeft)&&(identical(other.stepUp, stepUp) || other.stepUp == stepUp)&&const DeepCollectionEquality().equals(other._current, _current)&&(identical(other.currentStatus, currentStatus) || other.currentStatus == currentStatus)&&const DeepCollectionEquality().equals(other._allowedActions, _allowedActions)&&(identical(other.resource, resource) || other.resource == resource)&&(identical(other.reason, reason) || other.reason == reason)&&(identical(other.until, until) || other.until == until)&&(identical(other.possibleDuplicateOrderId, possibleDuplicateOrderId) || other.possibleDuplicateOrderId == possibleDuplicateOrderId)&&(identical(other.possibleDuplicatePublicNumber, possibleDuplicatePublicNumber) || other.possibleDuplicatePublicNumber == possibleDuplicatePublicNumber)&&(identical(other.possibleDuplicateCreatedAt, possibleDuplicateCreatedAt) || other.possibleDuplicateCreatedAt == possibleDuplicateCreatedAt)&&(identical(other.previewTotal, previewTotal) || other.previewTotal == previewTotal)&&(identical(other.total, total) || other.total == total)&&(identical(other.openPaymentId, openPaymentId) || other.openPaymentId == openPaymentId)&&(identical(other.limitPercent, limitPercent) || other.limitPercent == limitPercent)&&(identical(other.requiresRole, requiresRole) || other.requiresRole == requiresRole)&&(identical(other.creditReason, creditReason) || other.creditReason == creditReason)&&(identical(other.limitRemaining, limitRemaining) || other.limitRemaining == limitRemaining)&&(identical(other.overdueAmount, overdueAmount) || other.overdueAmount == overdueAmount)&&(identical(other.asOf, asOf) || other.asOf == asOf)&&const DeepCollectionEquality().equals(other._candidates, _candidates)&&(identical(other.runId, runId) || other.runId == runId)&&(identical(other.minVersion, minVersion) || other.minVersion == minVersion)&&(identical(other.storeUrl, storeUrl) || other.storeUrl == storeUrl)&&(identical(other.onec, onec) || other.onec == onec));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,type,title,status,code,requestId,detail,instance,const DeepCollectionEquality().hash(_errors),const DeepCollectionEquality().hash(_conflicts),retryAfter,attemptsLeft,stepUp,const DeepCollectionEquality().hash(_current),currentStatus,const DeepCollectionEquality().hash(_allowedActions),resource,reason,until,possibleDuplicateOrderId,possibleDuplicatePublicNumber,possibleDuplicateCreatedAt,previewTotal,total,openPaymentId,limitPercent,requiresRole,creditReason,limitRemaining,overdueAmount,asOf,const DeepCollectionEquality().hash(_candidates),runId,minVersion,storeUrl,onec]);

@override
String toString() {
  return 'Problem(type: $type, title: $title, status: $status, code: $code, requestId: $requestId, detail: $detail, instance: $instance, errors: $errors, conflicts: $conflicts, retryAfter: $retryAfter, attemptsLeft: $attemptsLeft, stepUp: $stepUp, current: $current, currentStatus: $currentStatus, allowedActions: $allowedActions, resource: $resource, reason: $reason, until: $until, possibleDuplicateOrderId: $possibleDuplicateOrderId, possibleDuplicatePublicNumber: $possibleDuplicatePublicNumber, possibleDuplicateCreatedAt: $possibleDuplicateCreatedAt, previewTotal: $previewTotal, total: $total, openPaymentId: $openPaymentId, limitPercent: $limitPercent, requiresRole: $requiresRole, creditReason: $creditReason, limitRemaining: $limitRemaining, overdueAmount: $overdueAmount, asOf: $asOf, candidates: $candidates, runId: $runId, minVersion: $minVersion, storeUrl: $storeUrl, onec: $onec)';
}


}

/// @nodoc
abstract mixin class _$ProblemCopyWith<$Res> implements $ProblemCopyWith<$Res> {
  factory _$ProblemCopyWith(_Problem value, $Res Function(_Problem) _then) = __$ProblemCopyWithImpl;
@override @useResult
$Res call({
 String type, String title, int status, String code, String requestId, String? detail, String? instance, List<ProblemFieldError>? errors,@JsonKey(fromJson: _objectList) List<Map<String, dynamic>>? conflicts, int? retryAfter, int? attemptsLeft, ProblemStepUp? stepUp, Map<String, dynamic>? current, String? currentStatus, List<String>? allowedActions, String? resource, String? reason, DateTime? until, String? possibleDuplicateOrderId, String? possibleDuplicatePublicNumber, String? possibleDuplicateCreatedAt, MoneyDto? previewTotal, MoneyDto? total, String? openPaymentId, String? limitPercent, String? requiresRole, String? creditReason, MoneyDto? limitRemaining, MoneyDto? overdueAmount, DateTime? asOf,@JsonKey(fromJson: _objectList) List<Map<String, dynamic>>? candidates, String? runId, String? minVersion, String? storeUrl, ProblemOnec? onec
});


@override $ProblemStepUpCopyWith<$Res>? get stepUp;@override $MoneyDtoCopyWith<$Res>? get previewTotal;@override $MoneyDtoCopyWith<$Res>? get total;@override $MoneyDtoCopyWith<$Res>? get limitRemaining;@override $MoneyDtoCopyWith<$Res>? get overdueAmount;@override $ProblemOnecCopyWith<$Res>? get onec;

}
/// @nodoc
class __$ProblemCopyWithImpl<$Res>
    implements _$ProblemCopyWith<$Res> {
  __$ProblemCopyWithImpl(this._self, this._then);

  final _Problem _self;
  final $Res Function(_Problem) _then;

/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? type = null,Object? title = null,Object? status = null,Object? code = null,Object? requestId = null,Object? detail = freezed,Object? instance = freezed,Object? errors = freezed,Object? conflicts = freezed,Object? retryAfter = freezed,Object? attemptsLeft = freezed,Object? stepUp = freezed,Object? current = freezed,Object? currentStatus = freezed,Object? allowedActions = freezed,Object? resource = freezed,Object? reason = freezed,Object? until = freezed,Object? possibleDuplicateOrderId = freezed,Object? possibleDuplicatePublicNumber = freezed,Object? possibleDuplicateCreatedAt = freezed,Object? previewTotal = freezed,Object? total = freezed,Object? openPaymentId = freezed,Object? limitPercent = freezed,Object? requiresRole = freezed,Object? creditReason = freezed,Object? limitRemaining = freezed,Object? overdueAmount = freezed,Object? asOf = freezed,Object? candidates = freezed,Object? runId = freezed,Object? minVersion = freezed,Object? storeUrl = freezed,Object? onec = freezed,}) {
  return _then(_Problem(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as int,code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String,requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,detail: freezed == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String?,instance: freezed == instance ? _self.instance : instance // ignore: cast_nullable_to_non_nullable
as String?,errors: freezed == errors ? _self._errors : errors // ignore: cast_nullable_to_non_nullable
as List<ProblemFieldError>?,conflicts: freezed == conflicts ? _self._conflicts : conflicts // ignore: cast_nullable_to_non_nullable
as List<Map<String, dynamic>>?,retryAfter: freezed == retryAfter ? _self.retryAfter : retryAfter // ignore: cast_nullable_to_non_nullable
as int?,attemptsLeft: freezed == attemptsLeft ? _self.attemptsLeft : attemptsLeft // ignore: cast_nullable_to_non_nullable
as int?,stepUp: freezed == stepUp ? _self.stepUp : stepUp // ignore: cast_nullable_to_non_nullable
as ProblemStepUp?,current: freezed == current ? _self._current : current // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>?,currentStatus: freezed == currentStatus ? _self.currentStatus : currentStatus // ignore: cast_nullable_to_non_nullable
as String?,allowedActions: freezed == allowedActions ? _self._allowedActions : allowedActions // ignore: cast_nullable_to_non_nullable
as List<String>?,resource: freezed == resource ? _self.resource : resource // ignore: cast_nullable_to_non_nullable
as String?,reason: freezed == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String?,until: freezed == until ? _self.until : until // ignore: cast_nullable_to_non_nullable
as DateTime?,possibleDuplicateOrderId: freezed == possibleDuplicateOrderId ? _self.possibleDuplicateOrderId : possibleDuplicateOrderId // ignore: cast_nullable_to_non_nullable
as String?,possibleDuplicatePublicNumber: freezed == possibleDuplicatePublicNumber ? _self.possibleDuplicatePublicNumber : possibleDuplicatePublicNumber // ignore: cast_nullable_to_non_nullable
as String?,possibleDuplicateCreatedAt: freezed == possibleDuplicateCreatedAt ? _self.possibleDuplicateCreatedAt : possibleDuplicateCreatedAt // ignore: cast_nullable_to_non_nullable
as String?,previewTotal: freezed == previewTotal ? _self.previewTotal : previewTotal // ignore: cast_nullable_to_non_nullable
as MoneyDto?,total: freezed == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as MoneyDto?,openPaymentId: freezed == openPaymentId ? _self.openPaymentId : openPaymentId // ignore: cast_nullable_to_non_nullable
as String?,limitPercent: freezed == limitPercent ? _self.limitPercent : limitPercent // ignore: cast_nullable_to_non_nullable
as String?,requiresRole: freezed == requiresRole ? _self.requiresRole : requiresRole // ignore: cast_nullable_to_non_nullable
as String?,creditReason: freezed == creditReason ? _self.creditReason : creditReason // ignore: cast_nullable_to_non_nullable
as String?,limitRemaining: freezed == limitRemaining ? _self.limitRemaining : limitRemaining // ignore: cast_nullable_to_non_nullable
as MoneyDto?,overdueAmount: freezed == overdueAmount ? _self.overdueAmount : overdueAmount // ignore: cast_nullable_to_non_nullable
as MoneyDto?,asOf: freezed == asOf ? _self.asOf : asOf // ignore: cast_nullable_to_non_nullable
as DateTime?,candidates: freezed == candidates ? _self._candidates : candidates // ignore: cast_nullable_to_non_nullable
as List<Map<String, dynamic>>?,runId: freezed == runId ? _self.runId : runId // ignore: cast_nullable_to_non_nullable
as String?,minVersion: freezed == minVersion ? _self.minVersion : minVersion // ignore: cast_nullable_to_non_nullable
as String?,storeUrl: freezed == storeUrl ? _self.storeUrl : storeUrl // ignore: cast_nullable_to_non_nullable
as String?,onec: freezed == onec ? _self.onec : onec // ignore: cast_nullable_to_non_nullable
as ProblemOnec?,
  ));
}

/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ProblemStepUpCopyWith<$Res>? get stepUp {
    if (_self.stepUp == null) {
    return null;
  }

  return $ProblemStepUpCopyWith<$Res>(_self.stepUp!, (value) {
    return _then(_self.copyWith(stepUp: value));
  });
}/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MoneyDtoCopyWith<$Res>? get previewTotal {
    if (_self.previewTotal == null) {
    return null;
  }

  return $MoneyDtoCopyWith<$Res>(_self.previewTotal!, (value) {
    return _then(_self.copyWith(previewTotal: value));
  });
}/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MoneyDtoCopyWith<$Res>? get total {
    if (_self.total == null) {
    return null;
  }

  return $MoneyDtoCopyWith<$Res>(_self.total!, (value) {
    return _then(_self.copyWith(total: value));
  });
}/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MoneyDtoCopyWith<$Res>? get limitRemaining {
    if (_self.limitRemaining == null) {
    return null;
  }

  return $MoneyDtoCopyWith<$Res>(_self.limitRemaining!, (value) {
    return _then(_self.copyWith(limitRemaining: value));
  });
}/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MoneyDtoCopyWith<$Res>? get overdueAmount {
    if (_self.overdueAmount == null) {
    return null;
  }

  return $MoneyDtoCopyWith<$Res>(_self.overdueAmount!, (value) {
    return _then(_self.copyWith(overdueAmount: value));
  });
}/// Create a copy of Problem
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ProblemOnecCopyWith<$Res>? get onec {
    if (_self.onec == null) {
    return null;
  }

  return $ProblemOnecCopyWith<$Res>(_self.onec!, (value) {
    return _then(_self.copyWith(onec: value));
  });
}
}


/// @nodoc
mixin _$ProblemFieldError {

 String get field; String get message; String get rule; Map<String, dynamic>? get params;
/// Create a copy of ProblemFieldError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProblemFieldErrorCopyWith<ProblemFieldError> get copyWith => _$ProblemFieldErrorCopyWithImpl<ProblemFieldError>(this as ProblemFieldError, _$identity);

  /// Serializes this ProblemFieldError to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProblemFieldError&&(identical(other.field, field) || other.field == field)&&(identical(other.message, message) || other.message == message)&&(identical(other.rule, rule) || other.rule == rule)&&const DeepCollectionEquality().equals(other.params, params));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,field,message,rule,const DeepCollectionEquality().hash(params));

@override
String toString() {
  return 'ProblemFieldError(field: $field, message: $message, rule: $rule, params: $params)';
}


}

/// @nodoc
abstract mixin class $ProblemFieldErrorCopyWith<$Res>  {
  factory $ProblemFieldErrorCopyWith(ProblemFieldError value, $Res Function(ProblemFieldError) _then) = _$ProblemFieldErrorCopyWithImpl;
@useResult
$Res call({
 String field, String message, String rule, Map<String, dynamic>? params
});




}
/// @nodoc
class _$ProblemFieldErrorCopyWithImpl<$Res>
    implements $ProblemFieldErrorCopyWith<$Res> {
  _$ProblemFieldErrorCopyWithImpl(this._self, this._then);

  final ProblemFieldError _self;
  final $Res Function(ProblemFieldError) _then;

/// Create a copy of ProblemFieldError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? field = null,Object? message = null,Object? rule = null,Object? params = freezed,}) {
  return _then(_self.copyWith(
field: null == field ? _self.field : field // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,rule: null == rule ? _self.rule : rule // ignore: cast_nullable_to_non_nullable
as String,params: freezed == params ? _self.params : params // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>?,
  ));
}

}


/// Adds pattern-matching-related methods to [ProblemFieldError].
extension ProblemFieldErrorPatterns on ProblemFieldError {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ProblemFieldError value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ProblemFieldError() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ProblemFieldError value)  $default,){
final _that = this;
switch (_that) {
case _ProblemFieldError():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ProblemFieldError value)?  $default,){
final _that = this;
switch (_that) {
case _ProblemFieldError() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String field,  String message,  String rule,  Map<String, dynamic>? params)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ProblemFieldError() when $default != null:
return $default(_that.field,_that.message,_that.rule,_that.params);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String field,  String message,  String rule,  Map<String, dynamic>? params)  $default,) {final _that = this;
switch (_that) {
case _ProblemFieldError():
return $default(_that.field,_that.message,_that.rule,_that.params);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String field,  String message,  String rule,  Map<String, dynamic>? params)?  $default,) {final _that = this;
switch (_that) {
case _ProblemFieldError() when $default != null:
return $default(_that.field,_that.message,_that.rule,_that.params);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ProblemFieldError implements ProblemFieldError {
  const _ProblemFieldError({required this.field, required this.message, required this.rule, final  Map<String, dynamic>? params}): _params = params;
  factory _ProblemFieldError.fromJson(Map<String, dynamic> json) => _$ProblemFieldErrorFromJson(json);

@override final  String field;
@override final  String message;
@override final  String rule;
 final  Map<String, dynamic>? _params;
@override Map<String, dynamic>? get params {
  final value = _params;
  if (value == null) return null;
  if (_params is EqualUnmodifiableMapView) return _params;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(value);
}


/// Create a copy of ProblemFieldError
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProblemFieldErrorCopyWith<_ProblemFieldError> get copyWith => __$ProblemFieldErrorCopyWithImpl<_ProblemFieldError>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ProblemFieldErrorToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ProblemFieldError&&(identical(other.field, field) || other.field == field)&&(identical(other.message, message) || other.message == message)&&(identical(other.rule, rule) || other.rule == rule)&&const DeepCollectionEquality().equals(other._params, _params));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,field,message,rule,const DeepCollectionEquality().hash(_params));

@override
String toString() {
  return 'ProblemFieldError(field: $field, message: $message, rule: $rule, params: $params)';
}


}

/// @nodoc
abstract mixin class _$ProblemFieldErrorCopyWith<$Res> implements $ProblemFieldErrorCopyWith<$Res> {
  factory _$ProblemFieldErrorCopyWith(_ProblemFieldError value, $Res Function(_ProblemFieldError) _then) = __$ProblemFieldErrorCopyWithImpl;
@override @useResult
$Res call({
 String field, String message, String rule, Map<String, dynamic>? params
});




}
/// @nodoc
class __$ProblemFieldErrorCopyWithImpl<$Res>
    implements _$ProblemFieldErrorCopyWith<$Res> {
  __$ProblemFieldErrorCopyWithImpl(this._self, this._then);

  final _ProblemFieldError _self;
  final $Res Function(_ProblemFieldError) _then;

/// Create a copy of ProblemFieldError
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? field = null,Object? message = null,Object? rule = null,Object? params = freezed,}) {
  return _then(_ProblemFieldError(
field: null == field ? _self.field : field // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,rule: null == rule ? _self.rule : rule // ignore: cast_nullable_to_non_nullable
as String,params: freezed == params ? _self._params : params // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>?,
  ));
}


}


/// @nodoc
mixin _$ProblemStepUp {

 String? get operation; List<String>? get allowedMethods;
/// Create a copy of ProblemStepUp
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProblemStepUpCopyWith<ProblemStepUp> get copyWith => _$ProblemStepUpCopyWithImpl<ProblemStepUp>(this as ProblemStepUp, _$identity);

  /// Serializes this ProblemStepUp to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProblemStepUp&&(identical(other.operation, operation) || other.operation == operation)&&const DeepCollectionEquality().equals(other.allowedMethods, allowedMethods));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,operation,const DeepCollectionEquality().hash(allowedMethods));

@override
String toString() {
  return 'ProblemStepUp(operation: $operation, allowedMethods: $allowedMethods)';
}


}

/// @nodoc
abstract mixin class $ProblemStepUpCopyWith<$Res>  {
  factory $ProblemStepUpCopyWith(ProblemStepUp value, $Res Function(ProblemStepUp) _then) = _$ProblemStepUpCopyWithImpl;
@useResult
$Res call({
 String? operation, List<String>? allowedMethods
});




}
/// @nodoc
class _$ProblemStepUpCopyWithImpl<$Res>
    implements $ProblemStepUpCopyWith<$Res> {
  _$ProblemStepUpCopyWithImpl(this._self, this._then);

  final ProblemStepUp _self;
  final $Res Function(ProblemStepUp) _then;

/// Create a copy of ProblemStepUp
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? operation = freezed,Object? allowedMethods = freezed,}) {
  return _then(_self.copyWith(
operation: freezed == operation ? _self.operation : operation // ignore: cast_nullable_to_non_nullable
as String?,allowedMethods: freezed == allowedMethods ? _self.allowedMethods : allowedMethods // ignore: cast_nullable_to_non_nullable
as List<String>?,
  ));
}

}


/// Adds pattern-matching-related methods to [ProblemStepUp].
extension ProblemStepUpPatterns on ProblemStepUp {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ProblemStepUp value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ProblemStepUp() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ProblemStepUp value)  $default,){
final _that = this;
switch (_that) {
case _ProblemStepUp():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ProblemStepUp value)?  $default,){
final _that = this;
switch (_that) {
case _ProblemStepUp() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? operation,  List<String>? allowedMethods)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ProblemStepUp() when $default != null:
return $default(_that.operation,_that.allowedMethods);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? operation,  List<String>? allowedMethods)  $default,) {final _that = this;
switch (_that) {
case _ProblemStepUp():
return $default(_that.operation,_that.allowedMethods);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? operation,  List<String>? allowedMethods)?  $default,) {final _that = this;
switch (_that) {
case _ProblemStepUp() when $default != null:
return $default(_that.operation,_that.allowedMethods);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ProblemStepUp implements ProblemStepUp {
  const _ProblemStepUp({this.operation, final  List<String>? allowedMethods}): _allowedMethods = allowedMethods;
  factory _ProblemStepUp.fromJson(Map<String, dynamic> json) => _$ProblemStepUpFromJson(json);

@override final  String? operation;
 final  List<String>? _allowedMethods;
@override List<String>? get allowedMethods {
  final value = _allowedMethods;
  if (value == null) return null;
  if (_allowedMethods is EqualUnmodifiableListView) return _allowedMethods;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}


/// Create a copy of ProblemStepUp
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProblemStepUpCopyWith<_ProblemStepUp> get copyWith => __$ProblemStepUpCopyWithImpl<_ProblemStepUp>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ProblemStepUpToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ProblemStepUp&&(identical(other.operation, operation) || other.operation == operation)&&const DeepCollectionEquality().equals(other._allowedMethods, _allowedMethods));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,operation,const DeepCollectionEquality().hash(_allowedMethods));

@override
String toString() {
  return 'ProblemStepUp(operation: $operation, allowedMethods: $allowedMethods)';
}


}

/// @nodoc
abstract mixin class _$ProblemStepUpCopyWith<$Res> implements $ProblemStepUpCopyWith<$Res> {
  factory _$ProblemStepUpCopyWith(_ProblemStepUp value, $Res Function(_ProblemStepUp) _then) = __$ProblemStepUpCopyWithImpl;
@override @useResult
$Res call({
 String? operation, List<String>? allowedMethods
});




}
/// @nodoc
class __$ProblemStepUpCopyWithImpl<$Res>
    implements _$ProblemStepUpCopyWith<$Res> {
  __$ProblemStepUpCopyWithImpl(this._self, this._then);

  final _ProblemStepUp _self;
  final $Res Function(_ProblemStepUp) _then;

/// Create a copy of ProblemStepUp
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? operation = freezed,Object? allowedMethods = freezed,}) {
  return _then(_ProblemStepUp(
operation: freezed == operation ? _self.operation : operation // ignore: cast_nullable_to_non_nullable
as String?,allowedMethods: freezed == allowedMethods ? _self._allowedMethods : allowedMethods // ignore: cast_nullable_to_non_nullable
as List<String>?,
  ));
}


}


/// @nodoc
mixin _$ProblemOnec {

 String? get code; String? get message;
/// Create a copy of ProblemOnec
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProblemOnecCopyWith<ProblemOnec> get copyWith => _$ProblemOnecCopyWithImpl<ProblemOnec>(this as ProblemOnec, _$identity);

  /// Serializes this ProblemOnec to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProblemOnec&&(identical(other.code, code) || other.code == code)&&(identical(other.message, message) || other.message == message));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,code,message);

@override
String toString() {
  return 'ProblemOnec(code: $code, message: $message)';
}


}

/// @nodoc
abstract mixin class $ProblemOnecCopyWith<$Res>  {
  factory $ProblemOnecCopyWith(ProblemOnec value, $Res Function(ProblemOnec) _then) = _$ProblemOnecCopyWithImpl;
@useResult
$Res call({
 String? code, String? message
});




}
/// @nodoc
class _$ProblemOnecCopyWithImpl<$Res>
    implements $ProblemOnecCopyWith<$Res> {
  _$ProblemOnecCopyWithImpl(this._self, this._then);

  final ProblemOnec _self;
  final $Res Function(ProblemOnec) _then;

/// Create a copy of ProblemOnec
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? code = freezed,Object? message = freezed,}) {
  return _then(_self.copyWith(
code: freezed == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String?,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ProblemOnec].
extension ProblemOnecPatterns on ProblemOnec {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ProblemOnec value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ProblemOnec() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ProblemOnec value)  $default,){
final _that = this;
switch (_that) {
case _ProblemOnec():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ProblemOnec value)?  $default,){
final _that = this;
switch (_that) {
case _ProblemOnec() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? code,  String? message)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ProblemOnec() when $default != null:
return $default(_that.code,_that.message);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? code,  String? message)  $default,) {final _that = this;
switch (_that) {
case _ProblemOnec():
return $default(_that.code,_that.message);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? code,  String? message)?  $default,) {final _that = this;
switch (_that) {
case _ProblemOnec() when $default != null:
return $default(_that.code,_that.message);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ProblemOnec implements ProblemOnec {
  const _ProblemOnec({this.code, this.message});
  factory _ProblemOnec.fromJson(Map<String, dynamic> json) => _$ProblemOnecFromJson(json);

@override final  String? code;
@override final  String? message;

/// Create a copy of ProblemOnec
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProblemOnecCopyWith<_ProblemOnec> get copyWith => __$ProblemOnecCopyWithImpl<_ProblemOnec>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ProblemOnecToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ProblemOnec&&(identical(other.code, code) || other.code == code)&&(identical(other.message, message) || other.message == message));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,code,message);

@override
String toString() {
  return 'ProblemOnec(code: $code, message: $message)';
}


}

/// @nodoc
abstract mixin class _$ProblemOnecCopyWith<$Res> implements $ProblemOnecCopyWith<$Res> {
  factory _$ProblemOnecCopyWith(_ProblemOnec value, $Res Function(_ProblemOnec) _then) = __$ProblemOnecCopyWithImpl;
@override @useResult
$Res call({
 String? code, String? message
});




}
/// @nodoc
class __$ProblemOnecCopyWithImpl<$Res>
    implements _$ProblemOnecCopyWith<$Res> {
  __$ProblemOnecCopyWithImpl(this._self, this._then);

  final _ProblemOnec _self;
  final $Res Function(_ProblemOnec) _then;

/// Create a copy of ProblemOnec
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? code = freezed,Object? message = freezed,}) {
  return _then(_ProblemOnec(
code: freezed == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String?,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$ApiWarning {

 String get code; String get message;
/// Create a copy of ApiWarning
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ApiWarningCopyWith<ApiWarning> get copyWith => _$ApiWarningCopyWithImpl<ApiWarning>(this as ApiWarning, _$identity);

  /// Serializes this ApiWarning to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ApiWarning&&(identical(other.code, code) || other.code == code)&&(identical(other.message, message) || other.message == message));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,code,message);

@override
String toString() {
  return 'ApiWarning(code: $code, message: $message)';
}


}

/// @nodoc
abstract mixin class $ApiWarningCopyWith<$Res>  {
  factory $ApiWarningCopyWith(ApiWarning value, $Res Function(ApiWarning) _then) = _$ApiWarningCopyWithImpl;
@useResult
$Res call({
 String code, String message
});




}
/// @nodoc
class _$ApiWarningCopyWithImpl<$Res>
    implements $ApiWarningCopyWith<$Res> {
  _$ApiWarningCopyWithImpl(this._self, this._then);

  final ApiWarning _self;
  final $Res Function(ApiWarning) _then;

/// Create a copy of ApiWarning
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? code = null,Object? message = null,}) {
  return _then(_self.copyWith(
code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [ApiWarning].
extension ApiWarningPatterns on ApiWarning {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ApiWarning value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ApiWarning() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ApiWarning value)  $default,){
final _that = this;
switch (_that) {
case _ApiWarning():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ApiWarning value)?  $default,){
final _that = this;
switch (_that) {
case _ApiWarning() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String code,  String message)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ApiWarning() when $default != null:
return $default(_that.code,_that.message);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String code,  String message)  $default,) {final _that = this;
switch (_that) {
case _ApiWarning():
return $default(_that.code,_that.message);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String code,  String message)?  $default,) {final _that = this;
switch (_that) {
case _ApiWarning() when $default != null:
return $default(_that.code,_that.message);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ApiWarning extends ApiWarning {
  const _ApiWarning({required this.code, required this.message}): super._();
  factory _ApiWarning.fromJson(Map<String, dynamic> json) => _$ApiWarningFromJson(json);

@override final  String code;
@override final  String message;

/// Create a copy of ApiWarning
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ApiWarningCopyWith<_ApiWarning> get copyWith => __$ApiWarningCopyWithImpl<_ApiWarning>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ApiWarningToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ApiWarning&&(identical(other.code, code) || other.code == code)&&(identical(other.message, message) || other.message == message));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,code,message);

@override
String toString() {
  return 'ApiWarning(code: $code, message: $message)';
}


}

/// @nodoc
abstract mixin class _$ApiWarningCopyWith<$Res> implements $ApiWarningCopyWith<$Res> {
  factory _$ApiWarningCopyWith(_ApiWarning value, $Res Function(_ApiWarning) _then) = __$ApiWarningCopyWithImpl;
@override @useResult
$Res call({
 String code, String message
});




}
/// @nodoc
class __$ApiWarningCopyWithImpl<$Res>
    implements _$ApiWarningCopyWith<$Res> {
  __$ApiWarningCopyWithImpl(this._self, this._then);

  final _ApiWarning _self;
  final $Res Function(_ApiWarning) _then;

/// Create a copy of ApiWarning
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? code = null,Object? message = null,}) {
  return _then(_ApiWarning(
code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
