// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'public_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$PublicSettings {

 List<DeliverySlot>? get deliverySlots; List<SupportContact>? get supportContacts; String? get privacyContact; int? get lowStockThreshold;/// `platform=semver[,…]` (08 §2.11).
 String? get minAppVersion; String? get recommendedAppVersion; String? get customerStockDisplay; PublicFeatures? get features;
/// Create a copy of PublicSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PublicSettingsCopyWith<PublicSettings> get copyWith => _$PublicSettingsCopyWithImpl<PublicSettings>(this as PublicSettings, _$identity);

  /// Serializes this PublicSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PublicSettings&&const DeepCollectionEquality().equals(other.deliverySlots, deliverySlots)&&const DeepCollectionEquality().equals(other.supportContacts, supportContacts)&&(identical(other.privacyContact, privacyContact) || other.privacyContact == privacyContact)&&(identical(other.lowStockThreshold, lowStockThreshold) || other.lowStockThreshold == lowStockThreshold)&&(identical(other.minAppVersion, minAppVersion) || other.minAppVersion == minAppVersion)&&(identical(other.recommendedAppVersion, recommendedAppVersion) || other.recommendedAppVersion == recommendedAppVersion)&&(identical(other.customerStockDisplay, customerStockDisplay) || other.customerStockDisplay == customerStockDisplay)&&(identical(other.features, features) || other.features == features));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(deliverySlots),const DeepCollectionEquality().hash(supportContacts),privacyContact,lowStockThreshold,minAppVersion,recommendedAppVersion,customerStockDisplay,features);

@override
String toString() {
  return 'PublicSettings(deliverySlots: $deliverySlots, supportContacts: $supportContacts, privacyContact: $privacyContact, lowStockThreshold: $lowStockThreshold, minAppVersion: $minAppVersion, recommendedAppVersion: $recommendedAppVersion, customerStockDisplay: $customerStockDisplay, features: $features)';
}


}

/// @nodoc
abstract mixin class $PublicSettingsCopyWith<$Res>  {
  factory $PublicSettingsCopyWith(PublicSettings value, $Res Function(PublicSettings) _then) = _$PublicSettingsCopyWithImpl;
@useResult
$Res call({
 List<DeliverySlot>? deliverySlots, List<SupportContact>? supportContacts, String? privacyContact, int? lowStockThreshold, String? minAppVersion, String? recommendedAppVersion, String? customerStockDisplay, PublicFeatures? features
});


$PublicFeaturesCopyWith<$Res>? get features;

}
/// @nodoc
class _$PublicSettingsCopyWithImpl<$Res>
    implements $PublicSettingsCopyWith<$Res> {
  _$PublicSettingsCopyWithImpl(this._self, this._then);

  final PublicSettings _self;
  final $Res Function(PublicSettings) _then;

/// Create a copy of PublicSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? deliverySlots = freezed,Object? supportContacts = freezed,Object? privacyContact = freezed,Object? lowStockThreshold = freezed,Object? minAppVersion = freezed,Object? recommendedAppVersion = freezed,Object? customerStockDisplay = freezed,Object? features = freezed,}) {
  return _then(_self.copyWith(
deliverySlots: freezed == deliverySlots ? _self.deliverySlots : deliverySlots // ignore: cast_nullable_to_non_nullable
as List<DeliverySlot>?,supportContacts: freezed == supportContacts ? _self.supportContacts : supportContacts // ignore: cast_nullable_to_non_nullable
as List<SupportContact>?,privacyContact: freezed == privacyContact ? _self.privacyContact : privacyContact // ignore: cast_nullable_to_non_nullable
as String?,lowStockThreshold: freezed == lowStockThreshold ? _self.lowStockThreshold : lowStockThreshold // ignore: cast_nullable_to_non_nullable
as int?,minAppVersion: freezed == minAppVersion ? _self.minAppVersion : minAppVersion // ignore: cast_nullable_to_non_nullable
as String?,recommendedAppVersion: freezed == recommendedAppVersion ? _self.recommendedAppVersion : recommendedAppVersion // ignore: cast_nullable_to_non_nullable
as String?,customerStockDisplay: freezed == customerStockDisplay ? _self.customerStockDisplay : customerStockDisplay // ignore: cast_nullable_to_non_nullable
as String?,features: freezed == features ? _self.features : features // ignore: cast_nullable_to_non_nullable
as PublicFeatures?,
  ));
}
/// Create a copy of PublicSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PublicFeaturesCopyWith<$Res>? get features {
    if (_self.features == null) {
    return null;
  }

  return $PublicFeaturesCopyWith<$Res>(_self.features!, (value) {
    return _then(_self.copyWith(features: value));
  });
}
}


