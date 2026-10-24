// Поддержка тестов экранов оформления SCR-21/SCR-22 (агент F-fe-checkout): фикстуры корзины макета IMG_7090
// (16 850,00 − 842,50 = 16 007,50 сом), предпроверки, заказа и платежа; навигатор-шпион; обёртка экрана с фейками
// портов F (test/support/f_fakes.dart) и портов presentation (роль, сеть, QR, слоты, step-up, часы).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/checkout/checkout_providers.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/order_submission_recovery.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/notifications/notifications_providers.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';

import '../../support/f_fakes.dart';

/// «Сейчас» тестов: 2026-10-22 10:00 по Бишкеку (04:00 UTC).
final DateTime testNow = DateTime.utc(2026, 10, 22, 4);

/// Окна трёх классов (D-18).
const Map<String, Size> checkoutWindows = <String, Size>{
  'compact': Size(390, 844),
  'medium': Size(800, 1100),
  'expanded': Size(1280, 900),
};

LineQuantity qty(int units) => LineQuantity(value: Qty.units(units), unitId: 'pcs');

/// Корзина макета: смеситель ×2, унитаз ×1, душевая система ×1.
Cart mockupCart({Customer? customer, String id = 'cart-1', int rowVersion = 7}) => Cart(
  id: id,
  status: CartStatus.active,
  rowVersion: rowVersion,
  customer: customer,
  items: <CartLine>[
    CartLine(variantId: 'v-1', quantity: qty(2), productName: 'Смеситель для ванны Frap F3241'),
    CartLine(variantId: 'v-2', quantity: qty(1), productName: 'Унитаз-компакт Santek Бореал'),
    CartLine(variantId: 'v-3', quantity: qty(1), productName: 'Душевая система Gappo G2407'),
  ],
);

/// Клиент 1С (кассир видит суммы долга).
Customer mockupCustomer({bool withReceivable = true}) => Customer(
  id: 'cust-1',
  name: 'Азамат Бекович',
  phones: const <CustomerPhone>[CustomerPhone(valueE164: '+996700123456', verified: true)],
  discountPercent: const Percent(500),
  ordersCount: 12,
  hasDebt: false,
  onecCode: '00-000123',
  receivable: withReceivable ? ReceivableSummary(balance: Money.zero, asOf: testNow) : null,
);

List<OrderLine> mockupLines() => <OrderLine>[
  OrderLine(
    lineNo: 1,
    variantId: 'v-1',
    quantity: qty(2),
    productName: 'Смеситель для ванны Frap F3241',
    unitPrice: Money.som(2350),
    lineTotal: Money.som(4700),
  ),
  OrderLine(
    lineNo: 2,
    variantId: 'v-2',
    quantity: qty(1),
    productName: 'Унитаз-компакт Santek Бореал',
    unitPrice: Money.som(8150),
    lineTotal: Money.som(8150),
  ),
  OrderLine(
    lineNo: 3,
    variantId: 'v-3',
    quantity: qty(1),
    productName: 'Душевая система Gappo G2407',
    unitPrice: Money.som(4000),
    lineTotal: Money.som(4000),
  ),
];

/// Предпроверка макета: 16 850,00 → скидка 5 % −842,50 → 16 007,50.
CheckoutPreview mockupPreview({
  bool ok = true,
  PaymentMethod? method,
  List<PaymentMethod> allowed = PaymentMethod.values,
  OnecCheckResult onec = OnecCheckResult.ok,
  PaymentChecks? checks,
  List<CartConflict> conflicts = const <CartConflict>[],
  List<ApiWarning> warnings = const <ApiWarning>[],
}) => CheckoutPreview(
  cartId: 'cart-1',
  cartRowVersion: 7,
  ok: ok,
  conflicts: conflicts,
  items: mockupLines(),
  subtotal: const Money(1685000),
  discountPercent: const Percent(500),
  discountTotal: const Money(84250),
  total: const Money(1600750),
  totalToPay: const Money(1600750),
  paymentMethod: method,
  paymentChecks: checks,
  permissions: CheckoutPermissions(allowedPaymentMethods: allowed),
  onecCheck: OnecCheck(performed: onec == OnecCheckResult.ok, at: testNow, result: onec),
  validUntil: testNow.add(const Duration(minutes: 5)),
  previewToken: 'preview-token', // check-secrets: allow — тестовое значение
  warnings: warnings,
);

