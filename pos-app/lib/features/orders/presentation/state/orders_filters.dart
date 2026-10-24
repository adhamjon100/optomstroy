// Фильтры SCR-25 (02 UI-25-002…UI-25-005, UI-25-012, UI-25-013): группы статусов чипов, период в границах суток
// Бишкека (AC-UI-25-011), «Мои / Все», клиент, способ оплаты, оплачен, поиск по номеру, сортировка. Значения
// `status`, `from`, `to`, `customerId`, `mine` отражаются в query маршрута (восстановление и «Назад» из SCR-24,
// AC-UI-25-010); прочие — только память экрана.
import 'package:flutter/foundation.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/orders_format.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';

/// Группы статусов чипов SCR-25 (UI-25-003).
enum OrdersStatusGroup {
  /// «Все» — без фильтра статуса.
  all(<OrderStatus>{}),

  /// «В работе».
  inProgress(<OrderStatus>{
    OrderStatus.submitting,
    OrderStatus.pendingApproval,
    OrderStatus.approved,
    OrderStatus.awaitingShipment,
  }),

  /// «Ждут оплаты».
  awaitingPayment(<OrderStatus>{OrderStatus.awaitingPayment}),

  /// «Отгружены».
  shipped(<OrderStatus>{OrderStatus.shipped, OrderStatus.partiallyReturned}),

  /// «Закрыты».
  closed(<OrderStatus>{OrderStatus.closed}),

  /// «Отменены и отклонены».
  cancelled(<OrderStatus>{OrderStatus.cancelled, OrderStatus.submitFailed});

  const OrdersStatusGroup(this.statuses);

  /// Статусы группы (`status=` запроса).
  final Set<OrderStatus> statuses;

  /// Группа с ровно таким набором статусов; `null` — набор из маршрута не совпал ни с одной группой.
  static OrdersStatusGroup? of(Set<OrderStatus> statuses) {
    for (final OrdersStatusGroup g in values) {
      if (setEquals(g.statuses, statuses)) return g;
    }
    return null;
  }

  /// Счётчик группы из `statusCounts`; `null` — счётчиков нет (чип без числа).
  int? countIn(Map<OrderStatus, int> counts) {
    if (counts.isEmpty) return null;
    final Iterable<OrderStatus> keys = this == all ? counts.keys : statuses;
    return keys.fold<int>(0, (int acc, OrderStatus s) => acc + (counts[s] ?? 0));
  }
}

/// Пресет периода (UI-25-004).
enum OrdersPeriodPreset {
  /// Последние 3 дня — по умолчанию [ТИПОВО].
  last3Days,
  today,
  yesterday,
  days7,
  month,

  /// «Период…» (`DateRangePicker`).
  custom,
}

/// Период: полуинтервал `[from, to)` в UTC.
@immutable
final class OrdersPeriod {
  /// Создаёт период.
  const OrdersPeriod({required this.preset, required this.from, required this.to});

  /// Пресет на дату [nowUtc] (границы суток Бишкека, AC-UI-25-011).
  factory OrdersPeriod.preset(OrdersPeriodPreset preset, DateTime nowUtc) {
    final DateTime today = OrdersFormat.startOfDayUtc(nowUtc);
    final DateTime tomorrow = today.add(const Duration(days: 1));
    return switch (preset) {
      OrdersPeriodPreset.today => OrdersPeriod(preset: preset, from: today, to: tomorrow),
      OrdersPeriodPreset.yesterday => OrdersPeriod(
        preset: preset,
        from: today.subtract(const Duration(days: 1)),
        to: today,
      ),
      OrdersPeriodPreset.days7 => OrdersPeriod(
        preset: preset,
        from: today.subtract(const Duration(days: 6)),
        to: tomorrow,
      ),
      OrdersPeriodPreset.month => OrdersPeriod(
        preset: preset,
        from: today.subtract(const Duration(days: 29)),
        to: tomorrow,
      ),
      OrdersPeriodPreset.last3Days || OrdersPeriodPreset.custom => OrdersPeriod(
        preset: OrdersPeriodPreset.last3Days,
        from: today.subtract(const Duration(days: 2)),
        to: tomorrow,
      ),
    };
  }

  /// Произвольные даты: с полуночи дня [firstDayUtc] до полуночи после дня [lastDayUtc] (оба — дни Бишкека).
  factory OrdersPeriod.days(DateTime firstDayUtc, DateTime lastDayUtc) => OrdersPeriod(
    preset: OrdersPeriodPreset.custom,
    from: OrdersFormat.startOfDayUtc(firstDayUtc),
    to: OrdersFormat.startOfDayUtc(lastDayUtc).add(const Duration(days: 1)),
  );

  final OrdersPeriodPreset preset;
  final DateTime from;
  final DateTime to;

  @override
  bool operator ==(Object other) =>
      other is OrdersPeriod && other.preset == preset && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(preset, from, to);
}

/// Значение «Оплачен» фильтра (`isPaid`).
enum OrdersPaidFilter { any, paid, unpaid }

/// Набор фильтров SCR-25 (ключ провайдера списка — равенство по значению).
@immutable
final class OrdersFilters {
  /// Создаёт фильтры.
  const OrdersFilters({
    required this.period,
    this.statuses = const <OrderStatus>{},
    this.mine = false,
    this.customerId,
    this.customerName,
    this.paymentMethod,
    this.paid = OrdersPaidFilter.any,
    this.q = '',
    this.sort = OrdersSort.createdAtDesc,
  });

