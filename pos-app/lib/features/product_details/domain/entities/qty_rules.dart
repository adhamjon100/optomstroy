// Правила количества карточки товара и нампада (10 §4.1, INV-001…INV-010, INV-041, INV-042;
// 02 SCR-14.4, SCR-16.4). Чистый Dart (FL-01): количества — `Qty` (milli-units), без `double` (D-19).
//
// Проверка в приложении — удобство и мгновенный ответ; окончательное решение — сервер (INV-008):
// `QTY_NOT_MULTIPLE` (кратность; точность — с rule `qty_precision`), `QTY_BELOW_MIN`,
// `VALIDATION_FAILED` (дробное число упаковок, слишком большое количество).
import 'package:optomstroy/core/utils/amount_exception.dart';
import 'package:optomstroy/core/utils/qty.dart';

/// Вид нарушения правил количества.
enum QtyIssueKind {
  /// Не кратно `multiplicity` (INV-004) → `QTY_NOT_MULTIPLE`.
  notMultiple('QTY_NOT_MULTIPLE'),

  /// Меньше минимальной партии (INV-005) → `QTY_BELOW_MIN`.
  belowMin('QTY_BELOW_MIN'),

  /// Больше знаков после запятой, чем `qty_precision` (INV-001) → `QTY_NOT_MULTIPLE` (rule `qty_precision`).
  precision('QTY_NOT_MULTIPLE'),

  /// Дробное число упаковок (INV-006) → `VALIDATION_FAILED`.
  packInteger('VALIDATION_FAILED'),

  /// Больше доступного на складе корзины (INV-042; локальная проверка, не ошибка сервера).
  exceedsAvailable('STOCK_LOCAL'),

  /// Больше 999 999,999 (INV-010) → `VALIDATION_FAILED`.
  tooLarge('VALIDATION_FAILED'),

  /// Ноль или пусто (INV-007): в карточке «Готово» недоступна.
  zero('VALIDATION_FAILED'),

  /// Строка не разбирается как количество.
  invalid('VALIDATION_FAILED');

  const QtyIssueKind(this.code);

  /// Код ошибки сервера, которому соответствует нарушение (08 §2.4).
  final String code;
}

/// Нарушение правил количества.
final class QtyIssue {
  const QtyIssue(this.kind, {this.limit, this.suggestion, this.precision});

  final QtyIssueKind kind;

  /// Кратность / минимум / доступно в базовой единице.
  final Qty? limit;

  /// «Округлить до N» (базовая единица): ближайшее большее допустимое значение.
  final Qty? suggestion;

  /// Допустимое число знаков (`precision`).
  final int? precision;

  @override
  String toString() => 'QtyIssue(${kind.name}, limit: ${limit?.milli}, suggestion: ${suggestion?.milli})';
}

/// Правила количества варианта (базовая единица) и пересчёт упаковок (INV-003).
final class QtyRules {
  const QtyRules({required this.precision, this.multiplicity, this.minQuantity, this.available});

  /// `qty_precision` базовой единицы (0…3).
  final int precision;

  /// Кратность `Variant.multiplicity` в базовой единице; `null`/0 — не задана.
  final Qty? multiplicity;

  /// Минимальная партия `minQuantity`; `null` — не задана.
  final Qty? minQuantity;

  /// Предел для «+» и нампада: `remainingAvailable` строки корзины или `available` склада корзины
  /// (INV-042); `null` — проверки нет (число скрыто сервером, решает сервер).
  final Qty? available;

  /// Верхняя граница ввода (INV-010: 999 999,999 [НЕ ПОДТВЕРЖДЕНО, Q-176]).
  static const Qty maxInput = Qty(999999999);

  /// Кратность, если задана (> 0).
  Qty? get effectiveMultiplicity {
    final Qty? m = multiplicity;
    return m != null && m.milli > 0 ? m : null;
  }

  /// Шаг степпера (10 §4.1): `factor` выбранной упаковки; иначе `multiplicity`, если задана и больше
  /// одной единицы (или одна единица ей не кратна); иначе одна базовая единица.
  Qty stepFor({Qty? packFactor}) {
    if (packFactor != null && packFactor.milli > 0) return packFactor;
    final Qty? m = effectiveMultiplicity;
    final Qty one = Qty.units(1);
    if (m != null && (m.milli > one.milli || one.milli % m.milli != 0)) return m;
    return one;
  }

