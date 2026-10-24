// Состояние SCR-39 «Заявка на возврат» (02 SCR-39.7): фазы экрана, строки к возврату с лимитом «отгружено −
// возвращено» (10 RET-003, RET-005, RET-008), причина и комментарий (RET-004), пожелание способа (08 §3.12 `refundKind`),
// флаги ответа сервера (порог RET-009, `already_in_onec` RET-013, неизвестный исход P-IDEMP). Деньги — `Money`
// (тыйыны), количества — `Qty` (milli), D-19. Только память (07 §11.2: таблиц заявок в drift нет).
import 'package:flutter/foundation.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/utils/amount_exception.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';

/// Аргументы экрана: `/returns/new?orderId=` или `/returns/{id}`.
@immutable
final class ReturnScreenArgs {
  /// Создаёт аргументы.
  const ReturnScreenArgs({this.orderId, this.returnId});

  /// Новая заявка по заказу.
  final String? orderId;

  /// Сохранённая заявка.
  final String? returnId;

  @override
  bool operator ==(Object other) => other is ReturnScreenArgs && other.orderId == orderId && other.returnId == returnId;

  @override
  int get hashCode => Object.hash(orderId, returnId);

  @override
  String toString() => 'ReturnScreenArgs(order: $orderId, return: $returnId)';
}

/// Фаза экрана (02 SCR-39.7).
enum ReturnPhase {
  /// Скелетон карточки и строк.
  loading,

  /// Форма (новая заявка или черновик).
  editing,

  /// Заявка не в `draft`: заголовок со статусом, статус-линия, позиции read-only.
  viewOnly,

  /// Заказ не отгружен / нет реализации 1С (RET-001).
  notReturnable,

  /// `404` — нет заявки или чужой черновик для `cashier` (11 SEC-030 (г)).
  notFound,

  /// `5xx` / сбой — «Повторить».
  error,

  /// Нет сети и данных в памяти (`return_offline_no_data`).
  offlineNoData,
}

/// Идущая операция (повторные нажатия игнорируются, 02 SCR-39.4).
enum ReturnBusy { saving, submitting, deleting, accepting, rejecting }

/// Операция с неизвестным исходом (P-IDEMP): повтор — тем же `Idempotency-Key`.
enum ReturnPendingOp { create, submit }

/// Строка к возврату (по строке заказа `OrderLine` и/или строке заявки `ReturnRequestItem`).
@immutable
final class ReturnLine {
  /// Создаёт строку.
  const ReturnLine({
    required this.orderLineNo,
    required this.variantId,
    required this.unitId,
    required this.sold,
    this.title,
    this.variantName,
    this.packagingId,
    this.returned,
    this.maxReturnable,
    this.orderedQty,
    this.lineTotal,
    this.serverAmount,
    this.checked = false,
    this.qty = Qty.zero,
    this.serverError = false,
  });

  /// Строка заказа (`orderLineNo`).
  final int orderLineNo;
  final String variantId;

  /// Название товара (`null` — заказ не загружен; экран показывает артикул варианта).
  final String? title;
  final String? variantName;

  /// Единица количества строки заказа.
  final String unitId;
  final String? packagingId;

  /// Отгружено (`shippedQuantity`; без него — заказанное количество).
  final Qty sold;

  /// Уже возвращено; `null` — нет данных о прежних возвратах (02 `return_no_previous_data`).
  final Qty? returned;

  /// `maxReturnable` сервера (приоритетнее расчёта).
  final Qty? maxReturnable;

  /// Заказанное количество и сумма строки со скидкой — для предварительной суммы (MNY-006).
  final Qty? orderedQty;
  final Money? lineTotal;

  /// Сумма строки из ответа сервера (`ReturnRequestItem.amount`).
  final Money? serverAmount;

  /// Включена в заявку и количество.
  final bool checked;
  final Qty qty;

  /// Сервер отверг количество строки (`RETURN_QTY_EXCEEDED`).
  final bool serverError;

  /// Можно вернуть: `maxReturnable` или «отгружено − возвращено» (без данных о возвратах — отгружено), ≥ 0.
  Qty get limit {
    final Qty raw = maxReturnable ?? (returned == null ? sold : sold - returned!);
    return raw.milli < 0 ? Qty.zero : raw;
  }

  /// Возвращено полностью — строка `disabled`.
  bool get fullyReturned => limit.milli <= 0;

  /// Нет данных о прежних возвратах — количество проверит 1С (RET-003).
  bool get noPreviousData => maxReturnable == null && returned == null;

  /// Количество больше допустимого (AC-UI-39-002).
  bool get exceeds => checked && qty > limit;

  /// Строка участвует в заявке.
  bool get selected => checked && qty.milli > 0;

