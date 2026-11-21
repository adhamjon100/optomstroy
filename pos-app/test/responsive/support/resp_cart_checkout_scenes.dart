// Сцены прогона адаптивности корзины и оформления (12 T-UI-117): SCR-20 (экран `/cart` уже 600, drawer 420 шире),
// SCR-23, окно SCR-21 и SCR-22 — для resp_cart_checkout_test.dart и resp_rules_test.dart. Данные — как у эталонов;
// сцены «предварительно / офлайн» (ревью own-server:FIX-app) — корзина с крупным итогом [respBigCart].
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/cart_panel.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/screens/parked_carts_screen.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/checkout/presentation/screens/checkout_screen.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

import '../../features/cart/support/cart_test_support.dart';
import '../../features/checkout/checkout_test_support.dart';
import '../../support/f_fakes.dart';
import '../../support/responsive_audit.dart';

CartLocalSnapshot respLocal(Cart cart) => CartLocalSnapshot(
  localCartId: 'local-1',
  dirty: false,
  baseRowVersion: cart.rowVersion,
  lines: <CartLocalLine>[
    for (final (int i, CartLine l) in cart.items.indexed)
      CartLocalLine(
        key: CartLineKey(l.variantId),
        quantity: l.quantity.value,
        syncState: CartDraftSyncState.synced,
        lineNo: i + 1,
        unitId: 'u-pc',
        unitLabel: 'шт',
        step: Qty.units(1),
      ),
  ],
);

final List<CartParkedSummary> respParked = <CartParkedSummary>[
  CartParkedSummary(
    id: 'pc-1',
    status: CartStatus.parked,
    rowVersion: 3,
    name: 'Бригада Асанова',
    ownerId: 'user-1',
    itemsCount: 5,
    total: const Money(1600750),
    parkedAt: cartNow.subtract(const Duration(hours: 2)),
    expiresAt: cartNow.add(const Duration(days: 5)),
  ),
  CartParkedSummary(
    id: 'pc-2',
    status: CartStatus.parked,
    rowVersion: 1,
    name: 'Восстановлена из заказа № 2026-000123',
    ownerId: 'user-1',
    itemsCount: 2,
    total: const Money(480000),
    restoredFromOrderId: 'o-123',
    parkedAt: cartNow.subtract(const Duration(days: 6)),
    expiresAt: cartNow.add(const Duration(hours: 20)),
  ),
];

/// SCR-20: окна уже 600 — экран `/cart`; шире — drawer 420 (в окне уже — во всю ширину) над затемнением.
Widget respCart(Size size) {
  final FakeCartRepository repo = FakeCartRepository();
  final FakeCartSync sync = FakeCartSync(repo);
  final Cart cart = canonCart();
  serveCart(repo, cart);
  sync.snapshot = respLocal(cart);
  repo.onListParked = (ParkedScope s, String? c) async =>
      Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: respParked));
  return cartApp(
    size: size,
    overrides: cartOverrides(sync: sync, repo: repo, role: RoleCode.cashier),
    cartBuilder: size.width < DsBreakpoints.medium ? null : (BuildContext context) => _respCartDrawer(context, size),
  );
}

/// Drawer корзины 420 (в окне уже — во всю ширину окна) над затемнением.
Widget _respCartDrawer(BuildContext context, Size size) => Scaffold(
  backgroundColor: context.colors.overlay,
  body: Align(
    alignment: AlignmentDirectional.centerEnd,
    child: SizedBox(
      width: math.min(DsBreakpoints.cartDrawer, size.width),
      child: const CartPanelView(variant: CartPanelVariant.overlay),
    ),
  ),
);

/// Корзина с крупным итогом (ревью own-server:FIX-app): 5 позиций · 51 шт, 131 000,00 − 5 % 6 550,00 = 124 450,00 сом.
Cart respBigCart() {
  final List<CartLine> lines = <CartLine>[
    canonLine('f4252', 'Смеситель для кухни Frap F4252', 'F4252', 20, 2350),
    canonLine('f2283', 'Смеситель для ванны Frap F2283', 'F2283', 10, 3450),
    canonLine('g1007', 'Смеситель для раковины Gappo G1007', 'G1007', 12, 1650),
    canonLine('l74103', 'Смеситель для кухни Ledeme L74103', 'L74103', 6, 2850),
    canonLine('sus011', 'Смеситель для кухни Mixxus SUS-011', 'SUS-011', 3, 4200),
  ];
  return Cart(
    id: 'cart-1',
    status: CartStatus.active,
    items: lines,
    rowVersion: 17,
    warehouseId: 'wh-main',
    priceListId: 'pl-retail',
    itemsCount: lines.length,
    subtotal: const Money(13100000),
    requestedDiscountPercent: const Percent(500),
    appliedDiscountPercent: const Percent(500),
    discountTotal: const Money(655000),
    total: const Money(12445000),
    discountLimitPercent: const Percent(500),
  );
}

