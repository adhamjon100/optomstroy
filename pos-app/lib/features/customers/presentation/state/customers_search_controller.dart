// Состояние SCR-31 «Поиск клиентов» (02 SCR-31.4, SCR-31.7; 08 §4.5.4, §4.11.1; ядро §19.4, §22.13 п.1).
//
// * Текст ≥ порога роли → `GET /search/customers?q=` (debounce 300 мс; ответ устаревшего запроса отбрасывается);
//   с активным чипом — `GET /customers?q=&favorite=|hasDebt=|isOverdue=` (текст не сбрасывается).
// * Без текста: чип → `GET /customers?…`; «Все» — у `cashier`+ список «Избранные» (`favorite=true`), у остальных —
//   подсказка (02 SCR-31.7 Idle).
// * Пороги (ядро §19.4): `cashier`+ — от 4 цифр телефона или 2 букв имени; `seller` — только полный номер (9 цифр) или
//   код клиента; буквы — подсказка без запроса, 4–8 цифр — «введите номер полностью».
// * Суммы долга в строках не запрашиваются (`include=receivable` не передаётся — AC-UI-31-012). Результаты — только
//   память провайдера (кэша клиентов на устройстве нет, DATA-258); офлайн — «Поиск клиентов недоступен без сети».
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';

/// Чип-фильтр UI-31-002 (один активный).
enum CustomersFilter { all, favorites, debt, overdue }

/// Фаза списка (02 SCR-31.7).
enum CustomersSearchPhase {
  /// Без запроса: подсказка («Введите имя, телефон или код клиента»).
  idle,

  /// `seller` ввёл буквы (имя) — «Введите полный номер телефона или код клиента», запроса нет.
  sellerHint,

  /// `seller` ввёл 4–8 цифр — «Для поиска по телефону введите номер полностью», запроса нет.
  phoneFullHint,

  /// Запрос (скелетон, P-SKEL).
  loading,

  /// Список.
  results,

  /// Пусто — `EmptyState.customers` с «+ Новый клиент».
  empty,

  /// Ошибка — `ErrorState.inline` «Не удалось найти клиентов · Повторить».
  error,

  /// Нет сети.
  offline,
}

/// Вид ввода для порога роли.
enum CustomersQueryKind { none, search, sellerHint, phoneFullHint }

/// Состояние SCR-31.
final class CustomersSearchState {
  const CustomersSearchState({
    this.query = '',
    this.filter = CustomersFilter.all,
    this.phase = CustomersSearchPhase.idle,
    this.items = const <Customer>[],
    this.textSearch = false,
    this.matchType,
    this.matchCount = 0,
    this.cursor,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.failure,
  });

  final String query;
  final CustomersFilter filter;
  final CustomersSearchPhase phase;
  final List<Customer> items;

  /// Список — результат текстового поиска (подпись `matchType`, текст пустого состояния с `q`).
  final bool textSearch;
  final CustomerMatchType? matchType;
  final int matchCount;

  /// Курсор следующей страницы; `null` — конец.
  final String? cursor;
  final bool loadingMore;
  final bool loadMoreFailed;
  final Failure? failure;

  bool get hasMore => cursor != null;

  CustomersSearchState copyWith({
    String? query,
    CustomersFilter? filter,
    CustomersSearchPhase? phase,
    List<Customer>? items,
    bool? textSearch,
    CustomerMatchType? Function()? matchType,
    int? matchCount,
    String? Function()? cursor,
    bool? loadingMore,
    bool? loadMoreFailed,
    Failure? Function()? failure,
  }) => CustomersSearchState(
    query: query ?? this.query,
    filter: filter ?? this.filter,
    phase: phase ?? this.phase,
    items: items ?? this.items,
    textSearch: textSearch ?? this.textSearch,
    matchType: matchType == null ? this.matchType : matchType(),
    matchCount: matchCount ?? this.matchCount,
    cursor: cursor == null ? this.cursor : cursor(),
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
    failure: failure == null ? this.failure : failure(),
  );
}

/// SCR-31 (живёт, пока открыт экран).
final customersSearchProvider = NotifierProvider.autoDispose<CustomersSearchController, CustomersSearchState>(
  CustomersSearchController.new,
);

/// Логика SCR-31.
final class CustomersSearchController extends Notifier<CustomersSearchState> {
  /// Debounce ввода (AC-UI-31-001).
  static const Duration debounce = Duration(milliseconds: 300);

  /// Размер страницы (02 SCR-31.9).
  static const int pageSize = 50;

  Timer? _timer;
  int _generation = 0;
  bool _started = false;

  /// Отмена устаревшего запроса первой страницы: новый поиск/фильтр и уход с экрана отменяют HTTP-запрос
  /// (SCR-31.11 «двойной запрос поиска исключён отменой предыдущего», D-31); ответ отменённого отбрасывается.
  final CancelSignalSeries _requests = CancelSignalSeries();

