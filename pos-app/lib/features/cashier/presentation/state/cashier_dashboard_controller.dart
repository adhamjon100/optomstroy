// Состояние SCR-30 «Дашборд кассира» (02 SCR-30.4, SCR-30.7; 08 §4.10.1 `GET /pos/dashboard`).
//
// * Загрузка: `GET /pos/dashboard` (+ параллельно `GET /sync/status` для баннера и карточки синхронизации,
//   `GET /discounts/rules` для зоны Z7). Ошибки вспомогательных запросов дашборд не ломают (баннер — по
//   `sync.overall` без деталей сущности).
// * Одновременно — не более одного запроса дашборда: ручное обновление и polling объединяются (AC-UI-30-010);
//   ответ после ухода с экрана отбрасывается (провайдер autoDispose).
// * Polling — каждые 60 с при активном экране, приостанавливается в фоне и при idle-блокировке (экран).
// * Данные — только память провайдера (ядро §18.2 п. 1, CASH-015): в drift ничего не пишется; без сети и без данных
//   в памяти — OfflineNoData; при ошибке обновления остаются данные с меткой времени (ReadyStale).
// * Избранное: удаление — оптимистично (карточка скрыта), при ошибке — возврат; «Отменить» — `PUT` обратно.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_ports.dart';
import 'package:optomstroy/core/sync/sync_providers.dart' show syncStatusPortProvider;
import 'package:optomstroy/features/cashier/cashier_providers.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';

/// Фаза экрана (02 SCR-30.7).
enum CashierDashboardPhase { loading, ready, error, offlineNoData, forbidden }

/// Состояние дашборда.
@immutable
final class CashierDashboardState {
  /// Создаёт состояние.
  const CashierDashboardState({
    this.phase = CashierDashboardPhase.loading,
    this.dashboard,
    this.fetchedAt,
    this.refreshing = false,
    this.refreshFailed = false,
    this.offline = false,
    this.failure,
    this.sync,
    this.rules,
    this.rulesFailed = false,
    this.hiddenFavorites = const <String>{},
  });

  final CashierDashboardPhase phase;
  final PosDashboard? dashboard;

  /// Момент ответа (метка «обновлено HH:MM»).
  final DateTime? fetchedAt;

  /// Идёт обновление при показанных данных.
  final bool refreshing;

  /// Последнее обновление не удалось — ReadyStale («Не удалось обновить, данные от HH:MM»).
  final bool refreshFailed;

  /// Причина — нет сети (кассовые кнопки disabled, P-OFFLINE).
  final bool offline;

  /// Ошибка первой загрузки (ErrorState с кодом обращения).
  final Failure? failure;

  /// `GET /sync/status` (краткий ответ); `null` — не загружен или ошибка.
  final SyncServerStatus? sync;

  /// `GET /discounts/rules`.
  final DiscountRulesInfo? rules;
  final bool rulesFailed;

  /// Избранные, скрытые оптимистично (удаление в процессе / ждёт «Отменить»).
  final Set<String> hiddenFavorites;

  /// Избранные к показу.
  List<Customer> get favorites => <Customer>[
    for (final Customer c in dashboard?.favoriteCustomers ?? const <Customer>[])
      if (!hiddenFavorites.contains(c.id)) c,
  ];

  CashierDashboardState copyWith({
    CashierDashboardPhase? phase,
    PosDashboard? dashboard,
    DateTime? fetchedAt,
    bool? refreshing,
    bool? refreshFailed,
    bool? offline,
    Failure? Function()? failure,
    SyncServerStatus? Function()? sync,
    DiscountRulesInfo? rules,
    bool? rulesFailed,
    Set<String>? hiddenFavorites,
  }) => CashierDashboardState(
    phase: phase ?? this.phase,
    dashboard: dashboard ?? this.dashboard,
    fetchedAt: fetchedAt ?? this.fetchedAt,
    refreshing: refreshing ?? this.refreshing,
    refreshFailed: refreshFailed ?? this.refreshFailed,
    offline: offline ?? this.offline,
    failure: failure == null ? this.failure : failure(),
    sync: sync == null ? this.sync : sync(),
    rules: rules ?? this.rules,
    rulesFailed: rulesFailed ?? this.rulesFailed,
    hiddenFavorites: hiddenFavorites ?? this.hiddenFavorites,
  );
}

/// Дашборд кассира (память экрана).
final cashierDashboardControllerProvider =
    NotifierProvider.autoDispose<CashierDashboardController, CashierDashboardState>(CashierDashboardController.new);

