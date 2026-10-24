// Контроллер SCR-39 (02 SCR-39.4, SCR-39.7, SCR-39.11): загрузка заказа/заявки, правка строк (≤ отгружено −
// возвращено), сохранение черновика (`POST /returns` с `Idempotency-Key`, далее `PATCH` по `rowVersion`), отправка
// (сохранение изменений → step-up `return.submit` → `POST /returns/{id}/submit`), удаление черновика, согласование /
// отклонение держателем `return.approve` (step-up). Ключи идемпотентности — только в памяти до окончательного ответа
// (P-IDEMP, 07 DATA-263): повтор после потери связи — тем же ключом, автоповтора нет. Повторные нажатия во время
// запроса игнорируются. Состояние — только память (07 §11.2).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';
import 'package:optomstroy/features/returns/domain/repositories/returns_repository.dart';
import 'package:optomstroy/features/returns/presentation/providers/returns_ports.dart';
import 'package:optomstroy/features/returns/presentation/state/return_request_state.dart';
import 'package:optomstroy/features/returns/returns_providers.dart';

/// Передача состояния при замене маршрута `/returns/new?orderId=` → `/returns/{id}` после первого сохранения
/// (02 SCR-39.4 `replace`): новый экран продолжает с тем же состоянием (порог, причина отклонения), без перезагрузки.
/// Только память процесса; запись забирается один раз.
final class ReturnsHandoff {
  final Map<String, ReturnFormState> _states = <String, ReturnFormState>{};

  /// Оставить состояние для экрана заявки [returnId].
  void put(String returnId, ReturnFormState state) => _states[returnId] = state;

  /// Забрать состояние (один раз).
  ReturnFormState? take(String returnId) => _states.remove(returnId);
}

/// Передача состояния между экранами SCR-39.
final returnsHandoffProvider = Provider<ReturnsHandoff>((ref) => ReturnsHandoff());

/// `returnRequestProvider(args)`.
final returnRequestProvider = NotifierProvider.autoDispose
    .family<ReturnRequestController, ReturnFormState, ReturnScreenArgs>(ReturnRequestController.new);

/// Контроллер заявки на возврат.
final class ReturnRequestController extends Notifier<ReturnFormState> {
  /// Контроллер экрана с аргументами [args].
  ReturnRequestController(this.args);

  final ReturnScreenArgs args;
  int _generation = 0;

  String? _createKey;
  String? _submitKey;
  String? _acceptKey;
  String? _rejectKey;
  String? _rejectKeyReason;

  @override
  ReturnFormState build() {
    final String? id = args.returnId;
    final ReturnFormState? handed = id == null ? null : ref.read(returnsHandoffProvider).take(id);
    if (handed != null) return handed;
    unawaited(Future<void>.microtask(load));
    return const ReturnFormState();
  }

  ReturnsRepository get _repo => ref.read(returnsRepositoryProvider);

  bool _alive(int gen) => ref.mounted && gen == _generation;

  DateTime get _now => ref.read(clockProvider).nowUtc();

  String _newKey() => ref.read(returnsKeyFactoryProvider)();

  static bool _isNotFound(Failure f) => f is ServerFailure && (f.status == 404 || f.code == 'NOT_FOUND');

  static bool _isOffline(Failure f) => f is NetworkFailure && f.kind == NetworkFailureKind.offline && !f.outcomeUnknown;

  /// Исход запроса неизвестен: ответ потерян после отправки (P-IDEMP).
  static bool _isUnknownOutcome(Failure f) =>
      f is NetworkFailure && (f.outcomeUnknown || f.kind == NetworkFailureKind.timeout);

  static bool _isReturnState(Failure f, String reason) =>
      f is ConflictFailure && f.kind == ConflictKind.orderStateInvalid && f.reason == reason;

  static bool _isQtyExceeded(Failure f) => f is ServerFailure && f.code == ProblemCode.returnQtyExceeded.value;

  Future<Result<T>> _guard<T>(Future<Result<T>> Function() run) async {
    try {
      return await run();
    } on Object catch (e) {
      return FailureResult<T>(UnknownFailure(cause: e));
    }
  }

  // --- Загрузка -------------------------------------------------------------------------------------------------

