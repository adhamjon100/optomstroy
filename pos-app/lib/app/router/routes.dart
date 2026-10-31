// Типизированные маршруты go_router_builder по карте экранов ядра R0 §9 (06 §6.4).
//
// Каркас RM-C-002: экраны без реализации показывают RouteStubScreen с ID экрана.
// Фича, реализующая экран, меняет только тело build(...) своего класса маршрута.
// Параметры — только path/query, `$extra` не используется (06 §6.4).
// Не зарегистрированы: SCR-05 `/register/face-scan` (R2, только при
// FEATURE_FACE_SCAN=true, D-14); SCR-15/16 — листы без маршрута; SCR-90 — overlay.
// Этап E: маршруты SCR-10…SCR-14, SCR-17, SCR-42, SCR-43, SCR-50 ведут на экраны фич
// (`features/<f>/presentation/screens/*_screen.dart`) с параметрами по 02 §4.1; доступ по роли —
// guards/role_guard.dart (staff / customer, 02 §4.1, navigation.md G-7/G-8).
// Этап F (основа): SCR-20…SCR-26, SCR-44 ведут на экраны-заглушки фич с фиксированными именами классов и
// параметрами 02 §4.1 (`/cart?cartId=`, `/checkout?cartId=&step=`, `/orders/{id}/created?paymentId=`,
// `/orders?status=&from=&to=&customerId=&mine=`, `/customers/new?returnTo=`, `/notifications?unread=1`);
// реализации меняют только тело экранов. SCR-13 получил `q` (EQ-CAT-12).
// Этап G (основа): SCR-30…SCR-41, SCR-45…SCR-48 ведут на экраны фич с фиксированными именами классов и
// параметрами 02 §4.1 (`/customers?q=&favorites=1&withDebt=1`, `/customers/{id}?tab=`,
// `/customers/{id}/history?from=&to=&source=`, `/transactions?from=&to=&customerId=&status=&kind=&paymentMethod=
// &actorId=&q=&mine=`, `/payments/new?orderId=&method=|customerId=`, `/favorites?tab=`, `/admin/users?tab=&userId=`,
// `/admin/settings?section=`, `/admin/audit?from=&to=&userId=&action=&entityType=&entityId=&result=`,
// `/reports?from=&to=&report=&groupBy=`); `/reports` — ветка оболочки `reports` (главный экран `owner`,
// navigation.md §2.2, §14.7). Реализации меняют только тело экранов.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/catalog_family.dart';
import 'package:optomstroy/app/router/panel_page.dart';
import 'package:optomstroy/app/router/pass_through_page.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/app/router/window_class_scope.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/admin/presentation/audit/audit_screen.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_screen.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_users_screen.dart';
import 'package:optomstroy/features/auth/auth_providers.dart'
    show AuthSessionState, AuthSessionStatus, authSessionProvider;
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/unlock_screen.dart';
import 'package:optomstroy/features/cart/presentation/screens/cart_screen.dart';
import 'package:optomstroy/features/cart/presentation/screens/parked_carts_screen.dart';
import 'package:optomstroy/features/cashier/presentation/screens/cashier_dashboard_screen.dart';
import 'package:optomstroy/features/cashier/presentation/screens/payment_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_filters_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_search_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/category_screen.dart';
import 'package:optomstroy/features/checkout/presentation/screens/checkout_screen.dart';
import 'package:optomstroy/features/checkout/presentation/screens/order_created_screen.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_card_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_discounts_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_history_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_receivables_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customers_search_screen.dart';
import 'package:optomstroy/features/favorites/presentation/screens/favorites_screen.dart';
import 'package:optomstroy/features/home/presentation/screens/customer_home_screen.dart';
import 'package:optomstroy/features/notifications/presentation/screens/notifications_screen.dart';
import 'package:optomstroy/features/orders/presentation/screens/order_details_screen.dart';
import 'package:optomstroy/features/orders/presentation/screens/orders_screen.dart';
import 'package:optomstroy/features/product_details/presentation/screens/product_details_screen.dart';
import 'package:optomstroy/features/profile/presentation/screens/profile_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/customer_link_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/pending_activation_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_form_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_security_screen.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';
import 'package:optomstroy/features/reports/presentation/screens/reports_screen.dart';
import 'package:optomstroy/features/returns/presentation/screens/return_request_screen.dart';
import 'package:optomstroy/features/scan/presentation/screens/scan_screen.dart';
import 'package:optomstroy/features/settings/presentation/screens/settings_screen.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';
import 'package:optomstroy/features/sync_status/presentation/screens/sync_status_screen.dart';
import 'package:optomstroy/features/transactions/presentation/screens/transaction_details_screen.dart';
import 'package:optomstroy/features/transactions/presentation/screens/transactions_screen.dart';

part 'routes.g.dart';

// ---------------------------------------------------------------------------
// Вне оболочки: запуск, вход, регистрация
// ---------------------------------------------------------------------------

/// SCR-00 Splash.
@TypedGoRoute<SplashRoute>(path: '/splash')
class SplashRoute extends GoRouteData with $SplashRoute {
  /// Маршрут `/splash`.
  const SplashRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const SplashScreen();
}

