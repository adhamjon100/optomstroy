// Этап G (основа): типизированные маршруты SCR-30…SCR-41, SCR-45…SCR-48 с параметрами строго по 02 §4.1; маршруты
// ведут на экраны фич с фиксированными именами классов (не RouteStubScreen); guards по ролям (02 §5, 11 §4.4,
// navigation.md §14.2, §14.7: owner — главный /reports, ограниченный режим SCR-45/46; admin без SCR-38 — D-15) и по
// флагам функций (G-8: `returns_enabled=false`; RM-G-013: `debtPaymentsFromPos=false` — режима «по долгу» нет).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/guards/role_guard.dart';
import 'package:optomstroy/app/router/route_stub_screen.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/cashier_shell.dart';
import 'package:optomstroy/app/router/shells/seller_shell.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/features/admin/presentation/audit/audit_screen.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_screen.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_users_screen.dart';
import 'package:optomstroy/features/cashier/presentation/screens/cashier_dashboard_screen.dart';
import 'package:optomstroy/features/cashier/presentation/screens/payment_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_card_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_discounts_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_history_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_receivables_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customers_search_screen.dart';
import 'package:optomstroy/features/favorites/presentation/screens/favorites_screen.dart';
import 'package:optomstroy/features/profile/presentation/screens/profile_screen.dart';
import 'package:optomstroy/features/reports/presentation/screens/reports_screen.dart';
import 'package:optomstroy/features/returns/presentation/screens/return_request_screen.dart';
import 'package:optomstroy/features/transactions/presentation/screens/transaction_details_screen.dart';
import 'package:optomstroy/features/transactions/presentation/screens/transactions_screen.dart';

final class _MockState extends Mock implements GoRouterState {}

String? _redirect(RoleCode role, String location, {RouteFeatures features = RouteFeatures.defaults, AppMode? mode}) =>
    appRedirect(
      status: SessionStatus.authenticated,
      uri: Uri.parse(location),
      mode: mode ?? appModeFor(kind: role == RoleCode.customer ? UserKind.customer : UserKind.staff, role: role),
      customerSelfService: true,
      role: role,
      features: features,
    );

