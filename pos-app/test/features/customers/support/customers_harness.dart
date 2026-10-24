// Обвязка widget- и golden-тестов экранов клиентов SCR-31…SCR-35, SCR-40 (клиенты), SCR-26 (RM-G-007, RM-G-012):
// фейки портов customers (справочник, долги, избранные клиенты, поиск этапа F), роль, сеть, «сейчас» (Бишкек) и
// координатор step-up с кэшем на том же фиксированном времени. Деньги — целые тыйыны.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/session/session_controller.dart' show stepUpCoordinatorProvider;
import 'package:optomstroy/core/session/step_up_coordinator.dart';
import 'package:optomstroy/core/session/step_up_token_cache.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' show catalogViewerRoleProvider;
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_contact.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_history.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';
import 'package:optomstroy/features/customers/domain/entities/new_customer.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/favorite_customers_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/receivables_repository.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_controller.dart';
import 'package:optomstroy/features/favorites/domain/repositories/favorites_repository.dart';
import 'package:optomstroy/features/favorites/favorites_providers.dart';

/// Окна golden (D-18).
const Map<String, Size> kWindows = <String, Size>{
  'compact': Size(390, 844),
  'medium': Size(820, 1000),
  'expanded': Size(1366, 900),
};

/// «Сейчас»: 24.10.2026 10:00 Бишкек.
final DateTime kNow = DateTime.utc(2026, 10, 24, 4);

/// Снимок 1С 20 мин назад (свежий).
final DateTime kAsOf = kNow.subtract(const Duration(minutes: 20));

Money som(int v) => Money.som(v);

/// Клиент глазами кассира (полные поля).
Customer cashierCustomer({
  String id = 'c1',
  String name = 'ОсОО «Азамат Строй»',
  bool favorite = false,
  bool hasDebt = true,
  bool overdue = true,
  ReceivableSummary? receivable,
  bool withReceivable = true,
  CustomerMatchType? match,
  CustomerOnecStatus? onecStatus = CustomerOnecStatus.confirmed,
}) => Customer(
  id: id,
  name: name,
  customerType: CustomerType.legal,
  onecCode: 'ОС-000123',
  onecRef: 'ref-$id',
  source: CustomerSource.onec,
  onecStatus: onecStatus,
  phones: const <CustomerPhone>[
    CustomerPhone(valueE164: '+996700123456', verified: true),
    CustomerPhone(valueE164: '+996555987654', verified: false),
  ],
  inn: '01234567890123',
  priceList: const PriceListRef(id: 'pl-opt', name: 'Оптовая'),
  discountPercent: const Percent(500),
  creditAllowed: true,
  hasDebt: hasDebt,
  isOverdue: overdue,
  receivable: withReceivable
      ? (receivable ??
            ReceivableSummary(
              balance: som(12000),
              overdueAmount: som(4200),
              creditLimit: som(50000),
              limitRemaining: som(33800),
              asOf: kAsOf,
            ))
      : null,
  ordersCount: 12,
  lastOrderAt: kNow.subtract(const Duration(days: 3)),
  addresses: const <String>['г. Бишкек, ул. Ахунбаева, 125'],
  contacts: const <CustomerContact>[
    CustomerContact(kind: ContactKind.email, value: 'zakup@azamat.kg', name: 'Бухгалтерия'),
  ],
  isFavorite: favorite,
  matchType: match,
);

/// Тот же клиент глазами продавца (08 §3.7: без `phones`, `inn`, `receivable`, `addresses`, `isFavorite`).
Customer sellerCustomer({String id = 'c1', CustomerMatchType? match}) => Customer(
  id: id,
  name: 'ОсОО «Азамат Строй»',
  customerType: CustomerType.legal,
  onecCode: 'ОС-000123',
  source: CustomerSource.onec,
  phoneMasked: '+996 700 *** *56',
  priceList: const PriceListRef(id: 'pl-opt', name: 'Оптовая'),
  discountPercent: const Percent(500),
  creditAllowed: true,
  hasDebt: true,
  isOverdue: true,
  ordersCount: 12,
  matchType: match,
);

