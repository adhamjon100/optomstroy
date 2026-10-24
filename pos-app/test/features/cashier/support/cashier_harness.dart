// Поддержка тестов экранов кассира SCR-30, SCR-38 и журнала SCR-36/SCR-37 (агент G-fe-cashier): фейки портов
// этапа G (дашборд, справочник клиентов, долги, избранное, журнал), синтетические данные (деньги — целые тыйыны,
// D-19) и обёртка приложения (тема B, локаль ru, размер окна, без анимаций, необязательный go_router с
// маршрутами-метками для проверки переходов).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/audit_record.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_ports.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cashier/cashier_providers.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/cashier/domain/repositories/cashier_repository.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_history.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/favorite_customers_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/receivables_repository.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/domain/repositories/transactions_repository.dart';
import 'package:optomstroy/features/transactions/presentation/providers/transactions_ports.dart';
import 'package:optomstroy/features/transactions/transactions_providers.dart';

import '../../../support/f_fakes.dart';

/// «Сейчас» тестов: 22.10.2026 10:30 по Бишкеку (04:30 UTC).
final DateTime kNow = DateTime.utc(2026, 10, 22, 4, 30);

/// Размеры окон D-18.
const Map<String, Size> kWindows = <String, Size>{
  'compact': Size(390, 844),
  'medium': Size(820, 1000),
  'expanded': Size(1366, 900),
};

Result<T> _unstubbed<T>() => FailureResult<T>(const UnknownFailure(cause: 'not stubbed'));

/// Сумма в формате экрана («16 007,50 сом», разделитель групп — U+202F).
String fmt(int tyiyn) => PriceText.format(Money(tyiyn), fixed2: true);

/// Клиент.
Customer customer(String id, String name, {bool hasDebt = false, bool overdue = false, String? onecRef}) => Customer(
  id: id,
  name: name,
  displayName: name,
  phoneMasked: '+996 555 ** ** 12',
  hasDebt: hasDebt,
  isOverdue: overdue,
  onecRef: onecRef,
);

/// Строка «Ожидают оплаты».
OrderSummary awaiting(
  String id,
  int n, {
  OrderStatus status = OrderStatus.awaitingPayment,
  int tyiyn = 1600750,
  PaymentMethod method = PaymentMethod.cash,
}) => OrderSummary(
  id: id,
  publicNumber: 'POS-2026-${n.toString().padLeft(6, '0')}',
  status: status,
  total: Money(tyiyn),
  totalToPay: Money(tyiyn),
  paidAmount: Money.zero,
  paymentMethod: method,
  customer: customer('cu-$n', 'ОсОО «СтройМир»'),
  createdAt: DateTime.utc(2026, 10, 22, 3, 41),
);

/// Заказ SCR-38: итог 16 850,00 − 5 % (842,50) = 16 007,50 сом (ядро §17.2).
Order payOrder({
  String id = 'o1',
  OrderStatus status = OrderStatus.awaitingPayment,
  PaymentMethod method = PaymentMethod.cash,
  bool isPaid = false,
  int paidTyiyn = 0,
  List<Payment> payments = const <Payment>[],
  DateTime? dueDate,
}) => Order(
  id: id,
  publicNumber: 'POS-2026-000123',
  status: status,
  total: const Money(1600750),
  subtotal: const Money(1685000),
  discountPercent: const Percent(500),
  discountTotal: const Money(84250),
  totalToPay: const Money(1600750),
  paymentMethod: method,
  paidAmount: Money(paidTyiyn),
  isPaid: isPaid,
  paymentDueDate: dueDate,
  customer: customer('cu-1', 'Азамат Б.', onecRef: 'ref-1'),
  items: const <OrderLine>[],
  payments: payments,
);

/// QR-платёж заказа.
Payment qrPayment({
  String id = 'pay-qr',
  PaymentStatus status = PaymentStatus.qrShown,
  bool autoConfirm = true,
  DateTime? expiresAt,
  ReviewReason? review,
  bool withQr = true,
}) => Payment(
  id: id,
  orderId: 'o1',
  method: PaymentMethod.qrBakai,
  status: status,
  amount: const Money(1600750),
  reviewReason: review,
  qr: withQr
      ? QrInfo(
          rawProvider: 'onec',
          payload: '00020101021226',
          issuedAt: DateTime.utc(2026, 10, 22, 4, 20),
          expiresAt: expiresAt ?? DateTime.utc(2026, 10, 22, 4, 44, 32),
          autoConfirm: autoConfirm,
        )
      : null,
);

