// Количества — `int` тысячные доли единицы (milli-units) + `qty_precision` единицы
// (D-19; 07 §11.3: "2.500" → 2500). `double` запрещён.
// Форматирование для UI — design_system/formats/DsQtyFormat (03 §17.1); здесь —
// value-объект, разбор ввода (parseQty) и пересчёт упаковок (10 §18.1).
import 'package:optomstroy/core/utils/amount_exception.dart';

/// Количество в тысячных долях единицы.
extension type const Qty(int milli) {
  /// Строка API `QuantityValue`: `^\d{1,11}(\.\d{1,3})?$` (08 §2.14).
  factory Qty.fromString(String value) {
    final match = _apiPattern.firstMatch(value);
    if (match == null) {
      throw AmountException(_tooManyDecimals.hasMatch(value) ? AmountError.tooManyDecimals : AmountError.invalidFormat);
    }
    return Qty(int.parse(match.group(1)!) * 1000 + int.parse((match.group(2) ?? '').padRight(3, '0')));
  }

  /// Целое число единиц.
  factory Qty.units(int units) => Qty(units * 1000);

  static const Qty zero = Qty(0);

  /// Максимальная точность количества (3 знака, `NUMERIC(14,3)`).
  static const int maxPrecision = 3;

  /// Ввод пользователя (`parseQty`, 10 §18.1; MV-23, MV-24; INV-006): принимает «,» и «.»,
  /// удаляет пробелы-разряды, отклоняет больше [precision] знаков после разделителя.
  static Qty parseInput(String input, {required int precision}) {
    _checkPrecision(precision);
    final normalized = input.replaceAll(_spaces, '').replaceAll(',', '.');
    final match = _inputPattern.firstMatch(normalized);
    if (match == null) throw const AmountException(AmountError.invalidFormat);
    final fraction = match.group(2) ?? '';
    if (fraction.length > precision) throw const AmountException(AmountError.tooManyDecimals);
    return Qty(int.parse(match.group(1)!) * 1000 + int.parse(fraction.padRight(3, '0')));
  }

  /// `packToBase(qtyPacks, factor)` (MV-05, MV-07): количество в упаковках всегда целое
  /// (INV-006); результат в базовой единице должен помещаться в её `qty_precision`.
  /// [factorMilli] — `packagings.factor_milli` (> 0).
  static Qty packToBase(Qty packs, {required int factorMilli, required int basePrecision}) {
    _checkPrecision(basePrecision);
    if (factorMilli <= 0 || packs.milli < 0) throw const AmountException(AmountError.outOfRange);
    if (packs.milli % 1000 != 0) throw const AmountException(AmountError.packsNotInteger);
    final base = Qty(packs.milli ~/ 1000 * factorMilli);
    if (!base.fitsPrecision(basePrecision)) throw const AmountException(AmountError.tooManyDecimals);
    return base;
  }

  /// `baseToPacks(baseQty, factor)` (MV-06): `packs = floor(base / factor)`,
  /// `remainder = base − packs × factor`.
  static ({int packs, Qty remainder}) baseToPacks(Qty base, {required int factorMilli}) {
    if (factorMilli <= 0 || base.milli < 0) throw const AmountException(AmountError.outOfRange);
    final packs = base.milli ~/ factorMilli;
    return (packs: packs, remainder: Qty(base.milli - packs * factorMilli));
  }

  /// Строка API: всегда 3 знака (`"124.000"`, `"2.333"`).
  String toApiString() => '${milli ~/ 1000}.${(milli % 1000).toString().padLeft(3, '0')}';

  /// Значение не имеет знаков сверх [precision] (0…3).
  bool fitsPrecision(int precision) {
    _checkPrecision(precision);
    return milli % _scale[precision] == 0;
  }

  bool get isWhole => milli % 1000 == 0;
  bool get isZero => milli == 0;

  Qty operator +(Qty other) => Qty(milli + other.milli);
  Qty operator -(Qty other) => Qty(milli - other.milli);
  bool operator <(Qty other) => milli < other.milli;
  bool operator >(Qty other) => milli > other.milli;
  int compareTo(Qty other) => milli.compareTo(other.milli);
}

const List<int> _scale = [1000, 100, 10, 1];
final RegExp _apiPattern = RegExp(r'^(\d{1,11})(?:\.(\d{1,3}))?$');
final RegExp _inputPattern = RegExp(r'^(\d{1,11})(?:\.(\d*))?$');
final RegExp _tooManyDecimals = RegExp(r'^\d+\.\d{4,}$');
final RegExp _spaces = RegExp('[    ]');

void _checkPrecision(int precision) {
  if (precision < 0 || precision > Qty.maxPrecision) throw ArgumentError.value(precision, 'precision', '0…3');
}
