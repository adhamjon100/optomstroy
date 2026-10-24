// T-UI-021 (12 §3.9) — недостающие кейсы приёмочного набора SCR-21 «Оформление заказа» (02 SCR-21.13): AC-UI-21-007,
// 009 (долг), 011, 013, 014, 016, 018, 019, 020, 023, 025. Остальные AC — checkout_screen_test.dart. Фейки —
// checkout_test_support.dart; данные синтетические, без реальной 1С.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/checkout/data/dto/checkout_dtos.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/checkout/presentation/screens/checkout_screen.dart';
import 'package:optomstroy/features/checkout/presentation/screens/order_created_screen.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';

import '../checkout_test_support.dart';

const Size expanded = Size(1280, 900);

const CheckoutPrefs cashPickup = CheckoutPrefs(
  paymentMethod: PaymentMethod.cash,
  deliveryMethod: DeliveryMethod.pickup,
);

Future<void> choosePayment(WidgetTester tester, PaymentMethod m) async {
  await tapKey(tester, ValueKey<String>('payment-method-${m.value}'));
  await tester.pump(const Duration(milliseconds: 600));
  await settle(tester);
}

List<OrderCreateRequest> createRequests(CheckoutHarness h) => <OrderCreateRequest>[
  for (final ({String method, List<Object?> args}) c in h.fakes.checkout.calls)
    if (c.method == 'createOrder') c.args[0]! as OrderCreateRequest,
];

Success<OrderCreateResult> created({PaymentMethod method = PaymentMethod.cash}) =>
    Success<OrderCreateResult>(OrderCreateResult(order: createdOrder(method: method), accepted: false));

/// Ключи JSON на любой глубине.
Set<String> keysDeep(Object? v) => switch (v) {
  final Map<dynamic, dynamic> m => <String>{
    for (final MapEntry<dynamic, dynamic> e in m.entries) ...<String>{e.key.toString(), ...keysDeep(e.value)},
  },
  final List<dynamic> l => <String>{for (final Object? x in l) ...keysDeep(x)},
  _ => const <String>{},
};

/// Предпроверка с долгом: [checks] — для `credit`.
CheckoutHarness creditHarness(RoleCode role, PaymentChecks Function(CheckoutPreviewRequest r) checks) =>
    CheckoutHarness(role: role, prefs: cashPickup)..stubDefaults(
      preview: (CheckoutPreviewRequest r) =>
          mockupPreview(method: r.paymentMethod, checks: r.paymentMethod == PaymentMethod.credit ? checks(r) : null),
    );

