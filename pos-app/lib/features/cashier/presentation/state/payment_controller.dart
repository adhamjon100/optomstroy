// Состояние и логика SCR-38 «Приём оплаты» по заказу (02 SCR-38.4, SCR-38.7, SCR-38.11; 08 §4.8.6, §4.9.2–§4.9.4;
// 10 PAY-001…PAY-052; RM-G-007, RM-G-012).
//
// * Сумма к оплате — только с сервера (`totalToPay − paidAmount`, PAY-002); в запросе — только `method` и
//   `receivedAmount` для наличных (AC-UI-38-002).
// * P-IDEMP: один `Idempotency-Key` на операцию; ключ, тело и описание — только память процесса
//   ([cashierUnfinishedOperationsProvider]); `IDEMPOTENCY_IN_PROGRESS` — автоповтор тем же ключом через `retryAfter`
//   (2 с) не более 3 раз, затем «Статус операции уточняется · Проверить»; сеть/таймаут — «Результат неизвестен»
//   (повтор только по «Проверить», тем же ключом); окончательный ответ — запись удаляется. Автоповтора нет.
// * QR: `POST /orders/{id}/payments {method: qr_bakai}` → ожидание `GET /payments/{id}?wait=25` (не более одного
//   запроса одновременно; при уходе с экрана подписка отменяется, платёж живёт на сервере). `QR_UNAVAILABLE`
//   (предупреждение при `QR_PROVIDER=onec` или `503` при `bakai`) → статический QR / ручное подтверждение
//   (`manualOnly`). Ручное подтверждение — step-up до запроса (P-STEPUP-PRE).
// * Смена способа до получения денег — сервер сам аннулирует открытый `cash_pending`/`qr_pending`/`qr_shown`
//   (`method_changed`, без step-up); `409 open_payment_exists` (`qr_expired`/`manual_confirm`) — переход к открытому
//   платежу, ручное аннулирование — со step-up (AuthInterceptor).
// * Долг — fail-closed (D-24, PAY-031): `CREDIT_BLOCKED`, `CREDIT_LIMIT_EXCEEDED`, `RECEIVABLES_STALE`,
//   `CUSTOMER_NOT_IDENTIFIED`, `403` с `creditReason` — блок с причиной (ключи 02 §7 по `creditReason`) и действиями
//   «Обновить долг» (`POST /customers/{id}/receivables/refresh`) и «Как получить разрешение старшего» (CASH-007:
//   только в собственной сессии старшего; `StepUpDialog.supervisor` — R2). Способ `credit` на SCR-38 не оформляется
//   (версия 1.5): заказ в долг — только просмотр (CreditOrder).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/cashier/presentation/state/unfinished_operations.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/domain/repositories/orders_repository.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';

/// Фаза экрана (02 SCR-38.7).
enum PaymentPhase {
  /// LoadingContext.
  loading,

  /// Маршрут без `orderId` и `customerId` — переход на SCR-30.
  noContext,

  /// Режим «по долгу» (`?customerId=`) выключен (RM-G-013, `features.debtPaymentsFromPos=false`) — «Недоступно».
  debtUnavailable,

  /// Ошибка загрузки заказа.
  error,

  /// Нет прав (`403`).
  forbidden,

  /// ChooseMethod / CashInput / QrActive.
  ready,

  /// AlreadyPaid.
  alreadyPaid,

  /// NotPayable.
  notPayable,

  /// CreditOrder (UI-38-013).
  creditOrder,

  /// Success (Z8).
  success,
}

/// Печать чека после успеха (UI-38-006).
enum ReceiptPrintState { idle, printing, printed, failed }

/// Статусы заказа, в которых допустим приём оплаты (ядро §22.5).
const Set<OrderStatus> kPayableStatuses = <OrderStatus>{
  OrderStatus.submitting,
  OrderStatus.pendingApproval,
  OrderStatus.approved,
  OrderStatus.awaitingPayment,
};

/// Аргументы маршрута SCR-38.
typedef PaymentArgs = ({String? orderId, String? customerId, String? method});

/// Состояние SCR-38 (только память).
@immutable
final class PaymentScreenState {
  /// Создаёт состояние.
  const PaymentScreenState({
    this.phase = PaymentPhase.loading,
    this.order,
    this.allowedActions = const <OrderAction>{},
    this.method,
    this.qrPayment,
    this.qrActions = const <PaymentAction>{},
    this.qrCreating = false,
    this.qrFailure,
    this.qrUnavailable = false,
    this.qrBankDown = false,
    this.submitting = false,
    this.unknown = false,
    this.idempotencyPending = false,
    this.failure,
    this.receivedLess = false,
    this.creditBlock,
    this.refreshingDebt = false,
    this.debtSnapshot,
    this.openQrExists = false,
    this.confirming = false,
    this.voiding = false,
    this.manualMismatch = false,
    this.stateChanged = false,
    this.result,
    this.print = ReceiptPrintState.idle,
    this.loadFailure,
  });

