// Фейки портов этапа F для widget- и unit-тестов экранов (агенты F-fe-cart, F-fe-checkout, F-fe-orders, F-fe-notif).
//
// Подключение:
//   ProviderScope(overrides: [
//     cartRepositoryProvider.overrideWithValue(fakes.cart),
//     ordersRepositoryProvider.overrideWithValue(fakes.orders),
//     paymentsRepositoryProvider.overrideWithValue(fakes.payments),
//     checkoutRepositoryProvider.overrideWithValue(fakes.checkout),
//     checkoutDraftRepositoryProvider.overrideWithValue(fakes.checkoutDraft),
//     customersRepositoryProvider.overrideWithValue(fakes.customers),
//     notificationsRepositoryProvider.overrideWithValue(fakes.notifications),
//   ], child: …)
// или `...fakes.overrides` (FFakes). Каждый метод возвращает значение из поля-обработчика (`on<Метод>`), по умолчанию —
// `UnknownFailure(cause: 'not stubbed')`; вызовы пишутся в `calls` (имя метода и аргументы) — для проверок
// «один запрос», «тот же ключ идемпотентности» и т. п.
import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/checkout/checkout_providers.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/checkout/domain/repositories/checkout_repository.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/new_customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';
import 'package:optomstroy/features/notifications/domain/repositories/notifications_repository.dart';
import 'package:optomstroy/features/notifications/notifications_providers.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/domain/repositories/orders_repository.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';

/// Вызов фейка: метод и аргументы.
typedef FakeCall = ({String method, List<Object?> args});

Result<T> _unstubbed<T>() => FailureResult<T>(const UnknownFailure(cause: 'not stubbed'));

/// Пустая активная корзина (`GET /cart` без строк).
Cart emptyCart({String id = 'cart-1', int rowVersion = 1}) =>
    Cart(id: id, status: CartStatus.active, items: const <CartLine>[], rowVersion: rowVersion);

final class FakeCartRepository implements CartRepository {
  final List<FakeCall> calls = <FakeCall>[];
  Future<Result<Cart>> Function()? onFetch;
  Future<Result<Cart>> Function(String variantId, CartItemPut put, String? key)? onPutItem;
  Future<Result<Cart>> Function(String variantId, String? packagingId)? onDeleteItem;
  Future<Result<Cart>> Function(int rowVersion)? onClear;
  Future<Result<Cart>> Function(String warehouseId, int rowVersion)? onSetWarehouse;
  Future<Result<Cart>> Function(String customerId, int rowVersion, Receiver? receiver)? onSetCustomer;
  Future<Result<Cart>> Function()? onClearCustomer;
  Future<Result<Cart>> Function(CartDiscountInput input, String? stepUpToken)? onApplyDiscount;
  Future<Result<CartParkResult>> Function(int rowVersion, String? name, String key)? onPark;
  Future<Result<PageResult<CartParkedSummary>>> Function(ParkedScope scope, String? cursor)? onListParked;
  Future<Result<Cart>> Function(String cartId, bool replaceActive)? onResumeParked;
  Future<Result<void>> Function(String cartId)? onDeleteParked;
  Cart? Function(Failure failure)? onConflictCurrent;
  List<CartConflict> Function(Failure failure)? onProblemConflicts;

  void _log(String method, List<Object?> args) => calls.add((method: method, args: args));

  @override
  Future<Result<Cart>> fetch({bool revalidate = true}) async {
    _log('fetch', <Object?>[revalidate]);
    return onFetch?.call() ?? _unstubbed();
  }

  @override
  Future<Result<Cart>> putItem(String variantId, CartItemPut put, {String? idempotencyKey}) async {
    _log('putItem', <Object?>[variantId, put, idempotencyKey]);
    return onPutItem?.call(variantId, put, idempotencyKey) ?? _unstubbed();
  }

  @override
  Future<Result<Cart>> deleteItem(String variantId, {String? packagingId, String? idempotencyKey}) async {
    _log('deleteItem', <Object?>[variantId, packagingId, idempotencyKey]);
    return onDeleteItem?.call(variantId, packagingId) ?? _unstubbed();
  }

  @override
  Future<Result<Cart>> clear({required int rowVersion}) async {
    _log('clear', <Object?>[rowVersion]);
    return onClear?.call(rowVersion) ?? _unstubbed();
  }

