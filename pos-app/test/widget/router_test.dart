import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/guards/auth_guard.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';

/// Маршруты карты экранов ядра R0 §9, зарегистрированные в R1-сборке
/// (без SCR-05 `/register/face-scan` — R2; листы SCR-15/16 и overlay SCR-90 без маршрута).
const Set<String> kernelPaths = <String>{
  '/splash',
  '/auth/phone',
  '/auth/otp',
  '/auth/unlock',
  '/register',
  '/register/security',
  '/register/customer-link',
  '/pending-activation',
  '/catalog',
  '/catalog/search',
  '/catalog/filters',
  '/catalog/c/:categoryId',
  '/catalog/p/:productId',
  '/scan',
  '/cart',
  '/cart/parked',
  '/checkout',
  '/orders',
  '/orders/:orderId',
  '/orders/:orderId/created',
  '/customers',
  '/customers/new',
  '/customers/:customerId',
  '/customers/:customerId/history',
  '/customers/:customerId/receivables',
  '/customers/:customerId/discounts',
  '/cashier',
  '/transactions',
  '/transactions/:transactionId',
  '/payments/new',
  '/returns/new',
  '/returns/:returnId',
  '/favorites',
  '/profile',
  '/settings',
  '/sync',
  '/notifications',
  '/admin/users',
  '/admin/settings',
  '/admin/audit',
  '/reports',
  '/home',
};

void _collect(List<RouteBase> routes, String parent, Set<String> out) {
  for (final route in routes) {
    if (route is GoRoute) {
      final full = route.path.startsWith('/') ? route.path : '${parent == '/' ? '' : parent}/${route.path}';
      out.add(full);
      _collect(route.routes, full, out);
    } else {
      _collect(route.routes, parent, out);
    }
  }
}

