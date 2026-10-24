// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'money_dto.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$MoneyDto {

 String get amount; String get currency;
/// Create a copy of MoneyDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MoneyDtoCopyWith<MoneyDto> get copyWith => _$MoneyDtoCopyWithImpl<MoneyDto>(this as MoneyDto, _$identity);

  /// Serializes this MoneyDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MoneyDto&&(identical(other.amount, amount) || other.amount == amount)&&(identical(other.currency, currency) || other.currency == currency));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,amount,currency);

@override
String toString() {
  return 'MoneyDto(amount: $amount, currency: $currency)';
}


}

/// @nodoc
abstract mixin class $MoneyDtoCopyWith<$Res>  {
  factory $MoneyDtoCopyWith(MoneyDto value, $Res Function(MoneyDto) _then) = _$MoneyDtoCopyWithImpl;
@useResult
$Res call({
 String amount, String currency
});




}
/// @nodoc
class _$MoneyDtoCopyWithImpl<$Res>
    implements $MoneyDtoCopyWith<$Res> {
  _$MoneyDtoCopyWithImpl(this._self, this._then);

  final MoneyDto _self;
  final $Res Function(MoneyDto) _then;

/// Create a copy of MoneyDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? amount = null,Object? currency = null,}) {
  return _then(_self.copyWith(
amount: null == amount ? _self.amount : amount // ignore: cast_nullable_to_non_nullable
as String,currency: null == currency ? _self.currency : currency // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [MoneyDto].
extension MoneyDtoPatterns on MoneyDto {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MoneyDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MoneyDto() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MoneyDto value)  $default,){
final _that = this;
switch (_that) {
case _MoneyDto():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MoneyDto value)?  $default,){
final _that = this;
switch (_that) {
case _MoneyDto() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String amount,  String currency)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MoneyDto() when $default != null:
return $default(_that.amount,_that.currency);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String amount,  String currency)  $default,) {final _that = this;
switch (_that) {
case _MoneyDto():
return $default(_that.amount,_that.currency);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String amount,  String currency)?  $default,) {final _that = this;
switch (_that) {
case _MoneyDto() when $default != null:
return $default(_that.amount,_that.currency);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _MoneyDto extends MoneyDto {
  const _MoneyDto({required this.amount, this.currency = MoneyDto.currencyKgs}): super._();
  factory _MoneyDto.fromJson(Map<String, dynamic> json) => _$MoneyDtoFromJson(json);

@override final  String amount;
@override@JsonKey() final  String currency;

/// Create a copy of MoneyDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MoneyDtoCopyWith<_MoneyDto> get copyWith => __$MoneyDtoCopyWithImpl<_MoneyDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MoneyDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _MoneyDto&&(identical(other.amount, amount) || other.amount == amount)&&(identical(other.currency, currency) || other.currency == currency));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,amount,currency);

@override
String toString() {
  return 'MoneyDto(amount: $amount, currency: $currency)';
}


}

/// @nodoc
abstract mixin class _$MoneyDtoCopyWith<$Res> implements $MoneyDtoCopyWith<$Res> {
  factory _$MoneyDtoCopyWith(_MoneyDto value, $Res Function(_MoneyDto) _then) = __$MoneyDtoCopyWithImpl;
@override @useResult
$Res call({
 String amount, String currency
});




}
/// @nodoc
class __$MoneyDtoCopyWithImpl<$Res>
    implements _$MoneyDtoCopyWith<$Res> {
  __$MoneyDtoCopyWithImpl(this._self, this._then);

  final _MoneyDto _self;
  final $Res Function(_MoneyDto) _then;

/// Create a copy of MoneyDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? amount = null,Object? currency = null,}) {
  return _then(_MoneyDto(
amount: null == amount ? _self.amount : amount // ignore: cast_nullable_to_non_nullable
as String,currency: null == currency ? _self.currency : currency // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
