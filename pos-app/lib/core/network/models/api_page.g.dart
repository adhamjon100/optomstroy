// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'api_page.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ApiPage<T> _$ApiPageFromJson<T>(
  Map<String, dynamic> json,
  T Function(Object? json) fromJsonT,
) => _ApiPage<T>(
  items: (json['items'] as List<dynamic>).map(fromJsonT).toList(),
  nextCursor: json['nextCursor'] as String?,
  hasMore: json['hasMore'] as bool,
  totalEstimate: (json['totalEstimate'] as num?)?.toInt(),
  isEstimate: json['isEstimate'] as bool?,
  asOf: json['asOf'] == null ? null : DateTime.parse(json['asOf'] as String),
);

Map<String, dynamic> _$ApiPageToJson<T>(
  _ApiPage<T> instance,
  Object? Function(T value) toJsonT,
) => <String, dynamic>{
  'items': instance.items.map(toJsonT).toList(),
  'nextCursor': instance.nextCursor,
  'hasMore': instance.hasMore,
  'totalEstimate': instance.totalEstimate,
  'isEstimate': instance.isEstimate,
  'asOf': instance.asOf?.toIso8601String(),
};