  /// Загрузка (первая и «Повторить»).
  Future<void> load() async {
    final int gen = ++_generation;
    if (!ref.mounted) return;
    state = const ReturnFormState();
    final String? returnId = args.returnId;
    if (returnId != null) {
      final Result<ReturnRequest> r = await _guard(() => _repo.get(returnId));
      if (!_alive(gen)) return;
      switch (r) {
        case FailureResult<ReturnRequest>(:final Failure failure):
          state = _failedLoad(failure);
        case Success<ReturnRequest>(:final ReturnRequest value):
          final Order? order = await _loadOrderQuiet(value.orderId);
          if (!_alive(gen)) return;
          state = _fromRequest(value, order: order);
      }
      return;
    }
    final String? orderId = args.orderId;
    if (orderId == null || orderId.isEmpty) {
      state = const ReturnFormState(phase: ReturnPhase.notReturnable);
      return;
    }
    final Result<OrderDetails> r = await _guard(() => ref.read(ordersRepositoryProvider).get(orderId));
    if (!_alive(gen)) return;
    switch (r) {
      case FailureResult<OrderDetails>(:final Failure failure):
        state = _failedLoad(failure);
      case Success<OrderDetails>(:final OrderDetails value):
        final Order o = value.order;
        state = ReturnFormState(
          phase: isReturnable(o) ? ReturnPhase.editing : ReturnPhase.notReturnable,
          order: o,
          lines: ReturnLine.build(o, null),
          loadedAt: _now,
        );
    }
  }

  /// Заявка по заказу возможна: `shipped`/`partially_returned` с реализацией 1С (RET-001, RET-002).
  static bool isReturnable(Order o) =>
      (o.status == OrderStatus.shipped || o.status == OrderStatus.partiallyReturned) && o.onec?.number != null;

  ReturnFormState _failedLoad(Failure f) {
    if (_isNotFound(f)) return ReturnFormState(phase: ReturnPhase.notFound, failure: f);
    if (_isOffline(f)) return ReturnFormState(phase: ReturnPhase.offlineNoData, failure: f);
    return ReturnFormState(phase: ReturnPhase.error, failure: f);
  }

  Future<Order?> _loadOrderQuiet(String orderId) async {
    final Result<OrderDetails> r = await _guard(() => ref.read(ordersRepositoryProvider).get(orderId));
    return switch (r) {
      Success<OrderDetails>(:final OrderDetails value) => value.order,
      FailureResult<OrderDetails>() => null,
    };
  }

  ReturnFormState _fromRequest(ReturnRequest r, {Order? order, ReturnFormState? base}) {
    final ReturnFormState b = base ?? state;
    return ReturnFormState(
      phase: r.isDraft ? ReturnPhase.editing : ReturnPhase.viewOnly,
      order: order ?? b.order,
      request: r,
      lines: ReturnLine.build(order ?? b.order, r),
      reason: r.reasonCode,
      comment: r.reasonComment ?? '',
      refundKind: r.refundKind,
      loadedAt: _now,
      thresholdBlocked: r.isDraft && b.thresholdBlocked,
      rejectReason: b.rejectReason,
    );
  }

  /// Перечитать заявку (конфликт версии, смена статуса, синхронизация).
  Future<Failure?> reloadRequest() async {
    final String? id = state.request?.id;
    if (id == null) return null;
    final int gen = ++_generation;
    final Result<ReturnRequest> r = await _guard(() => _repo.get(id));
    if (!_alive(gen)) return null;
    switch (r) {
      case Success<ReturnRequest>(:final ReturnRequest value):
        state = _fromRequest(value);
        return null;
      case FailureResult<ReturnRequest>(:final Failure failure):
        if (_isNotFound(failure)) state = ReturnFormState(phase: ReturnPhase.notFound, failure: failure);
        return failure;
    }
  }

  // --- Правка формы ---------------------------------------------------------------------------------------------

  bool get _editable => state.phase == ReturnPhase.editing && state.busy == null;

  void _updateLine(int orderLineNo, ReturnLine Function(ReturnLine l) f) {
    if (!_editable) return;
    state = state.copyWith(
      lines: <ReturnLine>[
        for (final ReturnLine l in state.lines)
          if (l.orderLineNo == orderLineNo) f(l).copyWith(serverError: false) else l,
      ],
      dirty: true,
    );
  }

  static Qty _one(ReturnLine l) => l.limit < Qty.units(1) ? l.limit : Qty.units(1);

  /// Чекбокс строки: включение ставит 1 (или весь остаток, если он меньше 1), снятие обнуляет строку.
  void toggleLine(int orderLineNo, bool checked) => _updateLine(
    orderLineNo,
    (ReturnLine l) => l.fullyReturned ? l : l.copyWith(checked: checked, qty: checked ? _one(l) : Qty.zero),
  );

