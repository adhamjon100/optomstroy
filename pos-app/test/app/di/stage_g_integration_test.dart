// RM-G-009/RM-G-010 (интеграция Flutter этапа G): порты корня `stageGOverrides` — флаг оплаты долга (RM-G-013, Q-152,
// fail-closed), роль SCR-39, «В заказ» SCR-32 (UI-32-011: `POST /cart/customer`, замена клиента — ConfirmDialog),
// «Заказы и операции» SCR-32 (UI-32-007), печать SCR-37/SCR-38, сотрудники фильтра SCR-36; guard G-8 режима клиента
// для `/customers/{id}` при `CUSTOMER_SELF_SERVICE=false` (GQ-FECM-03).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/di/customer_orders_tab.dart';
import 'package:optomstroy/app/di/stage_g_overrides.dart';
import 'package:optomstroy/app/router/guards/role_guard.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/enums.dart' show CartStatus, QrProviderMode, RoleCode;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_users_repository.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:optomstroy/features/returns/presentation/providers/returns_ports.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/presentation/providers/transactions_ports.dart';
import 'package:optomstroy/features/transactions/transactions_providers.dart';

import '../../features/cart/support/cart_test_support.dart';
import '../../features/cashier/support/cashier_harness.dart' show FakeTransactions, tx, txPage;
import '../../features/orders/support/orders_harness.dart' show ordersPage, summary;
import '../../support/f_fakes.dart';

final Provider<OrderDocumentPrinter?> _printer = Provider<OrderDocumentPrinter?>((Ref ref) => _Printer());

final class _Printer implements OrderDocumentPrinter {
  final List<OrderDocumentFile> printed = <OrderDocumentFile>[];

  @override
  Future<void> preview(BuildContext context, OrderDocumentFile file) async {}

  @override
  Future<bool> print(OrderDocumentFile file) async {
    printed.add(file);
    return true;
  }
}

final class _Users implements AdminUsersRepository {
  @override
  Future<Result<AdminPage<AdminUser>>> listUsers(AdminUsersQuery query) async => const Success<AdminPage<AdminUser>>(
    AdminPage<AdminUser>(
      items: <AdminUser>[
        AdminUser(id: 'u-1', kind: 'staff', status: 'active', roles: <String>['cashier'], fullName: 'Тестов Кассир'),
        AdminUser(id: 'u-2', kind: 'customer', status: 'active', roles: <String>['customer'], fullName: 'Покупатель'),
      ],
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

PublicFeatureFlags _flags({required bool debt, bool fromServer = true}) => PublicFeatureFlags(
  customerSelfService: true,
  returnsFromPos: true,
  qrProvider: QrProviderMode.onec,
  qrWebhook: false,
  debtPaymentsFromPos: debt,
  fromServer: fromServer,
);

ProviderContainer _container(RoleCode? role, {bool debt = false, List<Override> extra = const <Override>[]}) {
  final ProviderContainer c = ProviderContainer(
    overrides: <Override>[
      ...stageGOverrides(_printer),
      catalogViewerRoleProvider.overrideWithValue(role),
      publicFeatureFlagsProvider.overrideWithValue(_flags(debt: debt)),
      adminUsersRepositoryProvider.overrideWithValue(_Users()),
      ...extra,
    ],
  );
  addTearDown(c.dispose);
  return c;
}

const Customer _current = Customer(id: 'cu-other', name: 'Иванов Иван');

Widget _routerApp(Widget home, {List<Override> overrides = const <Override>[], Size size = const Size(1366, 900)}) {
  final GoRouter router = GoRouter(
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(body: SingleChildScrollView(child: home)),
      ),
      for (final String p in <String>[
        '/cart',
        '/catalog',
        '/orders',
        '/orders/:id',
        '/transactions',
        '/transactions/:id',
      ])
        GoRoute(
          path: p,
          builder: (_, GoRouterState s) => Scaffold(body: Text('route:${s.uri}')),
        ),
    ],
  );
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true, size: size),
        child: child!,
      ),
    ),
  );
}

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

