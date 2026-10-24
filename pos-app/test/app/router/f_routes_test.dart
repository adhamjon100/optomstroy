// Этап F (основа): типизированные маршруты SCR-20…SCR-26, SCR-44 с параметрами 02 §4.1 и `q` у SCR-13 (EQ-CAT-12);
// маршруты строят реальные экраны фич (интеграция F, RM-F-011); guards G-7/G-8 для путей F.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:optomstroy/app/router/guards/role_guard.dart';
import 'package:optomstroy/app/router/route_stub_screen.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/features/cart/presentation/screens/cart_screen.dart';
import 'package:optomstroy/features/cart/presentation/screens/parked_carts_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_filters_screen.dart';
import 'package:optomstroy/features/checkout/presentation/screens/checkout_screen.dart';
import 'package:optomstroy/features/checkout/presentation/screens/order_created_screen.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_screen.dart';
import 'package:optomstroy/features/notifications/presentation/screens/notifications_screen.dart';
import 'package:optomstroy/features/orders/presentation/screens/order_details_screen.dart';
import 'package:optomstroy/features/orders/presentation/screens/orders_screen.dart';

void main() {
  test('пути и query-параметры маршрутов этапа F — строго по 02 §4.1', () {
    expect(const CartRoute().location, '/cart');
    expect(const CartRoute(cartId: 'c1').location, '/cart?cartId=c1');
    expect(const CartParkedRoute().location, '/cart/parked');
    expect(const CheckoutRoute(cartId: 'c1', step: 'payment').location, '/checkout?cartId=c1&step=payment');
    expect(const OrderCreatedRoute(orderId: 'o1', paymentId: 'p1').location, '/orders/o1/created?paymentId=p1');
    expect(const OrderRoute(orderId: 'o1').location, '/orders/o1');
    expect(
      const OrdersRoute(status: 'submitting,pending_approval', customerId: 'k1', mine: '1').location,
      '/orders?status=submitting%2Cpending_approval&customerId=k1&mine=1',
    );
    expect(const OrdersRoute(from: '2026-10-01', to: '2026-10-22').location, '/orders?from=2026-10-01&to=2026-10-22');
    expect(const CustomerNewRoute(returnTo: 'checkout').location, '/customers/new?returnTo=checkout');
    expect(const NotificationsRoute(unread: '1').location, '/notifications?unread=1');
    expect(
      const CatalogFiltersRoute(f: 'x', q: 'смеситель').location,
      '/catalog/filters?f=x&q=%D1%81%D0%BC%D0%B5%D1%81%D0%B8%D1%82%D0%B5%D0%BB%D1%8C',
    );
  });

  test('guards: customer — корзина, оформление, заказы, уведомления; не отложенные и не «Новый клиент»', () {
    String? customer(String path) => roleRedirect(
      mode: AppMode.customer,
      uri: Uri.parse(path),
      homeLocation: '/home',
      customerSelfService: true,
      role: RoleCode.customer,
    );
    for (final String path in <String>[
      '/cart',
      '/checkout?cartId=c1',
      '/orders',
      '/orders/o1',
      '/orders/o1/created',
      '/notifications',
    ]) {
      expect(customer(path), isNull, reason: path);
    }
    expect(customer('/cart/parked'), '/home');
    expect(customer('/customers/new'), '/home');
    String? staff(RoleCode role, String path) => roleRedirect(
      mode: AppMode.seller,
      uri: Uri.parse(path),
      homeLocation: '/catalog',
      customerSelfService: true,
      role: role,
    );
    for (final RoleCode role in <RoleCode>[RoleCode.seller, RoleCode.cashier, RoleCode.seniorSeller, RoleCode.admin]) {
      for (final String path in <String>[
        '/cart',
        '/cart/parked',
        '/checkout',
        '/orders',
        '/customers/new',
        '/notifications',
      ]) {
        expect(staff(role, path), isNull, reason: '${role.value} $path');
      }
    }
    expect(staff(RoleCode.owner, '/checkout'), '/catalog');
    expect(staff(RoleCode.owner, '/orders'), isNull);
  });

  testWidgets(
    'маршруты этапа F ведут на реальные экраны фич (не RouteStubScreen), параметры передаются в конструктор',
    (WidgetTester tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        Builder(
          builder: (BuildContext c) {
            context = c;
            return const SizedBox.shrink();
          },
        ),
      );
      final GoRouterState state = _MockState();
      Widget build(GoRouteData route) => route.build(context, state);

      final Widget cart = build(const CartRoute(cartId: 'c1'));
      expect(cart, isA<CartScreen>().having((s) => s.cartId, 'cartId', 'c1'));
      expect(build(const CartParkedRoute()), isA<ParkedCartsScreen>());
      expect(
        build(const CheckoutRoute(cartId: 'c1', step: 'delivery')),
        isA<CheckoutScreen>().having((s) => s.cartId, 'cartId', 'c1').having((s) => s.step, 'step', 'delivery'),
      );
      expect(
        build(const OrderCreatedRoute(orderId: 'o1', paymentId: 'p1')),
        isA<OrderCreatedScreen>()
            .having((s) => s.orderId, 'orderId', 'o1')
            .having((s) => s.paymentId, 'paymentId', 'p1'),
      );
      expect(
        build(const OrderRoute(orderId: 'o1')),
        isA<OrderDetailsScreen>().having((s) => s.orderId, 'orderId', 'o1'),
      );
      expect(build(const OrdersRoute(mine: '1')), isA<OrdersScreen>().having((s) => s.mine, 'mine', '1'));
      expect(
        build(const CustomerNewRoute(returnTo: 'checkout')),
        isA<NewCustomerScreen>().having((s) => s.returnTo, 'returnTo', 'checkout'),
      );
      expect(
        build(const NotificationsRoute(unread: '1')),
        isA<NotificationsScreen>().having((s) => s.unreadOnly, 'unreadOnly', isTrue),
      );
      expect(
        build(const CatalogFiltersRoute(f: 'x', q: 'смеситель')),
        isA<CatalogFiltersScreen>().having((s) => s.q, 'q', 'смеситель').having((s) => s.f, 'f', 'x'),
      );
      for (final GoRouteData route in <GoRouteData>[
        const CartRoute(),
        const CartParkedRoute(),
        const CheckoutRoute(),
        const OrderCreatedRoute(orderId: 'o1'),
        const OrderRoute(orderId: 'o1'),
        const OrdersRoute(),
        const CustomerNewRoute(),
        const NotificationsRoute(),
      ]) {
        expect(build(route), isNot(isA<RouteStubScreen>()), reason: route.runtimeType.toString());
      }
    },
  );
}

final class _MockState extends Mock implements GoRouterState {}