  /// Фильтры по умолчанию: все статусы, последние 3 дня, «Мои» — для `seller` (свои всегда) и без переключателя.
  factory OrdersFilters.defaults(DateTime nowUtc) =>
      OrdersFilters(period: OrdersPeriod.preset(OrdersPeriodPreset.last3Days, nowUtc));

  /// Фильтры из query маршрута (`status`, `from`, `to`, `customerId`, `mine`); неверные значения — по умолчанию.
  factory OrdersFilters.fromRoute({
    required DateTime nowUtc,
    String? status,
    String? from,
    String? to,
    String? customerId,
    String? mine,
  }) {
    final Set<OrderStatus> statuses = <OrderStatus>{
      for (final String s in (status ?? '').split(',')) ?OrderStatus.tryParse(s.trim()),
    };
    final DateTime? f = from == null ? null : DateTime.tryParse(from)?.toUtc();
    final DateTime? t = to == null ? null : DateTime.tryParse(to)?.toUtc();
    final OrdersPeriod period = f != null && t != null && f.isBefore(t)
        ? _periodFor(f, t, nowUtc)
        : OrdersPeriod.preset(OrdersPeriodPreset.last3Days, nowUtc);
    final String? customer = customerId == null || customerId.isEmpty ? null : customerId;
    return OrdersFilters(period: period, statuses: statuses, mine: mine == '1', customerId: customer);
  }

  static OrdersPeriod _periodFor(DateTime from, DateTime to, DateTime nowUtc) {
    for (final OrdersPeriodPreset p in OrdersPeriodPreset.values) {
      if (p == OrdersPeriodPreset.custom) continue;
      final OrdersPeriod candidate = OrdersPeriod.preset(p, nowUtc);
      if (candidate.from == from && candidate.to == to) return candidate;
    }
    return OrdersPeriod(preset: OrdersPeriodPreset.custom, from: from, to: to);
  }

  final OrdersPeriod period;
  final Set<OrderStatus> statuses;

  /// «Мои» (для ролей с `order.read.all`).
  final bool mine;
  final String? customerId;

  /// Наименование выбранного клиента (подпись фильтра; в запрос не уходит).
  final String? customerName;
  final PaymentMethod? paymentMethod;
  final OrdersPaidFilter paid;

  /// Номер POS или 1С (`q`, ≤ 200).
  final String q;
  final OrdersSort sort;

  /// Группа чипа; `null` — набор статусов не совпал с группой.
  OrdersStatusGroup? get group => OrdersStatusGroup.of(statuses);

  /// Число активных фильтров панели (бейдж «Фильтры»).
  int get panelCount =>
      (customerId != null ? 1 : 0) + (paymentMethod != null ? 1 : 0) + (paid != OrdersPaidFilter.any ? 1 : 0);

  /// Фильтры отличаются от умолчаний (для `EmptyState`: «по выбранным фильтрам»).
  bool differsFromDefaults(DateTime nowUtc) =>
      statuses.isNotEmpty || panelCount > 0 || period != OrdersPeriod.preset(OrdersPeriodPreset.last3Days, nowUtc);

  /// Копия.
  OrdersFilters copyWith({
    OrdersPeriod? period,
    Set<OrderStatus>? statuses,
    bool? mine,
    String? Function()? customerId,
    String? Function()? customerName,
    PaymentMethod? Function()? paymentMethod,
    OrdersPaidFilter? paid,
    String? q,
    OrdersSort? sort,
  }) => OrdersFilters(
    period: period ?? this.period,
    statuses: statuses ?? this.statuses,
    mine: mine ?? this.mine,
    customerId: customerId == null ? this.customerId : customerId(),
    customerName: customerName == null ? this.customerName : customerName(),
    paymentMethod: paymentMethod == null ? this.paymentMethod : paymentMethod(),
    paid: paid ?? this.paid,
    q: q ?? this.q,
    sort: sort ?? this.sort,
  );

  /// Запрос `GET /orders` первой страницы (`include=statusCounts` — AC-UI-25-012). «Мои» уходит как `createdBy`
  /// только у ролей с `order.read.all` (у `seller`/`customer` сервер сам ограничивает своими — без `403`).
  OrdersQuery toQuery(OrdersViewer viewer, {String? cursor}) => OrdersQuery(
    statuses: statuses,
    customerId: customerId,
    createdBy: viewer.canReadAll && mine ? viewer.userId : null,
    from: period.from,
    to: period.to,
    paymentMethod: paymentMethod,
    isPaid: switch (paid) {
      OrdersPaidFilter.any => null,
      OrdersPaidFilter.paid => true,
      OrdersPaidFilter.unpaid => false,
    },
    q: q.trim().isEmpty ? null : q.trim(),
    withStatusCounts: cursor == null,
    sort: sort,
    cursor: cursor,
  );

  /// Query маршрута `/orders?status=&from=&to=&customerId=&mine=` (значения как в `OrdersRoute`).
  Map<String, String> toRouteQuery() => <String, String>{
    if (statuses.isNotEmpty) 'status': (statuses.map((OrderStatus s) => s.value).toList()..sort()).join(','),
    'from': period.from.toUtc().toIso8601String(),
    'to': period.to.toUtc().toIso8601String(),
    'customerId': ?customerId,
    if (mine) 'mine': '1',
  };

  @override
  bool operator ==(Object other) =>
      other is OrdersFilters &&
      other.period == period &&
      setEquals(other.statuses, statuses) &&
      other.mine == mine &&
      other.customerId == customerId &&
      other.paymentMethod == paymentMethod &&
      other.paid == paid &&
      other.q == q &&
      other.sort == sort;

  @override
  int get hashCode =>
      Object.hash(period, Object.hashAllUnordered(statuses), mine, customerId, paymentMethod, paid, q, sort);
}
