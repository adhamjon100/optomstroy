// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'routes.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [
  $splashRoute,
  $authPhoneRoute,
  $authOtpRoute,
  $authUnlockRoute,
  $registerRoute,
  $pendingActivationRoute,
  $customerNewRoute,
  $appShellRoute,
  $scanRoute,
  $checkoutRoute,
  $paymentNewRoute,
  $returnNewRoute,
  $returnRoute,
  $settingsRoute,
  $syncRoute,
  $notificationsRoute,
];

RouteBase get $splashRoute => GoRouteData.$route(
  path: '/splash',
  hasOverriddenOnExit: false,
  factory: $SplashRoute._fromState,
);

mixin $SplashRoute on GoRouteData {
  static SplashRoute _fromState(GoRouterState state) => const SplashRoute();

  @override
  String get location => GoRouteData.$location('/splash');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $authPhoneRoute => GoRouteData.$route(
  path: '/auth/phone',
  hasOverriddenOnExit: false,
  factory: $AuthPhoneRoute._fromState,
);

mixin $AuthPhoneRoute on GoRouteData {
  static AuthPhoneRoute _fromState(GoRouterState state) =>
      AuthPhoneRoute(returnTo: state.uri.queryParameters['returnTo']);

  AuthPhoneRoute get _self => this as AuthPhoneRoute;

  @override
  String get location => GoRouteData.$location(
    '/auth/phone',
    queryParams: {if (_self.returnTo != null) 'returnTo': _self.returnTo},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $authOtpRoute => GoRouteData.$route(
  path: '/auth/otp',
  hasOverriddenOnExit: false,
  factory: $AuthOtpRoute._fromState,
);

mixin $AuthOtpRoute on GoRouteData {
  static AuthOtpRoute _fromState(GoRouterState state) => const AuthOtpRoute();

  @override
  String get location => GoRouteData.$location('/auth/otp');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $authUnlockRoute => GoRouteData.$route(
  path: '/auth/unlock',
  hasOverriddenOnExit: false,
  factory: $AuthUnlockRoute._fromState,
);

mixin $AuthUnlockRoute on GoRouteData {
  static AuthUnlockRoute _fromState(GoRouterState state) =>
      const AuthUnlockRoute();

  @override
  String get location => GoRouteData.$location('/auth/unlock');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $registerRoute => GoRouteData.$route(
  path: '/register',
  hasOverriddenOnExit: false,
  factory: $RegisterRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: 'security',
      hasOverriddenOnExit: false,
      factory: $RegisterSecurityRoute._fromState,
    ),
    GoRouteData.$route(
      path: 'customer-link',
      hasOverriddenOnExit: false,
      factory: $RegisterCustomerLinkRoute._fromState,
    ),
  ],
);

mixin $RegisterRoute on GoRouteData {
  static RegisterRoute _fromState(GoRouterState state) => const RegisterRoute();

  @override
  String get location => GoRouteData.$location('/register');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $RegisterSecurityRoute on GoRouteData {
  static RegisterSecurityRoute _fromState(GoRouterState state) =>
      const RegisterSecurityRoute();

  @override
  String get location => GoRouteData.$location('/register/security');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $RegisterCustomerLinkRoute on GoRouteData {
  static RegisterCustomerLinkRoute _fromState(GoRouterState state) =>
      const RegisterCustomerLinkRoute();

  @override
  String get location => GoRouteData.$location('/register/customer-link');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $pendingActivationRoute => GoRouteData.$route(
  path: '/pending-activation',
  hasOverriddenOnExit: false,
  factory: $PendingActivationRoute._fromState,
);

mixin $PendingActivationRoute on GoRouteData {
  static PendingActivationRoute _fromState(GoRouterState state) =>
      const PendingActivationRoute();

  @override
  String get location => GoRouteData.$location('/pending-activation');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $customerNewRoute => GoRouteData.$route(
  path: '/customers/new',
  hasOverriddenOnExit: false,
  factory: $CustomerNewRoute._fromState,
);

mixin $CustomerNewRoute on GoRouteData {
  static CustomerNewRoute _fromState(GoRouterState state) =>
      CustomerNewRoute(returnTo: state.uri.queryParameters['returnTo']);

  CustomerNewRoute get _self => this as CustomerNewRoute;

  @override
  String get location => GoRouteData.$location(
    '/customers/new',
    queryParams: {if (_self.returnTo != null) 'returnTo': _self.returnTo},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $appShellRoute => StatefulShellRouteData.$route(
  factory: $AppShellRouteExtension._fromState,
  branches: [
    StatefulShellBranchData.$branch(
      routes: [
        GoRouteData.$route(
          path: '/catalog',
          hasOverriddenOnExit: false,
          factory: $CatalogRoute._fromState,
          routes: [
            GoRouteData.$route(
              path: 'search',
              hasOverriddenOnExit: false,
              factory: $CatalogSearchRoute._fromState,
            ),
            GoRouteData.$route(
              path: 'filters',
              hasOverriddenOnExit: false,
              factory: $CatalogFiltersRoute._fromState,
            ),
            GoRouteData.$route(
              path: 'c/:categoryId',
              hasOverriddenOnExit: false,
              factory: $CategoryRoute._fromState,
            ),
            GoRouteData.$route(
              path: 'p/:productId',
              hasOverriddenOnExit: false,
              factory: $ProductRoute._fromState,
            ),
          ],
        ),
      ],
    ),
    StatefulShellBranchData.$branch(
      routes: [
        GoRouteData.$route(
          path: '/home',
          hasOverriddenOnExit: false,
          factory: $HomeRoute._fromState,
        ),
      ],
    ),
    StatefulShellBranchData.$branch(
      routes: [
        GoRouteData.$route(
          path: '/favorites',
          hasOverriddenOnExit: false,
          factory: $FavoritesRoute._fromState,
        ),
      ],
    ),
    StatefulShellBranchData.$branch(
      routes: [
        GoRouteData.$route(
          path: '/cart',
          hasOverriddenOnExit: false,
          factory: $CartRoute._fromState,
          routes: [
            GoRouteData.$route(
              path: 'parked',
              hasOverriddenOnExit: false,
              factory: $CartParkedRoute._fromState,
            ),
          ],
        ),
      ],
    ),
    StatefulShellBranchData.$branch(
      routes: [
        GoRouteData.$route(
          path: '/customers',
          hasOverriddenOnExit: false,
          factory: $CustomersRoute._fromState,
          routes: [
            GoRouteData.$route(
              path: ':customerId',
              hasOverriddenOnExit: false,
              factory: $CustomerRoute._fromState,
              routes: [
                GoRouteData.$route(
                  path: 'history',
                  hasOverriddenOnExit: false,
                  factory: $CustomerHistoryRoute._fromState,
                ),
                GoRouteData.$route(
                  path: 'receivables',
                  hasOverriddenOnExit: false,
                  factory: $CustomerReceivablesRoute._fromState,
                ),
                GoRouteData.$route(
                  path: 'discounts',
                  hasOverriddenOnExit: false,
                  factory: $CustomerDiscountsRoute._fromState,
                ),
              ],
            ),
          ],
        ),
      ],
    ),
    StatefulShellBranchData.$branch(
      routes: [
        GoRouteData.$route(
          path: '/cashier',
          hasOverriddenOnExit: false,
          factory: $CashierRoute._fromState,
        ),
      ],
    ),
    StatefulShellBranchData.$branch(
      routes: [
        GoRouteData.$route(
          path: '/transactions',
          hasOverriddenOnExit: false,
          factory: $TransactionsRoute._fromState,
          routes: [
            GoRouteData.$route(
              path: ':transactionId',
              hasOverriddenOnExit: false,
              factory: $TransactionRoute._fromState,
            ),
          ],
        ),
      ],
    ),
    StatefulShellBranchData.$branch(
      routes: [
        GoRouteData.$route(
          path: '/orders',
          hasOverriddenOnExit: false,
          factory: $OrdersRoute._fromState,
          routes: [
            GoRouteData.$route(
              path: ':orderId',
              hasOverriddenOnExit: false,
              factory: $OrderRoute._fromState,
              routes: [
                GoRouteData.$route(
                  path: 'created',
                  hasOverriddenOnExit: false,
                  factory: $OrderCreatedRoute._fromState,
                ),
              ],
            ),
          ],
        ),
      ],
    ),
    StatefulShellBranchData.$branch(
      routes: [
        GoRouteData.$route(
          path: '/admin/users',
          hasOverriddenOnExit: false,
          factory: $AdminUsersRoute._fromState,
        ),
        GoRouteData.$route(
          path: '/admin/settings',
          hasOverriddenOnExit: false,
          factory: $AdminSettingsRoute._fromState,
        ),
        GoRouteData.$route(
          path: '/admin/audit',
          hasOverriddenOnExit: false,
          factory: $AdminAuditRoute._fromState,
        ),
      ],
    ),
    StatefulShellBranchData.$branch(
      routes: [
        GoRouteData.$route(
          path: '/profile',
          hasOverriddenOnExit: false,
          factory: $ProfileRoute._fromState,
        ),
      ],
    ),
    StatefulShellBranchData.$branch(
      routes: [
        GoRouteData.$route(
          path: '/reports',
          hasOverriddenOnExit: false,
          factory: $ReportsRoute._fromState,
        ),
      ],
    ),
  ],
);

extension $AppShellRouteExtension on AppShellRoute {
  static AppShellRoute _fromState(GoRouterState state) => const AppShellRoute();
}

mixin $CatalogRoute on GoRouteData {
  static CatalogRoute _fromState(GoRouterState state) => CatalogRoute(
    preset: state.uri.queryParameters['preset'],
    view: state.uri.queryParameters['view'],
    sort: state.uri.queryParameters['sort'],
  );

  CatalogRoute get _self => this as CatalogRoute;

  @override
  String get location => GoRouteData.$location(
    '/catalog',
    queryParams: {
      if (_self.preset != null) 'preset': _self.preset,
      if (_self.view != null) 'view': _self.view,
      if (_self.sort != null) 'sort': _self.sort,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $CatalogSearchRoute on GoRouteData {
  static CatalogSearchRoute _fromState(GoRouterState state) =>
      CatalogSearchRoute(
        q: state.uri.queryParameters['q'],
        categoryId: state.uri.queryParameters['categoryId'],
        view: state.uri.queryParameters['view'],
        sort: state.uri.queryParameters['sort'],
      );

  CatalogSearchRoute get _self => this as CatalogSearchRoute;

  @override
  String get location => GoRouteData.$location(
    '/catalog/search',
    queryParams: {
      if (_self.q != null) 'q': _self.q,
      if (_self.categoryId != null) 'categoryId': _self.categoryId,
      if (_self.view != null) 'view': _self.view,
      if (_self.sort != null) 'sort': _self.sort,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $CatalogFiltersRoute on GoRouteData {
  static CatalogFiltersRoute _fromState(GoRouterState state) =>
      CatalogFiltersRoute(
        f: state.uri.queryParameters['f'],
        q: state.uri.queryParameters['q'],
      );

  CatalogFiltersRoute get _self => this as CatalogFiltersRoute;

  @override
  String get location => GoRouteData.$location(
    '/catalog/filters',
    queryParams: {
      if (_self.f != null) 'f': _self.f,
      if (_self.q != null) 'q': _self.q,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $CategoryRoute on GoRouteData {
  static CategoryRoute _fromState(GoRouterState state) => CategoryRoute(
    categoryId: state.pathParameters['categoryId']!,
    view: state.uri.queryParameters['view'],
    sort: state.uri.queryParameters['sort'],
    f: state.uri.queryParameters['f'],
  );

  CategoryRoute get _self => this as CategoryRoute;

  @override
  String get location => GoRouteData.$location(
    '/catalog/c/${Uri.encodeComponent(_self.categoryId)}',
    queryParams: {
      if (_self.view != null) 'view': _self.view,
      if (_self.sort != null) 'sort': _self.sort,
      if (_self.f != null) 'f': _self.f,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $ProductRoute on GoRouteData {
  static ProductRoute _fromState(GoRouterState state) => ProductRoute(
    productId: state.pathParameters['productId']!,
    variantId: state.uri.queryParameters['variantId'],
    qty: state.uri.queryParameters['qty'],
  );

  ProductRoute get _self => this as ProductRoute;

  @override
  String get location => GoRouteData.$location(
    '/catalog/p/${Uri.encodeComponent(_self.productId)}',
    queryParams: {
      if (_self.variantId != null) 'variantId': _self.variantId,
      if (_self.qty != null) 'qty': _self.qty,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $HomeRoute on GoRouteData {
  static HomeRoute _fromState(GoRouterState state) => HomeRoute(
    view: state.uri.queryParameters['view'],
    sort: state.uri.queryParameters['sort'],
  );

  HomeRoute get _self => this as HomeRoute;

  @override
  String get location => GoRouteData.$location(
    '/home',
    queryParams: {
      if (_self.view != null) 'view': _self.view,
      if (_self.sort != null) 'sort': _self.sort,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $FavoritesRoute on GoRouteData {
  static FavoritesRoute _fromState(GoRouterState state) =>
      FavoritesRoute(tab: state.uri.queryParameters['tab']);

  FavoritesRoute get _self => this as FavoritesRoute;

  @override
  String get location => GoRouteData.$location(
    '/favorites',
    queryParams: {if (_self.tab != null) 'tab': _self.tab},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $CartRoute on GoRouteData {
  static CartRoute _fromState(GoRouterState state) =>
      CartRoute(cartId: state.uri.queryParameters['cartId']);

  CartRoute get _self => this as CartRoute;

  @override
  String get location => GoRouteData.$location(
    '/cart',
    queryParams: {if (_self.cartId != null) 'cartId': _self.cartId},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $CartParkedRoute on GoRouteData {
  static CartParkedRoute _fromState(GoRouterState state) =>
      const CartParkedRoute();

  @override
  String get location => GoRouteData.$location('/cart/parked');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $CustomersRoute on GoRouteData {
  static CustomersRoute _fromState(GoRouterState state) => CustomersRoute(
    q: state.uri.queryParameters['q'],
    favorites: state.uri.queryParameters['favorites'],
    withDebt: state.uri.queryParameters['withDebt'],
  );

  CustomersRoute get _self => this as CustomersRoute;

  @override
  String get location => GoRouteData.$location(
    '/customers',
    queryParams: {
      if (_self.q != null) 'q': _self.q,
      if (_self.favorites != null) 'favorites': _self.favorites,
      if (_self.withDebt != null) 'withDebt': _self.withDebt,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $CustomerRoute on GoRouteData {
  static CustomerRoute _fromState(GoRouterState state) => CustomerRoute(
    customerId: state.pathParameters['customerId']!,
    tab: state.uri.queryParameters['tab'],
  );

  CustomerRoute get _self => this as CustomerRoute;

  @override
  String get location => GoRouteData.$location(
    '/customers/${Uri.encodeComponent(_self.customerId)}',
    queryParams: {if (_self.tab != null) 'tab': _self.tab},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $CustomerHistoryRoute on GoRouteData {
  static CustomerHistoryRoute _fromState(GoRouterState state) =>
      CustomerHistoryRoute(
        customerId: state.pathParameters['customerId']!,
        from: state.uri.queryParameters['from'],
        to: state.uri.queryParameters['to'],
        source: state.uri.queryParameters['source'],
      );

  CustomerHistoryRoute get _self => this as CustomerHistoryRoute;

  @override
  String get location => GoRouteData.$location(
    '/customers/${Uri.encodeComponent(_self.customerId)}/history',
    queryParams: {
      if (_self.from != null) 'from': _self.from,
      if (_self.to != null) 'to': _self.to,
      if (_self.source != null) 'source': _self.source,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $CustomerReceivablesRoute on GoRouteData {
  static CustomerReceivablesRoute _fromState(GoRouterState state) =>
      CustomerReceivablesRoute(customerId: state.pathParameters['customerId']!);

  CustomerReceivablesRoute get _self => this as CustomerReceivablesRoute;

  @override
  String get location => GoRouteData.$location(
    '/customers/${Uri.encodeComponent(_self.customerId)}/receivables',
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $CustomerDiscountsRoute on GoRouteData {
  static CustomerDiscountsRoute _fromState(GoRouterState state) =>
      CustomerDiscountsRoute(customerId: state.pathParameters['customerId']!);

  CustomerDiscountsRoute get _self => this as CustomerDiscountsRoute;

  @override
  String get location => GoRouteData.$location(
    '/customers/${Uri.encodeComponent(_self.customerId)}/discounts',
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $CashierRoute on GoRouteData {
  static CashierRoute _fromState(GoRouterState state) => const CashierRoute();

  @override
  String get location => GoRouteData.$location('/cashier');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $TransactionsRoute on GoRouteData {
  static TransactionsRoute _fromState(GoRouterState state) => TransactionsRoute(
    from: state.uri.queryParameters['from'],
    to: state.uri.queryParameters['to'],
    customerId: state.uri.queryParameters['customerId'],
    status: state.uri.queryParameters['status'],
    kind: state.uri.queryParameters['kind'],
    paymentMethod: state.uri.queryParameters['paymentMethod'],
    actorId: state.uri.queryParameters['actorId'],
    q: state.uri.queryParameters['q'],
    mine: state.uri.queryParameters['mine'],
  );

  TransactionsRoute get _self => this as TransactionsRoute;

  @override
  String get location => GoRouteData.$location(
    '/transactions',
    queryParams: {
      if (_self.from != null) 'from': _self.from,
      if (_self.to != null) 'to': _self.to,
      if (_self.customerId != null) 'customerId': _self.customerId,
      if (_self.status != null) 'status': _self.status,
      if (_self.kind != null) 'kind': _self.kind,
      if (_self.paymentMethod != null) 'paymentMethod': _self.paymentMethod,
      if (_self.actorId != null) 'actorId': _self.actorId,
      if (_self.q != null) 'q': _self.q,
      if (_self.mine != null) 'mine': _self.mine,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $TransactionRoute on GoRouteData {
  static TransactionRoute _fromState(GoRouterState state) =>
      TransactionRoute(transactionId: state.pathParameters['transactionId']!);

  TransactionRoute get _self => this as TransactionRoute;

  @override
  String get location => GoRouteData.$location(
    '/transactions/${Uri.encodeComponent(_self.transactionId)}',
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $OrdersRoute on GoRouteData {
  static OrdersRoute _fromState(GoRouterState state) => OrdersRoute(
    status: state.uri.queryParameters['status'],
    from: state.uri.queryParameters['from'],
    to: state.uri.queryParameters['to'],
    customerId: state.uri.queryParameters['customerId'],
    mine: state.uri.queryParameters['mine'],
  );

  OrdersRoute get _self => this as OrdersRoute;

  @override
  String get location => GoRouteData.$location(
    '/orders',
    queryParams: {
      if (_self.status != null) 'status': _self.status,
      if (_self.from != null) 'from': _self.from,
      if (_self.to != null) 'to': _self.to,
      if (_self.customerId != null) 'customerId': _self.customerId,
      if (_self.mine != null) 'mine': _self.mine,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $OrderRoute on GoRouteData {
  static OrderRoute _fromState(GoRouterState state) =>
      OrderRoute(orderId: state.pathParameters['orderId']!);

  OrderRoute get _self => this as OrderRoute;

  @override
  String get location =>
      GoRouteData.$location('/orders/${Uri.encodeComponent(_self.orderId)}');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $OrderCreatedRoute on GoRouteData {
  static OrderCreatedRoute _fromState(GoRouterState state) => OrderCreatedRoute(
    orderId: state.pathParameters['orderId']!,
    paymentId: state.uri.queryParameters['paymentId'],
  );

  OrderCreatedRoute get _self => this as OrderCreatedRoute;

  @override
  String get location => GoRouteData.$location(
    '/orders/${Uri.encodeComponent(_self.orderId)}/created',
    queryParams: {if (_self.paymentId != null) 'paymentId': _self.paymentId},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $AdminUsersRoute on GoRouteData {
  static AdminUsersRoute _fromState(GoRouterState state) => AdminUsersRoute(
    tab: state.uri.queryParameters['tab'],
    userId: state.uri.queryParameters['userId'],
  );

  AdminUsersRoute get _self => this as AdminUsersRoute;

  @override
  String get location => GoRouteData.$location(
    '/admin/users',
    queryParams: {
      if (_self.tab != null) 'tab': _self.tab,
      if (_self.userId != null) 'userId': _self.userId,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $AdminSettingsRoute on GoRouteData {
  static AdminSettingsRoute _fromState(GoRouterState state) =>
      AdminSettingsRoute(section: state.uri.queryParameters['section']);

  AdminSettingsRoute get _self => this as AdminSettingsRoute;

  @override
  String get location => GoRouteData.$location(
    '/admin/settings',
    queryParams: {if (_self.section != null) 'section': _self.section},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $AdminAuditRoute on GoRouteData {
  static AdminAuditRoute _fromState(GoRouterState state) => AdminAuditRoute(
    from: state.uri.queryParameters['from'],
    to: state.uri.queryParameters['to'],
    userId: state.uri.queryParameters['userId'],
    action: state.uri.queryParameters['action'],
    entityType: state.uri.queryParameters['entityType'],
    entityId: state.uri.queryParameters['entityId'],
    result: state.uri.queryParameters['result'],
  );

  AdminAuditRoute get _self => this as AdminAuditRoute;

  @override
  String get location => GoRouteData.$location(
    '/admin/audit',
    queryParams: {
      if (_self.from != null) 'from': _self.from,
      if (_self.to != null) 'to': _self.to,
      if (_self.userId != null) 'userId': _self.userId,
      if (_self.action != null) 'action': _self.action,
      if (_self.entityType != null) 'entityType': _self.entityType,
      if (_self.entityId != null) 'entityId': _self.entityId,
      if (_self.result != null) 'result': _self.result,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $ProfileRoute on GoRouteData {
  static ProfileRoute _fromState(GoRouterState state) => const ProfileRoute();

  @override
  String get location => GoRouteData.$location('/profile');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $ReportsRoute on GoRouteData {
  static ReportsRoute _fromState(GoRouterState state) => ReportsRoute(
    from: state.uri.queryParameters['from'],
    to: state.uri.queryParameters['to'],
    report: state.uri.queryParameters['report'],
    groupBy: state.uri.queryParameters['groupBy'],
  );

  ReportsRoute get _self => this as ReportsRoute;

  @override
  String get location => GoRouteData.$location(
    '/reports',
    queryParams: {
      if (_self.from != null) 'from': _self.from,
      if (_self.to != null) 'to': _self.to,
      if (_self.report != null) 'report': _self.report,
      if (_self.groupBy != null) 'groupBy': _self.groupBy,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $scanRoute => GoRouteData.$route(
  path: '/scan',
  hasOverriddenOnExit: false,
  factory: $ScanRoute._fromState,
);

mixin $ScanRoute on GoRouteData {
  static ScanRoute _fromState(GoRouterState state) =>
      ScanRoute(mode: state.uri.queryParameters['mode']);

  ScanRoute get _self => this as ScanRoute;

  @override
  String get location => GoRouteData.$location(
    '/scan',
    queryParams: {if (_self.mode != null) 'mode': _self.mode},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $checkoutRoute => GoRouteData.$route(
  path: '/checkout',
  hasOverriddenOnExit: false,
  factory: $CheckoutRoute._fromState,
);

mixin $CheckoutRoute on GoRouteData {
  static CheckoutRoute _fromState(GoRouterState state) => CheckoutRoute(
    cartId: state.uri.queryParameters['cartId'],
    step: state.uri.queryParameters['step'],
  );

  CheckoutRoute get _self => this as CheckoutRoute;

  @override
  String get location => GoRouteData.$location(
    '/checkout',
    queryParams: {
      if (_self.cartId != null) 'cartId': _self.cartId,
      if (_self.step != null) 'step': _self.step,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $paymentNewRoute => GoRouteData.$route(
  path: '/payments/new',
  hasOverriddenOnExit: false,
  factory: $PaymentNewRoute._fromState,
);

mixin $PaymentNewRoute on GoRouteData {
  static PaymentNewRoute _fromState(GoRouterState state) => PaymentNewRoute(
    orderId: state.uri.queryParameters['orderId'],
    customerId: state.uri.queryParameters['customerId'],
    method: state.uri.queryParameters['method'],
  );

  PaymentNewRoute get _self => this as PaymentNewRoute;

  @override
  String get location => GoRouteData.$location(
    '/payments/new',
    queryParams: {
      if (_self.orderId != null) 'orderId': _self.orderId,
      if (_self.customerId != null) 'customerId': _self.customerId,
      if (_self.method != null) 'method': _self.method,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $returnNewRoute => GoRouteData.$route(
  path: '/returns/new',
  hasOverriddenOnExit: false,
  factory: $ReturnNewRoute._fromState,
);

mixin $ReturnNewRoute on GoRouteData {
  static ReturnNewRoute _fromState(GoRouterState state) =>
      ReturnNewRoute(orderId: state.uri.queryParameters['orderId']);

  ReturnNewRoute get _self => this as ReturnNewRoute;

  @override
  String get location => GoRouteData.$location(
    '/returns/new',
    queryParams: {if (_self.orderId != null) 'orderId': _self.orderId},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $returnRoute => GoRouteData.$route(
  path: '/returns/:returnId',
  hasOverriddenOnExit: false,
  factory: $ReturnRoute._fromState,
);

mixin $ReturnRoute on GoRouteData {
  static ReturnRoute _fromState(GoRouterState state) =>
      ReturnRoute(returnId: state.pathParameters['returnId']!);

  ReturnRoute get _self => this as ReturnRoute;

  @override
  String get location =>
      GoRouteData.$location('/returns/${Uri.encodeComponent(_self.returnId)}');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $settingsRoute => GoRouteData.$route(
  path: '/settings',
  hasOverriddenOnExit: false,
  factory: $SettingsRoute._fromState,
);

mixin $SettingsRoute on GoRouteData {
  static SettingsRoute _fromState(GoRouterState state) =>
      SettingsRoute(section: state.uri.queryParameters['section']);

  SettingsRoute get _self => this as SettingsRoute;

  @override
  String get location => GoRouteData.$location(
    '/settings',
    queryParams: {if (_self.section != null) 'section': _self.section},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $syncRoute => GoRouteData.$route(
  path: '/sync',
  hasOverriddenOnExit: false,
  factory: $SyncRoute._fromState,
);

mixin $SyncRoute on GoRouteData {
  static SyncRoute _fromState(GoRouterState state) => SyncRoute(
    entity: state.uri.queryParameters['entity'],
    runId: state.uri.queryParameters['runId'],
    tab: state.uri.queryParameters['tab'],
  );

  SyncRoute get _self => this as SyncRoute;

  @override
  String get location => GoRouteData.$location(
    '/sync',
    queryParams: {
      if (_self.entity != null) 'entity': _self.entity,
      if (_self.runId != null) 'runId': _self.runId,
      if (_self.tab != null) 'tab': _self.tab,
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $notificationsRoute => GoRouteData.$route(
  path: '/notifications',
  hasOverriddenOnExit: false,
  factory: $NotificationsRoute._fromState,
);

mixin $NotificationsRoute on GoRouteData {
  static NotificationsRoute _fromState(GoRouterState state) =>
      NotificationsRoute(unread: state.uri.queryParameters['unread']);

  NotificationsRoute get _self => this as NotificationsRoute;

  @override
  String get location => GoRouteData.$location(
    '/notifications',
    queryParams: {if (_self.unread != null) 'unread': _self.unread},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}
