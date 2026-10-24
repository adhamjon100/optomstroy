// Ошибки денежной арифметики и количеств (10 §18.1): соответствуют серверному
// `400/422 VALIDATION_FAILED` с машинным правилом [AmountError.rule].
// Чистый Dart — доступен domain и presentation (L-9).

/// Причина отклонения значения.
enum AmountError {
  /// Строка не соответствует формату (`money_format`, `qty_format`, `percent_format`).
  invalidFormat('format'),

  /// Больше знаков после разделителя, чем допускает точность (MV-24, MV-26, MV-28).
  tooManyDecimals('precision'),

  /// Значение вне допустимого диапазона (переполнение, процент > 100, скидка > суммы).
  outOfRange('range'),

  /// Отрицательное значение там, где допустимы только неотрицательные.
  negative('non_negative'),

  /// Количество в упаковках должно быть целым (INV-006, MV-07).
  packsNotInteger('packs_integer'),

  /// Получено меньше суммы к оплате (MV-18).
  receivedLessThanTotal('received_less_than_total');

  const AmountError(this.rule);

  /// Машинное правило (для сопоставления с `errors[].rule` и ARB-ключами).
  final String rule;
}

/// Значение отклонено; соответствует `VALIDATION_FAILED` (10 §18.2).
final class AmountException implements Exception {
  const AmountException(this.error);

  final AmountError error;

  /// Код ошибки по словарю 08 §2.4.
  String get code => 'VALIDATION_FAILED';

  @override
  String toString() => 'AmountException(${error.name})';
}
