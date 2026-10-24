// Состояние SCR-37 «Транзакция: детали» (02 SCR-37.4, SCR-37.7, SCR-37.11; 08 §4.14.2, §4.9.2–§4.9.4, §4.8.3).
//
// * Загрузка: `GET /transactions/{id}`; если среди связанных есть платёж — параллельно `GET /payments/{id}`
//   (`allowedActions`, статус, `reviewReason`), если есть заказ — `GET /orders/{id}` (`allowedActions`, история,
//   документы). Ошибки вспомогательных запросов деталь не ломают (действия скрываются).
// * «Подтвердить вручную» — step-up до запроса (P-STEPUP-PRE), `Idempotency-Key` — память; «Аннулировать платёж» —
//   `ConfirmDialog` с причиной, step-up по `403 STEP_UP_REQUIRED` (AuthInterceptor, тот же ключ). Сеть/таймаут —
//   «Результат операции неизвестен · Проверить» (повтор тем же ключом; автоповтора нет); после перезапуска экран
//   перечитывает `GET /payments/{id}` — актуальный статус показывает, выполнено ли действие.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/domain/repositories/orders_repository.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/presentation/providers/transactions_ports.dart';
import 'package:optomstroy/features/transactions/transactions_providers.dart';

/// Фаза экрана.
enum TransactionDetailsPhase { loading, ready, notFound, error, offline, forbidden }

/// Вид незавершённого действия.
enum DetailsAction { confirmManual, voidPayment }

/// Статусы платежа до получения денег — аннулирование допустимо (PAY-050; `credit` — конечный).
const Set<PaymentStatus> kVoidableStatuses = <PaymentStatus>{
  PaymentStatus.cashPending,
  PaymentStatus.qrPending,
  PaymentStatus.qrShown,
  PaymentStatus.qrExpired,
  PaymentStatus.manualConfirm,
};

/// Состояние детали.
@immutable
final class TransactionDetailsState {
  /// Создаёт состояние.
  const TransactionDetailsState({
    this.phase = TransactionDetailsPhase.loading,
    this.detail,
    this.payment,
    this.order,
    this.busy,
    this.unknown,
    this.failure,
    this.loadFailure,
    this.stateChanged = false,
    this.manualMismatch = false,
    this.done,
  });

  final TransactionDetailsPhase phase;
  final TransactionDetail? detail;
  final PaymentDetails? payment;
  final OrderDetails? order;

  /// Идёт действие.
  final DetailsAction? busy;

  /// Результат действия неизвестен (сеть/таймаут) — «Проверить».
  final DetailsAction? unknown;

  /// Ошибка действия.
  final Failure? failure;
  final Failure? loadFailure;

  /// `PAYMENT_STATE_INVALID` — «Статус платежа изменился. Данные обновлены».
  final bool stateChanged;

  /// Подтверждение ушло на разбор (`PAYMENT_AMOUNT_MISMATCH`).
  final bool manualMismatch;

  /// Завершённое действие (снекбар «Оплата подтверждена» / «Платёж аннулирован»).
  final DetailsAction? done;

  Transaction? get transaction => detail?.transaction;

  TransactionDetailsState copyWith({
    TransactionDetailsPhase? phase,
    TransactionDetail? detail,
    PaymentDetails? Function()? payment,
    OrderDetails? Function()? order,
    DetailsAction? Function()? busy,
    DetailsAction? Function()? unknown,
    Failure? Function()? failure,
    Failure? Function()? loadFailure,
    bool? stateChanged,
    bool? manualMismatch,
    DetailsAction? Function()? done,
  }) => TransactionDetailsState(
    phase: phase ?? this.phase,
    detail: detail ?? this.detail,
    payment: payment == null ? this.payment : payment(),
    order: order == null ? this.order : order(),
    busy: busy == null ? this.busy : busy(),
    unknown: unknown == null ? this.unknown : unknown(),
    failure: failure == null ? this.failure : failure(),
    loadFailure: loadFailure == null ? this.loadFailure : loadFailure(),
    stateChanged: stateChanged ?? this.stateChanged,
    manualMismatch: manualMismatch ?? this.manualMismatch,
    done: done == null ? this.done : done(),
  );
}

/// Связанный документ вида [type] (первый).
String? relatedId(Transaction t, TransactionRelatedType type) {
  for (final TransactionRelated r in t.related) {
    if (r.type == type && r.id != null) return r.id;
  }
  return null;
}