  /// «+» (не выше лимита).
  void increment(int orderLineNo) => _updateLine(orderLineNo, (ReturnLine l) {
    if (!l.checked) return l;
    final Qty next = l.qty + Qty.units(1);
    return l.copyWith(qty: next > l.limit ? l.limit : next);
  });

  /// «−» (не ниже минимального шага; 0 — снимает строку).
  void decrement(int orderLineNo) => _updateLine(orderLineNo, (ReturnLine l) {
    if (!l.checked) return l;
    final Qty next = l.qty - Qty.units(1);
    if (next.milli <= 0) return l.copyWith(checked: false, qty: Qty.zero);
    return l.copyWith(qty: next);
  });

  /// Ручной ввод (нампад): больше лимита — строка в ошибке (AC-UI-39-002), 0 — снимает строку.
  void setQty(int orderLineNo, Qty qty) => _updateLine(
    orderLineNo,
    (ReturnLine l) => qty.milli <= 0 ? l.copyWith(checked: false, qty: Qty.zero) : l.copyWith(checked: true, qty: qty),
  );

  /// «Выбрать всё» — все доступные строки с максимальным количеством.
  void selectAll() {
    if (!_editable) return;
    state = state.copyWith(
      lines: <ReturnLine>[
        for (final ReturnLine l in state.lines)
          l.fullyReturned ? l : l.copyWith(checked: true, qty: l.limit, serverError: false),
      ],
      dirty: true,
    );
  }

  void setReason(ReturnReason reason) {
    if (!_editable) return;
    state = state.copyWith(reason: () => reason, dirty: true, commentError: false);
  }

  void setComment(String comment) {
    if (!_editable || comment == state.comment) return;
    state = state.copyWith(comment: comment, dirty: true, commentError: state.commentError && !_commentOk(comment));
  }

  bool _commentOk(String comment) =>
      state.reason != ReturnReason.other || comment.trim().length >= ReturnFormState.otherCommentMin;

  void setRefundKind(PaymentMethod? kind) {
    if (!_editable) return;
    state = state.copyWith(refundKind: () => kind, dirty: true);
  }

  /// Закрыть баннер порога (ThresholdBlocked → Editing).
  void dismissThreshold() => state = state.copyWith(thresholdBlocked: false);

  /// Валидация перед запросом (AC-UI-39-003).
  bool _validate() {
    if (!state.formComplete) return false;
    if (!state.commentValid) {
      state = state.copyWith(commentError: true);
      return false;
    }
    return true;
  }

  List<ReturnItemInput> _items() => <ReturnItemInput>[
    for (final ReturnLine l in state.selectedLines)
      ReturnItemInput(
        orderLineNo: l.orderLineNo,
        quantity: LineQuantity(value: l.qty, unitId: l.unitId, packagingId: l.packagingId),
      ),
  ];

  String? get _commentOrNull {
    final String c = state.comment.trim();
    return c.isEmpty ? null : c;
  }

  // --- Сохранение -----------------------------------------------------------------------------------------------

  /// «Сохранить черновик» (UI-39-006).
  Future<ReturnActionResult> saveDraft() async {
    if (state.busy != null || state.phase != ReturnPhase.editing) {
      return (outcome: ReturnOutcome.ignored, failure: null);
    }
    if (!_validate()) return (outcome: ReturnOutcome.invalid, failure: null);
    state = state.copyWith(busy: () => ReturnBusy.saving);
    final ReturnActionResult r = await _save();
    if (ref.mounted) state = state.copyWith(busy: () => null);
    return r;
  }

  Future<ReturnActionResult> _save() async {
    final ReturnRequest? existing = state.request;
    if (existing == null) return _create();
    if (!state.dirty) return (outcome: ReturnOutcome.saved, failure: null);
    final List<ReturnItemInput> sent = _items();
    final Result<ReturnRequest> r = await _guard(
      () => _repo.update(
        existing.id,
        ReturnDraftPatch(
          rowVersion: existing.rowVersion,
          reasonCode: state.reason,
          reasonComment: _commentOrNull ?? '',
          items: sent,
          refundKind: state.refundKind,
          clearRefundKind: state.refundKind == null,
        ),
      ),
    );
    if (!ref.mounted) return (outcome: ReturnOutcome.ignored, failure: null);
    switch (r) {
      case Success<ReturnRequest>(:final ReturnRequest value):
        state = _fromRequest(value).copyWith(busy: () => state.busy);
        return (outcome: ReturnOutcome.saved, failure: null);
      case FailureResult<ReturnRequest>(:final Failure failure):
        return _onWriteFailure(failure, sent);
    }
  }