  final PaymentPhase phase;
  final Order? order;
  final Set<OrderAction> allowedActions;

  /// Выбранный способ (`cash` | `qr_bakai`); `null` — не выбран.
  final PaymentMethod? method;

  /// Открытый QR-платёж заказа.
  final Payment? qrPayment;
  final Set<PaymentAction> qrActions;
  final bool qrCreating;

  /// Ошибка формирования QR (`payment_qr_create_error`).
  final Failure? qrFailure;

  /// QR не сформирован (`warnings[QR_UNAVAILABLE]` / `503`) — запасной путь.
  final bool qrUnavailable;

  /// `503 QR_UNAVAILABLE` (`QR_PROVIDER=bakai`) — текст «Банк недоступен…».
  final bool qrBankDown;

  /// Идёт `POST /orders/{id}/payments {cash}` (CTA `loading`).
  final bool submitting;

  /// «Результат неизвестен» (UI-38-018).
  final bool unknown;

  /// «Статус операции уточняется» (`IDEMPOTENCY_IN_PROGRESS` после 3 повторов / `IDEMPOTENCY_KEY_REUSED`).
  final bool idempotencyPending;

  /// Ошибка операции (ErrorState.inline).
  final Failure? failure;

  /// `422 received_less_than_due` — ошибка у поля.
  final bool receivedLess;

  /// Отказ по долгу (fail-closed): ключ 02 §7 по `creditReason`.
  final UiError? creditBlock;

  /// «Обновить долг» выполняется.
  final bool refreshingDebt;

  /// Снимок долга после «Обновить долг» (метка «данные 1С от HH:MM»; только память — CASH-015).
  final Receivable? debtSnapshot;

  /// `409 open_payment_exists` — «По заказу открыт QR-платёж…».
  final bool openQrExists;
  final bool confirming;
  final bool voiding;

  /// Ручное подтверждение ушло на разбор (`PAYMENT_AMOUNT_MISMATCH`).
  final bool manualMismatch;

  /// `PAYMENT_STATE_INVALID` — «Статус платежа изменился. Данные обновлены».
  final bool stateChanged;

  /// Полученный платёж (Z8).
  final Payment? result;
  final ReceiptPrintState print;
  final Failure? loadFailure;

  /// К оплате: `totalToPay − paidAmount` (сервер; клиент не вычисляет цен — только остаток для показа).
  Money get due {
    final Order? o = order;
    if (o == null) return Money.zero;
    final Money total = o.totalToPay ?? o.total;
    final Money left = total - (o.paidAmount ?? Money.zero);
    return left.isNegative ? Money.zero : left;
  }

  /// Блокирующая операция идёт.
  bool get busy => submitting || confirming || voiding || qrCreating;

  PaymentScreenState copyWith({
    PaymentPhase? phase,
    Order? order,
    Set<OrderAction>? allowedActions,
    PaymentMethod? Function()? method,
    Payment? Function()? qrPayment,
    Set<PaymentAction>? qrActions,
    bool? qrCreating,
    Failure? Function()? qrFailure,
    bool? qrUnavailable,
    bool? qrBankDown,
    bool? submitting,
    bool? unknown,
    bool? idempotencyPending,
    Failure? Function()? failure,
    bool? receivedLess,
    UiError? Function()? creditBlock,
    bool? refreshingDebt,
    Receivable? debtSnapshot,
    bool? openQrExists,
    bool? confirming,
    bool? voiding,
    bool? manualMismatch,
    bool? stateChanged,
    Payment? result,
    ReceiptPrintState? print,
    Failure? Function()? loadFailure,
  }) => PaymentScreenState(
    phase: phase ?? this.phase,
    order: order ?? this.order,
    allowedActions: allowedActions ?? this.allowedActions,
    method: method == null ? this.method : method(),
    qrPayment: qrPayment == null ? this.qrPayment : qrPayment(),
    qrActions: qrActions ?? this.qrActions,
    qrCreating: qrCreating ?? this.qrCreating,
    qrFailure: qrFailure == null ? this.qrFailure : qrFailure(),
    qrUnavailable: qrUnavailable ?? this.qrUnavailable,
    qrBankDown: qrBankDown ?? this.qrBankDown,
    submitting: submitting ?? this.submitting,
    unknown: unknown ?? this.unknown,
    idempotencyPending: idempotencyPending ?? this.idempotencyPending,
    failure: failure == null ? this.failure : failure(),
    receivedLess: receivedLess ?? this.receivedLess,
    creditBlock: creditBlock == null ? this.creditBlock : creditBlock(),
    refreshingDebt: refreshingDebt ?? this.refreshingDebt,
    debtSnapshot: debtSnapshot ?? this.debtSnapshot,
    openQrExists: openQrExists ?? this.openQrExists,
    confirming: confirming ?? this.confirming,
    voiding: voiding ?? this.voiding,
    manualMismatch: manualMismatch ?? this.manualMismatch,
    stateChanged: stateChanged ?? this.stateChanged,
    result: result ?? this.result,
    print: print ?? this.print,
    loadFailure: loadFailure == null ? this.loadFailure : loadFailure(),
  );
}