/// SCR-37 по `transactionId`.
final transactionDetailsControllerProvider = NotifierProvider.autoDispose
    .family<TransactionDetailsController, TransactionDetailsState, String>(TransactionDetailsController.new);

/// Логика SCR-37.
final class TransactionDetailsController extends Notifier<TransactionDetailsState> {
  TransactionDetailsController(this.transactionId);

  /// ID транзакции.
  final String transactionId;

  bool _disposed = false;
  String? _key;
  Object? _request;

  PaymentsRepository get _payments => ref.read(paymentsRepositoryProvider);

  @override
  TransactionDetailsState build() {
    ref.onDispose(() => _disposed = true);
    return const TransactionDetailsState();
  }

  void _set(TransactionDetailsState s) {
    if (!_disposed) state = s;
  }

  /// Загрузить деталь и связанные платёж/заказ.
  Future<void> load() async {
    if (state.detail == null) _set(state.copyWith(phase: TransactionDetailsPhase.loading, loadFailure: () => null));
    final Result<TransactionDetail> r = await ref.read(transactionsRepositoryProvider).get(transactionId);
    if (_disposed) return;
    switch (r) {
      case FailureResult<TransactionDetail>(:final Failure failure):
        if (state.detail != null) {
          _set(state.copyWith(failure: () => failure));
          return;
        }
        final TransactionDetailsPhase phase = switch (failure) {
          NetworkFailure() => TransactionDetailsPhase.offline,
          PermissionFailure() => TransactionDetailsPhase.forbidden,
          ServerFailure(status: 404) => TransactionDetailsPhase.notFound,
          _ => TransactionDetailsPhase.error,
        };
        _set(state.copyWith(phase: phase, loadFailure: () => failure));
        return;
      case Success<TransactionDetail>(:final TransactionDetail value):
        _set(state.copyWith(phase: TransactionDetailsPhase.ready, detail: value, loadFailure: () => null));
        final String? paymentId = relatedId(value.transaction, TransactionRelatedType.payment);
        final String? orderId = relatedId(value.transaction, TransactionRelatedType.order);
        final Future<Result<PaymentDetails>>? pf = paymentId == null ? null : _payments.get(paymentId);
        final Future<Result<OrderDetails>>? of = orderId == null
            ? null
            : ref.read(ordersRepositoryProvider).get(orderId);
        if (pf != null) {
          final Result<PaymentDetails> p = await pf;
          if (_disposed) return;
          if (p case Success<PaymentDetails>(:final PaymentDetails value)) _set(state.copyWith(payment: () => value));
        }
        if (of != null) {
          final Result<OrderDetails> o = await of;
          if (_disposed) return;
          if (o case Success<OrderDetails>(:final OrderDetails value)) _set(state.copyWith(order: () => value));
        }
    }
  }

  Future<void> _reloadPayment() async {
    final String? id = state.payment?.payment.id;
    if (id == null) return;
    final Result<PaymentDetails> p = await _payments.get(id);
    if (_disposed) return;
    if (p case Success<PaymentDetails>(:final PaymentDetails value)) _set(state.copyWith(payment: () => value));
  }

  /// Ручное подтверждение QR (UI-37-010): step-up до запроса.
  Future<bool> confirmManual(ConfirmManualRequest request) async {
    final Payment? p = state.payment?.payment;
    if (p == null || state.busy != null) return false;
    _set(state.copyWith(busy: () => DetailsAction.confirmManual, failure: () => null, stateChanged: false));
    final TransactionsStepUp stepUp = ref.read(transactionsStepUpProvider);
    final TransactionsStepUpResult pre = await stepUp('payment.qr.confirm_manual');
    if (_disposed) return false;
    if (pre.cancelled) {
      _set(state.copyWith(busy: () => null));
      return false;
    }
    if (_request is! ConfirmManualRequest || state.unknown != DetailsAction.confirmManual) {
      _key = ref.read(transactionsKeyFactoryProvider)();
      _request = request;
    }
    return _sendConfirm(p.id, _request! as ConfirmManualRequest, pre.token);
  }

