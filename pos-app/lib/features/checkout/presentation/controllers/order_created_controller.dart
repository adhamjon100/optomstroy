// Состояние и логика SCR-22 «Заказ создан / QR для оплаты» (02 SCR-22.4, SCR-22.7, SCR-22.11; RM-F-006, RM-F-013).
//
// * Данные — сначала из ответа `POST /orders` (`createdOrderHandoffProvider`), затем `GET /orders/{id}`; пока заказ
//   в `submitting` — опрос каждые 3 с до 60 с (номер 1С и статус приходят вместе при `sent`, ядро §23 п.2).
// * Ожидание оплаты QR — `PaymentsRepository.watch` (long-polling `GET /payments/{id}?wait=25`, не более одного
//   ожидающего запроса; при уходе с экрана подписка отменяется — платёж живёт на сервере).
// * «Перевыпустить QR» — `POST /orders/{id}/payments {reissueQr:true}` (тот же `payment_id`); ручное подтверждение —
//   step-up `payment.qr.confirm_manual` + `Idempotency-Key` (только память, ядро §22.6; повтор после сбоя — тем же
//   ключом, автоповтора после перезапуска нет).
// * «Проверить» (RM-F-013 п. 4, R0 §19.4): статус платежа с сервера (`GET /payments/{id}?refreshStatus=true`) —
//   после перезапуска приложения SCR-22 открывается кассиром заново («Показать QR» SCR-24) и только читает статус;
//   повторного `POST` без действия кассира нет.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/domain/repositories/orders_repository.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';

/// Статус печати документа (UI-22-008).
enum OrderDocState { idle, queued, printed, failed }

/// Аргументы экрана.
typedef OrderCreatedArgs = ({String orderId, String? paymentId});

/// Состояние SCR-22 (только память; в drift не сохраняется).
final class OrderCreatedState {
  const OrderCreatedState({
    this.order,
    this.accepted = false,
    this.allowedActions = const <OrderAction>{},
    this.payment,
    this.paymentActions = const <PaymentAction>{},
    this.printOptions,
    this.loading = true,
    this.loadFailure,
    this.reissuing = false,
    this.confirming = false,
    this.paymentFailure,
    this.paymentStateChanged = false,
    this.docs = const <OrderDocumentKind, OrderDocState>{},
    this.checkingPayment = false,
  });

  final Order? order;

  /// `202 Accepted` (1С недоступна, `STALE_DATA`).
  final bool accepted;
  final Set<OrderAction> allowedActions;
  final Payment? payment;
  final Set<PaymentAction> paymentActions;
  final PrintOptions? printOptions;
  final bool loading;
  final Failure? loadFailure;
  final bool reissuing;
  final bool confirming;
  final Failure? paymentFailure;

  /// `409 PAYMENT_STATE_INVALID` — «Статус платежа изменился. Данные обновлены».
  final bool paymentStateChanged;
  final Map<OrderDocumentKind, OrderDocState> docs;

  /// Идёт «Проверить» (статус платежа с сервера).
  final bool checkingPayment;

  /// QR не сформирован (`warnings[QR_UNAVAILABLE]` у заказа или платежа).
  bool get qrUnavailable =>
      (order?.warnings.any((ApiWarning w) => w.code == WarningCode.qrUnavailable) ?? false) ||
      (payment?.warnings.any((ApiWarning w) => w.code == WarningCode.qrUnavailable) ?? false);

  OrderCreatedState copyWith({
    Order? order,
    bool? accepted,
    Set<OrderAction>? allowedActions,
    Payment? payment,
    Set<PaymentAction>? paymentActions,
    PrintOptions? printOptions,
    bool? loading,
    Failure? loadFailure,
    bool clearLoadFailure = false,
    bool? reissuing,
    bool? confirming,
    Failure? paymentFailure,
    bool clearPaymentFailure = false,
    bool? paymentStateChanged,
    Map<OrderDocumentKind, OrderDocState>? docs,
    bool? checkingPayment,
  }) => OrderCreatedState(
    order: order ?? this.order,
    accepted: accepted ?? this.accepted,
    allowedActions: allowedActions ?? this.allowedActions,
    payment: payment ?? this.payment,
    paymentActions: paymentActions ?? this.paymentActions,
    printOptions: printOptions ?? this.printOptions,
    loading: loading ?? this.loading,
    loadFailure: clearLoadFailure ? null : loadFailure ?? this.loadFailure,
    reissuing: reissuing ?? this.reissuing,
    confirming: confirming ?? this.confirming,
    paymentFailure: clearPaymentFailure ? null : paymentFailure ?? this.paymentFailure,
    paymentStateChanged: paymentStateChanged ?? this.paymentStateChanged,
    docs: docs ?? this.docs,
    checkingPayment: checkingPayment ?? this.checkingPayment,
  );
}