/// SCR-38 по аргументам маршрута.
final paymentControllerProvider = NotifierProvider.autoDispose
    .family<PaymentController, PaymentScreenState, PaymentArgs>(PaymentController.new);

/// Отказ по долгу (fail-closed, ядро §22.4, §23 п. 5): ключ 02 §7 по `creditReason` или `null`, если ошибка не о долге.
UiError? creditBlockOf(Failure failure) {
  final UiError e = UiErrorMapper.fromFailureDetailed(failure);
  final bool creditCode = switch (e.code) {
    ProblemCode.creditBlocked ||
    ProblemCode.creditLimitExceeded ||
    ProblemCode.receivablesStale ||
    ProblemCode.customerNotIdentified => true,
    _ => false,
  };
  return creditCode || e.creditReason != null ? e : null;
}

/// Логика SCR-38.
final class PaymentController extends Notifier<PaymentScreenState> {
  PaymentController(this.args);

  /// Аргументы маршрута.
  final PaymentArgs args;

  /// Повторов `IDEMPOTENCY_IN_PROGRESS` до «Статус уточняется» (P-IDEMP).
  static const int maxInProgressRetries = 3;

  /// Пауза повтора без `retryAfter`.
  static const Duration inProgressDelay = Duration(seconds: 2);

  StreamSubscription<Result<PaymentDetails>>? _watch;
  bool _disposed = false;
  bool _opened = false;
  String? _qrKey;
  String? _confirmKey;
  String? _voidKey;
  String? _refreshKey;

  OrdersRepository get _orders => ref.read(ordersRepositoryProvider);
  PaymentsRepository get _payments => ref.read(paymentsRepositoryProvider);
  UnfinishedOperationsNotifier get _memory => ref.read(cashierUnfinishedOperationsProvider.notifier);

  @override
  PaymentScreenState build() {
    ref.onDispose(() {
      _disposed = true;
      unawaited(_watch?.cancel());
    });
    if (args.orderId == null) {
      return PaymentScreenState(phase: args.customerId == null ? PaymentPhase.noContext : PaymentPhase.debtUnavailable);
    }
    // Незавершённая операция заказа любого вида (баннер SCR-30 → SCR-38, AC-UI-30-017): «Результат неизвестен» с тем же
    // ключом; приём наличных — способ «наличные», подтверждение/аннулирование QR — способ QR.
    final UnfinishedOperation? pending = ref.read(cashierUnfinishedOperationsProvider.notifier).forOrder(args.orderId!);
    return PaymentScreenState(
      unknown: pending != null,
      method: pending == null
          ? null
          : (pending.kind == UnfinishedKind.orderPayment ? PaymentMethod.cash : PaymentMethod.qrBakai),
    );
  }

  void _set(PaymentScreenState s) {
    if (!_disposed) state = s;
  }

  String _newKey() => ref.read(cashierKeyFactoryProvider)();

  /// Открыть экран: `GET /orders/{id}?include=payments` и выбор начального состояния.
  Future<void> open() async {
    if (_opened || args.orderId == null) return;
    _opened = true;
    await reload(initial: true);
  }

  /// Перечитать заказ (после ошибок состояния, «Повторить», возврата на экран).
  Future<void> reload({bool initial = false}) async {
    final String? orderId = args.orderId;
    if (orderId == null) return;
    if (initial || state.order == null) _set(state.copyWith(phase: PaymentPhase.loading, loadFailure: () => null));
    final Result<OrderDetails> r = await _orders.get(orderId);
    if (_disposed) return;
    switch (r) {
      case Success<OrderDetails>(:final OrderDetails value):
        _apply(value, initial: initial);
      case FailureResult<OrderDetails>(:final Failure failure):
        if (state.order != null) {
          _set(state.copyWith(failure: () => failure));
        } else {
          _set(
            state.copyWith(
              phase: failure is PermissionFailure ? PaymentPhase.forbidden : PaymentPhase.error,
              loadFailure: () => failure,
            ),
          );
        }
    }
  }

