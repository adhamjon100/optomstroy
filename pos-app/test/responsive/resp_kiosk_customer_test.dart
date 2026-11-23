// T-UI-117: прогон адаптивности планшета магазина и режима клиента — SCR-51 «Витрина» (и drawer корзины, баннер
// «Планшет нужно обновить», полноэкранное состояние «Сервис временно недоступен»), SCR-52 «Оформление» (шаги
// «Телефон» и «Код»), SCR-53 «Заявка отправлена», диалог аварийного выхода UI-51-017; режим `customer` — SCR-24
// «Заказ», SCR-34 «Долги» (привязка подтверждена и предложена) — по окнам 360…2560 (портрет и ландшафт, окна
// масштаба страницы веб-демо) при масштабе текста 1 и 1,3: без переполнения и недоступных элементов (03 §8.8;
// указание владельца 2026-11-18, 15 §5.8 (3)). Планшет биометрию не предлагает (паритет: экраны не меняются).
import 'dart:async';

import 'package:alchemist/alchemist.dart' show precacheImages;
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/router/kiosk_routes.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/kiosk_keypad.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_receivables_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_code_step.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_phone_step.dart';
import 'package:optomstroy/features/kiosk/presentation/emergency_exit_screen.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/presentation/screens/order_details_screen.dart';

import '../features/customer_mode/support/customer_mode_harness.dart';
import '../features/kiosk/checkout/kiosk_checkout_support.dart' as ks;
import '../features/kiosk/kiosk_screens_support.dart';
import '../features/orders/support/orders_harness.dart' as oh;
import '../support/f_fakes.dart';
import '../support/responsive_audit.dart';

late KioskScreensStand _stand;

Future<void> _kframes(WidgetTester tester, {int count = 12}) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _showcase(WidgetTester tester, Size size) async {
  await _kframes(tester);
  await precacheImages(tester);
  await _kframes(tester, count: 4);
}

Future<void> _keypad(WidgetTester tester, String digits) async {
  for (final String d in digits.split('')) {
    await tester.ensureVisible(find.byKey(KioskKeypad.keyFor(d)));
    await tester.pump();
    await tester.tap(find.byKey(KioskKeypad.keyFor(d)));
    await tester.pump();
  }
}

Future<void> _phone(WidgetTester tester, Size size) async {
  await _showcase(tester, size);
  unawaited(_stand.router.push<void>('${KioskPaths.checkout}?step=phone'));
  await _kframes(tester);
  await _keypad(tester, ks.kPhoneA);
  await _kframes(tester, count: 4);
}

Future<void> _code(WidgetTester tester, Size size) async {
  await _phone(tester, size);
  _stand.checkout.repo.otpAnswers.add(ks.otpSent(ks.kChallengeA));
  await tester.ensureVisible(find.byKey(KioskPhoneStep.getCodeKey));
  await tester.pump();
  await tester.tap(find.byKey(KioskPhoneStep.getCodeKey));
  await _kframes(tester);
}

Future<void> _done(WidgetTester tester, Size size) async {
  await _code(tester, size);
  await _keypad(tester, ks.kCode);
  _stand.checkout.repo.answerOrder(ks.orderAccepted());
  await tester.ensureVisible(find.byKey(KioskCodeStep.sendKey));
  await tester.pump();
  await tester.tap(find.byKey(KioskCodeStep.sendKey));
  await _kframes(tester, count: 16);
}

Widget _kiosk(Size size, double scale, {bool drawer = false, KioskStatus status = KioskStatus.ready}) {
  _stand = KioskScreensStand(drawer: drawer, status: status);
  return _stand.app(size, textScale: scale);
}

Widget _emergency(Size size) => ProviderScope(
  child: MaterialApp(
    theme: AppTheme.light(),
    locale: const Locale('ru'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    debugShowCheckedModeBanner: false,
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero),
      child: child!,
    ),
    home: const Scaffold(body: KioskEmergencyExitDialog()),
  ),
);

Widget _customerOrder(Size size) => oh.OrdersHarness(
  role: RoleCode.customer,
  userId: 'cust-user',
  orders: FakeOrdersRepository()
    ..onGet = (String id, bool refresh) async => Success<OrderDetails>(
      oh.details(
        oh.order(
          status: OrderStatus.awaitingPayment,
          method: PaymentMethod.qrBakai,
          paidTyiyn: 800000,
          payments: <Payment>[
            oh.payment(tyiyn: 800000),
            const Payment(
              id: 'pay-r',
              orderId: 'o1',
              method: PaymentMethod.qrBakai,
              status: PaymentStatus.manualConfirm,
              amount: Money(800750),
              reviewReason: ReviewReason.latePayment,
            ),
          ],
        ),
        <OrderAction>{OrderAction.cancel, OrderAction.printInvoice},
      ),
    ),
).app(const OrderDetailsScreen(orderId: 'o1'), size: size);

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, (RespBuild, RespSettle)> scenes = <String, (RespBuild, RespSettle)>{
    'scr51_showcase': (_kiosk, _showcase),
    'scr51_drawer': ((Size s, double t) => _kiosk(s, t, drawer: true), _showcase),
    'scr51_update_needed': ((Size s, double t) => _kiosk(s, t, status: KioskStatus.updateNeeded), _showcase),
    'scr51_unavailable': ((Size s, double t) => _kiosk(s, t, status: KioskStatus.unavailable), _showcase),
    'scr52_phone': (_kiosk, _phone),
    'scr52_code': (_kiosk, _code),
    'scr53_done': (_kiosk, _done),
    'ui51_017_emergency': ((Size s, double _) => _emergency(s), respFrames),
    'customer_scr24_order': ((Size s, double _) => _customerOrder(s), respFrames),
    'customer_scr34_debt': (
      (Size s, double _) =>
          CustomerModeHarness(link: kConfirmed).app(const CustomerReceivablesScreen(customerId: kOwnId), size: s),
      respFrames,
    ),
    'customer_scr34_proposed': (
      (Size s, double _) => CustomerModeHarness(
        link: const CustomerSelfLink(status: CustomerLinkStatus.proposed),
      ).app(const CustomerReceivablesScreen(customerId: kOwnId), size: s),
      respFrames,
    ),
  };

  for (final MapEntry<String, (RespBuild, RespSettle)> scene in scenes.entries) {
    testWidgets('T-UI-117 ${scene.key}: окна 360…2560 × текст 1 / 1,3', (WidgetTester tester) async {
      final RespAudit audit = RespAudit(scene.key);
      await audit.run(tester, scene.value.$1, settle: scene.value.$2);
      audit.expectNoBlocking();
    });
  }
}