/// Полученный платёж (ответ `POST /orders/{id}/payments`).
OrderPaymentResult cashResult({int received = 1610000}) => OrderPaymentResult(
  payment: Payment(
    id: 'pay-cash',
    orderId: 'o1',
    method: PaymentMethod.cash,
    status: PaymentStatus.received,
    amount: const Money(1600750),
    receivedAmount: Money(received),
    changeAmount: Money(received - 1600750),
    onec: const PaymentOnecInfo(status: OutboxStatus.pending),
  ),
  orderPaidAmount: const Money(1600750),
  orderIsPaid: true,
  created: true,
);

/// Транзакция.
Transaction tx(
  String id, {
  TransactionKind kind = TransactionKind.paymentReceived,
  int tyiyn = 1600750,
  TransactionSign sign = TransactionSign.plus,
  TransactionStatusGroup group = TransactionStatusGroup.received,
  DateTime? at,
  String number = '1024',
  TransactionSource source = TransactionSource.pos,
  List<TransactionRelated> related = const <TransactionRelated>[],
}) => Transaction(
  id: id,
  kind: kind,
  number: number,
  occurredAt: at ?? DateTime.utc(2026, 10, 22, 3, 42),
  amount: Money(tyiyn),
  status: group.value,
  sign: sign,
  statusGroup: group,
  customer: const TransactionCustomerRef(id: 'cu-1', displayName: 'Азамат Б.'),
  actor: source == TransactionSource.pos ? const UserRef(id: 'u1', displayName: 'Абдулла') : null,
  source: source,
  related: related,
);

/// Дашборд по умолчанию (все блоки заполнены).
PosDashboard dashboard({
  List<OrderSummary>? awaitingPayment,
  List<Payment> qrPending = const <Payment>[],
  List<Payment> manualConfirm = const <Payment>[],
  List<PosDashboardOverdueItem>? overdue,
  List<Customer>? favorites,
  List<Transaction>? recent,
  DashboardSyncOverall overall = DashboardSyncOverall.ok,
  DateTime? receivablesAsOf,
  int unread = 3,
}) => PosDashboard(
  date: DateTime.utc(2026, 10, 22),
  totals: const PosDashboardTotals(
    cash: Money(4520050),
    qr: Money(1600750),
    credit: Money(845000),
    ordersCount: 12,
    paymentsCount: 9,
  ),
  awaitingPayment:
      awaitingPayment ??
      <OrderSummary>[
        awaiting('o1', 123),
        awaiting('o2', 124, status: OrderStatus.submitting, tyiyn: 235000, method: PaymentMethod.qrBakai),
      ],
  qrPending: qrPending,
  manualConfirm: manualConfirm,
  qrPendingCount: qrPending.length,
  manualConfirmCount: manualConfirm.length,
  overdue:
      overdue ??
      <PosDashboardOverdueItem>[
        PosDashboardOverdueItem(
          customer: customer('cu-7', 'ИП Асанов'),
          overdueAmount: const Money(420000),
          overdueDays: 12,
          asOf: DateTime.utc(2026, 10, 22, 4),
        ),
      ],
  favoriteCustomers:
      favorites ??
      <Customer>[
        customer('cu-1', 'Азамат Б.', hasDebt: true, onecRef: 'ref-1'),
        customer('cu-2', 'ОсОО «СтройМир»', overdue: true, hasDebt: true),
        customer('cu-3', 'Бакыт Т.'),
      ],
  recentTransactions:
      recent ??
      <Transaction>[
        tx('t1'),
        tx(
          't2',
          kind: TransactionKind.paymentVoided,
          sign: TransactionSign.minus,
          group: TransactionStatusGroup.voided,
        ),
        tx('t3', kind: TransactionKind.orderCreated, group: TransactionStatusGroup.pending, sign: TransactionSign.plus),
      ],
  sync: PosDashboardSync(overall: overall, receivablesAsOf: receivablesAsOf ?? DateTime.utc(2026, 10, 22, 4)),
  notificationsUnread: unread,
);

/// Фейк дашборда.
final class FakeCashierRepository implements CashierRepository {
  Future<Result<PosDashboard>> Function()? onDashboard;
  int calls = 0;

  @override
  Future<Result<PosDashboard>> dashboard({DateTime? date, String? warehouseId}) async {
    calls++;
    return onDashboard?.call() ?? _unstubbed();
  }
}