/// SCR-22 по `orderId` и `paymentId` маршрута.
final orderCreatedControllerProvider = NotifierProvider.autoDispose
    .family<OrderCreatedController, OrderCreatedState, OrderCreatedArgs>(OrderCreatedController.new);

/// Логика SCR-22.
final class OrderCreatedController extends Notifier<OrderCreatedState> {
  OrderCreatedController(this.args);

  /// Аргументы маршрута.
  final OrderCreatedArgs args;

  /// Опрос заказа в `submitting` (08 §4.8.1).
  static const Duration orderPollInterval = Duration(seconds: 3);

  /// Предел опроса.
  static const Duration orderPollLimit = Duration(seconds: 60);

  Timer? _orderPoll;
  StreamSubscription<Result<PaymentDetails>>? _watch;
  DateTime? _pollStarted;
  bool _disposed = false;
  bool _opened = false;
  bool _invoicePrinted = false;

  /// Ключ ручного подтверждения — один на попытку (повтор после сбоя — тем же ключом), только память.
  String? _confirmKey;

  /// Ключ перевыпуска QR — один на нажатие.
  String? _reissueKey;

  OrdersRepository get _orders => ref.read(ordersRepositoryProvider);
  PaymentsRepository get _payments => ref.read(paymentsRepositoryProvider);

  @override
  OrderCreatedState build() {
    ref.onDispose(() {
      _disposed = true;
      _orderPoll?.cancel();
      unawaited(_watch?.cancel());
    });
    final OrderCreatedHandoffEntry? entry = ref.read(createdOrderHandoffProvider.notifier).take(args.orderId);
    if (entry == null) return const OrderCreatedState();
    return OrderCreatedState(
      order: entry.order,
      accepted: entry.accepted,
      payment: _paymentOf(entry.order),
      printOptions: entry.printOptions,
      loading: false,
    );
  }

  void _set(OrderCreatedState s) {
    if (!_disposed) state = s;
  }

  Payment? _paymentOf(Order order) {
    final List<Payment> list = order.payments;
    if (list.isEmpty) return null;
    if (args.paymentId != null) {
      for (final Payment p in list) {
        if (p.id == args.paymentId) return p;
      }
    }
    return list.first;
  }

  /// Открыть: актуализировать заказ, запустить опрос `submitting` и ожидание оплаты QR.
  Future<void> open({required bool watchPayment}) async {
    if (_opened) return;
    _opened = true;
    await refresh();
    _maybePollOrder();
    if (watchPayment) _startWatch();
  }

  /// `GET /orders/{id}`.
  Future<void> refresh() async {
    final Result<OrderDetails> r = await _orders.get(args.orderId);
    if (_disposed) return;
    switch (r) {
      case Success<OrderDetails>(:final OrderDetails value):
        final Payment? fromOrder = _paymentOf(value.order);
        // Статус платежа из ожидания новее заказа — не откатываем его.
        final Payment? payment = state.payment != null && fromOrder != null && state.payment!.id == fromOrder.id
            ? (_rank(state.payment!.status) > _rank(fromOrder.status) ? state.payment : fromOrder)
            : fromOrder ?? state.payment;
        _set(
          state.copyWith(
            order: value.order,
            allowedActions: value.allowedActions,
            payment: payment,
            loading: false,
            clearLoadFailure: true,
          ),
        );
        unawaited(_maybeAutoPrint());
      case FailureResult<OrderDetails>(:final Failure failure):
        _set(state.copyWith(loading: false, loadFailure: state.order == null ? failure : null));
    }
  }

