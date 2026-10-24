// Незавершённые финансовые операции текущей сессии (02 §0.3 P-IDEMP; 07 DATA-263; ядро §22.6): `Idempotency-Key`,
// вид операции, объект, тело запроса и описание для баннера SCR-30 «Незавершённая операция: {описание} · Проверить»
// хранятся **только в памяти процесса** до окончательного ответа (2xx или 4xx бизнес-уровня) или «Отменить операцию».
// В drift (в том числе `outbox_actions`) и secure storage ничего не пишется; автоповтора нет. Смена пользователя
// сессии (выход, вход другого кассира) — новая пустая память.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// Вид незавершённой операции (описание баннера — ключи `cashier_unfinished_desc_*`).
enum UnfinishedKind {
  /// Приём оплаты по заказу (`POST /orders/{id}/payments`).
  orderPayment,

  /// Ручное подтверждение QR (`POST /payments/{id}/confirm-manual`).
  confirmManual,

  /// Аннулирование платежа (`POST /payments/{id}/void`).
  voidPayment,
}

/// Незавершённая операция (только память).
@immutable
final class UnfinishedOperation {
  /// Создаёт запись.
  const UnfinishedOperation({
    required this.kind,
    required this.idempotencyKey,
    required this.orderId,
    this.orderNumber,
    this.amount,
    this.paymentId,
    this.request,
  });

  /// Вид.
  final UnfinishedKind kind;

  /// Ключ идемпотентности — повтор «Проверить» идёт с ним же.
  final String idempotencyKey;

  /// Заказ (SCR-38 открывается по нему).
  final String orderId;

  /// Номер заказа для описания.
  final String? orderNumber;

  /// Сумма заказа к оплате (не сумма долга; P-IDEMP).
  final Money? amount;

  /// Платёж (подтверждение / аннулирование).
  final String? paymentId;

  /// Тело запроса (`OrderPaymentRequest` и т. п.) — повтор тем же телом.
  final Object? request;

  /// Тело запроса приёма оплаты.
  OrderPaymentRequest? get paymentRequest => request is OrderPaymentRequest ? request! as OrderPaymentRequest : null;

  /// Тело запроса ручного подтверждения QR.
  ConfirmManualRequest? get confirmRequest => request is ConfirmManualRequest ? request! as ConfirmManualRequest : null;

  /// Тело запроса аннулирования.
  VoidPaymentRequest? get voidRequest => request is VoidPaymentRequest ? request! as VoidPaymentRequest : null;
}

/// Память незавершённых операций сессии.
final class UnfinishedOperationsNotifier extends Notifier<List<UnfinishedOperation>> {
  @override
  List<UnfinishedOperation> build() {
    // Новая память при каждой смене пользователя сессии, в том числе выход → вход того же пользователя
    // (CASH-015; P-IDEMP: после выхода ключей нет).
    ref.watch(cashierSessionScopeProvider);
    return const <UnfinishedOperation>[];
  }

  /// Запомнить (или заменить запись с тем же ключом).
  void put(UnfinishedOperation op) {
    state = <UnfinishedOperation>[
      for (final UnfinishedOperation o in state)
        if (o.idempotencyKey != op.idempotencyKey) o,
      op,
    ];
  }

  /// Забыть после окончательного ответа или «Отменить операцию».
  void remove(String idempotencyKey) {
    if (!state.any((UnfinishedOperation o) => o.idempotencyKey == idempotencyKey)) return;
    state = <UnfinishedOperation>[
      for (final UnfinishedOperation o in state)
        if (o.idempotencyKey != idempotencyKey) o,
    ];
  }

  /// Незавершённая операция по заказу (последняя); [kind] `null` — любого вида (приём оплаты, ручное подтверждение
  /// QR, аннулирование: баннер SCR-30 ведёт на SCR-38 заказа для любого вида — AC-UI-30-017).
  UnfinishedOperation? forOrder(String orderId, {UnfinishedKind? kind}) {
    for (final UnfinishedOperation o in state.reversed) {
      if (o.orderId == orderId && (kind == null || o.kind == kind)) return o;
    }
    return null;
  }
}

/// Незавершённые операции текущей сессии (SCR-30 баннер, SCR-38 состояние «Результат неизвестен»).
final cashierUnfinishedOperationsProvider = NotifierProvider<UnfinishedOperationsNotifier, List<UnfinishedOperation>>(
  UnfinishedOperationsNotifier.new,
);
