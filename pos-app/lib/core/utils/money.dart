// Денежная арифметика клиента (10 §18, D-19; MNY-001…MNY-004).
//
// Деньги — `int` тыйыны (1 сом = 100 тыйын), `double` запрещён (MNY-002, FL-10).
// Округление — HALF_UP (0,5 → от нуля) до 0,01 на уровне строки, затем суммирование.
// Сервер считает то же в decimal и является истиной; клиент показывает результат
// как «предварительно» до ответа сервера (MNY-001).
//
// Форматирование для UI («16 007,50 сом», MV-25) здесь намеренно отсутствует:
// единственная реализация — design_system/formats/DsMoneyFormat (03 §17.1, DS-082).
// Здесь — только value-объект, арифметика и нормализация для API ("1234.50").
import 'package:optomstroy/core/utils/amount_exception.dart';
import 'package:optomstroy/core/utils/qty.dart';

/// Сумма в тыйынах. Extension type над `int`: без накладных расходов,
/// но не смешивается с количествами и процентами на уровне типов.
extension type const Money(int tyiyn) {
  /// Строка API `MoneyAmount`: `^-?\d{1,12}\.\d{2}$` (08 §2.14, OpenAPI `MoneyAmount`).
  ///
  /// `Money.fromString("1234.50") == Money(123450)`. Три знака после точки
  /// (цена из 1С `1234.565`, MV-28) → [AmountException] `tooManyDecimals`.
  factory Money.fromString(String value) {
    final match = _apiPattern.firstMatch(value);
    if (match == null) {
      throw AmountException(_decimalsPattern.hasMatch(value) ? AmountError.tooManyDecimals : AmountError.invalidFormat);
    }
    final abs = int.parse(match.group(2)!) * 100 + int.parse(match.group(3)!);
    return Money(match.group(1) == null ? abs : -abs);
  }

  /// Ввод суммы пользователем (например, «Получено» на SCR-38): пробелы-разряды
  /// (в том числе U+00A0, U+202F) удаляются, «,» и «.» — десятичный разделитель,
  /// не более 2 знаков, без знака.
  factory Money.parseInput(String input) {
    final normalized = input.replaceAll(_spaces, '').replaceAll(',', '.');
    final match = _inputPattern.firstMatch(normalized);
    if (match == null) {
      throw AmountException(
        _decimalsPattern.hasMatch(normalized) ? AmountError.tooManyDecimals : AmountError.invalidFormat,
      );
    }
    final fraction = (match.group(2) ?? '').padRight(2, '0');
    return Money(int.parse(match.group(1)!) * 100 + int.parse(fraction));
  }

  static const Money zero = Money(0);

  /// Целые сомы.
  static Money som(int som) => Money(som * 100);

  /// Строка API: `"1234.50"`, `"-842.50"`, `"0.05"`.
  String toApiString() {
    final abs = tyiyn.abs();
    final sign = tyiyn < 0 ? '-' : '';
    return '$sign${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  }

  bool get isZero => tyiyn == 0;
  bool get isNegative => tyiyn < 0;

  Money operator +(Money other) => Money(tyiyn + other.tyiyn);
  Money operator -(Money other) => Money(tyiyn - other.tyiyn);
  Money operator -() => Money(-tyiyn);
  bool operator <(Money other) => tyiyn < other.tyiyn;
  bool operator <=(Money other) => tyiyn <= other.tyiyn;
  bool operator >(Money other) => tyiyn > other.tyiyn;
  bool operator >=(Money other) => tyiyn >= other.tyiyn;
  int compareTo(Money other) => tyiyn.compareTo(other.tyiyn);

  /// Сумма в целое число раз (без округления).
  Money times(int factor) => Money(tyiyn * factor);

  /// Сумма списка.
  static Money sum(Iterable<Money> values) => Money(values.fold<int>(0, (acc, m) => acc + m.tyiyn));
}

/// Процент в сотых долях (`NUMERIC(5,2)`, 07 §11.3: `"5.00"` → 500).
extension type const Percent(int hundredths) {
  /// Строка API `Percent`: `^(\d{1,2}(\.\d{1,2})?|100\.00)$` (rule `percent_range`).
  /// Ввод «12,345 %» → [AmountException] `tooManyDecimals` (MV-26); > 100 → `outOfRange`.
  factory Percent.fromString(String value) {
    final normalized = value.trim().replaceAll(',', '.');
    final match = _percentPattern.firstMatch(normalized);
    if (match == null) {
      throw AmountException(
        _decimalsPattern.hasMatch(normalized) ? AmountError.tooManyDecimals : AmountError.invalidFormat,
      );
    }
    final hundredths = int.parse(match.group(1)!) * 100 + int.parse((match.group(2) ?? '').padRight(2, '0'));
    if (hundredths > 10000) throw const AmountException(AmountError.outOfRange);
    return Percent(hundredths);
  }

