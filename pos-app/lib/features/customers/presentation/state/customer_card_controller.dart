// Состояние SCR-32 «Карточка клиента» (02 SCR-32.4, SCR-32.7; 08 §4.11.3; CUST-001…007, DEBT-002/009/011).
//
// * Загрузка — `GET /customers/{id}?include=` по роли: суммы, скидки, контакты — роли с правом на суммы; `seller` —
//   только `discounts` (сервер всё равно отфильтрует поля, SEC-031); привязки — `admin`, `owner` (`include=links`).
// * Ответ с суммами пишет аудит `customer.debt_viewed` (summary) на сервере; повторно сводка не перезапрашивается до
//   «Обновить» (кэш провайдера до ухода с экрана).
// * «Обновить долг» (P-STALE) — `POST /customers/{id}/receivables/refresh` (cashier, senior_seller, admin, owner);
//   `429` — кнопка недоступна до `retryAfter`; `isStale=true` в ответе — снекбар «1С недоступна…».
// * Данные — только память провайдера (CASH-015); офлайн при открытии — «Карточка клиента недоступна без сети».
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_controller.dart'
    show newCustomerKeyFactoryProvider;
import 'package:optomstroy/features/customers/presentation/state/debt_snapshot.dart';

/// Фаза карточки.
enum CustomerCardPhase { loading, ready, notFound, forbidden, error, offline }

/// Исход «Обновить долг».
sealed class DebtRefreshOutcome {
  const DebtRefreshOutcome();
}

/// Повтор во время запроса — игнор.
final class DebtRefreshIgnored extends DebtRefreshOutcome {
  const DebtRefreshIgnored();
}

/// Снимок обновлён.
final class DebtRefreshUpdated extends DebtRefreshOutcome {
  const DebtRefreshUpdated();
}

/// 1С недоступна — показаны данные от [asOf] (`isStale=true`).
final class DebtRefreshOnecDown extends DebtRefreshOutcome {
  const DebtRefreshOnecDown(this.asOf);

  final DateTime? asOf;
}

/// `429 RATE_LIMITED` — повтор через [seconds].
final class DebtRefreshRateLimited extends DebtRefreshOutcome {
  const DebtRefreshRateLimited(this.seconds);

  final int seconds;
}

/// Ошибка (данные остаются).
final class DebtRefreshFailed extends DebtRefreshOutcome {
  const DebtRefreshFailed(this.failure);

  final Failure failure;
}

/// Разбор ответа «Обновить» (общий для SCR-32 и SCR-34). [shownAsOf] — время снимка на экране: при
/// `503 ONEC_UNAVAILABLE` (08 §4.11.8: 1С не ответила, снимок не изменён) экран остаётся на нём — «1С недоступна,
/// показаны данные от HH:MM» (02 SCR-34.4, 04 FLOW-025.S2), а не общая ошибка.
DebtRefreshOutcome debtRefreshOutcomeOf(Result<Receivable> r, {DateTime? shownAsOf}) => switch (r) {
  Success<Receivable>(:final Receivable value) =>
    value.isStale ? DebtRefreshOnecDown(value.asOf) : const DebtRefreshUpdated(),
  FailureResult<Receivable>(failure: ServerFailure(code: 'RATE_LIMITED', :final Duration? retryAfter)) =>
    DebtRefreshRateLimited(((retryAfter ?? const Duration(seconds: 30)).inMilliseconds + 999) ~/ 1000),
  FailureResult<Receivable>(failure: OnecUnavailableFailure()) => DebtRefreshOnecDown(shownAsOf),
  FailureResult<Receivable>(:final Failure failure) => DebtRefreshFailed(failure),
};

/// `404` / `NOT_FOUND`.
bool isNotFoundFailure(Failure f) => f is ServerFailure && (f.status == 404 || f.code == 'NOT_FOUND');

/// Нет сети.
bool isOfflineFailure(Failure f) => f is NetworkFailure && f.kind == NetworkFailureKind.offline;

/// Состояние SCR-32.
final class CustomerCardState {
  const CustomerCardState({
    this.phase = CustomerCardPhase.loading,
    this.customer,
    this.failure,
    this.debt,
    this.loadedAt,
    this.refreshing = false,
    this.refreshFailed = false,
    this.debtRefreshing = false,
    this.debtRateLimitedUntil,
  });

  final CustomerCardPhase phase;
  final Customer? customer;
  final Failure? failure;

  /// Снимок долга (сводка карточки или ответ «Обновить»); `null` — сумм нет (роль без права).
  final DebtSnapshot? debt;
  final DateTime? loadedAt;
  final bool refreshing;

  /// «Не удалось обновить» (ReadyStale: данные в памяти + баннер).
  final bool refreshFailed;
  final bool debtRefreshing;
  final DateTime? debtRateLimitedUntil;

  CustomerCardState copyWith({
    CustomerCardPhase? phase,
    Customer? customer,
    Failure? Function()? failure,
    DebtSnapshot? Function()? debt,
    DateTime? loadedAt,
    bool? refreshing,
    bool? refreshFailed,
    bool? debtRefreshing,
    DateTime? Function()? debtRateLimitedUntil,
  }) => CustomerCardState(
    phase: phase ?? this.phase,
    customer: customer ?? this.customer,
    failure: failure == null ? this.failure : failure(),
    debt: debt == null ? this.debt : debt(),
    loadedAt: loadedAt ?? this.loadedAt,
    refreshing: refreshing ?? this.refreshing,
    refreshFailed: refreshFailed ?? this.refreshFailed,
    debtRefreshing: debtRefreshing ?? this.debtRefreshing,
    debtRateLimitedUntil: debtRateLimitedUntil == null ? this.debtRateLimitedUntil : debtRateLimitedUntil(),
  );
}

