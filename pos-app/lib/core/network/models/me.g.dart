// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'me.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Me _$MeFromJson(Map<String, dynamic> json) => _Me(
  id: json['id'] as String,
  kind: json['kind'] as String,
  status: json['status'] as String,
  roles: (json['roles'] as List<dynamic>).map((e) => e as String).toList(),
  permissions: (json['permissions'] as List<dynamic>)
      .map((e) => e as String)
      .toList(),
  permissionsVersion: (json['permissionsVersion'] as num).toInt(),
  discountLimitPercent: json['discountLimitPercent'] as String?,
  profile: json['profile'] == null
      ? null
      : MeProfile.fromJson(json['profile'] as Map<String, dynamic>),
  customerLink: json['customerLink'] == null
      ? null
      : MeCustomerLink.fromJson(json['customerLink'] as Map<String, dynamic>),
  settings: json['settings'] == null
      ? null
      : UserSettings.fromJson(json['settings'] as Map<String, dynamic>),
  security: json['security'] == null
      ? null
      : MeSecurity.fromJson(json['security'] as Map<String, dynamic>),
  consents: (json['consents'] as List<dynamic>?)
      ?.map((e) => Consent.fromJson(e as Map<String, dynamic>))
      .toList(),
  session: json['session'] == null
      ? null
      : MeSession.fromJson(json['session'] as Map<String, dynamic>),
  appVersion: json['appVersion'] == null
      ? null
      : MeAppVersion.fromJson(json['appVersion'] as Map<String, dynamic>),
  apiVersion: json['apiVersion'] as String?,
  serverTime: json['serverTime'] == null
      ? null
      : DateTime.parse(json['serverTime'] as String),
);

Map<String, dynamic> _$MeToJson(_Me instance) => <String, dynamic>{
  'id': instance.id,
  'kind': instance.kind,
  'status': instance.status,
  'roles': instance.roles,
  'permissions': instance.permissions,
  'permissionsVersion': instance.permissionsVersion,
  'discountLimitPercent': instance.discountLimitPercent,
  'profile': instance.profile,
  'customerLink': instance.customerLink,
  'settings': instance.settings,
  'security': instance.security,
  'consents': instance.consents,
  'session': instance.session,
  'appVersion': instance.appVersion,
  'apiVersion': instance.apiVersion,
  'serverTime': instance.serverTime?.toIso8601String(),
};

_MeProfile _$MeProfileFromJson(Map<String, dynamic> json) => _MeProfile(
  fullName: json['fullName'] as String?,
  phone: json['phone'] as String?,
  birthYear: (json['birthYear'] as num?)?.toInt(),
  activitySphere: json['activitySphere'] as String?,
  avatarUrl: json['avatarUrl'] as String?,
  rowVersion: (json['rowVersion'] as num?)?.toInt(),
);

Map<String, dynamic> _$MeProfileToJson(_MeProfile instance) =>
    <String, dynamic>{
      'fullName': instance.fullName,
      'phone': instance.phone,
      'birthYear': instance.birthYear,
      'activitySphere': instance.activitySphere,
      'avatarUrl': instance.avatarUrl,
      'rowVersion': instance.rowVersion,
    };

_MeCustomerLink _$MeCustomerLinkFromJson(Map<String, dynamic> json) =>
    _MeCustomerLink(
      status: json['status'] as String,
      linkId: json['linkId'] as String?,
      displayNameMasked: json['displayNameMasked'] as String?,
      customerId: json['customerId'] as String?,
      displayName: json['displayName'] as String?,
    );

Map<String, dynamic> _$MeCustomerLinkToJson(_MeCustomerLink instance) =>
    <String, dynamic>{
      'status': instance.status,
      'linkId': instance.linkId,
      'displayNameMasked': instance.displayNameMasked,
      'customerId': instance.customerId,
      'displayName': instance.displayName,
    };

_UserSettings _$UserSettingsFromJson(Map<String, dynamic> json) =>
    _UserSettings(
      locale: json['locale'] as String?,
      scanner: json['scanner'] == null
          ? null
          : ScannerSettings.fromJson(json['scanner'] as Map<String, dynamic>),
      scanAddsToCart: json['scanAddsToCart'] as bool?,
      printer: json['printer'] == null
          ? null
          : PrinterSettings.fromJson(json['printer'] as Map<String, dynamic>),
      catalogView: json['catalogView'] as String?,
      defaultWarehouseId: json['defaultWarehouseId'] as String?,
      idleLockMinutes: (json['idleLockMinutes'] as num?)?.toInt(),
      rowVersion: (json['rowVersion'] as num?)?.toInt(),
    );