/// SCR-01 Вход: ввод телефона (PhoneScreen, RM-D-007; класс-обёртка NoSessionScreen сохранён для RM-C-014).
@TypedGoRoute<AuthPhoneRoute>(path: '/auth/phone')
class AuthPhoneRoute extends GoRouteData with $AuthPhoneRoute {
  /// Маршрут `/auth/phone?returnTo=`.
  const AuthPhoneRoute({@TypedQueryParameter<String>(name: 'returnTo') this.returnTo});

  /// Адрес, на который вернуться после входа (authGuard, 06 §6.4).
  final String? returnTo;

  @override
  Widget build(BuildContext context, GoRouterState state) => const NoSessionScreen();
}

/// SCR-02 Подтверждение OTP.
@TypedGoRoute<AuthOtpRoute>(path: '/auth/otp')
class AuthOtpRoute extends GoRouteData with $AuthOtpRoute {
  /// Маршрут `/auth/otp`.
  const AuthOtpRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const OtpScreen();
}

/// SCR-08 Быстрый вход (биометрия/PIN).
@TypedGoRoute<AuthUnlockRoute>(path: '/auth/unlock')
class AuthUnlockRoute extends GoRouteData with $AuthUnlockRoute {
  /// Маршрут `/auth/unlock?mode=cold|idle&from=` (параметры читает экран из query).
  const AuthUnlockRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => UnlockScreen.fromRoute(context);
}

/// SCR-03 Регистрация: форма.
@TypedGoRoute<RegisterRoute>(
  path: '/register',
  routes: <TypedRoute<RouteData>>[
    TypedGoRoute<RegisterSecurityRoute>(path: 'security'),
    TypedGoRoute<RegisterCustomerLinkRoute>(path: 'customer-link'),
  ],
)
class RegisterRoute extends GoRouteData with $RegisterRoute {
  /// Маршрут `/register`.
  const RegisterRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      _RegisterFormEntry(leaf: state.uri.path == state.matchedLocation);
}

/// SCR-04 Регистрация: защита входа + согласие.
class RegisterSecurityRoute extends GoRouteData with $RegisterSecurityRoute {
  /// Маршрут `/register/security`.
  const RegisterSecurityRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const _RegisterSecurityEntry();
}

/// SCR-06 Привязка к клиенту 1С (CUSTOMER_SELF_SERVICE=true по умолчанию).
class RegisterCustomerLinkRoute extends GoRouteData with $RegisterCustomerLinkRoute {
  /// Маршрут `/register/customer-link`.
  const RegisterCustomerLinkRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const CustomerLinkScreen();
}

/// SCR-03 — нижняя страница стека `/register/*`. Первый вход сотрудника по приглашению идёт сразу на
/// `/register/security` без `registration_token` (RM-D-017): форму клиента под ним не строим — иначе её guard G-2
/// («нет билета → SCR-01») увёл бы сотрудника со SCR-04.
class _RegisterFormEntry extends ConsumerWidget {
  const _RegisterFormEntry({required this.leaf});

  /// `/register` — текущий экран (а не подложка под `/register/security`, `/register/customer-link`).
  final bool leaf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!leaf && ref.watch(registrationTicketProvider) == null) {
      return const SizedBox.shrink();
    }
    return const RegistrationFormScreen();
  }
}

/// SCR-04 в двух режимах (02 SCR-02.6, D_spec_questions AU-10): сотрудник по приглашению без PIN
/// (`nextStep=set_pin` → `authSessionProvider.pinSetupRequired`) — «первый вход сотрудника» без формы SCR-03
/// (ядро §24.2, RM-D-017); иначе — шаг «Защита входа» регистрации клиента.
/// Режим фиксируется при открытии экрана: после установки PIN навигатор переводит профиль в `signedIn`,
/// и экран не должен перестраиваться в режим клиента до ухода с маршрута.
/// Подзаголовок «Вы вошли по приглашению администратора» — только при `roleSource: invitation` (02 SCR-02.6);
/// сотрудник без PIN по другой причине (сброс PIN, Q-323 — тот же экран) его не видит.
class _RegisterSecurityEntry extends ConsumerStatefulWidget {
  const _RegisterSecurityEntry();

  @override
  ConsumerState<_RegisterSecurityEntry> createState() => _RegisterSecurityEntryState();
}

class _RegisterSecurityEntryState extends ConsumerState<_RegisterSecurityEntry> {
  late final AuthSessionState _session = ref.read(authSessionProvider);
  late final RegistrationAudience _audience = _session.status == AuthSessionStatus.pinSetupRequired
      ? RegistrationAudience.staffFirstLogin
      : RegistrationAudience.customer;

  @override
  Widget build(BuildContext context) =>
      RegistrationSecurityScreen(audience: _audience, staffViaInvitation: _session.viaInvitation);
}

/// SCR-07 Ожидает активации.
@TypedGoRoute<PendingActivationRoute>(path: '/pending-activation')
class PendingActivationRoute extends GoRouteData with $PendingActivationRoute {
  /// Маршрут `/pending-activation`.
  const PendingActivationRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const PendingActivationScreen();
}

