// Golden SCR-21 «Оформление заказа» (каждый шаг; compact / medium / expanded — D-18, макет IMG_7090) и SCR-22
// «Заказ создан / QR» (три класса окна), палитра B. Данные — корзина макета (16 850,00 − 842,50 = 16 007,50 сом).
//
// Обновить эталоны: flutter test test/features/checkout/golden --update-goldens
// Проверить:        flutter test test/features/checkout/golden
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/checkout/presentation/screens/checkout_screen.dart';
import 'package:optomstroy/features/checkout/presentation/screens/order_created_screen.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

import '../checkout_test_support.dart';

/// Кадры без `pumpAndSettle` (индикаторы ожидания бесконечны).
Future<void> _frames(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Окно с экраном и фейками.
class _Window extends StatelessWidget {
  const _Window({required this.size, required this.harness, required this.child});

  final Size size;
  final CheckoutHarness harness;
  final Widget child;

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: harness.overrides,
    child: MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero),
      child: Localizations(
        locale: const Locale('ru'),
        delegates: AppLocalizations.localizationsDelegates,
        child: Material(
          color: DsColors.lightB.background,
          child: SizedBox.fromSize(
            size: size,
            child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => child)),
          ),
        ),
      ),
    ),
  );
}

/// SCR-21: кассир, клиент 1С выбран, наличные; шаг [step] (compact) из черновика.
CheckoutHarness _checkout({CheckoutStep step = CheckoutStep.customer, bool delivery = false}) {
  final CheckoutHarness h = CheckoutHarness(
    prefs: CheckoutPrefs(
      paymentMethod: step == CheckoutStep.payment ? PaymentMethod.qrBakai : PaymentMethod.cash,
      deliveryMethod: delivery ? DeliveryMethod.delivery : DeliveryMethod.pickup,
    ),
  )..stubDefaults(cart: mockupCart(customer: mockupCustomer()));
  if (step != CheckoutStep.customer) {
    h.drafts.drafts['cart-1'] = CheckoutDraft(
      localCartId: 'cart-1',
      step: step,
      updatedAt: testNow,
      customerId: 'cust-1',
      deliveryMethod: delivery ? DeliveryMethod.delivery : DeliveryMethod.pickup,
      receiverKind: ReceiverKind.customer,
      paymentMethod: step == CheckoutStep.payment ? PaymentMethod.qrBakai : PaymentMethod.cash,
    );
  }
  return h;
}

/// SCR-22: QR через 1С, ожидание оплаты.
CheckoutHarness _created() {
  final Order order = createdOrder(
    method: PaymentMethod.qrBakai,
    status: OrderStatus.awaitingPayment,
    payments: <Payment>[qrPayment()],
    onecNumber: 'УТ-0001234',
  );
  final CheckoutHarness h = CheckoutHarness();
  h.fakes.orders.onGet = (String id, bool r) async => Success<OrderDetails>(OrderDetails(order: order));
  return h;
}

void main() {
  group('SCR-21 оформление', () {
    for (final String w in <String>['expanded', 'medium']) {
      unawaited(
        goldenTest(
          'SCR-21 · $w',
          fileName: 'scr21_checkout_$w',
          constraints: BoxConstraints.tight(checkoutWindows[w]!),
          pumpBeforeTest: _frames,
          // Маршрут SCR-21 на medium/expanded прозрачный (02 SCR-21.2): под окном — фон раскладки SCR-10.
          builder: () => _Window(
            size: checkoutWindows[w]!,
            harness: _checkout(),
            child: Builder(
              builder: (BuildContext context) => ColoredBox(
                color: context.colors.background,
                child: const CheckoutScreen(cartId: 'cart-1'),
              ),
            ),
          ),
        ),
      );
    }
    for (final (CheckoutStep step, bool delivery) in <(CheckoutStep, bool)>[
      (CheckoutStep.customer, false),
      (CheckoutStep.delivery, true),
      (CheckoutStep.payment, false),
      (CheckoutStep.review, false),
    ]) {
      unawaited(
        goldenTest(
          'SCR-21 · compact · ${step.value}',
          fileName: 'scr21_checkout_compact_${step.value}',
          constraints: BoxConstraints.tight(checkoutWindows['compact']!),
          pumpBeforeTest: _frames,
          builder: () => _Window(
            size: checkoutWindows['compact']!,
            harness: _checkout(step: step, delivery: delivery),
            child: const CheckoutScreen(cartId: 'cart-1'),
          ),
        ),
      );
    }
  });

  group('SCR-22 заказ создан / QR', () {
    for (final MapEntry<String, Size> w in checkoutWindows.entries) {
      unawaited(
        goldenTest(
          'SCR-22 · ${w.key}',
          fileName: 'scr22_order_created_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          pumpBeforeTest: _frames,
          builder: () => _Window(
            size: w.value,
            harness: _created(),
            child: const OrderCreatedScreen(orderId: 'order-1', paymentId: 'pay-1'),
          ),
        ),
      );
    }
  });
}
