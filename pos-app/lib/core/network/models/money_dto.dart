// DTO `Money` (OpenAPI components.schemas.Money): `{amount: "16007.50", currency: "KGS"}`.
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:optomstroy/core/utils/money.dart';

part 'money_dto.freezed.dart';
part 'money_dto.g.dart';

@freezed
abstract class MoneyDto with _$MoneyDto {
  const factory MoneyDto({required String amount, @Default(MoneyDto.currencyKgs) String currency}) = _MoneyDto;

  const MoneyDto._();

  factory MoneyDto.fromJson(Map<String, dynamic> json) => _$MoneyDtoFromJson(json);

  factory MoneyDto.of(Money money) => MoneyDto(amount: money.toApiString());

  static const String currencyKgs = 'KGS';

  /// Значение в тыйынах; неверный формат → `AmountException`.
  Money get value => Money.fromString(amount);
}
