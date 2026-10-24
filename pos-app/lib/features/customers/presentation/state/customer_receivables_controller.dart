// Состояние SCR-34 «Долги и взаиморасчёты» (02 SCR-34.4, SCR-34.7; 08 §4.11.7–§4.11.8; DEBT-001…012, D-24, SEC-032).
//
// * Открытие — `GET /customers/{id}/receivables` (сводка, без step-up; аудит summary на сервере). Если в памяти есть
//   действующий `stepUpToken` области `customer.receivables.read.detail` — сразу второй запрос `include=documents` с
//   токеном, заглушка не показывается (AC-UI-34-003).
// * «Показать детализацию» — `include=documents` без токена → `403 STEP_UP_REQUIRED` → StepUpDialog (AuthInterceptor,
//   P-STEPUP) → повтор с токеном. Отмена диалога — заглушка «Детализация не открыта», без ошибки (AC-UI-34-011).
//   До подтверждения документы не запрашиваются и не рисуются (AC-UI-34-002).
// * Истечение 15 мин: при открытии и «Обновить» без действующего токена детализация скрывается до нового step-up;
//   уже показанная таблица в момент истечения не скрывается.
// * «Обновить» — `POST …/receivables/refresh` (+ `include=documents` при действующем токене); `429` — кнопка недоступна
//   до `retryAfter`; `isStale=true` — «1С недоступна, показаны данные от HH:MM».
// * Финансовые данные — только память сессии ([CustomerFinanceMemory], CASH-015): офлайн экран показывает то, что уже
//   получено в этой сессии, иначе «Данные о долге недоступны без сети»; в drift ничего не пишется.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/session/session_controller.dart' show stepUpCoordinatorProvider;
import 'package:optomstroy/core/session/step_up_coordinator.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_controller.dart'
    show newCustomerKeyFactoryProvider;
import 'package:optomstroy/features/customers/presentation/state/customer_card_controller.dart';

/// Фаза сводки.
enum ReceivablesPhase { loading, ready, error, offline, forbidden, notFound }

/// Фаза детализации (Z5).
enum ReceivablesDetailPhase {
  /// Заглушка с замком (нет токена).
  locked,

  /// Идёт запрос (в т. ч. ожидание StepUpDialog).
  loading,

  /// Таблица.
  ready,

  /// Отмена диалога — «Детализация не открыта».
  cancelled,

  /// Ошибка запроса детализации (заглушка + `ErrorState.inline`).
  error,
}

/// Фильтр документов (UI-34-004; на клиенте по загруженному снимку).
enum ReceivablesDocFilter { shipments, payments, returns, discounts, overdue }

/// Состояние SCR-34.
final class CustomerReceivablesState {
  const CustomerReceivablesState({
    this.phase = ReceivablesPhase.loading,
    this.receivable,
    this.failure,
    this.detail = ReceivablesDetailPhase.locked,
    this.detailFailure,
    this.detailUntil,
    this.fromMemory = false,
    this.refreshing = false,
    this.rateLimitedUntil,
    this.filters = const <ReceivablesDocFilter>{},
  });

  final ReceivablesPhase phase;
  final Receivable? receivable;
  final Failure? failure;
  final ReceivablesDetailPhase detail;
  final Failure? detailFailure;

  /// «Детализация открыта до HH:MM» (оценка, см. [DetailWindowMemory]); `null` — неизвестно.
  final DateTime? detailUntil;

  /// Показан снимок из памяти сессии (офлайн).
  final bool fromMemory;
  final bool refreshing;
  final DateTime? rateLimitedUntil;

  /// Выбранные чипы; пусто — «Все».
  final Set<ReceivablesDocFilter> filters;

  /// Документы снимка (после step-up).
  List<ReceivableDocument>? get documents => detail == ReceivablesDetailPhase.ready ? receivable?.documents : null;