/// Фейк справочника клиентов (только правила скидок).
final class FakeCustomerDirectory implements CustomerDirectoryRepository {
  Result<DiscountRulesInfo> rules = const Success<DiscountRulesInfo>(
    DiscountRulesInfo(
      rules: <DiscountRule>[
        DiscountRule(
          id: 'r1',
          name: 'Опт от 50 000',
          source: DiscountSource.onec,
          kind: DiscountKind.percent,
          value: '3',
        ),
        DiscountRule(
          id: 'r2',
          name: 'Постоянный клиент',
          source: DiscountSource.onec,
          kind: DiscountKind.percent,
          value: '5',
        ),
      ],
      manualDiscountLimitPercent: Percent(500),
      overrideRoles: <RoleCode>[RoleCode.seniorSeller, RoleCode.admin],
    ),
  );

  @override
  Future<Result<DiscountRulesInfo>> discountRules({String? customerId, String? cartId}) async => rules;

  @override
  Future<Result<Customer>> card(String customerId, {Set<CustomerInclude> include = const <CustomerInclude>{}}) async =>
      _unstubbed();

  @override
  Future<Result<CustomerDiscounts>> discounts(String customerId) async => _unstubbed();

  @override
  Future<Result<CustomerHistory>> history(
    String customerId,
    CustomerHistoryQuery query, {
    CancelSignal? cancel,
  }) async => _unstubbed();

  @override
  Future<Result<PageResult<Customer>>> list(CustomersListQuery query, {CancelSignal? cancel}) async => _unstubbed();
}

/// Фейк долгов.
final class FakeReceivables implements ReceivablesRepository {
  final List<String> refreshed = <String>[];
  Result<Receivable> refreshResult = Success<Receivable>(
    Receivable(
      customerId: 'cu-1',
      balance: const Money(1250000),
      overdueAmount: Money.zero,
      asOf: DateTime.utc(2026, 10, 22, 4, 29),
    ),
  );
  Result<OverdueReceivablesPage>? overduePage;
  final List<OverdueReceivablesQuery> overdueQueries = <OverdueReceivablesQuery>[];

  @override
  Future<Result<Receivable>> get(
    String customerId, {
    bool withDocuments = false,
    bool refresh = false,
    String? stepUpToken,
  }) async => _unstubbed();

  @override
  Future<Result<Receivable>> refresh(
    String customerId, {
    bool withDocuments = false,
    String? idempotencyKey,
    String? stepUpToken,
  }) async {
    refreshed.add(customerId);
    return refreshResult;
  }

  @override
  Future<Result<OverdueReceivablesPage>> overdue(OverdueReceivablesQuery query) async {
    overdueQueries.add(query);
    return overduePage ?? _unstubbed();
  }
}

/// Фейк избранных клиентов.
final class FakeFavorites implements FavoriteCustomersRepository {
  final List<String> calls = <String>[];
  Result<void> removeResult = const Success<void>(null);

  @override
  Future<Result<void>> add(String customerId, {String? idempotencyKey}) async {
    calls.add('add:$customerId');
    return const Success<void>(null);
  }

  @override
  Future<Result<FavoriteCustomersPage>> list({int? limit, String? cursor}) async => _unstubbed();

  @override
  Future<Result<void>> remove(String customerId) async {
    calls.add('remove:$customerId');
    return removeResult;
  }
}

/// Фейк журнала.
final class FakeTransactions implements TransactionsRepository {
  final List<TransactionsQuery> queries = <TransactionsQuery>[];
  Future<Result<TransactionsPage>> Function(TransactionsQuery q)? onList;
  Future<Result<TransactionDetail>> Function(String id)? onGet;

  @override
  Future<Result<TransactionsPage>> list(TransactionsQuery query) async {
    queries.add(query);
    return onList?.call(query) ?? _unstubbed();
  }

  @override
  Future<Result<TransactionDetail>> get(String transactionId) async => onGet?.call(transactionId) ?? _unstubbed();
}

/// Страница журнала.
TransactionsPage txPage(List<Transaction> items, {String? next, TransactionsSummary? summary}) => TransactionsPage(
  page: PageResult<Transaction>(items: items, nextCursor: next, hasMore: next != null),
  summary: summary,
);

/// Деталь транзакции.
TransactionDetail txDetail(Transaction t, {List<AuditRecord> audit = const <AuditRecord>[]}) =>
    TransactionDetail(transaction: t, audit: audit);