  static bool _isOpenQr(Payment p) =>
      p.method == PaymentMethod.qrBakai &&
      (p.status == PaymentStatus.qrPending ||
          p.status == PaymentStatus.qrShown ||
          p.status == PaymentStatus.qrExpired ||
          p.status == PaymentStatus.manualConfirm ||
          p.status == PaymentStatus.initiated);

  void _apply(OrderDetails details, {required bool initial}) {
    final Order o = details.order;
    Payment? openQr;
    for (final Payment p in o.payments) {
      if (_isOpenQr(p)) openQr = p;
    }
    final PaymentPhase phase;
    if (state.phase == PaymentPhase.success) {
      phase = PaymentPhase.success;
    } else if (o.isPaid) {
      phase = PaymentPhase.alreadyPaid;
    } else if (o.paymentMethod == PaymentMethod.credit) {
      phase = PaymentPhase.creditOrder;
    } else if (!kPayableStatuses.contains(o.status)) {
      phase = PaymentPhase.notPayable;
    } else {
      phase = PaymentPhase.ready;
    }
    PaymentMethod? method = state.method;
    if (initial && method == null) {
      method = openQr != null
          ? PaymentMethod.qrBakai
          : (PaymentMethod.tryParse(args.method) ?? (o.paymentMethod == PaymentMethod.credit ? null : o.paymentMethod));
      if (method == PaymentMethod.credit) method = null;
    }
    final Payment? keepQr = state.qrPayment != null && openQr != null && state.qrPayment!.id == openQr.id
        ? state.qrPayment
        : openQr;
    _set(
      state.copyWith(
        phase: phase,
        order: o,
        allowedActions: details.allowedActions,
        method: () => method,
        qrPayment: () => keepQr ?? (method == PaymentMethod.qrBakai ? state.qrPayment : null),
        qrUnavailable: keepQr != null ? _noQr(keepQr) : state.qrUnavailable,
        loadFailure: () => null,
      ),
    );
    if (phase != PaymentPhase.ready) {
      unawaited(_stopWatch());
      return;
    }
    if (method == PaymentMethod.qrBakai) {
      if (keepQr == null && initial && !state.unknown) {
        unawaited(createQr());
      } else {
        _startWatch();
      }
    }
  }

  static bool _noQr(Payment p) => p.qr == null && p.warnings.any((ApiWarning w) => w.code == WarningCode.qrUnavailable);

  // ---------------------------------------------------------------------------------------------------------------
  // Способ оплаты.

  /// Выбрать способ (02 SCR-38.4 «Плитки способа»). Наличные при открытом QR — после `ConfirmDialog` на экране.
  Future<void> selectMethod(PaymentMethod method) async {
    if (state.method == method || state.busy || method == PaymentMethod.credit) return;
    _set(
      state.copyWith(
        method: () => method,
        failure: () => null,
        receivedLess: false,
        creditBlock: () => null,
        openQrExists: false,
        stateChanged: false,
      ),
    );
    if (method == PaymentMethod.qrBakai) {
      final Payment? p = state.qrPayment;
      if (p == null || p.isFinal) {
        await createQr();
      } else {
        _startWatch();
      }
    }
  }

  /// Сбросить выбор способа («Другой способ оплаты»).
  void clearMethod() => _set(state.copyWith(method: () => null, creditBlock: () => null, failure: () => null));

  // ---------------------------------------------------------------------------------------------------------------
  // QR.

  /// Сформировать QR / перевыпустить (PAY-025) / статический QR с ручным подтверждением (`manualOnly`).
  Future<void> createQr({bool reissue = false, bool manualOnly = false}) async {
    final String? orderId = args.orderId;
    if (orderId == null || state.qrCreating) return;
    _set(
      state.copyWith(
        qrCreating: true,
        qrFailure: () => null,
        openQrExists: false,
        stateChanged: false,
        creditBlock: () => null,
      ),
    );
    _qrKey ??= _newKey();
    final OrderPaymentRequest request = reissue
        ? const OrderPaymentRequest.reissueQr()
        : (manualOnly
              ? const OrderPaymentRequest.manualQr()
              : const OrderPaymentRequest(method: PaymentMethod.qrBakai));
    final Result<OrderPaymentResult> r = await _payments.createForOrder(orderId, request, idempotencyKey: _qrKey!);
    if (_disposed) return;
    switch (r) {
      case Success<OrderPaymentResult>(:final OrderPaymentResult value):
        _qrKey = null;
        final Payment p = value.payment;
        if (value.orderIsPaid || p.status == PaymentStatus.received) {
          _success(p);
          return;
        }
        _set(
          state.copyWith(
            qrCreating: false,
            qrPayment: () => p,
            qrUnavailable: _noQr(p),
            qrBankDown: false,
            manualMismatch: false,
          ),
        );
        _startWatch();
      case FailureResult<OrderPaymentResult>(:final Failure failure):
        if (failure is! NetworkFailure) _qrKey = null;
        await _onQrFailure(failure);
    }
  }

