// Golden SCR-36 «Транзакции» (список с заголовками дней — compact/medium, таблица с панелью фильтров — expanded) и
// SCR-37 «Транзакция: детали» на трёх брейкпоинтах (D-18; 13 RM-G-007 п. 1). Палитра B, reduce-motion,
// синтетические данные (деньги — целые тыйыны), «сейчас» зафиксировано (Бишкек).
//
// Обновить эталоны: flutter test test/features/transactions/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/presentation/screens/transaction_details_screen.dart';
import 'package:optomstroy/features/transactions/presentation/screens/transactions_screen.dart';

import '../../cashier/support/cashier_harness.dart';

CashierHarness _list() {
  final CashierHarness h = CashierHarness();
  h.transactions.onList = (TransactionsQuery q) async => Success<TransactionsPage>(
    txPage(<Transaction>[
      tx('t1', at: DateTime.utc(2026, 10, 22, 4, 10)),
      tx(
        't2',
        kind: TransactionKind.paymentVoided,
        sign: TransactionSign.minus,
        group: TransactionStatusGroup.voided,
        tyiyn: 235000,
        number: '1025',
        at: DateTime.utc(2026, 10, 22, 3),
      ),
      tx(
        't3',
        kind: TransactionKind.manualQrConfirm,
        number: '1022',
        tyiyn: 845000,
        at: DateTime.utc(2026, 10, 22, 2, 15),
      ),
      tx(
        't4',
        kind: TransactionKind.orderCreated,
        group: TransactionStatusGroup.onecError,
        number: '1023',
        source: TransactionSource.onec,
        at: DateTime.utc(2026, 10, 21, 9),
      ),
      tx(
        't5',
        kind: TransactionKind.refund,
        sign: TransactionSign.minus,
        group: TransactionStatusGroup.returned,
        tyiyn: 120000,
        number: '1019',
        at: DateTime.utc(2026, 10, 21, 7, 30),
      ),
    ], summary: const TransactionsSummary(count: 5, sumIn: Money(4046750), sumOut: Money(355000))),
  );
  return h;
}

CashierHarness _details() {
  final CashierHarness h = CashierHarness();
  h.transactions.onGet = (String id) async => Success<TransactionDetail>(
    txDetail(
      tx(
        id,
        related: const <TransactionRelated>[
          TransactionRelated(type: TransactionRelatedType.order, id: 'o1', number: 'POS-2026-000123'),
          TransactionRelated(type: TransactionRelatedType.payment, id: 'pay-1', number: 'PAY-77'),
        ],
      ),
    ),
  );
  h.payments.onGet = (String id, bool refresh) async => const Success<PaymentDetails>(
    PaymentDetails(
      payment: Payment(
        id: 'pay-1',
        orderId: 'o1',
        method: PaymentMethod.qrBakai,
        status: PaymentStatus.manualConfirm,
        amount: Money(1600750),
        bankAmount: Money(1600000),
        reviewReason: ReviewReason.amountMismatch,
      ),
      allowedActions: <PaymentAction>{PaymentAction.voidPayment, PaymentAction.confirmManual},
    ),
  );
  h.orders.onGet = (String id, bool refresh) async =>
      Success<OrderDetails>(OrderDetails(order: payOrder(), allowedActions: const <OrderAction>{OrderAction.pay}));
  return h;
}

Future<void> _prepare(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, (CashierHarness Function(), Widget)> scenes = <String, (CashierHarness Function(), Widget)>{
    'scr36_transactions': (_list, const TransactionsScreen()),
    'scr37_details': (_details, const TransactionDetailsScreen(transactionId: 't1')),
  };

  for (final MapEntry<String, (CashierHarness Function(), Widget)> scene in scenes.entries) {
    for (final MapEntry<String, Size> w in kWindows.entries) {
      unawaited(
        goldenTest(
          '${scene.key} · ${w.key}',
          fileName: 'transactions_${scene.key}_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          pumpBeforeTest: _prepare,
          builder: () => SizedBox(
            width: w.value.width,
            height: w.value.height,
            child: scene.value.$1().app(scene.value.$2, size: w.value),
          ),
        ),
      );
    }
  }
}
