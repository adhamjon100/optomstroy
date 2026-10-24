// Состояние SCR-33 «История покупок» (02 SCR-33.4, SCR-33.7; 08 §4.11.4 `GET /customers/{id}/orders`; CUST-005,
// DEBT-001, ядро §19.2 `summary`/`historyFrom`, §19.4 — период ≤ 366 дней). По умолчанию — 90 дней (Q-176/Q-215).
// Смена периода или источника отменяет прежний запрос (ответ отбрасывается); подгрузка — по курсору без дублей.
// Долг по истории не вычисляется. Данные — только память провайдера.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_history.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_card_controller.dart';

/// Пресет периода (UI-33-001).
enum HistoryPreset {
  days30(30),
  days90(90),
  year(365),
  custom(0);

  const HistoryPreset(this.days);

  final int days;
}

/// Параметры экрана (маршрут `?from=&to=&source=`).
@immutable
final class CustomerHistoryArgs {
  const CustomerHistoryArgs(this.customerId, {this.from, this.to, this.source});

  final String customerId;
  final String? from;
  final String? to;
  final String? source;

  @override
  bool operator ==(Object other) =>
      other is CustomerHistoryArgs &&
      other.customerId == customerId &&
      other.from == from &&
      other.to == to &&
      other.source == source;

  @override
  int get hashCode => Object.hash(customerId, from, to, source);
}

/// Фаза.
enum CustomerHistoryPhase { loading, list, empty, error, offline, forbidden, notFound }

/// Состояние SCR-33.
final class CustomerHistoryState {
  const CustomerHistoryState({
    required this.from,
    required this.to,
    this.preset = HistoryPreset.days90,
    this.source = CustomerHistorySource.all,
    this.phase = CustomerHistoryPhase.loading,
    this.entries = const <CustomerHistoryEntry>[],
    this.summary,
    this.historyFrom,
    this.asOf,
    this.cursor,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.failure,
    this.expanded = const <String>{},
  });

  /// Начало периода (UTC, полночь Бишкека).
  final DateTime from;

  /// Конец периода (UTC).
  final DateTime to;
  final HistoryPreset preset;
  final CustomerHistorySource source;
  final CustomerHistoryPhase phase;
  final List<CustomerHistoryEntry> entries;
  final CustomerHistorySummary? summary;
  final DateTime? historyFrom;

  /// Метка данных (`Page.asOf`) — «Документы 1С на HH:MM».
  final DateTime? asOf;
  final String? cursor;
  final bool loadingMore;
  final bool loadMoreFailed;
  final Failure? failure;

  /// Раскрытые строки (ключ — [entryKey]).
  final Set<String> expanded;

  bool get hasMore => cursor != null;

  CustomerHistoryState copyWith({
    DateTime? from,
    DateTime? to,
    HistoryPreset? preset,
    CustomerHistorySource? source,
    CustomerHistoryPhase? phase,
    List<CustomerHistoryEntry>? entries,
    CustomerHistorySummary? Function()? summary,
    DateTime? Function()? historyFrom,
    DateTime? Function()? asOf,
    String? Function()? cursor,
    bool? loadingMore,
    bool? loadMoreFailed,
    Failure? Function()? failure,
    Set<String>? expanded,
  }) => CustomerHistoryState(
    from: from ?? this.from,
    to: to ?? this.to,
    preset: preset ?? this.preset,
    source: source ?? this.source,
    phase: phase ?? this.phase,
    entries: entries ?? this.entries,
    summary: summary == null ? this.summary : summary(),
    historyFrom: historyFrom == null ? this.historyFrom : historyFrom(),
    asOf: asOf == null ? this.asOf : asOf(),
    cursor: cursor == null ? this.cursor : cursor(),
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
    failure: failure == null ? this.failure : failure(),
    expanded: expanded ?? this.expanded,
  );
}

/// Ключ строки истории (id заказа POS или вид+номер+дата документа 1С).
String entryKey(CustomerHistoryEntry e) => e.id ?? '${e.kind?.value}:${e.number}:${e.date.toIso8601String()}';

/// `customerHistoryProvider(args)`.
final customerHistoryProvider = NotifierProvider.autoDispose
    .family<CustomerHistoryController, CustomerHistoryState, CustomerHistoryArgs>(CustomerHistoryController.new);

/// Логика SCR-33.
final class CustomerHistoryController extends Notifier<CustomerHistoryState> {
  /// Контроллер истории.
  CustomerHistoryController(this.args);

  final CustomerHistoryArgs args;
  int _generation = 0;

  /// Отмена устаревшего запроса первой страницы (смена периода/источника, уход с экрана; SCR-33.11, D-31).
  final CancelSignalSeries _requests = CancelSignalSeries();

  /// Максимальный период (ядро §19.4).
  static const int maxDays = 366;

  /// Размер страницы.
  static const int pageSize = 50;

  @override
  CustomerHistoryState build() {
    ref.onDispose(_requests.cancel);
    final DateTime now = ref.read(clockProvider).nowUtc();
    final DateTime? from = _parse(args.from);
    final DateTime? to = _parse(args.to);
    final bool custom = from != null || to != null;
    final DateTime end = to ?? now;
    final DateTime start =
        from ?? CustomersFormat.startOfDayUtc(end.subtract(Duration(days: HistoryPreset.days90.days)));
    unawaited(Future<void>.microtask(load));
    return CustomerHistoryState(
      from: start,
      to: end,
      preset: custom ? HistoryPreset.custom : HistoryPreset.days90,
      source: CustomerHistorySource.tryParse(args.source) ?? CustomerHistorySource.all,
    );
  }