  @override
  Future<Result<Cart>> setWarehouse(String warehouseId, {required int rowVersion, String? idempotencyKey}) async {
    _log('setWarehouse', <Object?>[warehouseId, rowVersion, idempotencyKey]);
    return onSetWarehouse?.call(warehouseId, rowVersion) ?? _unstubbed();
  }

  @override
  Future<Result<Cart>> setCustomer(
    String customerId, {
    required int rowVersion,
    Receiver? receiver,
    String? idempotencyKey,
  }) async {
    _log('setCustomer', <Object?>[customerId, rowVersion, receiver, idempotencyKey]);
    return onSetCustomer?.call(customerId, rowVersion, receiver) ?? _unstubbed();
  }

  @override
  Future<Result<Cart>> clearCustomer({String? idempotencyKey}) async {
    _log('clearCustomer', <Object?>[idempotencyKey]);
    return onClearCustomer?.call() ?? _unstubbed();
  }

  @override
  Future<Result<Cart>> applyDiscount(CartDiscountInput input, {String? idempotencyKey, String? stepUpToken}) async {
    _log('applyDiscount', <Object?>[input, idempotencyKey, stepUpToken]);
    return onApplyDiscount?.call(input, stepUpToken) ?? _unstubbed();
  }

  @override
  Future<Result<CartParkResult>> park({required int rowVersion, String? name, required String idempotencyKey}) async {
    _log('park', <Object?>[rowVersion, name, idempotencyKey]);
    return onPark?.call(rowVersion, name, idempotencyKey) ?? _unstubbed();
  }

  @override
  Future<Result<PageResult<CartParkedSummary>>> listParked({
    ParkedScope scope = ParkedScope.own,
    String? cursor,
    int limit = 50,
  }) async {
    _log('listParked', <Object?>[scope, cursor, limit]);
    return onListParked?.call(scope, cursor) ?? _unstubbed();
  }

  @override
  Future<Result<Cart>> resumeParked(String cartId, {bool replaceActive = false, String? idempotencyKey}) async {
    _log('resumeParked', <Object?>[cartId, replaceActive, idempotencyKey]);
    return onResumeParked?.call(cartId, replaceActive) ?? _unstubbed();
  }

  @override
  Future<Result<void>> deleteParked(String cartId) async {
    _log('deleteParked', <Object?>[cartId]);
    return onDeleteParked?.call(cartId) ?? _unstubbed();
  }

  @override
  Cart? conflictCurrent(Failure failure) => onConflictCurrent?.call(failure);

  @override
  List<CartConflict> problemConflicts(Failure failure) => onProblemConflicts?.call(failure) ?? const <CartConflict>[];
}

final class FakeOrdersRepository implements OrdersRepository {
  final List<FakeCall> calls = <FakeCall>[];
  Future<Result<OrdersPage>> Function(OrdersQuery query)? onList;
  Future<Result<OrderSummary?>> Function(String key)? onFindByIdempotencyKey;
  Future<Result<OrderDetails>> Function(String orderId, bool refreshFromOnec)? onGet;
  Future<Result<Order>> Function(String orderId, OrderCancelRequest request, String key, String? stepUp)? onCancel;
  Future<Result<OrderDocumentFile>> Function(String orderId, OrderDocumentKind kind, PrintPaper format, bool copy)?
  onDocument;
  Future<Result<WaybillStatus>> Function(String orderId)? onWaybill;
  Future<Result<Order>> Function(String orderId, OrderOnecLinkRequest request, String key, String? stepUp)? onLinkOnec;

  @override
  Future<Result<OrdersPage>> list(OrdersQuery query) async {
    calls.add((method: 'list', args: <Object?>[query]));
    return onList?.call(query) ?? _unstubbed();
  }

  @override
  Future<Result<OrderSummary?>> findByIdempotencyKey(String idempotencyKey) async {
    calls.add((method: 'findByIdempotencyKey', args: <Object?>[idempotencyKey]));
    return onFindByIdempotencyKey?.call(idempotencyKey) ?? _unstubbed();
  }

  @override
  Future<Result<OrderDetails>> get(String orderId, {bool refreshFromOnec = false}) async {
    calls.add((method: 'get', args: <Object?>[orderId, refreshFromOnec]));
    return onGet?.call(orderId, refreshFromOnec) ?? _unstubbed();
  }

