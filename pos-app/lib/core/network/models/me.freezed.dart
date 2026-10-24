// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'me.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Me {

 String get id; String get kind; String get status; List<String> get roles; List<String> get permissions; int get permissionsVersion; String? get discountLimitPercent; MeProfile? get profile; MeCustomerLink? get customerLink; UserSettings? get settings; MeSecurity? get security; List<Consent>? get consents; MeSession? get session; MeAppVersion? get appVersion; String? get apiVersion; DateTime? get serverTime;
/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeCopyWith<Me> get copyWith => _$MeCopyWithImpl<Me>(this as Me, _$identity);

  /// Serializes this Me to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Me&&(identical(other.id, id) || other.id == id)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.status, status) || other.status == status)&&const DeepCollectionEquality().equals(other.roles, roles)&&const DeepCollectionEquality().equals(other.permissions, permissions)&&(identical(other.permissionsVersion, permissionsVersion) || other.permissionsVersion == permissionsVersion)&&(identical(other.discountLimitPercent, discountLimitPercent) || other.discountLimitPercent == discountLimitPercent)&&(identical(other.profile, profile) || other.profile == profile)&&(identical(other.customerLink, customerLink) || other.customerLink == customerLink)&&(identical(other.settings, settings) || other.settings == settings)&&(identical(other.security, security) || other.security == security)&&const DeepCollectionEquality().equals(other.consents, consents)&&(identical(other.session, session) || other.session == session)&&(identical(other.appVersion, appVersion) || other.appVersion == appVersion)&&(identical(other.apiVersion, apiVersion) || other.apiVersion == apiVersion)&&(identical(other.serverTime, serverTime) || other.serverTime == serverTime));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,kind,status,const DeepCollectionEquality().hash(roles),const DeepCollectionEquality().hash(permissions),permissionsVersion,discountLimitPercent,profile,customerLink,settings,security,const DeepCollectionEquality().hash(consents),session,appVersion,apiVersion,serverTime);



}

/// @nodoc
abstract mixin class $MeCopyWith<$Res>  {
  factory $MeCopyWith(Me value, $Res Function(Me) _then) = _$MeCopyWithImpl;
@useResult
$Res call({
 String id, String kind, String status, List<String> roles, List<String> permissions, int permissionsVersion, String? discountLimitPercent, MeProfile? profile, MeCustomerLink? customerLink, UserSettings? settings, MeSecurity? security, List<Consent>? consents, MeSession? session, MeAppVersion? appVersion, String? apiVersion, DateTime? serverTime
});


$MeProfileCopyWith<$Res>? get profile;$MeCustomerLinkCopyWith<$Res>? get customerLink;$UserSettingsCopyWith<$Res>? get settings;$MeSecurityCopyWith<$Res>? get security;$MeSessionCopyWith<$Res>? get session;$MeAppVersionCopyWith<$Res>? get appVersion;

}
/// @nodoc
class _$MeCopyWithImpl<$Res>
    implements $MeCopyWith<$Res> {
  _$MeCopyWithImpl(this._self, this._then);

  final Me _self;
  final $Res Function(Me) _then;

/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? kind = null,Object? status = null,Object? roles = null,Object? permissions = null,Object? permissionsVersion = null,Object? discountLimitPercent = freezed,Object? profile = freezed,Object? customerLink = freezed,Object? settings = freezed,Object? security = freezed,Object? consents = freezed,Object? session = freezed,Object? appVersion = freezed,Object? apiVersion = freezed,Object? serverTime = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,roles: null == roles ? _self.roles : roles // ignore: cast_nullable_to_non_nullable
as List<String>,permissions: null == permissions ? _self.permissions : permissions // ignore: cast_nullable_to_non_nullable
as List<String>,permissionsVersion: null == permissionsVersion ? _self.permissionsVersion : permissionsVersion // ignore: cast_nullable_to_non_nullable
as int,discountLimitPercent: freezed == discountLimitPercent ? _self.discountLimitPercent : discountLimitPercent // ignore: cast_nullable_to_non_nullable
as String?,profile: freezed == profile ? _self.profile : profile // ignore: cast_nullable_to_non_nullable
as MeProfile?,customerLink: freezed == customerLink ? _self.customerLink : customerLink // ignore: cast_nullable_to_non_nullable
as MeCustomerLink?,settings: freezed == settings ? _self.settings : settings // ignore: cast_nullable_to_non_nullable
as UserSettings?,security: freezed == security ? _self.security : security // ignore: cast_nullable_to_non_nullable
as MeSecurity?,consents: freezed == consents ? _self.consents : consents // ignore: cast_nullable_to_non_nullable
as List<Consent>?,session: freezed == session ? _self.session : session // ignore: cast_nullable_to_non_nullable
as MeSession?,appVersion: freezed == appVersion ? _self.appVersion : appVersion // ignore: cast_nullable_to_non_nullable
as MeAppVersion?,apiVersion: freezed == apiVersion ? _self.apiVersion : apiVersion // ignore: cast_nullable_to_non_nullable
as String?,serverTime: freezed == serverTime ? _self.serverTime : serverTime // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}
/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MeProfileCopyWith<$Res>? get profile {
    if (_self.profile == null) {
    return null;
  }

  return $MeProfileCopyWith<$Res>(_self.profile!, (value) {
    return _then(_self.copyWith(profile: value));
  });
}/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MeCustomerLinkCopyWith<$Res>? get customerLink {
    if (_self.customerLink == null) {
    return null;
  }

  return $MeCustomerLinkCopyWith<$Res>(_self.customerLink!, (value) {
    return _then(_self.copyWith(customerLink: value));
  });
}/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$UserSettingsCopyWith<$Res>? get settings {
    if (_self.settings == null) {
    return null;
  }

  return $UserSettingsCopyWith<$Res>(_self.settings!, (value) {
    return _then(_self.copyWith(settings: value));
  });
}/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MeSecurityCopyWith<$Res>? get security {
    if (_self.security == null) {
    return null;
  }

  return $MeSecurityCopyWith<$Res>(_self.security!, (value) {
    return _then(_self.copyWith(security: value));
  });
}/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MeSessionCopyWith<$Res>? get session {
    if (_self.session == null) {
    return null;
  }

  return $MeSessionCopyWith<$Res>(_self.session!, (value) {
    return _then(_self.copyWith(session: value));
  });
}/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MeAppVersionCopyWith<$Res>? get appVersion {
    if (_self.appVersion == null) {
    return null;
  }

  return $MeAppVersionCopyWith<$Res>(_self.appVersion!, (value) {
    return _then(_self.copyWith(appVersion: value));
  });
}
}