void main() {
  test('адреса маршрутов этапа G — пути и query строго по 02 §4.1', () {
    expect(
      const CustomersRoute(q: 'Асан', favorites: '1', withDebt: '1').location,
      '/customers?q=%D0%90%D1%81%D0%B0%D0%BD&favorites=1&withDebt=1',
    );
    expect(const CustomerRoute(customerId: 'c1', tab: 'receivables').location, '/customers/c1?tab=receivables');
    expect(
      const CustomerHistoryRoute(customerId: 'c1', from: '2026-10-01', to: '2026-10-24', source: 'onec').location,
      '/customers/c1/history?from=2026-10-01&to=2026-10-24&source=onec',
    );
    expect(const CustomerReceivablesRoute(customerId: 'c1').location, '/customers/c1/receivables');
    expect(const CustomerDiscountsRoute(customerId: 'c1').location, '/customers/c1/discounts');
    expect(const CashierRoute().location, '/cashier');
    expect(
      const TransactionsRoute(
        from: 'a',
        to: 'b',
        customerId: 'c1',
        status: 'received',
        kind: 'refund',
        paymentMethod: 'cash',
        actorId: 'u1',
        q: 'x',
        mine: '1',
      ).location,
      '/transactions?from=a&to=b&customerId=c1&status=received&kind=refund&paymentMethod=cash&actorId=u1&q=x&mine=1',
    );
    expect(const TransactionRoute(transactionId: 't1').location, '/transactions/t1');
    expect(const PaymentNewRoute(orderId: 'o1', method: 'cash').location, '/payments/new?orderId=o1&method=cash');
    expect(const PaymentNewRoute(customerId: 'c1').location, '/payments/new?customerId=c1');
    expect(const ReturnNewRoute(orderId: 'o1').location, '/returns/new?orderId=o1');
    expect(const ReturnRoute(returnId: 'r1').location, '/returns/r1');
    expect(const FavoritesRoute(tab: 'customers').location, '/favorites?tab=customers');
    expect(const ProfileRoute().location, '/profile');
    expect(const AdminUsersRoute(tab: 'links', userId: 'u1').location, '/admin/users?tab=links&userId=u1');
    expect(const AdminSettingsRoute(section: 'limits').location, '/admin/settings?section=limits');
    expect(
      const AdminAuditRoute(
        from: 'a',
        to: 'b',
        userId: 'u1',
        action: 'payment.',
        entityType: 'order',
        entityId: 'o1',
        result: 'denied',
      ).location,
      '/admin/audit?from=a&to=b&userId=u1&action=payment.&entityType=order&entityId=o1&result=denied',
    );
    expect(
      const ReportsRoute(from: 'a', to: 'b', report: 'sales', groupBy: 'seller').location,
      '/reports?from=a&to=b&report=sales&groupBy=seller',
    );
  });

  testWidgets('маршруты этапа G строят экраны фич с параметрами (не RouteStubScreen)', (WidgetTester tester) async {
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

    expect(build(const CashierRoute()), isA<CashierDashboardScreen>());
    expect(
      build(const CustomersRoute(q: 'a', favorites: '1')),
      isA<CustomersSearchScreen>()
          .having((s) => s.q, 'q', 'a')
          .having((s) => s.favoritesOnly, 'favoritesOnly', isTrue)
          .having((s) => s.withDebtOnly, 'withDebtOnly', isFalse),
    );
    expect(
      build(const CustomerRoute(customerId: 'c1', tab: 'history')),
      isA<CustomerCardScreen>().having((s) => s.customerId, 'id', 'c1').having((s) => s.tab, 'tab', 'history'),
    );
    expect(
      build(const CustomerHistoryRoute(customerId: 'c1', source: 'pos')),
      isA<CustomerHistoryScreen>().having((s) => s.source, 'source', 'pos'),
    );
    expect(
      build(const CustomerReceivablesRoute(customerId: 'c1')),
      isA<CustomerReceivablesScreen>().having((s) => s.customerId, 'id', 'c1'),
    );
    expect(build(const CustomerDiscountsRoute(customerId: 'c1')), isA<CustomerDiscountsScreen>());
    expect(
      build(const FavoritesRoute(tab: 'customers')),
      isA<FavoritesScreen>().having((s) => s.tab, 'tab', 'customers'),
    );
    expect(
      build(const TransactionsRoute(mine: '1', kind: 'refund')),
      isA<TransactionsScreen>().having((s) => s.mine, 'mine', '1').having((s) => s.kind, 'kind', 'refund'),
    );
    expect(
      build(const TransactionRoute(transactionId: 't1')),
      isA<TransactionDetailsScreen>().having((s) => s.transactionId, 'id', 't1'),
    );
    expect(
      build(const PaymentNewRoute(orderId: 'o1', method: 'qr_bakai')),
      isA<PaymentScreen>().having((s) => s.orderId, 'orderId', 'o1').having((s) => s.method, 'method', 'qr_bakai'),
    );
    expect(
      build(const ReturnNewRoute(orderId: 'o1')),
      isA<ReturnRequestScreen>().having((s) => s.orderId, 'orderId', 'o1').having((s) => s.returnId, 'id', isNull),
    );
    expect(build(const ReturnRoute(returnId: 'r1')), isA<ReturnRequestScreen>().having((s) => s.returnId, 'id', 'r1'));
    expect(build(const ProfileRoute()), isA<ProfileScreen>());
    expect(
      build(const AdminUsersRoute(tab: 'links', userId: 'u1')),
      isA<AdminUsersScreen>()
          .having((s) => s.initialTab, 'tab', AdminUsersTab.links)
          .having((s) => s.initialUserId, 'userId', 'u1'),
    );
    expect(
      build(const AdminSettingsRoute(section: 's')),
      isA<AdminSettingsScreen>().having((s) => s.section, 's', 's'),
    );
    expect(build(const AdminAuditRoute(userId: 'u1')), isA<AuditScreen>().having((s) => s.userId, 'userId', 'u1'));
    expect(
      build(const ReportsRoute(report: 'qr', groupBy: 'day')),
      isA<ReportsScreen>().having((s) => s.report, 'report', 'qr').having((s) => s.groupBy, 'groupBy', 'day'),
    );
    for (final GoRouteData route in <GoRouteData>[
      const CashierRoute(),
      const CustomersRoute(),
      const CustomerRoute(customerId: 'c1'),
      const CustomerHistoryRoute(customerId: 'c1'),
      const CustomerReceivablesRoute(customerId: 'c1'),
      const CustomerDiscountsRoute(customerId: 'c1'),
      const FavoritesRoute(),
      const TransactionsRoute(),
      const TransactionRoute(transactionId: 't1'),
      const PaymentNewRoute(),
      const ReturnNewRoute(),
      const ReturnRoute(returnId: 'r1'),
      const ProfileRoute(),
      const AdminSettingsRoute(),
      const AdminAuditRoute(),
      const ReportsRoute(),
    ]) {
      expect(build(route), isNot(isA<RouteStubScreen>()), reason: route.runtimeType.toString());
    }
  });

  group('guards этапа G по ролям (02 §5, 11 §4.4)', () {
    test('owner: главный /reports; касса, клиенты, транзакции, аудит, SCR-45/46 (ограниченно), долг и история — да; '
        'оплата, создание возврата и клиента, корзина — нет', () {
      expect(homeLocationFor(appModeFor(kind: UserKind.staff, role: RoleCode.owner)), '/reports');
      for (final String path in <String>[
        '/reports',
        '/cashier',
        '/customers',
        '/customers/c1',
        '/customers/c1/history',
        '/customers/c1/receivables',
        '/customers/c1/discounts',
        '/transactions',
        '/transactions/t1',
        '/admin/audit',
        '/admin/users',
        '/admin/settings',
        '/returns/r1',
        '/favorites',
        '/catalog',
      ]) {
        expect(_redirect(RoleCode.owner, path), isNull, reason: 'owner $path');
      }
      for (final String path in <String>[
        '/payments/new?orderId=o1',
        '/returns/new?orderId=o1',
        '/customers/new',
        '/checkout',
        '/cart',
        '/cart/parked',
      ]) {
        expect(_redirect(RoleCode.owner, path), '/reports', reason: 'owner $path');
      }
    });

    test('admin: без SCR-38 (D-15); касса — просмотр, аудит, отчёты, настройки, возвраты — да', () {
      expect(_redirect(RoleCode.admin, '/payments/new?orderId=o1'), '/catalog');
      for (final String path in <String>[
        '/cashier',
        '/admin/settings',
        '/admin/audit',
        '/reports',
        '/returns/new?orderId=o1',
        '/customers/c1/receivables',
        '/transactions',
      ]) {
        expect(_redirect(RoleCode.admin, path), isNull, reason: 'admin $path');
      }
    });

    test('cashier: главный /cashier; оплата, возвраты, долги, история — да; админка и отчёты — нет', () {
      expect(homeLocationFor(appModeFor(kind: UserKind.staff, role: RoleCode.cashier)), '/cashier');
      for (final String path in <String>[
        '/cashier',
        '/payments/new?orderId=o1',
        '/returns/new?orderId=o1',
        '/customers/c1/receivables',
        '/customers/c1/history',
        '/transactions?mine=1',
      ]) {
        expect(_redirect(RoleCode.cashier, path), isNull, reason: 'cashier $path');
      }
      for (final String path in <String>['/admin/settings', '/admin/audit', '/reports']) {
        expect(_redirect(RoleCode.cashier, path), '/cashier', reason: 'cashier $path');
      }
    });

    test('seller: история и долги (суммы) клиента закрыты (Q-017), карточка и скидки — да; транзакции — свои', () {
      for (final String path in <String>[
        '/customers/c1/history',
        '/customers/c1/receivables',
        '/cashier',
        '/reports',
      ]) {
        expect(_redirect(RoleCode.seller, path), '/catalog', reason: 'seller $path');
      }
      for (final String path in <String>['/customers', '/customers/c1', '/customers/c1/discounts', '/transactions']) {
        expect(_redirect(RoleCode.seller, path), isNull, reason: 'seller $path');
      }
      expect(
        appRedirectNotice(
          status: SessionStatus.authenticated,
          uri: Uri.parse('/customers/c1/receivables'),
          mode: AppMode.seller,
          customerSelfService: true,
          role: RoleCode.seller,
        ),
        RoleGuardNotice.roleForbidden,
      );
    });

    test('AC-UI-30-004 seller: вкладки «Касса» нет; прямой переход на /cashier — guard G-7: главный экран роли и '
        '«Раздел недоступен для вашей роли» (navigation.md §4.1)', () {
      expect(sellerShellTabs.map((ShellTab t) => t.branch), isNot(contains(ShellBranch.cashier)));
      expect(_redirect(RoleCode.seller, '/cashier'), '/catalog');
      expect(
        appRedirectNotice(
          status: SessionStatus.authenticated,
          uri: Uri.parse('/cashier'),
          mode: AppMode.seller,
          customerSelfService: true,
          role: RoleCode.seller,
        ),
        RoleGuardNotice.roleForbidden,
      );
    });

    test('AC-UI-30-016 (compact, нижняя навигация): вкладки кассира — «Касса · Каталог · Клиенты · Транзакции · '
        'Профиль»', () {
      expect(cashierShellTabs.map((ShellTab t) => t.branch), <ShellBranch>[
        ShellBranch.cashier,
        ShellBranch.catalog,
        ShellBranch.customers,
        ShellBranch.transactions,
        ShellBranch.profile,
      ]);
    });

    test('customer (RM-G-014): своя карточка, долг, история, скидки — доступны (свой/confirmed проверяет сервер); '
        'касса, транзакции, оплата, возвраты — нет', () {
      for (final String path in <String>[
        '/customers/c1',
        '/customers/c1/receivables',
        '/customers/c1/history',
        '/customers/c1/discounts',
        '/profile',
        '/settings',
        '/notifications',
        '/orders/o1',
      ]) {
        expect(_redirect(RoleCode.customer, path), isNull, reason: 'customer $path');
      }
      for (final String path in <String>['/cashier', '/transactions', '/payments/new?orderId=o1', '/returns/r1']) {
        expect(_redirect(RoleCode.customer, path), '/home', reason: 'customer $path');
      }
    });
  });

  group('guards по флагам функций (G-8; RM-G-005, RM-G-013)', () {
    test('DEBT_PAYMENTS_FROM_POS=false (по умолчанию R1): режима SCR-38 «по долгу» нет; по заказу — есть', () {
      expect(_redirect(RoleCode.cashier, '/payments/new?customerId=c1'), '/cashier');
      expect(_redirect(RoleCode.seniorSeller, '/payments/new?customerId=c1'), '/catalog');
      expect(_redirect(RoleCode.cashier, '/payments/new?orderId=o1'), isNull);
      expect(
        appRedirectNotice(
          status: SessionStatus.authenticated,
          uri: Uri.parse('/payments/new?customerId=c1'),
          mode: AppMode.cashier,
          customerSelfService: true,
          role: RoleCode.cashier,
        ),
        isNull,
        reason: 'функция выключена, а не роль — без снекбара G-7',
      );
      const RouteFeatures on = RouteFeatures(debtPaymentsFromPos: true);
      expect(_redirect(RoleCode.cashier, '/payments/new?customerId=c1', features: on), isNull);
      expect(_redirect(RoleCode.admin, '/payments/new?customerId=c1', features: on), '/catalog', reason: 'D-15');
    });

    test('returns_enabled=false: /returns/* закрыты для всех ролей; до ответа сервера — не закрыты', () {
      const RouteFeatures off = RouteFeatures(returnsEnabled: false);
      for (final RoleCode role in <RoleCode>[RoleCode.cashier, RoleCode.seniorSeller, RoleCode.admin, RoleCode.owner]) {
        expect(_redirect(role, '/returns/r1', features: off), isNotNull, reason: role.value);
      }
      expect(_redirect(RoleCode.cashier, '/returns/new?orderId=o1', features: off), '/cashier');
      expect(_redirect(RoleCode.cashier, '/returns/new?orderId=o1'), isNull, reason: 'returnsEnabled неизвестен');
      expect(_redirect(RoleCode.cashier, '/returns/r1', features: const RouteFeatures(returnsEnabled: true)), isNull);
    });

    test('routeFeaturesFrom: returnsFromPos — только из ответа сервера; debtPaymentsFromPos — fail-closed', () {
      final AppConfig config = AppConfig(
        apiBaseUrl: Uri.parse('http://localhost:3000/api/v1'),
        environment: AppEnvironment.dev,
        logLevel: LogLevel.info,
        features: const <String, bool>{},
      );
      final RouteFeatures before = routeFeaturesFrom(PublicFeatureFlags.resolve(null, config));
      expect((before.returnsEnabled, before.debtPaymentsFromPos), (null, false));
      final RouteFeatures after = routeFeaturesFrom(
        PublicFeatureFlags.resolve(const PublicFeatures(returnsFromPos: false, debtPaymentsFromPos: false), config),
      );
      expect((after.returnsEnabled, after.debtPaymentsFromPos), (false, false));
    });
  });
}