  Future<ReturnActionResult> _create() async {
    final Order? order = state.order;
    final ReturnReason? reason = state.reason;
    final String orderId = order?.id ?? args.orderId ?? '';
    if (reason == null || orderId.isEmpty) return (outcome: ReturnOutcome.invalid, failure: null);
    final String key = _createKey ??= _newKey();
    final List<ReturnItemInput> sent = _items();
    final Result<ReturnRequest> r = await _guard(
      () => _repo.create(
        ReturnDraftInput(
          orderId: orderId,
          reasonCode: reason,
          reasonComment: _commentOrNull,
          items: sent,
          refundKind: state.refundKind,
        ),
        idempotencyKey: key,
      ),
    );
    if (!ref.mounted) return (outcome: ReturnOutcome.ignored, failure: null);
    switch (r) {
      case Success<ReturnRequest>(:final ReturnRequest value):
        _createKey = null;
        state = _fromRequest(value).copyWith(busy: () => state.busy, pending: () => null);
        return (outcome: ReturnOutcome.created, failure: null);
      case FailureResult<ReturnRequest>(:final Failure failure):
        if (_isUnknownOutcome(failure)) {
          state = state.copyWith(pending: () => ReturnPendingOp.create);
          return (outcome: ReturnOutcome.unknown, failure: failure);
        }
        if (!_isOffline(failure)) _createKey = null;
        if (_isReturnState(failure, 'order_not_shipped')) {
          state = state.copyWith(phase: ReturnPhase.notReturnable);
          return (outcome: ReturnOutcome.notReturnable, failure: failure);
        }
        return _onWriteFailure(failure, sent);
    }
  }

  /// Общая обработка отказа `PATCH`/`submit`: конфликт версии, не черновик, превышение количества.
  Future<ReturnActionResult> _onWriteFailure(Failure failure, List<ReturnItemInput> sent) async {
    if (failure is ConflictFailure && failure.kind == ConflictKind.versionConflict) {
      await reloadRequest();
      return (outcome: ReturnOutcome.versionConflict, failure: failure);
    }
    if (failure is ConflictFailure && failure.kind == ConflictKind.orderStateInvalid) {
      await reloadRequest();
      return (outcome: ReturnOutcome.stateChanged, failure: failure);
    }
    if (_isQtyExceeded(failure)) {
      _markQtyErrors(failure as ServerFailure, sent);
      return (outcome: ReturnOutcome.qtyExceeded, failure: failure);
    }
    if (failure is PermissionFailure) return (outcome: ReturnOutcome.forbidden, failure: failure);
    return (outcome: ReturnOutcome.failed, failure: failure);
  }

  static final RegExp _itemIndex = RegExp(r'items\[(\d+)\]');

  /// Подсветка строк по `errors[].field` (`items[i].quantity`) или `orderLineNo` ответа; без указания — все.
  void _markQtyErrors(ServerFailure f, List<ReturnItemInput> sent) {
    final Set<int> bad = <int>{};
    for (final FieldError e in f.errors) {
      final RegExpMatch? m = _itemIndex.firstMatch(e.field);
      final int? i = m == null ? null : int.tryParse(m.group(1)!);
      if (i != null && i < sent.length) bad.add(sent[i].orderLineNo);
    }
    final Object? no = f.details['orderLineNo'];
    if (no is int) bad.add(no);
    if (bad.isEmpty) bad.addAll(sent.map((ReturnItemInput i) => i.orderLineNo));
    state = state.copyWith(
      lines: <ReturnLine>[for (final ReturnLine l in state.lines) l.copyWith(serverError: bad.contains(l.orderLineNo))],
    );
  }

  // --- Отправка -------------------------------------------------------------------------------------------------

  /// «Отправить заявку»: сохранить изменения → step-up → `POST /returns/{id}/submit` (RET-006, RET-009).
  Future<ReturnActionResult> submit() async {
    if (state.busy != null || state.phase != ReturnPhase.editing) {
      return (outcome: ReturnOutcome.ignored, failure: null);
    }
    if (!_validate()) return (outcome: ReturnOutcome.invalid, failure: null);
    state = state.copyWith(busy: () => ReturnBusy.submitting, thresholdBlocked: false);
    final ReturnActionResult r = await _submitFlow();
    if (ref.mounted) state = state.copyWith(busy: () => null);
    return r;
  }

