// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'money_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_MoneyDto _$MoneyDtoFromJson(Map<String, dynamic> json) => _MoneyDto(
  amount: json['amount'] as String,
  currency: json['currency'] as String? ?? MoneyDto.currencyKgs,
);

Map<String, dynamic> _$MoneyDtoToJson(_MoneyDto instance) => <String, dynamic>{
  'amount': instance.amount,
  'currency': instance.currency,
};