  @override
  Future<Result<Order>> cancel(
    String orderId,
    OrderCancelRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add((method: 'cancel', args: <Object?>[orderId, request, idempotencyKey, stepUpToken]));
    return onCancel?.call(orderId, request, idempotencyKey, stepUpToken) ?? _unstubbed();
  }

  @override
  Future<Result<OrderDocumentFile>> document(
    String orderId,
    OrderDocumentKind kind, {
    PrintPaper format = PrintPaper.a4,
    bool copy = false,
  }) async {
    calls.add((method: 'document', args: <Object?>[orderId, kind, format, copy]));
    return onDocument?.call(orderId, kind, format, copy) ?? _unstubbed();
  }

  @override
  Future<Result<WaybillStatus>> waybill(String orderId) async {
    calls.add((method: 'waybill', args: <Object?>[orderId]));
    return onWaybill?.call(orderId) ?? _unstubbed();
  }

  @override
  Future<Result<Order>> linkOnec(
    String orderId,
    OrderOnecLinkRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add((method: 'linkOnec', args: <Object?>[orderId, request, idempotencyKey, stepUpToken]));
    return onLinkOnec?.call(orderId, request, idempotencyKey, stepUpToken) ?? _unstubbed();
  }
}

final class FakePaymentsRepository implements PaymentsRepository {
  final List<FakeCall> calls = <FakeCall>[];
  Future<Result<List<Payment>>> Function(String orderId)? onListForOrder;
  Future<Result<OrderPaymentResult>> Function(String orderId, OrderPaymentRequest request, String key)?
  onCreateForOrder;
  Future<Result<PaymentDetails>> Function(String paymentId, bool refreshStatus)? onGet;

  /// Поток ожидания оплаты: тест управляет им (`watchController.add(Success(...))`) и закрывает ([dispose]).
  // ignore: close_sinks — закрывает тест через dispose()
  final StreamController<Result<PaymentDetails>> watchController = StreamController<Result<PaymentDetails>>.broadcast();

  /// Закрыть поток ожидания.
  Future<void> dispose() => watchController.close();
  Future<Result<Payment>> Function(String paymentId, ConfirmManualRequest request, String key, String? stepUp)?
  onConfirmManual;
  Future<Result<Payment>> Function(String paymentId, VoidPaymentRequest request, String key, String? stepUp)? onVoid;

  @override
  Future<Result<List<Payment>>> listForOrder(String orderId) async {
    calls.add((method: 'listForOrder', args: <Object?>[orderId]));
    return onListForOrder?.call(orderId) ?? _unstubbed();
  }

  @override
  Future<Result<OrderPaymentResult>> createForOrder(
    String orderId,
    OrderPaymentRequest request, {
    required String idempotencyKey,
  }) async {
    calls.add((method: 'createForOrder', args: <Object?>[orderId, request, idempotencyKey]));
    return onCreateForOrder?.call(orderId, request, idempotencyKey) ?? _unstubbed();
  }

  @override
  Future<Result<PaymentDetails>> get(String paymentId, {bool refreshStatus = false}) async {
    calls.add((method: 'get', args: <Object?>[paymentId, refreshStatus]));
    return onGet?.call(paymentId, refreshStatus) ?? _unstubbed();
  }

  @override
  Stream<Result<PaymentDetails>> watch(String paymentId, {Duration wait = const Duration(seconds: 25)}) {
    calls.add((method: 'watch', args: <Object?>[paymentId, wait]));
    return watchController.stream;
  }

  @override
  Future<Result<Payment>> confirmManual(
    String paymentId,
    ConfirmManualRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add((method: 'confirmManual', args: <Object?>[paymentId, request, idempotencyKey, stepUpToken]));
    return onConfirmManual?.call(paymentId, request, idempotencyKey, stepUpToken) ?? _unstubbed();
  }

  @override
  Future<Result<Payment>> voidPayment(
    String paymentId,
    VoidPaymentRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add((method: 'voidPayment', args: <Object?>[paymentId, request, idempotencyKey, stepUpToken]));
    return onVoid?.call(paymentId, request, idempotencyKey, stepUpToken) ?? _unstubbed();
  }
}

