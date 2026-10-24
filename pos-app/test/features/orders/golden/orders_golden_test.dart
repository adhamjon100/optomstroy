// Golden SCR-24 «Заказ» и SCR-25 «Список заказов» на трёх брейкпоинтах compact / medium / expanded (D-18; 13 RM-F-006,
// RM-F-013 п. 5 — чипы со счётчиками `statusCounts`): палитра B, reduce-motion, синтетические данные (деньги — целые
// тыйыны), «сейчас» зафиксировано (время Бишкека — без зависимости от пояса машины). Эталоны: `goldens/ci/` (текст
// блоками, любая ОС) и `goldens/windows/` (только Windows).
//
// Обновить эталоны: flutter test test/features/orders/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/presentation/screens/order_details_screen.dart';
import 'package:optomstroy/features/orders/presentation/screens/orders_screen.dart';

import '../../../support/f_fakes.dart';
import '../support/orders_harness.dart';

OrdersHarness _listHarness() => OrdersHarness(
  orders: FakeOrdersRepository()
    ..onList = (OrdersQuery q) async => Success<OrdersPage>(
      ordersPage(
        <OrderSummary>[
          summary(123, onecNumber: 'УТ-0001234'),
          summary(122, status: OrderStatus.awaitingPayment, totalSom: 8450, paidSom: 4000, onecNumber: 'УТ-0001233'),
          summary(121, status: OrderStatus.submitting, totalSom: 2350),
          summary(
            120,
            status: OrderStatus.shipped,
            totalSom: 41200,
            method: PaymentMethod.credit,
            onecNumber: 'УТ-0001230',
          ),
          summary(
            119,
            status: OrderStatus.closed,
            totalSom: 9400,
            isPaid: true,
            paidSom: 9400,
            onecNumber: 'УТ-0001229',
          ),
          summary(118, status: OrderStatus.cancelled, totalSom: 1650, onecNumber: 'УТ-0001228'),
        ],
        total: 31,
        counts: kCounts,
      ),
    ),
);

OrdersHarness _detailsHarness() => OrdersHarness(
  orders: FakeOrdersRepository()
    ..onGet = (String id, bool refresh) async => Success<OrderDetails>(
      details(
        order(
          status: OrderStatus.awaitingPayment,
          method: PaymentMethod.qrBakai,
          paidTyiyn: 800000,
          payments: <Payment>[
            payment(tyiyn: 800000),
            payment(id: 'pay-2', method: PaymentMethod.qrBakai, status: PaymentStatus.qrShown, tyiyn: 800750),
          ],
          totalsDiffer: true,
        ),
        <OrderAction>{OrderAction.pay, OrderAction.cancel, OrderAction.printInvoice},
      ),
    ),
);

Future<void> _prepare(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, (OrdersHarness Function(), Widget)> scenes = <String, (OrdersHarness Function(), Widget)>{
    'scr25_orders': (_listHarness, const OrdersScreen()),
    'scr24_order': (_detailsHarness, const OrderDetailsScreen(orderId: 'o1')),
  };

  for (final MapEntry<String, (OrdersHarness Function(), Widget)> scene in scenes.entries) {
    for (final MapEntry<String, Size> w in kWindows.entries) {
      unawaited(
        goldenTest(
          '${scene.key} · ${w.key}',
          fileName: 'orders_${scene.key}_${w.key}',
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
