// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'api_page.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ApiPage<T> {

 List<T> get items; String? get nextCursor; bool get hasMore; int? get totalEstimate; bool? get isEstimate; DateTime? get asOf;
/// Create a copy of ApiPage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ApiPageCopyWith<T, ApiPage<T>> get copyWith => _$ApiPageCopyWithImpl<T, ApiPage<T>>(this as ApiPage<T>, _$identity);

  /// Serializes this ApiPage to a JSON map.
  Map<String, dynamic> toJson(Object? Function(T) toJsonT);


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ApiPage<T>&&const DeepCollectionEquality().equals(other.items, items)&&(identical(other.nextCursor, nextCursor) || other.nextCursor == nextCursor)&&(identical(other.hasMore, hasMore) || other.hasMore == hasMore)&&(identical(other.totalEstimate, totalEstimate) || other.totalEstimate == totalEstimate)&&(identical(other.isEstimate, isEstimate) || other.isEstimate == isEstimate)&&(identical(other.asOf, asOf) || other.asOf == asOf));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(items),nextCursor,hasMore,totalEstimate,isEstimate,asOf);

@override
String toString() {
  return 'ApiPage<$T>(items: $items, nextCursor: $nextCursor, hasMore: $hasMore, totalEstimate: $totalEstimate, isEstimate: $isEstimate, asOf: $asOf)';
}


}

/// @nodoc
abstract mixin class $ApiPageCopyWith<T,$Res>  {
  factory $ApiPageCopyWith(ApiPage<T> value, $Res Function(ApiPage<T>) _then) = _$ApiPageCopyWithImpl;
@useResult
$Res call({
 List<T> items, String? nextCursor, bool hasMore, int? totalEstimate, bool? isEstimate, DateTime? asOf
});




}
/// @nodoc
class _$ApiPageCopyWithImpl<T,$Res>
    implements $ApiPageCopyWith<T, $Res> {
  _$ApiPageCopyWithImpl(this._self, this._then);

  final ApiPage<T> _self;
  final $Res Function(ApiPage<T>) _then;

/// Create a copy of ApiPage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? items = null,Object? nextCursor = freezed,Object? hasMore = null,Object? totalEstimate = freezed,Object? isEstimate = freezed,Object? asOf = freezed,}) {
  return _then(_self.copyWith(
items: null == items ? _self.items : items // ignore: cast_nullable_to_non_nullable
as List<T>,nextCursor: freezed == nextCursor ? _self.nextCursor : nextCursor // ignore: cast_nullable_to_non_nullable
as String?,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,totalEstimate: freezed == totalEstimate ? _self.totalEstimate : totalEstimate // ignore: cast_nullable_to_non_nullable
as int?,isEstimate: freezed == isEstimate ? _self.isEstimate : isEstimate // ignore: cast_nullable_to_non_nullable
as bool?,asOf: freezed == asOf ? _self.asOf : asOf // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [ApiPage].
extension ApiPagePatterns<T> on ApiPage<T> {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ApiPage<T> value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ApiPage() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ApiPage<T> value)  $default,){
final _that = this;
switch (_that) {
case _ApiPage():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ApiPage<T> value)?  $default,){
final _that = this;
switch (_that) {
case _ApiPage() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<T> items,  String? nextCursor,  bool hasMore,  int? totalEstimate,  bool? isEstimate,  DateTime? asOf)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ApiPage() when $default != null:
return $default(_that.items,_that.nextCursor,_that.hasMore,_that.totalEstimate,_that.isEstimate,_that.asOf);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<T> items,  String? nextCursor,  bool hasMore,  int? totalEstimate,  bool? isEstimate,  DateTime? asOf)  $default,) {final _that = this;
switch (_that) {
case _ApiPage():
return $default(_that.items,_that.nextCursor,_that.hasMore,_that.totalEstimate,_that.isEstimate,_that.asOf);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<T> items,  String? nextCursor,  bool hasMore,  int? totalEstimate,  bool? isEstimate,  DateTime? asOf)?  $default,) {final _that = this;
switch (_that) {
case _ApiPage() when $default != null:
return $default(_that.items,_that.nextCursor,_that.hasMore,_that.totalEstimate,_that.isEstimate,_that.asOf);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable(genericArgumentFactories: true)

class _ApiPage<T> implements ApiPage<T> {
  const _ApiPage({required final  List<T> items, required this.nextCursor, required this.hasMore, this.totalEstimate, this.isEstimate, this.asOf}): _items = items;
  factory _ApiPage.fromJson(Map<String, dynamic> json,T Function(Object?) fromJsonT) => _$ApiPageFromJson(json,fromJsonT);

 final  List<T> _items;
@override List<T> get items {
  if (_items is EqualUnmodifiableListView) return _items;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_items);
}

@override final  String? nextCursor;
@override final  bool hasMore;
@override final  int? totalEstimate;
@override final  bool? isEstimate;
@override final  DateTime? asOf;

/// Create a copy of ApiPage
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ApiPageCopyWith<T, _ApiPage<T>> get copyWith => __$ApiPageCopyWithImpl<T, _ApiPage<T>>(this, _$identity);

@override
Map<String, dynamic> toJson(Object? Function(T) toJsonT) {
  return _$ApiPageToJson<T>(this, toJsonT);
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ApiPage<T>&&const DeepCollectionEquality().equals(other._items, _items)&&(identical(other.nextCursor, nextCursor) || other.nextCursor == nextCursor)&&(identical(other.hasMore, hasMore) || other.hasMore == hasMore)&&(identical(other.totalEstimate, totalEstimate) || other.totalEstimate == totalEstimate)&&(identical(other.isEstimate, isEstimate) || other.isEstimate == isEstimate)&&(identical(other.asOf, asOf) || other.asOf == asOf));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_items),nextCursor,hasMore,totalEstimate,isEstimate,asOf);

@override
String toString() {
  return 'ApiPage<$T>(items: $items, nextCursor: $nextCursor, hasMore: $hasMore, totalEstimate: $totalEstimate, isEstimate: $isEstimate, asOf: $asOf)';
}


}