final class FakeCheckoutRepository implements CheckoutRepository {
  final List<FakeCall> calls = <FakeCall>[];
  Future<Result<CheckoutPreview>> Function(CheckoutPreviewRequest request)? onPreview;
  Future<Result<OrderCreateResult>> Function(OrderCreateRequest request, String key, String? stepUp)? onCreateOrder;
  Future<Result<OrderSummary?>> Function(String key)? onFindSubmittedOrder;

  @override
  Future<Result<CheckoutPreview>> preview(CheckoutPreviewRequest request, {String? idempotencyKey}) async {
    calls.add((method: 'preview', args: <Object?>[request, idempotencyKey]));
    return onPreview?.call(request) ?? _unstubbed();
  }

  @override
  Future<Result<OrderCreateResult>> createOrder(
    OrderCreateRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add((method: 'createOrder', args: <Object?>[request, idempotencyKey, stepUpToken]));
    return onCreateOrder?.call(request, idempotencyKey, stepUpToken) ?? _unstubbed();
  }

  @override
  Future<Result<OrderSummary?>> findSubmittedOrder(String idempotencyKey) async {
    calls.add((method: 'findSubmittedOrder', args: <Object?>[idempotencyKey]));
    return onFindSubmittedOrder?.call(idempotencyKey) ?? _unstubbed();
  }
}

/// Черновик оформления в памяти (ключ `POST /orders` создаётся один раз — как drift-реализация).
final class InMemoryCheckoutDraftRepository implements CheckoutDraftRepository {
  InMemoryCheckoutDraftRepository({String Function()? newKey}) : _newKey = newKey ?? (() => 'order-key-1');

  final String Function() _newKey;
  final Map<String, CheckoutDraft> drafts = <String, CheckoutDraft>{};

  CheckoutDraft _blank(String id) =>
      CheckoutDraft(localCartId: id, step: CheckoutStep.customer, updatedAt: DateTime.utc(2026));

  @override
  Future<Result<CheckoutDraft?>> load(String localCartId) async => Success<CheckoutDraft?>(drafts[localCartId]);

  @override
  Future<Result<CheckoutDraft>> save(CheckoutDraft draft) async {
    final CheckoutDraft? prev = drafts[draft.localCartId];
    final CheckoutDraft merged = CheckoutDraft(
      localCartId: draft.localCartId,
      step: draft.step,
      customerId: draft.customerId,
      deliveryMethod: draft.deliveryMethod,
      receiverKind: draft.receiverKind,
      paymentMethod: draft.paymentMethod,
      orderIdempotencyKey: prev?.orderIdempotencyKey,
      submittedAt: prev?.submittedAt,
      updatedAt: draft.updatedAt,
    );
    drafts[draft.localCartId] = merged;
    return Success<CheckoutDraft>(merged);
  }

  @override
  Future<Result<String>> ensureOrderKey(String localCartId) async {
    final CheckoutDraft d = drafts[localCartId] ?? _blank(localCartId);
    final String key = d.orderIdempotencyKey ?? _newKey();
    drafts[localCartId] = CheckoutDraft(
      localCartId: localCartId,
      step: d.step,
      customerId: d.customerId,
      deliveryMethod: d.deliveryMethod,
      receiverKind: d.receiverKind,
      paymentMethod: d.paymentMethod,
      orderIdempotencyKey: key,
      submittedAt: d.submittedAt,
      updatedAt: d.updatedAt,
    );
    return Success<String>(key);
  }

  @override
  Future<Result<void>> markSubmitted(String localCartId) async {
    final CheckoutDraft d = drafts[localCartId] ?? _blank(localCartId);
    drafts[localCartId] = CheckoutDraft(
      localCartId: localCartId,
      step: d.step,
      customerId: d.customerId,
      deliveryMethod: d.deliveryMethod,
      receiverKind: d.receiverKind,
      paymentMethod: d.paymentMethod,
      orderIdempotencyKey: d.orderIdempotencyKey,
      submittedAt: DateTime.utc(2026),
      updatedAt: d.updatedAt,
    );
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> clear(String localCartId) async {
    drafts.remove(localCartId);
    return const Success<void>(null);
  }

  @override
  Future<Result<List<CheckoutDraft>>> pendingSubmissions() async => Success<List<CheckoutDraft>>(<CheckoutDraft>[
    for (final CheckoutDraft d in drafts.values)
      if (d.submittedAt != null && d.orderIdempotencyKey != null) d,
  ]);
}

final class FakeCustomersRepository implements CustomersRepository {
  final List<FakeCall> calls = <FakeCall>[];
  Future<Result<PageResult<Customer>>> Function(CustomerSearchQuery query)? onSearch;
  Future<Result<Customer>> Function(String customerId)? onGet;
  Future<Result<NewCustomerOutcome>> Function(NewCustomerRequest request, String key)? onCreate;