void main() {
  test('маршруты совпадают с картой ядра R0 §9', () {
    final paths = <String>{};
    _collect($appRoutes, '', paths);
    expect(paths, kernelPaths);
  });

  test('порядок веток оболочки совпадает с ShellBranch', () {
    final shell = $appRoutes.whereType<StatefulShellRoute>().single;
    const roots = <ShellBranch, String>{
      ShellBranch.catalog: '/catalog',
      ShellBranch.home: '/home',
      ShellBranch.favorites: '/favorites',
      ShellBranch.cart: '/cart',
      ShellBranch.customers: '/customers',
      ShellBranch.cashier: '/cashier',
      ShellBranch.transactions: '/transactions',
      ShellBranch.orders: '/orders',
      ShellBranch.admin: '/admin/users',
      ShellBranch.profile: '/profile',
      ShellBranch.reports: '/reports',
    };
    expect(shell.branches, hasLength(ShellBranch.values.length));
    for (final branch in ShellBranch.values) {
      final first = shell.branches[branch.index].routes.first as GoRoute;
      expect(first.path, roots[branch], reason: branch.name);
    }
  });

  test('у каждого режима 5 вкладок по R0 §9', () {
    expect(shellTabsFor(AppMode.seller).map((t) => t.branch), <ShellBranch>[
      ShellBranch.catalog,
      ShellBranch.favorites,
      ShellBranch.cart,
      ShellBranch.customers,
      ShellBranch.profile,
    ]);
    expect(shellTabsFor(AppMode.cashier).map((t) => t.branch), <ShellBranch>[
      ShellBranch.cashier,
      ShellBranch.catalog,
      ShellBranch.customers,
      ShellBranch.transactions,
      ShellBranch.profile,
    ]);
    expect(shellTabsFor(AppMode.admin).map((t) => t.branch), <ShellBranch>[
      ShellBranch.catalog,
      ShellBranch.customers,
      ShellBranch.transactions,
      ShellBranch.admin,
      ShellBranch.profile,
    ]);
    // Этап G: owner — «Каталог · Клиенты · Транзакции · Отчёты · Профиль» (navigation.md §2.1, §14.7).
    expect(shellTabsFor(AppMode.owner).map((t) => t.branch), <ShellBranch>[
      ShellBranch.catalog,
      ShellBranch.customers,
      ShellBranch.transactions,
      ShellBranch.reports,
      ShellBranch.profile,
    ]);
    expect(shellTabsFor(AppMode.customer).map((t) => t.branch), <ShellBranch>[
      ShellBranch.home,
      ShellBranch.favorites,
      ShellBranch.cart,
      ShellBranch.orders,
      ShellBranch.profile,
    ]);
  });

  group('authRedirect', () {
    String? redirect(SessionStatus status, String location) =>
        authRedirect(status: status, uri: Uri.parse(location), homeLocation: '/catalog');

    test('пока сессия восстанавливается — Splash', () {
      expect(redirect(SessionStatus.unknown, '/splash'), isNull);
      expect(redirect(SessionStatus.unknown, '/cart'), '/splash');
    });

    test(
      'после восстановления на /splash решение принимает SplashScreen (02 SCR-00.6, AU-05) — redirect не уводит',
      () {
        expect(redirect(SessionStatus.unauthenticated, '/splash'), isNull);
        expect(redirect(SessionStatus.authenticated, '/splash'), isNull);
      },
    );

    test('SCR-08 /auth/unlock — публичный маршрут (холодный старт под блокировкой)', () {
      expect(redirect(SessionStatus.unauthenticated, '/auth/unlock?mode=cold'), isNull);
    });

    test('защищённый маршрут без сессии — вход с returnTo', () {
      expect(redirect(SessionStatus.unauthenticated, '/orders/42'), '/auth/phone?returnTo=%2Forders%2F42');
      expect(redirect(SessionStatus.unauthenticated, '/register/security'), isNull);
      expect(redirect(SessionStatus.authenticated, '/orders/42'), isNull);
    });

    // G-5 (navigation.md §4.1): холодный старт сразу на внутреннем адресе (deep link; веб-демо — F5 на `#/cashier`,
    // uiA-01/B-01) ведёт на SCR-08 `cold` с возвратом, а не на рабочий экран под невидимой блокировкой.
    test('G-5: сессия заблокирована холодным стартом — SCR-08 cold с from=<адрес>', () {
      String? cold(String location) => authRedirect(
        status: SessionStatus.authenticated,
        uri: Uri.parse(location),
        homeLocation: '/catalog',
        lock: SessionLockReason.coldStart,
      );
      expect(cold('/cashier'), '/auth/unlock?mode=cold&from=%2Fcashier');
      expect(cold('/catalog/search?q=G9259'), '/auth/unlock?mode=cold&from=%2Fcatalog%2Fsearch%3Fq%3DG9259');
      expect(Uri.parse(cold('/orders/42')!).queryParameters, <String, String>{'mode': 'cold', 'from': '/orders/42'});
      // SCR-08 сам, Splash и публичные экраны («Войти по номеру телефона» с SCR-08) не перенаправляются.
      expect(cold('/auth/unlock?mode=cold'), isNull);
      expect(cold('/splash'), isNull);
      expect(cold('/auth/phone'), isNull);
      // Idle/ручная блокировка — overlay поверх экрана (§4.3), redirect путь не меняет.
      for (final SessionLockReason reason in <SessionLockReason>[
        SessionLockReason.idle,
        SessionLockReason.manual,
        SessionLockReason.background,
        SessionLockReason.unlockRequired,
      ]) {
        expect(
          authRedirect(
            status: SessionStatus.authenticated,
            uri: Uri.parse('/cashier'),
            homeLocation: '/catalog',
            lock: reason,
          ),
          isNull,
          reason: reason.name,
        );
      }
    });

    test('G-5 раньше roleGuard: под блокировкой холодного старта нет снекбара «Раздел недоступен»', () {
      // До разблокировки роль неизвестна (режим по умолчанию — продавец), `/cashier` продавцу недоступен.
      expect(
        appRedirect(
          status: SessionStatus.authenticated,
          uri: Uri.parse('/cashier'),
          mode: AppMode.seller,
          customerSelfService: true,
          lock: SessionLockReason.coldStart,
        ),
        '/auth/unlock?mode=cold&from=%2Fcashier',
      );
      expect(
        appRedirectNotice(
          status: SessionStatus.authenticated,
          uri: Uri.parse('/cashier'),
          mode: AppMode.seller,
          customerSelfService: true,
          lock: SessionLockReason.coldStart,
        ),
        isNull,
      );
    });
  });

  test(
    'режим оболочки по сессии: customer → customer, cashier → касса, admin → админ, owner → руководитель, прочие → продавец',
    () {
      expect(appModeFor(kind: UserKind.customer), AppMode.customer);
      expect(appModeFor(kind: UserKind.staff, role: RoleCode.cashier), AppMode.cashier);
      expect(appModeFor(kind: UserKind.staff, role: RoleCode.admin), AppMode.admin);
      expect(appModeFor(kind: UserKind.staff, role: RoleCode.seniorSeller), AppMode.seller);
      expect(appModeFor(kind: UserKind.staff, role: RoleCode.owner), AppMode.owner);
      expect(homeLocationFor(AppMode.owner), '/reports');
      expect(appModeFor(), AppMode.seller);
      expect(homeLocationFor(appModeFor(kind: UserKind.customer)), '/home');
      expect(homeLocationFor(appModeFor(kind: UserKind.staff, role: RoleCode.cashier)), '/cashier');
    },
  );

  test('типизированные маршруты строят адреса R0 §9', () {
    expect(const PaymentNewRoute(orderId: 'o1').location, '/payments/new?orderId=o1');
    expect(const CatalogSearchRoute(q: 'цемент').location, '/catalog/search?q=%D1%86%D0%B5%D0%BC%D0%B5%D0%BD%D1%82');
    expect(const CustomerReceivablesRoute(customerId: 'c1').location, '/customers/c1/receivables');
    expect(const OrderCreatedRoute(orderId: 'o1').location, '/orders/o1/created');
  });
}
