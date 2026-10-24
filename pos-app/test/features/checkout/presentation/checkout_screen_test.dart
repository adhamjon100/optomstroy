// Widget-тесты SCR-21 «Оформление заказа» (RM-F-006 п. 2–5, RM-F-013 п. 3–4, RM-F-015 п. 3; 02 AC-UI-21-001…027):
// шаги и валидация, повторное нажатие «Создать», офлайн, недоступность 1С, режим клиента, восстановление после
// перезапуска, похожий заказ, конфликты цен.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/checkout/presentation/checkout_formats.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/checkout_controller.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/order_submission_recovery.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/checkout/presentation/screens/checkout_screen.dart';
import 'package:optomstroy/features/checkout/presentation/widgets/order_submission_overlay.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

import '../../cart/support/cart_test_support.dart';
import '../checkout_test_support.dart';

const Size expanded = Size(1280, 900);
const Size compact = Size(390, 844);

/// Последние на устройстве: наличные, самовывоз.
const CheckoutPrefs cashPickup = CheckoutPrefs(
  paymentMethod: PaymentMethod.cash,
  deliveryMethod: DeliveryMethod.pickup,
);

/// Сумма так, как её показывает экран (разделитель разрядов — узкий неразрывный пробел).
String m(int tyiyn) => CheckoutFormats.money(Money(tyiyn));

List<CreateCall> createCalls(CheckoutHarness h) => <CreateCall>[
  for (final ({String method, List<Object?> args}) c in h.fakes.checkout.calls)
    if (c.method == 'createOrder') (request: c.args[0]! as OrderCreateRequest, key: c.args[1]! as String),
];

/// Вызов `createOrder`.
typedef CreateCall = ({OrderCreateRequest request, String key});

Future<void> choosePayment(WidgetTester tester, PaymentMethod m) async {
  await tapKey(tester, ValueKey<String>('payment-method-${m.value}'));
  await tester.pump(const Duration(milliseconds: 600));
  await settle(tester);
}

bool enabled(WidgetTester tester, Key key) => tester.widget<AppButton>(find.byKey(key)).onPressed != null;

bool ctaEnabled(WidgetTester tester) => enabled(tester, CheckoutScreen.ctaKey);

Success<OrderCreateResult> created({bool accepted = false, List<Payment> payments = const <Payment>[]}) =>
    Success<OrderCreateResult>(
      OrderCreateResult(
        order: createdOrder(payments: payments, method: payments.isEmpty ? PaymentMethod.cash : PaymentMethod.qrBakai),
        accepted: accepted,
      ),
    );