void main() {
  group('stageGOverrides — порты корня', () {
    test('RM-G-013: «Принять оплату по долгу» — только при debtPaymentsFromPos=true от сервера (R1 — выключено)', () {
      expect(_container(RoleCode.cashier).read(customerDebtPaymentsEnabledProvider), isFalse);
      expect(_container(RoleCode.cashier, debt: true).read(customerDebtPaymentsEnabledProvider), isTrue);
    });

    test('SCR-39: роль из профиля входа (без роли — только просмотр); касса/журнал — та же роль', () {
      final ProviderContainer cashier = _container(RoleCode.cashier);
      expect(cashier.read(returnsViewerProvider).role, RoleCode.cashier);
      expect(cashier.read(returnsViewerProvider).canCreate, isTrue);
      expect(cashier.read(returnsViewerProvider).canApprove, isFalse);
      expect(cashier.read(cashierViewerRoleProvider), RoleCode.cashier);
      expect(cashier.read(transactionsViewerRoleProvider), RoleCode.cashier);
      expect(_container(RoleCode.seniorSeller).read(returnsViewerProvider).canApprove, isTrue);
      expect(_container(null).read(returnsViewerProvider).canCreate, isFalse);
    });

    test('UI-32-011 «В заказ»: seller, cashier, senior_seller, admin — есть; owner, customer, без роли — скрыта', () {
      for (final RoleCode r in <RoleCode>[RoleCode.seller, RoleCode.cashier, RoleCode.seniorSeller, RoleCode.admin]) {
        expect(_container(r).read(customerToCartActionProvider), isNotNull, reason: '$r');
      }
      for (final RoleCode? r in <RoleCode?>[RoleCode.owner, RoleCode.customer, null]) {
        expect(_container(r).read(customerToCartActionProvider), isNull, reason: '$r');
      }
      expect(_container(RoleCode.cashier).read(customerOrdersTabBuilderProvider), isNotNull);
    });

    test('печать SCR-38/SCR-37 — принтер документов корня; без принтера — недоступна', () async {
      final ProviderContainer c = _container(RoleCode.cashier);
      final CashierReceiptPrinter? p = c.read(cashierReceiptPrinterProvider);
      expect(p, isNotNull);
      const OrderDocumentFile f = OrderDocumentFile(bytes: <int>[37, 80, 68, 70], fileName: 'r.pdf');
      expect(await p!(f), isTrue);
      expect(c.read(transactionsDocumentPrinterProvider), isNotNull);
      final ProviderContainer none = _container(RoleCode.cashier, extra: <Override>[_printer.overrideWithValue(null)]);
      expect(none.read(cashierReceiptPrinterProvider), isNull);
      expect(none.read(transactionsDocumentPrinterProvider), isNull);
    });

    test(
      'SCR-36 «Сотрудник»: admin/owner — сотрудники из /admin/users (без клиентов); кассир — нет источника',
      () async {
        expect(_container(RoleCode.cashier).read(transactionsActorsProvider), isNull);
        final TransactionsActorsSource? src = _container(RoleCode.owner).read(transactionsActorsProvider);
        final List<UserRef> users = (await src!()).valueOrNull!;
        expect(users.map((UserRef u) => (u.id, u.displayName, u.role)), <(String, String, RoleCode?)>[
          ('u-1', 'Тестов Кассир', RoleCode.cashier),
        ]);
      },
    );
  });

  group('assignCustomerToCart (UI-32-011)', () {
    late FakeCartRepository repo;
    late FakeCartSync sync;

    setUp(() {
      repo = FakeCartRepository();
      sync = FakeCartSync(repo);
      repo.onSetCustomer = (String id, int rv, Receiver? r) async => Success<Cart>(
        Cart(
          id: 'cart-1',
          status: CartStatus.active,
          items: const <CartLine>[],
          rowVersion: rv + 1,
          customer: Customer(id: id, name: 'Новый'),
        ),
      );
    });

    Widget button() => Builder(
      builder: (BuildContext context) => TextButton(
        onPressed: () => assignCustomerToCart(context, 'cu-1', sync: sync, repository: repo, keyFactory: () => 'k-1'),
        child: const Text('to-cart'),
      ),
    );

    testWidgets('корзина без клиента → POST /cart/customer (rowVersion, ключ) → expanded: SCR-10 с панелью корзины', (
      tester,
    ) async {
      await _setSize(tester, const Size(1366, 900));
      repo.onFetch = () async => Success<Cart>(emptyCart(rowVersion: 4));
      await tester.pumpWidget(_routerApp(button()));
      await tester.tap(find.text('to-cart'));
      await tester.pumpAndSettle();
      final FakeCall call = repo.calls.firstWhere((FakeCall c) => c.method == 'setCustomer');
      expect(call.args, <Object?>['cu-1', 4, null, 'k-1']);
      expect(find.text('route:/catalog'), findsOneWidget);
    });

    testWidgets('compact → SCR-20; другой клиент в корзине → ConfirmDialog; «Отмена» — без запроса', (tester) async {
      await _setSize(tester, const Size(390, 844));
      repo.onFetch = () async => const Success<Cart>(
        Cart(id: 'cart-1', status: CartStatus.active, items: <CartLine>[], rowVersion: 2, customer: _current),
      );
      await tester.pumpWidget(_routerApp(button(), size: const Size(390, 844)));
      await tester.tap(find.text('to-cart'));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmDialog), findsOneWidget);
      expect(find.textContaining('Иванов Иван'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(repo.calls.where((FakeCall c) => c.method == 'setCustomer'), isEmpty);
      await tester.tap(find.text('to-cart'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Заменить'));
      await tester.pumpAndSettle();
      expect(repo.calls.where((FakeCall c) => c.method == 'setCustomer'), hasLength(1));
      expect(find.text('route:/cart'), findsOneWidget);
    });

    testWidgets('тот же клиент — без запроса, сразу корзина; ошибка корзины — снекбар, остаёмся', (tester) async {
      await _setSize(tester, const Size(390, 844));
      repo.onFetch = () async => const Success<Cart>(
        Cart(
          id: 'cart-1',
          status: CartStatus.active,
          items: <CartLine>[],
          rowVersion: 2,
          customer: Customer(id: 'cu-1', name: 'Тот же'),
        ),
      );
      await tester.pumpWidget(_routerApp(button(), size: const Size(390, 844)));
      await tester.tap(find.text('to-cart'));
      await tester.pumpAndSettle();
      expect(repo.calls.where((FakeCall c) => c.method == 'setCustomer'), isEmpty);
      expect(find.text('route:/cart'), findsOneWidget);
    });

    testWidgets('нет сети — снекбар ошибки, без перехода', (tester) async {
      await _setSize(tester, const Size(1366, 900));
      sync.offline = true;
      await tester.pumpWidget(_routerApp(button()));
      await tester.tap(find.text('to-cart'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('route:'), findsNothing);
      expect(repo.calls.where((FakeCall c) => c.method == 'setCustomer'), isEmpty);
    });
  });

  group('CustomerOrdersTab (UI-32-007)', () {
    late FakeOrdersRepository orders;
    late FakeTransactions transactions;

    setUp(() {
      orders = FakeOrdersRepository();
      transactions = FakeTransactions();
    });

    List<Override> overrides() => <Override>[
      ordersRepositoryProvider.overrideWithValue(orders),
      transactionsRepositoryProvider.overrideWithValue(transactions),
    ];

    testWidgets('«Заказы» — GET /orders?customerId= (20 строк), тап → SCR-24; «Операции» — GET /transactions за '
        '≤ 366 дней, тап → SCR-37; «Показать всю историю» → SCR-25/36 с фильтром клиента', (tester) async {
      await _setSize(tester, const Size(1366, 900));
      orders.onList = (OrdersQuery q) async => Success<OrdersPage>(ordersPage(<OrderSummary>[summary(1)], next: 'c2'));
      transactions.onList = (_) async => Success<TransactionsPage>(txPage(<Transaction>[tx('t-1')], next: 'n'));
      await tester.pumpWidget(_routerApp(const CustomerOrdersTab(customerId: 'cu-1'), overrides: overrides()));
      await tester.pumpAndSettle();
      final OrdersQuery q = orders.calls.single.args.single! as OrdersQuery;
      expect((q.customerId, q.limit), ('cu-1', customerOrdersTabPageSize));
      expect(find.byKey(CustomerOrdersTabKeys.order('o1')), findsOneWidget);
      expect(transactions.queries, isEmpty, reason: 'операции — только при открытии сегмента');

      await tester.tap(find.text('Операции'));
      await tester.pumpAndSettle();
      final TransactionsQuery tq = transactions.queries.single;
      expect(tq.customerId, 'cu-1');
      expect(tq.period.to.difference(tq.period.from).inDays, lessThanOrEqualTo(366));
      await tester.tap(find.byKey(CustomerOrdersTabKeys.operation('t-1')));
      await tester.pumpAndSettle();
      expect(find.text('route:/transactions/t-1'), findsOneWidget);
    });

    testWidgets('пусто — EmptyState; ошибка — «Повторить» перезапрашивает', (tester) async {
      await _setSize(tester, const Size(1366, 900));
      int n = 0;
      orders.onList = (_) async => ++n == 1
          ? const FailureResult<OrdersPage>(NetworkFailure(NetworkFailureKind.timeout))
          : Success<OrdersPage>(ordersPage(const <OrderSummary>[]));
      await tester.pumpWidget(_routerApp(const CustomerOrdersTab(customerId: 'cu-1'), overrides: overrides()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(n, 2);
      expect(find.text('Заказов пока нет'), findsOneWidget);
    });

    testWidgets('тап по заказу → SCR-24', (tester) async {
      await _setSize(tester, const Size(390, 844));
      orders.onList = (_) async => Success<OrdersPage>(ordersPage(<OrderSummary>[summary(7)]));
      await tester.pumpWidget(
        _routerApp(
          const CustomerOrdersTab(customerId: 'cu-1'),
          overrides: overrides(),
          size: const Size(390, 844),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(CustomerOrdersTabKeys.showAllOrders), findsNothing);
      await tester.tap(find.byKey(CustomerOrdersTabKeys.order('o7')));
      await tester.pumpAndSettle();
      expect(find.text('route:/orders/o7'), findsOneWidget);
    });
  });

  group('guard G-8 режима клиента (GQ-FECM-03)', () {
    String? redirect(String path, {required bool selfService}) => roleRedirect(
      mode: AppMode.customer,
      uri: Uri.parse(path),
      homeLocation: '/home',
      customerSelfService: selfService,
      role: RoleCode.customer,
    );

    test(
      'CUSTOMER_SELF_SERVICE=false закрывает свои SCR-32…35 (→ SCR-07); при true — путь открыт (проверяет сервер)',
      () {
        for (final String p in <String>['/customers/cu-1', '/customers/cu-1/receivables', '/customers/cu-1/history']) {
          expect(redirect(p, selfService: false), '/pending-activation', reason: p);
          expect(redirect(p, selfService: true), isNull, reason: p);
        }
        expect(redirect('/customers', selfService: true), '/home', reason: 'список клиентов — только сотрудникам');
      },
    );
  });
}
