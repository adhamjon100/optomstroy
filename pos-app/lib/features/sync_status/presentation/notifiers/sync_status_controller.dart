// Состояние SCR-43 «Статус синхронизации» (02 ч. E, SCR-43.4, SCR-43.7; 08 §4.17; ядро R0 §17.2, §22.8).
//
// - `GET /sync/status` — при открытии, по «Обновить»/F5 и опросом экрана (30 с; 5 с, пока идёт прогон);
//   последний успешный ответ сохраняется (ошибка → баннер «данные от HH:MM» поверх последнего статуса).
// - Ручной запуск: правило [SyncRunPolicy]; для `sync.run.full` StepUpDialog открывается ДО запроса — отмена
//   не отправляет `POST /sync/runs` (AC-UI-43-017); один `Idempotency-Key` на действие пользователя.
//   Кнопка остаётся «Обновляем…» до завершения прогона (`GET /sync/runs/{id}`), затем — снекбар итога.
// - `409 SYNC_ALREADY_RUNNING` → снекбар; `429` → `sync_rate_limited`; `422 inbound_mode` (вариант C-2) →
//   ручной запуск неактивен до конца сеанса; `FORBIDDEN` → снекбар «Недостаточно прав».
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/sync/sync_run_policy.dart';
import 'package:uuid/uuid.dart';

/// Событие для снекбара (одноразовое: экран показывает событие с новым [id]).
sealed class SyncStatusEvent {
  const SyncStatusEvent(this.id);

  final int id;
}

final class SyncRunStartedEvent extends SyncStatusEvent {
  const SyncRunStartedEvent(super.id, this.entity);

  final SyncEntity entity;
}

final class SyncRunFinishedEvent extends SyncStatusEvent {
  const SyncRunFinishedEvent(super.id, this.run);

  final SyncRunInfo run;
}

final class SyncRunRejectedEvent extends SyncStatusEvent {
  const SyncRunRejectedEvent(super.id, this.reason, {this.retryAfter, this.runId});

  final SyncRunRejection reason;
  final Duration? retryAfter;

  /// `SYNC_ALREADY_RUNNING`: текущий прогон.
  final String? runId;
}

/// Почему запуск не состоялся.
enum SyncRunRejection { alreadyRunning, rateLimited, inboundMode, forbidden, network, other }

/// Итог нажатия «Запустить».
enum SyncStartResult { started, cancelled, rejected, ignored }

final class SyncStatusViewState {
  const SyncStatusViewState({
    this.status,
    this.failure,
    this.loading = false,
    this.busy = const <SyncEntity>{},
    this.pendingRuns = const <SyncEntity, String>{},
    this.runs,
    this.runsLoading = false,
    this.runsFailure,
    this.event,
  });

  /// Последний успешный `GET /sync/status`.
  final SyncServerStatus? status;

  /// Ошибка последнего запроса статуса.
  final Failure? failure;
  final bool loading;

  /// Сущности с нажатой кнопкой запуска (до завершения прогона).
  final Set<SyncEntity> busy;

  /// Запущенные с этого экрана прогоны (ожидание итога).
  final Map<SyncEntity, String> pendingRuns;
  final SyncRunsPage? runs;
  final bool runsLoading;
  final Failure? runsFailure;
  final SyncStatusEvent? event;

  /// Идёт хотя бы один прогон (опрос 5 с).
  bool get anyRunning => pendingRuns.isNotEmpty || (status?.entities.any((e) => e.running) ?? false);

  SyncStatusViewState copyWith({
    SyncServerStatus? status,
    Failure? failure,
    bool clearFailure = false,
    bool? loading,
    Set<SyncEntity>? busy,
    Map<SyncEntity, String>? pendingRuns,
    SyncRunsPage? runs,
    bool? runsLoading,
    Failure? runsFailure,
    bool clearRunsFailure = false,
    SyncStatusEvent? event,
  }) => SyncStatusViewState(
    status: status ?? this.status,
    failure: clearFailure ? null : (failure ?? this.failure),
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    pendingRuns: pendingRuns ?? this.pendingRuns,
    runs: runs ?? this.runs,
    runsLoading: runsLoading ?? this.runsLoading,
    runsFailure: clearRunsFailure ? null : (runsFailure ?? this.runsFailure),
    event: event ?? this.event,
  );
}

/// Генератор `Idempotency-Key` (UUID v4); в тестах — детерминированный.
final syncIdempotencyKeyProvider = Provider<String Function()>((ref) => const Uuid().v4);

/// Интервалы опроса `GET /sync/status` (обычный, во время прогона); `null` — без опроса (тесты).
final syncStatusPollIntervalsProvider = Provider<(Duration, Duration)?>(
  (ref) => (const Duration(seconds: 30), const Duration(seconds: 5)),
);

final syncStatusControllerProvider = NotifierProvider.autoDispose<SyncStatusController, SyncStatusViewState>(
  SyncStatusController.new,
);

final class SyncStatusController extends Notifier<SyncStatusViewState> {
  int _eventId = 0;
  bool _disposed = false;

