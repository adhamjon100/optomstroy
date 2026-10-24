// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'auth_token_pair.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_AuthTokenPair _$AuthTokenPairFromJson(Map<String, dynamic> json) =>
    _AuthTokenPair(
      accessToken: json['accessToken'] as String,
      accessExpiresIn: (json['accessExpiresIn'] as num).toInt(),
      refreshToken: json['refreshToken'] as String,
      refreshExpiresAt: DateTime.parse(json['refreshExpiresAt'] as String),
      sid: json['sid'] as String,
      permissionsVersion: (json['permissionsVersion'] as num?)?.toInt(),
    );

Map<String, dynamic> _$AuthTokenPairToJson(_AuthTokenPair instance) =>
    <String, dynamic>{
      'accessToken': instance.accessToken,
      'accessExpiresIn': instance.accessExpiresIn,
      'refreshToken': instance.refreshToken,
      'refreshExpiresAt': instance.refreshExpiresAt.toIso8601String(),
      'sid': instance.sid,
      'permissionsVersion': instance.permissionsVersion,
    };