void main() {
  testWidgets('AC-UI-21-007: QR_WEBHOOK_ENABLED=false — нет обещания автоматической отметки; «Оплату подтвердит '
      'кассир по выписке банка»', (WidgetTester tester) async {
    final CheckoutHarness h = CheckoutHarness(
      qr: const CheckoutQrMode(provider: QrProviderMode.bakai, autoConfirm: false),
    )..stubDefaults();
    await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
    await choosePayment(tester, PaymentMethod.qrBakai);
    expect(textContaining('Оплату подтвердит кассир по выписке банка'), findsOneWidget);
    expect(textContaining('автоматически отмечен'), findsNothing);
  });

  testWidgets('AC-UI-21-009 (долг): устаревший снимок — 422 RECEIVABLES_STALE «Данные о долге устарели, 1С '
      'недоступна…», заказ в долг не создаётся', (WidgetTester tester) async {
    final CheckoutHarness h = CheckoutHarness(role: RoleCode.cashier)..stubDefaults();
    h.fakes.checkout.onPreview = (CheckoutPreviewRequest r) async => r.paymentMethod == PaymentMethod.credit
        ? const FailureResult<CheckoutPreview>(ServerFailure(code: 'RECEIVABLES_STALE', status: 422))
        : Success<CheckoutPreview>(mockupPreview(method: r.paymentMethod));
    await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
    await choosePayment(tester, PaymentMethod.credit);
    expect(
      find.text('Данные о долге устарели, 1С недоступна: продажа в долг невозможна, выберите наличные или QR'),
      findsWidgets,
    );
    expect(tester.widget<AppButton>(find.byKey(CheckoutScreen.ctaKey)).onPressed, isNull);
    expect(createRequests(h), isEmpty);
  });

  testWidgets('AC-UI-21-011: 422 STOCK_INSUFFICIENT при создании — возврат в корзину (строка «Доступно N» / «Уменьшить '
      'до N» — AC-UI-20-010)', (WidgetTester tester) async {
    final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
    h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String k, String? s) async =>
        const FailureResult<OrderCreateResult>(ConflictFailure(ConflictKind.stockInsufficient));
    await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
    await tapKey(tester, CheckoutScreen.ctaKey);
    expect(h.nav.calls, contains('backToCart'));
    expect(h.drafts.drafts['cart-1']?.orderIdempotencyKey, isNull, reason: 'ключ очищен — новая попытка');
  });

  testWidgets('AC-UI-21-013: senior_seller в своей сессии — причина и step-up, плитка долга доступна, «Разрешено: '
      '{имя}»; POST /orders с creditOverride и токеном', (WidgetTester tester) async {
    final CheckoutHarness h = creditHarness(
      RoleCode.seniorSeller,
      (CheckoutPreviewRequest r) => r.creditOverrideReason == null
          ? const PaymentChecks(creditAllowed: false, creditReason: CreditReason.overdue)
          : const PaymentChecks(creditAllowed: true),
    );
    h.extraOverrides.add(checkoutViewerNameProvider.overrideWithValue('Айгуль Старшая'));
    h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String k, String? s) async =>
        created(method: PaymentMethod.credit);
    await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
    await choosePayment(tester, PaymentMethod.credit);
    await tapKey(tester, const ValueKey<String>('checkout-credit-approve'));
    await tester.enterText(
      find.descendant(of: find.byType(ConfirmDialog), matching: find.byType(EditableText)),
      'Постоянный клиент',
    );
    await tester.pump();
    await tester.tap(
      find.descendant(of: find.byType(ConfirmDialog), matching: find.text('Разрешить продажу в долг')).last,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await settle(tester);
    expect(h.stepUps, <String>['credit.sale.approve']);
    expect(find.byKey(const ValueKey<String>('checkout-credit-allowed-by')), findsOneWidget);
    expect(find.text('Разрешено: Айгуль Старшая'), findsOneWidget);
    await tapKey(tester, CheckoutScreen.ctaKey);
    final OrderCreateRequest req = createRequests(h).single;
    expect((req.paymentMethod, req.creditOverrideReason), (PaymentMethod.credit, 'Постоянный клиент'));
    final ({String method, List<Object?> args}) call = h.fakes.checkout.calls.lastWhere(
      (c) => c.method == 'createOrder',
    );
    expect(call.args[2], 'step-up-token', reason: 'аудит credit.sale_approved пишет сервер по токену step-up');
  });

  testWidgets(
    'AC-UI-21-014: снимок долга старше 60 мин и 1С недоступна — «Разрешить продажу в долг» нет (fail-closed)',
    (WidgetTester tester) async {
      final CheckoutHarness h = creditHarness(
        RoleCode.seniorSeller,
        (_) =>
            const PaymentChecks(creditAllowed: false, creditReason: CreditReason.staleSnapshot, receivablesStale: true),
      );
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      await choosePayment(tester, PaymentMethod.credit);
      expect(find.byKey(const ValueKey<String>('checkout-credit-approve')), findsNothing);
      expect(tester.widget<AppButton>(find.byKey(CheckoutScreen.ctaKey)).onPressed, isNull);
    },
  );

  testWidgets('AC-UI-21-016: чекбоксы печати сохраняются между заказами на устройстве; создание не ждёт печати', (
    WidgetTester tester,
  ) async {
    final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
    h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String k, String? s) async => created();
    await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
    await tapKey(tester, const ValueKey<String>('checkout-print-invoice'));
    await tapKey(tester, const ValueKey<String>('checkout-print-receipt'));
    await tapKey(tester, CheckoutScreen.ctaKey);
    expect(h.nav.calls, contains('orderCreated:order-1:-'), reason: 'переход сразу, печать — в SCR-22');
    expect(h.printed, isEmpty);
    expect((h.prefsStore.read().printInvoice, h.prefsStore.read().printReceipt), (false, true));

    // Следующее оформление на этом устройстве.
    await tester.pumpWidget(const SizedBox());
    await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
    expect(tester.widget<AppCheckbox>(find.byKey(const ValueKey<String>('checkout-print-invoice'))).value, isFalse);
    expect(tester.widget<AppCheckbox>(find.byKey(const ValueKey<String>('checkout-print-receipt'))).value, isTrue);
  });

  testWidgets('AC-UI-21-018: admin — плитка долга недоступна «Нет права продажи в долг»; при qr_bakai CTA «Создать '
      'заказ» (QR в SCR-22 не показывается — AC-UI-22-008)', (WidgetTester tester) async {
    final CheckoutHarness h = CheckoutHarness(role: RoleCode.admin)
      ..stubDefaults(
        preview: (CheckoutPreviewRequest r) => mockupPreview(
          method: r.paymentMethod,
          allowed: const <PaymentMethod>[PaymentMethod.cash, PaymentMethod.qrBakai],
        ),
      );
    await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
    expect(find.text('Нет права продажи в долг'), findsWidgets);
    expect(find.byKey(const ValueKey<String>('checkout-credit-approve')), findsNothing);
    await choosePayment(tester, PaymentMethod.qrBakai);
    expect(tester.widget<AppButton>(find.byKey(CheckoutScreen.ctaKey)).label, 'Создать заказ');
  });

  testWidgets('AC-UI-21-019: Windows без мыши — Ctrl+Enter создаёт заказ', (WidgetTester tester) async {
    final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
    h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String k, String? s) async => created();
    await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(createRequests(h), hasLength(1));
    expect(h.nav.calls, contains('orderCreated:order-1:-'));
  });

  testWidgets('AC-UI-21-020: тело POST /orders без price, unitPrice, total, subtotal, amount, clientTotalSnapshot', (
    WidgetTester tester,
  ) async {
    final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
    h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String k, String? s) async => created();
    await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
    await tapKey(tester, CheckoutScreen.ctaKey);
    final Set<String> keys = keysDeep(CheckoutRequestDto.create(createRequests(h).single));
    expect(keys, isNotEmpty);
    expect(
      keys.intersection(<String>{'price', 'unitPrice', 'total', 'subtotal', 'amount', 'clientTotalSnapshot'}),
      isEmpty,
    );
  });

  testWidgets('AC-UI-21-023: cashier — подсказка «После создания заказа нажмите «Принять оплату»», затем SCR-22 (не '
      'SCR-38) с фокусом на «Принять оплату»', (WidgetTester tester) async {
    final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
    h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String k, String? s) async => created();
    await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
    expect(textContaining('После создания заказа нажмите «Принять оплату»'), findsOneWidget);
    await tapKey(tester, CheckoutScreen.ctaKey);
    expect(h.nav.calls.where((String c) => c.startsWith('orderCreated:')), hasLength(1));
    expect(h.nav.calls.where((String c) => c.startsWith('acceptPayment')), isEmpty, reason: 'не SCR-38');

    final CheckoutHarness h22 = CheckoutHarness();
    h22.fakes.orders.onGet = (String id, bool refresh) async =>
        Success<OrderDetails>(OrderDetails(order: createdOrder(status: OrderStatus.awaitingPayment)));
    await tester.pumpWidget(const SizedBox());
    await h22.pump(tester, const OrderCreatedScreen(orderId: 'order-1'));
    final Finder accept = find.byKey(const ValueKey<String>('order-created-accept'));
    expect(accept, findsOneWidget);
    expect(tester.widget<AppButton>(accept).autofocus, isTrue);
  });

  testWidgets('AC-UI-21-025: admin не видит «Разрешить продажу в долг» (запрос с creditOverride не формируется); '
      'seller/cashier — «Как получить разрешение старшего»', (WidgetTester tester) async {
    for (final RoleCode role in <RoleCode>[RoleCode.admin, RoleCode.seller, RoleCode.cashier]) {
      final CheckoutHarness h = creditHarness(
        role,
        (_) => const PaymentChecks(creditAllowed: false, creditReason: CreditReason.limitExceeded),
      );
      await tester.pumpWidget(const SizedBox());
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      await choosePayment(tester, PaymentMethod.credit);
      expect(find.byKey(const ValueKey<String>('checkout-credit-approve')), findsNothing, reason: '$role');
      expect(
        find.byKey(const ValueKey<String>('checkout-credit-help')),
        role == RoleCode.admin ? findsNothing : findsOneWidget,
        reason: '$role',
      );
      expect(createRequests(h).where((OrderCreateRequest r) => r.creditOverrideReason != null), isEmpty);
    }
  });

  testWidgets('AC-UI-26-005: созданный в SCR-26 клиент выбран в SCR-21; долг недоступен «Выберите клиента из 1С» до '
      'подтверждения 1С', (WidgetTester tester) async {
    final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
    h.fakes.cart.onSetCustomer = (String id, int rv, Receiver? r) async => Success<Cart>(
      mockupCart(
        customer: Customer(id: id, name: 'Нурлан Асанов'),
      ),
    );
    h.fakes.checkout.onPreview = (CheckoutPreviewRequest r) async => r.paymentMethod == PaymentMethod.credit
        ? const FailureResult<CheckoutPreview>(ServerFailure(code: 'CUSTOMER_NOT_IDENTIFIED', status: 422))
        : Success<CheckoutPreview>(mockupPreview(method: r.paymentMethod));
    h.nav.newCustomerResult = 'cust-new';
    await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
    await tapKey(tester, const ValueKey<String>('customer-picker-new'));
    expect(h.fakes.cart.calls.where((c) => c.method == 'setCustomer').single.args.first, 'cust-new');
    expect(find.text('Нурлан Асанов'), findsWidgets);
    await choosePayment(tester, PaymentMethod.credit);
    expect(find.text('Выберите клиента из 1С'), findsWidgets);
    expect(tester.widget<AppButton>(find.byKey(CheckoutScreen.ctaKey)).onPressed, isNull);
  });
}