  static const Percent zero = Percent(0);

  /// Строка API: `"5.00"`.
  String toApiString() => '${hundredths ~/ 100}.${(hundredths % 100).toString().padLeft(2, '0')}';
}

/// Режим округления наличных (`app_settings.cash_rounding`, ядро §17.7; Q-016).
enum CashRoundingMode {
  none('none'),
  toSomHalfUp('to_som_half_up'),
  toSomDown('to_som_down');

  const CashRoundingMode(this.value);

  /// Значение настройки.
  final String value;
}

/// Результат [MoneyMath.cashRounding]: округлённая сумма и разница (передаётся в 1С
/// как «скидка округления», MNY-005).
typedef CashRounding = ({Money rounded, Money delta});

/// Результат [MoneyMath.twoStageDiscount] (07 §7.3 п.3–5).
typedef TwoStageDiscount = ({List<Money> customer, List<Money> manual, List<Money> lineTotals, Money total});

/// Функции 10 §18.1 (сигнатуры — спецификация).
abstract final class MoneyMath {
  /// `lineTotal(unitPrice, baseQty) = roundHalfUp(unitPrice × baseQty, 2)` (MV-01…MV-04).
  static Money lineTotal(Money unitPrice, Qty baseQty) => Money(_mulDivHalfUp(unitPrice.tyiyn, baseQty.milli, 1000));

  /// `documentDiscount(subtotal, percent) = roundHalfUp(subtotal × percent / 100, 2)` (MV-08, MV-27).
  static Money documentDiscount(Money subtotal, Percent percent) =>
      Money(_mulDivHalfUp(subtotal.tyiyn, percent.hundredths, 10000));

  /// Распределение скидки документа по строкам (MNY-003, MV-10…MV-13):
  /// `alloc_i = roundHalfUp(discount × line_i / Σlines, 2)`, разница `delta = discount − Σalloc`
  /// добавляется к последней строке с `line_i > 0`. Гарантии: `Σalloc = discount`,
  /// `0 ≤ alloc_i ≤ line_i` (если коррекция не помещается в последнюю строку,
  /// остаток переносится на предыдущую ненулевую).
  static List<Money> allocateDiscount(List<Money> lines, Money discount) {
    if (discount.isNegative || lines.any((line) => line.isNegative)) {
      throw const AmountException(AmountError.negative);
    }
    final total = Money.sum(lines).tyiyn;
    if (discount.tyiyn > total) throw const AmountException(AmountError.outOfRange);
    if (total == 0) return List<Money>.filled(lines.length, Money.zero);
    final caps = [for (final line in lines) line.tyiyn];
    final alloc = [for (final cap in caps) _mulDivHalfUp(discount.tyiyn, cap, total)];
    _distributeDelta(alloc, caps, discount.tyiyn - _sum(alloc));
    return [for (final a in alloc) Money(a)];
  }

  /// Двухэтапная скидка (07 §7.3 п.3–5, MV-29, MV-30): этап 1 — скидка клиента 1С
  /// построчно без коррекции; этап 2 — ручная скидка от базы `b_i = line_i − customer_i`
  /// с коррекцией копеек в последней строке с `b_i > 0`.
  static TwoStageDiscount twoStageDiscount(List<Money> lineSubtotals, Percent customerPercent, Percent manualPercent) {
    if (lineSubtotals.any((line) => line.isNegative)) throw const AmountException(AmountError.negative);
    final customer = [for (final line in lineSubtotals) _mulDivHalfUp(line.tyiyn, customerPercent.hundredths, 10000)];
    final bases = [for (var i = 0; i < lineSubtotals.length; i++) lineSubtotals[i].tyiyn - customer[i]];
    final manualTotal = documentDiscount(Money(_sum(bases)), manualPercent).tyiyn;
    final manual = [for (final base in bases) _mulDivHalfUp(base, manualPercent.hundredths, 10000)];
    _distributeDelta(manual, bases, manualTotal - _sum(manual));
    final lineTotals = [for (var i = 0; i < bases.length; i++) Money(bases[i] - manual[i])];
    return (
      customer: [for (final c in customer) Money(c)],
      manual: [for (final m in manual) Money(m)],
      lineTotals: lineTotals,
      total: Money.sum(lineTotals),
    );
  }