/// Заказ после `POST /orders`.
Order createdOrder({
  PaymentMethod method = PaymentMethod.cash,
  OrderStatus status = OrderStatus.submitting,
  List<Payment> payments = const <Payment>[],
  List<ApiWarning> warnings = const <ApiWarning>[],
  String? onecNumber,
  bool isPaid = false,
  Customer? customer,
  OrderSubmitError? submitError,
}) => Order(
  id: 'order-1',
  publicNumber: 'POS-2026-000123',
  status: status,
  total: const Money(1600750),
  totalToPay: const Money(1600750),
  paidAmount: isPaid ? const Money(1600750) : Money.zero,
  isPaid: isPaid,
  paymentMethod: method,
  items: mockupLines(),
  payments: payments,
  warnings: warnings,
  customer: customer ?? mockupCustomer(),
  delivery: const Delivery.pickup(),
  onec: onecNumber == null ? null : OrderOnecInfo(number: onecNumber, date: DateTime(2026, 10, 22)),
  submitError: submitError,
);

/// Платёж QR.
Payment qrPayment({
  PaymentStatus status = PaymentStatus.qrShown,
  bool withQr = true,
  bool autoConfirm = true,
  DateTime? expiresAt,
  ReviewReason? reviewReason,
  PaymentConfirmationKind? confirmation,
  List<ApiWarning> warnings = const <ApiWarning>[],
}) => Payment(
  id: 'pay-1',
  orderId: 'order-1',
  method: PaymentMethod.qrBakai,
  status: status,
  amount: const Money(1600750),
  reviewReason: reviewReason,
  confirmationKind: confirmation,
  warnings: warnings,
  qr: withQr
      ? QrInfo(
          rawProvider: autoConfirm ? 'onec' : 'none',
          payload: '00020101021226370011kg.bakai.qr0112POS2026000123520459995303417540816007.505802KG6304ABCD',
          amount: const Money(1600750),
          issuedAt: testNow,
          expiresAt: expiresAt ?? testNow.add(const Duration(minutes: 15)),
          autoConfirm: autoConfirm,
        )
      : null,
);

/// Навигатор-шпион.
final class SpyCheckoutNavigator implements CheckoutNavigator {
  final List<String> calls = <String>[];

  /// Результат «+ Новый клиент».
  String? newCustomerResult;

  @override
  void orderCreated(BuildContext context, {required String orderId, String? paymentId}) =>
      calls.add('orderCreated:$orderId:${paymentId ?? '-'}');

  @override
  void backToCart(BuildContext context, {String? cartId}) => calls.add('backToCart');

  @override
  Future<String?> newCustomer(BuildContext context) async {
    calls.add('newCustomer');
    return newCustomerResult;
  }

  @override
  void order(BuildContext context, String orderId) => calls.add('order:$orderId');

  @override
  void home(BuildContext context) => calls.add('home');

  @override
  void acceptPayment(BuildContext context, String orderId, {PaymentMethod? method}) =>
      calls.add('acceptPayment:$orderId:${method?.value ?? '-'}');

  @override
  void parked(BuildContext context) => calls.add('parked');
}

/// Окружение экрана оформления.
final class CheckoutHarness {
  CheckoutHarness({
    this.role = RoleCode.cashier,
    this.online = true,
    this.qr = const CheckoutQrMode(provider: QrProviderMode.onec, autoConfirm: true),
    this.slots = const <CheckoutSlot>[CheckoutSlot('10:00', '14:00'), CheckoutSlot('14:00', '18:00')],
    CheckoutPrefs prefs = const CheckoutPrefs(),
  }) : prefsStore = InMemoryCheckoutPrefsStore(prefs);

  final FFakes fakes = FFakes();

  /// Черновик оформления: новый ключ `order-key-N` на каждую попытку (`ensureOrderKey` после очистки).
  late final InMemoryCheckoutDraftRepository drafts = InMemoryCheckoutDraftRepository(
    newKey: () => 'order-key-${++_orderKeys}',
  );
  int _orderKeys = 0;
  final SpyCheckoutNavigator nav = SpyCheckoutNavigator();
  final FixedClock clock = FixedClock(testNow);
  final InMemoryCheckoutPrefsStore prefsStore;
  RoleCode? role;
  bool online;
  CheckoutQrMode qr;
  List<CheckoutSlot> slots;