/// SCR-26 Новый клиент (staff: `customer.create`) — маршрут вне оболочки (02 §4.1 п. 2, navigation.md §3: root, compact —
/// полноэкранно, medium/expanded — поверх родителя): вызывается `push` из SCR-21 `/checkout` (root) и SCR-20/SCR-31
/// (оболочка). Внутри ветки «Клиенты» `push` из root-маршрута поверх оболочки дублировал страницу оболочки
/// (`!keyReservation.contains(key)` в Navigator). Объявлен раньше оболочки: путь совпадает с шаблоном
/// `/customers/:customerId` ветки, go_router выбирает первый подходящий маршрут.
@TypedGoRoute<CustomerNewRoute>(path: '/customers/new')
class CustomerNewRoute extends GoRouteData with $CustomerNewRoute {
  /// Маршрут `/customers/new?returnTo=checkout`.
  const CustomerNewRoute({@TypedQueryParameter<String>(name: 'returnTo') this.returnTo});

  /// Куда вернуться после создания (`checkout` — SCR-21 с выбранным клиентом).
  final String? returnTo;

  @override
  Widget build(BuildContext context, GoRouterState state) => NewCustomerScreen(returnTo: returnTo);
}

// ---------------------------------------------------------------------------
// Оболочка: один StatefulShellRoute, ветки = объединение вкладок всех режимов
// (порядок веток = ShellBranch, shells/shell_tab.dart)
// ---------------------------------------------------------------------------

/// Оболочка с ветками режимов seller / cashier / admin / customer (R0 §9).
@TypedStatefulShellRoute<AppShellRoute>(
  branches: <TypedStatefulShellBranch<StatefulShellBranchData>>[
    TypedStatefulShellBranch<CatalogBranch>(
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<CatalogRoute>(
          path: '/catalog',
          routes: <TypedRoute<RouteData>>[
            TypedGoRoute<CatalogSearchRoute>(path: 'search'),
            TypedGoRoute<CatalogFiltersRoute>(path: 'filters'),
            TypedGoRoute<CategoryRoute>(path: 'c/:categoryId'),
            TypedGoRoute<ProductRoute>(path: 'p/:productId'),
          ],
        ),
      ],
    ),
    TypedStatefulShellBranch<HomeBranch>(routes: <TypedRoute<RouteData>>[TypedGoRoute<HomeRoute>(path: '/home')]),
    TypedStatefulShellBranch<FavoritesBranch>(
      routes: <TypedRoute<RouteData>>[TypedGoRoute<FavoritesRoute>(path: '/favorites')],
    ),
    TypedStatefulShellBranch<CartBranch>(
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<CartRoute>(
          path: '/cart',
          routes: <TypedRoute<RouteData>>[TypedGoRoute<CartParkedRoute>(path: 'parked')],
        ),
      ],
    ),
    TypedStatefulShellBranch<CustomersBranch>(
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<CustomersRoute>(
          path: '/customers',
          routes: <TypedRoute<RouteData>>[
            TypedGoRoute<CustomerRoute>(
              path: ':customerId',
              routes: <TypedRoute<RouteData>>[
                TypedGoRoute<CustomerHistoryRoute>(path: 'history'),
                TypedGoRoute<CustomerReceivablesRoute>(path: 'receivables'),
                TypedGoRoute<CustomerDiscountsRoute>(path: 'discounts'),
              ],
            ),
          ],
        ),
      ],
    ),
    TypedStatefulShellBranch<CashierBranch>(
      routes: <TypedRoute<RouteData>>[TypedGoRoute<CashierRoute>(path: '/cashier')],
    ),
    TypedStatefulShellBranch<TransactionsBranch>(
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<TransactionsRoute>(
          path: '/transactions',
          routes: <TypedRoute<RouteData>>[TypedGoRoute<TransactionRoute>(path: ':transactionId')],
        ),
      ],
    ),
    TypedStatefulShellBranch<OrdersBranch>(
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<OrdersRoute>(
          path: '/orders',
          routes: <TypedRoute<RouteData>>[
            TypedGoRoute<OrderRoute>(
              path: ':orderId',
              routes: <TypedRoute<RouteData>>[TypedGoRoute<OrderCreatedRoute>(path: 'created')],
            ),
          ],
        ),
      ],
    ),
    TypedStatefulShellBranch<AdminBranch>(
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<AdminUsersRoute>(path: '/admin/users'),
        TypedGoRoute<AdminSettingsRoute>(path: '/admin/settings'),
        TypedGoRoute<AdminAuditRoute>(path: '/admin/audit'),
      ],
    ),
    TypedStatefulShellBranch<ProfileBranch>(
      routes: <TypedRoute<RouteData>>[TypedGoRoute<ProfileRoute>(path: '/profile')],
    ),
    TypedStatefulShellBranch<ReportsBranch>(
      routes: <TypedRoute<RouteData>>[TypedGoRoute<ReportsRoute>(path: '/reports')],
    ),
  ],
)
class AppShellRoute extends StatefulShellRouteData {
  /// Оболочка режимов.
  const AppShellRoute();

  @override
  Widget builder(BuildContext context, GoRouterState state, StatefulNavigationShell navigationShell) =>
      AppShell(navigationShell: navigationShell);
}

/// Ветка «Каталог» (staff).
class CatalogBranch extends StatefulShellBranchData {
  /// Ветка `/catalog`.
  const CatalogBranch();
}