/// Adds pattern-matching-related methods to [Me].
extension MePatterns on Me {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Me value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Me() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Me value)  $default,){
final _that = this;
switch (_that) {
case _Me():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Me value)?  $default,){
final _that = this;
switch (_that) {
case _Me() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String kind,  String status,  List<String> roles,  List<String> permissions,  int permissionsVersion,  String? discountLimitPercent,  MeProfile? profile,  MeCustomerLink? customerLink,  UserSettings? settings,  MeSecurity? security,  List<Consent>? consents,  MeSession? session,  MeAppVersion? appVersion,  String? apiVersion,  DateTime? serverTime)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Me() when $default != null:
return $default(_that.id,_that.kind,_that.status,_that.roles,_that.permissions,_that.permissionsVersion,_that.discountLimitPercent,_that.profile,_that.customerLink,_that.settings,_that.security,_that.consents,_that.session,_that.appVersion,_that.apiVersion,_that.serverTime);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String kind,  String status,  List<String> roles,  List<String> permissions,  int permissionsVersion,  String? discountLimitPercent,  MeProfile? profile,  MeCustomerLink? customerLink,  UserSettings? settings,  MeSecurity? security,  List<Consent>? consents,  MeSession? session,  MeAppVersion? appVersion,  String? apiVersion,  DateTime? serverTime)  $default,) {final _that = this;
switch (_that) {
case _Me():
return $default(_that.id,_that.kind,_that.status,_that.roles,_that.permissions,_that.permissionsVersion,_that.discountLimitPercent,_that.profile,_that.customerLink,_that.settings,_that.security,_that.consents,_that.session,_that.appVersion,_that.apiVersion,_that.serverTime);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String kind,  String status,  List<String> roles,  List<String> permissions,  int permissionsVersion,  String? discountLimitPercent,  MeProfile? profile,  MeCustomerLink? customerLink,  UserSettings? settings,  MeSecurity? security,  List<Consent>? consents,  MeSession? session,  MeAppVersion? appVersion,  String? apiVersion,  DateTime? serverTime)?  $default,) {final _that = this;
switch (_that) {
case _Me() when $default != null:
return $default(_that.id,_that.kind,_that.status,_that.roles,_that.permissions,_that.permissionsVersion,_that.discountLimitPercent,_that.profile,_that.customerLink,_that.settings,_that.security,_that.consents,_that.session,_that.appVersion,_that.apiVersion,_that.serverTime);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Me extends Me {
  const _Me({required this.id, required this.kind, required this.status, required final  List<String> roles, required final  List<String> permissions, required this.permissionsVersion, this.discountLimitPercent, this.profile, this.customerLink, this.settings, this.security, final  List<Consent>? consents, this.session, this.appVersion, this.apiVersion, this.serverTime}): _roles = roles,_permissions = permissions,_consents = consents,super._();
  factory _Me.fromJson(Map<String, dynamic> json) => _$MeFromJson(json);

@override final  String id;
@override final  String kind;
@override final  String status;
 final  List<String> _roles;
@override List<String> get roles {
  if (_roles is EqualUnmodifiableListView) return _roles;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_roles);
}

 final  List<String> _permissions;
@override List<String> get permissions {
  if (_permissions is EqualUnmodifiableListView) return _permissions;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_permissions);
}

@override final  int permissionsVersion;
@override final  String? discountLimitPercent;
@override final  MeProfile? profile;
@override final  MeCustomerLink? customerLink;
@override final  UserSettings? settings;
@override final  MeSecurity? security;
 final  List<Consent>? _consents;
@override List<Consent>? get consents {
  final value = _consents;
  if (value == null) return null;
  if (_consents is EqualUnmodifiableListView) return _consents;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

@override final  MeSession? session;
@override final  MeAppVersion? appVersion;
@override final  String? apiVersion;
@override final  DateTime? serverTime;

/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MeCopyWith<_Me> get copyWith => __$MeCopyWithImpl<_Me>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Me&&(identical(other.id, id) || other.id == id)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.status, status) || other.status == status)&&const DeepCollectionEquality().equals(other._roles, _roles)&&const DeepCollectionEquality().equals(other._permissions, _permissions)&&(identical(other.permissionsVersion, permissionsVersion) || other.permissionsVersion == permissionsVersion)&&(identical(other.discountLimitPercent, discountLimitPercent) || other.discountLimitPercent == discountLimitPercent)&&(identical(other.profile, profile) || other.profile == profile)&&(identical(other.customerLink, customerLink) || other.customerLink == customerLink)&&(identical(other.settings, settings) || other.settings == settings)&&(identical(other.security, security) || other.security == security)&&const DeepCollectionEquality().equals(other._consents, _consents)&&(identical(other.session, session) || other.session == session)&&(identical(other.appVersion, appVersion) || other.appVersion == appVersion)&&(identical(other.apiVersion, apiVersion) || other.apiVersion == apiVersion)&&(identical(other.serverTime, serverTime) || other.serverTime == serverTime));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,kind,status,const DeepCollectionEquality().hash(_roles),const DeepCollectionEquality().hash(_permissions),permissionsVersion,discountLimitPercent,profile,customerLink,settings,security,const DeepCollectionEquality().hash(_consents),session,appVersion,apiVersion,serverTime);



}

/// @nodoc
abstract mixin class _$MeCopyWith<$Res> implements $MeCopyWith<$Res> {
  factory _$MeCopyWith(_Me value, $Res Function(_Me) _then) = __$MeCopyWithImpl;
@override @useResult
$Res call({
 String id, String kind, String status, List<String> roles, List<String> permissions, int permissionsVersion, String? discountLimitPercent, MeProfile? profile, MeCustomerLink? customerLink, UserSettings? settings, MeSecurity? security, List<Consent>? consents, MeSession? session, MeAppVersion? appVersion, String? apiVersion, DateTime? serverTime
});


@override $MeProfileCopyWith<$Res>? get profile;@override $MeCustomerLinkCopyWith<$Res>? get customerLink;@override $UserSettingsCopyWith<$Res>? get settings;@override $MeSecurityCopyWith<$Res>? get security;@override $MeSessionCopyWith<$Res>? get session;@override $MeAppVersionCopyWith<$Res>? get appVersion;

}
/// @nodoc
class __$MeCopyWithImpl<$Res>
    implements _$MeCopyWith<$Res> {
  __$MeCopyWithImpl(this._self, this._then);

  final _Me _self;
  final $Res Function(_Me) _then;

/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? kind = null,Object? status = null,Object? roles = null,Object? permissions = null,Object? permissionsVersion = null,Object? discountLimitPercent = freezed,Object? profile = freezed,Object? customerLink = freezed,Object? settings = freezed,Object? security = freezed,Object? consents = freezed,Object? session = freezed,Object? appVersion = freezed,Object? apiVersion = freezed,Object? serverTime = freezed,}) {
  return _then(_Me(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,roles: null == roles ? _self._roles : roles // ignore: cast_nullable_to_non_nullable
as List<String>,permissions: null == permissions ? _self._permissions : permissions // ignore: cast_nullable_to_non_nullable
as List<String>,permissionsVersion: null == permissionsVersion ? _self.permissionsVersion : permissionsVersion // ignore: cast_nullable_to_non_nullable
as int,discountLimitPercent: freezed == discountLimitPercent ? _self.discountLimitPercent : discountLimitPercent // ignore: cast_nullable_to_non_nullable
as String?,profile: freezed == profile ? _self.profile : profile // ignore: cast_nullable_to_non_nullable
as MeProfile?,customerLink: freezed == customerLink ? _self.customerLink : customerLink // ignore: cast_nullable_to_non_nullable
as MeCustomerLink?,settings: freezed == settings ? _self.settings : settings // ignore: cast_nullable_to_non_nullable
as UserSettings?,security: freezed == security ? _self.security : security // ignore: cast_nullable_to_non_nullable
as MeSecurity?,consents: freezed == consents ? _self._consents : consents // ignore: cast_nullable_to_non_nullable
as List<Consent>?,session: freezed == session ? _self.session : session // ignore: cast_nullable_to_non_nullable
as MeSession?,appVersion: freezed == appVersion ? _self.appVersion : appVersion // ignore: cast_nullable_to_non_nullable
as MeAppVersion?,apiVersion: freezed == apiVersion ? _self.apiVersion : apiVersion // ignore: cast_nullable_to_non_nullable
as String?,serverTime: freezed == serverTime ? _self.serverTime : serverTime // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MeProfileCopyWith<$Res>? get profile {
    if (_self.profile == null) {
    return null;
  }

  return $MeProfileCopyWith<$Res>(_self.profile!, (value) {
    return _then(_self.copyWith(profile: value));
  });
}/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MeCustomerLinkCopyWith<$Res>? get customerLink {
    if (_self.customerLink == null) {
    return null;
  }

  return $MeCustomerLinkCopyWith<$Res>(_self.customerLink!, (value) {
    return _then(_self.copyWith(customerLink: value));
  });
}/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$UserSettingsCopyWith<$Res>? get settings {
    if (_self.settings == null) {
    return null;
  }

  return $UserSettingsCopyWith<$Res>(_self.settings!, (value) {
    return _then(_self.copyWith(settings: value));
  });
}/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MeSecurityCopyWith<$Res>? get security {
    if (_self.security == null) {
    return null;
  }

  return $MeSecurityCopyWith<$Res>(_self.security!, (value) {
    return _then(_self.copyWith(security: value));
  });
}/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MeSessionCopyWith<$Res>? get session {
    if (_self.session == null) {
    return null;
  }

  return $MeSessionCopyWith<$Res>(_self.session!, (value) {
    return _then(_self.copyWith(session: value));
  });
}/// Create a copy of Me
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MeAppVersionCopyWith<$Res>? get appVersion {
    if (_self.appVersion == null) {
    return null;
  }

  return $MeAppVersionCopyWith<$Res>(_self.appVersion!, (value) {
    return _then(_self.copyWith(appVersion: value));
  });
}
}


/// @nodoc
mixin _$MeProfile {

 String? get fullName; String? get phone; int? get birthYear; String? get activitySphere; String? get avatarUrl; int? get rowVersion;
/// Create a copy of MeProfile
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeProfileCopyWith<MeProfile> get copyWith => _$MeProfileCopyWithImpl<MeProfile>(this as MeProfile, _$identity);

  /// Serializes this MeProfile to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeProfile&&(identical(other.fullName, fullName) || other.fullName == fullName)&&(identical(other.phone, phone) || other.phone == phone)&&(identical(other.birthYear, birthYear) || other.birthYear == birthYear)&&(identical(other.activitySphere, activitySphere) || other.activitySphere == activitySphere)&&(identical(other.avatarUrl, avatarUrl) || other.avatarUrl == avatarUrl)&&(identical(other.rowVersion, rowVersion) || other.rowVersion == rowVersion));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,fullName,phone,birthYear,activitySphere,avatarUrl,rowVersion);



}

/// @nodoc
abstract mixin class $MeProfileCopyWith<$Res>  {
  factory $MeProfileCopyWith(MeProfile value, $Res Function(MeProfile) _then) = _$MeProfileCopyWithImpl;
@useResult
$Res call({
 String? fullName, String? phone, int? birthYear, String? activitySphere, String? avatarUrl, int? rowVersion
});




}
/// @nodoc
class _$MeProfileCopyWithImpl<$Res>
    implements $MeProfileCopyWith<$Res> {
  _$MeProfileCopyWithImpl(this._self, this._then);

  final MeProfile _self;
  final $Res Function(MeProfile) _then;

/// Create a copy of MeProfile
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? fullName = freezed,Object? phone = freezed,Object? birthYear = freezed,Object? activitySphere = freezed,Object? avatarUrl = freezed,Object? rowVersion = freezed,}) {
  return _then(_self.copyWith(
fullName: freezed == fullName ? _self.fullName : fullName // ignore: cast_nullable_to_non_nullable
as String?,phone: freezed == phone ? _self.phone : phone // ignore: cast_nullable_to_non_nullable
as String?,birthYear: freezed == birthYear ? _self.birthYear : birthYear // ignore: cast_nullable_to_non_nullable
as int?,activitySphere: freezed == activitySphere ? _self.activitySphere : activitySphere // ignore: cast_nullable_to_non_nullable
as String?,avatarUrl: freezed == avatarUrl ? _self.avatarUrl : avatarUrl // ignore: cast_nullable_to_non_nullable
as String?,rowVersion: freezed == rowVersion ? _self.rowVersion : rowVersion // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

}


/// Adds pattern-matching-related methods to [MeProfile].
extension MeProfilePatterns on MeProfile {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MeProfile value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MeProfile() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MeProfile value)  $default,){
final _that = this;
switch (_that) {
case _MeProfile():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MeProfile value)?  $default,){
final _that = this;
switch (_that) {
case _MeProfile() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? fullName,  String? phone,  int? birthYear,  String? activitySphere,  String? avatarUrl,  int? rowVersion)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MeProfile() when $default != null:
return $default(_that.fullName,_that.phone,_that.birthYear,_that.activitySphere,_that.avatarUrl,_that.rowVersion);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? fullName,  String? phone,  int? birthYear,  String? activitySphere,  String? avatarUrl,  int? rowVersion)  $default,) {final _that = this;
switch (_that) {
case _MeProfile():
return $default(_that.fullName,_that.phone,_that.birthYear,_that.activitySphere,_that.avatarUrl,_that.rowVersion);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? fullName,  String? phone,  int? birthYear,  String? activitySphere,  String? avatarUrl,  int? rowVersion)?  $default,) {final _that = this;
switch (_that) {
case _MeProfile() when $default != null:
return $default(_that.fullName,_that.phone,_that.birthYear,_that.activitySphere,_that.avatarUrl,_that.rowVersion);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _MeProfile extends MeProfile {
  const _MeProfile({this.fullName, this.phone, this.birthYear, this.activitySphere, this.avatarUrl, this.rowVersion}): super._();
  factory _MeProfile.fromJson(Map<String, dynamic> json) => _$MeProfileFromJson(json);

@override final  String? fullName;
@override final  String? phone;
@override final  int? birthYear;
@override final  String? activitySphere;
@override final  String? avatarUrl;
@override final  int? rowVersion;

/// Create a copy of MeProfile
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MeProfileCopyWith<_MeProfile> get copyWith => __$MeProfileCopyWithImpl<_MeProfile>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeProfileToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _MeProfile&&(identical(other.fullName, fullName) || other.fullName == fullName)&&(identical(other.phone, phone) || other.phone == phone)&&(identical(other.birthYear, birthYear) || other.birthYear == birthYear)&&(identical(other.activitySphere, activitySphere) || other.activitySphere == activitySphere)&&(identical(other.avatarUrl, avatarUrl) || other.avatarUrl == avatarUrl)&&(identical(other.rowVersion, rowVersion) || other.rowVersion == rowVersion));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,fullName,phone,birthYear,activitySphere,avatarUrl,rowVersion);



}