  CustomerReceivablesState copyWith({
    ReceivablesPhase? phase,
    Receivable? receivable,
    Failure? Function()? failure,
    ReceivablesDetailPhase? detail,
    Failure? Function()? detailFailure,
    DateTime? Function()? detailUntil,
    bool? fromMemory,
    bool? refreshing,
    DateTime? Function()? rateLimitedUntil,
    Set<ReceivablesDocFilter>? filters,
  }) => CustomerReceivablesState(
    phase: phase ?? this.phase,
    receivable: receivable ?? this.receivable,
    failure: failure == null ? this.failure : failure(),
    detail: detail ?? this.detail,
    detailFailure: detailFailure == null ? this.detailFailure : detailFailure(),
    detailUntil: detailUntil == null ? this.detailUntil : detailUntil(),
    fromMemory: fromMemory ?? this.fromMemory,
    refreshing: refreshing ?? this.refreshing,
    rateLimitedUntil: rateLimitedUntil == null ? this.rateLimitedUntil : rateLimitedUntil(),
    filters: filters ?? this.filters,
  );
}

/// Документ попадает под фильтр.
bool receivableDocMatches(ReceivableDocument d, ReceivablesDocFilter f) => switch (f) {
  ReceivablesDocFilter.shipments => d.kind == ReceivableDocumentKind.invoice,
  ReceivablesDocFilter.payments => d.kind == ReceivableDocumentKind.payment,
  ReceivablesDocFilter.returns => d.kind == ReceivableDocumentKind.returnValue,
  ReceivablesDocFilter.discounts =>
    d.kind == ReceivableDocumentKind.discount || d.kind == ReceivableDocumentKind.adjustment,
  ReceivablesDocFilter.overdue => (d.overdueDays ?? 0) > 0,
};

/// `customerReceivablesProvider(customerId)`.
final customerReceivablesProvider = NotifierProvider.autoDispose
    .family<CustomerReceivablesController, CustomerReceivablesState, String>(CustomerReceivablesController.new);

/// Логика SCR-34.
final class CustomerReceivablesController extends Notifier<CustomerReceivablesState> {
  /// Контроллер долга клиента [customerId].
  CustomerReceivablesController(this.customerId);

  final String customerId;
  int _generation = 0;
  Timer? _rateTimer;

  @override
  CustomerReceivablesState build() {
    ref.onDispose(() => _rateTimer?.cancel());
    unawaited(Future<void>.microtask(load));
    return const CustomerReceivablesState();
  }

  StepUpCoordinator get _stepUp => ref.read(stepUpCoordinatorProvider);

  DateTime get _now => ref.read(clockProvider).nowUtc();

  /// Действующий токен области детализации.
  String? get _token => _stepUp.tokenFor(receivablesDetailOperation);

  ReceivablesPhase _phaseOf(Failure f) {
    if (isNotFoundFailure(f)) return ReceivablesPhase.notFound;
    if (f is PermissionFailure) return ReceivablesPhase.forbidden;
    if (isOfflineFailure(f)) return ReceivablesPhase.offline;
    return ReceivablesPhase.error;
  }