  /// Операции step-up (журнал) и выдаваемый токен (`null` — отмена).
  final List<String> stepUps = <String>[];
  String? stepUpToken = 'step-up-token'; // check-secrets: allow — тестовое значение
  int _keys = 0;
  final List<String> printed = <String>[];

  /// Принтер исправен (`false` — ошибка печати, AC-UI-22-010).
  bool printerOk = true;

  /// Стандартные ответы: корзина, предпроверка, поиск.
  void stubDefaults({Cart? cart, CheckoutPreview Function(CheckoutPreviewRequest r)? preview}) {
    fakes.cart.onFetch = () async => Success<Cart>(cart ?? mockupCart());
    fakes.checkout.onPreview = (CheckoutPreviewRequest r) async =>
        Success<CheckoutPreview>(preview?.call(r) ?? mockupPreview(method: r.paymentMethod));
    fakes.customers.onSearch = (_) async =>
        Success<PageResult<Customer>>(PageResult<Customer>(items: <Customer>[mockupCustomer()]));
  }

  /// Дополнительные переопределения теста (например, `cartSyncProvider`).
  final List<Override> extraOverrides = <Override>[];

  List<Override> get overrides => <Override>[
    ...extraOverrides,
    cartRepositoryProvider.overrideWithValue(fakes.cart),
    ordersRepositoryProvider.overrideWithValue(fakes.orders),
    paymentsRepositoryProvider.overrideWithValue(fakes.payments),
    checkoutRepositoryProvider.overrideWithValue(fakes.checkout),
    checkoutDraftRepositoryProvider.overrideWithValue(drafts),
    customersRepositoryProvider.overrideWithValue(fakes.customers),
    notificationsRepositoryProvider.overrideWithValue(fakes.notifications),
    checkoutViewerRoleProvider.overrideWithValue(role),
    checkoutOnlineProvider.overrideWithValue(online),
    checkoutSessionLockedProvider.overrideWith((Ref ref) => ref.watch(testSessionLockedProvider)),
    checkoutQrModeProvider.overrideWithValue(qr),
    checkoutDeliverySlotsProvider.overrideWithValue(slots),
    checkoutNavigatorProvider.overrideWithValue(nav),
    checkoutPrefsStoreProvider.overrideWithValue(prefsStore),
    checkoutKeyFactoryProvider.overrideWithValue(() => 'key-${++_keys}'),
    checkoutStepUpProvider.overrideWithValue((String op) async {
      stepUps.add(op);
      return stepUpToken;
    }),
    checkoutPrinterProvider.overrideWithValue((OrderDocumentFile f) async {
      printed.add(f.fileName);
      return printerOk;
    }),
    clockProvider.overrideWithValue(clock),
    // Повторы при неизвестном результате POST /orders — без джиттера (02 SCR-20.11.1).
    orderSubmissionJitterProvider.overrideWithValue((int ms) => ms),
  ];

  /// Экран в приложении с темой B и локалью `ru` (окно [size]).
  Widget app(Widget child, {Size size = const Size(1280, 900)}) => ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? app) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true, size: size),
        child: app!,
      ),
      home: child,
    ),
  );

  /// Показать экран в окне [size].
  Future<void> pump(WidgetTester tester, Widget child, {Size size = const Size(1280, 900)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(child, size: size));
    await settle(tester);
  }
}

/// Несколько кадров без `pumpAndSettle` (бесконечные индикаторы/шиммеры): ответы фейков, debounce 500 мс.
Future<void> settle(WidgetTester tester, {Duration step = const Duration(milliseconds: 100), int frames = 8}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// Нажать (с прокруткой к виджету).
Future<void> tapKey(WidgetTester tester, Key key) async {
  final Finder f = find.byKey(key);
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await settle(tester);
}

/// Найти текст (в том числе внутри RichText).
Finder textContaining(String s) => find.textContaining(s, findRichText: true);

/// Idle-блокировка сессии в тестах SCR-22 (AC-UI-22-011): `container.read(testSessionLockedProvider.notifier).set(true)`.
final testSessionLockedProvider = NotifierProvider<TestSessionLocked, bool>(TestSessionLocked.new);

final class TestSessionLocked extends Notifier<bool> {
  @override
  bool build() => false;

  // ignore: use_setters_to_change_properties
  void set(bool value) => state = value;
}