/// Статус сети сцены «офлайн»: корзина загружена в сети, затем сеть пропала ([respGoOffline]).
final class RespOnline extends Notifier<OnlineStatus> {
  @override
  OnlineStatus build() => OnlineStatus.online;

  void set(OnlineStatus s) => state = s;
}

final NotifierProvider<RespOnline, OnlineStatus> respOnlineProvider = NotifierProvider<RespOnline, OnlineStatus>(
  RespOnline.new,
);

/// Очередь отправки корзины не пуста (`queued` 1) — «Итого» предварительно (UI-20-030), сервер доступен.
final class RespQueuedCartSync extends FakeCartSync {
  RespQueuedCartSync(super.repo);

  @override
  Stream<CartSyncStatus> watchStatus() async* {
    yield const CartSyncStatus(queued: 1);
  }
}

/// SCR-20 с меткой «предварительно» у «Итого» и крупной суммой ([respBigCart]; ревью own-server:FIX-app): [offline] —
/// сеть пропала после загрузки корзины (settle [respGoOffline]), иначе — очередь отправки не пуста. Окна уже 600 —
/// экран `/cart`, шире — drawer 420; [drawer] — drawer и в окне уже 600 (во всю ширину окна).
Widget respCartPreliminary(Size size, {required bool offline, bool drawer = false}) {
  final FakeCartRepository repo = FakeCartRepository();
  final FakeCartSync sync = offline ? FakeCartSync(repo) : RespQueuedCartSync(repo);
  final Cart cart = respBigCart();
  serveCart(repo, cart);
  sync.snapshot = respLocal(cart);
  repo.onListParked = (ParkedScope s, String? c) async =>
      Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: respParked));
  return cartApp(
    size: size,
    overrides: cartOverrides(
      sync: sync,
      repo: repo,
      role: RoleCode.cashier,
      onlineOverride: offline
          ? cartOnlineStatusProvider.overrideWith((Ref ref) => ref.watch(respOnlineProvider))
          : null,
    ),
    cartBuilder: size.width < DsBreakpoints.medium && !drawer
        ? null
        : (BuildContext context) => _respCartDrawer(context, size),
  );
}

/// Кадры загрузки корзины в сети, затем сеть пропала ([respOnlineProvider] → `offline`) — кадры перестройки.
Future<void> respGoOffline(WidgetTester tester, Size size) async {
  await respFrames(tester);
  ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  ).read(respOnlineProvider.notifier).set(OnlineStatus.offline);
  await respFrames(tester);
}

/// SCR-23: окна уже 600 — экран; шире — side sheet 400.
Widget respParkedCarts(Size size) {
  final FakeCartRepository repo = FakeCartRepository();
  final FakeCartSync sync = FakeCartSync(repo);
  serveCart(repo, canonCart());
  repo.onListParked = (ParkedScope s, String? c) async =>
      Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: respParked));
  final bool compact = size.width < DsBreakpoints.medium;
  return cartApp(
    size: size,
    initialLocation: compact ? '/cart/parked' : '/cart',
    overrides: cartOverrides(sync: sync, repo: repo, role: RoleCode.seller),
    cartBuilder: compact
        ? null
        : (BuildContext context) => Scaffold(
            backgroundColor: context.colors.overlay,
            body: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Container(width: 400, color: context.colors.surface, child: const ParkedCartsBody(asSheet: true)),
            ),
          ),
  );
}

class RespCheckoutWindow extends StatelessWidget {
  const RespCheckoutWindow({super.key, required this.size, required this.harness, required this.child});

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

CheckoutHarness respCheckout({CheckoutStep step = CheckoutStep.customer, bool delivery = false}) {
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

CheckoutHarness respCreated() {
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

Future<void> respCheckoutFrames(WidgetTester tester, Size size) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget respCheckoutWindow(Size size, CheckoutStep step, {bool delivery = false}) => RespCheckoutWindow(
  size: size,
  harness: respCheckout(step: step, delivery: delivery),
  child: Builder(
    builder: (BuildContext context) => ColoredBox(
      color: context.colors.background,
      child: const CheckoutScreen(cartId: 'cart-1'),
    ),
  ),
);
