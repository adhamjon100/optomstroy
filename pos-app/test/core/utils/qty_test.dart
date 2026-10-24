// Количества (milli-units): MV-05…MV-07, MV-23, MV-24 (10 §18.2), INV-006.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/amount_exception.dart';
import 'package:optomstroy/core/utils/qty.dart';

Matcher throwsAmount(AmountError error) => throwsA(isA<AmountException>().having((e) => e.error, 'error', error));

void main() {
  group('Qty.fromString (API QuantityValue)', () {
    test('"2.500" → 2500, целое, 3 знака', () {
      expect(Qty.fromString('2.500').milli, 2500);
      expect(Qty.fromString('124').milli, 124000);
      expect(Qty.fromString('0.005').milli, 5);
      expect(Qty.fromString('4.5').milli, 4500);
    });

    test('ошибки формата', () {
      expect(() => Qty.fromString('1.2345'), throwsAmount(AmountError.tooManyDecimals));
      expect(() => Qty.fromString('-1'), throwsAmount(AmountError.invalidFormat));
      expect(() => Qty.fromString('1,5'), throwsAmount(AmountError.invalidFormat));
    });

    test('toApiString — всегда 3 знака', () {
      expect(const Qty(124000).toApiString(), '124.000');
      expect(const Qty(2333).toApiString(), '2.333');
      expect(Qty.zero.toApiString(), '0.000');
    });

    test('операции', () {
      expect(Qty.units(3), const Qty(3000));
      expect(const Qty(1500) + const Qty(500), const Qty(2000));
      expect(const Qty(1500) - const Qty(500), const Qty(1000));
      expect(const Qty(1) < const Qty(2), isTrue);
      expect(const Qty(2) > const Qty(1), isTrue);
      expect(const Qty(2).compareTo(const Qty(1)), 1);
      expect(const Qty(2000).isWhole, isTrue);
      expect(const Qty(2001).isWhole, isFalse);
      expect(Qty.zero.isZero, isTrue);
    });
  });

  group('parseQty (MV-23, MV-24)', () {
    test('MV-23: «1 200,5», precision 1 → 1200,5', () {
      expect(Qty.parseInput('1 200,5', precision: 1), const Qty(1200500));
      expect(Qty.parseInput('1 200.5', precision: 1), const Qty(1200500));
    });

    test('MV-24: «2.3333», precision 3 → ошибка', () {
      expect(() => Qty.parseInput('2.3333', precision: 3), throwsAmount(AmountError.tooManyDecimals));
    });

    test('INV-006: precision 0 — дробь запрещена', () {
      expect(() => Qty.parseInput('1.5', precision: 0), throwsAmount(AmountError.tooManyDecimals));
      expect(Qty.parseInput('15', precision: 0), const Qty(15000));
    });

    test('неверный ввод и точность', () {
      expect(() => Qty.parseInput('abc', precision: 2), throwsAmount(AmountError.invalidFormat));
      expect(() => Qty.parseInput('', precision: 2), throwsAmount(AmountError.invalidFormat));
      expect(() => Qty.parseInput('1', precision: 4), throwsArgumentError);
      expect(() => Qty.parseInput('1', precision: -1), throwsArgumentError);
    });
  });

  group('packToBase (MV-05, MV-07)', () {
    test('MV-05: 5 кор × 12 = 60 шт', () {
      expect(Qty.packToBase(Qty.units(5), factorMilli: 12000, basePrecision: 0), Qty.units(60));
    });

    test('MV-07: 2,5 кор × 12 → «Количество упаковок должно быть целым»', () {
      expect(
        () => Qty.packToBase(const Qty(2500), factorMilli: 12000, basePrecision: 0),
        throwsAmount(AmountError.packsNotInteger),
      );
    });

    test('результат не помещается в точность базовой единицы', () {
      expect(
        () => Qty.packToBase(Qty.units(3), factorMilli: 500, basePrecision: 0),
        throwsAmount(AmountError.tooManyDecimals),
      );
      expect(Qty.packToBase(Qty.units(3), factorMilli: 500, basePrecision: 1), const Qty(1500));
    });

    test('недопустимые аргументы', () {
      expect(
        () => Qty.packToBase(Qty.units(1), factorMilli: 0, basePrecision: 0),
        throwsAmount(AmountError.outOfRange),
      );
      expect(
        () => Qty.packToBase(const Qty(-1000), factorMilli: 1000, basePrecision: 0),
        throwsAmount(AmountError.outOfRange),
      );
    });
  });

  group('baseToPacks (MV-06)', () {
    test('MV-06: 43 шт, factor 12 → 3 кор + 7 шт', () {
      final r = Qty.baseToPacks(Qty.units(43), factorMilli: 12000);
      expect(r.packs, 3);
      expect(r.remainder, Qty.units(7));
    });

    test('недопустимые аргументы', () {
      expect(() => Qty.baseToPacks(Qty.units(1), factorMilli: 0), throwsAmount(AmountError.outOfRange));
      expect(() => Qty.baseToPacks(const Qty(-1), factorMilli: 1000), throwsAmount(AmountError.outOfRange));
    });
  });

  test('fitsPrecision', () {
    expect(const Qty(1500).fitsPrecision(1), isTrue);
    expect(const Qty(1550).fitsPrecision(1), isFalse);
    expect(const Qty(1555).fitsPrecision(3), isTrue);
    expect(() => const Qty(1).fitsPrecision(5), throwsArgumentError);
  });
}