  Future<void> _onQrFailure(Failure failure) async {
    if (failure is ServerFailure && failure.problemCode == ProblemCode.qrUnavailable) {
      _set(state.copyWith(qrCreating: false, qrUnavailable: true, qrBankDown: true));
      return;
    }
    if (failure is ConflictFailure && failure.kind == ConflictKind.paymentStateInvalid) {
      _set(state.copyWith(qrCreating: false, openQrExists: failure.reason == 'open_payment_exists'));
      await _loadOpenPayment(failure);
      return;
    }
    if (failure is ConflictFailure && failure.kind == ConflictKind.orderStateInvalid) {
      _set(state.copyWith(qrCreating: false));
      await reload();
      return;
    }
    final UiError? credit = creditBlockOf(failure);
    _set(
      state.copyWith(
        qrCreating: false,
        qrFailure: credit == null ? () => failure : null,
        creditBlock: credit == null ? null : () => credit,
      ),
    );
  }

  Future<void> _loadOpenPayment(ConflictFailure failure) async {
    final Object? id = failure.details['openPaymentId'];
    if (id is String) {
      final Result<PaymentDetails> p = await _payments.get(id);
      if (_disposed) return;
      if (p case Success<PaymentDetails>(:final PaymentDetails value)) {
        _set(
          state.copyWith(
            method: () => PaymentMethod.qrBakai,
            qrPayment: () => value.payment,
            qrActions: value.allowedActions,
            qrUnavailable: _noQr(value.payment),
          ),
        );
        _startWatch();
        return;
      }
    }
    await reload();
  }

  void _startWatch() {
    final Payment? p = state.qrPayment;
    if (p == null || !p.isAwaiting || _watch != null) return;
    if (ref.read(cashierSessionLockedProvider)) return;
    _watch = _payments.watch(p.id).listen((Result<PaymentDetails> r) {
      if (_disposed) return;
      if (r case Success<PaymentDetails>(:final PaymentDetails value)) {
        final Payment np = value.payment;
        if (np.status == PaymentStatus.received) {
          _success(np);
          return;
        }
        _set(state.copyWith(qrPayment: () => np, qrActions: value.allowedActions, qrUnavailable: _noQr(np)));
        if (!np.isAwaiting) unawaited(_stopWatch());
      }
    });
  }

  /// Остановить ожидание: отмена подписки не ожидается (текущий long-poll отменяется в фоне — CancelToken), чтобы
  /// не задерживать следующее действие экрана.
  Future<void> _stopWatch() async {
    final StreamSubscription<Result<PaymentDetails>>? w = _watch;
    _watch = null;
    if (w != null) unawaited(w.cancel());
  }

  /// Пауза ожидания (фон, idle-блокировка).
  Future<void> pauseWatch() => _stopWatch();

  /// Возобновить ожидание.
  void resumeWatch() => _startWatch();

  /// «Проверить» статус QR (только чтение).
  Future<void> checkQr() async {
    final Payment? p = state.qrPayment;
    if (p == null) return;
    final Result<PaymentDetails> r = await _payments.get(p.id, refreshStatus: true);
    if (_disposed) return;
    if (r case Success<PaymentDetails>(:final PaymentDetails value)) {
      if (value.payment.status == PaymentStatus.received) {
        _success(value.payment);
      } else {
        _set(state.copyWith(qrPayment: () => value.payment, qrActions: value.allowedActions));
      }
    }
  }

  /// Ручное подтверждение QR (UI-38-015; PAY-026): step-up до запроса (P-STEPUP-PRE) → `confirm-manual`.
  /// `true` — запрос выполнен (получено или ушло на разбор).
  Future<bool> confirmManual(ConfirmManualRequest request) async {
    final Payment? p = state.qrPayment;
    if (p == null || state.confirming || state.unknown) return false;
    _set(state.copyWith(confirming: true, failure: () => null, stateChanged: false, manualMismatch: false));
    final CashierStepUpResult pre = await ref.read(cashierStepUpProvider)('payment.qr.confirm_manual');
    if (_disposed) return false;
    if (pre.cancelled) {
      _set(state.copyWith(confirming: false));
      return false;
    }
    final UnfinishedOperation? prior = _memory.forOrder(args.orderId!, kind: UnfinishedKind.confirmManual);
    _confirmKey ??= prior != null && prior.paymentId == p.id ? prior.idempotencyKey : _newKey();
    final UnfinishedOperation op = UnfinishedOperation(
      kind: UnfinishedKind.confirmManual,
      idempotencyKey: _confirmKey!,
      orderId: args.orderId!,
      orderNumber: state.order?.publicNumber,
      paymentId: p.id,
      request: request,
    );
    _memory.put(op);
    return _sendConfirm(op, pre.token);
  }