/// `customerCardProvider(customerId)`.
final customerCardProvider = NotifierProvider.autoDispose.family<CustomerCardController, CustomerCardState, String>(
  CustomerCardController.new,
);

/// Логика SCR-32.
final class CustomerCardController extends Notifier<CustomerCardState> {
  /// Контроллер карточки [customerId].
  CustomerCardController(this.customerId);

  final String customerId;
  int _generation = 0;
  Timer? _rateTimer;

  @override
  CustomerCardState build() {
    ref.onDispose(() => _rateTimer?.cancel());
    unawaited(Future<void>.microtask(load));
    return const CustomerCardState();
  }

  CustomersViewer get _viewer => ref.read(customersViewerProvider);

  /// `include` по роли.
  Set<CustomerInclude> get _includes => <CustomerInclude>{
    CustomerInclude.discounts,
    if (_viewer.seesSums) ...<CustomerInclude>{CustomerInclude.receivable, CustomerInclude.contacts},
    if (_viewer.isAdmin || _viewer.isOwner) CustomerInclude.links,
  };

  Future<Result<Customer>> _get() async {
    try {
      return await ref.read(customerDirectoryRepositoryProvider).card(customerId, include: _includes);
    } on Object catch (e) {
      return FailureResult<Customer>(UnknownFailure(cause: e));
    }
  }

  CustomerCardPhase _phaseOf(Failure f) {
    if (isNotFoundFailure(f)) return CustomerCardPhase.notFound;
    if (f is PermissionFailure) return CustomerCardPhase.forbidden;
    if (isOfflineFailure(f)) return CustomerCardPhase.offline;
    return CustomerCardPhase.error;
  }

  DebtSnapshot? _debtOf(Customer c) =>
      c.receivable == null ? null : DebtSnapshot.fromSummary(c.receivable!, creditAllowed: c.creditAllowed);

  /// Загрузка (первая и «Повторить»).
  Future<void> load() async {
    final int gen = ++_generation;
    if (!ref.mounted) return;
    if (!ref.read(customersOnlineProvider)) {
      state = const CustomerCardState(phase: CustomerCardPhase.offline);
      return;
    }
    state = const CustomerCardState();
    final Result<Customer> r = await _get();
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<Customer>(:final Customer value):
        ref.read(customerNamesProvider).put(value.id, value.title);
        state = CustomerCardState(
          phase: CustomerCardPhase.ready,
          customer: value,
          debt: _debtOf(value),
          loadedAt: ref.read(clockProvider).nowUtc(),
        );
      case FailureResult<Customer>(:final Failure failure):
        state = CustomerCardState(phase: _phaseOf(failure), failure: failure);
    }
  }

  /// «Обновить» карточку (UI-32-010, F5); во время запроса — игнор; ошибка не скрывает данные.
  Future<void> refresh() async {
    if (state.phase != CustomerCardPhase.ready) return load();
    if (state.refreshing) return;
    final int gen = ++_generation;
    state = state.copyWith(refreshing: true, refreshFailed: false);
    final Result<Customer> r = await _get();
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<Customer>(:final Customer value):
        state = state.copyWith(
          customer: value,
          debt: () => _debtOf(value),
          refreshing: false,
          loadedAt: ref.read(clockProvider).nowUtc(),
        );
      case FailureResult<Customer>(:final Failure failure):
        if (isNotFoundFailure(failure)) {
          state = CustomerCardState(phase: CustomerCardPhase.notFound, failure: failure);
        } else {
          state = state.copyWith(refreshing: false, refreshFailed: true, failure: () => failure);
        }
    }
  }

  /// «Обновить» снимок долга (P-STALE).
  Future<DebtRefreshOutcome> refreshDebt() async {
    final DateTime now = ref.read(clockProvider).nowUtc();
    final DateTime? until = state.debtRateLimitedUntil;
    if (state.debtRefreshing || (until != null && now.isBefore(until)) || !_viewer.canRefreshReceivables) {
      return const DebtRefreshIgnored();
    }
    state = state.copyWith(debtRefreshing: true);
    Result<Receivable> r;
    try {
      r = await ref
          .read(receivablesRepositoryProvider)
          .refresh(customerId, idempotencyKey: ref.read(newCustomerKeyFactoryProvider)());
    } on Object catch (e) {
      r = FailureResult<Receivable>(UnknownFailure(cause: e));
    }
    if (!ref.mounted) return const DebtRefreshIgnored();
    final DebtRefreshOutcome outcome = debtRefreshOutcomeOf(r, shownAsOf: state.debt?.asOf);
    switch (r) {
      case Success<Receivable>(:final Receivable value):
        state = state.copyWith(debtRefreshing: false, debt: () => DebtSnapshot.fromReceivable(value));
      case FailureResult<Receivable>():
        state = state.copyWith(debtRefreshing: false);
    }
    if (outcome is DebtRefreshRateLimited) _limitFor(outcome.seconds);
    return outcome;
  }

  void _limitFor(int seconds) {
    _rateTimer?.cancel();
    state = state.copyWith(
      debtRateLimitedUntil: () => ref.read(clockProvider).nowUtc().add(Duration(seconds: seconds)),
    );
    _rateTimer = Timer(Duration(seconds: seconds), () {
      if (ref.mounted) state = state.copyWith(debtRateLimitedUntil: () => null);
    });
  }
}