/// Ветка «Каталог клиента» (customer).
class HomeBranch extends StatefulShellBranchData {
  /// Ветка `/home`.
  const HomeBranch();
}

/// Ветка «Избранное».
class FavoritesBranch extends StatefulShellBranchData {
  /// Ветка `/favorites`.
  const FavoritesBranch();
}

/// Ветка «Корзина».
class CartBranch extends StatefulShellBranchData {
  /// Ветка `/cart`.
  const CartBranch();
}

/// Ветка «Клиенты».
class CustomersBranch extends StatefulShellBranchData {
  /// Ветка `/customers`.
  const CustomersBranch();
}

/// Ветка «Касса».
class CashierBranch extends StatefulShellBranchData {
  /// Ветка `/cashier`.
  const CashierBranch();
}

/// Ветка «Транзакции».
class TransactionsBranch extends StatefulShellBranchData {
  /// Ветка `/transactions`.
  const TransactionsBranch();
}

/// Ветка «Мои заказы» / «Заказы».
class OrdersBranch extends StatefulShellBranchData {
  /// Ветка `/orders`.
  const OrdersBranch();
}

/// Ветка «Админ».
class AdminBranch extends StatefulShellBranchData {
  /// Ветка `/admin/*`.
  const AdminBranch();
}

/// Ветка «Профиль».
class ProfileBranch extends StatefulShellBranchData {
  /// Ветка `/profile`.
  const ProfileBranch();
}

/// Ветка «Отчёты» (owner — главный экран; admin — через меню; navigation.md §2.2, §14.7).
class ReportsBranch extends StatefulShellBranchData {
  /// Ветка `/reports`.
  const ReportsBranch();
}

/// SCR-10 Рабочее пространство продавца / Каталог (staff).
class CatalogRoute extends GoRouteData with $CatalogRoute {
  /// Маршрут `/catalog?preset=&view=&sort=`.
  const CatalogRoute({this.preset, this.view, this.sort});

  /// `recent` — подборка «Недавние» (02 §4.1).
  final String? preset;

  /// Вид списка: `grid|list|compact`.
  final String? view;

  /// Сортировка — значение API (`price:asc` …).
  final String? sort;

  @override
  Widget build(BuildContext context, GoRouterState state) => CatalogScreen(preset: preset, view: view, sort: sort);

  /// medium/expanded/large — страница без анимации перехода (02 SCR-10.5 ANIM-024: SB и CP не анимируются) с экраном
  /// всего семейства каталога ([CatalogFamilyHost] по верхней записи `/catalog` → `/catalog/c/{id}` →
  /// `/catalog/search`, в том числе открытой `push`): переходы обновляют один экземпляр (заказчик 2026-10-28 —
  /// «мигает весь экран»), форма страницы одна для всех классов ≥ medium. compact — обычная страница ветки
  /// (переходы и «Назад» по navigation.md, N-7).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    if (WindowClassScope.of(context) == WindowClass.compact) return super.buildPage(context, state);
    return _catalogPage(state, CatalogFamilyHost(state: state));
  }
}

/// Страница семейства каталога без анимации перехода; ключ go_router (шаблон пути) стабилен — `go` в другую
/// категорию обновляет ту же страницу, а не меняет её.
Page<void> _catalogPage(GoRouterState state, Widget child) => NoTransitionPage<void>(
  key: state.pageKey,
  name: state.name ?? state.path,
  arguments: <String, String>{...state.pathParameters, ...state.uri.queryParameters},
  restorationId: state.pageKey.value,
  child: child,
);

/// Запись SCR-11/12 на medium+, которую рисует страница `/catalog` ([CatalogFamilyHost]).
Page<void> _catalogPassThrough(GoRouterState state) => PassThroughPage<void>(
  key: state.pageKey,
  name: state.name ?? state.path,
  arguments: <String, String>{...state.pathParameters, ...state.uri.queryParameters},
  restorationId: state.pageKey.value,
);

/// SCR-11/12 на medium+: запись семейства прямо над `/catalog` (`go` или `push`) — без содержимого; иначе (открыта
/// `push` не над семейством, например клиентом из `/home` или из SCR-14) — своя страница без анимации.
Page<void> _catalogEntryPage(BuildContext context, GoRouterState state, Widget Function() build) {
  if (catalogEntryPassesThrough(context, state)) return _catalogPassThrough(state);
  return _catalogPage(state, build());
}

/// SCR-11 Результаты поиска (staff, customer).
class CatalogSearchRoute extends GoRouteData with $CatalogSearchRoute {
  /// Маршрут `/catalog/search?q=&categoryId=&view=&sort=`.
  const CatalogSearchRoute({
    this.q,
    @TypedQueryParameter<String>(name: 'categoryId') this.categoryId,
    this.view,
    this.sort,
  });

  /// Строка поиска.
  final String? q;

  /// Категория, в которой начат поиск (SCR-12; 02 SCR-11.6: «Назад» → эта категория).
  final String? categoryId;

  /// Вид списка: `grid|list|compact`.
  final String? view;

  /// Сортировка — значение API (`relevance:desc` …).
  final String? sort;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      CatalogSearchScreen(q: q, categoryId: categoryId, view: view, sort: sort);