  /// `confirm-manual` с ключом и телом [op] (первая отправка и «Проверить» — P-IDEMP).
  Future<bool> _sendConfirm(UnfinishedOperation op, String? stepUpToken) async {
    final String paymentId = op.paymentId!;
    final ConfirmManualRequest request = op.confirmRequest!;
    _set(state.copyWith(confirming: true, failure: () => null, stateChanged: false, manualMismatch: false));
    final String key = op.idempotencyKey;
    Result<Payment> r = await _payments.confirmManual(
      paymentId,
      request,
      idempotencyKey: key,
      stepUpToken: stepUpToken,
    );
    final Failure? f = r.failureOrNull;
    if (f is AuthFailure && f.reason == AuthReason.stepUpRequired && !_disposed) {
      final CashierStepUpResult again = await ref.read(cashierStepUpProvider)(
        f.stepUpOperation ?? 'payment.qr.confirm_manual',
      );
      if (!again.cancelled && !_disposed) {
        r = await _payments.confirmManual(paymentId, request, idempotencyKey: key, stepUpToken: again.token);
      }
    }
    if (_disposed) return false;
    switch (r) {
      case Success<Payment>(:final Payment value):
        _confirmKey = null;
        _memory.remove(key);
        if (value.status == PaymentStatus.received) {
          _success(value);
        } else {
          _set(
            state.copyWith(
              confirming: false,
              qrPayment: () => value,
              manualMismatch: true,
              unknown: false,
              idempotencyPending: false,
            ),
          );
        }
        return true;
      case FailureResult<Payment>(:final Failure failure):
        if (_unknownOutcome(failure)) {
          // Результат неизвестен: ключ и тело остаются в памяти, повтор — только «Проверить» тем же ключом.
          _set(state.copyWith(confirming: false, unknown: true, idempotencyPending: failure is ConflictFailure));
          return false;
        }
        _confirmKey = null;
        _memory.remove(key);
        _set(state.copyWith(unknown: false, idempotencyPending: false));
        if (failure is AuthFailure && failure.reason == AuthReason.stepUpRequired) {
          _set(state.copyWith(confirming: false));
          return false;
        }
        if (failure is ConflictFailure && failure.kind == ConflictKind.paymentStateInvalid) {
          _set(state.copyWith(confirming: false, stateChanged: true));
          await checkQr();
          return false;
        }
        _set(state.copyWith(confirming: false, failure: () => failure));
        return false;
    }
  }

  /// Неизвестный результат операции с деньгами: сеть/таймаут или `IDEMPOTENCY_IN_PROGRESS`/`IDEMPOTENCY_KEY_REUSED`.
  static bool _unknownOutcome(Failure failure) =>
      failure is NetworkFailure ||
      (failure is ConflictFailure &&
          (failure.kind == ConflictKind.idempotencyInProgress || failure.kind == ConflictKind.idempotencyKeyReused));

  /// Аннулировать открытый неполученный платёж (из «Требует проверки» / после `open_payment_exists`; PAY-050):
  /// step-up `payment.void` — по `403 STEP_UP_REQUIRED` (AuthInterceptor, тот же ключ). `true` — аннулирован.
  Future<bool> voidOpenPayment(VoidPaymentRequest request) async {
    final Payment? p = state.qrPayment;
    if (p == null || state.voiding || state.unknown) return false;
    final UnfinishedOperation? prior = _memory.forOrder(args.orderId!, kind: UnfinishedKind.voidPayment);
    _voidKey ??= prior != null && prior.paymentId == p.id ? prior.idempotencyKey : _newKey();
    final UnfinishedOperation op = UnfinishedOperation(
      kind: UnfinishedKind.voidPayment,
      idempotencyKey: _voidKey!,
      orderId: args.orderId!,
      orderNumber: state.order?.publicNumber,
      paymentId: p.id,
      request: request,
    );
    _memory.put(op);
    return _sendVoid(op);
  }