  Future<ReturnActionResult> _submitFlow() async {
    if (state.request == null || state.dirty) {
      final ReturnActionResult saved = await _save();
      if (saved.outcome != ReturnOutcome.saved && saved.outcome != ReturnOutcome.created) return saved;
    }
    final ReturnRequest? draft = state.request;
    if (draft == null || !ref.mounted) return (outcome: ReturnOutcome.ignored, failure: null);
    final ReturnsStepUpResult stepUp = await ref.read(returnsStepUpProvider)(ReturnsStepUpOperations.submit);
    if (!ref.mounted) return (outcome: ReturnOutcome.ignored, failure: null);
    if (stepUp.cancelled) return (outcome: ReturnOutcome.stepUpCancelled, failure: null);
    return _sendSubmit(draft, stepUpToken: stepUp.token);
  }

  Future<ReturnActionResult> _sendSubmit(ReturnRequest draft, {String? stepUpToken}) async {
    final String key = _submitKey ??= _newKey();
    final Result<ReturnRequest> r = await _guard(
      () => _repo.submit(draft.id, rowVersion: draft.rowVersion, idempotencyKey: key, stepUpToken: stepUpToken),
    );
    if (!ref.mounted) return (outcome: ReturnOutcome.ignored, failure: null);
    switch (r) {
      case Success<ReturnRequest>(:final ReturnRequest value):
        _submitKey = null;
        if (value.isDraft) {
          // Сервер оставил черновик (порог согласования, 08 §3.12 `approvalReason`).
          state = _fromRequest(value).copyWith(
            busy: () => state.busy,
            pending: () => null,
            thresholdBlocked: value.approvalReason == ReturnApprovalReason.returnThresholdExceeded,
          );
          return (
            outcome: value.approvalReason == ReturnApprovalReason.returnThresholdExceeded
                ? ReturnOutcome.thresholdBlocked
                : ReturnOutcome.stateChanged,
            failure: null,
          );
        }
        state = _fromRequest(value).copyWith(busy: () => state.busy, pending: () => null);
        return (outcome: ReturnOutcome.submitted, failure: null);
      case FailureResult<ReturnRequest>(:final Failure failure):
        if (_isUnknownOutcome(failure)) {
          state = state.copyWith(pending: () => ReturnPendingOp.submit);
          return (outcome: ReturnOutcome.unknown, failure: failure);
        }
        if (!_isOffline(failure)) _submitKey = null;
        state = state.copyWith(pending: () => null);
        if (failure is PermissionFailure &&
            failure.serverReason == ReturnApprovalReason.returnThresholdExceeded.value) {
          state = state.copyWith(thresholdBlocked: true);
          return (outcome: ReturnOutcome.thresholdBlocked, failure: failure);
        }
        if (failure is AuthFailure && failure.reason == AuthReason.stepUpRequired) {
          // StepUpDialog AuthInterceptor-а закрыт «Отменой» — заявка осталась черновиком (AC-UI-39-004).
          return (outcome: ReturnOutcome.stepUpCancelled, failure: failure);
        }
        return _onWriteFailure(failure, _items());
    }
  }

  /// «Проверить» после неизвестного исхода — тот же `Idempotency-Key` (AC-UI-39-005).
  Future<ReturnActionResult> retryPending() async {
    final ReturnPendingOp? op = state.pending;
    if (op == null || state.busy != null) return (outcome: ReturnOutcome.ignored, failure: null);
    state = state.copyWith(busy: () => op == ReturnPendingOp.create ? ReturnBusy.saving : ReturnBusy.submitting);
    final ReturnActionResult r;
    if (op == ReturnPendingOp.create) {
      r = await _create();
    } else {
      final ReturnRequest? draft = state.request;
      r = draft == null ? (outcome: ReturnOutcome.ignored, failure: null) : await _sendSubmit(draft, stepUpToken: null);
    }
    if (ref.mounted) state = state.copyWith(busy: () => null);
    return r;
  }

  // --- Удаление черновика ---------------------------------------------------------------------------------------