  /// medium+ — запись без содержимого (экран — страница `/catalog`), и из `go`, и `push` из SCR-12 (02 SCR-11.6:
  /// «Назад» в категорию тем же экземпляром с её прокруткой); compact — обычная страница.
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    if (WindowClassScope.of(context) == WindowClass.compact) return super.buildPage(context, state);
    return _catalogEntryPage(context, state, () => build(context, state));
  }
}

/// SCR-13 Фильтры (маршрут-лист на compact/medium; на expanded — панель без маршрута, 02 SCR-13).
class CatalogFiltersRoute extends GoRouteData with $CatalogFiltersRoute {
  /// Маршрут `/catalog/filters?f=&q=`.
  const CatalogFiltersRoute({this.f, this.q});

  /// Сериализованные фильтры.
  final String? f;

  /// Строка поиска, из которой открыт лист (02 SCR-13.6; EQ-CAT-12): подсчёт «Показать N» и фасеты — с учётом `q`.
  final String? q;

  @override
  Widget build(BuildContext context, GoRouterState state) => CatalogFiltersScreen(f: f, q: q);
}

/// SCR-12 Категория / подкатегории (staff, customer).
class CategoryRoute extends GoRouteData with $CategoryRoute {
  /// Маршрут `/catalog/c/:categoryId?view=&sort=&f=`.
  const CategoryRoute({required this.categoryId, this.view, this.sort, this.f});

  /// ID категории.
  final String categoryId;

  /// Вид списка: `grid|list|compact`.
  final String? view;

  /// Сортировка — значение API.
  final String? sort;

  /// Сериализованные фильтры.
  final String? f;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      CategoryScreen(categoryId: categoryId, view: view, sort: sort, f: f);

  /// medium+ — запись без содержимого (экран — страница `/catalog`, смена категории обновляет его; подкатегория на
  /// medium — `push` той же формы); compact — обычная страница (`push`, «Назад» к родителю — navigation.md SCR-12).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    if (WindowClassScope.of(context) == WindowClass.compact) return super.buildPage(context, state);
    return _catalogEntryPage(context, state, () => build(context, state));
  }
}

/// SCR-14 Карточка товара (staff, customer).
class ProductRoute extends GoRouteData with $ProductRoute {
  /// Маршрут `/catalog/p/:productId?variantId=&qty=`.
  const ProductRoute({
    required this.productId,
    @TypedQueryParameter<String>(name: 'variantId') this.variantId,
    this.qty,
  });

  /// ID товара.
  final String productId;

  /// Выбранный вариант.
  final String? variantId;

  /// Предзаполнение количества из сканера (строка `QuantityValue`).
  final String? qty;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      ProductDetailsScreen(productId: productId, variantId: variantId, qty: qty);

  /// expanded/large — прозрачная страница без барьера ([PanelPage]): SCR-14 рисует панель поверх контент-колонки
  /// списка (SB и CP видимы); клик по SB или пустой области шапки и `Esc` закрывают её (`pop` того же маршрута),
  /// работа с CP панель не закрывает — 02 SCR-14.2, navigation.md §5 «Панель на expanded», EQ-PD-05.
  /// compact/medium — обычная страница ветки.
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    final WindowClass wc = WindowClassScope.of(context);
    if (wc != WindowClass.expanded && wc != WindowClass.large) return super.buildPage(context, state);
    return PanelPage<void>(
      key: state.pageKey,
      name: state.name,
      arguments: <String, String>{...state.pathParameters, ...state.uri.queryParameters},
      restorationId: state.pageKey.value,
      transitionDuration: context.motion.of(const Duration(milliseconds: 200)),
      reverseTransitionDuration: context.motion.of(const Duration(milliseconds: 150)),
      child: build(context, state),
    );
  }
}

/// SCR-50 Главный экран клиента (customer; R1 — ядро v1.9 §24.2).
class HomeRoute extends GoRouteData with $HomeRoute {
  /// Маршрут `/home?view=&sort=`.
  const HomeRoute({this.view, this.sort});

  /// Вид списка: `grid|list|compact`.
  final String? view;

  /// Сортировка — значение API.
  final String? sort;

  @override
  Widget build(BuildContext context, GoRouterState state) => CustomerHomeScreen(view: view, sort: sort);
}

/// SCR-40 Избранное.
class FavoritesRoute extends GoRouteData with $FavoritesRoute {
  /// Маршрут `/favorites?tab=products|customers`.
  const FavoritesRoute({this.tab});

  /// Вкладка: `products|customers`.
  final String? tab;

  @override
  Widget build(BuildContext context, GoRouterState state) => FavoritesScreen(tab: tab);
}

/// SCR-20 Корзина (staff кроме owner; customer — своя).
class CartRoute extends GoRouteData with $CartRoute {
  /// Маршрут `/cart?cartId=`.
  const CartRoute({@TypedQueryParameter<String>(name: 'cartId') this.cartId});

  /// Корзина (по умолчанию — активная).
  final String? cartId;

  @override
  Widget build(BuildContext context, GoRouterState state) => CartScreen(cartId: cartId);
}

/// SCR-23 Отложенные заказы.
class CartParkedRoute extends GoRouteData with $CartParkedRoute {
  /// Маршрут `/cart/parked`.
  const CartParkedRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const ParkedCartsScreen();
}