  static int _rank(PaymentStatus s) => switch (s) {
    PaymentStatus.initiated => 0,
    PaymentStatus.cashPending || PaymentStatus.qrPending => 1,
    PaymentStatus.qrShown => 2,
    PaymentStatus.qrExpired || PaymentStatus.manualConfirm => 3,
    PaymentStatus.credit || PaymentStatus.received || PaymentStatus.voided || PaymentStatus.refunded => 4,
  };

  void _maybePollOrder() {
    if (state.order?.status != OrderStatus.submitting) return;
    _pollStarted = DateTime.now();
    _orderPoll?.cancel();
    _orderPoll = Timer.periodic(orderPollInterval, (Timer t) {
      if (_disposed ||
          state.order?.status != OrderStatus.submitting ||
          DateTime.now().difference(_pollStarted!) > orderPollLimit) {
        t.cancel();
        return;
      }
      unawaited(refresh());
    });
  }

  void _startWatch() {
    final Payment? p = state.payment;
    if (p == null || p.method != PaymentMethod.qrBakai || !p.isAwaiting) return;
    unawaited(_watch?.cancel());
    _watch = _payments.watch(p.id).listen((Result<PaymentDetails> r) {
      if (_disposed) return;
      if (r case Success<PaymentDetails>(:final PaymentDetails value)) {
        _set(state.copyWith(payment: value.payment, paymentActions: value.allowedActions));
        if (value.payment.status == PaymentStatus.received) unawaited(refresh());
      }
    });
  }

  /// «Проверить»: статус платежа с сервера (только чтение; повторного приёма денег нет).
  Future<void> checkPayment() async {
    final Payment? p = state.payment;
    if (p == null || state.checkingPayment) return;
    _set(state.copyWith(checkingPayment: true, clearPaymentFailure: true));
    final Result<PaymentDetails> r = await _payments.get(p.id, refreshStatus: true);
    if (_disposed) return;
    switch (r) {
      case Success<PaymentDetails>(:final PaymentDetails value):
        _set(state.copyWith(payment: value.payment, paymentActions: value.allowedActions, checkingPayment: false));
        if (value.payment.status == PaymentStatus.received) unawaited(refresh());
      case FailureResult<PaymentDetails>(:final Failure failure):
        _set(state.copyWith(checkingPayment: false, paymentFailure: failure));
    }
  }

  /// Остановить ожидание (idle-блокировка, уход с экрана).
  Future<void> pauseWatch() async {
    // Сначала снять ссылку: «возобновить» сразу после паузы (разблокировка в том же кадре) не должно увидеть
    // отменяемую подписку и остаться без ожидания; одновременно — не более одного запроса (AC-UI-22-011).
    final StreamSubscription<Result<PaymentDetails>>? current = _watch;
    _watch = null;
    await current?.cancel();
  }

  /// Возобновить ожидание.
  void resumeWatch() {
    if (_watch == null) _startWatch();
  }

  /// «Перевыпустить QR» (PAY-025): тот же `payment_id`, новый QR и срок. Повторное нажатие игнорируется.
  Future<void> reissueQr() async {
    if (state.reissuing) return;
    _set(state.copyWith(reissuing: true, clearPaymentFailure: true, paymentStateChanged: false));
    _reissueKey ??= ref.read(checkoutKeyFactoryProvider)();
    final Result<OrderPaymentResult> r = await _payments.createForOrder(
      args.orderId,
      const OrderPaymentRequest.reissueQr(),
      idempotencyKey: _reissueKey!,
    );
    if (_disposed) return;
    switch (r) {
      case Success<OrderPaymentResult>(:final OrderPaymentResult value):
        _reissueKey = null;
        _set(state.copyWith(reissuing: false, payment: value.payment));
        _startWatch();
      case FailureResult<OrderPaymentResult>(:final Failure failure):
        if (failure is! NetworkFailure) _reissueKey = null;
        _set(state.copyWith(reissuing: false, paymentFailure: failure));
    }
  }