/// Снимок долга.
Receivable receivable({
  String customerId = 'c1',
  DateTime? asOf,
  bool stale = false,
  List<ReceivableDocument>? documents,
  Money? balance,
}) => Receivable(
  customerId: customerId,
  balance: balance ?? som(12000),
  overdueAmount: som(4200),
  overdueDays: 12,
  creditLimit: som(50000),
  openOrdersAmount: som(4200),
  limitRemaining: som(33800),
  creditAllowed: true,
  paymentTermDays: 14,
  asOf: asOf ?? kAsOf,
  isStale: stale,
  staleAfterMinutes: 60,
  documents: documents,
);

/// Детализация (реализации, платёж, возврат, просрочка).
List<ReceivableDocument> documents() => <ReceivableDocument>[
  ReceivableDocument(
    kind: ReceivableDocumentKind.invoice,
    status: ReceivableDocumentStatus.due,
    number: 'УТ-0001230',
    date: DateTime(2026, 9, 28),
    amount: som(8200),
    paid: som(4000),
    remaining: som(4200),
    dueDate: DateTime(2026, 10, 12),
    overdueDays: 12,
  ),
  ReceivableDocument(
    kind: ReceivableDocumentKind.invoice,
    status: ReceivableDocumentStatus.posted,
    number: 'УТ-0001250',
    date: DateTime(2026, 10, 20),
    amount: som(7800),
    paid: som(0),
    remaining: som(7800),
    dueDate: DateTime(2026, 11, 3),
    overdueDays: 0,
  ),
  ReceivableDocument(
    kind: ReceivableDocumentKind.payment,
    status: ReceivableDocumentStatus.posted,
    number: 'ПКО-000512',
    date: DateTime(2026, 10, 1),
    amount: som(4000),
    remaining: som(0),
  ),
  ReceivableDocument(
    kind: ReceivableDocumentKind.returnValue,
    status: ReceivableDocumentStatus.posted,
    number: 'ВЗ-000031',
    date: DateTime(2026, 10, 5),
    amount: som(1350),
    remaining: som(0),
  ),
];

/// Фейк справочника клиентов.
final class FakeDirectory implements CustomerDirectoryRepository {
  final List<CustomersListQuery> listCalls = <CustomersListQuery>[];
  final List<CancelSignal?> listCancels = <CancelSignal?>[];
  final List<(String, Set<CustomerInclude>)> cardCalls = <(String, Set<CustomerInclude>)>[];
  final List<CustomerHistoryQuery> historyCalls = <CustomerHistoryQuery>[];
  final List<CancelSignal?> historyCancels = <CancelSignal?>[];
  int discountsCalls = 0;
  int rulesCalls = 0;

  Future<Result<PageResult<Customer>>> Function(CustomersListQuery q) onList = (CustomersListQuery q) async =>
      Success<PageResult<Customer>>(PageResult<Customer>(items: <Customer>[cashierCustomer(favorite: true)]));
  Future<Result<Customer>> Function(String id, Set<CustomerInclude> include) onCard =
      (String id, Set<CustomerInclude> include) async => Success<Customer>(cashierCustomer(id: id));
  Future<Result<CustomerHistory>> Function(String id, CustomerHistoryQuery q) onHistory =
      (String id, CustomerHistoryQuery q) async => Success<CustomerHistory>(sampleHistory());
  Future<Result<CustomerDiscounts>> Function(String id) onDiscounts = (String id) async =>
      Success<CustomerDiscounts>(sampleDiscounts());
  Future<Result<DiscountRulesInfo>> Function() onRules = () async => Success<DiscountRulesInfo>(rulesInfo());

  @override
  Future<Result<PageResult<Customer>>> list(CustomersListQuery query, {CancelSignal? cancel}) {
    listCalls.add(query);
    listCancels.add(cancel);
    return onList(query);
  }

  @override
  Future<Result<Customer>> card(String customerId, {Set<CustomerInclude> include = const <CustomerInclude>{}}) {
    cardCalls.add((customerId, include));
    return onCard(customerId, include);
  }

  @override
  Future<Result<CustomerHistory>> history(String customerId, CustomerHistoryQuery query, {CancelSignal? cancel}) {
    historyCalls.add(query);
    historyCancels.add(cancel);
    return onHistory(customerId, query);
  }

  @override
  Future<Result<CustomerDiscounts>> discounts(String customerId) {
    discountsCalls++;
    return onDiscounts(customerId);
  }

  @override
  Future<Result<DiscountRulesInfo>> discountRules({String? customerId, String? cartId}) {
    rulesCalls++;
    return onRules();
  }
}