  /// Округление наличных (MV-15, MV-16; по умолчанию `none`, Q-016).
  static CashRounding cashRounding(Money total, CashRoundingMode mode) {
    final rounded = switch (mode) {
      CashRoundingMode.none => total,
      CashRoundingMode.toSomHalfUp => Money(_mulDivHalfUp(total.tyiyn, 1, 100) * 100),
      CashRoundingMode.toSomDown => Money(total.tyiyn ~/ 100 * 100),
    };
    return (rounded: rounded, delta: rounded - total);
  }

  /// Сдача `received − total`; `received < total` → `VALIDATION_FAILED` (MV-17, MV-18).
  static Money change(Money total, Money received) {
    if (received < total) throw const AmountException(AmountError.receivedLessThanTotal);
    return received - total;
  }

  /// Сумма возврата строки (MNY-006, MV-19, MV-20):
  /// `roundHalfUp(lineTotalAfterDiscount × returnQty / shippedQty, 2)`;
  /// полный возврат — ровно сумма строки.
  static Money returnLineAmount(Money lineTotalAfterDiscount, Qty shippedQty, Qty returnQty) {
    if (shippedQty.milli <= 0 || returnQty.milli <= 0 || returnQty.milli > shippedQty.milli) {
      throw const AmountException(AmountError.outOfRange);
    }
    if (returnQty == shippedQty) return lineTotalAfterDiscount;
    return Money(_mulDivHalfUp(lineTotalAfterDiscount.tyiyn, returnQty.milli, shippedQty.milli));
  }

  /// `limit − balance − openOrders`, может быть отрицательным (MV-21, MV-22).
  /// Только для предварительного показа: решение о долге — на сервере (D-24).
  static Money creditRemaining(Money limit, Money balance, Money openOrders) => limit - balance - openOrders;
}

final RegExp _apiPattern = RegExp(r'^(-)?(\d{1,12})\.(\d{2})$');
final RegExp _inputPattern = RegExp(r'^(\d{1,12})(?:\.(\d{0,2}))?$');
final RegExp _percentPattern = RegExp(r'^(\d{1,3})(?:\.(\d{1,2}))?$');
final RegExp _decimalsPattern = RegExp(r'^-?\d+\.\d{3,}$');
final RegExp _spaces = RegExp('[    ]');

int _sum(List<int> values) => values.fold<int>(0, (acc, v) => acc + v);

/// `roundHalfUp(a × b / divisor)` в целых; половина — от нуля. Промежуточное
/// произведение — `BigInt` (без переполнения), результат обязан помещаться в `int`.
/// [divisor] > 0 гарантируют вызывающие.
int _mulDivHalfUp(int a, int b, int divisor) {
  final product = BigInt.from(a) * BigInt.from(b);
  final d = BigInt.from(divisor);
  final abs = product.abs();
  var quotient = abs ~/ d;
  if (abs.remainder(d) * BigInt.two >= d) quotient += BigInt.one;
  final signed = product.isNegative ? -quotient : quotient;
  if (!signed.isValidInt) throw const AmountException(AmountError.outOfRange);
  return signed.toInt();
}

/// Переносит [delta] на строки с конца (строки с `cap ≤ 0` пропускаются),
/// не выходя за `0 ≤ alloc_i ≤ cap_i`. Предусловие: `0 ≤ Σalloc + delta ≤ Σcaps`.
void _distributeDelta(List<int> alloc, List<int> caps, int delta) {
  var rest = delta;
  for (var i = alloc.length - 1; i >= 0 && rest != 0; i--) {
    if (caps[i] <= 0) continue;
    if (rest > 0) {
      final take = rest < caps[i] - alloc[i] ? rest : caps[i] - alloc[i];
      alloc[i] += take;
      rest -= take;
    } else {
      final take = -rest < alloc[i] ? -rest : alloc[i];
      alloc[i] -= take;
      rest += take;
    }
  }
}
