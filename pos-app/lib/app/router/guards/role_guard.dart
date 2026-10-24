import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/enums.dart';

/// Пути только для сотрудников (staff): клиенту-покупателю недоступны (02 §4.1; 06 AC-MOD-029).
/// Этап G: свой долг, история и скидки клиента (`/customers/{id}`, `/history`, `/receivables`, `/discounts`) остаются
/// доступны `customer` — «свой» и `confirmed` проверяет сервер (иначе 404, 10 CUST-025; RM-G-014).
///
/// Этап E: SCR-10 `/catalog` (корень ветки; поиск, категория, фильтры и карточка — staff и customer),
/// SCR-17 `/scan`, SCR-43 `/sync`. Разделы, закрытые клиенту по AC-MOD-029: `/cashier`,
/// `/customers` (список) и `/customers/new`, `/transactions*`, `/admin/*`, `/reports`, `/cart/parked`,
/// кассовые `/payments/new` и `/returns/*` (G-7).
/// Карточка клиента `/customers/{id}` (свой — SCR-32…34) не закрывается: проверку «свой» делает сервер.
bool isStaffOnlyPath(String path) {
  if (path == '/catalog' || path == '/scan' || path == '/sync') return true;
  if (path == '/customers' || path == '/customers/new' || path == '/cart/parked') return true;
  // Кассовые маршруты root-уровня (SCR-38, SCR-39): у клиента нет кассовых прав (G-7, RM-E-017).
  for (final prefix in const <String>['/cashier', '/transactions', '/admin', '/reports', '/payments', '/returns']) {
    if (path == prefix || path.startsWith('$prefix/')) return true;
  }
  return false;
}

/// Пути режима клиента-покупателя, закрытые при `CUSTOMER_SELF_SERVICE=false` (navigation.md G-8):
/// SCR-50 `/home`, каталог, избранное, корзина, оформление, «Мои заказы»; этап G (RM-G-014, GQ-FECM-03) — свои
/// карточка, долг, история и скидки `/customers/{id}…` (SCR-32…SCR-35).
bool isCustomerSelfServicePath(String path) {
  for (final prefix in const <String>[
    '/home',
    '/catalog',
    '/favorites',
    '/cart',
    '/checkout',
    '/orders',
    '/customers',
  ]) {
    if (path == prefix || path.startsWith('$prefix/')) return true;
  }
  return false;
}

/// Только для клиента-покупателя: SCR-50 `/home` (сотрудник уходит на главный экран своего режима).
bool isCustomerOnlyPath(String path) => path == '/home' || path.startsWith('/home/');

/// Флаги функций, которые закрывают маршруты этапа G (G-8; `GET /settings/public` → `features`).
///
/// - [returnsEnabled] — `features.returnsFromPos` (= `returns_enabled`, 10 RET-012): `false` закрывает `/returns/*`;
///   `null` — ответа сервера ещё нет: маршрут не закрывается (скрытие — не защита, сервер ответит сам).
/// - [debtPaymentsFromPos] — `features.debtPaymentsFromPos` (RM-G-013, Q-152; R1 — `false`): `false` закрывает режим
///   SCR-38 «по долгу» `/payments/new?customerId=` (fail-closed: до ответа сервера — тоже закрыт).
final class RouteFeatures {
  const RouteFeatures({this.returnsEnabled, this.debtPaymentsFromPos = false});

  /// Флаги до ответа сервера / по умолчанию R1.
  static const RouteFeatures defaults = RouteFeatures();

  final bool? returnsEnabled;
  final bool debtPaymentsFromPos;

  @override
  bool operator ==(Object other) =>
      other is RouteFeatures &&
      other.returnsEnabled == returnsEnabled &&
      other.debtPaymentsFromPos == debtPaymentsFromPos;

  @override
  int get hashCode => Object.hash(returnsEnabled, debtPaymentsFromPos);
}

/// Путь закрыт выключенной функцией [features] (G-8 этапа G) — для любой роли сотрудника.
bool isPathDisabledByFeature(Uri uri, RouteFeatures features) {
  final String path = uri.path;
  if (features.returnsEnabled == false && (path == '/returns' || path.startsWith('/returns/'))) return true;
  if (!features.debtPaymentsFromPos && path == '/payments/new' && uri.queryParameters.containsKey('customerId')) {
    return true;
  }
  return false;
}

final RegExp _customerFinancePath = RegExp(r'^/customers/[^/]+/(history|receivables)$');