  /// `void` с ключом и телом [op] (первая отправка и «Проверить» — P-IDEMP).
  Future<bool> _sendVoid(UnfinishedOperation op) async {
    final String paymentId = op.paymentId!;
    final VoidPaymentRequest request = op.voidRequest!;
    _set(state.copyWith(voiding: true, failure: () => null, stateChanged: false));
    final String key = op.idempotencyKey;
    final Result<Payment> r = await _payments.voidPayment(paymentId, request, idempotencyKey: key);
    if (_disposed) return false;
    switch (r) {
      case Success<Payment>():
        _voidKey = null;
        _memory.remove(key);
        await _stopWatch();
        if (_disposed) return true;
        _set(
          state.copyWith(
            voiding: false,
            qrPayment: () => null,
            method: () => null,
            openQrExists: false,
            manualMismatch: false,
            unknown: false,
            idempotencyPending: false,
          ),
        );
        await reload();
        return true;
      case FailureResult<Payment>(:final Failure failure):
        if (_unknownOutcome(failure)) {
          _set(state.copyWith(voiding: false, unknown: true, idempotencyPending: failure is ConflictFailure));
          return false;
        }
        _voidKey = null;
        _memory.remove(key);
        _set(state.copyWith(unknown: false, idempotencyPending: false));
        if (failure is AuthFailure && failure.reason == AuthReason.stepUpRequired) {
          _set(state.copyWith(voiding: false));
          return false;
        }
        if (failure is ConflictFailure && failure.kind == ConflictKind.paymentStateInvalid) {
          _set(state.copyWith(voiding: false, stateChanged: true));
          await checkQr();
          return false;
        }
        _set(state.copyWith(voiding: false, failure: () => failure));
        return false;
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Наличные.

  /// «Подтвердить приём» наличных (после `ConfirmDialog`): P-IDEMP.
  Future<void> acceptCash(Money received) async {
    final String? orderId = args.orderId;
    if (orderId == null || state.submitting) return;
    if (received < state.due) {
      _set(state.copyWith(receivedLess: true));
      return;
    }
    final OrderPaymentRequest request = OrderPaymentRequest.cash(received: received);
    final UnfinishedOperation op = UnfinishedOperation(
      kind: UnfinishedKind.orderPayment,
      idempotencyKey: _newKey(),
      orderId: orderId,
      orderNumber: state.order?.publicNumber,
      amount: state.due,
      request: request,
    );
    _memory.put(op);
    await _send(op);
  }

  /// «Проверить» (UI-38-018, SCR-38.11): повтор того же запроса с тем же ключом и телом — для любого вида операции
  /// (приём оплаты; ручное подтверждение QR — снова step-up до запроса, P-STEPUP-PRE; аннулирование).
  Future<void> check() async {
    final String? orderId = args.orderId;
    if (orderId == null || state.busy) return;
    final UnfinishedOperation? op = _memory.forOrder(orderId);
    if (op == null) {
      _set(state.copyWith(unknown: false, idempotencyPending: false));
      await reload();
      return;
    }
    switch (op.kind) {
      case UnfinishedKind.orderPayment:
        await _send(op);
      case UnfinishedKind.confirmManual:
        _set(state.copyWith(confirming: true, failure: () => null));
        final CashierStepUpResult pre = await ref.read(cashierStepUpProvider)('payment.qr.confirm_manual');
        if (_disposed) return;
        if (pre.cancelled) {
          _set(state.copyWith(confirming: false));
          return;
        }
        await _sendConfirm(op, pre.token);
      case UnfinishedKind.voidPayment:
        await _sendVoid(op);
    }
  }

  /// «Отменить операцию» (только если деньги не принимались): сведения удаляются из памяти.
  void discardUnknown() {
    final String? orderId = args.orderId;
    if (orderId == null) return;
    final UnfinishedOperation? op = _memory.forOrder(orderId);
    if (op != null) {
      _memory.remove(op.idempotencyKey);
      if (op.idempotencyKey == _confirmKey) _confirmKey = null;
      if (op.idempotencyKey == _voidKey) _voidKey = null;
    }
    _set(state.copyWith(unknown: false, idempotencyPending: false, failure: () => null));
  }

  Future<void> _send(UnfinishedOperation op) async {
    final OrderPaymentRequest? request = op.paymentRequest;
    if (request == null) return;
    _set(
      state.copyWith(
        submitting: true,
        failure: () => null,
        receivedLess: false,
        creditBlock: () => null,
        openQrExists: false,
        idempotencyPending: false,
      ),
    );
    Result<OrderPaymentResult> r = await _payments.createForOrder(
      op.orderId,
      request,
      idempotencyKey: op.idempotencyKey,
    );
    int retries = 0;
    while (!_disposed) {
      final Failure? f = r.failureOrNull;
      if (f is! ConflictFailure || f.kind != ConflictKind.idempotencyInProgress || retries >= maxInProgressRetries) {
        break;
      }
      retries++;
      await Future<void>.delayed(f.retryAfter ?? inProgressDelay);
      if (_disposed) return;
      r = await _payments.createForOrder(op.orderId, request, idempotencyKey: op.idempotencyKey);
    }
    if (_disposed) return;
    switch (r) {
      case Success<OrderPaymentResult>(:final OrderPaymentResult value):
        _memory.remove(op.idempotencyKey);
        await _stopWatch();
        if (_disposed) return;
        _success(value.payment);
      case FailureResult<OrderPaymentResult>(:final Failure failure):
        await _onCashFailure(op, failure);
    }
  }

  Future<void> _onCashFailure(UnfinishedOperation op, Failure failure) async {
    // Неизвестный результат: ключ и тело остаются в памяти, повтор — только «Проверить».
    if (failure is NetworkFailure) {
      _set(state.copyWith(submitting: false, unknown: true));
      return;
    }
    if (failure is ConflictFailure &&
        (failure.kind == ConflictKind.idempotencyInProgress || failure.kind == ConflictKind.idempotencyKeyReused)) {
      _set(state.copyWith(submitting: false, unknown: true, idempotencyPending: true));
      return;
    }
    // Окончательный ответ бизнес-уровня — сведения об операции удаляются.
    _memory.remove(op.idempotencyKey);
    _set(state.copyWith(submitting: false, unknown: false, idempotencyPending: false));
    if (failure is ValidationFailure &&
        failure.errors.any((FieldError e) => e.rule == 'received_less_than_due' || e.field == 'receivedAmount')) {
      _set(state.copyWith(receivedLess: true));
      return;
    }
    if (failure is ConflictFailure && failure.kind == ConflictKind.paymentStateInvalid) {
      _set(state.copyWith(openQrExists: failure.reason == 'open_payment_exists'));
      await _loadOpenPayment(failure);
      return;
    }
    if (failure is ConflictFailure && failure.kind == ConflictKind.orderStateInvalid) {
      await reload();
      return;
    }
    final UiError? credit = creditBlockOf(failure);
    if (credit != null) {
      _set(state.copyWith(creditBlock: () => credit));
      return;
    }
    _set(state.copyWith(failure: () => failure));
  }

  void _success(Payment payment) {
    if (_disposed) return;
    unawaited(_stopWatch());
    _set(
      state.copyWith(
        phase: PaymentPhase.success,
        result: payment,
        submitting: false,
        confirming: false,
        qrCreating: false,
        unknown: false,
        voiding: false,
        idempotencyPending: false,
        failure: () => null,
        qrPayment: () => payment.method == PaymentMethod.qrBakai ? payment : state.qrPayment,
      ),
    );
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Долг (fail-closed) и печать.

  /// «Обновить долг» (`POST /customers/{id}/receivables/refresh`, P-STALE): снимок — только память сессии.
  Future<void> refreshDebt() async {
    final String? customerId = state.order?.customer?.id ?? args.customerId;
    if (customerId == null || state.refreshingDebt) return;
    _set(state.copyWith(refreshingDebt: true, failure: () => null));
    _refreshKey ??= _newKey();
    final Result<Receivable> r = await ref
        .read(receivablesRepositoryProvider)
        .refresh(customerId, idempotencyKey: _refreshKey);
    if (_disposed) return;
    _refreshKey = null;
    switch (r) {
      case Success<Receivable>(:final Receivable value):
        ref.read(customerFinanceMemoryProvider).putReceivable(value);
        _set(state.copyWith(refreshingDebt: false, debtSnapshot: value, creditBlock: () => null));
      case FailureResult<Receivable>(:final Failure failure):
        _set(state.copyWith(refreshingDebt: false, failure: () => failure));
    }
  }

  /// Скрыть сообщение об ошибке / изменении статуса.
  void dismissMessages() =>
      _set(state.copyWith(failure: () => null, stateChanged: false, openQrExists: false, manualMismatch: false));

  /// Печать товарного чека 80 мм (только после получения оплаты, ядро §19.4); ошибка платёж не отменяет.
  Future<void> printReceipt() async {
    final String? orderId = args.orderId;
    final CashierReceiptPrinter? printer = ref.read(cashierReceiptPrinterProvider);
    if (orderId == null || printer == null || state.result == null || state.print == ReceiptPrintState.printing) {
      return;
    }
    _set(state.copyWith(print: ReceiptPrintState.printing));
    final Result<OrderDocumentFile> r = await _orders.document(
      orderId,
      OrderDocumentKind.receipt,
      format: PrintPaper.thermal80,
    );
    if (_disposed) return;
    bool printed = false;
    if (r case Success<OrderDocumentFile>(:final OrderDocumentFile value)) {
      try {
        printed = await printer(value);
      } on Object {
        printed = false;
      }
    }
    if (_disposed) return;
    _set(state.copyWith(print: printed ? ReceiptPrintState.printed : ReceiptPrintState.failed));
  }
}