  @override
  Future<Result<PageResult<Customer>>> search(CustomerSearchQuery query, {CancelSignal? cancel}) async {
    calls.add((method: 'search', args: <Object?>[query]));
    return onSearch?.call(query) ?? _unstubbed();
  }

  @override
  Future<Result<Customer>> get(String customerId) async {
    calls.add((method: 'get', args: <Object?>[customerId]));
    return onGet?.call(customerId) ?? _unstubbed();
  }

  @override
  Future<Result<NewCustomerOutcome>> create(NewCustomerRequest request, {required String idempotencyKey}) async {
    calls.add((method: 'create', args: <Object?>[request, idempotencyKey]));
    return onCreate?.call(request, idempotencyKey) ?? _unstubbed();
  }
}

final class FakeNotificationsRepository implements NotificationsRepository {
  final List<FakeCall> calls = <FakeCall>[];
  Future<Result<NotificationsPage>> Function(NotificationsQuery query)? onList;
  Future<Result<int>> Function(String id)? onMarkRead;
  Future<Result<int>> Function()? onMarkAllRead;

  /// Кэш (офлайн) — тест задаёт напрямую.
  List<AppNotification> cached = const <AppNotification>[];

  @override
  Future<Result<NotificationsPage>> list(NotificationsQuery query) async {
    calls.add((method: 'list', args: <Object?>[query]));
    return onList?.call(query) ?? _unstubbed();
  }

  @override
  Future<Result<int>> markRead(String notificationId, {String? idempotencyKey}) async {
    calls.add((method: 'markRead', args: <Object?>[notificationId, idempotencyKey]));
    return onMarkRead?.call(notificationId) ?? _unstubbed();
  }

  /// `before` последнего `markAllRead` (OpenAPI 1.2.0, 08 §4.16.2).
  DateTime? lastMarkAllReadBefore;

  @override
  Future<Result<int>> markAllRead({String? idempotencyKey, DateTime? before}) async {
    lastMarkAllReadBefore = before;
    calls.add((method: 'markAllRead', args: <Object?>[idempotencyKey]));
    return onMarkAllRead?.call() ?? _unstubbed();
  }

  @override
  Stream<List<AppNotification>> watchCached({bool unreadOnly = false}) =>
      Stream<List<AppNotification>>.value(<AppNotification>[
        for (final AppNotification n in cached)
          if (!unreadOnly || !n.isRead) n,
      ]);

  @override
  Stream<int> watchCachedUnreadCount() => Stream<int>.value(cached.where((AppNotification n) => !n.isRead).length);
}

/// Набор фейков этапа F и переопределения провайдеров одним списком.
final class FFakes {
  final FakeCartRepository cart = FakeCartRepository();
  final FakeOrdersRepository orders = FakeOrdersRepository();
  final FakePaymentsRepository payments = FakePaymentsRepository();
  final FakeCheckoutRepository checkout = FakeCheckoutRepository();
  final InMemoryCheckoutDraftRepository checkoutDraft = InMemoryCheckoutDraftRepository();
  final FakeCustomersRepository customers = FakeCustomersRepository();
  final FakeNotificationsRepository notifications = FakeNotificationsRepository();

  List<Override> get overrides => <Override>[
    cartRepositoryProvider.overrideWithValue(cart),
    ordersRepositoryProvider.overrideWithValue(orders),
    paymentsRepositoryProvider.overrideWithValue(payments),
    checkoutRepositoryProvider.overrideWithValue(checkout),
    checkoutDraftRepositoryProvider.overrideWithValue(checkoutDraft),
    customersRepositoryProvider.overrideWithValue(customers),
    notificationsRepositoryProvider.overrideWithValue(notifications),
  ];
}
