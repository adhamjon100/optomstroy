// Точки подключения экранов клиентов SCR-31…SCR-35 (RM-G-007, RM-G-012) к сессии, сети и соседним фичам без
// межфичевого импорта (06 §6.1: customers ни от кого не зависит; app/ — композиционный корень).
//
// * Роль — из [newCustomerViewerRoleProvider] (корень уже подставляет роль входа для SCR-26, этап F). Права выводятся
//   из роли по матрице 11 §4.4 / `contracts/rbac/permissions.yaml`; сервер проверяет их независимо и отдаёт поля по
//   allowlist роли — экраны рисуют только присланное (SEC-031).
// * «В заказ» (`POST /cart/customer`), вкладка «Заказы и операции» (`GET /orders|/transactions?customerId=`) и флаг
//   `features.debtPaymentsFromPos` принадлежат фичам cart / orders / transactions / cashier — корень подставляет их
//   реализации; по умолчанию действия скрыты (fail-closed, Q-152).
// * Финансовые данные и ПДн — только память процесса (CASH-015, 07 §11.1 п. 5); новая память — при смене пользователя.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/session/session_controller.dart' show sessionControllerProvider;
import 'package:optomstroy/features/customers/presentation/new/new_customer_controller.dart';

/// Операция step-up детализации долга (08 §4.11.5, 11 №31/№62).
const String receivablesDetailOperation = 'customer.receivables.read.detail';

/// Срок действия `stepUpToken` (08 §2.12; ядро §17.2 — 15 мин, многоразовый в области).
const Duration stepUpWindow = Duration(minutes: 15);

/// Своя привязка клиента-покупателя к карточке 1С (`Me.customerLink`, 08 §4.3; RM-G-014). Только память процесса.
@immutable
final class CustomerSelfLink {
  /// Создаёт привязку.
  const CustomerSelfLink({this.status, this.customerId});

  /// Статус привязки; `null` — привязки нет (`none`).
  final CustomerLinkStatus? status;

  /// Карточка клиента 1С — только при `confirmed` (иначе свой долг и история — 404, 10 CUST-025).
  final String? customerId;

  /// Привязка подтверждена (ядро §22.12).
  bool get confirmed => status == CustomerLinkStatus.confirmed && customerId != null;

  @override
  bool operator ==(Object other) =>
      other is CustomerSelfLink && other.status == status && other.customerId == customerId;

  @override
  int get hashCode => Object.hash(status, customerId);
}

/// Своя привязка `customer` (`GET /me`). По умолчанию `null` — привязки нет: свои долг, история и скидки закрыты
/// (fail-closed, 10 CUST-025); корень (`app/router/shells/customer_mode_bindings.dart`) подставляет `GET /me`.
final customerSelfLinkProvider = FutureProvider<CustomerSelfLink?>((ref) async => null);

/// `features.customerSelfService` (`GET /settings/public`; env `CUSTOMER_SELF_SERVICE`, 10 CASH-006). `false` — строки
/// матрицы прав для `customer` не действуют (сервер → `403`): свои экраны клиента закрыты (02 SCR-35.7). По умолчанию
/// `true` (ядро §24.2); корень подставляет серверный флаг.
final customersSelfServiceProvider = Provider<bool>((ref) => true);

/// Доступ зрителя к экранам клиента `customerId` (SCR-32…SCR-35).
enum CustomerAccess {
  /// Сотрудник — поля и действия по роли (сервер отдаёт allowlist роли).
  staff,

  /// `customer`, своя карточка при подтверждённой привязке.
  own,

  /// `customer`, привязка ещё загружается.
  loading,

  /// `customer` без подтверждённой привязки (`none`/`proposed`/`conflict`/`rejected`) — запросов нет, показан
  /// статус привязки (02 AC-UI-41-010; 10 CUST-025).
  notLinked,

  /// `customer`, чужой `customerId` — «не найден» без запроса (сервер ответил бы `404`).
  foreign,

  /// `customer` при `CUSTOMER_SELF_SERVICE=false` — «Раздел недоступен» без запросов (10 CASH-006).
  disabled,
}

/// Кто смотрит клиентов: роль сессии и производные права (11 §4.4; 02 §0.4 части D).
@immutable
final class CustomersViewer {
  /// Создаёт зрителя.
  const CustomersViewer({this.role, this.selfLink, this.selfLinkLoading = false, this.selfService = true});