/// История за период.
CustomerHistory sampleHistory() => CustomerHistory(
  page: PageResult<CustomerHistoryEntry>(
    items: <CustomerHistoryEntry>[
      CustomerHistoryEntry(
        kind: CustomerHistoryKind.order,
        id: 'o-123',
        number: 'POS-000123',
        date: kNow.subtract(const Duration(days: 3)),
        total: const Money(1600750),
        status: 'shipped',
        source: CustomerHistorySource.pos,
      ),
      CustomerHistoryEntry(
        kind: CustomerHistoryKind.shipment,
        number: 'УТ-0001230',
        date: kNow.subtract(const Duration(days: 26)),
        total: som(8200),
        status: 'Проведён',
        source: CustomerHistorySource.onec,
      ),
    ],
    asOf: kAsOf,
  ),
  summary: const CustomerHistorySummary(count: 2, total: Money(2420750)),
  historyFrom: DateTime(2025, 10, 24),
);

/// Скидки и условия.
CustomerDiscounts sampleDiscounts({bool withLimit = true}) => CustomerDiscounts(
  rules: const <DiscountRule>[
    DiscountRule(
      id: 'r1',
      source: DiscountSource.onec,
      kind: DiscountKind.percent,
      name: 'Оптовая скидка',
      value: '3.00',
      isActive: true,
      conditions: DiscountRuleConditions(minTotal: Money(5000000)),
    ),
    DiscountRule(
      id: 'r2',
      source: DiscountSource.pos,
      kind: DiscountKind.percent,
      name: 'Ручная скидка',
      value: '5.00',
      isActive: true,
    ),
  ],
  asOf: kAsOf,
  priceList: const PriceListRef(id: 'pl-opt', name: 'Оптовая'),
  customerDiscountPercent: const Percent(500),
  creditTerms: CustomerCreditTerms(
    creditAllowed: true,
    paymentTermDays: 14,
    creditLimit: withLimit ? som(50000) : null,
  ),
  manualDiscountLimitPercent: const Percent(500),
);

/// Правила и лимиты.
DiscountRulesInfo rulesInfo() => const DiscountRulesInfo(
  rules: <DiscountRule>[],
  manualDiscountLimitPercent: Percent(500),
  overrideRoles: <RoleCode>[RoleCode.seniorSeller, RoleCode.admin],
  limitsByRole: <String, String>{'senior_seller': '10.00', 'admin': '15.00'},
);

/// Фейк долгов (кладёт ответы в память финансов сессии, как реализация data).
final class FakeReceivables implements ReceivablesRepository {
  FakeReceivables(this.memory);

  final CustomerFinanceMemory memory;
  final List<({bool withDocuments, String? token})> getCalls = <({bool withDocuments, String? token})>[];
  final List<({bool withDocuments, String? key, String? token})> refreshCalls =
      <({bool withDocuments, String? key, String? token})>[];

  /// Ответ `GET` (без/с документами).
  Future<Result<Receivable>> Function(bool withDocuments, String? token) onGet =
      (bool withDocuments, String? token) async =>
          Success<Receivable>(receivable(documents: withDocuments ? documents() : null));
  Future<Result<Receivable>> Function(bool withDocuments) onRefresh = (bool withDocuments) async =>
      Success<Receivable>(receivable(documents: withDocuments ? documents() : null));

  @override
  Future<Result<Receivable>> get(
    String customerId, {
    bool withDocuments = false,
    bool refresh = false,
    String? stepUpToken,
  }) async {
    getCalls.add((withDocuments: withDocuments, token: stepUpToken));
    final Result<Receivable> r = await onGet(withDocuments, stepUpToken);
    if (r case Success<Receivable>(:final Receivable value)) memory.putReceivable(value);
    return r;
  }

  @override
  Future<Result<Receivable>> refresh(
    String customerId, {
    bool withDocuments = false,
    String? idempotencyKey,
    String? stepUpToken,
  }) async {
    refreshCalls.add((withDocuments: withDocuments, key: idempotencyKey, token: stepUpToken));
    final Result<Receivable> r = await onRefresh(withDocuments);
    if (r case Success<Receivable>(:final Receivable value)) memory.putReceivable(value);
    return r;
  }

  @override
  Future<Result<OverdueReceivablesPage>> overdue(OverdueReceivablesQuery query) async =>
      const Success<OverdueReceivablesPage>(
        OverdueReceivablesPage(page: PageResult<OverdueReceivable>(items: <OverdueReceivable>[])),
      );
}

