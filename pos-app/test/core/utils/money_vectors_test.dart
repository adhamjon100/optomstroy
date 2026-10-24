// Общие тест-векторы MV-01…MV-30 (10 §18.2, MNY-004): тот же файл
// contracts/test-vectors/money.v1.json исполняет pos-api
// (src/common/money/money-vectors.spec.ts). Ревью C-CR-01: распределение
// скидки клиента и сервера совпадает построчно.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/amount_exception.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';

Money m(String value) => Money.fromString(value);
List<Money> ms(List<dynamic> values) => [for (final v in values) m(v as String)];
List<String> str(List<Money> values) => [for (final v in values) v.toApiString()];

/// Количество в векторах — строка Quantity без обязательных 3 знаков ("2", "2.333").
Qty q(String value) {
  final parts = value.split('.');
  final fraction = parts.length > 1 ? parts[1].padRight(3, '0') : '000';
  return Qty(int.parse(parts[0]) * 1000 + int.parse(fraction));
}

Percent p(String value) => Percent.fromString(value);

AmountError? errorOf(void Function() fn) {
  try {
    fn();
    return null;
  } on AmountException catch (e) {
    return e.error;
  }
}

AmountError errorByName(String name) => switch (name) {
  'negative' => AmountError.negative,
  'outOfRange' => AmountError.outOfRange,
  'receivedLessThanTotal' => AmountError.receivedLessThanTotal,
  _ => throw ArgumentError('неизвестная ошибка вектора: $name'),
};

CashRoundingMode modeByValue(String value) => CashRoundingMode.values.firstWhere((mode) => mode.value == value);

void main() {
  final file = File('../contracts/test-vectors/money.v1.json');
  final vectors = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  List<Map<String, dynamic>> group0(String name) => [
    for (final v in vectors[name] as List<dynamic>) v as Map<String, dynamic>,
  ];

  group('общие векторы contracts/test-vectors/money.v1.json', () {
    for (final v in group0('lineTotal')) {
      test('lineTotal ${v['id']}', () {
        expect(MoneyMath.lineTotal(m(v['unitPrice'] as String), q(v['qty'] as String)), m(v['expected'] as String));
      });
    }

    for (final v in group0('documentDiscount')) {
      test('documentDiscount ${v['id']}', () {
        expect(
          MoneyMath.documentDiscount(m(v['subtotal'] as String), p(v['percent'] as String)),
          m(v['expected'] as String),
        );
      });
    }

    for (final v in group0('allocateDiscount')) {
      test('allocateDiscount ${v['id']}', () {
        final result = MoneyMath.allocateDiscount(ms(v['lines'] as List<dynamic>), m(v['discount'] as String));
        expect(str(result), (v['expected'] as List<dynamic>).cast<String>());
        expect(Money.sum(result), m(v['discount'] as String));
      });
    }

    for (final v in group0('allocateDiscountErrors')) {
      test('allocateDiscount ошибка ${v['id']}', () {
        expect(
          errorOf(() => MoneyMath.allocateDiscount(ms(v['lines'] as List<dynamic>), m(v['discount'] as String))),
          errorByName(v['error'] as String),
        );
      });
    }

    for (final v in group0('twoStageDiscount')) {
      test('twoStageDiscount ${v['id']}', () {
        final r = MoneyMath.twoStageDiscount(
          ms(v['lines'] as List<dynamic>),
          p(v['customerPercent'] as String),
          p(v['manualPercent'] as String),
        );
        expect(str(r.customer), (v['customer'] as List<dynamic>).cast<String>());
        expect(str(r.manual), (v['manual'] as List<dynamic>).cast<String>());
        expect(str(r.lineTotals), (v['lineTotals'] as List<dynamic>).cast<String>());
        expect(r.total, m(v['total'] as String));
      });
    }

    for (final v in group0('cashRounding')) {
      test('cashRounding ${v['id']}', () {
        final r = MoneyMath.cashRounding(m(v['total'] as String), modeByValue(v['mode'] as String));
        expect(r.rounded, m(v['rounded'] as String));
        expect(r.delta, m(v['delta'] as String));
      });
    }

    for (final v in group0('change')) {
      test('change ${v['id']}', () {
        if (v['error'] != null) {
          expect(
            errorOf(() => MoneyMath.change(m(v['total'] as String), m(v['received'] as String))),
            errorByName(v['error'] as String),
          );
        } else {
          expect(MoneyMath.change(m(v['total'] as String), m(v['received'] as String)), m(v['expected'] as String));
        }
      });
    }

    for (final v in group0('returnLineAmount')) {
      test('returnLineAmount ${v['id']}', () {
        expect(
          MoneyMath.returnLineAmount(
            m(v['lineTotal'] as String),
            q(v['shippedQty'] as String),
            q(v['returnQty'] as String),
          ),
          m(v['expected'] as String),
        );
      });
    }

    for (final v in group0('creditRemaining')) {
      test('creditRemaining ${v['id']}', () {
        expect(
          MoneyMath.creditRemaining(m(v['limit'] as String), m(v['balance'] as String), m(v['openOrders'] as String)),
          m(v['expected'] as String),
        );
      });
    }
  });
}