  /// Начальное количество (INV-005, SCR-14 UI-14-010): шаг или минимальная партия, округлённая
  /// вверх до шага.
  Qty initialFor({Qty? packFactor}) {
    final Qty step = stepFor(packFactor: packFactor);
    final Qty? min = minQuantity;
    if (min == null || min.milli <= step.milli) return step;
    return roundUpTo(min, step);
  }

  /// Наименьшее кратное [step], не меньшее [value].
  static Qty roundUpTo(Qty value, Qty step) {
    if (step.milli <= 0) return value;
    final int n = (value.milli + step.milli - 1) ~/ step.milli;
    return Qty(n * step.milli);
  }

  /// Проверка количества в базовой единице. Порядок: ноль → слишком много → точность →
  /// кратность упаковки/`multiplicity` → минимум → доступно.
  QtyIssue? validate(Qty base, {Qty? packFactor}) {
    if (base.milli <= 0) return const QtyIssue(QtyIssueKind.zero);
    if (base.milli > maxInput.milli) return const QtyIssue(QtyIssueKind.tooLarge, limit: maxInput);
    if (!base.fitsPrecision(precision)) return QtyIssue(QtyIssueKind.precision, precision: precision);
    if (packFactor != null && packFactor.milli > 0 && base.milli % packFactor.milli != 0) {
      return const QtyIssue(QtyIssueKind.packInteger);
    }
    final Qty? m = effectiveMultiplicity;
    if (m != null && base.milli % m.milli != 0) {
      return QtyIssue(QtyIssueKind.notMultiple, limit: m, suggestion: roundUpTo(base, m));
    }
    final Qty? min = minQuantity;
    if (min != null && base.milli < min.milli) {
      return QtyIssue(
        QtyIssueKind.belowMin,
        limit: min,
        suggestion: initialFor(packFactor: packFactor),
      );
    }
    final Qty? avail = available;
    if (avail != null && base.milli > avail.milli) return QtyIssue(QtyIssueKind.exceedsAvailable, limit: avail);
    return null;
  }

  /// Проверка ввода нампада [input] («12,5») в единице с точностью [inputPrecision]: базовая
  /// единица — `precision`, упаковка — 0 (INV-006). Возвращает базовое количество или нарушение.
  ({Qty? base, QtyIssue? issue}) parseAndValidate(String input, {Qty? packFactor}) {
    if (input.trim().isEmpty) return (base: null, issue: const QtyIssue(QtyIssueKind.zero));
    final bool packs = packFactor != null && packFactor.milli > 0;
    final Qty entered;
    try {
      entered = Qty.parseInput(input, precision: packs ? 0 : precision);
    } on AmountException catch (e) {
      if (e.error == AmountError.tooManyDecimals) {
        return (
          base: null,
          issue: packs
              ? const QtyIssue(QtyIssueKind.packInteger)
              : QtyIssue(QtyIssueKind.precision, precision: precision),
        );
      }
      return (base: null, issue: const QtyIssue(QtyIssueKind.invalid));
    }
    if (packs && entered.milli > maxInput.milli) {
      return (base: null, issue: const QtyIssue(QtyIssueKind.tooLarge, limit: maxInput));
    }
    final Qty base = packs ? Qty(entered.milli ~/ 1000 * packFactor.milli) : entered;
    return (base: base, issue: validate(base, packFactor: packFactor));
  }

  /// Пересчёт базового количества в упаковки (INV-003): целое число упаковок, при нецелом —
  /// ближайшее большее ([exact] = `false`, подсказка «2 кор = 12 шт»).
  static ({int packs, bool exact}) toPacks(Qty base, Qty factor) {
    if (factor.milli <= 0) return (packs: 0, exact: false);
    final ({int packs, Qty remainder}) r = Qty.baseToPacks(base.milli < 0 ? Qty.zero : base, factorMilli: factor.milli);
    if (r.remainder.isZero) return (packs: r.packs, exact: true);
    return (packs: r.packs + 1, exact: false);
  }
}