/// SCR-31 Поиск клиентов.
class CustomersRoute extends GoRouteData with $CustomersRoute {
  /// Маршрут `/customers?q=&favorites=1&withDebt=1`.
  const CustomersRoute({this.q, this.favorites, @TypedQueryParameter<String>(name: 'withDebt') this.withDebt});

  /// Строка поиска (в `lastLocation` не сохраняется — navigation.md §14.5).
  final String? q;

  /// `1` — только избранные.
  final String? favorites;

  /// `1` — только с долгом.
  final String? withDebt;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      CustomersSearchScreen(q: q, favoritesOnly: favorites == '1', withDebtOnly: withDebt == '1');
}

/// SCR-32 Карточка клиента.
class CustomerRoute extends GoRouteData with $CustomerRoute {
  /// Маршрут `/customers/:customerId?tab=`.
  const CustomerRoute({required this.customerId, this.tab});

  /// ID клиента.
  final String customerId;

  /// Вкладка на expanded: `history|receivables|discounts|orders`.
  final String? tab;

  @override
  Widget build(BuildContext context, GoRouterState state) => CustomerCardScreen(customerId: customerId, tab: tab);
}

/// SCR-33 История покупок клиента.
class CustomerHistoryRoute extends GoRouteData with $CustomerHistoryRoute {
  /// Маршрут `/customers/:customerId/history?from=&to=&source=`.
  const CustomerHistoryRoute({required this.customerId, this.from, this.to, this.source});

  /// ID клиента.
  final String customerId;

  /// Начало периода (ISO-8601).
  final String? from;

  /// Конец периода (ISO-8601).
  final String? to;

  /// Источник: `pos|onec|all`.
  final String? source;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      CustomerHistoryScreen(customerId: customerId, from: from, to: to, source: source);
}

/// SCR-34 Долги и взаиморасчёты клиента.
class CustomerReceivablesRoute extends GoRouteData with $CustomerReceivablesRoute {
  /// Маршрут `/customers/:customerId/receivables`.
  const CustomerReceivablesRoute({required this.customerId});

  /// ID клиента.
  final String customerId;

  @override
  Widget build(BuildContext context, GoRouterState state) => CustomerReceivablesScreen(customerId: customerId);
}

/// SCR-35 Скидки и условия клиента.
class CustomerDiscountsRoute extends GoRouteData with $CustomerDiscountsRoute {
  /// Маршрут `/customers/:customerId/discounts`.
  const CustomerDiscountsRoute({required this.customerId});

  /// ID клиента.
  final String customerId;

  @override
  Widget build(BuildContext context, GoRouterState state) => CustomerDiscountsScreen(customerId: customerId);
}

/// SCR-30 Дашборд кассира.
class CashierRoute extends GoRouteData with $CashierRoute {
  /// Маршрут `/cashier`.
  const CashierRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const CashierDashboardScreen();
}

/// SCR-36 Транзакции.
class TransactionsRoute extends GoRouteData with $TransactionsRoute {
  /// Маршрут `/transactions?from=&to=&customerId=&status=&kind=&paymentMethod=&actorId=&q=&mine=`.
  const TransactionsRoute({
    this.from,
    this.to,
    @TypedQueryParameter<String>(name: 'customerId') this.customerId,
    this.status,
    this.kind,
    @TypedQueryParameter<String>(name: 'paymentMethod') this.paymentMethod,
    @TypedQueryParameter<String>(name: 'actorId') this.actorId,
    this.q,
    this.mine,
  });

  /// Начало периода (ISO-8601).
  final String? from;

  /// Конец периода (ISO-8601; период ≤ 366 дней).
  final String? to;

  /// Клиент.
  final String? customerId;

  /// Группы статусов через запятую (`TransactionStatusGroup`).
  final String? status;

  /// Виды через запятую (`TransactionKind`).
  final String? kind;

  /// Способ оплаты (`PaymentMethod`).
  final String? paymentMethod;

  /// Сотрудник (admin/owner).
  final String? actorId;

  /// Поиск.
  final String? q;

  /// `1` — только свои.
  final String? mine;

  @override
  Widget build(BuildContext context, GoRouterState state) => TransactionsScreen(
    from: from,
    to: to,
    customerId: customerId,
    status: status,
    kind: kind,
    paymentMethod: paymentMethod,
    actorId: actorId,
    q: q,
    mine: mine,
  );
}

/// SCR-37 Транзакция: детали.
class TransactionRoute extends GoRouteData with $TransactionRoute {
  /// Маршрут `/transactions/:transactionId`.
  const TransactionRoute({required this.transactionId});

  /// ID транзакции.
  final String transactionId;

  @override
  Widget build(BuildContext context, GoRouterState state) => TransactionDetailsScreen(transactionId: transactionId);
}

/// SCR-25 Список заказов (seller, customer — свои; прочие staff — все).
class OrdersRoute extends GoRouteData with $OrdersRoute {
  /// Маршрут `/orders?status=&from=&to=&customerId=&mine=`.
  const OrdersRoute({
    this.status,
    this.from,
    this.to,
    @TypedQueryParameter<String>(name: 'customerId') this.customerId,
    this.mine,
  });

  /// Статусы через запятую (значения `OrderStatus`).
  final String? status;

  /// Начало периода (ISO-8601).
  final String? from;