  /// Роль сессии; `null` — неизвестна (до входа) — минимальные возможности (как `seller`, без создания).
  final RoleCode? role;

  /// Своя привязка (только `customer`).
  final CustomerSelfLink? selfLink;

  /// Привязка `customer` ещё загружается.
  final bool selfLinkLoading;

  /// Режим клиента включён (`CUSTOMER_SELF_SERVICE`).
  final bool selfService;

  /// Продавец (Q-017: только признаки долга, маска телефона).
  bool get isSeller => role == RoleCode.seller;

  /// Руководитель (без кассовых действий, без избранного — FAV-006).
  bool get isOwner => role == RoleCode.owner;

  /// Администратор.
  bool get isAdmin => role == RoleCode.admin;

  /// Клиент-покупатель (режим клиента, ядро §24.2): только своя карточка при `confirmed`, без служебных действий.
  bool get isCustomer => role == RoleCode.customer;

  /// `customer` с подтверждённой привязкой: свой долг (сводка; детализация — step-up, 11 №62) и история покупок.
  bool get selfConfirmed => isCustomer && selfService && (selfLink?.confirmed ?? false);

  /// Доступ к экранам клиента [customerId].
  CustomerAccess accessTo(String customerId) {
    if (!isCustomer) return CustomerAccess.staff;
    if (!selfService) return CustomerAccess.disabled;
    if (selfLinkLoading && selfLink == null) return CustomerAccess.loading;
    if (!selfConfirmed) return CustomerAccess.notLinked;
    return selfLink!.customerId == customerId ? CustomerAccess.own : CustomerAccess.foreign;
  }

  bool get _cashierPlus => role == RoleCode.cashier || role == RoleCode.seniorSeller || role == RoleCode.admin;

  /// `customer.receivables.read.summary` — суммы долга (Z5 SCR-32, SCR-34); `customer` — свои при `confirmed`.
  bool get seesSums => _cashierPlus || isOwner || selfConfirmed;

  /// `customer.history.read` — SCR-33; `customer` — своя при `confirmed`.
  bool get canReadHistory => _cashierPlus || isOwner || selfConfirmed;

  /// SCR-34 (сводка; детализация — step-up); `customer` — свой при `confirmed` (`customer.self.receivables.read`).
  bool get canReadReceivables => _cashierPlus || isOwner || selfConfirmed;

  /// `POST /customers/{id}/receivables/refresh`.
  bool get canRefreshReceivables => _cashierPlus || isOwner;

  /// `favorites.customers.manage` (FAV-006).
  bool get canManageFavorites => _cashierPlus;

  /// Чипы «С долгом» / «С просрочкой» (фильтр `hasDebt` — только с правом на суммы).
  bool get canFilterDebt => _cashierPlus || isOwner;

  /// `customer.create` (SCR-26; у `owner` — нет, 02 §5).
  bool get canCreateCustomer => isSeller || _cashierPlus;

  /// `payment.debt.receive` (D-15: не у `admin`/`owner`).
  bool get canAcceptDebtPayment => role == RoleCode.cashier || role == RoleCode.seniorSeller;

  /// `cart.manage.own` — «В заказ».
  bool get canAddToCart => isSeller || _cashierPlus;

  /// `customer.link.read` — привязки (Z7).
  bool get canReadLinks => _cashierPlus || isOwner;

  /// Разрешение конфликтов привязок (SCR-45).
  bool get canResolveLinks => isAdmin;

  /// Поиск по имени, части телефона, ИНН (ядро §19.4); `seller` — только полный номер или код.
  bool get searchesByName => _cashierPlus || isOwner;

  @override
  bool operator ==(Object other) =>
      other is CustomersViewer &&
      other.role == role &&
      other.selfLink == selfLink &&
      other.selfLinkLoading == selfLinkLoading &&
      other.selfService == selfService;

  @override
  int get hashCode => Object.hash(role, selfLink, selfLinkLoading, selfService);
}

/// Зритель экранов клиентов (роль — как у SCR-26; у `customer` — плюс своя привязка; в тестах — `overrideWithValue`).
final customersViewerProvider = Provider<CustomersViewer>((ref) {
  final RoleCode? role = ref.watch(newCustomerViewerRoleProvider);
  if (role != RoleCode.customer) return CustomersViewer(role: role);
  if (!ref.watch(customersSelfServiceProvider)) return CustomersViewer(role: role, selfService: false);
  final AsyncValue<CustomerSelfLink?> link = ref.watch(customerSelfLinkProvider);
  return CustomersViewer(
    role: role,
    selfLink: link.hasError ? null : link.value,
    selfLinkLoading: link.isLoading && !link.hasValue,
  );
});