  static DateTime? _parse(String? v) => v == null ? null : DateTime.tryParse(v)?.toUtc();

  /// Период корректен: «по» не раньше «с», не длиннее 366 дней.
  static bool validRange(DateTime from, DateTime to) => !to.isBefore(from) && to.difference(from).inDays <= maxDays;

  /// Пресет: период до «сейчас».
  Future<void> setPreset(HistoryPreset p) {
    if (p == HistoryPreset.custom) return Future<void>.value();
    final DateTime now = ref.read(clockProvider).nowUtc();
    state = state.copyWith(
      preset: p,
      from: CustomersFormat.startOfDayUtc(now.subtract(Duration(days: p.days))),
      to: now,
      expanded: const <String>{},
    );
    return load();
  }

  /// «Период…»: произвольный диапазон (проверка — [validRange]).
  Future<void> setRange(DateTime from, DateTime to) {
    if (!validRange(from, to)) return Future<void>.value();
    state = state.copyWith(preset: HistoryPreset.custom, from: from, to: to, expanded: const <String>{});
    return load();
  }

  /// Источник `all|pos|onec` — мгновенный запрос.
  Future<void> setSource(CustomerHistorySource s) {
    if (s == state.source) return Future<void>.value();
    state = state.copyWith(source: s, expanded: const <String>{});
    return load();
  }

  /// Раскрыть/свернуть строку.
  void toggle(CustomerHistoryEntry e) {
    final String k = entryKey(e);
    final Set<String> next = <String>{...state.expanded};
    if (!next.remove(k)) next.add(k);
    state = state.copyWith(expanded: next);
  }

  CustomerHistoryPhase _phaseOf(Failure f) {
    if (isNotFoundFailure(f)) return CustomerHistoryPhase.notFound;
    if (f is PermissionFailure) return CustomerHistoryPhase.forbidden;
    if (isOfflineFailure(f)) return CustomerHistoryPhase.offline;
    return CustomerHistoryPhase.error;
  }

  Future<Result<CustomerHistory>> _fetch({String? cursor, CancelSignal? cancel}) async {
    try {
      return await ref
          .read(customerDirectoryRepositoryProvider)
          .history(
            args.customerId,
            CustomerHistoryQuery(from: state.from, to: state.to, source: state.source, limit: pageSize, cursor: cursor),
            cancel: cancel,
          );
    } on Object catch (e) {
      return FailureResult<CustomerHistory>(UnknownFailure(cause: e));
    }
  }

  /// Загрузка первой страницы.
  Future<void> load() async {
    final int gen = ++_generation;
    final CancelSignal signal = _requests.next();
    if (!ref.mounted) return;
    if (!ref.read(customersOnlineProvider)) {
      state = state.copyWith(phase: CustomerHistoryPhase.offline, entries: const <CustomerHistoryEntry>[]);
      return;
    }
    state = state.copyWith(
      phase: CustomerHistoryPhase.loading,
      entries: const <CustomerHistoryEntry>[],
      cursor: () => null,
      loadMoreFailed: false,
      failure: () => null,
    );
    final Result<CustomerHistory> r = await _fetch(cancel: signal);
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<CustomerHistory>(:final CustomerHistory value):
        state = state.copyWith(
          phase: value.page.items.isEmpty ? CustomerHistoryPhase.empty : CustomerHistoryPhase.list,
          entries: value.page.items,
          summary: () => value.summary,
          historyFrom: () => value.historyFrom,
          asOf: () => value.page.asOf,
          cursor: () => value.page.hasMore ? value.page.nextCursor : null,
        );
      case FailureResult<CustomerHistory>(:final Failure failure):
        state = state.copyWith(phase: _phaseOf(failure), failure: () => failure);
    }
  }

  /// Подгрузка по курсору.
  Future<void> loadMore() async {
    final String? cursor = state.cursor;
    if (cursor == null || state.loadingMore || state.phase != CustomerHistoryPhase.list) return;
    final int gen = _generation;
    state = state.copyWith(loadingMore: true, loadMoreFailed: false);
    final Result<CustomerHistory> r = await _fetch(cursor: cursor);
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<CustomerHistory>(:final CustomerHistory value):
        final Set<String> seen = <String>{for (final CustomerHistoryEntry e in state.entries) entryKey(e)};
        state = state.copyWith(
          entries: <CustomerHistoryEntry>[
            ...state.entries,
            for (final CustomerHistoryEntry e in value.page.items)
              if (seen.add(entryKey(e))) e,
          ],
          cursor: () => value.page.hasMore ? value.page.nextCursor : null,
          loadingMore: false,
        );
      case FailureResult<CustomerHistory>():
        state = state.copyWith(loadingMore: false, loadMoreFailed: true);
    }
  }

  /// Подзаголовок: имя клиента из памяти сессии.
  String? customerName() => ref.read(customerNamesProvider).nameOf(args.customerId);
}