  Future<bool> _sendConfirm(String paymentId, ConfirmManualRequest request, String? token) async {
    Result<Payment> r = await _payments.confirmManual(paymentId, request, idempotencyKey: _key!, stepUpToken: token);
    final Failure? f = r.failureOrNull;
    if (f is AuthFailure && f.reason == AuthReason.stepUpRequired && !_disposed) {
      final TransactionsStepUpResult again = await ref.read(transactionsStepUpProvider)(
        f.stepUpOperation ?? 'payment.qr.confirm_manual',
      );
      if (!again.cancelled && !_disposed) {
        r = await _payments.confirmManual(paymentId, request, idempotencyKey: _key!, stepUpToken: again.token);
      }
    }
    if (_disposed) return false;
    return _finish(r, DetailsAction.confirmManual);
  }

  /// Аннулировать неполученный платёж (UI-37-009): step-up по `403` (AuthInterceptor, тот же ключ).
  Future<bool> voidPayment(VoidPaymentRequest request) async {
    final Payment? p = state.payment?.payment;
    if (p == null || state.busy != null) return false;
    if (_request is! VoidPaymentRequest || state.unknown != DetailsAction.voidPayment) {
      _key = ref.read(transactionsKeyFactoryProvider)();
      _request = request;
    }
    _set(state.copyWith(busy: () => DetailsAction.voidPayment, failure: () => null, stateChanged: false));
    final Result<Payment> r = await _payments.voidPayment(p.id, _request! as VoidPaymentRequest, idempotencyKey: _key!);
    if (_disposed) return false;
    return _finish(r, DetailsAction.voidPayment);
  }

  /// «Проверить» (Unknown): повтор того же действия тем же ключом.
  Future<void> check() async {
    final Payment? p = state.payment?.payment;
    final DetailsAction? a = state.unknown;
    if (p == null || a == null || _key == null || state.busy != null) return;
    _set(state.copyWith(busy: () => a));
    switch (a) {
      case DetailsAction.confirmManual:
        await _sendConfirm(p.id, _request! as ConfirmManualRequest, null);
      case DetailsAction.voidPayment:
        final Result<Payment> r = await _payments.voidPayment(
          p.id,
          _request! as VoidPaymentRequest,
          idempotencyKey: _key!,
        );
        if (!_disposed) await _finish(r, a);
    }
  }

  Future<bool> _finish(Result<Payment> r, DetailsAction action) async {
    switch (r) {
      case Success<Payment>(:final Payment value):
        _key = null;
        _request = null;
        final bool mismatch = action == DetailsAction.confirmManual && value.status == PaymentStatus.manualConfirm;
        _set(
          state.copyWith(
            busy: () => null,
            unknown: () => null,
            manualMismatch: mismatch,
            done: mismatch ? null : () => action,
          ),
        );
        await load();
        return true;
      case FailureResult<Payment>(:final Failure failure):
        if (failure is NetworkFailure) {
          _set(state.copyWith(busy: () => null, unknown: () => action));
          return false;
        }
        _key = null;
        _request = null;
        if (failure is AuthFailure && failure.reason == AuthReason.stepUpRequired) {
          _set(state.copyWith(busy: () => null, unknown: () => null));
          return false;
        }
        if (failure is ConflictFailure && failure.kind == ConflictKind.paymentStateInvalid) {
          _set(state.copyWith(busy: () => null, unknown: () => null, stateChanged: true));
          await _reloadPayment();
          return false;
        }
        _set(state.copyWith(busy: () => null, unknown: () => null, failure: () => failure));
        return false;
    }
  }

  /// Сообщение показано.
  void consumeDone() => _set(state.copyWith(done: () => null));

  /// Скрыть сообщения.
  void dismiss() => _set(state.copyWith(stateChanged: false, manualMismatch: false, failure: () => null));

  /// Печать документа заказа (`GET /orders/{id}/documents/{kind}.pdf`); `true` — отправлено.
  Future<bool> print(OrderDocumentKind kind) async {
    final String? orderId = state.order?.order.id;
    final TransactionsDocumentPrinter? printer = ref.read(transactionsDocumentPrinterProvider);
    if (orderId == null || printer == null) return false;
    final Result<OrderDocumentFile> r = await ref
        .read(ordersRepositoryProvider)
        .document(orderId, kind, format: kind == OrderDocumentKind.receipt ? PrintPaper.thermal80 : PrintPaper.a4);
    if (r case Success<OrderDocumentFile>(:final OrderDocumentFile value)) {
      try {
        return await printer(value);
      } on Object {
        return false;
      }
    }
    return false;
  }
}
