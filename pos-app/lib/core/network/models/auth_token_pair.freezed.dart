// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'auth_token_pair.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$AuthTokenPair {

 String get accessToken; int get accessExpiresIn; String get refreshToken; DateTime get refreshExpiresAt; String get sid; int? get permissionsVersion;
/// Create a copy of AuthTokenPair
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AuthTokenPairCopyWith<AuthTokenPair> get copyWith => _$AuthTokenPairCopyWithImpl<AuthTokenPair>(this as AuthTokenPair, _$identity);

  /// Serializes this AuthTokenPair to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthTokenPair&&(identical(other.accessToken, accessToken) || other.accessToken == accessToken)&&(identical(other.accessExpiresIn, accessExpiresIn) || other.accessExpiresIn == accessExpiresIn)&&(identical(other.refreshToken, refreshToken) || other.refreshToken == refreshToken)&&(identical(other.refreshExpiresAt, refreshExpiresAt) || other.refreshExpiresAt == refreshExpiresAt)&&(identical(other.sid, sid) || other.sid == sid)&&(identical(other.permissionsVersion, permissionsVersion) || other.permissionsVersion == permissionsVersion));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,accessToken,accessExpiresIn,refreshToken,refreshExpiresAt,sid,permissionsVersion);



}

/// @nodoc
abstract mixin class $AuthTokenPairCopyWith<$Res>  {
  factory $AuthTokenPairCopyWith(AuthTokenPair value, $Res Function(AuthTokenPair) _then) = _$AuthTokenPairCopyWithImpl;
@useResult
$Res call({
 String accessToken, int accessExpiresIn, String refreshToken, DateTime refreshExpiresAt, String sid, int? permissionsVersion
});




}
/// @nodoc
class _$AuthTokenPairCopyWithImpl<$Res>
    implements $AuthTokenPairCopyWith<$Res> {
  _$AuthTokenPairCopyWithImpl(this._self, this._then);

  final AuthTokenPair _self;
  final $Res Function(AuthTokenPair) _then;

/// Create a copy of AuthTokenPair
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? accessToken = null,Object? accessExpiresIn = null,Object? refreshToken = null,Object? refreshExpiresAt = null,Object? sid = null,Object? permissionsVersion = freezed,}) {
  return _then(_self.copyWith(
accessToken: null == accessToken ? _self.accessToken : accessToken // ignore: cast_nullable_to_non_nullable
as String,accessExpiresIn: null == accessExpiresIn ? _self.accessExpiresIn : accessExpiresIn // ignore: cast_nullable_to_non_nullable
as int,refreshToken: null == refreshToken ? _self.refreshToken : refreshToken // ignore: cast_nullable_to_non_nullable
as String,refreshExpiresAt: null == refreshExpiresAt ? _self.refreshExpiresAt : refreshExpiresAt // ignore: cast_nullable_to_non_nullable
as DateTime,sid: null == sid ? _self.sid : sid // ignore: cast_nullable_to_non_nullable
as String,permissionsVersion: freezed == permissionsVersion ? _self.permissionsVersion : permissionsVersion // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

}


/// Adds pattern-matching-related methods to [AuthTokenPair].
extension AuthTokenPairPatterns on AuthTokenPair {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AuthTokenPair value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AuthTokenPair() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AuthTokenPair value)  $default,){
final _that = this;
switch (_that) {
case _AuthTokenPair():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AuthTokenPair value)?  $default,){
final _that = this;
switch (_that) {
case _AuthTokenPair() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String accessToken,  int accessExpiresIn,  String refreshToken,  DateTime refreshExpiresAt,  String sid,  int? permissionsVersion)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AuthTokenPair() when $default != null:
return $default(_that.accessToken,_that.accessExpiresIn,_that.refreshToken,_that.refreshExpiresAt,_that.sid,_that.permissionsVersion);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String accessToken,  int accessExpiresIn,  String refreshToken,  DateTime refreshExpiresAt,  String sid,  int? permissionsVersion)  $default,) {final _that = this;
switch (_that) {
case _AuthTokenPair():
return $default(_that.accessToken,_that.accessExpiresIn,_that.refreshToken,_that.refreshExpiresAt,_that.sid,_that.permissionsVersion);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String accessToken,  int accessExpiresIn,  String refreshToken,  DateTime refreshExpiresAt,  String sid,  int? permissionsVersion)?  $default,) {final _that = this;
switch (_that) {
case _AuthTokenPair() when $default != null:
return $default(_that.accessToken,_that.accessExpiresIn,_that.refreshToken,_that.refreshExpiresAt,_that.sid,_that.permissionsVersion);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AuthTokenPair extends AuthTokenPair {
  const _AuthTokenPair({required this.accessToken, required this.accessExpiresIn, required this.refreshToken, required this.refreshExpiresAt, required this.sid, this.permissionsVersion}): super._();
  factory _AuthTokenPair.fromJson(Map<String, dynamic> json) => _$AuthTokenPairFromJson(json);

@override final  String accessToken;
@override final  int accessExpiresIn;
@override final  String refreshToken;
@override final  DateTime refreshExpiresAt;
@override final  String sid;
@override final  int? permissionsVersion;

/// Create a copy of AuthTokenPair
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AuthTokenPairCopyWith<_AuthTokenPair> get copyWith => __$AuthTokenPairCopyWithImpl<_AuthTokenPair>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AuthTokenPairToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AuthTokenPair&&(identical(other.accessToken, accessToken) || other.accessToken == accessToken)&&(identical(other.accessExpiresIn, accessExpiresIn) || other.accessExpiresIn == accessExpiresIn)&&(identical(other.refreshToken, refreshToken) || other.refreshToken == refreshToken)&&(identical(other.refreshExpiresAt, refreshExpiresAt) || other.refreshExpiresAt == refreshExpiresAt)&&(identical(other.sid, sid) || other.sid == sid)&&(identical(other.permissionsVersion, permissionsVersion) || other.permissionsVersion == permissionsVersion));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,accessToken,accessExpiresIn,refreshToken,refreshExpiresAt,sid,permissionsVersion);



}