/// @nodoc
abstract mixin class _$MeProfileCopyWith<$Res> implements $MeProfileCopyWith<$Res> {
  factory _$MeProfileCopyWith(_MeProfile value, $Res Function(_MeProfile) _then) = __$MeProfileCopyWithImpl;
@override @useResult
$Res call({
 String? fullName, String? phone, int? birthYear, String? activitySphere, String? avatarUrl, int? rowVersion
});




}
/// @nodoc
class __$MeProfileCopyWithImpl<$Res>
    implements _$MeProfileCopyWith<$Res> {
  __$MeProfileCopyWithImpl(this._self, this._then);

  final _MeProfile _self;
  final $Res Function(_MeProfile) _then;

/// Create a copy of MeProfile
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? fullName = freezed,Object? phone = freezed,Object? birthYear = freezed,Object? activitySphere = freezed,Object? avatarUrl = freezed,Object? rowVersion = freezed,}) {
  return _then(_MeProfile(
fullName: freezed == fullName ? _self.fullName : fullName // ignore: cast_nullable_to_non_nullable
as String?,phone: freezed == phone ? _self.phone : phone // ignore: cast_nullable_to_non_nullable
as String?,birthYear: freezed == birthYear ? _self.birthYear : birthYear // ignore: cast_nullable_to_non_nullable
as int?,activitySphere: freezed == activitySphere ? _self.activitySphere : activitySphere // ignore: cast_nullable_to_non_nullable
as String?,avatarUrl: freezed == avatarUrl ? _self.avatarUrl : avatarUrl // ignore: cast_nullable_to_non_nullable
as String?,rowVersion: freezed == rowVersion ? _self.rowVersion : rowVersion // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}


/// @nodoc
mixin _$MeCustomerLink {

 String get status; String? get linkId; String? get displayNameMasked; String? get customerId; String? get displayName;
/// Create a copy of MeCustomerLink
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeCustomerLinkCopyWith<MeCustomerLink> get copyWith => _$MeCustomerLinkCopyWithImpl<MeCustomerLink>(this as MeCustomerLink, _$identity);

  /// Serializes this MeCustomerLink to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeCustomerLink&&(identical(other.status, status) || other.status == status)&&(identical(other.linkId, linkId) || other.linkId == linkId)&&(identical(other.displayNameMasked, displayNameMasked) || other.displayNameMasked == displayNameMasked)&&(identical(other.customerId, customerId) || other.customerId == customerId)&&(identical(other.displayName, displayName) || other.displayName == displayName));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,status,linkId,displayNameMasked,customerId,displayName);



}

/// @nodoc
abstract mixin class $MeCustomerLinkCopyWith<$Res>  {
  factory $MeCustomerLinkCopyWith(MeCustomerLink value, $Res Function(MeCustomerLink) _then) = _$MeCustomerLinkCopyWithImpl;
@useResult
$Res call({
 String status, String? linkId, String? displayNameMasked, String? customerId, String? displayName
});




}
/// @nodoc
class _$MeCustomerLinkCopyWithImpl<$Res>
    implements $MeCustomerLinkCopyWith<$Res> {
  _$MeCustomerLinkCopyWithImpl(this._self, this._then);

  final MeCustomerLink _self;
  final $Res Function(MeCustomerLink) _then;

/// Create a copy of MeCustomerLink
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? status = null,Object? linkId = freezed,Object? displayNameMasked = freezed,Object? customerId = freezed,Object? displayName = freezed,}) {
  return _then(_self.copyWith(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,linkId: freezed == linkId ? _self.linkId : linkId // ignore: cast_nullable_to_non_nullable
as String?,displayNameMasked: freezed == displayNameMasked ? _self.displayNameMasked : displayNameMasked // ignore: cast_nullable_to_non_nullable
as String?,customerId: freezed == customerId ? _self.customerId : customerId // ignore: cast_nullable_to_non_nullable
as String?,displayName: freezed == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [MeCustomerLink].
extension MeCustomerLinkPatterns on MeCustomerLink {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MeCustomerLink value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MeCustomerLink() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MeCustomerLink value)  $default,){
final _that = this;
switch (_that) {
case _MeCustomerLink():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MeCustomerLink value)?  $default,){
final _that = this;
switch (_that) {
case _MeCustomerLink() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String status,  String? linkId,  String? displayNameMasked,  String? customerId,  String? displayName)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MeCustomerLink() when $default != null:
return $default(_that.status,_that.linkId,_that.displayNameMasked,_that.customerId,_that.displayName);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String status,  String? linkId,  String? displayNameMasked,  String? customerId,  String? displayName)  $default,) {final _that = this;
switch (_that) {
case _MeCustomerLink():
return $default(_that.status,_that.linkId,_that.displayNameMasked,_that.customerId,_that.displayName);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String status,  String? linkId,  String? displayNameMasked,  String? customerId,  String? displayName)?  $default,) {final _that = this;
switch (_that) {
case _MeCustomerLink() when $default != null:
return $default(_that.status,_that.linkId,_that.displayNameMasked,_that.customerId,_that.displayName);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _MeCustomerLink extends MeCustomerLink {
  const _MeCustomerLink({required this.status, this.linkId, this.displayNameMasked, this.customerId, this.displayName}): super._();
  factory _MeCustomerLink.fromJson(Map<String, dynamic> json) => _$MeCustomerLinkFromJson(json);

@override final  String status;
@override final  String? linkId;
@override final  String? displayNameMasked;
@override final  String? customerId;
@override final  String? displayName;

/// Create a copy of MeCustomerLink
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MeCustomerLinkCopyWith<_MeCustomerLink> get copyWith => __$MeCustomerLinkCopyWithImpl<_MeCustomerLink>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeCustomerLinkToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _MeCustomerLink&&(identical(other.status, status) || other.status == status)&&(identical(other.linkId, linkId) || other.linkId == linkId)&&(identical(other.displayNameMasked, displayNameMasked) || other.displayNameMasked == displayNameMasked)&&(identical(other.customerId, customerId) || other.customerId == customerId)&&(identical(other.displayName, displayName) || other.displayName == displayName));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,status,linkId,displayNameMasked,customerId,displayName);



}

/// @nodoc
abstract mixin class _$MeCustomerLinkCopyWith<$Res> implements $MeCustomerLinkCopyWith<$Res> {
  factory _$MeCustomerLinkCopyWith(_MeCustomerLink value, $Res Function(_MeCustomerLink) _then) = __$MeCustomerLinkCopyWithImpl;
@override @useResult
$Res call({
 String status, String? linkId, String? displayNameMasked, String? customerId, String? displayName
});




}
/// @nodoc
class __$MeCustomerLinkCopyWithImpl<$Res>
    implements _$MeCustomerLinkCopyWith<$Res> {
  __$MeCustomerLinkCopyWithImpl(this._self, this._then);

  final _MeCustomerLink _self;
  final $Res Function(_MeCustomerLink) _then;

/// Create a copy of MeCustomerLink
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? status = null,Object? linkId = freezed,Object? displayNameMasked = freezed,Object? customerId = freezed,Object? displayName = freezed,}) {
  return _then(_MeCustomerLink(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,linkId: freezed == linkId ? _self.linkId : linkId // ignore: cast_nullable_to_non_nullable
as String?,displayNameMasked: freezed == displayNameMasked ? _self.displayNameMasked : displayNameMasked // ignore: cast_nullable_to_non_nullable
as String?,customerId: freezed == customerId ? _self.customerId : customerId // ignore: cast_nullable_to_non_nullable
as String?,displayName: freezed == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$UserSettings {

 String? get locale; ScannerSettings? get scanner; bool? get scanAddsToCart; PrinterSettings? get printer; String? get catalogView; String? get defaultWarehouseId; int? get idleLockMinutes; int? get rowVersion;
/// Create a copy of UserSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserSettingsCopyWith<UserSettings> get copyWith => _$UserSettingsCopyWithImpl<UserSettings>(this as UserSettings, _$identity);

  /// Serializes this UserSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UserSettings&&(identical(other.locale, locale) || other.locale == locale)&&(identical(other.scanner, scanner) || other.scanner == scanner)&&(identical(other.scanAddsToCart, scanAddsToCart) || other.scanAddsToCart == scanAddsToCart)&&(identical(other.printer, printer) || other.printer == printer)&&(identical(other.catalogView, catalogView) || other.catalogView == catalogView)&&(identical(other.defaultWarehouseId, defaultWarehouseId) || other.defaultWarehouseId == defaultWarehouseId)&&(identical(other.idleLockMinutes, idleLockMinutes) || other.idleLockMinutes == idleLockMinutes)&&(identical(other.rowVersion, rowVersion) || other.rowVersion == rowVersion));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,locale,scanner,scanAddsToCart,printer,catalogView,defaultWarehouseId,idleLockMinutes,rowVersion);

@override
String toString() {
  return 'UserSettings(locale: $locale, scanner: $scanner, scanAddsToCart: $scanAddsToCart, printer: $printer, catalogView: $catalogView, defaultWarehouseId: $defaultWarehouseId, idleLockMinutes: $idleLockMinutes, rowVersion: $rowVersion)';
}


}

/// @nodoc
abstract mixin class $UserSettingsCopyWith<$Res>  {
  factory $UserSettingsCopyWith(UserSettings value, $Res Function(UserSettings) _then) = _$UserSettingsCopyWithImpl;
@useResult
$Res call({
 String? locale, ScannerSettings? scanner, bool? scanAddsToCart, PrinterSettings? printer, String? catalogView, String? defaultWarehouseId, int? idleLockMinutes, int? rowVersion
});


$ScannerSettingsCopyWith<$Res>? get scanner;$PrinterSettingsCopyWith<$Res>? get printer;

}
/// @nodoc
class _$UserSettingsCopyWithImpl<$Res>
    implements $UserSettingsCopyWith<$Res> {
  _$UserSettingsCopyWithImpl(this._self, this._then);

  final UserSettings _self;
  final $Res Function(UserSettings) _then;

/// Create a copy of UserSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? locale = freezed,Object? scanner = freezed,Object? scanAddsToCart = freezed,Object? printer = freezed,Object? catalogView = freezed,Object? defaultWarehouseId = freezed,Object? idleLockMinutes = freezed,Object? rowVersion = freezed,}) {
  return _then(_self.copyWith(
locale: freezed == locale ? _self.locale : locale // ignore: cast_nullable_to_non_nullable
as String?,scanner: freezed == scanner ? _self.scanner : scanner // ignore: cast_nullable_to_non_nullable
as ScannerSettings?,scanAddsToCart: freezed == scanAddsToCart ? _self.scanAddsToCart : scanAddsToCart // ignore: cast_nullable_to_non_nullable
as bool?,printer: freezed == printer ? _self.printer : printer // ignore: cast_nullable_to_non_nullable
as PrinterSettings?,catalogView: freezed == catalogView ? _self.catalogView : catalogView // ignore: cast_nullable_to_non_nullable
as String?,defaultWarehouseId: freezed == defaultWarehouseId ? _self.defaultWarehouseId : defaultWarehouseId // ignore: cast_nullable_to_non_nullable
as String?,idleLockMinutes: freezed == idleLockMinutes ? _self.idleLockMinutes : idleLockMinutes // ignore: cast_nullable_to_non_nullable
as int?,rowVersion: freezed == rowVersion ? _self.rowVersion : rowVersion // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}
/// Create a copy of UserSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ScannerSettingsCopyWith<$Res>? get scanner {
    if (_self.scanner == null) {
    return null;
  }

  return $ScannerSettingsCopyWith<$Res>(_self.scanner!, (value) {
    return _then(_self.copyWith(scanner: value));
  });
}/// Create a copy of UserSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PrinterSettingsCopyWith<$Res>? get printer {
    if (_self.printer == null) {
    return null;
  }

  return $PrinterSettingsCopyWith<$Res>(_self.printer!, (value) {
    return _then(_self.copyWith(printer: value));
  });
}
}


/// Adds pattern-matching-related methods to [UserSettings].
extension UserSettingsPatterns on UserSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _UserSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _UserSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _UserSettings value)  $default,){
final _that = this;
switch (_that) {
case _UserSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _UserSettings value)?  $default,){
final _that = this;
switch (_that) {
case _UserSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? locale,  ScannerSettings? scanner,  bool? scanAddsToCart,  PrinterSettings? printer,  String? catalogView,  String? defaultWarehouseId,  int? idleLockMinutes,  int? rowVersion)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _UserSettings() when $default != null:
return $default(_that.locale,_that.scanner,_that.scanAddsToCart,_that.printer,_that.catalogView,_that.defaultWarehouseId,_that.idleLockMinutes,_that.rowVersion);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? locale,  ScannerSettings? scanner,  bool? scanAddsToCart,  PrinterSettings? printer,  String? catalogView,  String? defaultWarehouseId,  int? idleLockMinutes,  int? rowVersion)  $default,) {final _that = this;
switch (_that) {
case _UserSettings():
return $default(_that.locale,_that.scanner,_that.scanAddsToCart,_that.printer,_that.catalogView,_that.defaultWarehouseId,_that.idleLockMinutes,_that.rowVersion);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? locale,  ScannerSettings? scanner,  bool? scanAddsToCart,  PrinterSettings? printer,  String? catalogView,  String? defaultWarehouseId,  int? idleLockMinutes,  int? rowVersion)?  $default,) {final _that = this;
switch (_that) {
case _UserSettings() when $default != null:
return $default(_that.locale,_that.scanner,_that.scanAddsToCart,_that.printer,_that.catalogView,_that.defaultWarehouseId,_that.idleLockMinutes,_that.rowVersion);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _UserSettings implements UserSettings {
  const _UserSettings({this.locale, this.scanner, this.scanAddsToCart, this.printer, this.catalogView, this.defaultWarehouseId, this.idleLockMinutes, this.rowVersion});
  factory _UserSettings.fromJson(Map<String, dynamic> json) => _$UserSettingsFromJson(json);

@override final  String? locale;
@override final  ScannerSettings? scanner;
@override final  bool? scanAddsToCart;
@override final  PrinterSettings? printer;
@override final  String? catalogView;
@override final  String? defaultWarehouseId;
@override final  int? idleLockMinutes;
@override final  int? rowVersion;

/// Create a copy of UserSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$UserSettingsCopyWith<_UserSettings> get copyWith => __$UserSettingsCopyWithImpl<_UserSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$UserSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _UserSettings&&(identical(other.locale, locale) || other.locale == locale)&&(identical(other.scanner, scanner) || other.scanner == scanner)&&(identical(other.scanAddsToCart, scanAddsToCart) || other.scanAddsToCart == scanAddsToCart)&&(identical(other.printer, printer) || other.printer == printer)&&(identical(other.catalogView, catalogView) || other.catalogView == catalogView)&&(identical(other.defaultWarehouseId, defaultWarehouseId) || other.defaultWarehouseId == defaultWarehouseId)&&(identical(other.idleLockMinutes, idleLockMinutes) || other.idleLockMinutes == idleLockMinutes)&&(identical(other.rowVersion, rowVersion) || other.rowVersion == rowVersion));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,locale,scanner,scanAddsToCart,printer,catalogView,defaultWarehouseId,idleLockMinutes,rowVersion);

@override
String toString() {
  return 'UserSettings(locale: $locale, scanner: $scanner, scanAddsToCart: $scanAddsToCart, printer: $printer, catalogView: $catalogView, defaultWarehouseId: $defaultWarehouseId, idleLockMinutes: $idleLockMinutes, rowVersion: $rowVersion)';
}


}

/// @nodoc
abstract mixin class _$UserSettingsCopyWith<$Res> implements $UserSettingsCopyWith<$Res> {
  factory _$UserSettingsCopyWith(_UserSettings value, $Res Function(_UserSettings) _then) = __$UserSettingsCopyWithImpl;
@override @useResult
$Res call({
 String? locale, ScannerSettings? scanner, bool? scanAddsToCart, PrinterSettings? printer, String? catalogView, String? defaultWarehouseId, int? idleLockMinutes, int? rowVersion
});


@override $ScannerSettingsCopyWith<$Res>? get scanner;@override $PrinterSettingsCopyWith<$Res>? get printer;

}
/// @nodoc
class __$UserSettingsCopyWithImpl<$Res>
    implements _$UserSettingsCopyWith<$Res> {
  __$UserSettingsCopyWithImpl(this._self, this._then);

  final _UserSettings _self;
  final $Res Function(_UserSettings) _then;

/// Create a copy of UserSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? locale = freezed,Object? scanner = freezed,Object? scanAddsToCart = freezed,Object? printer = freezed,Object? catalogView = freezed,Object? defaultWarehouseId = freezed,Object? idleLockMinutes = freezed,Object? rowVersion = freezed,}) {
  return _then(_UserSettings(
locale: freezed == locale ? _self.locale : locale // ignore: cast_nullable_to_non_nullable
as String?,scanner: freezed == scanner ? _self.scanner : scanner // ignore: cast_nullable_to_non_nullable
as ScannerSettings?,scanAddsToCart: freezed == scanAddsToCart ? _self.scanAddsToCart : scanAddsToCart // ignore: cast_nullable_to_non_nullable
as bool?,printer: freezed == printer ? _self.printer : printer // ignore: cast_nullable_to_non_nullable
as PrinterSettings?,catalogView: freezed == catalogView ? _self.catalogView : catalogView // ignore: cast_nullable_to_non_nullable
as String?,defaultWarehouseId: freezed == defaultWarehouseId ? _self.defaultWarehouseId : defaultWarehouseId // ignore: cast_nullable_to_non_nullable
as String?,idleLockMinutes: freezed == idleLockMinutes ? _self.idleLockMinutes : idleLockMinutes // ignore: cast_nullable_to_non_nullable
as int?,rowVersion: freezed == rowVersion ? _self.rowVersion : rowVersion // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

/// Create a copy of UserSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ScannerSettingsCopyWith<$Res>? get scanner {
    if (_self.scanner == null) {
    return null;
  }

  return $ScannerSettingsCopyWith<$Res>(_self.scanner!, (value) {
    return _then(_self.copyWith(scanner: value));
  });
}/// Create a copy of UserSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PrinterSettingsCopyWith<$Res>? get printer {
    if (_self.printer == null) {
    return null;
  }

  return $PrinterSettingsCopyWith<$Res>(_self.printer!, (value) {
    return _then(_self.copyWith(printer: value));
  });
}
}


/// @nodoc
mixin _$ScannerSettings {

 String? get mode; String? get suffix;
/// Create a copy of ScannerSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ScannerSettingsCopyWith<ScannerSettings> get copyWith => _$ScannerSettingsCopyWithImpl<ScannerSettings>(this as ScannerSettings, _$identity);

  /// Serializes this ScannerSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ScannerSettings&&(identical(other.mode, mode) || other.mode == mode)&&(identical(other.suffix, suffix) || other.suffix == suffix));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,mode,suffix);

@override
String toString() {
  return 'ScannerSettings(mode: $mode, suffix: $suffix)';
}


}

/// @nodoc
abstract mixin class $ScannerSettingsCopyWith<$Res>  {
  factory $ScannerSettingsCopyWith(ScannerSettings value, $Res Function(ScannerSettings) _then) = _$ScannerSettingsCopyWithImpl;
@useResult
$Res call({
 String? mode, String? suffix
});




}
/// @nodoc
class _$ScannerSettingsCopyWithImpl<$Res>
    implements $ScannerSettingsCopyWith<$Res> {
  _$ScannerSettingsCopyWithImpl(this._self, this._then);

  final ScannerSettings _self;
  final $Res Function(ScannerSettings) _then;

/// Create a copy of ScannerSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? mode = freezed,Object? suffix = freezed,}) {
  return _then(_self.copyWith(
mode: freezed == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as String?,suffix: freezed == suffix ? _self.suffix : suffix // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ScannerSettings].
extension ScannerSettingsPatterns on ScannerSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ScannerSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ScannerSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ScannerSettings value)  $default,){
final _that = this;
switch (_that) {
case _ScannerSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ScannerSettings value)?  $default,){
final _that = this;
switch (_that) {
case _ScannerSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? mode,  String? suffix)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ScannerSettings() when $default != null:
return $default(_that.mode,_that.suffix);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? mode,  String? suffix)  $default,) {final _that = this;
switch (_that) {
case _ScannerSettings():
return $default(_that.mode,_that.suffix);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? mode,  String? suffix)?  $default,) {final _that = this;
switch (_that) {
case _ScannerSettings() when $default != null:
return $default(_that.mode,_that.suffix);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ScannerSettings implements ScannerSettings {
  const _ScannerSettings({this.mode, this.suffix});
  factory _ScannerSettings.fromJson(Map<String, dynamic> json) => _$ScannerSettingsFromJson(json);

@override final  String? mode;
@override final  String? suffix;

/// Create a copy of ScannerSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ScannerSettingsCopyWith<_ScannerSettings> get copyWith => __$ScannerSettingsCopyWithImpl<_ScannerSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ScannerSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ScannerSettings&&(identical(other.mode, mode) || other.mode == mode)&&(identical(other.suffix, suffix) || other.suffix == suffix));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,mode,suffix);

@override
String toString() {
  return 'ScannerSettings(mode: $mode, suffix: $suffix)';
}


}

/// @nodoc
abstract mixin class _$ScannerSettingsCopyWith<$Res> implements $ScannerSettingsCopyWith<$Res> {
  factory _$ScannerSettingsCopyWith(_ScannerSettings value, $Res Function(_ScannerSettings) _then) = __$ScannerSettingsCopyWithImpl;
@override @useResult
$Res call({
 String? mode, String? suffix
});




}
/// @nodoc
class __$ScannerSettingsCopyWithImpl<$Res>
    implements _$ScannerSettingsCopyWith<$Res> {
  __$ScannerSettingsCopyWithImpl(this._self, this._then);

  final _ScannerSettings _self;
  final $Res Function(_ScannerSettings) _then;

/// Create a copy of ScannerSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? mode = freezed,Object? suffix = freezed,}) {
  return _then(_ScannerSettings(
mode: freezed == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as String?,suffix: freezed == suffix ? _self.suffix : suffix // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$PrinterSettings {

 String? get defaultFormat; bool? get autoPrint;
/// Create a copy of PrinterSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PrinterSettingsCopyWith<PrinterSettings> get copyWith => _$PrinterSettingsCopyWithImpl<PrinterSettings>(this as PrinterSettings, _$identity);

  /// Serializes this PrinterSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PrinterSettings&&(identical(other.defaultFormat, defaultFormat) || other.defaultFormat == defaultFormat)&&(identical(other.autoPrint, autoPrint) || other.autoPrint == autoPrint));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,defaultFormat,autoPrint);

@override
String toString() {
  return 'PrinterSettings(defaultFormat: $defaultFormat, autoPrint: $autoPrint)';
}


}

/// @nodoc
abstract mixin class $PrinterSettingsCopyWith<$Res>  {
  factory $PrinterSettingsCopyWith(PrinterSettings value, $Res Function(PrinterSettings) _then) = _$PrinterSettingsCopyWithImpl;
@useResult
$Res call({
 String? defaultFormat, bool? autoPrint
});




}
/// @nodoc
class _$PrinterSettingsCopyWithImpl<$Res>
    implements $PrinterSettingsCopyWith<$Res> {
  _$PrinterSettingsCopyWithImpl(this._self, this._then);

  final PrinterSettings _self;
  final $Res Function(PrinterSettings) _then;

/// Create a copy of PrinterSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? defaultFormat = freezed,Object? autoPrint = freezed,}) {
  return _then(_self.copyWith(
defaultFormat: freezed == defaultFormat ? _self.defaultFormat : defaultFormat // ignore: cast_nullable_to_non_nullable
as String?,autoPrint: freezed == autoPrint ? _self.autoPrint : autoPrint // ignore: cast_nullable_to_non_nullable
as bool?,
  ));
}

}


/// Adds pattern-matching-related methods to [PrinterSettings].
extension PrinterSettingsPatterns on PrinterSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PrinterSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PrinterSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PrinterSettings value)  $default,){
final _that = this;
switch (_that) {
case _PrinterSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PrinterSettings value)?  $default,){
final _that = this;
switch (_that) {
case _PrinterSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? defaultFormat,  bool? autoPrint)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PrinterSettings() when $default != null:
return $default(_that.defaultFormat,_that.autoPrint);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? defaultFormat,  bool? autoPrint)  $default,) {final _that = this;
switch (_that) {
case _PrinterSettings():
return $default(_that.defaultFormat,_that.autoPrint);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? defaultFormat,  bool? autoPrint)?  $default,) {final _that = this;
switch (_that) {
case _PrinterSettings() when $default != null:
return $default(_that.defaultFormat,_that.autoPrint);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PrinterSettings implements PrinterSettings {
  const _PrinterSettings({this.defaultFormat, this.autoPrint});
  factory _PrinterSettings.fromJson(Map<String, dynamic> json) => _$PrinterSettingsFromJson(json);

@override final  String? defaultFormat;
@override final  bool? autoPrint;

/// Create a copy of PrinterSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PrinterSettingsCopyWith<_PrinterSettings> get copyWith => __$PrinterSettingsCopyWithImpl<_PrinterSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PrinterSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PrinterSettings&&(identical(other.defaultFormat, defaultFormat) || other.defaultFormat == defaultFormat)&&(identical(other.autoPrint, autoPrint) || other.autoPrint == autoPrint));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,defaultFormat,autoPrint);

@override
String toString() {
  return 'PrinterSettings(defaultFormat: $defaultFormat, autoPrint: $autoPrint)';
}


}

/// @nodoc
abstract mixin class _$PrinterSettingsCopyWith<$Res> implements $PrinterSettingsCopyWith<$Res> {
  factory _$PrinterSettingsCopyWith(_PrinterSettings value, $Res Function(_PrinterSettings) _then) = __$PrinterSettingsCopyWithImpl;
@override @useResult
$Res call({
 String? defaultFormat, bool? autoPrint
});




}
/// @nodoc
class __$PrinterSettingsCopyWithImpl<$Res>
    implements _$PrinterSettingsCopyWith<$Res> {
  __$PrinterSettingsCopyWithImpl(this._self, this._then);

  final _PrinterSettings _self;
  final $Res Function(_PrinterSettings) _then;

/// Create a copy of PrinterSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? defaultFormat = freezed,Object? autoPrint = freezed,}) {
  return _then(_PrinterSettings(
defaultFormat: freezed == defaultFormat ? _self.defaultFormat : defaultFormat // ignore: cast_nullable_to_non_nullable
as String?,autoPrint: freezed == autoPrint ? _self.autoPrint : autoPrint // ignore: cast_nullable_to_non_nullable
as bool?,
  ));
}


}


/// @nodoc
mixin _$MeSecurity {

 bool? get pinSet; bool? get biometricsEnabled; String? get biometricsPlatform;
/// Create a copy of MeSecurity
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeSecurityCopyWith<MeSecurity> get copyWith => _$MeSecurityCopyWithImpl<MeSecurity>(this as MeSecurity, _$identity);

  /// Serializes this MeSecurity to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeSecurity&&(identical(other.pinSet, pinSet) || other.pinSet == pinSet)&&(identical(other.biometricsEnabled, biometricsEnabled) || other.biometricsEnabled == biometricsEnabled)&&(identical(other.biometricsPlatform, biometricsPlatform) || other.biometricsPlatform == biometricsPlatform));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,pinSet,biometricsEnabled,biometricsPlatform);

@override
String toString() {
  return 'MeSecurity(pinSet: $pinSet, biometricsEnabled: $biometricsEnabled, biometricsPlatform: $biometricsPlatform)';
}


}

/// @nodoc
abstract mixin class $MeSecurityCopyWith<$Res>  {
  factory $MeSecurityCopyWith(MeSecurity value, $Res Function(MeSecurity) _then) = _$MeSecurityCopyWithImpl;
@useResult
$Res call({
 bool? pinSet, bool? biometricsEnabled, String? biometricsPlatform
});




}
/// @nodoc
class _$MeSecurityCopyWithImpl<$Res>
    implements $MeSecurityCopyWith<$Res> {
  _$MeSecurityCopyWithImpl(this._self, this._then);

  final MeSecurity _self;
  final $Res Function(MeSecurity) _then;

/// Create a copy of MeSecurity
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? pinSet = freezed,Object? biometricsEnabled = freezed,Object? biometricsPlatform = freezed,}) {
  return _then(_self.copyWith(
pinSet: freezed == pinSet ? _self.pinSet : pinSet // ignore: cast_nullable_to_non_nullable
as bool?,biometricsEnabled: freezed == biometricsEnabled ? _self.biometricsEnabled : biometricsEnabled // ignore: cast_nullable_to_non_nullable
as bool?,biometricsPlatform: freezed == biometricsPlatform ? _self.biometricsPlatform : biometricsPlatform // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [MeSecurity].
extension MeSecurityPatterns on MeSecurity {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MeSecurity value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MeSecurity() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MeSecurity value)  $default,){
final _that = this;
switch (_that) {
case _MeSecurity():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MeSecurity value)?  $default,){
final _that = this;
switch (_that) {
case _MeSecurity() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool? pinSet,  bool? biometricsEnabled,  String? biometricsPlatform)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MeSecurity() when $default != null:
return $default(_that.pinSet,_that.biometricsEnabled,_that.biometricsPlatform);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool? pinSet,  bool? biometricsEnabled,  String? biometricsPlatform)  $default,) {final _that = this;
switch (_that) {
case _MeSecurity():
return $default(_that.pinSet,_that.biometricsEnabled,_that.biometricsPlatform);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool? pinSet,  bool? biometricsEnabled,  String? biometricsPlatform)?  $default,) {final _that = this;
switch (_that) {
case _MeSecurity() when $default != null:
return $default(_that.pinSet,_that.biometricsEnabled,_that.biometricsPlatform);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _MeSecurity implements MeSecurity {
  const _MeSecurity({this.pinSet, this.biometricsEnabled, this.biometricsPlatform});
  factory _MeSecurity.fromJson(Map<String, dynamic> json) => _$MeSecurityFromJson(json);

@override final  bool? pinSet;
@override final  bool? biometricsEnabled;
@override final  String? biometricsPlatform;

/// Create a copy of MeSecurity
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MeSecurityCopyWith<_MeSecurity> get copyWith => __$MeSecurityCopyWithImpl<_MeSecurity>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeSecurityToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _MeSecurity&&(identical(other.pinSet, pinSet) || other.pinSet == pinSet)&&(identical(other.biometricsEnabled, biometricsEnabled) || other.biometricsEnabled == biometricsEnabled)&&(identical(other.biometricsPlatform, biometricsPlatform) || other.biometricsPlatform == biometricsPlatform));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,pinSet,biometricsEnabled,biometricsPlatform);

@override
String toString() {
  return 'MeSecurity(pinSet: $pinSet, biometricsEnabled: $biometricsEnabled, biometricsPlatform: $biometricsPlatform)';
}


}

/// @nodoc
abstract mixin class _$MeSecurityCopyWith<$Res> implements $MeSecurityCopyWith<$Res> {
  factory _$MeSecurityCopyWith(_MeSecurity value, $Res Function(_MeSecurity) _then) = __$MeSecurityCopyWithImpl;
@override @useResult
$Res call({
 bool? pinSet, bool? biometricsEnabled, String? biometricsPlatform
});




}
/// @nodoc
class __$MeSecurityCopyWithImpl<$Res>
    implements _$MeSecurityCopyWith<$Res> {
  __$MeSecurityCopyWithImpl(this._self, this._then);

  final _MeSecurity _self;
  final $Res Function(_MeSecurity) _then;

/// Create a copy of MeSecurity
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? pinSet = freezed,Object? biometricsEnabled = freezed,Object? biometricsPlatform = freezed,}) {
  return _then(_MeSecurity(
pinSet: freezed == pinSet ? _self.pinSet : pinSet // ignore: cast_nullable_to_non_nullable
as bool?,biometricsEnabled: freezed == biometricsEnabled ? _self.biometricsEnabled : biometricsEnabled // ignore: cast_nullable_to_non_nullable
as bool?,biometricsPlatform: freezed == biometricsPlatform ? _self.biometricsPlatform : biometricsPlatform // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$Consent {

 String get kind; String get version; bool get granted; DateTime? get grantedAt; DateTime? get revokedAt;
/// Create a copy of Consent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConsentCopyWith<Consent> get copyWith => _$ConsentCopyWithImpl<Consent>(this as Consent, _$identity);

  /// Serializes this Consent to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Consent&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.version, version) || other.version == version)&&(identical(other.granted, granted) || other.granted == granted)&&(identical(other.grantedAt, grantedAt) || other.grantedAt == grantedAt)&&(identical(other.revokedAt, revokedAt) || other.revokedAt == revokedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,kind,version,granted,grantedAt,revokedAt);

@override
String toString() {
  return 'Consent(kind: $kind, version: $version, granted: $granted, grantedAt: $grantedAt, revokedAt: $revokedAt)';
}


}

/// @nodoc
abstract mixin class $ConsentCopyWith<$Res>  {
  factory $ConsentCopyWith(Consent value, $Res Function(Consent) _then) = _$ConsentCopyWithImpl;
@useResult
$Res call({
 String kind, String version, bool granted, DateTime? grantedAt, DateTime? revokedAt
});




}
/// @nodoc
class _$ConsentCopyWithImpl<$Res>
    implements $ConsentCopyWith<$Res> {
  _$ConsentCopyWithImpl(this._self, this._then);

  final Consent _self;
  final $Res Function(Consent) _then;

/// Create a copy of Consent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? kind = null,Object? version = null,Object? granted = null,Object? grantedAt = freezed,Object? revokedAt = freezed,}) {
  return _then(_self.copyWith(
kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,version: null == version ? _self.version : version // ignore: cast_nullable_to_non_nullable
as String,granted: null == granted ? _self.granted : granted // ignore: cast_nullable_to_non_nullable
as bool,grantedAt: freezed == grantedAt ? _self.grantedAt : grantedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,revokedAt: freezed == revokedAt ? _self.revokedAt : revokedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [Consent].
extension ConsentPatterns on Consent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Consent value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Consent() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Consent value)  $default,){
final _that = this;
switch (_that) {
case _Consent():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Consent value)?  $default,){
final _that = this;
switch (_that) {
case _Consent() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String kind,  String version,  bool granted,  DateTime? grantedAt,  DateTime? revokedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Consent() when $default != null:
return $default(_that.kind,_that.version,_that.granted,_that.grantedAt,_that.revokedAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String kind,  String version,  bool granted,  DateTime? grantedAt,  DateTime? revokedAt)  $default,) {final _that = this;
switch (_that) {
case _Consent():
return $default(_that.kind,_that.version,_that.granted,_that.grantedAt,_that.revokedAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String kind,  String version,  bool granted,  DateTime? grantedAt,  DateTime? revokedAt)?  $default,) {final _that = this;
switch (_that) {
case _Consent() when $default != null:
return $default(_that.kind,_that.version,_that.granted,_that.grantedAt,_that.revokedAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Consent implements Consent {
  const _Consent({required this.kind, required this.version, required this.granted, this.grantedAt, this.revokedAt});
  factory _Consent.fromJson(Map<String, dynamic> json) => _$ConsentFromJson(json);

@override final  String kind;
@override final  String version;
@override final  bool granted;
@override final  DateTime? grantedAt;
@override final  DateTime? revokedAt;

/// Create a copy of Consent
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ConsentCopyWith<_Consent> get copyWith => __$ConsentCopyWithImpl<_Consent>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ConsentToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Consent&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.version, version) || other.version == version)&&(identical(other.granted, granted) || other.granted == granted)&&(identical(other.grantedAt, grantedAt) || other.grantedAt == grantedAt)&&(identical(other.revokedAt, revokedAt) || other.revokedAt == revokedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,kind,version,granted,grantedAt,revokedAt);

@override
String toString() {
  return 'Consent(kind: $kind, version: $version, granted: $granted, grantedAt: $grantedAt, revokedAt: $revokedAt)';
}


}

/// @nodoc
abstract mixin class _$ConsentCopyWith<$Res> implements $ConsentCopyWith<$Res> {
  factory _$ConsentCopyWith(_Consent value, $Res Function(_Consent) _then) = __$ConsentCopyWithImpl;
@override @useResult
$Res call({
 String kind, String version, bool granted, DateTime? grantedAt, DateTime? revokedAt
});




}
/// @nodoc
class __$ConsentCopyWithImpl<$Res>
    implements _$ConsentCopyWith<$Res> {
  __$ConsentCopyWithImpl(this._self, this._then);

  final _Consent _self;
  final $Res Function(_Consent) _then;

/// Create a copy of Consent
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? kind = null,Object? version = null,Object? granted = null,Object? grantedAt = freezed,Object? revokedAt = freezed,}) {
  return _then(_Consent(
kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,version: null == version ? _self.version : version // ignore: cast_nullable_to_non_nullable
as String,granted: null == granted ? _self.granted : granted // ignore: cast_nullable_to_non_nullable
as bool,grantedAt: freezed == grantedAt ? _self.grantedAt : grantedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,revokedAt: freezed == revokedAt ? _self.revokedAt : revokedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}


/// @nodoc
mixin _$MeSession {

 String? get sid; String? get deviceId; String? get deviceName; DateTime? get createdAt; List<String>? get amr; DateTime? get expiresAt;
/// Create a copy of MeSession
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeSessionCopyWith<MeSession> get copyWith => _$MeSessionCopyWithImpl<MeSession>(this as MeSession, _$identity);

  /// Serializes this MeSession to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeSession&&(identical(other.sid, sid) || other.sid == sid)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.deviceName, deviceName) || other.deviceName == deviceName)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&const DeepCollectionEquality().equals(other.amr, amr)&&(identical(other.expiresAt, expiresAt) || other.expiresAt == expiresAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,sid,deviceId,deviceName,createdAt,const DeepCollectionEquality().hash(amr),expiresAt);

@override
String toString() {
  return 'MeSession(sid: $sid, deviceId: $deviceId, deviceName: $deviceName, createdAt: $createdAt, amr: $amr, expiresAt: $expiresAt)';
}


}

/// @nodoc
abstract mixin class $MeSessionCopyWith<$Res>  {
  factory $MeSessionCopyWith(MeSession value, $Res Function(MeSession) _then) = _$MeSessionCopyWithImpl;
@useResult
$Res call({
 String? sid, String? deviceId, String? deviceName, DateTime? createdAt, List<String>? amr, DateTime? expiresAt
});




}
/// @nodoc
class _$MeSessionCopyWithImpl<$Res>
    implements $MeSessionCopyWith<$Res> {
  _$MeSessionCopyWithImpl(this._self, this._then);

  final MeSession _self;
  final $Res Function(MeSession) _then;

/// Create a copy of MeSession
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? sid = freezed,Object? deviceId = freezed,Object? deviceName = freezed,Object? createdAt = freezed,Object? amr = freezed,Object? expiresAt = freezed,}) {
  return _then(_self.copyWith(
sid: freezed == sid ? _self.sid : sid // ignore: cast_nullable_to_non_nullable
as String?,deviceId: freezed == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String?,deviceName: freezed == deviceName ? _self.deviceName : deviceName // ignore: cast_nullable_to_non_nullable
as String?,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,amr: freezed == amr ? _self.amr : amr // ignore: cast_nullable_to_non_nullable
as List<String>?,expiresAt: freezed == expiresAt ? _self.expiresAt : expiresAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [MeSession].
extension MeSessionPatterns on MeSession {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MeSession value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MeSession() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MeSession value)  $default,){
final _that = this;
switch (_that) {
case _MeSession():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MeSession value)?  $default,){
final _that = this;
switch (_that) {
case _MeSession() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? sid,  String? deviceId,  String? deviceName,  DateTime? createdAt,  List<String>? amr,  DateTime? expiresAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MeSession() when $default != null:
return $default(_that.sid,_that.deviceId,_that.deviceName,_that.createdAt,_that.amr,_that.expiresAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? sid,  String? deviceId,  String? deviceName,  DateTime? createdAt,  List<String>? amr,  DateTime? expiresAt)  $default,) {final _that = this;
switch (_that) {
case _MeSession():
return $default(_that.sid,_that.deviceId,_that.deviceName,_that.createdAt,_that.amr,_that.expiresAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? sid,  String? deviceId,  String? deviceName,  DateTime? createdAt,  List<String>? amr,  DateTime? expiresAt)?  $default,) {final _that = this;
switch (_that) {
case _MeSession() when $default != null:
return $default(_that.sid,_that.deviceId,_that.deviceName,_that.createdAt,_that.amr,_that.expiresAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _MeSession implements MeSession {
  const _MeSession({this.sid, this.deviceId, this.deviceName, this.createdAt, final  List<String>? amr, this.expiresAt}): _amr = amr;
  factory _MeSession.fromJson(Map<String, dynamic> json) => _$MeSessionFromJson(json);

@override final  String? sid;
@override final  String? deviceId;
@override final  String? deviceName;
@override final  DateTime? createdAt;
 final  List<String>? _amr;
@override List<String>? get amr {
  final value = _amr;
  if (value == null) return null;
  if (_amr is EqualUnmodifiableListView) return _amr;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

@override final  DateTime? expiresAt;

/// Create a copy of MeSession
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MeSessionCopyWith<_MeSession> get copyWith => __$MeSessionCopyWithImpl<_MeSession>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeSessionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _MeSession&&(identical(other.sid, sid) || other.sid == sid)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.deviceName, deviceName) || other.deviceName == deviceName)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&const DeepCollectionEquality().equals(other._amr, _amr)&&(identical(other.expiresAt, expiresAt) || other.expiresAt == expiresAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,sid,deviceId,deviceName,createdAt,const DeepCollectionEquality().hash(_amr),expiresAt);

@override
String toString() {
  return 'MeSession(sid: $sid, deviceId: $deviceId, deviceName: $deviceName, createdAt: $createdAt, amr: $amr, expiresAt: $expiresAt)';
}


}

/// @nodoc
abstract mixin class _$MeSessionCopyWith<$Res> implements $MeSessionCopyWith<$Res> {
  factory _$MeSessionCopyWith(_MeSession value, $Res Function(_MeSession) _then) = __$MeSessionCopyWithImpl;
@override @useResult
$Res call({
 String? sid, String? deviceId, String? deviceName, DateTime? createdAt, List<String>? amr, DateTime? expiresAt
});




}
/// @nodoc
class __$MeSessionCopyWithImpl<$Res>
    implements _$MeSessionCopyWith<$Res> {
  __$MeSessionCopyWithImpl(this._self, this._then);

  final _MeSession _self;
  final $Res Function(_MeSession) _then;

/// Create a copy of MeSession
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? sid = freezed,Object? deviceId = freezed,Object? deviceName = freezed,Object? createdAt = freezed,Object? amr = freezed,Object? expiresAt = freezed,}) {
  return _then(_MeSession(
sid: freezed == sid ? _self.sid : sid // ignore: cast_nullable_to_non_nullable
as String?,deviceId: freezed == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String?,deviceName: freezed == deviceName ? _self.deviceName : deviceName // ignore: cast_nullable_to_non_nullable
as String?,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,amr: freezed == amr ? _self._amr : amr // ignore: cast_nullable_to_non_nullable
as List<String>?,expiresAt: freezed == expiresAt ? _self.expiresAt : expiresAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}


/// @nodoc
mixin _$MeAppVersion {

 String? get min; String? get recommended;
/// Create a copy of MeAppVersion
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeAppVersionCopyWith<MeAppVersion> get copyWith => _$MeAppVersionCopyWithImpl<MeAppVersion>(this as MeAppVersion, _$identity);

  /// Serializes this MeAppVersion to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeAppVersion&&(identical(other.min, min) || other.min == min)&&(identical(other.recommended, recommended) || other.recommended == recommended));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,min,recommended);

@override
String toString() {
  return 'MeAppVersion(min: $min, recommended: $recommended)';
}


}

/// @nodoc
abstract mixin class $MeAppVersionCopyWith<$Res>  {
  factory $MeAppVersionCopyWith(MeAppVersion value, $Res Function(MeAppVersion) _then) = _$MeAppVersionCopyWithImpl;
@useResult
$Res call({
 String? min, String? recommended
});




}
/// @nodoc
class _$MeAppVersionCopyWithImpl<$Res>
    implements $MeAppVersionCopyWith<$Res> {
  _$MeAppVersionCopyWithImpl(this._self, this._then);

  final MeAppVersion _self;
  final $Res Function(MeAppVersion) _then;

/// Create a copy of MeAppVersion
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? min = freezed,Object? recommended = freezed,}) {
  return _then(_self.copyWith(
min: freezed == min ? _self.min : min // ignore: cast_nullable_to_non_nullable
as String?,recommended: freezed == recommended ? _self.recommended : recommended // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [MeAppVersion].
extension MeAppVersionPatterns on MeAppVersion {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MeAppVersion value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MeAppVersion() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MeAppVersion value)  $default,){
final _that = this;
switch (_that) {
case _MeAppVersion():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MeAppVersion value)?  $default,){
final _that = this;
switch (_that) {
case _MeAppVersion() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? min,  String? recommended)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MeAppVersion() when $default != null:
return $default(_that.min,_that.recommended);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? min,  String? recommended)  $default,) {final _that = this;
switch (_that) {
case _MeAppVersion():
return $default(_that.min,_that.recommended);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? min,  String? recommended)?  $default,) {final _that = this;
switch (_that) {
case _MeAppVersion() when $default != null:
return $default(_that.min,_that.recommended);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _MeAppVersion implements MeAppVersion {
  const _MeAppVersion({this.min, this.recommended});
  factory _MeAppVersion.fromJson(Map<String, dynamic> json) => _$MeAppVersionFromJson(json);

@override final  String? min;
@override final  String? recommended;

/// Create a copy of MeAppVersion
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MeAppVersionCopyWith<_MeAppVersion> get copyWith => __$MeAppVersionCopyWithImpl<_MeAppVersion>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeAppVersionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _MeAppVersion&&(identical(other.min, min) || other.min == min)&&(identical(other.recommended, recommended) || other.recommended == recommended));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,min,recommended);

@override
String toString() {
  return 'MeAppVersion(min: $min, recommended: $recommended)';
}


}

/// @nodoc
abstract mixin class _$MeAppVersionCopyWith<$Res> implements $MeAppVersionCopyWith<$Res> {
  factory _$MeAppVersionCopyWith(_MeAppVersion value, $Res Function(_MeAppVersion) _then) = __$MeAppVersionCopyWithImpl;
@override @useResult
$Res call({
 String? min, String? recommended
});




}
/// @nodoc
class __$MeAppVersionCopyWithImpl<$Res>
    implements _$MeAppVersionCopyWith<$Res> {
  __$MeAppVersionCopyWithImpl(this._self, this._then);

  final _MeAppVersion _self;
  final $Res Function(_MeAppVersion) _then;

/// Create a copy of MeAppVersion
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? min = freezed,Object? recommended = freezed,}) {
  return _then(_MeAppVersion(
min: freezed == min ? _self.min : min // ignore: cast_nullable_to_non_nullable
as String?,recommended: freezed == recommended ? _self.recommended : recommended // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