  /// Предварительная сумма строки: `lineTotal / quantity × qty` (MNY-006); `null` — не вычислить.
  Money? get preliminaryAmount {
    if (!selected) return null;
    final Money? total = lineTotal;
    final Qty base = orderedQty ?? sold;
    if (total == null || base.milli <= 0) return serverAmount;
    try {
      return MoneyMath.returnLineAmount(total, base, qty);
    } on AmountException {
      return serverAmount;
    }
  }

  ReturnLine copyWith({bool? checked, Qty? qty, bool? serverError}) => ReturnLine(
    orderLineNo: orderLineNo,
    variantId: variantId,
    title: title,
    variantName: variantName,
    unitId: unitId,
    packagingId: packagingId,
    sold: sold,
    returned: returned,
    maxReturnable: maxReturnable,
    orderedQty: orderedQty,
    lineTotal: lineTotal,
    serverAmount: serverAmount,
    checked: checked ?? this.checked,
    qty: qty ?? this.qty,
    serverError: serverError ?? this.serverError,
  );

  /// Строки формы: строки заказа [order] (если загружен) с позициями заявки [request] поверх.
  static List<ReturnLine> build(Order? order, ReturnRequest? request) {
    final Map<int, ReturnRequestItem> items = <int, ReturnRequestItem>{
      for (final ReturnRequestItem i in request?.items ?? const <ReturnRequestItem>[]) i.orderLineNo: i,
    };
    final List<ReturnLine> lines = <ReturnLine>[];
    if (order != null) {
      for (final OrderLine l in order.items) {
        final ReturnRequestItem? item = items.remove(l.lineNo);
        lines.add(
          ReturnLine(
            orderLineNo: l.lineNo,
            variantId: l.variantId,
            title: l.productName,
            variantName: l.variantName,
            unitId: l.quantity.unitId,
            packagingId: l.quantity.packagingId,
            sold: l.shippedQuantity ?? l.quantity.value,
            returned: l.returnedQuantity,
            maxReturnable: item?.maxReturnable,
            orderedQty: l.quantity.value,
            lineTotal: l.lineTotal,
            serverAmount: item?.amount,
            checked: item != null,
            qty: item?.quantity.value ?? Qty.zero,
          ),
        );
      }
    }
    // Позиции заявки без строки заказа (заказ не загружен): лимит — `maxReturnable` сервера.
    for (final ReturnRequestItem i in items.values) {
      lines.add(
        ReturnLine(
          orderLineNo: i.orderLineNo,
          variantId: i.variantId,
          unitId: i.quantity.unitId,
          packagingId: i.quantity.packagingId,
          sold: i.maxReturnable ?? i.quantity.value,
          maxReturnable: i.maxReturnable ?? i.quantity.value,
          serverAmount: i.amount,
          checked: true,
          qty: i.quantity.value,
        ),
      );
    }
    lines.sort((ReturnLine a, ReturnLine b) => a.orderLineNo.compareTo(b.orderLineNo));
    return lines;
  }
}

/// Состояние SCR-39.
@immutable
final class ReturnFormState {
  /// Создаёт состояние.
  const ReturnFormState({
    this.phase = ReturnPhase.loading,
    this.order,
    this.request,
    this.lines = const <ReturnLine>[],
    this.reason,
    this.comment = '',
    this.refundKind,
    this.dirty = false,
    this.busy,
    this.commentError = false,
    this.thresholdBlocked = false,
    this.alreadyInOnec = false,
    this.pending,
    this.failure,
    this.loadedAt,
    this.rejectReason,
  });

  final ReturnPhase phase;

  /// Исходный заказ (`GET /orders/{id}?include=items,documents`).
  final Order? order;

  /// Сохранённая заявка (`null` — ещё не сохранена).
  final ReturnRequest? request;
  final List<ReturnLine> lines;
  final ReturnReason? reason;
  final String comment;

  /// Пожелание способа возврата денег (`cash` | `qr_bakai` | `credit`); деньги возвращает 1С (D-25).
  final PaymentMethod? refundKind;

  /// Есть несохранённые изменения («Назад» — `ConfirmDialog`, отправка — сначала сохранение).
  final bool dirty;
  final ReturnBusy? busy;

  /// «Иное» без комментария ≥ 10 символов — показана ошибка (после попытки сохранить/отправить).
  final bool commentError;

  /// UI-39-012: сумма выше порога — отправляет старший (RET-009, CASH-007).
  final bool thresholdBlocked;

  /// `409 already_in_onec`: кнопки решения скрыты до перезагрузки (UI-39-015/016).
  final bool alreadyInOnec;

  /// Операция с неизвестным исходом (баннер `return_unknown`).
  final ReturnPendingOp? pending;

  /// Ошибка загрузки (фаза [ReturnPhase.error]).
  final Failure? failure;

  /// Время последнего ответа сервера («Статус из 1С на HH:MM»).
  final DateTime? loadedAt;

