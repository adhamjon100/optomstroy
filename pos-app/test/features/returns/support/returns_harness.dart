// Поддержка тестов SCR-39 (агент G-fe-returns): фейк порта заявок (журнал вызовов, обработчики `on<Метод>`),
// синтетический заказ (деньги — целые тыйыны, D-19) и обвязка приложения (тема B, локаль ru, размер окна, без
// анимаций, детерминированные ключи идемпотентности, фейк step-up).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';
import 'package:optomstroy/features/returns/domain/repositories/returns_repository.dart';
import 'package:optomstroy/features/returns/presentation/providers/returns_ports.dart';
import 'package:optomstroy/features/returns/returns_providers.dart';

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

/// Фейк `ReturnsRepository`.
final class FakeReturnsRepository implements ReturnsRepository {
  final List<FakeCall> calls = <FakeCall>[];
  Future<Result<ReturnRequest>> Function(String id)? onGet;
  Future<Result<ReturnRequest>> Function(ReturnDraftInput input, String key)? onCreate;
  Future<Result<ReturnRequest>> Function(String id, ReturnDraftPatch patch)? onUpdate;
  Future<Result<void>> Function(String id, int rowVersion)? onDelete;
  Future<Result<ReturnRequest>> Function(String id, int rowVersion, String key, String? stepUp)? onSubmit;
  Future<Result<ReturnRequest>> Function(String id, int rowVersion, String key, String? stepUp)? onAccept;
  Future<Result<ReturnRequest>> Function(String id, String reason, int rowVersion, String key, String? stepUp)?
  onReject;

  /// Вызовы метода [method].
  List<FakeCall> of(String method) => calls.where((FakeCall c) => c.method == method).toList();

  @override
  Future<Result<PageResult<ReturnRequest>>> list(ReturnsQuery query) async {
    calls.add((method: 'list', args: <Object?>[query]));
    return _unstubbed();
  }

  @override
  Future<Result<ReturnRequest>> get(String returnId) async {
    calls.add((method: 'get', args: <Object?>[returnId]));
    return onGet?.call(returnId) ?? _unstubbed();
  }

  @override
  Future<Result<ReturnRequest>> create(ReturnDraftInput input, {required String idempotencyKey}) async {
    calls.add((method: 'create', args: <Object?>[input, idempotencyKey]));
    return onCreate?.call(input, idempotencyKey) ?? _unstubbed();
  }

  @override
  Future<Result<ReturnRequest>> update(String returnId, ReturnDraftPatch patch, {String? idempotencyKey}) async {
    calls.add((method: 'update', args: <Object?>[returnId, patch]));
    return onUpdate?.call(returnId, patch) ?? _unstubbed();
  }

  @override
  Future<Result<void>> delete(String returnId, {required int rowVersion}) async {
    calls.add((method: 'delete', args: <Object?>[returnId, rowVersion]));
    return onDelete?.call(returnId, rowVersion) ?? _unstubbed();
  }

  @override
  Future<Result<ReturnRequest>> submit(
    String returnId, {
    required int rowVersion,
    required String idempotencyKey,
    String? comment,
    String? stepUpToken,
  }) async {
    calls.add((method: 'submit', args: <Object?>[returnId, rowVersion, idempotencyKey, stepUpToken]));
    return onSubmit?.call(returnId, rowVersion, idempotencyKey, stepUpToken) ?? _unstubbed();
  }

  @override
  Future<Result<ReturnRequest>> accept(
    String returnId, {
    required int rowVersion,
    required String idempotencyKey,
    String? comment,
    String? stepUpToken,
  }) async {
    calls.add((method: 'accept', args: <Object?>[returnId, rowVersion, idempotencyKey, stepUpToken]));
    return onAccept?.call(returnId, rowVersion, idempotencyKey, stepUpToken) ?? _unstubbed();
  }