/// Фейк `GET /sync/status`.
final class FakeSyncStatusPort implements SyncStatusPort {
  FakeSyncStatusPort(this.value);

  final SyncServerStatus value;

  @override
  Future<Result<SyncServerStatus>> status() async => Success<SyncServerStatus>(value);

  @override
  Future<Result<SyncRunInfo>> run(String runId) async => _unstubbed();

  @override
  Future<Result<SyncRunsPage>> runs({SyncEntity? entity, int limit = 50, String? cursor}) async => _unstubbed();

  @override
  Future<Result<SyncRunInfo>> startRun({
    required SyncEntity entity,
    required SyncMode mode,
    required String idempotencyKey,
    String? stepUpToken,
  }) async => _unstubbed();
}

/// Подмена `GET /sync/status` с сущностями [entities].
Override syncStatusOverride({required List<({String entity, DateTime? last, int errors, bool stale})> entities}) =>
    syncStatusPortProvider.overrideWithValue(
      FakeSyncStatusPort(
        SyncServerStatus(
          onecReachable: false,
          checkedAt: kNow,
          overall: 'failed',
          entities: <SyncServerEntity>[
            for (final ({String entity, DateTime? last, int errors, bool stale}) e in entities)
              SyncServerEntity(
                entityValue: e.entity,
                lastSuccessAt: e.last,
                consecutiveErrors: e.errors,
                isStale: e.stale,
              ),
          ],
        ),
      ),
    );

/// Страница просрочек.
OverdueReceivablesPage overduePageOf(List<({String id, String name, int tyiyn, int days})> rows, {String? next}) =>
    OverdueReceivablesPage(
      page: PageResult<OverdueReceivable>(
        items: <OverdueReceivable>[
          for (final ({String id, String name, int tyiyn, int days}) r in rows)
            OverdueReceivable(
              customer: customer(r.id, r.name),
              balance: Money(r.tyiyn),
              overdueAmount: Money(r.tyiyn),
              overdueDays: r.days,
              asOf: kNow,
            ),
        ],
        nextCursor: next,
        hasMore: next != null,
      ),
      isStale: false,
    );

/// Флаги функций.
PublicFeatureFlags flags({bool returns = true, bool debt = false}) => PublicFeatureFlags(
  customerSelfService: true,
  returnsFromPos: returns,
  qrProvider: QrProviderMode.onec,
  qrWebhook: false,
  debtPaymentsFromPos: debt,
  fromServer: true,
);

/// Обвязка экранов кассира и журнала.
final class CashierHarness {
  CashierHarness({
    this.role = RoleCode.cashier,
    this.online = true,
    this.returns = true,
    this.stepUpCancelled = false,
    this.printerOk = true,
    this.withPrinter = true,
  });

  final RoleCode? role;
  final bool online;
  final bool returns;
  final bool stepUpCancelled;
  final bool printerOk;
  final bool withPrinter;

  final FakeCashierRepository cashier = FakeCashierRepository();
  final FakeCustomerDirectory directory = FakeCustomerDirectory();
  final FakeReceivables receivables = FakeReceivables();
  final FakeFavorites favorites = FakeFavorites();
  final FakeOrdersRepository orders = FakeOrdersRepository();
  final FakePaymentsRepository payments = FakePaymentsRepository();
  final FakeCustomersRepository customers = FakeCustomersRepository();
  final FakeTransactions transactions = FakeTransactions();
  final FixedClock clock = FixedClock(kNow);
  final List<String> stepUps = <String>[];
  final List<String> printed = <String>[];
  int _key = 0;

  /// Дополнительные подмены теста.
  final List<Override> extraOverrides = <Override>[];