  @override
  SyncStatusViewState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const SyncStatusViewState();
  }

  void _set(SyncStatusViewState s) {
    if (!_disposed) state = s;
  }

  int _nextEventId() => ++_eventId;

  /// `GET /sync/status` (+ итоги ожидаемых прогонов).
  Future<void> refresh() async {
    final port = ref.read(syncStatusPortProvider);
    if (port == null) {
      _set(state.copyWith(failure: const UnknownFailure(cause: 'SyncStatusPort'), loading: false));
      return;
    }
    _set(state.copyWith(loading: true));
    final r = await port.status();
    if (_disposed) return;
    switch (r) {
      case Success(:final value):
        _set(state.copyWith(status: value, loading: false, clearFailure: true));
      case FailureResult(:final failure):
        _set(state.copyWith(failure: failure, loading: false));
    }
    await _checkPendingRuns();
  }

  Future<void> _checkPendingRuns() async {
    final port = ref.read(syncStatusPortProvider);
    if (port == null || state.pendingRuns.isEmpty) return;
    for (final entry in Map<SyncEntity, String>.of(state.pendingRuns).entries) {
      final r = await port.run(entry.value);
      if (_disposed) return;
      final run = r.valueOrNull;
      if (run == null || !run.finished) continue;
      final pending = Map<SyncEntity, String>.of(state.pendingRuns)..remove(entry.key);
      _set(
        state.copyWith(
          pendingRuns: pending,
          busy: {...state.busy}..remove(entry.key),
          event: SyncRunFinishedEvent(_nextEventId(), run),
        ),
      );
    }
  }

  /// `GET /sync/runs` (вкладка «Прогоны»; `sync.runs.read`).
  Future<void> loadRuns({SyncEntity? entity}) async {
    final port = ref.read(syncStatusPortProvider);
    if (port == null) return;
    _set(state.copyWith(runsLoading: true, clearRunsFailure: true));
    final r = await port.runs(entity: entity);
    if (_disposed) return;
    switch (r) {
      case Success(:final value):
        _set(state.copyWith(runs: value, runsLoading: false));
      case FailureResult(:final failure):
        _set(state.copyWith(runsFailure: failure, runsLoading: false));
    }
  }

  /// Ручной запуск по правилу R0 §17.2.
  Future<SyncStartResult> start(SyncEntity entity, SyncMode mode) async {
    final role = ref.read(syncViewerRoleProvider);
    final port = ref.read(syncStatusPortProvider);
    if (port == null ||
        ref.read(manualSyncBlockedProvider) ||
        state.busy.contains(entity) ||
        !SyncRunPolicy.canStart(role, entity, mode)) {
      return SyncStartResult.ignored;
    }
    _set(state.copyWith(busy: {...state.busy, entity}));
    String? token;
    if (SyncRunPolicy.requiresStepUp(entity, mode)) {
      final outcome = await ref.read(syncStepUpProvider)(SyncRunPolicy.stepUpOperation);
      if (_disposed) return SyncStartResult.cancelled;
      if (outcome.cancelled) {
        _set(state.copyWith(busy: {...state.busy}..remove(entity)));
        return SyncStartResult.cancelled;
      }
      token = outcome.token;
    }
    final key = ref.read(syncIdempotencyKeyProvider)();
    final r = await port.startRun(entity: entity, mode: mode, idempotencyKey: key, stepUpToken: token);
    if (_disposed) return r.isSuccess ? SyncStartResult.started : SyncStartResult.rejected;
    switch (r) {
      case Success(:final value):
        _set(
          state.copyWith(
            pendingRuns: {...state.pendingRuns, entity: value.id},
            event: SyncRunStartedEvent(_nextEventId(), entity),
          ),
        );
        unawaited(refresh());
        return SyncStartResult.started;
      case FailureResult(:final failure):
        final (reason, retryAfter, runId) = _rejection(failure);
        if (reason == SyncRunRejection.inboundMode) ref.read(manualSyncBlockedProvider.notifier).block();
        _set(
          state.copyWith(
            busy: {...state.busy}..remove(entity),
            event: SyncRunRejectedEvent(_nextEventId(), reason, retryAfter: retryAfter, runId: runId),
          ),
        );
        return SyncStartResult.rejected;
    }
  }

  static (SyncRunRejection, Duration?, String?) _rejection(Failure f) => switch (f) {
    ConflictFailure(:final kind, :final details) when kind == ConflictKind.syncAlreadyRunning => (
      SyncRunRejection.alreadyRunning,
      null,
      details['runId'] is String ? details['runId']! as String : null,
    ),
    ServerFailure(:final code, :final retryAfter) when code == 'RATE_LIMITED' => (
      SyncRunRejection.rateLimited,
      retryAfter,
      null,
    ),
    ValidationFailure(:final errors) when errors.any((e) => e.rule == 'inbound_mode') => (
      SyncRunRejection.inboundMode,
      null,
      null,
    ),
    ServerFailure(:final reason) when reason == 'inbound_mode' => (SyncRunRejection.inboundMode, null, null),
    PermissionFailure() || AuthFailure() => (SyncRunRejection.forbidden, null, null),
    NetworkFailure() => (SyncRunRejection.network, null, null),
    _ => (SyncRunRejection.other, null, null),
  };
}