  /// «Удалить черновик» (UI-39-014): `DELETE /returns/{id}?rowVersion=`; `404` — уже удалён.
  Future<ReturnActionResult> deleteDraft() async {
    final ReturnRequest? r0 = state.request;
    if (state.busy != null || r0 == null || !r0.isDraft) return (outcome: ReturnOutcome.ignored, failure: null);
    state = state.copyWith(busy: () => ReturnBusy.deleting);
    final Result<void> r = await _guard(() => _repo.delete(r0.id, rowVersion: r0.rowVersion));
    if (!ref.mounted) return (outcome: ReturnOutcome.ignored, failure: null);
    state = state.copyWith(busy: () => null);
    switch (r) {
      case Success<void>():
        return (outcome: ReturnOutcome.deleted, failure: null);
      case FailureResult<void>(:final Failure failure):
        if (_isNotFound(failure)) return (outcome: ReturnOutcome.deleted, failure: null);
        return _onWriteFailure(failure, const <ReturnItemInput>[]);
    }
  }

  // --- Согласование / отклонение --------------------------------------------------------------------------------

  /// «Согласовать заявку» (UI-39-015): step-up `return.approve` → `POST /returns/{id}/accept`.
  Future<ReturnActionResult> accept() async {
    final ReturnRequest? r0 = state.request;
    if (state.busy != null || r0 == null || r0.status != ReturnRequestStatus.submitted) {
      return (outcome: ReturnOutcome.ignored, failure: null);
    }
    state = state.copyWith(busy: () => ReturnBusy.accepting);
    final ReturnActionResult res = await _decide(
      run: (String key, String? token) =>
          _repo.accept(r0.id, rowVersion: r0.rowVersion, idempotencyKey: key, stepUpToken: token),
      key: () => _acceptKey ??= _newKey(),
      clearKey: () => _acceptKey = null,
      ok: ReturnOutcome.accepted,
    );
    if (ref.mounted) state = state.copyWith(busy: () => null);
    return res;
  }

  /// «Отклонить заявку» (UI-39-016): причина 5…500 → step-up → `POST /returns/{id}/reject`.
  Future<ReturnActionResult> reject(String reason) async {
    final ReturnRequest? r0 = state.request;
    final String text = reason.trim();
    if (state.busy != null ||
        r0 == null ||
        (r0.status != ReturnRequestStatus.submitted && r0.status != ReturnRequestStatus.accepted)) {
      return (outcome: ReturnOutcome.ignored, failure: null);
    }
    if (text.length < ReturnFormState.rejectReasonMin) return (outcome: ReturnOutcome.invalid, failure: null);
    if (_rejectKeyReason != text) {
      _rejectKey = null;
      _rejectKeyReason = text;
    }
    state = state.copyWith(busy: () => ReturnBusy.rejecting);
    final ReturnActionResult res = await _decide(
      run: (String key, String? token) =>
          _repo.reject(r0.id, reason: text, rowVersion: r0.rowVersion, idempotencyKey: key, stepUpToken: token),
      key: () => _rejectKey ??= _newKey(),
      clearKey: () => _rejectKey = null,
      ok: ReturnOutcome.rejected,
    );
    if (ref.mounted) {
      state = state.copyWith(busy: () => null, rejectReason: res.outcome == ReturnOutcome.rejected ? () => text : null);
    }
    return res;
  }

  Future<ReturnActionResult> _decide({
    required Future<Result<ReturnRequest>> Function(String key, String? token) run,
    required String Function() key,
    required void Function() clearKey,
    required ReturnOutcome ok,
  }) async {
    final ReturnsStepUpResult stepUp = await ref.read(returnsStepUpProvider)(ReturnsStepUpOperations.approve);
    if (!ref.mounted) return (outcome: ReturnOutcome.ignored, failure: null);
    if (stepUp.cancelled) return (outcome: ReturnOutcome.stepUpCancelled, failure: null);
    final String k = key();
    final Result<ReturnRequest> r = await _guard(() => run(k, stepUp.token));
    if (!ref.mounted) return (outcome: ReturnOutcome.ignored, failure: null);
    switch (r) {
      case Success<ReturnRequest>(:final ReturnRequest value):
        clearKey();
        state = _fromRequest(value).copyWith(busy: () => state.busy);
        return (outcome: ok, failure: null);
      case FailureResult<ReturnRequest>(:final Failure failure):
        if (_isUnknownOutcome(failure) || _isOffline(failure)) return (outcome: ReturnOutcome.failed, failure: failure);
        clearKey();
        if (_isReturnState(failure, 'already_in_onec')) {
          state = state.copyWith(alreadyInOnec: true);
          return (outcome: ReturnOutcome.alreadyInOnec, failure: failure);
        }
        if (failure is AuthFailure && failure.reason == AuthReason.stepUpRequired) {
          return (outcome: ReturnOutcome.stepUpCancelled, failure: failure);
        }
        return _onWriteFailure(failure, const <ReturnItemInput>[]);
    }
  }
}