/// @nodoc
abstract mixin class _$ApiPageCopyWith<T,$Res> implements $ApiPageCopyWith<T, $Res> {
  factory _$ApiPageCopyWith(_ApiPage<T> value, $Res Function(_ApiPage<T>) _then) = __$ApiPageCopyWithImpl;
@override @useResult
$Res call({
 List<T> items, String? nextCursor, bool hasMore, int? totalEstimate, bool? isEstimate, DateTime? asOf
});




}
/// @nodoc
class __$ApiPageCopyWithImpl<T,$Res>
    implements _$ApiPageCopyWith<T, $Res> {
  __$ApiPageCopyWithImpl(this._self, this._then);

  final _ApiPage<T> _self;
  final $Res Function(_ApiPage<T>) _then;

/// Create a copy of ApiPage
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? items = null,Object? nextCursor = freezed,Object? hasMore = null,Object? totalEstimate = freezed,Object? isEstimate = freezed,Object? asOf = freezed,}) {
  return _then(_ApiPage<T>(
items: null == items ? _self._items : items // ignore: cast_nullable_to_non_nullable
as List<T>,nextCursor: freezed == nextCursor ? _self.nextCursor : nextCursor // ignore: cast_nullable_to_non_nullable
as String?,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,totalEstimate: freezed == totalEstimate ? _self.totalEstimate : totalEstimate // ignore: cast_nullable_to_non_nullable
as int?,isEstimate: freezed == isEstimate ? _self.isEstimate : isEstimate // ignore: cast_nullable_to_non_nullable
as bool?,asOf: freezed == asOf ? _self.asOf : asOf // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}

// dart format on