  @override
  CustomersSearchState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _requests.cancel();
    });
    return const CustomersSearchState();
  }

  CustomersViewer get _viewer => ref.read(customersViewerProvider);

  bool get _online => ref.read(customersOnlineProvider);

  /// Порог роли (ядро §19.4).
  static CustomersQueryKind classify(String q, CustomersViewer viewer) {
    final String t = q.trim();
    if (t.length < 2) return CustomersQueryKind.none;
    final int digits = t.replaceAll(RegExp(r'\D'), '').length;
    final bool letters = RegExp(r'[A-Za-zА-Яа-яЁёӨөҮүҢң]').hasMatch(t);
    final bool codeLike = t.contains('-') && digits >= 2;
    if (!viewer.searchesByName) {
      if (codeLike) return CustomersQueryKind.search;
      if (letters) return CustomersQueryKind.sellerHint;
      if (CustomersFormat.phoneQuery(t) != null) return CustomersQueryKind.search;
      return digits >= 4 ? CustomersQueryKind.phoneFullHint : CustomersQueryKind.sellerHint;
    }
    if (letters || codeLike) {
      return t.replaceAll(RegExp(r'\s'), '').length >= 2 ? CustomersQueryKind.search : CustomersQueryKind.none;
    }
    return digits >= 4 ? CustomersQueryKind.search : CustomersQueryKind.none;
  }

  /// Нормализация: телефон из 9 национальных цифр → E.164 (AC-UI-31-002), иначе текст как есть.
  static String normalize(String q) => CustomersFormat.phoneQuery(q) ?? q.trim();

  /// Открытие экрана с параметрами маршрута (один раз).
  void start({String? q, CustomersFilter filter = CustomersFilter.all}) {
    if (_started) return;
    _started = true;
    final CustomersFilter allowed = _allowedFilter(filter);
    state = state.copyWith(query: q ?? '', filter: allowed);
    unawaited(_run());
  }

  CustomersFilter _allowedFilter(CustomersFilter f) => switch (f) {
    CustomersFilter.favorites when !_viewer.canManageFavorites => CustomersFilter.all,
    CustomersFilter.debt || CustomersFilter.overdue when !_viewer.canFilterDebt => CustomersFilter.all,
    _ => f,
  };

  /// Ввод (debounce 300 мс; каждый ввод перезапускает таймер).
  void setQuery(String q) {
    _timer?.cancel();
    state = state.copyWith(query: q);
    final CustomersQueryKind kind = classify(q, _viewer);
    if (kind == CustomersQueryKind.search) {
      _timer = Timer(debounce, () => unawaited(_run()));
    } else {
      unawaited(_run());
    }
  }

  /// Enter — немедленный запрос.
  Future<void> submit() {
    _timer?.cancel();
    return _run();
  }

  /// Чип; повторный тап по активному — «Все».
  Future<void> setFilter(CustomersFilter f) {
    _timer?.cancel();
    final CustomersFilter next = f == state.filter ? CustomersFilter.all : _allowedFilter(f);
    state = state.copyWith(filter: next);
    return _run();
  }

  /// «Повторить».
  Future<void> retry() => _run();

  /// Перечитать текущий список (возврат с SCR-26/SCR-32).
  Future<void> reload() => _run(silent: state.phase == CustomersSearchPhase.results);

  Future<void> _run({bool silent = false}) async {
    final int gen = ++_generation;
    final CancelSignal signal = _requests.next();
    final CustomersSearchState s = state;
    final CustomersQueryKind kind = classify(s.query, _viewer);
    final bool text = kind == CustomersQueryKind.search;
    if (kind == CustomersQueryKind.sellerHint || kind == CustomersQueryKind.phoneFullHint) {
      state = s.copyWith(
        phase: kind == CustomersQueryKind.sellerHint
            ? CustomersSearchPhase.sellerHint
            : CustomersSearchPhase.phoneFullHint,
        items: const <Customer>[],
        textSearch: false,
        matchType: () => null,
        cursor: () => null,
      );
      return;
    }
    final CustomersFilter filter = s.filter;
    final bool favoritesByDefault = !text && filter == CustomersFilter.all && _viewer.canManageFavorites;
    if (!text && filter == CustomersFilter.all && !favoritesByDefault) {
      state = s.copyWith(
        phase: CustomersSearchPhase.idle,
        items: const <Customer>[],
        textSearch: false,
        matchType: () => null,
        cursor: () => null,
      );
      return;
    }
    if (!_online) {
      state = s.copyWith(phase: CustomersSearchPhase.offline, items: const <Customer>[], cursor: () => null);
      return;
    }
    if (!silent) {
      state = s.copyWith(phase: CustomersSearchPhase.loading, loadMoreFailed: false, failure: () => null);
    }
    final Result<PageResult<Customer>> r = await _fetch(
      text: text,
      filter: favoritesByDefault ? CustomersFilter.favorites : filter,
      cancel: signal,
    );
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<PageResult<Customer>>(:final PageResult<Customer> value):
        final List<Customer> items = _visible(value.items);
        _remember(items);
        final (CustomerMatchType? match, int count) = text && filter == CustomersFilter.all
            ? _dominantMatch(items)
            : (null, 0);
        state = state.copyWith(
          phase: items.isEmpty ? CustomersSearchPhase.empty : CustomersSearchPhase.results,
          items: items,
          textSearch: text,
          matchType: () => match,
          matchCount: count,
          cursor: () => value.hasMore ? value.nextCursor : null,
          loadMoreFailed: false,
          failure: () => null,
        );
      case FailureResult<PageResult<Customer>>(:final Failure failure):
        final bool offline = failure is NetworkFailure && failure.kind == NetworkFailureKind.offline;
        state = state.copyWith(
          phase: offline ? CustomersSearchPhase.offline : CustomersSearchPhase.error,
          failure: () => failure,
          textSearch: text,
        );
    }
  }

  Future<Result<PageResult<Customer>>> _fetch({
    required bool text,
    required CustomersFilter filter,
    String? cursor,
    CancelSignal? cancel,
  }) async {
    final String q = normalize(state.query);
    try {
      if (text && filter == CustomersFilter.all) {
        return await ref
            .read(customersRepositoryProvider)
            .search(
              CustomerSearchQuery(q: q, limit: pageSize, cursor: cursor),
              cancel: cancel,
            );
      }
      return await ref
          .read(customerDirectoryRepositoryProvider)
          .list(
            CustomersListQuery(
              q: text ? q : null,
              favoriteOnly: filter == CustomersFilter.favorites,
              hasDebt: filter == CustomersFilter.debt ? true : null,
              isOverdue: filter == CustomersFilter.overdue ? true : null,
              limit: pageSize,
              cursor: cursor,
            ),
            cancel: cancel,
          );
    } on Object catch (e) {
      return FailureResult<PageResult<Customer>>(UnknownFailure(cause: e));
    }
  }

  /// Подгрузка по курсору (прокрутка за 80 %).
  Future<void> loadMore() async {
    final CustomersSearchState s = state;
    final String? cursor = s.cursor;
    if (cursor == null || s.loadingMore || s.phase != CustomersSearchPhase.results) return;
    final int gen = _generation;
    final bool text = classify(s.query, _viewer) == CustomersQueryKind.search;
    final bool favoritesByDefault = !text && s.filter == CustomersFilter.all && _viewer.canManageFavorites;
    state = s.copyWith(loadingMore: true, loadMoreFailed: false);
    final Result<PageResult<Customer>> r = await _fetch(
      text: text,
      filter: favoritesByDefault ? CustomersFilter.favorites : s.filter,
      cursor: cursor,
    );
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<PageResult<Customer>>(:final PageResult<Customer> value):
        final Set<String> seen = <String>{for (final Customer c in state.items) c.id};
        final List<Customer> more = <Customer>[
          for (final Customer c in _visible(value.items))
            if (seen.add(c.id)) c,
        ];
        _remember(more);
        state = state.copyWith(
          items: <Customer>[...state.items, ...more],
          cursor: () => value.hasMore ? value.nextCursor : null,
          loadingMore: false,
        );
      case FailureResult<PageResult<Customer>>():
        state = state.copyWith(loadingMore: false, loadMoreFailed: true);
    }
  }

  /// Скрыть строку (клиент убран из избранного в режиме «Избранные»).
  void hide(String customerId) => state = state.copyWith(
    items: <Customer>[
      for (final Customer c in state.items)
        if (c.id != customerId) c,
    ],
  );

  /// Вернуть строку на прежнее место («Отменить»).
  void restore(Customer customer, int index) {
    if (state.items.any((Customer c) => c.id == customer.id)) return;
    final List<Customer> items = <Customer>[...state.items];
    items.insert(index.clamp(0, items.length), customer);
    state = state.copyWith(items: items, phase: CustomersSearchPhase.results);
  }

  /// Системный «Розничный покупатель» в поиске не показывается (CUST-018).
  static List<Customer> _visible(List<Customer> items) => <Customer>[
    for (final Customer c in items)
      if (!c.isRetailDefault) c,
  ];

  void _remember(List<Customer> items) {
    final CustomerNameMemory names = ref.read(customerNamesProvider);
    for (final Customer c in items) {
      names.put(c.id, c.title);
    }
  }

  /// Тип совпадения большинства строк и их число.
  static (CustomerMatchType?, int) _dominantMatch(List<Customer> items) {
    final Map<CustomerMatchType, int> counts = <CustomerMatchType, int>{};
    for (final Customer c in items) {
      final CustomerMatchType? t = c.matchType;
      if (t != null) counts[t] = (counts[t] ?? 0) + 1;
    }
    if (counts.isEmpty) return (null, 0);
    final MapEntry<CustomerMatchType, int> top = counts.entries.reduce(
      (MapEntry<CustomerMatchType, int> a, MapEntry<CustomerMatchType, int> b) => b.value > a.value ? b : a,
    );
    return (top.key, top.value);
  }
}
