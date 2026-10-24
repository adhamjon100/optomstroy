// Тест-векторы денежной арифметики 10 §18.2 (MV-01…MV-30, кроме MV-25 —
// форматирование DsMoneyFormat в design_system, 03 §17.1) + граничные ветви
// money.dart (AC-RM-C-004 п. 2: 100 % веток денежных утилит).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/amount_exception.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';

Money m(String value) => Money.fromString(value);
Qty q(String value) => Qty.fromString(value);
List<Money> ms(List<String> values) => [for (final v in values) m(v)];
Matcher throwsAmount(AmountError error) => throwsA(
  isA<AmountException>().having((e) => e.error, 'error', error).having((e) => e.code, 'code', 'VALIDATION_FAILED'),
);

void main() {
  group('Money.fromString (API MoneyAmount)', () {
    test('AC-RM-C-004: "1234.50" == 123450 тыйын', () {
      expect(Money.fromString('1234.50').tyiyn, 123450);
      expect(Money.fromString('1234.50'), const Money(123450));
    });

    test('знак, ноль, максимум 12 знаков целой части', () {
      expect(m('-842.50').tyiyn, -84250);
      expect(m('0.05').tyiyn, 5);
      expect(m('0.00').isZero, isTrue);
      expect(m('999999999999.99').tyiyn, 99999999999999);
    });

    test('MV-28: цена с 3 знаками → ошибка', () {
      expect(() => m('1234.565'), throwsAmount(AmountError.tooManyDecimals));
      expect(() => m('-1.001'), throwsAmount(AmountError.tooManyDecimals));
    });

    test('неверный формат', () {
      for (final bad in ['1234.5', '1234', '', 'abc', '1 234.50', '1234,50', '+1.00', '1234567890123.00']) {
        expect(() => m(bad), throwsAmount(AmountError.invalidFormat), reason: bad);
      }
    });
  });

  group('Money.parseInput', () {
    test('пробелы-разряды, запятая, 0–2 знака', () {
      expect(Money.parseInput('16 100,00').tyiyn, 1610000);
      expect(Money.parseInput('16 100').tyiyn, 1610000);
      expect(Money.parseInput('16 007,5').tyiyn, 1600750);
      expect(Money.parseInput('0.05').tyiyn, 5);
      expect(Money.parseInput('7.').tyiyn, 700);
    });

    test('ошибки ввода', () {
      expect(() => Money.parseInput('1,005'), throwsAmount(AmountError.tooManyDecimals));
      expect(() => Money.parseInput('-5'), throwsAmount(AmountError.invalidFormat));
      expect(() => Money.parseInput(''), throwsAmount(AmountError.invalidFormat));
    });
  });

  group('Money: операции и строка API', () {
    test('toApiString', () {
      expect(const Money(123450).toApiString(), '1234.50');
      expect(const Money(-84250).toApiString(), '-842.50');
      expect(const Money(5).toApiString(), '0.05');
      expect(Money.zero.toApiString(), '0.00');
    });

    test('арифметика и сравнения', () {
      const a = Money(1000);
      const b = Money(250);
      expect(a + b, const Money(1250));
      expect(a - b, const Money(750));
      expect(-a, const Money(-1000));
      expect((-a).isNegative, isTrue);
      expect(a.isNegative, isFalse);
      expect(b < a, isTrue);
      expect(a <= a, isTrue);
      expect(a > b, isTrue);
      expect(b >= a, isFalse);
      expect(a.compareTo(b), 1);
      expect(b.times(3), const Money(750));
      expect(Money.som(2350), const Money(235000));
      expect(Money.sum(ms(['1.00', '2.50'])), const Money(350));
    });
  });

  group('Percent', () {
    test('разбор и строка API', () {
      expect(Percent.fromString('5.00').hundredths, 500);
      expect(Percent.fromString('5').hundredths, 500);
      expect(Percent.fromString('12,5').hundredths, 1250);
      expect(Percent.fromString(' 100.00 ').hundredths, 10000);
      expect(const Percent(500).toApiString(), '5.00');
      expect(const Percent(1205).toApiString(), '12.05');
      expect(Percent.zero.hundredths, 0);
    });

    test('MV-26: 12,345 % → ошибка (не более 2 знаков)', () {
      expect(() => Percent.fromString('12,345'), throwsAmount(AmountError.tooManyDecimals));
    });

    test('> 100 % и неверный формат', () {
      expect(() => Percent.fromString('100.01'), throwsAmount(AmountError.outOfRange));
      expect(() => Percent.fromString('150'), throwsAmount(AmountError.outOfRange));
      expect(() => Percent.fromString('-5'), throwsAmount(AmountError.invalidFormat));
      expect(() => Percent.fromString('abc'), throwsAmount(AmountError.invalidFormat));
    });
  });

  group('lineTotal (MV-01…MV-04)', () {
    test('MV-01: 2 350,00 × 2 = 4 700,00', () => expect(MoneyMath.lineTotal(m('2350.00'), q('2')), m('4700.00')));
    test('MV-02: 85,00 × 4,5 м = 382,50', () => expect(MoneyMath.lineTotal(m('85.00'), q('4.5')), m('382.50')));
    test('MV-03: 85,00 × 2,333 м = 198,31 (198,305 → HALF_UP)', () {
      expect(MoneyMath.lineTotal(m('85.00'), q('2.333')), m('198.31'));
    });
    test('MV-04: 0,10 × 0,005 кг = 0,00', () => expect(MoneyMath.lineTotal(m('0.10'), q('0.005')), m('0.00')));

    test('HALF_UP для отрицательных — от нуля', () {
      expect(MoneyMath.lineTotal(m('-85.00'), q('2.333')), m('-198.31'));
      expect(MoneyMath.lineTotal(m('-0.01'), q('0.5')), m('-0.01'));
      expect(MoneyMath.lineTotal(m('-0.01'), q('0.4')), m('0.00'));
    });

    test('переполнение int → outOfRange', () {
      expect(
        () => MoneyMath.lineTotal(const Money(9000000000000000000), Qty.units(1000)),
        throwsAmount(AmountError.outOfRange),
      );
    });
  });

  group('documentDiscount и итог (MV-08, MV-09, MV-14, MV-27)', () {
    test('MV-08: 16 850,00 × 5 % = 842,50', () {
      expect(MoneyMath.documentDiscount(m('16850.00'), Percent.fromString('5')), m('842.50'));
    });

    test('MV-09: 16 850,00 − 842,50 = 16 007,50', () {
      final discount = MoneyMath.documentDiscount(m('16850.00'), Percent.fromString('5'));
      expect(m('16850.00') - discount, m('16007.50'));
    });

    test('MV-14: 18 050 × 5 % → скидка 902,50, итог 17 147,50', () {
      final lines = [
        MoneyMath.lineTotal(m('2350.00'), q('2')),
        MoneyMath.lineTotal(m('540.00'), q('5')),
        MoneyMath.lineTotal(m('6800.00'), q('1')),
        MoneyMath.lineTotal(m('120.00'), q('10')),
        MoneyMath.lineTotal(m('530.00'), q('5')),
      ];
      final subtotal = Money.sum(lines);
      expect(subtotal, m('18050.00'));
      final discount = MoneyMath.documentDiscount(subtotal, Percent.fromString('5'));
      expect(discount, m('902.50'));
      expect(subtotal - discount, m('17147.50'));
    });

    test('MV-27: 0,01 × 5 % = 0,00', () {
      expect(MoneyMath.documentDiscount(m('0.01'), Percent.fromString('5')), m('0.00'));
    });
  });

  group('allocateDiscount (MV-10…MV-13)', () {
    test('MV-10: корзина макета, delta = 0', () {
      final result = MoneyMath.allocateDiscount(
        ms(['4700.00', '3450.00', '1650.00', '2850.00', '4200.00']),
        m('842.50'),
      );
      expect(result, ms(['235.00', '172.50', '82.50', '142.50', '210.00']));
      expect(Money.sum(result), m('842.50'));
    });

    test('MV-11: коррекция +0,01 в последней строке', () {
      final result = MoneyMath.allocateDiscount(ms(['33.33', '33.33', '33.33']), m('10.00'));
      expect(result, ms(['3.33', '3.33', '3.34']));
    });

    test('MV-12: 5 % от 2 825,49 = 141,27', () {
      final lines = ms(['999.99', '1250.00', '575.50']);
      final discount = MoneyMath.documentDiscount(Money.sum(lines), Percent.fromString('5'));
      expect(discount, m('141.27'));
      expect(MoneyMath.allocateDiscount(lines, discount), ms(['50.00', '62.50', '28.77']));
    });

    test('MV-13: нулевая строка не получает скидку', () {
      expect(MoneyMath.allocateDiscount(ms(['100.00', '0.00']), m('10.00')), ms(['10.00', '0.00']));
    });

    test('нулевая последняя строка пропускается при коррекции', () {
      expect(
        MoneyMath.allocateDiscount(ms(['33.33', '33.33', '33.33', '0.00']), m('10.00')),
        ms(['3.33', '3.33', '3.34', '0.00']),
      );
    });

    test('положительная коррекция не помещается в последнюю строку — перенос на предыдущую', () {
      // alloc = [1,1,1,1,0] (Σ4), delta = +2; последняя строка вмещает 1.
      const lines = [Money(3), Money(3), Money(3), Money(3), Money(1)];
      final result = MoneyMath.allocateDiscount(lines, const Money(6));
      expect(result, const [Money(1), Money(1), Money(1), Money(2), Money(1)]);
      expect(Money.sum(result), const Money(6));
    });

    test('отрицательная коррекция больше последней доли — перенос на предыдущую', () {
      // alloc = [2,2,2,1] (Σ7), delta = −2.
      const lines = [Money(3), Money(3), Money(3), Money(1)];
      final result = MoneyMath.allocateDiscount(lines, const Money(5));
      expect(result, const [Money(2), Money(2), Money(1), Money(0)]);
    });

    test('все строки нулевые, скидка 0 → нули; пустой список', () {
      expect(MoneyMath.allocateDiscount(ms(['0.00', '0.00']), Money.zero), ms(['0.00', '0.00']));
      expect(MoneyMath.allocateDiscount(const [], Money.zero), isEmpty);
    });

    test('гарантии Σ = скидка и 0 ≤ alloc ≤ line на переборе', () {
      final lines = ms(['0.01', '0.02', '0.03', '17.77', '0.00', '1000.01']);
      final total = Money.sum(lines);
      for (var d = 0; d <= total.tyiyn; d += 7) {
        final result = MoneyMath.allocateDiscount(lines, Money(d));
        expect(Money.sum(result).tyiyn, d);
        for (var i = 0; i < lines.length; i++) {
          expect(result[i].tyiyn, inInclusiveRange(0, lines[i].tyiyn));
        }
      }
    });

    test('ошибки: отрицательные значения, скидка больше суммы', () {
      expect(() => MoneyMath.allocateDiscount(ms(['1.00']), m('-0.01')), throwsAmount(AmountError.negative));
      expect(() => MoneyMath.allocateDiscount(ms(['-1.00', '2.00']), m('0.01')), throwsAmount(AmountError.negative));
      expect(() => MoneyMath.allocateDiscount(ms(['1.00']), m('1.01')), throwsAmount(AmountError.outOfRange));
    });
  });

  group('twoStageDiscount (MV-29, MV-30)', () {
    test('MV-29: скидка клиента 5 % + ручная 5 %', () {
      final r = MoneyMath.twoStageDiscount(
        ms(['2350.00', '4800.00', '3200.00', '5000.00', '1500.00']),
        Percent.fromString('5'),
        Percent.fromString('5'),
      );
      expect(r.customer, ms(['117.50', '240.00', '160.00', '250.00', '75.00']));
      expect(Money.sum(r.customer), m('842.50'));
      expect(r.manual, ms(['111.63', '228.00', '152.00', '237.50', '71.25']));
      expect(Money.sum(r.manual), m('800.38'));
      expect(Money.sum(r.customer) + Money.sum(r.manual), m('1642.88'));
      expect(r.lineTotals, ms(['2120.87', '4332.00', '2888.00', '4512.50', '1353.75']));
      expect(r.total, m('15207.12'));
    });

    test('MV-30: коррекция −0,01 в последней строке этапа 2', () {
      final r = MoneyMath.twoStageDiscount(
        ms(['33.33', '33.33', '33.33']),
        Percent.fromString('5'),
        Percent.fromString('10'),
      );
      expect(r.customer, ms(['1.67', '1.67', '1.67']));
      expect(r.manual, ms(['3.17', '3.17', '3.16']));
      expect(r.lineTotals, ms(['28.49', '28.49', '28.50']));
      expect(r.total, m('85.48'));
      expect(r.total, m('99.99') - m('5.01') - m('9.50'));
    });

    test('при c = 0 совпадает с documentDiscount + allocateDiscount', () {
      final lines = ms(['4700.00', '3450.00', '1650.00', '2850.00', '4200.00']);
      final r = MoneyMath.twoStageDiscount(lines, Percent.zero, Percent.fromString('5'));
      expect(r.manual, MoneyMath.allocateDiscount(lines, m('842.50')));
      expect(r.customer, everyElement(Money.zero));
    });

    test('отрицательная строка → ошибка', () {
      expect(
        () => MoneyMath.twoStageDiscount(ms(['-1.00']), Percent.zero, Percent.zero),
        throwsAmount(AmountError.negative),
      );
    });
  });

  group('cashRounding (MV-15, MV-16)', () {
    test('MV-15: none — без изменений', () {
      final r = MoneyMath.cashRounding(m('16007.50'), CashRoundingMode.none);
      expect(r.rounded, m('16007.50'));
      expect(r.delta, Money.zero);
    });

    test('MV-16: to_som_half_up — 16 008,00, delta +0,50', () {
      final r = MoneyMath.cashRounding(m('16007.50'), CashRoundingMode.toSomHalfUp);
      expect(r.rounded, m('16008.00'));
      expect(r.delta, m('0.50'));
      expect(MoneyMath.cashRounding(m('16007.49'), CashRoundingMode.toSomHalfUp).rounded, m('16007.00'));
    });

    test('to_som_down — отбрасывает тыйыны', () {
      final r = MoneyMath.cashRounding(m('16007.99'), CashRoundingMode.toSomDown);
      expect(r.rounded, m('16007.00'));
      expect(r.delta, m('-0.99'));
    });

    test('значения настройки', () {
      expect(CashRoundingMode.values.map((e) => e.value), ['none', 'to_som_half_up', 'to_som_down']);
    });
  });

  group('change (MV-17, MV-18)', () {
    test('MV-17: сдача 92,50', () => expect(MoneyMath.change(m('16007.50'), m('16100.00')), m('92.50')));
    test('MV-18: получено меньше суммы → ошибка', () {
      expect(() => MoneyMath.change(m('16007.50'), m('16000.00')), throwsAmount(AmountError.receivedLessThanTotal));
    });
    test('без сдачи', () => expect(MoneyMath.change(m('10.00'), m('10.00')), Money.zero));
  });

  group('returnLineAmount (MV-19, MV-20)', () {
    test('MV-19: 4 465,00, отгружено 2, возврат 1 → 2 232,50', () {
      expect(MoneyMath.returnLineAmount(m('4465.00'), q('2'), q('1')), m('2232.50'));
    });

    test('MV-20: 198,31, отгружено 2,333 м, возврат 1,000 м → 85,00', () {
      expect(MoneyMath.returnLineAmount(m('198.31'), q('2.333'), q('1.000')), m('85.00'));
    });

    test('полный возврат — ровно сумма строки', () {
      expect(MoneyMath.returnLineAmount(m('198.31'), q('2.333'), q('2.333')), m('198.31'));
    });

    test('ошибки: возврат больше отгрузки, нулевые количества', () {
      expect(() => MoneyMath.returnLineAmount(m('1.00'), q('1'), q('2')), throwsAmount(AmountError.outOfRange));
      expect(() => MoneyMath.returnLineAmount(m('1.00'), q('0'), q('0')), throwsAmount(AmountError.outOfRange));
      expect(() => MoneyMath.returnLineAmount(m('1.00'), q('1'), q('0')), throwsAmount(AmountError.outOfRange));
    });
  });

  group('creditRemaining (MV-21, MV-22)', () {
    test('MV-21: 100 000 − 64 500 − 20 000 = 15 500; заказ 16 007,50 превышает', () {
      final remaining = MoneyMath.creditRemaining(m('100000.00'), m('64500.00'), m('20000.00'));
      expect(remaining, m('15500.00'));
      expect(m('16007.50') > remaining, isTrue);
    });

    test('MV-22: лимит исчерпан → −12 000', () {
      expect(MoneyMath.creditRemaining(m('50000.00'), m('62000.00'), Money.zero), m('-12000.00'));
    });
  });

  test('AmountException.toString без значений', () {
    expect(const AmountException(AmountError.negative).toString(), 'AmountException(negative)');
    expect(AmountError.values.map((e) => e.rule).toSet(), hasLength(AmountError.values.length));
  });
}