/// Логика SCR-30.
final class CashierDashboardController extends Notifier<CashierDashboardState> {
  Future<void>? _inFlight;
  bool _disposed = false;

  @override
  CashierDashboardState build() {
    ref.onDispose(() => _disposed = true);
    return const CashierDashboardState();
  }

  void _set(CashierDashboardState s) {
    if (!_disposed) state = s;
  }

  /// Загрузить / обновить (повторный вызов во время запроса присоединяется к нему).
  Future<void> load() => _inFlight ??= _load().whenComplete(() => _inFlight = null);

  Future<void> _load() async {
    final bool hasData = state.dashboard != null;
    if (hasData) _set(state.copyWith(refreshing: true));
    final Future<Result<PosDashboard>> dashboardF = ref.read(cashierRepositoryProvider).dashboard();
    final SyncStatusPort? syncPort = ref.read(syncStatusPortProvider);
    final Future<Result<SyncServerStatus>>? syncF = syncPort?.status();
    final Future<Result<DiscountRulesInfo>> rulesF = _rules();
    final Result<PosDashboard> r = await dashboardF;
    if (_disposed) return;
    final DateTime now = ref.read(clockProvider).nowUtc();
    switch (r) {
      case Success<PosDashboard>(:final PosDashboard value):
        _set(
          state.copyWith(
            phase: CashierDashboardPhase.ready,
            dashboard: value,
            fetchedAt: now,
            refreshing: false,
            refreshFailed: false,
            offline: false,
            failure: () => null,
            // Удалённые на сервере больше не придут; оптимистично скрытые до ответа остаются скрытыми.
            hiddenFavorites: state.hiddenFavorites,
          ),
        );
      case FailureResult<PosDashboard>(:final Failure failure):
        final bool network = failure is NetworkFailure;
        if (failure is PermissionFailure) {
          _set(state.copyWith(phase: CashierDashboardPhase.forbidden, refreshing: false, failure: () => failure));
        } else if (hasData) {
          _set(state.copyWith(refreshing: false, refreshFailed: true, offline: network));
        } else {
          _set(
            state.copyWith(
              phase: network ? CashierDashboardPhase.offlineNoData : CashierDashboardPhase.error,
              refreshing: false,
              offline: network,
              failure: () => failure,
            ),
          );
        }
    }
    if (syncF != null) {
      final Result<SyncServerStatus> s = await syncF;
      if (_disposed) return;
      if (s case Success<SyncServerStatus>(:final SyncServerStatus value)) {
        _set(state.copyWith(sync: () => value));
      }
    }
    final Result<DiscountRulesInfo> rules = await rulesF;
    if (_disposed) return;
    switch (rules) {
      case Success<DiscountRulesInfo>(:final DiscountRulesInfo value):
        _set(state.copyWith(rules: value, rulesFailed: false));
      case FailureResult<DiscountRulesInfo>():
        _set(state.copyWith(rulesFailed: state.rules == null));
    }
  }

  Future<Result<DiscountRulesInfo>> _rules() async {
    try {
      return await ref.read(customerDirectoryRepositoryProvider).discountRules();
    } on Object catch (e) {
      // Справочник не подключён (тесты корня без customersBindings) — зона Z7 показывает «Правил нет».
      return FailureResult<DiscountRulesInfo>(UnknownFailure(cause: e));
    }
  }

  /// Убрать клиента из избранного (UI-30-005): карточка скрывается сразу; `null` — успех, иначе ошибка (карточка
  /// возвращается).
  Future<Failure?> removeFavorite(String customerId) async {
    _set(state.copyWith(hiddenFavorites: <String>{...state.hiddenFavorites, customerId}));
    final Result<void> r = await ref.read(favoriteCustomersRepositoryProvider).remove(customerId);
    if (_disposed) return null;
    if (r case FailureResult<void>(:final Failure failure)) {
      _set(state.copyWith(hiddenFavorites: <String>{...state.hiddenFavorites}..remove(customerId)));
      return failure;
    }
    return null;
  }

  /// «Отменить» удаление (снекбар 8 с): вернуть клиента в избранное.
  Future<Failure?> restoreFavorite(String customerId) async {
    final Result<void> r = await ref.read(favoriteCustomersRepositoryProvider).add(customerId);
    if (_disposed) return null;
    if (r case FailureResult<void>(:final Failure failure)) return failure;
    _set(state.copyWith(hiddenFavorites: <String>{...state.hiddenFavorites}..remove(customerId)));
    return null;
  }
}