/// Фейк избранных клиентов.
final class FakeFavoriteCustomers implements FavoriteCustomersRepository {
  final List<String> added = <String>[];
  final List<String> removed = <String>[];
  Result<void> addResult = const Success<void>(null);
  Result<void> removeResult = const Success<void>(null);
  List<Customer> items = <Customer>[
    cashierCustomer(favorite: true),
    cashierCustomer(id: 'c2', name: 'ИП Бакытов', favorite: true, hasDebt: false, overdue: false),
  ];

  @override
  Future<Result<FavoriteCustomersPage>> list({int? limit, String? cursor}) async => Success<FavoriteCustomersPage>(
    FavoriteCustomersPage(
      page: PageResult<Customer>(items: items),
      count: items.length,
    ),
  );

  @override
  Future<Result<void>> add(String customerId, {String? idempotencyKey}) async {
    added.add(customerId);
    return addResult;
  }

  @override
  Future<Result<void>> remove(String customerId) async {
    removed.add(customerId);
    return removeResult;
  }
}

/// Фейк поиска этапа F (`GET /search/customers`).
final class FakeSearch implements CustomersRepository {
  final List<CustomerSearchQuery> calls = <CustomerSearchQuery>[];
  final List<CancelSignal?> cancels = <CancelSignal?>[];
  Future<Result<PageResult<Customer>>> Function(CustomerSearchQuery q) onSearch = (CustomerSearchQuery q) async =>
      Success<PageResult<Customer>>(
        PageResult<Customer>(items: <Customer>[cashierCustomer(match: CustomerMatchType.phone)]),
      );

  @override
  Future<Result<PageResult<Customer>>> search(CustomerSearchQuery query, {CancelSignal? cancel}) {
    calls.add(query);
    cancels.add(cancel);
    return onSearch(query);
  }

  @override
  Future<Result<Customer>> get(String customerId) async => Success<Customer>(cashierCustomer(id: customerId));

  @override
  Future<Result<NewCustomerOutcome>> create(NewCustomerRequest request, {required String idempotencyKey}) async =>
      Success<NewCustomerOutcome>(NewCustomerCreated(cashierCustomer(id: 'new')));
}

/// Фейк избранных товаров.
final class FakeFavoriteProducts implements FavoritesRepository {
  final List<String> removed = <String>[];

  @override
  Future<Result<FavoriteProductsPage>> list({int limit = 50, String? cursor, String? warehouseId}) async =>
      const Success<FavoriteProductsPage>(
        FavoriteProductsPage(
          items: <ProductSummary>[ProductSummary(id: 'p1', name: 'Смеситель Grohe Eurosmart', sku: 'GR-33265')],
          count: 1,
          hasMore: false,
        ),
      );

  @override
  Future<Result<void>> add(String productId, {required String idempotencyKey}) async => const Success<void>(null);

  @override
  Future<Result<void>> remove(String productId) async {
    removed.add(productId);
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> markPending(String productId, {required bool add}) async => const Success<void>(null);

  @override
  Future<Result<void>> confirmPending(String productId) async => const Success<void>(null);

  @override
  Future<Result<Set<String>>> cachedIds() async => const Success<Set<String>>(<String>{});

  @override
  Stream<Set<String>> watchCachedIds() => Stream<Set<String>>.value(const <String>{});
}

/// Обвязка.
final class CustomersHarness {
  CustomersHarness({this.role = RoleCode.cashier, this.online = true, DateTime? now})
    : clock = FixedClock(now ?? kNow) {
    stepUp = StepUpCoordinator(StepUpTokenCache(clock: clock, skew: Duration.zero));
    receivables = FakeReceivables(memory);
  }

  final RoleCode role;
  bool online;
  final FixedClock clock;
  late final StepUpCoordinator stepUp;
  final InMemoryCustomerFinanceMemory memory = InMemoryCustomerFinanceMemory();
  final FakeDirectory directory = FakeDirectory();
  late final FakeReceivables receivables;
  final FakeFavoriteCustomers favorites = FakeFavoriteCustomers();
  final FakeSearch search = FakeSearch();
  final FakeFavoriteProducts products = FakeFavoriteProducts();
  bool debtPayments = false;
  int _keys = 0;