  List<Override> get overrides => <Override>[
    ...extraOverrides,
    cashierRepositoryProvider.overrideWithValue(cashier),
    customerDirectoryRepositoryProvider.overrideWithValue(directory),
    receivablesRepositoryProvider.overrideWithValue(receivables),
    favoriteCustomersRepositoryProvider.overrideWithValue(favorites),
    customerFinanceMemoryProvider.overrideWithValue(InMemoryCustomerFinanceMemory()),
    customersRepositoryProvider.overrideWithValue(customers),
    ordersRepositoryProvider.overrideWithValue(orders),
    paymentsRepositoryProvider.overrideWithValue(payments),
    transactionsRepositoryProvider.overrideWithValue(transactions),
    clockProvider.overrideWithValue(clock),
    publicFeatureFlagsProvider.overrideWithValue(flags(returns: returns)),
    cashierViewerRoleProvider.overrideWithValue(role),
    cashierOnlineProvider.overrideWithValue(online),
    cashierSessionLockedProvider.overrideWithValue(false),
    cashierSessionScopeProvider.overrideWithValue('u1'),
    cashierDashboardPollProvider.overrideWithValue(null),
    cashierKeyFactoryProvider.overrideWithValue(() => 'key-${++_key}'),
    cashierStepUpProvider.overrideWithValue((String op) async {
      stepUps.add(op);
      return (cancelled: stepUpCancelled, token: stepUpCancelled ? null : 'step-up-token');
    }),
    cashierReceiptPrinterProvider.overrideWithValue(
      withPrinter
          ? (OrderDocumentFile f) async {
              printed.add(f.fileName);
              return printerOk;
            }
          : null,
    ),
    transactionsViewerRoleProvider.overrideWithValue(role),
    transactionsOnlineProvider.overrideWithValue(online),
    transactionsReturnsEnabledProvider.overrideWithValue(returns),
    transactionsKeyFactoryProvider.overrideWithValue(() => 'tkey-${++_key}'),
    transactionsStepUpProvider.overrideWithValue((String op) async {
      stepUps.add(op);
      return (cancelled: stepUpCancelled, token: stepUpCancelled ? null : 'step-up-token');
    }),
  ];

  Widget _shell(Widget child, Size size) => MediaQuery(
    data: MediaQueryData(size: size, disableAnimations: true),
    child: child,
  );

  /// Приложение с экраном [home].
  Widget app(Widget home, {Size size = const Size(1366, 900)}) => ProviderScope(
    key: ObjectKey(this),
    overrides: overrides,
    child: MaterialApp(
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
    ),
  );

  /// Последний адрес, открытый маршрутизатором ([routerApp]).
  final List<String> visited = <String>[];

  /// Приложение с go_router: [home] на [homePath], прочие маршруты — метки «loc:{uri}».
  Widget routerApp(String homePath, Widget Function(GoRouterState s) home, {Size size = const Size(1366, 900)}) {
    Widget label(BuildContext c, GoRouterState s) {
      visited.add(s.uri.toString());
      return Scaffold(body: Text('loc:${s.uri}'));
    }

    final List<String> others = <String>[
      '/payments/new',
      '/customers',
      '/customers/new',
      '/customers/:id',
      '/customers/:id/receivables',
      '/transactions',
      '/transactions/:id',
      '/orders/:id',
      '/favorites',
      '/catalog',
      '/sync',
      '/notifications',
      '/returns/new',
      '/returns/:id',
      '/cart/parked',
      '/admin/audit',
      '/profile',
      '/settings',
    ]..remove(homePath);
    final GoRouter router = GoRouter(
      initialLocation: homePath,
      routes: <RouteBase>[
        GoRoute(path: homePath, builder: (BuildContext c, GoRouterState s) => home(s)),
        for (final String p in others) GoRoute(path: p, builder: label),
      ],
    );
    return ProviderScope(
      key: ObjectKey(this),
      overrides: overrides,
      child: MaterialApp.router(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => _shell(child!, size),
      ),
    );
  }

  /// Показать [home] в окне [size] и дождаться загрузки.
  Future<void> pump(WidgetTester tester, Widget home, {Size size = const Size(1366, 900)}) async {
    _view(tester, size);
    await tester.pumpWidget(app(home, size: size));
    await settle(tester);
  }

  /// Показать экран через маршрутизатор.
  Future<void> pumpRouter(
    WidgetTester tester,
    String homePath,
    Widget Function(GoRouterState s) home, {
    Size size = const Size(1366, 900),
  }) async {
    _view(tester, size);
    await tester.pumpWidget(routerApp(homePath, home, size: size));
    await settle(tester);
  }

  void _view(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }

  /// Несколько кадров (без `pumpAndSettle`: на экранах есть периодические таймеры и скелетоны).
  static Future<void> settle(WidgetTester tester, [int frames = 6]) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

/// Завершить ожидание фейкового потока (тест-утилита).
Future<void> flushMicrotasks() => Future<void>.delayed(Duration.zero);

/// Вызовы, не дождавшиеся ответа (для проверки «один запрос»).
Completer<T> pending<T>() => Completer<T>();