/// @nodoc
abstract mixin class _$AuthTokenPairCopyWith<$Res> implements $AuthTokenPairCopyWith<$Res> {
  factory _$AuthTokenPairCopyWith(_AuthTokenPair value, $Res Function(_AuthTokenPair) _then) = __$AuthTokenPairCopyWithImpl;
@override @useResult
$Res call({
 String accessToken, int accessExpiresIn, String refreshToken, DateTime refreshExpiresAt, String sid, int? permissionsVersion
});




}
/// @nodoc
class __$AuthTokenPairCopyWithImpl<$Res>
    implements _$AuthTokenPairCopyWith<$Res> {
  __$AuthTokenPairCopyWithImpl(this._self, this._then);

  final _AuthTokenPair _self;
  final $Res Function(_AuthTokenPair) _then;

/// Create a copy of AuthTokenPair
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? accessToken = null,Object? accessExpiresIn = null,Object? refreshToken = null,Object? refreshExpiresAt = null,Object? sid = null,Object? permissionsVersion = freezed,}) {
  return _then(_AuthTokenPair(
accessToken: null == accessToken ? _self.accessToken : accessToken // ignore: cast_nullable_to_non_nullable
as String,accessExpiresIn: null == accessExpiresIn ? _self.accessExpiresIn : accessExpiresIn // ignore: cast_nullable_to_non_nullable
as int,refreshToken: null == refreshToken ? _self.refreshToken : refreshToken // ignore: cast_nullable_to_non_nullable
as String,refreshExpiresAt: null == refreshExpiresAt ? _self.refreshExpiresAt : refreshExpiresAt // ignore: cast_nullable_to_non_nullable
as DateTime,sid: null == sid ? _self.sid : sid // ignore: cast_nullable_to_non_nullable
as String,permissionsVersion: freezed == permissionsVersion ? _self.permissionsVersion : permissionsVersion // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}

// dart format on