  /// Причина отклонения, указанная в этой сессии (в `ReturnRequest` её нет — GQ-FERET-04).
  final String? rejectReason;

  /// Минимальная длина комментария при `other` (02 SCR-39.4, Q-176).
  static const int otherCommentMin = 10;

  /// Счётчик комментария в UI (02 UI-39-004: 0/300; контракт — ≤ 500).
  static const int commentMaxUi = 300;

  /// Причина отклонения 5…500 (02 UI-39-016).
  static const int rejectReasonMin = 5;

  /// Выбранные строки.
  List<ReturnLine> get selectedLines => <ReturnLine>[
    for (final ReturnLine l in lines)
      if (l.selected) l,
  ];

  bool get hasSelection => lines.any((ReturnLine l) => l.selected);

  bool get anyExceeds => lines.any((ReturnLine l) => l.exceeds);

  /// Комментарий для `other` достаточен.
  bool get commentValid => reason != ReturnReason.other || comment.trim().length >= otherCommentMin;

  /// «Сохранить черновик» / «Отправить заявку» активны (AC-UI-39-003): строки, причина, без превышений.
  bool get formComplete => hasSelection && reason != null && !anyExceeds;

  /// Предварительная сумма: после сохранения без изменений — `totalAmount` сервера, иначе сумма строк (RET-005).
  Money? get displayTotal {
    final ReturnRequest? r = request;
    if (r != null && !dirty && r.totalAmount != null) return r.totalAmount;
    if (!hasSelection) return Money.zero;
    Money sum = Money.zero;
    for (final ReturnLine l in selectedLines) {
      final Money? a = l.preliminaryAmount;
      if (a == null) return null;
      sum = sum + a;
    }
    return sum;
  }

  ReturnFormState copyWith({
    ReturnPhase? phase,
    Order? order,
    ReturnRequest? Function()? request,
    List<ReturnLine>? lines,
    ReturnReason? Function()? reason,
    String? comment,
    PaymentMethod? Function()? refundKind,
    bool? dirty,
    ReturnBusy? Function()? busy,
    bool? commentError,
    bool? thresholdBlocked,
    bool? alreadyInOnec,
    ReturnPendingOp? Function()? pending,
    Failure? Function()? failure,
    DateTime? loadedAt,
    String? Function()? rejectReason,
  }) => ReturnFormState(
    phase: phase ?? this.phase,
    order: order ?? this.order,
    request: request == null ? this.request : request(),
    lines: lines ?? this.lines,
    reason: reason == null ? this.reason : reason(),
    comment: comment ?? this.comment,
    refundKind: refundKind == null ? this.refundKind : refundKind(),
    dirty: dirty ?? this.dirty,
    busy: busy == null ? this.busy : busy(),
    commentError: commentError ?? this.commentError,
    thresholdBlocked: thresholdBlocked ?? this.thresholdBlocked,
    alreadyInOnec: alreadyInOnec ?? this.alreadyInOnec,
    pending: pending == null ? this.pending : pending(),
    failure: failure == null ? this.failure : failure(),
    loadedAt: loadedAt ?? this.loadedAt,
    rejectReason: rejectReason == null ? this.rejectReason : rejectReason(),
  );
}

/// Итог действия для экрана (снекбары, переходы).
enum ReturnOutcome {
  /// Повторное нажатие во время запроса / нечего делать.
  ignored,

  /// Не прошла клиентская валидация (ошибки показаны у полей).
  invalid,

  /// Черновик создан (`POST /returns`) — маршрут заменяется на `/returns/{id}`.
  created,

  /// Черновик сохранён (`PATCH`).
  saved,

  /// Заявка отправлена (`submitted`).
  submitted,

  /// Пользователь отменил `StepUpDialog` — заявка осталась черновиком.
  stepUpCancelled,

  /// Порог согласования (UI-39-012).
  thresholdBlocked,

  /// `VERSION_CONFLICT` — данные перечитаны.
  versionConflict,

  /// `RETURN_QTY_EXCEEDED` — строки подсвечены.
  qtyExceeded,

  /// `ORDER_STATE_INVALID not_draft` / `invalid_transition` — заявка перечитана.
  stateChanged,

  /// `order_not_shipped`.
  notReturnable,

  /// Исход неизвестен (сеть/таймаут) — баннер «Проверить».
  unknown,

  /// Черновик удалён (в т. ч. `404` — уже удалён).
  deleted,

  /// Согласовано / отклонено.
  accepted,
  rejected,

  /// `409 already_in_onec` — решение только в 1С.
  alreadyInOnec,

  /// `403 FORBIDDEN` (P-403).
  forbidden,

  /// Прочая ошибка ([ReturnActionResult.failure]).
  failed,
}

/// Итог действия и ошибка (для текста снекбара).
typedef ReturnActionResult = ({ReturnOutcome outcome, Failure? failure});
