// T-UI-024 / T-UI-025 (12 §3.9) — недостающие кейсы приёмочных наборов SCR-24 «Заказ: детали» (AC-UI-24-003) и SCR-25
// «Список заказов» (AC-UI-25-007, 009, 010) плюс поля контракта 1.2.0: `audit.createdAt/createdBy` в шапке и строке
// (FQ-FEORD-02), `Payment.transactionId` → SCR-37 (UI-24-008). Остальные AC — orders_screen_test.dart,
// order_details_screen_test.dart. Переходы — через go_router (как в приложении); данные синтетические.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/presentation/orders_format.dart';
import 'package:optomstroy/features/orders/presentation/screens/order_details_screen.dart';
import 'package:optomstroy/features/orders/presentation/screens/orders_screen.dart';

import '../../../support/f_fakes.dart';
import '../support/orders_harness.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

List<OrdersQuery> queries(FakeOrdersRepository r) => <OrdersQuery>[
  for (final FakeCall c in r.calls)
    if (c.method == 'list') c.args.single! as OrdersQuery,
];

/// Приложение с маршрутами `/orders` (SCR-25, фильтры из query), `/orders/:id` (SCR-24), `/transactions/:id`.
Widget routedApp(OrdersHarness h, String initial, {Size size = const Size(1366, 900)}) {
  final GoRouter router = GoRouter(
    initialLocation: initial,
    routes: <RouteBase>[
      GoRoute(
        path: '/orders',
        builder: (BuildContext c, GoRouterState s) => OrdersScreen(
          status: s.uri.queryParameters['status'],
          from: s.uri.queryParameters['from'],
          to: s.uri.queryParameters['to'],
          customerId: s.uri.queryParameters['customerId'],
          mine: s.uri.queryParameters['mine'],
        ),
        routes: <RouteBase>[
          GoRoute(
            path: ':id',
            builder: (BuildContext c, GoRouterState s) => OrderDetailsScreen(orderId: s.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: '/transactions/:id',
        builder: (BuildContext c, GoRouterState s) => Scaffold(body: Text('SCR-37:${s.pathParameters['id']}')),
      ),
    ],
  );
  return ProviderScope(
    overrides: h.overrides,
    child: MaterialApp.router(
      routerConfig: router,
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true, size: size, padding: EdgeInsets.zero),
        child: child!,
      ),
    ),
  );
}

Future<void> pumpRouted(WidgetTester t, OrdersHarness h, String initial, {Size size = const Size(390, 844)}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  await t.pumpWidget(routedApp(h, initial, size: size));
  await t.pumpAndSettle();
}

/// Список из [n] заказов.
FakeOrdersRepository listRepo({int n = 30}) {
  final FakeOrdersRepository repo = FakeOrdersRepository();
  repo.onList = (OrdersQuery q) async =>
      Success<OrdersPage>(ordersPage(<OrderSummary>[for (int i = 1; i <= n; i++) summary(i)], total: n));
  repo.onGet = (String id, bool refresh) async => Success<OrderDetails>(details(order(id: id)));
  return repo;
}

String location(WidgetTester t) {
  final GoRouter router = GoRouter.of(t.element(find.byType(Navigator).first));
  return router.routerDelegate.currentConfiguration.uri.toString();
}

void main() {
  testWidgets('AC-UI-24-003: состав — наименования и артикулы на момент заказа (строки заказа, без каталога)', (
    WidgetTester t,
  ) async {
    final OrdersHarness h = OrdersHarness(orders: listRepo());
    await h.pump(t, const OrderDetailsScreen(orderId: 'o1'));
    await t.pumpAndSettle();
    expect(find.text('Смеситель для кухни Frap F4252 · хром'), findsOneWidget);
    expect(find.text('F4252-CR'), findsOneWidget);
    expect(h.orders.calls.map((FakeCall c) => c.method).toSet(), <String>{'get'}, reason: 'только GET /orders/{id}');
  });

  testWidgets('UI-24-001 / FQ-FEORD-02: шапка — дата создания и автор из Order.audit', (WidgetTester t) async {
    final Order base = order();
    final OrdersHarness h = OrdersHarness(
      orders: FakeOrdersRepository()
        ..onGet = (String id, bool refresh) async => Success<OrderDetails>(
          details(
            Order(
              id: base.id,
              publicNumber: base.publicNumber,
              status: base.status,
              total: base.total,
              paymentMethod: base.paymentMethod,
              items: base.items,
              onec: base.onec,
              createdAt: DateTime.utc(2026, 10, 22, 3, 10),
              createdBy: const UserRef(id: 'u1', displayName: 'Абдулла'),
            ),
          ),
        ),
    );
    await h.pump(t, const OrderDetailsScreen(orderId: 'o1'));
    await t.pumpAndSettle();
    expect(find.text('${OrdersFormat.dateTime(DateTime.utc(2026, 10, 22, 3, 10))} · Абдулла'), findsOneWidget);
  });

  testWidgets('UI-24-008: платёж с transactionId — тап → SCR-37 (транзакция платежа); без него — не нажимается', (
    WidgetTester t,
  ) async {
    final Order base = order(status: OrderStatus.awaitingPayment);
    final FakeOrdersRepository repo = FakeOrdersRepository()
      ..onGet = (String id, bool refresh) async => Success<OrderDetails>(
        details(
          Order(
            id: base.id,
            publicNumber: base.publicNumber,
            status: base.status,
            total: base.total,
            paymentMethod: base.paymentMethod,
            items: base.items,
            payments: <Payment>[
              const Payment(
                id: 'pay-1',
                orderId: 'o1',
                method: PaymentMethod.cash,
                status: PaymentStatus.received,
                amount: Money(800000),
                transactionId: 'txn-77',
              ),
              const Payment(
                id: 'pay-2',
                orderId: 'o1',
                method: PaymentMethod.cash,
                status: PaymentStatus.cashPending,
                amount: Money(100000),
              ),
            ],
          ),
        ),
      );
    final OrdersHarness h = OrdersHarness(orders: repo);
    await pumpRouted(t, h, '/orders/o1', size: const Size(1366, 900));
    expect(find.byKey(const ValueKey<String>('payment-open-pay-2')), findsNothing);
    await t.ensureVisible(find.byKey(const ValueKey<String>('payment-open-pay-1')));
    await t.tap(find.byKey(const ValueKey<String>('payment-open-pay-1')));
    await t.pumpAndSettle();
    expect(find.text('SCR-37:txn-77'), findsOneWidget);
  });

  testWidgets('UI-25-006 / FQ-FEORD-02: дата строки — создание заказа (audit.createdAt)', (WidgetTester t) async {
    final OrderSummary s = summary(1);
    final FakeOrdersRepository repo = FakeOrdersRepository()
      ..onList = (OrdersQuery q) async => Success<OrdersPage>(
        ordersPage(<OrderSummary>[
          OrderSummary(
            id: s.id,
            publicNumber: s.publicNumber,
            status: s.status,
            total: s.total,
            paymentMethod: s.paymentMethod,
            customer: s.customer,
            createdAt: DateTime.utc(2026, 10, 21, 6),
          ),
        ], total: 1),
      );
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen(), size: kWindows['expanded']!);
    await t.pumpAndSettle();
    expect(find.textContaining(OrdersFormat.date(DateTime.utc(2026, 10, 21, 6))), findsWidgets);
  });

  testWidgets('AC-UI-25-007, AC-UI-25-010: SCR-25 → SCR-24 — в пути только orderId; «Назад» возвращает те же query '
      '(status, from, to, customerId, mine), фильтры и прокрутку', (WidgetTester t) async {
    const String query =
        '/orders?status=awaiting_payment&from=2026-10-19T18%3A00%3A00.000Z&to=2026-10-22T18%3A00%3A00.000Z'
        '&customerId=c1&mine=1';
    final FakeOrdersRepository repo = listRepo();
    final OrdersHarness h = OrdersHarness(orders: repo);
    await pumpRouted(t, h, query);
    final OrdersQuery first = queries(repo).first;
    expect((first.customerId, first.createdBy), ('c1', 'u1'));
    await t.drag(find.byType(Scrollable).last, const Offset(0, -900));
    await t.pumpAndSettle();
    final Finder row = find.byKey(const ValueKey<String>('order-row-o12'));
    await t.ensureVisible(row);
    await t.pumpAndSettle();
    final double offset = t.state<ScrollableState>(find.byType(Scrollable).last).position.pixels;
    expect(offset, greaterThan(0));
    await t.tap(row);
    await t.pumpAndSettle();
    expect(
      GoRouterState.of(t.element(find.byType(OrderDetailsScreen))).uri.toString(),
      '/orders/o12',
      reason: 'в пути — только orderId',
    );
    expect(find.byType(OrderDetailsScreen), findsOneWidget);

    GoRouter.of(t.element(find.byType(OrderDetailsScreen))).pop();
    await t.pumpAndSettle();
    final Uri back = Uri.parse(location(t));
    expect(back.queryParameters, Uri.parse(query).queryParameters);
    final OrdersQuery last = queries(repo).last;
    expect((last.customerId, last.createdBy, last.cursor), ('c1', 'u1', null), reason: 'фильтры прежние');
    expect(
      t.state<ScrollableState>(find.byType(Scrollable).last).position.pixels,
      offset,
      reason: 'прокрутка сохранена',
    );
  });

  testWidgets(
    'AC-UI-25-009: через 5 мин — «Данные от HH:MM · Обновить»; возврат на экран обновляет первую страницу без '
    'потери прокрутки',
    (WidgetTester t) async {
      final FakeOrdersRepository repo = listRepo();
      final OrdersHarness h = OrdersHarness(orders: repo);
      await pumpRouted(t, h, '/orders');
      await t.drag(find.byType(Scrollable).last, const Offset(0, -600));
      await t.pumpAndSettle();
      final double offset = t.state<ScrollableState>(find.byType(Scrollable).last).position.pixels;
      expect(find.byKey(const ValueKey<String>('orders-stale')), findsNothing);

      h.clock.advance(const Duration(minutes: 6));
      await t.pump(const Duration(seconds: 31));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('orders-stale')), findsOneWidget);
      expect(find.text(l10n.orders_stale(OrdersFormat.stamp(kNow, h.clock.nowUtc()))), findsOneWidget);

      final int before = queries(repo).length;
      final Finder row = find.byKey(const ValueKey<String>('order-row-o9'));
      await t.ensureVisible(row);
      await t.pumpAndSettle();
      final double shown = t.state<ScrollableState>(find.byType(Scrollable).last).position.pixels;
      await t.tap(row);
      await t.pumpAndSettle();
      GoRouter.of(t.element(find.byType(OrderDetailsScreen))).pop();
      await t.pumpAndSettle();
      expect(queries(repo).length, before + 1);
      expect(queries(repo).last.cursor, isNull, reason: 'первая страница');
      expect(find.byKey(const ValueKey<String>('orders-stale')), findsNothing, reason: 'данные обновлены');
      expect(t.state<ScrollableState>(find.byType(Scrollable).last).position.pixels, shown);
      expect(offset, greaterThan(0));
    },
  );

  testWidgets('UI-25-012: фильтр «Не оплачен» (ключ orders_paid_unpaid, SCR-25 «Уточнения» п. 3) — isPaid=false', (
    WidgetTester t,
  ) async {
    final FakeOrdersRepository repo = listRepo(n: 3);
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen(), size: kWindows['compact']!);
    await t.tap(find.byKey(const ValueKey<String>('orders-filters')));
    await t.pumpAndSettle();
    final Finder unpaid = find.byKey(const ValueKey<String>('filter-paid-no'));
    await t.ensureVisible(unpaid);
    await t.pumpAndSettle();
    expect(find.text(l10n.orders_paid_unpaid), findsOneWidget);
    await t.tap(unpaid);
    await t.pumpAndSettle();
    expect(queries(repo).last.isPaid, isFalse);
  });
}