  /// Положить действующий токен детализации (действует [ttl]).
  void grantDetail({Duration ttl = const Duration(minutes: 15), String token = 'detail_token'}) => stepUp.cache.put(
    StepUpGrant(token: token, operation: receivablesDetailOperation, expiresAt: clock.nowUtc().add(ttl), method: 'pin'),
  );

  List<Override> get overrides => <Override>[
    // Без платформенного connectivity_plus (сессия/Dio в тестах не обращаются к каналам ОС).
    connectivityWatcherProvider.overrideWithValue(ConnectivityWatcher(_Net(online))),
    clockProvider.overrideWithValue(clock),
    stepUpCoordinatorProvider.overrideWithValue(stepUp),
    customersViewerProvider.overrideWithValue(CustomersViewer(role: role)),
    newCustomerViewerRoleProvider.overrideWithValue(role),
    customersOnlineProvider.overrideWith((Ref ref) => online),
    newCustomerOnlineProvider.overrideWith((Ref ref) => online),
    newCustomerKeyFactoryProvider.overrideWithValue(() => 'key-${++_keys}'),
    customerFinanceMemoryProvider.overrideWithValue(memory),
    customerDirectoryRepositoryProvider.overrideWithValue(directory),
    receivablesRepositoryProvider.overrideWithValue(receivables),
    favoriteCustomersRepositoryProvider.overrideWithValue(favorites),
    customersRepositoryProvider.overrideWithValue(search),
    customerDebtPaymentsEnabledProvider.overrideWith((Ref ref) => debtPayments),
    favoritesRepositoryProvider.overrideWithValue(products),
    catalogViewerRoleProvider.overrideWithValue(role),
    onlineStatusProvider.overrideWith(
      (Ref ref) => Stream<OnlineStatus>.value(online ? OnlineStatus.online : OnlineStatus.offline),
    ),
  ];

  /// Приложение с экраном [home] в окне [size].
  Widget app(Widget home, {Size size = const Size(390, 844)}) => ProviderScope(
    key: ObjectKey(this),
    overrides: overrides,
    child: materialApp(home, size: size),
  );

  /// `MaterialApp` без `ProviderScope` (для `UncontrolledProviderScope`).
  Widget materialApp(Widget home, {Size size = const Size(390, 844)}) => MaterialApp(
    theme: AppTheme.light(),
    locale: const Locale('ru'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    debugShowCheckedModeBanner: false,
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true, size: size, padding: EdgeInsets.zero),
      child: child!,
    ),
    home: home,
  );

  /// Показать [home] и дождаться загрузки.
  Future<void> pump(WidgetTester tester, Widget home, {Size size = const Size(390, 844)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(home, size: size));
    await settle(tester);
  }
}

/// Несколько кадров (без pumpAndSettle — скелетоны анимированы).
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Ошибка «отмена StepUpDialog» (AuthInterceptor вернул исходный `403 STEP_UP_REQUIRED`).
const Failure kStepUpCancelled = AuthFailure(AuthReason.stepUpRequired, stepUpOperation: receivablesDetailOperation);

/// `429 RATE_LIMITED`.
const Failure kRateLimited = ServerFailure(code: 'RATE_LIMITED', status: 429, retryAfter: Duration(seconds: 30));

/// Нет сети.
const Failure kOffline = NetworkFailure(NetworkFailureKind.offline);

/// Ожидание завершения микрозадач.
Future<void> flush() => Future<void>.delayed(Duration.zero);

/// Нормализация пробелов (NBSP, узкий NBSP — разделители денег и телефона) к обычному пробелу.
String normSpaces(String s) => s.replaceAll(RegExp(r'[\s   ]+'), ' ').trim();

/// Текст с точностью до вида пробелов (`Text` и `RichText`).
Finder findText(String expected) {
  final String want = normSpaces(expected);
  return find.byWidgetPredicate((Widget w) {
    if (w is Text) return normSpaces(w.data ?? w.textSpan?.toPlainText() ?? '') == want;
    return false;
  });
}

/// Содержит текст с точностью до вида пробелов.
Finder findTextContaining(String part) {
  final String want = normSpaces(part);
  return find.byWidgetPredicate((Widget w) {
    if (w is Text) return normSpaces(w.data ?? w.textSpan?.toPlainText() ?? '').contains(want);
    return false;
  });
}

/// Прокрутить к элементу и нажать.
Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
}

final class _Net implements NetworkSignalSource {
  const _Net(this.online);

  final bool online;

  @override
  Future<bool> hasNetwork() async => online;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}