  /// Конец периода (ISO-8601).
  final String? to;

  /// Клиент.
  final String? customerId;

  /// `1` — только свои.
  final String? mine;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      OrdersScreen(status: status, from: from, to: to, customerId: customerId, mine: mine);
}

/// SCR-24 Заказ: детали и статус.
class OrderRoute extends GoRouteData with $OrderRoute {
  /// Маршрут `/orders/:orderId`.
  const OrderRoute({required this.orderId});

  /// ID заказа.
  final String orderId;

  @override
  Widget build(BuildContext context, GoRouterState state) => OrderDetailsScreen(orderId: orderId);
}

/// SCR-22 Заказ создан / QR для оплаты.
class OrderCreatedRoute extends GoRouteData with $OrderCreatedRoute {
  /// Маршрут `/orders/:orderId/created?paymentId=`.
  const OrderCreatedRoute({required this.orderId, @TypedQueryParameter<String>(name: 'paymentId') this.paymentId});

  /// ID заказа.
  final String orderId;

  /// Платёж, оплату которого ждёт экран (QR).
  final String? paymentId;

  @override
  Widget build(BuildContext context, GoRouterState state) => OrderCreatedScreen(orderId: orderId, paymentId: paymentId);
}

/// SCR-45 Админ: пользователи, роли, приглашения (admin; owner — ограниченный режим, ядро §21 п. 3).
class AdminUsersRoute extends GoRouteData with $AdminUsersRoute {
  /// Маршрут `/admin/users?tab=&userId=`.
  const AdminUsersRoute({this.tab, @TypedQueryParameter<String>(name: 'userId') this.userId});

  /// Вкладка: `users|invitations|links`.
  final String? tab;

  /// Пользователь (expanded — деталь).
  final String? userId;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      AdminUsersScreen(initialTab: AdminUsersTab.tryParse(tab), initialUserId: userId);
}

/// SCR-46 Админ: лимиты скидок и настройки (admin; owner — только просмотр, ядро §21 п. 3).
class AdminSettingsRoute extends GoRouteData with $AdminSettingsRoute {
  /// Маршрут `/admin/settings?section=`.
  const AdminSettingsRoute({this.section});

  /// Раздел настроек.
  final String? section;

  @override
  Widget build(BuildContext context, GoRouterState state) => AdminSettingsScreen(section: section);
}

/// SCR-47 Аудит (admin, owner).
class AdminAuditRoute extends GoRouteData with $AdminAuditRoute {
  /// Маршрут `/admin/audit?from=&to=&userId=&action=&entityType=&entityId=&result=`.
  const AdminAuditRoute({
    this.from,
    this.to,
    @TypedQueryParameter<String>(name: 'userId') this.userId,
    this.action,
    @TypedQueryParameter<String>(name: 'entityType') this.entityType,
    @TypedQueryParameter<String>(name: 'entityId') this.entityId,
    this.result,
  });

  /// Начало периода (ISO-8601).
  final String? from;

  /// Конец периода (ISO-8601; ≤ 366 дней).
  final String? to;

  /// Сотрудник.
  final String? userId;

  /// Префикс кода события.
  final String? action;

  /// Тип объекта.
  final String? entityType;

  /// ID объекта.
  final String? entityId;

  /// `ok|denied|error`.
  final String? result;

  @override
  Widget build(BuildContext context, GoRouterState state) => AuditScreen(
    from: from,
    to: to,
    userId: userId,
    action: action,
    entityType: entityType,
    entityId: entityId,
    result: result,
  );
}

/// SCR-41 Профиль (все роли).
class ProfileRoute extends GoRouteData with $ProfileRoute {
  /// Маршрут `/profile`.
  const ProfileRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const ProfileScreen();
}

/// SCR-48 Отчёты руководителя (owner — главный экран, admin; ветка `reports`).
class ReportsRoute extends GoRouteData with $ReportsRoute {
  /// Маршрут `/reports?from=&to=&report=&groupBy=`.
  const ReportsRoute({this.from, this.to, this.report, @TypedQueryParameter<String>(name: 'groupBy') this.groupBy});

  /// Начало периода (ISO-8601).
  final String? from;

  /// Конец периода (ISO-8601; ≤ 366 дней).
  final String? to;

  /// Отчёт: `sales|receivables|qr`.
  final String? report;

  /// Разрез сводки: `day|seller|paymentMethod`.
  final String? groupBy;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      ReportsScreen(from: from, to: to, report: report, groupBy: groupBy);
}

// ---------------------------------------------------------------------------
// Вне оболочки: полноэкранные сценарии
// ---------------------------------------------------------------------------

/// SCR-17 Сканер штрихкода (камера; Android/iOS; staff).
@TypedGoRoute<ScanRoute>(path: '/scan')
class ScanRoute extends GoRouteData with $ScanRoute {
  /// Маршрут `/scan?mode=search|add|order|test`.
  const ScanRoute({this.mode});

  /// Режим сканера (02 §4.1).
  final String? mode;

  @override
  Widget build(BuildContext context, GoRouterState state) => ScanScreen(mode: mode);
}