/// Есть ли сеть (клиенты и финансы — только онлайн, кэша на устройстве нет).
final customersOnlineProvider = Provider<bool>((ref) => ref.watch(newCustomerOnlineProvider));

/// `features.debtPaymentsFromPos` (`GET /settings/public`): «Принять оплату по долгу». По умолчанию `false` —
/// fail-closed (R1, Q-152); корень подставляет `debtPaymentsFromPosProvider` фичи cashier.
final customerDebtPaymentsEnabledProvider = Provider<bool>((ref) => false);

/// «В заказ»: назначить клиента корзине (`POST /cart/customer`, при другом клиенте — `ConfirmDialog` замены) и перейти
/// в корзину. Реализацию подставляет корень (фича cart); `null` — кнопка скрыта.
typedef CustomerToCartAction = Future<void> Function(BuildContext context, String customerId);

/// Действие «В заказ» (по умолчанию нет).
final customerToCartActionProvider = Provider<CustomerToCartAction?>((ref) => null);

/// Содержимое вкладки «Заказы и операции» SCR-32 (UI-32-007: `GET /orders?customerId=`,
/// `GET /transactions?customerId=`) — виджет фич orders/transactions, подставляет корень; `null` — вкладка без списка.
typedef CustomerOrdersTabBuilder = Widget Function(BuildContext context, String customerId);

/// Вкладка «Заказы и операции» (по умолчанию нет).
final customerOrdersTabBuilderProvider = Provider<CustomerOrdersTabBuilder?>((ref) => null);

/// Подсказка предзаполнения SCR-26 (номер из строки поиска SCR-31): аналог невосстанавливаемого `extra`
/// (navigation.md N-3) — только память процесса, читается один раз; в URL, логи роутера и `lastLocation` не попадает.
final customerNewPrefillProvider = Provider<CustomerNewPrefill>((ref) {
  ref.watch(sessionControllerProvider.select((s) => s.userId));
  return CustomerNewPrefill();
});

/// Номер E.164 для предзаполнения SCR-26 (не состояние провайдера: читается в `initState`).
final class CustomerNewPrefill {
  String? _value;

  /// Запомнить номер перед переходом на SCR-26 (`null` — забыть).
  void put(String? e164) => _value = e164;

  /// Забрать номер (одноразово).
  String? take() {
    final String? v = _value;
    _value = null;
    return v;
  }
}

/// Имена клиентов, увиденные в этой сессии (подзаголовок SCR-33/34/35 без лишнего запроса карточки). ПДн — только
/// память процесса; новая память — при смене пользователя.
final customerNamesProvider = Provider<CustomerNameMemory>((ref) {
  ref.watch(sessionControllerProvider.select((s) => s.userId));
  return CustomerNameMemory();
});

/// Память имён клиентов.
final class CustomerNameMemory {
  final Map<String, String> _names = <String, String>{};

  /// Имя клиента [id] или `null`.
  String? nameOf(String id) => _names[id];

  /// Запомнить имя.
  void put(String id, String name) => _names[id] = name;
}

/// Оценка срока детализации долга (UI-34-008 «открыта до HH:MM»): `StepUpTokenCache` не отдаёт `expiresAt`
/// (GQ-FECUST-03), поэтому срок отмечается в момент, когда в кэше впервые появился токен области — момент
/// получения + [stepUpWindow]. Ключ — хэш токена (сам токен не хранится). Память процесса; новая — при смене пользователя.
final receivablesDetailWindowProvider = Provider<DetailWindowMemory>((ref) {
  ref.watch(sessionControllerProvider.select((s) => s.userId));
  return DetailWindowMemory();
});

/// Память сроков детализации.
final class DetailWindowMemory {
  final Map<int, DateTime> _until = <int, DateTime>{};

  /// Срок для токена (по хэшу) или `null` — неизвестен (токен получен вне экрана долга).
  DateTime? untilFor(String token) => _until[token.hashCode];

  /// Отметить срок.
  void note(String token, DateTime until) => _until[token.hashCode] = until;
}