/// Adds pattern-matching-related methods to [PublicSettings].
extension PublicSettingsPatterns on PublicSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PublicSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PublicSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PublicSettings value)  $default,){
final _that = this;
switch (_that) {
case _PublicSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PublicSettings value)?  $default,){
final _that = this;
switch (_that) {
case _PublicSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<DeliverySlot>? deliverySlots,  List<SupportContact>? supportContacts,  String? privacyContact,  int? lowStockThreshold,  String? minAppVersion,  String? recommendedAppVersion,  String? customerStockDisplay,  PublicFeatures? features)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PublicSettings() when $default != null:
return $default(_that.deliverySlots,_that.supportContacts,_that.privacyContact,_that.lowStockThreshold,_that.minAppVersion,_that.recommendedAppVersion,_that.customerStockDisplay,_that.features);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<DeliverySlot>? deliverySlots,  List<SupportContact>? supportContacts,  String? privacyContact,  int? lowStockThreshold,  String? minAppVersion,  String? recommendedAppVersion,  String? customerStockDisplay,  PublicFeatures? features)  $default,) {final _that = this;
switch (_that) {
case _PublicSettings():
return $default(_that.deliverySlots,_that.supportContacts,_that.privacyContact,_that.lowStockThreshold,_that.minAppVersion,_that.recommendedAppVersion,_that.customerStockDisplay,_that.features);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<DeliverySlot>? deliverySlots,  List<SupportContact>? supportContacts,  String? privacyContact,  int? lowStockThreshold,  String? minAppVersion,  String? recommendedAppVersion,  String? customerStockDisplay,  PublicFeatures? features)?  $default,) {final _that = this;
switch (_that) {
case _PublicSettings() when $default != null:
return $default(_that.deliverySlots,_that.supportContacts,_that.privacyContact,_that.lowStockThreshold,_that.minAppVersion,_that.recommendedAppVersion,_that.customerStockDisplay,_that.features);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PublicSettings implements PublicSettings {
  const _PublicSettings({final  List<DeliverySlot>? deliverySlots, final  List<SupportContact>? supportContacts, this.privacyContact, this.lowStockThreshold, this.minAppVersion, this.recommendedAppVersion, this.customerStockDisplay, this.features}): _deliverySlots = deliverySlots,_supportContacts = supportContacts;
  factory _PublicSettings.fromJson(Map<String, dynamic> json) => _$PublicSettingsFromJson(json);

 final  List<DeliverySlot>? _deliverySlots;
@override List<DeliverySlot>? get deliverySlots {
  final value = _deliverySlots;
  if (value == null) return null;
  if (_deliverySlots is EqualUnmodifiableListView) return _deliverySlots;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

 final  List<SupportContact>? _supportContacts;
@override List<SupportContact>? get supportContacts {
  final value = _supportContacts;
  if (value == null) return null;
  if (_supportContacts is EqualUnmodifiableListView) return _supportContacts;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

@override final  String? privacyContact;
@override final  int? lowStockThreshold;
/// `platform=semver[,…]` (08 §2.11).
@override final  String? minAppVersion;
@override final  String? recommendedAppVersion;
@override final  String? customerStockDisplay;
@override final  PublicFeatures? features;

/// Create a copy of PublicSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PublicSettingsCopyWith<_PublicSettings> get copyWith => __$PublicSettingsCopyWithImpl<_PublicSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PublicSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PublicSettings&&const DeepCollectionEquality().equals(other._deliverySlots, _deliverySlots)&&const DeepCollectionEquality().equals(other._supportContacts, _supportContacts)&&(identical(other.privacyContact, privacyContact) || other.privacyContact == privacyContact)&&(identical(other.lowStockThreshold, lowStockThreshold) || other.lowStockThreshold == lowStockThreshold)&&(identical(other.minAppVersion, minAppVersion) || other.minAppVersion == minAppVersion)&&(identical(other.recommendedAppVersion, recommendedAppVersion) || other.recommendedAppVersion == recommendedAppVersion)&&(identical(other.customerStockDisplay, customerStockDisplay) || other.customerStockDisplay == customerStockDisplay)&&(identical(other.features, features) || other.features == features));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_deliverySlots),const DeepCollectionEquality().hash(_supportContacts),privacyContact,lowStockThreshold,minAppVersion,recommendedAppVersion,customerStockDisplay,features);

@override
String toString() {
  return 'PublicSettings(deliverySlots: $deliverySlots, supportContacts: $supportContacts, privacyContact: $privacyContact, lowStockThreshold: $lowStockThreshold, minAppVersion: $minAppVersion, recommendedAppVersion: $recommendedAppVersion, customerStockDisplay: $customerStockDisplay, features: $features)';
}


}

/// @nodoc
abstract mixin class _$PublicSettingsCopyWith<$Res> implements $PublicSettingsCopyWith<$Res> {
  factory _$PublicSettingsCopyWith(_PublicSettings value, $Res Function(_PublicSettings) _then) = __$PublicSettingsCopyWithImpl;
@override @useResult
$Res call({
 List<DeliverySlot>? deliverySlots, List<SupportContact>? supportContacts, String? privacyContact, int? lowStockThreshold, String? minAppVersion, String? recommendedAppVersion, String? customerStockDisplay, PublicFeatures? features
});


@override $PublicFeaturesCopyWith<$Res>? get features;

}
/// @nodoc
class __$PublicSettingsCopyWithImpl<$Res>
    implements _$PublicSettingsCopyWith<$Res> {
  __$PublicSettingsCopyWithImpl(this._self, this._then);

  final _PublicSettings _self;
  final $Res Function(_PublicSettings) _then;

/// Create a copy of PublicSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? deliverySlots = freezed,Object? supportContacts = freezed,Object? privacyContact = freezed,Object? lowStockThreshold = freezed,Object? minAppVersion = freezed,Object? recommendedAppVersion = freezed,Object? customerStockDisplay = freezed,Object? features = freezed,}) {
  return _then(_PublicSettings(
deliverySlots: freezed == deliverySlots ? _self._deliverySlots : deliverySlots // ignore: cast_nullable_to_non_nullable
as List<DeliverySlot>?,supportContacts: freezed == supportContacts ? _self._supportContacts : supportContacts // ignore: cast_nullable_to_non_nullable
as List<SupportContact>?,privacyContact: freezed == privacyContact ? _self.privacyContact : privacyContact // ignore: cast_nullable_to_non_nullable
as String?,lowStockThreshold: freezed == lowStockThreshold ? _self.lowStockThreshold : lowStockThreshold // ignore: cast_nullable_to_non_nullable
as int?,minAppVersion: freezed == minAppVersion ? _self.minAppVersion : minAppVersion // ignore: cast_nullable_to_non_nullable
as String?,recommendedAppVersion: freezed == recommendedAppVersion ? _self.recommendedAppVersion : recommendedAppVersion // ignore: cast_nullable_to_non_nullable
as String?,customerStockDisplay: freezed == customerStockDisplay ? _self.customerStockDisplay : customerStockDisplay // ignore: cast_nullable_to_non_nullable
as String?,features: freezed == features ? _self.features : features // ignore: cast_nullable_to_non_nullable
as PublicFeatures?,
  ));
}

/// Create a copy of PublicSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PublicFeaturesCopyWith<$Res>? get features {
    if (_self.features == null) {
    return null;
  }

  return $PublicFeaturesCopyWith<$Res>(_self.features!, (value) {
    return _then(_self.copyWith(features: value));
  });
}
}


/// @nodoc
mixin _$DeliverySlot {

 String get from; String get to;
/// Create a copy of DeliverySlot
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeliverySlotCopyWith<DeliverySlot> get copyWith => _$DeliverySlotCopyWithImpl<DeliverySlot>(this as DeliverySlot, _$identity);

  /// Serializes this DeliverySlot to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeliverySlot&&(identical(other.from, from) || other.from == from)&&(identical(other.to, to) || other.to == to));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,from,to);

@override
String toString() {
  return 'DeliverySlot(from: $from, to: $to)';
}


}

/// @nodoc
abstract mixin class $DeliverySlotCopyWith<$Res>  {
  factory $DeliverySlotCopyWith(DeliverySlot value, $Res Function(DeliverySlot) _then) = _$DeliverySlotCopyWithImpl;
@useResult
$Res call({
 String from, String to
});




}
/// @nodoc
class _$DeliverySlotCopyWithImpl<$Res>
    implements $DeliverySlotCopyWith<$Res> {
  _$DeliverySlotCopyWithImpl(this._self, this._then);

  final DeliverySlot _self;
  final $Res Function(DeliverySlot) _then;

/// Create a copy of DeliverySlot
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? from = null,Object? to = null,}) {
  return _then(_self.copyWith(
from: null == from ? _self.from : from // ignore: cast_nullable_to_non_nullable
as String,to: null == to ? _self.to : to // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [DeliverySlot].
extension DeliverySlotPatterns on DeliverySlot {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _DeliverySlot value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _DeliverySlot() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _DeliverySlot value)  $default,){
final _that = this;
switch (_that) {
case _DeliverySlot():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _DeliverySlot value)?  $default,){
final _that = this;
switch (_that) {
case _DeliverySlot() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String from,  String to)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _DeliverySlot() when $default != null:
return $default(_that.from,_that.to);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String from,  String to)  $default,) {final _that = this;
switch (_that) {
case _DeliverySlot():
return $default(_that.from,_that.to);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String from,  String to)?  $default,) {final _that = this;
switch (_that) {
case _DeliverySlot() when $default != null:
return $default(_that.from,_that.to);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _DeliverySlot implements DeliverySlot {
  const _DeliverySlot({required this.from, required this.to});
  factory _DeliverySlot.fromJson(Map<String, dynamic> json) => _$DeliverySlotFromJson(json);

@override final  String from;
@override final  String to;

/// Create a copy of DeliverySlot
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$DeliverySlotCopyWith<_DeliverySlot> get copyWith => __$DeliverySlotCopyWithImpl<_DeliverySlot>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$DeliverySlotToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _DeliverySlot&&(identical(other.from, from) || other.from == from)&&(identical(other.to, to) || other.to == to));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,from,to);

@override
String toString() {
  return 'DeliverySlot(from: $from, to: $to)';
}


}

/// @nodoc
abstract mixin class _$DeliverySlotCopyWith<$Res> implements $DeliverySlotCopyWith<$Res> {
  factory _$DeliverySlotCopyWith(_DeliverySlot value, $Res Function(_DeliverySlot) _then) = __$DeliverySlotCopyWithImpl;
@override @useResult
$Res call({
 String from, String to
});




}
/// @nodoc
class __$DeliverySlotCopyWithImpl<$Res>
    implements _$DeliverySlotCopyWith<$Res> {
  __$DeliverySlotCopyWithImpl(this._self, this._then);

  final _DeliverySlot _self;
  final $Res Function(_DeliverySlot) _then;

/// Create a copy of DeliverySlot
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? from = null,Object? to = null,}) {
  return _then(_DeliverySlot(
from: null == from ? _self.from : from // ignore: cast_nullable_to_non_nullable
as String,to: null == to ? _self.to : to // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$SupportContact {

 String get kind; String get value; String? get label;
/// Create a copy of SupportContact
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SupportContactCopyWith<SupportContact> get copyWith => _$SupportContactCopyWithImpl<SupportContact>(this as SupportContact, _$identity);

  /// Serializes this SupportContact to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SupportContact&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.value, value) || other.value == value)&&(identical(other.label, label) || other.label == label));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,kind,value,label);

@override
String toString() {
  return 'SupportContact(kind: $kind, value: $value, label: $label)';
}


}

/// @nodoc
abstract mixin class $SupportContactCopyWith<$Res>  {
  factory $SupportContactCopyWith(SupportContact value, $Res Function(SupportContact) _then) = _$SupportContactCopyWithImpl;
@useResult
$Res call({
 String kind, String value, String? label
});




}
/// @nodoc
class _$SupportContactCopyWithImpl<$Res>
    implements $SupportContactCopyWith<$Res> {
  _$SupportContactCopyWithImpl(this._self, this._then);

  final SupportContact _self;
  final $Res Function(SupportContact) _then;

/// Create a copy of SupportContact
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? kind = null,Object? value = null,Object? label = freezed,}) {
  return _then(_self.copyWith(
kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String,label: freezed == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [SupportContact].
extension SupportContactPatterns on SupportContact {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SupportContact value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SupportContact() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SupportContact value)  $default,){
final _that = this;
switch (_that) {
case _SupportContact():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SupportContact value)?  $default,){
final _that = this;
switch (_that) {
case _SupportContact() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String kind,  String value,  String? label)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SupportContact() when $default != null:
return $default(_that.kind,_that.value,_that.label);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String kind,  String value,  String? label)  $default,) {final _that = this;
switch (_that) {
case _SupportContact():
return $default(_that.kind,_that.value,_that.label);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String kind,  String value,  String? label)?  $default,) {final _that = this;
switch (_that) {
case _SupportContact() when $default != null:
return $default(_that.kind,_that.value,_that.label);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SupportContact implements SupportContact {
  const _SupportContact({required this.kind, required this.value, this.label});
  factory _SupportContact.fromJson(Map<String, dynamic> json) => _$SupportContactFromJson(json);

@override final  String kind;
@override final  String value;
@override final  String? label;

/// Create a copy of SupportContact
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SupportContactCopyWith<_SupportContact> get copyWith => __$SupportContactCopyWithImpl<_SupportContact>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SupportContactToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SupportContact&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.value, value) || other.value == value)&&(identical(other.label, label) || other.label == label));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,kind,value,label);

@override
String toString() {
  return 'SupportContact(kind: $kind, value: $value, label: $label)';
}


}

/// @nodoc
abstract mixin class _$SupportContactCopyWith<$Res> implements $SupportContactCopyWith<$Res> {
  factory _$SupportContactCopyWith(_SupportContact value, $Res Function(_SupportContact) _then) = __$SupportContactCopyWithImpl;
@override @useResult
$Res call({
 String kind, String value, String? label
});




}
/// @nodoc
class __$SupportContactCopyWithImpl<$Res>
    implements _$SupportContactCopyWith<$Res> {
  __$SupportContactCopyWithImpl(this._self, this._then);

  final _SupportContact _self;
  final $Res Function(_SupportContact) _then;

/// Create a copy of SupportContact
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? kind = null,Object? value = null,Object? label = freezed,}) {
  return _then(_SupportContact(
kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String,label: freezed == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$PublicFeatures {

 bool? get customerSelfService; bool? get returnsFromPos; String? get qrProvider; bool? get qrWebhook; bool? get debtPaymentsFromPos;
/// Create a copy of PublicFeatures
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PublicFeaturesCopyWith<PublicFeatures> get copyWith => _$PublicFeaturesCopyWithImpl<PublicFeatures>(this as PublicFeatures, _$identity);

  /// Serializes this PublicFeatures to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PublicFeatures&&(identical(other.customerSelfService, customerSelfService) || other.customerSelfService == customerSelfService)&&(identical(other.returnsFromPos, returnsFromPos) || other.returnsFromPos == returnsFromPos)&&(identical(other.qrProvider, qrProvider) || other.qrProvider == qrProvider)&&(identical(other.qrWebhook, qrWebhook) || other.qrWebhook == qrWebhook)&&(identical(other.debtPaymentsFromPos, debtPaymentsFromPos) || other.debtPaymentsFromPos == debtPaymentsFromPos));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,customerSelfService,returnsFromPos,qrProvider,qrWebhook,debtPaymentsFromPos);

@override
String toString() {
  return 'PublicFeatures(customerSelfService: $customerSelfService, returnsFromPos: $returnsFromPos, qrProvider: $qrProvider, qrWebhook: $qrWebhook, debtPaymentsFromPos: $debtPaymentsFromPos)';
}


}

/// @nodoc
abstract mixin class $PublicFeaturesCopyWith<$Res>  {
  factory $PublicFeaturesCopyWith(PublicFeatures value, $Res Function(PublicFeatures) _then) = _$PublicFeaturesCopyWithImpl;
@useResult
$Res call({
 bool? customerSelfService, bool? returnsFromPos, String? qrProvider, bool? qrWebhook, bool? debtPaymentsFromPos
});




}
/// @nodoc
class _$PublicFeaturesCopyWithImpl<$Res>
    implements $PublicFeaturesCopyWith<$Res> {
  _$PublicFeaturesCopyWithImpl(this._self, this._then);

  final PublicFeatures _self;
  final $Res Function(PublicFeatures) _then;

/// Create a copy of PublicFeatures
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? customerSelfService = freezed,Object? returnsFromPos = freezed,Object? qrProvider = freezed,Object? qrWebhook = freezed,Object? debtPaymentsFromPos = freezed,}) {
  return _then(_self.copyWith(
customerSelfService: freezed == customerSelfService ? _self.customerSelfService : customerSelfService // ignore: cast_nullable_to_non_nullable
as bool?,returnsFromPos: freezed == returnsFromPos ? _self.returnsFromPos : returnsFromPos // ignore: cast_nullable_to_non_nullable
as bool?,qrProvider: freezed == qrProvider ? _self.qrProvider : qrProvider // ignore: cast_nullable_to_non_nullable
as String?,qrWebhook: freezed == qrWebhook ? _self.qrWebhook : qrWebhook // ignore: cast_nullable_to_non_nullable
as bool?,debtPaymentsFromPos: freezed == debtPaymentsFromPos ? _self.debtPaymentsFromPos : debtPaymentsFromPos // ignore: cast_nullable_to_non_nullable
as bool?,
  ));
}

}


/// Adds pattern-matching-related methods to [PublicFeatures].
extension PublicFeaturesPatterns on PublicFeatures {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PublicFeatures value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PublicFeatures() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PublicFeatures value)  $default,){
final _that = this;
switch (_that) {
case _PublicFeatures():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PublicFeatures value)?  $default,){
final _that = this;
switch (_that) {
case _PublicFeatures() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool? customerSelfService,  bool? returnsFromPos,  String? qrProvider,  bool? qrWebhook,  bool? debtPaymentsFromPos)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PublicFeatures() when $default != null:
return $default(_that.customerSelfService,_that.returnsFromPos,_that.qrProvider,_that.qrWebhook,_that.debtPaymentsFromPos);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool? customerSelfService,  bool? returnsFromPos,  String? qrProvider,  bool? qrWebhook,  bool? debtPaymentsFromPos)  $default,) {final _that = this;
switch (_that) {
case _PublicFeatures():
return $default(_that.customerSelfService,_that.returnsFromPos,_that.qrProvider,_that.qrWebhook,_that.debtPaymentsFromPos);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool? customerSelfService,  bool? returnsFromPos,  String? qrProvider,  bool? qrWebhook,  bool? debtPaymentsFromPos)?  $default,) {final _that = this;
switch (_that) {
case _PublicFeatures() when $default != null:
return $default(_that.customerSelfService,_that.returnsFromPos,_that.qrProvider,_that.qrWebhook,_that.debtPaymentsFromPos);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PublicFeatures implements PublicFeatures {
  const _PublicFeatures({this.customerSelfService, this.returnsFromPos, this.qrProvider, this.qrWebhook, this.debtPaymentsFromPos});
  factory _PublicFeatures.fromJson(Map<String, dynamic> json) => _$PublicFeaturesFromJson(json);

@override final  bool? customerSelfService;
@override final  bool? returnsFromPos;
@override final  String? qrProvider;
@override final  bool? qrWebhook;
@override final  bool? debtPaymentsFromPos;

/// Create a copy of PublicFeatures
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PublicFeaturesCopyWith<_PublicFeatures> get copyWith => __$PublicFeaturesCopyWithImpl<_PublicFeatures>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PublicFeaturesToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PublicFeatures&&(identical(other.customerSelfService, customerSelfService) || other.customerSelfService == customerSelfService)&&(identical(other.returnsFromPos, returnsFromPos) || other.returnsFromPos == returnsFromPos)&&(identical(other.qrProvider, qrProvider) || other.qrProvider == qrProvider)&&(identical(other.qrWebhook, qrWebhook) || other.qrWebhook == qrWebhook)&&(identical(other.debtPaymentsFromPos, debtPaymentsFromPos) || other.debtPaymentsFromPos == debtPaymentsFromPos));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,customerSelfService,returnsFromPos,qrProvider,qrWebhook,debtPaymentsFromPos);

@override
String toString() {
  return 'PublicFeatures(customerSelfService: $customerSelfService, returnsFromPos: $returnsFromPos, qrProvider: $qrProvider, qrWebhook: $qrWebhook, debtPaymentsFromPos: $debtPaymentsFromPos)';
}


}