void main() {
  group('SCR-21 expanded: структура и итоги', () {
    testWidgets('степпер «Клиент · Получение · Оплата · Завершение», 4 секции, итоги из checkout-preview', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness()..stubDefaults();
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);

      expect(find.text('Подтверждение заказа'), findsOneWidget);
      for (final String s in <String>['Клиент', 'Получение', 'Оплата', 'Завершение']) {
        expect(find.text(s), findsWidgets);
      }
      expect(find.byKey(const ValueKey<String>('checkout-section-customer')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('checkout-section-delivery')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('checkout-section-payment')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('checkout-section-items')), findsOneWidget);
      // AC-UI-21-002: суммы — из ответа предпроверки.
      expect(find.text(m(1685000)), findsOneWidget);
      expect(find.text('−${m(84250)}'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('checkout-total')), findsOneWidget);
      expect(find.text(m(1600750)), findsWidgets);
      // AC-UI-21-021: ровно три способа оплаты и три документа печати.
      expect(find.byKey(const ValueKey<String>('payment-method-cash')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('payment-method-qr_bakai')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('payment-method-credit')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('checkout-print-invoice')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('checkout-print-waybill')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('checkout-print-receipt')), findsOneWidget);
      expect(find.text('Заказ будет создан в 1С и отправлен на согласование'), findsOneWidget);
    });

    testWidgets('RM-F-006 п. 2: CTA недоступна без способа оплаты, доступна после выбора', (WidgetTester tester) async {
      final CheckoutHarness h = CheckoutHarness()..stubDefaults();
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      expect(ctaEnabled(tester), isFalse);
      await choosePayment(tester, PaymentMethod.cash);
      expect(ctaEnabled(tester), isTrue);
      expect(find.text('Создать заказ'), findsOneWidget);
      await choosePayment(tester, PaymentMethod.qrBakai);
      expect(find.text('Создать заказ и показать QR'), findsOneWidget);
      // Подсказка кассиру при `cash` и QR через 1С (автоподтверждение).
      expect(
        find.text(
          'После создания заказа будет сформирован QR-код для оплаты через Бакай Банк. '
          'После оплаты заказ будет автоматически отмечен как оплаченный',
        ),
        findsOneWidget,
      );
    });

    testWidgets('клиент корзины: карточка с историей и скидкой, CTA доступна', (WidgetTester tester) async {
      final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
      h.fakes.cart.onFetch = () async => Success<Cart>(mockupCart(customer: mockupCustomer()));
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      expect(ctaEnabled(tester), isTrue);
      expect(find.byKey(const ValueKey<String>('checkout-customer-card')), findsOneWidget);
      expect(textContaining('История: 12 заказов'), findsOneWidget);
    });
  });

  group('SCR-21 валидация', () {
    testWidgets('AC-UI-21-004: «Другой человек» без ФИО и телефона — ошибки у полей, POST /orders не уходит', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness(
        prefs: const CheckoutPrefs(paymentMethod: PaymentMethod.cash, deliveryMethod: DeliveryMethod.pickup),
      )..stubDefaults();
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      await tapKey(tester, const ValueKey<String>('checkout-receiver-other'));
      expect(find.byKey(const ValueKey<String>('checkout-receiver-name')), findsOneWidget);
      await tapKey(tester, CheckoutScreen.ctaKey);
      expect(find.text('Введите ФИО получателя'), findsOneWidget);
      expect(find.text('Введите 9 цифр номера'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('checkout-errors-summary')), findsOneWidget);
      expect(createCalls(h), isEmpty);
    });

    testWidgets('AC-UI-21-005, AC-UI-21-006 (02 SCR-21 «Уточнения» п. 2: кнопки нет, запросов нет), RM-F-006 п. 4–5, '
        'RM-F-013 п. 3: доставка требует адрес, телефон, дату и интервал; адрес ≤ 300; комментарий N/200', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      await tapKey(tester, const ValueKey<String>('checkout-delivery-delivery'));
      expect(find.text('Выбрать на карте'), findsNothing);
      await tapKey(tester, CheckoutScreen.ctaKey);
      expect(find.text('Введите адрес доставки'), findsWidgets);
      expect(find.text('Введите 9 цифр номера'), findsOneWidget);
      expect(find.text('Выберите дату и время доставки'), findsOneWidget);
      expect(createCalls(h), isEmpty);

      final Finder address = find.descendant(
        of: find.byKey(const ValueKey<String>('checkout-address')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(address, 'а' * 310);
      await tester.pump();
      expect(tester.widget<EditableText>(address).controller.text.length, 300);
      // Комментарий — счётчик N/200.
      final Finder comment = find.descendant(
        of: find.byKey(const ValueKey<String>('checkout-comment')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(comment, 'Позвонить за час');
      await tester.pump();
      expect(find.text('16/200'), findsOneWidget);
    });

    testWidgets('AC-UI-21-022: телефон для курьера следует за телефоном получателя до ручной правки', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      await tapKey(tester, const ValueKey<String>('checkout-receiver-other'));
      await tapKey(tester, const ValueKey<String>('checkout-delivery-delivery'));
      expect(find.text('Телефон получателя'), findsOneWidget);
      expect(find.text('Телефон для курьера'), findsOneWidget);
      Finder field(String key) =>
          find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(EditableText));
      await tester.enterText(field('checkout-receiver-phone'), '700123456');
      await settle(tester);
      expect(tester.widget<EditableText>(field('checkout-courier-phone')).controller.text, contains('700'));
    });
  });

  group('SCR-21 создание заказа', () {
    testWidgets('RM-F-006 п. 3: двойное нажатие CTA — один POST /orders; ключ — из checkout_draft; без цен '
        '(AC-UI-21-020 — см. checkout_acceptance_test)', (WidgetTester tester) async {
      final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
      final Completer<Result<OrderCreateResult>> pending = Completer<Result<OrderCreateResult>>();
      h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String key, String? stepUp) => pending.future;
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      await tester.tap(find.byKey(CheckoutScreen.ctaKey));
      await tester.pump();
      await tester.tap(find.byKey(CheckoutScreen.ctaKey), warnIfMissed: false);
      await tester.pump();
      expect(find.text('Создаём заказ…'), findsWidgets);
      pending.complete(created());
      await settle(tester);

      final List<CreateCall> calls = createCalls(h);
      expect(calls, hasLength(1));
      expect(calls.single.key, 'order-key-1');
      expect(calls.single.request.cartId, 'cart-1');
      expect(calls.single.request.cartRowVersion, 7);
      expect(calls.single.request.previewToken, 'preview-token');
      expect(calls.single.request.items.map((OrderCreateItem i) => i.variantId), <String>['v-1', 'v-2', 'v-3']);
      expect(h.nav.calls, contains('orderCreated:order-1:-'));
      // Черновик удалён после успеха.
      expect(h.drafts.drafts, isEmpty);
    });

    testWidgets('заказ создан → копия корзины устройства принимает новую активную корзину (GET /cart через CartSync)', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
      final _CountingCartSync sync = _CountingCartSync(h.fakes.cart);
      h.extraOverrides.add(cartSyncProvider.overrideWithValue(sync));
      h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String key, String? stepUp) async => created();
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      expect(sync.refreshes, 0);
      await tester.tap(find.byKey(CheckoutScreen.ctaKey));
      await settle(tester);
      expect(h.nav.calls, contains('orderCreated:order-1:-'));
      expect(sync.refreshes, 1, reason: 'иначе следующий cart.sync уйдёт с rowVersion оформленной корзины (409)');
    });

    testWidgets('F-flutter-ui-1: результат POST /orders неизвестен → окно закрывается, корзина заблокирована; повтор '
        '— сохранённое тело и тот же ключ (AC-UI-20-019, AC-UI-21-008); ответ 201 → SCR-22', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
      int n = 0;
      h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String key, String? s) async => ++n == 1
          ? const FailureResult<OrderCreateResult>(NetworkFailure(NetworkFailureKind.timeout, outcomeUnknown: true))
          : created();
      await h.pump(
        tester,
        const OrderSubmissionHost(child: CheckoutScreen(cartId: 'cart-1')),
        size: expanded,
      );
      final ProviderContainer container = ProviderScope.containerOf(tester.element(find.byType(CheckoutScreen)));
      await tapKey(tester, CheckoutScreen.ctaKey);

      // Окно закрывается (SCR-20 с оверлеем UI-20-020), черновик и ключ сохранены, корзина заблокирована.
      expect(h.nav.calls, <String>['backToCart']);
      final CheckoutDraft draft = h.drafts.drafts['cart-1']!;
      expect((draft.orderIdempotencyKey, draft.submittedAt != null), ('order-key-1', true));
      expect(container.read(orderSubmissionRecoveryProvider).locked, isTrue);
      // Пока результат неизвестен, новое оформление не отправляется (тело не собирается заново).
      expect(await container.read(checkoutControllerProvider('cart-1').notifier).submit(), isA<CheckoutStay>());
      expect(createCalls(h), hasLength(1));

      // Фоновый повтор через 2 с: то же тело (объект из памяти) и тот же ключ.
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      final List<CreateCall> calls = createCalls(h);
      expect(calls, hasLength(2));
      expect(identical(calls[1].request, calls[0].request), isTrue);
      expect(calls[1].key, calls[0].key);
      expect(h.nav.calls, contains('orderCreated:order-1:-'));
      expect(h.drafts.drafts, isEmpty);
      expect(container.read(orderSubmissionRecoveryProvider).locked, isFalse);
    });

    testWidgets(
      'F-flutter-ui-1: 422 IDEMPOTENCY_KEY_REUSED → сначала поиск по ключу; найден — SCR-22 без нового ключа',
      (WidgetTester tester) async {
        final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
        h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String key, String? s) async =>
            const FailureResult<OrderCreateResult>(ConflictFailure(ConflictKind.idempotencyKeyReused));
        h.fakes.checkout.onFindSubmittedOrder = (String key) async => Success<OrderSummary?>(
          OrderSummary(
            id: 'order-7',
            publicNumber: 'POS-2026-000127',
            status: OrderStatus.submitting,
            total: Money.som(100),
            paymentMethod: PaymentMethod.cash,
          ),
        );
        await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
        await tapKey(tester, CheckoutScreen.ctaKey);
        expect(h.fakes.checkout.calls.where((c) => c.method == 'findSubmittedOrder').single.args.single, 'order-key-1');
        expect(h.nav.calls, contains('orderCreated:order-7:-'));
        expect(createCalls(h), hasLength(1));
      },
    );

    testWidgets('F-flutter-ui-2: во время повторной предпроверки CTA — loading; POST /orders — с предпроверкой '
        'по текущему способу оплаты', (WidgetTester tester) async {
      final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
      final List<PaymentMethod> previews = <PaymentMethod>[];
      h.fakes.checkout.onPreview = (CheckoutPreviewRequest r) async {
        previews.add(r.paymentMethod);
        return Success<CheckoutPreview>(mockupPreview(method: r.paymentMethod));
      };
      List<PaymentMethod>? previewsAtCreate;
      h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String key, String? s) async {
        previewsAtCreate = List<PaymentMethod>.of(previews);
        return created();
      };
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      expect(ctaEnabled(tester), isTrue);
      await tester.tap(find.byKey(const ValueKey<String>('payment-method-qr_bakai')));
      await tester.pump(const Duration(milliseconds: 50));
      // Предпроверка по QR ещё не пришла: CTA недоступна и в loading.
      expect(ctaEnabled(tester), isFalse);
      expect(tester.widget<AppButton>(find.byKey(CheckoutScreen.ctaKey)).loading, isTrue);
      // Ctrl+Enter в это время: submit дожидается предпроверки по QR, затем POST /orders.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      final List<CreateCall> calls = createCalls(h);
      expect(calls, hasLength(1));
      expect(calls.single.request.paymentMethod, PaymentMethod.qrBakai);
      expect(previewsAtCreate!.last, PaymentMethod.qrBakai, reason: 'POST /orders — после предпроверки по QR');
    });

    testWidgets('F-flutter-data-3: смена клиента в SCR-21 — через CartSync.direct (база rowVersion копии устройства)', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
      final FakeCartSync sync = FakeCartSync(h.fakes.cart)..server = mockupCart(rowVersion: 17);
      h.extraOverrides.add(cartSyncProvider.overrideWithValue(sync));
      final List<int> versions = <int>[];
      h.fakes.cart.onSetCustomer = (String id, int rowVersion, Receiver? r) async {
        versions.add(rowVersion);
        return Success<Cart>(mockupCart(customer: mockupCustomer(), rowVersion: rowVersion + 1));
      };
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      final Finder search = find.descendant(
        of: find.byKey(const ValueKey<String>('customer-picker-field')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(search, 'Аза');
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      await tapKey(tester, const ValueKey<String>('customer-picker-row-cust-1'));
      expect(versions, <int>[17], reason: 'rowVersion — база копии устройства, а не корзины, открытой в SCR-21');
      expect(sync.server?.rowVersion, 18, reason: 'ответ сервера — новая база цепочки cart.sync');
    });

    testWidgets('нет сети: CTA «Нужна сеть» недоступна, «+ Новый клиент» недоступна', (WidgetTester tester) async {
      final CheckoutHarness h = CheckoutHarness(online: false, prefs: cashPickup)..stubDefaults();
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      expect(find.text('Нужна сеть'), findsOneWidget);
      expect(ctaEnabled(tester), isFalse);
      expect(enabled(tester, const ValueKey<String>('customer-picker-new')), isFalse);
    });

    testWidgets(
      'AC-UI-21-009 (наличные): 1С недоступна — баннер UI-21-031, подпись о 1С; 202 → заказ создан (SCR-22)',
      (WidgetTester tester) async {
        final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)
          ..stubDefaults(
            preview: (CheckoutPreviewRequest r) => mockupPreview(
              method: r.paymentMethod,
              onec: OnecCheckResult.unavailable,
              warnings: const <ApiWarning>[ApiWarning(rawCode: 'STALE_DATA')],
            ),
          );
        h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String k, String? s) async => created(accepted: true);
        await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
        expect(find.byKey(const ValueKey<String>('checkout-onec-banner')), findsOneWidget);
        expect(find.text('Заказ будет отправлен в 1С автоматически, как только она станет доступна'), findsOneWidget);
        expect(textContaining('Проверено по данным от 10:00'), findsOneWidget);
        await tapKey(tester, CheckoutScreen.ctaKey);
        expect(h.nav.calls, contains('orderCreated:order-1:-'));
      },
    );

    testWidgets('AC-UI-21-015: 409 possible_duplicate → диалог; «Создать ещё один» — новый ключ и confirmDuplicate', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
      int n = 0;
      h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String k, String? s) async => ++n == 1
          ? const FailureResult<OrderCreateResult>(
              ConflictFailure(
                ConflictKind.orderStateInvalid,
                reason: 'possible_duplicate',
                details: <String, Object?>{'possibleDuplicateOrderId': 'order-0', 'publicNumber': 'POS-2026-000122'},
              ),
            )
          : created();
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      await tapKey(tester, CheckoutScreen.ctaKey);
      expect(find.text('Похожий заказ уже создан'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('checkout-choice-create')));
      await settle(tester);
      final List<CreateCall> calls = createCalls(h);
      expect(calls, hasLength(2));
      expect(calls[1].request.confirmDuplicate, isTrue);
      expect(calls[0].request.confirmDuplicate, isFalse);
      expect(calls[1].key, isNot(calls[0].key));
      expect(h.nav.calls, contains('orderCreated:order-1:-'));
    });

    testWidgets('AC-UI-21-010: 422 PRICE_CHANGED → возврат в корзину, ключ очищен', (WidgetTester tester) async {
      final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)..stubDefaults();
      h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String k, String? s) async =>
          const FailureResult<OrderCreateResult>(ConflictFailure(ConflictKind.priceChanged));
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      await tapKey(tester, CheckoutScreen.ctaKey);
      expect(h.nav.calls, contains('backToCart'));
      expect(h.drafts.drafts['cart-1']?.orderIdempotencyKey, isNull);
    });

    testWidgets('конфликты предпроверки: баннер, «Вернуться в корзину», CTA недоступна', (WidgetTester tester) async {
      final CheckoutHarness h = CheckoutHarness(prefs: cashPickup)
        ..stubDefaults(
          preview: (CheckoutPreviewRequest r) => mockupPreview(
            ok: false,
            method: r.paymentMethod,
            conflicts: <CartConflict>[
              CartConflict(
                variantId: 'v-1',
                rawKind: 'price_changed',
                oldPrice: Money.som(2350),
                newPrice: Money.som(2400),
              ),
            ],
          ),
        );
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      expect(find.byKey(const ValueKey<String>('checkout-conflicts')), findsOneWidget);
      expect(textContaining('Цена изменилась: Смеситель для ванны Frap F3241'), findsOneWidget);
      expect(ctaEnabled(tester), isFalse);
      await tapKey(tester, const ValueKey<String>('checkout-back-to-cart'));
      expect(h.nav.calls, contains('backToCart'));
    });

    testWidgets('RM-F-013 п. 4: после перезапуска с отправленным POST — заказ найден по ключу, второго нет', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness()..stubDefaults();
      h.drafts.drafts['cart-1'] = CheckoutDraft(
        localCartId: 'cart-1',
        step: CheckoutStep.review,
        updatedAt: testNow,
        orderIdempotencyKey: 'order-key-old',
        submittedAt: testNow,
      );
      h.fakes.checkout.onFindSubmittedOrder = (String key) async => Success<OrderSummary?>(
        OrderSummary(
          id: 'order-9',
          publicNumber: 'POS-2026-000129',
          status: OrderStatus.submitting,
          total: Money.som(100),
          paymentMethod: PaymentMethod.cash,
        ),
      );
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      expect(h.fakes.checkout.calls.where((c) => c.method == 'findSubmittedOrder').single.args.single, 'order-key-old');
      expect(createCalls(h), isEmpty);
      expect(h.nav.calls, contains('orderCreated:order-9:-'));
    });

    testWidgets(
      'F-flutter-data-2: ключ checkout_draft — cart_draft.local_id: после конвертации корзины (новый Cart.id) '
      'заказ найден по idempotencyKey, второго POST нет',
      (WidgetTester tester) async {
        final CheckoutHarness h = CheckoutHarness()..stubDefaults(cart: mockupCart(id: 'cart-2'));
        final FakeCartSync sync = FakeCartSync(h.fakes.cart)
          ..snapshot = const CartLocalSnapshot(localCartId: 'local-1', lines: <CartLocalLine>[], dirty: false);
        h.extraOverrides.add(cartSyncProvider.overrideWithValue(sync));
        h.drafts.drafts['local-1'] = CheckoutDraft(
          localCartId: 'local-1',
          step: CheckoutStep.review,
          updatedAt: testNow,
          orderIdempotencyKey: 'order-key-old',
          submittedAt: testNow,
        );
        h.fakes.checkout.onFindSubmittedOrder = (String key) async => Success<OrderSummary?>(
          OrderSummary(
            id: 'order-9',
            publicNumber: 'POS-2026-000129',
            status: OrderStatus.submitting,
            total: Money.som(100),
            paymentMethod: PaymentMethod.cash,
          ),
        );
        await h.pump(tester, const CheckoutScreen(cartId: 'cart-2'), size: expanded);
        expect(
          h.fakes.checkout.calls.where((c) => c.method == 'findSubmittedOrder').single.args.single,
          'order-key-old',
        );
        expect(createCalls(h), isEmpty);
        expect(h.nav.calls, contains('orderCreated:order-9:-'));
        expect(h.drafts.drafts, isEmpty);
      },
    );

    testWidgets('AC-UI-21-017: восстановление шага и выборов; ПДн получателя не восстанавливаются (подсказка)', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness()..stubDefaults();
      h.drafts.drafts['cart-1'] = CheckoutDraft(
        localCartId: 'cart-1',
        step: CheckoutStep.payment,
        updatedAt: testNow,
        deliveryMethod: DeliveryMethod.delivery,
        receiverKind: ReceiverKind.otherPerson,
        paymentMethod: PaymentMethod.qrBakai,
      );
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: compact);
      expect(find.text('Шаг 3 из 4 · Оплата'), findsOneWidget);
      expect(find.text('Создать заказ и показать QR'), findsNothing);
      await tapKey(tester, const ValueKey<String>('checkout-back'));
      await tapKey(tester, const ValueKey<String>('checkout-back'));
      expect(find.text('Шаг 1 из 4 · Клиент'), findsOneWidget);
      expect(find.text('Адрес и телефоны получателя не сохраняются на устройстве — введите их заново'), findsOneWidget);
      final EditableText name = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('checkout-receiver-name')),
          matching: find.byType(EditableText),
        ),
      );
      expect(name.controller.text, isEmpty);
    });
  });

  group('SCR-21 долг', () {
    testWidgets('AC-UI-21-012: продавцу при просрочке — «обратитесь к старшему продавцу» без сумм и без PIN', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness(role: RoleCode.seller)
        ..stubDefaults(
          cart: mockupCart(customer: mockupCustomer(withReceivable: false)),
          preview: (CheckoutPreviewRequest r) => mockupPreview(
            method: r.paymentMethod,
            checks: r.paymentMethod == PaymentMethod.credit
                ? const PaymentChecks(creditAllowed: false, creditReason: CreditReason.overdue)
                : null,
          ),
        );
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      await choosePayment(tester, PaymentMethod.credit);
      expect(find.text('Продажа в долг недоступна: обратитесь к старшему продавцу'), findsWidgets);
      expect(find.byKey(const ValueKey<String>('checkout-credit-help')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('checkout-credit-approve')), findsNothing);
      expect(ctaEnabled(tester), isFalse);
    });

    testWidgets('AC-UI-21-026: «Розничный покупатель» — 422 CUSTOMER_NOT_IDENTIFIED «Выберите клиента из 1С»', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness()..stubDefaults();
      h.fakes.checkout.onPreview = (CheckoutPreviewRequest r) async => r.paymentMethod == PaymentMethod.credit
          ? const FailureResult<CheckoutPreview>(ServerFailure(code: 'CUSTOMER_NOT_IDENTIFIED', status: 422))
          : Success<CheckoutPreview>(mockupPreview(method: r.paymentMethod));
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
      await choosePayment(tester, PaymentMethod.credit);
      expect(find.text('Выберите клиента из 1С'), findsWidgets);
      expect(find.byKey(const ValueKey<String>('checkout-credit-help')), findsNothing);
    });
  });

  group('RM-F-015 режим клиента', () {
    testWidgets(
      'AC-UI-21-027: нет шага «Клиент», выбора клиента, долга, печати; способы cash и QR; CTA «Отправить заявку»',
      (WidgetTester tester) async {
        final CheckoutHarness h = CheckoutHarness(role: RoleCode.customer)
          ..stubDefaults(
            preview: (CheckoutPreviewRequest r) => mockupPreview(
              method: r.paymentMethod,
              allowed: const <PaymentMethod>[PaymentMethod.cash, PaymentMethod.qrBakai],
            ),
          );
        await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: expanded);
        expect(find.byKey(const ValueKey<String>('checkout-section-customer')), findsNothing);
        expect(find.byKey(const ValueKey<String>('customer-picker-field')), findsNothing);
        expect(find.text('+ Новый клиент'), findsNothing);
        expect(find.byKey(const ValueKey<String>('payment-method-credit')), findsNothing);
        expect(find.byKey(const ValueKey<String>('checkout-section-print')), findsNothing);
        expect(find.text('Оплата при получении'), findsOneWidget);
        expect(find.text('Оплатить по QR'), findsOneWidget);
        expect(find.text('Клиент'), findsNothing);
        expect(
          find.text('Заявка уйдёт в магазин на согласование. Цены и наличие магазин подтвердит при согласовании'),
          findsOneWidget,
        );
        await tapKey(tester, const ValueKey<String>('checkout-delivery-pickup'));
        await choosePayment(tester, PaymentMethod.cash);
        expect(find.text('Отправить заявку'), findsOneWidget);
        h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String k, String? s) async => created();
        await tapKey(tester, CheckoutScreen.ctaKey);
        final OrderCreateRequest req = createCalls(h).single.request;
        expect(req.customerId, isNull);
        expect(req.receiver.kind, ReceiverKind.customer);
        expect(req.printOptions, isNull);
        expect(req.paymentMethod, PaymentMethod.cash);
      },
    );

    testWidgets(
      'AC-UI-21-027: QR_PROVIDER=none — плитки QR нет, «Оплата по QR сейчас недоступна»; compact — «Шаг 1 из 3»',
      (WidgetTester tester) async {
        final CheckoutHarness h = CheckoutHarness(role: RoleCode.customer, qr: const CheckoutQrMode())..stubDefaults();
        await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: compact);
        expect(find.text('Шаг 1 из 3 · Получение'), findsOneWidget);
        await tapKey(tester, const ValueKey<String>('checkout-delivery-pickup'));
        await tapKey(tester, CheckoutScreen.nextKey);
        expect(find.text('Шаг 2 из 3 · Оплата'), findsOneWidget);
        expect(find.byKey(const ValueKey<String>('payment-method-qr_bakai')), findsNothing);
        expect(find.byKey(const ValueKey<String>('payment-method-credit')), findsNothing);
        expect(find.byKey(const ValueKey<String>('checkout-customer-qr-unavailable')), findsOneWidget);
      },
    );
  });

  group('SCR-21 compact', () {
    testWidgets('4 шага: «Далее» валидирует шаг; «Назад» на первом шаге — диалог «Прервать оформление?»', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness()..stubDefaults();
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: compact);
      expect(find.text('Шаг 1 из 4 · Клиент'), findsOneWidget);
      await tapKey(tester, CheckoutScreen.nextKey);
      expect(find.text('Шаг 2 из 4 · Получение'), findsOneWidget);
      await tapKey(tester, CheckoutScreen.nextKey);
      expect(find.text('Шаг 2 из 4 · Получение'), findsOneWidget);
      expect(find.text('Выберите способ получения'), findsOneWidget);
      await tapKey(tester, const ValueKey<String>('checkout-delivery-pickup'));
      await tapKey(tester, CheckoutScreen.nextKey);
      expect(find.text('Шаг 3 из 4 · Оплата'), findsOneWidget);
      await choosePayment(tester, PaymentMethod.cash);
      await tapKey(tester, CheckoutScreen.nextKey);
      expect(find.text('Шаг 4 из 4 · Завершение'), findsOneWidget);
      expect(find.byKey(CheckoutScreen.ctaKey), findsOneWidget);
      // Назад до первого шага, затем диалог (введённых данных нет — сразу в корзину).
      for (int i = 0; i < 3; i++) {
        await tapKey(tester, const ValueKey<String>('checkout-back'));
      }
      expect(find.text('Шаг 1 из 4 · Клиент'), findsOneWidget);
      await tapKey(tester, const ValueKey<String>('checkout-receiver-other'));
      final Finder name = find.descendant(
        of: find.byKey(const ValueKey<String>('checkout-receiver-name')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(name, 'Нурлан');
      await tester.pump();
      await tapKey(tester, const ValueKey<String>('checkout-back'));
      expect(find.text('Прервать оформление?'), findsOneWidget);
    });

    testWidgets('выбор клиента из поиска → POST /cart/customer; «+ Новый клиент» → SCR-26 и выбор созданного', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness()..stubDefaults();
      h.fakes.cart.onSetCustomer = (String id, int rv, Receiver? r) async => Success<Cart>(
        mockupCart(
          customer: id == 'cust-1' ? mockupCustomer() : Customer(id: id, name: 'Новый'),
        ),
      );
      h.nav.newCustomerResult = 'cust-new';
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: compact);
      final Finder search = find.descendant(
        of: find.byKey(const ValueKey<String>('customer-picker-field')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(search, 'Аза');
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(h.fakes.customers.calls.where((c) => c.method == 'search'), hasLength(1));
      await tapKey(tester, const ValueKey<String>('customer-picker-row-cust-1'));
      expect(h.fakes.cart.calls.where((c) => c.method == 'setCustomer').single.args.first, 'cust-1');
      expect(find.byKey(const ValueKey<String>('checkout-customer-card')), findsOneWidget);
    });

    testWidgets('AC-UI-21-003: «+ Новый клиент» → SCR-26; созданный клиент выбран автоматически', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness()..stubDefaults();
      h.fakes.cart.onSetCustomer = (String id, int rv, Receiver? r) async => Success<Cart>(
        mockupCart(
          customer: Customer(id: id, name: 'Нурлан Асанов'),
        ),
      );
      h.nav.newCustomerResult = 'cust-new';
      await h.pump(tester, const CheckoutScreen(cartId: 'cart-1'), size: compact);
      await tapKey(tester, const ValueKey<String>('customer-picker-new'));
      expect(h.nav.calls, contains('newCustomer'));
      expect(h.fakes.cart.calls.where((c) => c.method == 'setCustomer').single.args.first, 'cust-new');
      expect(find.text('Нурлан Асанов'), findsOneWidget);
    });
  });
}

/// `CartSync` теста: считает `refresh()`.
class _CountingCartSync extends FakeCartSync {
  _CountingCartSync(super.repo);

  int refreshes = 0;

  @override
  Future<Result<Cart>> refresh() {
    refreshes++;
    return super.refresh();
  }
}