  /// Открытие и «Повторить».
  Future<void> load() async {
    final int gen = ++_generation;
    if (!ref.mounted) return;
    if (!ref.read(customersOnlineProvider)) {
      final Receivable? cached = ref.read(customerFinanceMemoryProvider).receivable(customerId);
      state = cached == null
          ? const CustomerReceivablesState(phase: ReceivablesPhase.offline)
          : CustomerReceivablesState(phase: ReceivablesPhase.ready, receivable: cached, fromMemory: true);
      return;
    }
    state = const CustomerReceivablesState();
    final Result<Receivable> r = await _call(() => ref.read(receivablesRepositoryProvider).get(customerId));
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<Receivable>(:final Receivable value):
        state = CustomerReceivablesState(phase: ReceivablesPhase.ready, receivable: value);
        final String? token = _token;
        if (token != null && value.balance != null) await _loadDetail(token: token, gen: gen);
      case FailureResult<Receivable>(:final Failure failure):
        state = CustomerReceivablesState(phase: _phaseOf(failure), failure: failure);
    }
  }

  /// «Показать детализацию» (P-STEPUP). Повторное нажатие во время запроса/диалога — игнор.
  Future<void> showDetail() async {
    if (state.phase != ReceivablesPhase.ready || state.detail == ReceivablesDetailPhase.loading || state.fromMemory) {
      return;
    }
    await _loadDetail(token: _token, gen: _generation);
  }

  Future<void> _loadDetail({required String? token, required int gen}) async {
    state = state.copyWith(detail: ReceivablesDetailPhase.loading, detailFailure: () => null);
    final String? before = token;
    final Result<Receivable> r = await _call(
      () => ref.read(receivablesRepositoryProvider).get(customerId, withDocuments: true, stepUpToken: before),
    );
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<Receivable>(:final Receivable value):
        state = state.copyWith(
          receivable: value,
          detail: ReceivablesDetailPhase.ready,
          detailUntil: () => _detailUntil(before),
        );
      case FailureResult<Receivable>(failure: AuthFailure(reason: AuthReason.stepUpRequired)):
        state = state.copyWith(detail: ReceivablesDetailPhase.cancelled);
      case FailureResult<Receivable>(:final Failure failure):
        state = state.copyWith(detail: ReceivablesDetailPhase.error, detailFailure: () => failure);
    }
  }

  /// Срок детализации: токен, впервые появившийся в кэше во время запроса, получен сейчас — + 15 мин.
  DateTime? _detailUntil(String? before) {
    final String? after = _token;
    if (after == null) return null;
    final DetailWindowMemory window = ref.read(receivablesDetailWindowProvider);
    final DateTime? known = window.untilFor(after);
    if (known != null) return known;
    if (before == after) return null;
    final DateTime until = _now.add(stepUpWindow);
    window.note(after, until);
    return until;
  }

  /// «Обновить» снимок (P-STALE, F5).
  Future<DebtRefreshOutcome> refresh() async {
    final DateTime? until = state.rateLimitedUntil;
    if (state.refreshing || state.phase != ReceivablesPhase.ready || (until != null && _now.isBefore(until))) {
      return const DebtRefreshIgnored();
    }
    if (!ref.read(customersViewerProvider).canRefreshReceivables) return const DebtRefreshIgnored();
    final int gen = ++_generation;
    final String? token = _token;
    final bool withDocs = token != null && state.detail == ReceivablesDetailPhase.ready;
    state = state.copyWith(refreshing: true);
    final Result<Receivable> r = await _call(
      () => ref
          .read(receivablesRepositoryProvider)
          .refresh(
            customerId,
            withDocuments: withDocs,
            idempotencyKey: ref.read(newCustomerKeyFactoryProvider)(),
            stepUpToken: withDocs ? token : null,
          ),
    );
    if (!ref.mounted || gen != _generation) return const DebtRefreshIgnored();
    final DebtRefreshOutcome outcome = debtRefreshOutcomeOf(r, shownAsOf: state.receivable?.asOf);
    switch (r) {
      case Success<Receivable>(:final Receivable value):
        state = state.copyWith(
          refreshing: false,
          receivable: value,
          fromMemory: false,
          // Токен истёк — детализация скрывается до нового step-up.
          detail: withDocs && value.documents != null ? ReceivablesDetailPhase.ready : ReceivablesDetailPhase.locked,
          detailUntil: withDocs ? null : () => null,
        );
      case FailureResult<Receivable>():
        state = state.copyWith(refreshing: false);
    }
    if (outcome is DebtRefreshRateLimited) _limitFor(outcome.seconds);
    return outcome;
  }

  void _limitFor(int seconds) {
    _rateTimer?.cancel();
    state = state.copyWith(rateLimitedUntil: () => _now.add(Duration(seconds: seconds)));
    _rateTimer = Timer(Duration(seconds: seconds), () {
      if (ref.mounted) state = state.copyWith(rateLimitedUntil: () => null);
    });
  }

  /// Чип типов (множественный выбор; `null` — «Все» сбрасывает остальные).
  void toggleFilter(ReceivablesDocFilter? f) {
    if (f == null) {
      state = state.copyWith(filters: const <ReceivablesDocFilter>{});
      return;
    }
    final Set<ReceivablesDocFilter> next = <ReceivablesDocFilter>{...state.filters};
    if (!next.remove(f)) next.add(f);
    state = state.copyWith(filters: next);
  }

  Future<Result<Receivable>> _call(Future<Result<Receivable>> Function() f) async {
    try {
      return await f();
    } on Object catch (e) {
      return FailureResult<Receivable>(UnknownFailure(cause: e));
    }
  }
}
