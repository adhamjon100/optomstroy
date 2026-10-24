// Golden SCR-30 «Дашборд кассира» и SCR-38 «Приём оплаты» (наличные и QR) на трёх брейкпоинтах compact / medium /
// expanded (D-18; 13 RM-G-007 п. 1): палитра B, reduce-motion, синтетические данные (деньги — целые тыйыны), «сейчас»
// зафиксировано (Бишкек). Эталоны: `goldens/ci/` (текст блоками, любая ОС) и `goldens/windows/` (только Windows).
//
// Обновить эталоны: flutter test test/features/cashier/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/cashier/presentation/screens/cashier_dashboard_screen.dart';
import 'package:optomstroy/features/cashier/presentation/screens/payment_screen.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

import '../support/cashier_harness.dart';

CashierHarness _dashboard() {
  final CashierHarness h = CashierHarness();
  h.cashier.onDashboard = () async => Success<PosDashboard>(dashboard());
  return h;
}

CashierHarness _payment({Order? order}) {
  final CashierHarness h = CashierHarness();
  final Order o = order ?? payOrder();
  h.orders.onGet = (String id, bool refresh) async =>
      Success<OrderDetails>(OrderDetails(order: o, allowedActions: const <OrderAction>{OrderAction.pay}));
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
    'scr30_dashboard': (_dashboard, const CashierDashboardScreen()),
    'scr38_cash': (_payment, const PaymentScreen(orderId: 'o1', method: 'cash')),
    'scr38_qr': (
      () => _payment(
        order: payOrder(method: PaymentMethod.qrBakai, payments: <Payment>[qrPayment()]),
      ),
      const PaymentScreen(orderId: 'o1'),
    ),
  };

  for (final MapEntry<String, (CashierHarness Function(), Widget)> scene in scenes.entries) {
    for (final MapEntry<String, Size> w in kWindows.entries) {
      unawaited(
        goldenTest(
          '${scene.key} · ${w.key}',
          fileName: 'cashier_${scene.key}_${w.key}',
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