/// SCR-21 Оформление заказа (seller, cashier, senior_seller, admin; customer — упрощённое).
@TypedGoRoute<CheckoutRoute>(path: '/checkout')
class CheckoutRoute extends GoRouteData with $CheckoutRoute {
  /// Маршрут `/checkout?cartId=&step=`.
  const CheckoutRoute({@TypedQueryParameter<String>(name: 'cartId') this.cartId, this.step});

  /// Корзина (`Cart.id`).
  final String? cartId;

  /// Шаг на compact: `customer|delivery|payment|done`.
  final String? step;

  @override
  Widget build(BuildContext context, GoRouterState state) => CheckoutScreen(cartId: cartId, step: step);

  /// medium/expanded/large — модальное окно поверх трёхколоночной раскладки (02 SCR-21.2): прозрачная страница,
  /// сайдбар и `CartPanel` SCR-10 видны под затемнением, но не интерактивны (затемнение рисует и перехватывает экран).
  /// compact — обычная полноэкранная страница шагов.
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    if (context.windowClass == WindowClass.compact) return super.buildPage(context, state);
    return CustomTransitionPage<void>(
      key: state.pageKey,
      name: state.name,
      arguments: <String, String>{...state.pathParameters, ...state.uri.queryParameters},
      restorationId: state.pageKey.value,
      opaque: false,
      transitionDuration: context.motion.of(const Duration(milliseconds: 200)),
      reverseTransitionDuration: context.motion.of(const Duration(milliseconds: 150)),
      transitionsBuilder:
          (
            BuildContext context,
            Animation<double> animation, // money-double: allow — анимация перехода, не деньги
            Animation<double> secondaryAnimation, // money-double: allow — анимация перехода, не деньги
            Widget child,
          ) => FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          ),
      child: build(context, state),
    );
  }
}

/// SCR-38 Приём оплаты (по заказу; «по долгу» — только при `features.debtPaymentsFromPos`, RM-G-013).
@TypedGoRoute<PaymentNewRoute>(path: '/payments/new')
class PaymentNewRoute extends GoRouteData with $PaymentNewRoute {
  /// Маршрут `/payments/new?orderId=[&method=]` / `?customerId=`.
  const PaymentNewRoute({
    @TypedQueryParameter<String>(name: 'orderId') this.orderId,
    @TypedQueryParameter<String>(name: 'customerId') this.customerId,
    this.method,
  });

  /// Оплата по заказу.
  final String? orderId;

  /// Оплата долга клиента (условно, Q-152; при `debtPaymentsFromPos=false` закрыто guard).
  final String? customerId;

  /// Предвыбор способа (`cash|qr_bakai`).
  final String? method;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      PaymentScreen(orderId: orderId, customerId: customerId, method: method);
}

/// SCR-39 Заявка на возврат: создание.
@TypedGoRoute<ReturnNewRoute>(path: '/returns/new')
class ReturnNewRoute extends GoRouteData with $ReturnNewRoute {
  /// Маршрут `/returns/new?orderId=` (объявлен раньше `/returns/:returnId`).
  const ReturnNewRoute({@TypedQueryParameter<String>(name: 'orderId') this.orderId});

  /// Заказ, по которому оформляется возврат.
  final String? orderId;

  @override
  Widget build(BuildContext context, GoRouterState state) => ReturnRequestScreen(orderId: orderId);
}

/// SCR-39 Заявка на возврат: просмотр.
@TypedGoRoute<ReturnRoute>(path: '/returns/:returnId')
class ReturnRoute extends GoRouteData with $ReturnRoute {
  /// Маршрут `/returns/:returnId`.
  const ReturnRoute({required this.returnId});

  /// ID заявки на возврат.
  final String returnId;

  @override
  Widget build(BuildContext context, GoRouterState state) => ReturnRequestScreen(returnId: returnId);
}

/// SCR-42 Настройки (все роли).
@TypedGoRoute<SettingsRoute>(path: '/settings')
class SettingsRoute extends GoRouteData with $SettingsRoute {
  /// Маршрут `/settings?section=`.
  const SettingsRoute({this.section});

  /// Раздел настроек.
  final String? section;

  @override
  Widget build(BuildContext context, GoRouterState state) => SettingsScreen(section: section);
}

/// SCR-43 Статус синхронизации (staff).
@TypedGoRoute<SyncRoute>(path: '/sync')
class SyncRoute extends GoRouteData with $SyncRoute {
  /// Маршрут `/sync?entity=&runId=&tab=`.
  const SyncRoute({this.entity, @TypedQueryParameter<String>(name: 'runId') this.runId, this.tab});

  /// Сущность обмена.
  final String? entity;

  /// Прогон синхронизации.
  final String? runId;

  /// Вкладка экрана.
  final String? tab;

  @override
  Widget build(BuildContext context, GoRouterState state) => SyncStatusScreen(entity: entity, runId: runId, tab: tab);
}

/// SCR-44 Центр уведомлений (все роли).
@TypedGoRoute<NotificationsRoute>(path: '/notifications')
class NotificationsRoute extends GoRouteData with $NotificationsRoute {
  /// Маршрут `/notifications?unread=1`.
  const NotificationsRoute({this.unread});

  /// `1` — только непрочитанные.
  final String? unread;

  @override
  Widget build(BuildContext context, GoRouterState state) => NotificationsScreen(unreadOnly: unread == '1');
}