Map<String, dynamic> _$UserSettingsToJson(_UserSettings instance) =>
    <String, dynamic>{
      'locale': instance.locale,
      'scanner': instance.scanner,
      'scanAddsToCart': instance.scanAddsToCart,
      'printer': instance.printer,
      'catalogView': instance.catalogView,
      'defaultWarehouseId': instance.defaultWarehouseId,
      'idleLockMinutes': instance.idleLockMinutes,
      'rowVersion': instance.rowVersion,
    };

_ScannerSettings _$ScannerSettingsFromJson(Map<String, dynamic> json) =>
    _ScannerSettings(
      mode: json['mode'] as String?,
      suffix: json['suffix'] as String?,
    );

Map<String, dynamic> _$ScannerSettingsToJson(_ScannerSettings instance) =>
    <String, dynamic>{'mode': instance.mode, 'suffix': instance.suffix};

_PrinterSettings _$PrinterSettingsFromJson(Map<String, dynamic> json) =>
    _PrinterSettings(
      defaultFormat: json['defaultFormat'] as String?,
      autoPrint: json['autoPrint'] as bool?,
    );

Map<String, dynamic> _$PrinterSettingsToJson(_PrinterSettings instance) =>
    <String, dynamic>{
      'defaultFormat': instance.defaultFormat,
      'autoPrint': instance.autoPrint,
    };

_MeSecurity _$MeSecurityFromJson(Map<String, dynamic> json) => _MeSecurity(
  pinSet: json['pinSet'] as bool?,
  biometricsEnabled: json['biometricsEnabled'] as bool?,
  biometricsPlatform: json['biometricsPlatform'] as String?,
);

Map<String, dynamic> _$MeSecurityToJson(_MeSecurity instance) =>
    <String, dynamic>{
      'pinSet': instance.pinSet,
      'biometricsEnabled': instance.biometricsEnabled,
      'biometricsPlatform': instance.biometricsPlatform,
    };

_Consent _$ConsentFromJson(Map<String, dynamic> json) => _Consent(
  kind: json['kind'] as String,
  version: json['version'] as String,
  granted: json['granted'] as bool,
  grantedAt: json['grantedAt'] == null
      ? null
      : DateTime.parse(json['grantedAt'] as String),
  revokedAt: json['revokedAt'] == null
      ? null
      : DateTime.parse(json['revokedAt'] as String),
);

Map<String, dynamic> _$ConsentToJson(_Consent instance) => <String, dynamic>{
  'kind': instance.kind,
  'version': instance.version,
  'granted': instance.granted,
  'grantedAt': instance.grantedAt?.toIso8601String(),
  'revokedAt': instance.revokedAt?.toIso8601String(),
};

_MeSession _$MeSessionFromJson(Map<String, dynamic> json) => _MeSession(
  sid: json['sid'] as String?,
  deviceId: json['deviceId'] as String?,
  deviceName: json['deviceName'] as String?,
  createdAt: json['createdAt'] == null
      ? null
      : DateTime.parse(json['createdAt'] as String),
  amr: (json['amr'] as List<dynamic>?)?.map((e) => e as String).toList(),
  expiresAt: json['expiresAt'] == null
      ? null
      : DateTime.parse(json['expiresAt'] as String),
);

Map<String, dynamic> _$MeSessionToJson(_MeSession instance) =>
    <String, dynamic>{
      'sid': instance.sid,
      'deviceId': instance.deviceId,
      'deviceName': instance.deviceName,
      'createdAt': instance.createdAt?.toIso8601String(),
      'amr': instance.amr,
      'expiresAt': instance.expiresAt?.toIso8601String(),
    };

_MeAppVersion _$MeAppVersionFromJson(Map<String, dynamic> json) =>
    _MeAppVersion(
      min: json['min'] as String?,
      recommended: json['recommended'] as String?,
    );

Map<String, dynamic> _$MeAppVersionToJson(_MeAppVersion instance) =>
    <String, dynamic>{'min': instance.min, 'recommended': instance.recommended};