  /// Ручное подтверждение QR (UI-22-009, PAY-026): step-up → `POST /payments/{id}/confirm-manual`.
  /// Возвращает `true`, если запрос выполнен (платёж `received` или ушёл на разбор).
  Future<bool> confirmManual(ConfirmManualRequest request) async {
    final Payment? p = state.payment;
    if (p == null || state.confirming) return false;
    _set(state.copyWith(confirming: true, clearPaymentFailure: true, paymentStateChanged: false));
    final CheckoutStepUp stepUp = ref.read(checkoutStepUpProvider);
    String? token = await stepUp('payment.qr.confirm_manual');
    if (_disposed) return false;
    if (token == null) {
      _set(state.copyWith(confirming: false));
      return false;
    }
    _confirmKey ??= ref.read(checkoutKeyFactoryProvider)();
    Result<Payment> r = await _payments.confirmManual(p.id, request, idempotencyKey: _confirmKey!, stepUpToken: token);
    final Failure? f = r.failureOrNull;
    if (f is AuthFailure && f.reason == AuthReason.stepUpRequired) {
      token = await stepUp(f.stepUpOperation ?? 'payment.qr.confirm_manual');
      if (token != null && !_disposed) {
        r = await _payments.confirmManual(p.id, request, idempotencyKey: _confirmKey!, stepUpToken: token);
      }
    }
    if (_disposed) return false;
    switch (r) {
      case Success<Payment>(:final Payment value):
        _confirmKey = null;
        unawaited(_watch?.cancel());
        _watch = null;
        _set(state.copyWith(confirming: false, payment: value));
        unawaited(refresh());
        return true;
      case FailureResult<Payment>(:final Failure failure):
        if (failure is ConflictFailure && failure.kind == ConflictKind.paymentStateInvalid) {
          _confirmKey = null;
          _set(state.copyWith(confirming: false, paymentStateChanged: true));
          final Result<PaymentDetails> fresh = await _payments.get(p.id);
          if (fresh case Success<PaymentDetails>(:final PaymentDetails value)) {
            _set(state.copyWith(payment: value.payment, paymentActions: value.allowedActions));
          }
          return false;
        }
        // Сеть — ключ сохраняется для повтора тем же ключом (08 §2.10).
        if (failure is! NetworkFailure) _confirmKey = null;
        _set(state.copyWith(confirming: false, paymentFailure: failure));
        return false;
    }
  }

  /// Скрыть сообщение об изменении статуса / ошибке платежа.
  void dismissPaymentMessage() => _set(state.copyWith(paymentStateChanged: false, clearPaymentFailure: true));

  /// Печать документа (UI-22-008): PDF из backend → системная печать; ошибка — «Повторить», на заказ не влияет.
  Future<void> printDocument(OrderDocumentKind kind) async {
    final Map<OrderDocumentKind, OrderDocState> docs = <OrderDocumentKind, OrderDocState>{
      ...state.docs,
      kind: OrderDocState.queued,
    };
    _set(state.copyWith(docs: docs));
    final Result<OrderDocumentFile> r = await _orders.document(
      args.orderId,
      kind,
      format: kind == OrderDocumentKind.receipt ? PrintPaper.thermal80 : PrintPaper.a4,
    );
    if (_disposed) return;
    bool printed = false;
    if (r case Success<OrderDocumentFile>(:final OrderDocumentFile value)) {
      try {
        printed = await ref.read(checkoutPrinterProvider)(value);
      } on Object {
        printed = false;
      }
    }
    if (_disposed) return;
    _set(
      state.copyWith(
        docs: <OrderDocumentKind, OrderDocState>{
          ...state.docs,
          kind: printed ? OrderDocState.printed : OrderDocState.failed,
        },
      ),
    );
  }

  /// Отложенная печать счёта: выбран в оформлении и появился номер 1С (PRINT-009).
  Future<void> _maybeAutoPrint() async {
    if (_invoicePrinted || state.printOptions?.invoice != true) return;
    if (state.order?.onec?.number == null) return;
    _invoicePrinted = true;
    await printDocument(OrderDocumentKind.invoice);
  }
}