/// Разрешён ли путь роли сотрудника [role] (navigation.md G-7: ветки §2.2, корневые маршруты §3, кассовые
/// маршруты по итогу §14.2, набор веток `owner` §14.7). UX-ограничение: права проверяет сервер (D-15).
/// Permissions access-токена клиент не разбирает, поэтому кассовые маршруты сверяются с итогом §14.2 по ролям
/// (11 §4.4). `null`-роль (профиль ещё не загружен) — ограничений сверх режима нет.
bool isPathAllowedForRole(RoleCode? role, String path) {
  if (role == null || role == RoleCode.customer || role == RoleCode.integration) return true;
  bool under(String prefix) => path == prefix || path.startsWith('$prefix/');
  const Set<RoleCode> all = <RoleCode>{
    RoleCode.seller,
    RoleCode.seniorSeller,
    RoleCode.cashier,
    RoleCode.admin,
    RoleCode.owner,
  };
  final Set<RoleCode> allowed = switch (path) {
    // SCR-26: `customer.create` — seller, cashier, senior_seller, admin; owner — нет (02 §5).
    '/customers/new' => const <RoleCode>{RoleCode.seller, RoleCode.cashier, RoleCode.seniorSeller, RoleCode.admin},
    // SCR-33 (`customer.history.read`) и SCR-34 (`customer.receivables.read.detail`): cashier, senior_seller, admin,
    // owner; seller — только признак долга на SCR-32 (Q-017, 11 §4.4).
    _ when _customerFinancePath.hasMatch(path) => const <RoleCode>{
      RoleCode.cashier,
      RoleCode.seniorSeller,
      RoleCode.admin,
      RoleCode.owner,
    },
    // SCR-38: permission `payment.cash.receive` / `payment.qr.show` / `payment.debt.receive` — cashier, senior_seller.
    _ when under('/payments') => const <RoleCode>{RoleCode.cashier, RoleCode.seniorSeller},
    // SCR-39: создание — cashier, senior_seller, admin; просмотр `/returns/{id}` — также owner (`return.read`).
    '/returns/new' => const <RoleCode>{RoleCode.cashier, RoleCode.seniorSeller, RoleCode.admin},
    _ when under('/returns') => const <RoleCode>{
      RoleCode.cashier,
      RoleCode.seniorSeller,
      RoleCode.admin,
      RoleCode.owner,
    },
    // SCR-30: `dashboard.cashier.read` — cashier, senior_seller; admin и owner — просмотр.
    _ when under('/cashier') => const <RoleCode>{
      RoleCode.cashier,
      RoleCode.seniorSeller,
      RoleCode.admin,
      RoleCode.owner,
    },
    // Ветки `admin` и `reports`: admin; owner — ограниченный режим (§14.7).
    _ when under('/admin') || under('/reports') => const <RoleCode>{RoleCode.admin, RoleCode.owner},
    // Owner: `/checkout`, `/cart`, `/cart/parked` закрыты (§14.7).
    _ when under('/checkout') || under('/cart') => const <RoleCode>{
      RoleCode.seller,
      RoleCode.seniorSeller,
      RoleCode.cashier,
      RoleCode.admin,
    },
    _ => all,
  };
  return allowed.contains(role);
}

/// roleGuard (06 §6.4; navigation.md G-7, G-8) для аутентифицированной сессии — UX-ограничение,
/// права проверяет сервер (D-15).
///
/// - `customer` на staff-пути (G-7) → [homeLocation] (`/home`);
/// - `customer` при выключенном `CUSTOMER_SELF_SERVICE` на пути режима клиента (G-8) → `/pending-activation`
///   (SCR-07 — экран клиента без самообслуживания, navigation.md §4.4; E_spec_questions EQ-FEF-08);
/// - сотрудник на `/home` → [homeLocation] (`/catalog`, `/cashier`);
/// - сотрудник на пути ветки/маршрута, не разрешённого его роли [role] (G-7, [isPathAllowedForRole]) →
///   [homeLocation];
/// - сотрудник на пути, закрытом выключенной функцией [features] (G-8 этапа G, [isPathDisabledByFeature]:
///   `returns_enabled=false`, `debtPaymentsFromPos=false`) → [homeLocation].
///
/// Возвращает адрес перенаправления или `null`.
String? roleRedirect({
  required AppMode mode,
  required Uri uri,
  required String homeLocation,
  required bool customerSelfService,
  RoleCode? role,
  RouteFeatures features = RouteFeatures.defaults,
}) {
  final path = uri.path;
  if (mode == AppMode.customer) {
    if (!customerSelfService && isCustomerSelfServicePath(path)) {
      return const PendingActivationRoute().location;
    }
    if (isStaffOnlyPath(path)) return homeLocation == path ? null : homeLocation;
    return null;
  }
  if (isCustomerOnlyPath(path) || !isPathAllowedForRole(role, path) || isPathDisabledByFeature(uri, features)) {
    return homeLocation == path ? null : homeLocation;
  }
  return null;
}

/// Снекбар G-7 при перенаправлении roleGuard (navigation.md §4.1, §4.3 «Смена роли»; 03 §16.7).
enum RoleGuardNotice {
  /// «Раздел недоступен для вашей роли» (`global_role_forbidden`).
  roleForbidden,

  /// «Приём оплаты выполняет кассир» (`global_payment_cashier_only`) — для `/payments/new`.
  paymentCashierOnly,
}

/// Снекбар, который сопровождает перенаправление [roleRedirect] по G-7, или `null`.
///
/// Снекбар показывается, только если путь закрыт **ролью**: `customer` на пути сотрудника, сотрудник
/// с известной ролью на пути, не разрешённом [isPathAllowedForRole]. Без снекбара: G-8 (выключенное
/// самообслуживание → SCR-07), сотрудник на `/home` (главный экран клиента — уход на свой главный экран),
/// роль ещё не загружена, путь закрыт выключенной функцией (G-8 этапа G — точки входа скрыты, не роль).
RoleGuardNotice? roleRedirectNotice({
  required AppMode mode,
  required Uri uri,
  required String homeLocation,
  required bool customerSelfService,
  RoleCode? role,
  RouteFeatures features = RouteFeatures.defaults,
}) {
  final path = uri.path;
  final target = roleRedirect(
    mode: mode,
    uri: uri,
    homeLocation: homeLocation,
    customerSelfService: customerSelfService,
    role: role,
    features: features,
  );
  if (target == null) return null;
  final bool forbidden = mode == AppMode.customer
      ? (customerSelfService || !isCustomerSelfServicePath(path)) && isStaffOnlyPath(path)
      : role != null && !isPathAllowedForRole(role, path);
  if (!forbidden) return null;
  final bool payments = path == '/payments' || path.startsWith('/payments/');
  return payments ? RoleGuardNotice.paymentCashierOnly : RoleGuardNotice.roleForbidden;
}