/// @nodoc
abstract mixin class _$PublicFeaturesCopyWith<$Res> implements $PublicFeaturesCopyWith<$Res> {
  factory _$PublicFeaturesCopyWith(_PublicFeatures value, $Res Function(_PublicFeatures) _then) = __$PublicFeaturesCopyWithImpl;
@override @useResult
$Res call({
 bool? customerSelfService, bool? returnsFromPos, String? qrProvider, bool? qrWebhook, bool? debtPaymentsFromPos
});




}
/// @nodoc
class __$PublicFeaturesCopyWithImpl<$Res>
    implements _$PublicFeaturesCopyWith<$Res> {
  __$PublicFeaturesCopyWithImpl(this._self, this._then);

  final _PublicFeatures _self;
  final $Res Function(_PublicFeatures) _then;

/// Create a copy of PublicFeatures
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? customerSelfService = freezed,Object? returnsFromPos = freezed,Object? qrProvider = freezed,Object? qrWebhook = freezed,Object? debtPaymentsFromPos = freezed,}) {
  return _then(_PublicFeatures(
customerSelfService: freezed == customerSelfService ? _self.customerSelfService : customerSelfService // ignore: cast_nullable_to_non_nullable
as bool?,returnsFromPos: freezed == returnsFromPos ? _self.returnsFromPos : returnsFromPos // ignore: cast_nullable_to_non_nullable
as bool?,qrProvider: freezed == qrProvider ? _self.qrProvider : qrProvider // ignore: cast_nullable_to_non_nullable
as String?,qrWebhook: freezed == qrWebhook ? _self.qrWebhook : qrWebhook // ignore: cast_nullable_to_non_nullable
as bool?,debtPaymentsFromPos: freezed == debtPaymentsFromPos ? _self.debtPaymentsFromPos : debtPaymentsFromPos // ignore: cast_nullable_to_non_nullable
as bool?,
  ));
}


}

// dart format on