  @override
  Future<Result<ReturnRequest>> reject(
    String returnId, {
    required String reason,
    required int rowVersion,
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add((method: 'reject', args: <Object?>[returnId, reason, rowVersion, idempotencyKey, stepUpToken]));
    return onReject?.call(returnId, reason, rowVersion, idempotencyKey, stepUpToken) ?? _unstubbed();
  }
}

const Customer kCustomer = Customer(id: 'cu-1', name: 'ОсОО «СтройМир»', displayName: 'ОсОО «СтройМир»');

/// Строки заказа: 1 — отгружено 2, возвращено 0; 2 — возвращено полностью; 3 — нет данных о прежних возвратах.
List<OrderLine> orderLines() => <OrderLine>[
  OrderLine(
    lineNo: 1,
    variantId: 'v1',
    productName: 'Смеситель для кухни Frap F4252',
    variantName: 'хром',
    quantity: const LineQuantity(value: Qty(2000), unitId: 'pcs'),
    unitPrice: Money.som(2350),
    lineTotal: Money.som(4700),
    shippedQuantity: const Qty(2000),
    returnedQuantity: Qty.zero,
  ),
  OrderLine(
    lineNo: 2,
    variantId: 'v2',
    productName: 'Унитаз-компакт Santek Бриз',
    quantity: const LineQuantity(value: Qty(1000), unitId: 'pcs'),
    unitPrice: Money.som(9400),
    lineTotal: const Money(855750),
    shippedQuantity: const Qty(1000),
    returnedQuantity: const Qty(1000),
  ),
  OrderLine(
    lineNo: 3,
    variantId: 'v3',
    productName: 'Труба полипропиленовая PN20 20 мм',
    quantity: const LineQuantity(value: Qty(25000), unitId: 'm'),
    unitPrice: Money.som(110),
    lineTotal: Money.som(2750),
    shippedQuantity: const Qty(25000),
  ),
];

/// Заказ-источник (по умолчанию — отгружен, с реализацией 1С).
Order sourceOrder({OrderStatus status = OrderStatus.shipped, String? onecNumber = 'УТ-0001234'}) => Order(
  id: 'o1',
  publicNumber: 'POS-2026-000123',
  status: status,
  total: const Money(1600750),
  paymentMethod: PaymentMethod.cash,
  customer: kCustomer,
  createdAt: DateTime.utc(2026, 10, 18, 5),
  onec: onecNumber == null ? null : OrderOnecInfo(number: onecNumber, date: DateTime.utc(2026, 10, 18, 6)),
  items: orderLines(),
);

/// Заявка.
ReturnRequest returnRequest({
  ReturnRequestStatus status = ReturnRequestStatus.draft,
  int rowVersion = 1,
  ReturnReason reason = ReturnReason.defect,
  String? comment,
  UserRef createdBy = const UserRef(id: 'u1', displayName: 'Айгуль'),
  ReturnApprovalReason? approvalReason,
  List<ReturnRequestItem>? items,
}) => ReturnRequest(
  id: 'r1',
  publicNumber: 'RET-2026-000012',
  status: status,
  orderId: 'o1',
  shipmentNumber: 'УТ-0001234',
  customerId: 'cu-1',
  reasonCode: reason,
  reasonComment: comment,
  items:
      items ??
      <ReturnRequestItem>[
        const ReturnRequestItem(
          orderLineNo: 1,
          variantId: 'v1',
          quantity: LineQuantity(value: Qty(1000), unitId: 'pcs'),
          maxReturnable: Qty(2000),
          amount: Money(235000),
        ),
      ],
  totalAmount: const Money(235000),
  approvalReason: approvalReason,
  rowVersion: rowVersion,
  createdBy: createdBy,
  createdAt: DateTime.utc(2026, 10, 22, 3, 10),
  updatedAt: DateTime.utc(2026, 10, 22, 4, 20),
);

/// Тестовая обвязка SCR-39.
final class ReturnsHarness {
  ReturnsHarness({
    FakeReturnsRepository? returns,
    FakeOrdersRepository? orders,
    this.role = RoleCode.cashier,
    this.userId = 'u1',
    this.online = true,
    this.returnsEnabled = true,
    this.flagsFromServer = true,
    this.stepUpCancelled = false,
    Order? order,
  }) : returns = returns ?? FakeReturnsRepository(),
       orders = orders ?? FakeOrdersRepository() {
    final Order o = order ?? sourceOrder();
    this.orders.onGet ??= (String id, bool refresh) async => Success<OrderDetails>(OrderDetails(order: o));
  }

  final FakeReturnsRepository returns;
  final FakeOrdersRepository orders;
  final RoleCode? role;
  final String? userId;
  final bool online;
  final bool returnsEnabled;
  final bool flagsFromServer;
  final bool stepUpCancelled;
  final List<String> stepUps = <String>[];
  int _keys = 0;

  /// Дополнительные подмены теста.
  final List<Override> extraOverrides = <Override>[];

  List<Override> get overrides => <Override>[
    ...extraOverrides,
    returnsRepositoryProvider.overrideWithValue(returns),
    ordersRepositoryProvider.overrideWithValue(orders),
    returnsViewerProvider.overrideWithValue(ReturnsViewer(role: role, userId: userId)),
    returnsOnlineProvider.overrideWithValue(online),
    publicFeatureFlagsProvider.overrideWithValue(
      PublicFeatureFlags(
        customerSelfService: false,
        returnsFromPos: returnsEnabled,
        qrProvider: QrProviderMode.none,
        qrWebhook: false,
        debtPaymentsFromPos: false,
        fromServer: flagsFromServer,
      ),
    ),
    clockProvider.overrideWithValue(FixedClock(kNow)),
    returnsKeyFactoryProvider.overrideWithValue(() => 'key-${++_keys}'),
    returnsStepUpProvider.overrideWithValue((String op) async {
      stepUps.add(op);
      return (cancelled: stepUpCancelled, token: stepUpCancelled ? null : 'step-up-token');
    }),
  ];

  /// Приложение с экраном [home] в окне [size].
  Widget app(Widget home, {Size size = const Size(390, 844)}) => ProviderScope(
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

  /// Показать [home] в окне [size] и дождаться загрузки.
  Future<void> pump(WidgetTester tester, Widget home, {Size size = const Size(390, 844)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(home, size: size));
    await tester.pump();
    await tester.pump();
  }
}
