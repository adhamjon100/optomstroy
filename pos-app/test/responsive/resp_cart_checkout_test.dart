// T-UI-117: прогон адаптивности корзины и оформления — SCR-20 «Корзина» (окна уже 600 — экран `/cart`, шире —
// drawer корзины 420 над затемнением, ADR-112), SCR-23 «Отложенные заказы», SCR-21 «Оформление» (шаги «Клиент»,
// «Доставка», «Оплата», «Проверка»), SCR-22 «Заказ создан / QR» — по окнам 360…2560 (портрет и ландшафт, окна
// масштаба страницы веб-демо) при масштабе текста 1 и 1,3: без переполнения и недоступных элементов (03 §8.8;
// указание владельца 2026-11-18, 15 §5.8 (3)). Корзина канонического примера 02 ч. C §3.2; деньги — целые тыйыны.
// Сцены «корзина предварительно / офлайн» (ревью own-server:FIX-app): «Итого» с меткой «предварительно» и крупной
// суммой — окна прогона, телефон 390 и drawer во всю ширину окна 360, масштаб текста 1, 1,3 и 1,5.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/cart_summary.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/checkout/presentation/screens/order_created_screen.dart';

import '../support/responsive_audit.dart';
import 'support/resp_cart_checkout_scenes.dart';

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, (RespBuild, RespSettle)> scenes = <String, (RespBuild, RespSettle)>{
    'scr20_cart': ((Size s, double _) => respCart(s), respFrames),
    'scr23_parked': ((Size s, double _) => respParkedCarts(s), respFrames),
    'scr21_customer': ((Size s, double _) => respCheckoutWindow(s, CheckoutStep.customer), respCheckoutFrames),
    'scr21_delivery': (
      (Size s, double _) => respCheckoutWindow(s, CheckoutStep.delivery, delivery: true),
      respCheckoutFrames,
    ),
    'scr21_payment': ((Size s, double _) => respCheckoutWindow(s, CheckoutStep.payment), respCheckoutFrames),
    'scr21_review': ((Size s, double _) => respCheckoutWindow(s, CheckoutStep.review), respCheckoutFrames),
    'scr22_created': (
      (Size s, double _) => RespCheckoutWindow(
        size: s,
        harness: respCreated(),
        child: const OrderCreatedScreen(orderId: 'order-1', paymentId: 'pay-1'),
      ),
      respCheckoutFrames,
    ),
  };

  for (final MapEntry<String, (RespBuild, RespSettle)> scene in scenes.entries) {
    testWidgets('T-UI-117 ${scene.key}: окна 360…2560 × текст 1 / 1,3', (WidgetTester tester) async {
      final RespAudit audit = RespAudit(scene.key);
      await audit.run(tester, scene.value.$1, settle: scene.value.$2);
      audit.expectNoBlocking();
    });
  }

  // Ревью own-server:FIX-app: «Итого» с меткой «предварительно» (UI-20-030) — очередь отправки не пуста или сеть
  // пропала после загрузки — и крупная сумма «124 450,00 сом»: сумма целиком, без уменьшения `FittedBox` (раньше
  // метка `Flexible` отнимала у суммы половину свободного места строки). Окна прогона, телефон 390 и drawer во всю
  // ширину окна 360 (планшет магазина) при масштабе текста 1, 1,3 и 1,5.
  for (final bool offline in <bool>[false, true]) {
    final String name = offline ? 'scr20_cart_offline' : 'scr20_cart_preliminary';
    final RespSettle settle = offline ? respGoOffline : respFrames;
    testWidgets('T-UI-117 $name: окна 360…2560, телефон 390, drawer 360 × текст 1 / 1,3 / 1,5', (
      WidgetTester tester,
    ) async {
      final RespAudit audit = RespAudit(name);
      await audit.run(
        tester,
        (Size s, double _) => respCartPreliminary(s, offline: offline),
        settle: settle,
        windows: const <RespWindow>[...kRespWindows, (name: 'phone-390x844', size: Size(390, 844))],
      );
      await audit.run(
        tester,
        (Size s, double _) => respCartPreliminary(s, offline: offline, drawer: true),
        settle: settle,
        windows: const <RespWindow>[(name: 'drawer-360x780', size: Size(360, 780))],
      );
      audit.expectNoBlocking();
    });

    testWidgets('$name: у «Итого» метка «предварительно» и сумма сервера', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final (Size size, bool drawer) in <(Size, bool)>[
        (const Size(360, 780), false),
        (const Size(800, 900), false),
        (const Size(360, 780), true),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          KeyedSubtree(
            key: ValueKey<String>('$size $drawer'),
            child: respCartPreliminary(size, offline: offline, drawer: drawer),
          ),
        );
        await settle(tester, size);
        final Finder summary = find.byType(CartSummary);
        expect(summary, findsOneWidget, reason: '$size drawer=$drawer');
        expect(tester.widget<CartSummary>(summary).drawer, drawer || size.width >= 600, reason: '$size');
        expect(tester.widget<CartSummary>(summary).preliminaryLabel, isNotNull, reason: '$size drawer=$drawer');
        expect(
          tester.widget<Text>(find.byKey(CartSummary.totalKey)).data,
          PriceText.format(respBigCart().total!, fixed2: true),
          reason: '$size drawer=$drawer',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
