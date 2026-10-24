// Фильтры SCR-36 (02 SCR-36.3, SCR-36.6, SCR-36.9): период (по умолчанию — «Сегодня» Бишкека, ≤ 366 дней — ядро
// §19.4), клиент, группы статуса, виды операции, способ оплаты, сотрудник (`admin`/`owner`), поиск по номеру,
// «Только мои» (`seller` — всегда). Хранятся в query маршрута (`from`, `to` — ISO-8601; `status`, `kind` — через
// запятую; `mine=1`) — сохраняются при возврате из SCR-37 и восстанавливаются deep link-ом. Имя клиента для чипа —
// только память (ПДн не в URL).
import 'package:flutter/foundation.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';

/// Фильтры журнала.
@immutable
final class TransactionsFilters {
  /// Создаёт фильтры.
  const TransactionsFilters({
    required this.period,
    this.customerId,
    this.customerName,
    this.statuses = const <TransactionStatusGroup>{},
    this.kinds = const <TransactionKind>{},
    this.paymentMethod,
    this.actorId,
    this.q = '',
    this.mine = false,
    this.periodRejected = false,
  });

  /// По умолчанию: сегодня (Q-215 — значения по умолчанию не решены; экран берёт «Сегодня»).
  factory TransactionsFilters.defaults(DateTime nowUtc, {bool mine = false}) =>
      TransactionsFilters(period: DateRangeValue.preset(DateRangePreset.today, nowUtc), mine: mine);

  /// Из query маршрута; период длиннее 366 дней или неверный — «Сегодня» с пометкой [periodRejected].
  factory TransactionsFilters.fromRoute({
    required DateTime nowUtc,
    required bool forceMine,
    String? from,
    String? to,
    String? customerId,
    String? status,
    String? kind,
    String? paymentMethod,
    String? actorId,
    String? q,
    String? mine,
  }) {
    final DateTime? f = from == null ? null : DateTime.tryParse(from)?.toUtc();
    final DateTime? t = to == null ? null : DateTime.tryParse(to)?.toUtc();
    DateRangeValue period = DateRangeValue.preset(DateRangePreset.today, nowUtc);
    bool rejected = false;
    if (f != null || t != null) {
      final DateTime a = f ?? DsBishkekTime.startOfDayUtc(t!);
      final DateTime b = t ?? DsBishkekTime.endOfDayUtc(nowUtc);
      if (JournalPeriod.tryCreate(a, b) != null &&
          DsBishkekTime.daysInclusive(a, b) <= DateRangePicker.journalMaxDays) {
        period = DateRangeValue(fromUtc: a, toUtc: b);
      } else {
        rejected = true;
      }
    }
    List<String> split(String? v) => v == null
        ? const <String>[]
        : v.split(',').map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();
    return TransactionsFilters(
      period: period,
      periodRejected: rejected,
      customerId: (customerId ?? '').isEmpty ? null : customerId,
      statuses: <TransactionStatusGroup>{for (final String s in split(status)) ?TransactionStatusGroup.tryParse(s)},
      kinds: <TransactionKind>{for (final String s in split(kind)) ?TransactionKind.tryParse(s)},
      paymentMethod: PaymentMethod.tryParse(paymentMethod),
      actorId: (actorId ?? '').isEmpty ? null : actorId,
      q: (q ?? '').trim(),
      mine: forceMine || mine == '1' || mine == 'true',
    );
  }

  final DateRangeValue period;
  final String? customerId;

  /// Подпись чипа клиента (только память).
  final String? customerName;
  final Set<TransactionStatusGroup> statuses;
  final Set<TransactionKind> kinds;
  final PaymentMethod? paymentMethod;
  final String? actorId;
  final String q;
  final bool mine;

  /// Период из URL отклонён (> 366 дней / неверный) — показан «Сегодня» и сообщение.
  final bool periodRejected;

  /// Активные фильтры, кроме периода, поиска и «Только мои» (счётчик «Фильтры · N»).
  int get activeCount =>
      (customerId == null ? 0 : 1) +
      statuses.length +
      kinds.length +
      (paymentMethod == null ? 0 : 1) +
      (actorId == null ? 0 : 1);

  /// Отличается ли от значений по умолчанию (кнопка «Сбросить фильтры»).
  bool differsFrom(TransactionsFilters defaults) => activeCount > 0 || q.isNotEmpty || period != defaults.period;

  /// Параметры `GET /transactions`.
  TransactionsQuery toQuery({
    String? cursor,
    int limit = 50,
    TransactionsSort sort = TransactionsSort.occurredAtDesc,
  }) => TransactionsQuery(
    period: JournalPeriod.tryCreate(period.fromUtc, period.toUtc)!,
    customerId: customerId,
    statuses: statuses,
    kinds: kinds,
    mine: mine,
    actorId: actorId,
    paymentMethod: paymentMethod,
    q: q.isEmpty ? null : (q.length > TransactionsQuery.qMaxLength ? q.substring(0, TransactionsQuery.qMaxLength) : q),
    limit: limit,
    cursor: cursor,
    sort: sort,
  );

  /// Query маршрута (`TransactionsRoute`).
  Map<String, String> toRoute() => <String, String>{
    'from': period.fromUtc.toIso8601String(),
    'to': period.toUtc.toIso8601String(),
    'customerId': ?customerId,
    if (statuses.isNotEmpty) 'status': statuses.map((TransactionStatusGroup s) => s.value).join(','),
    if (kinds.isNotEmpty) 'kind': kinds.map((TransactionKind k) => k.value).join(','),
    'paymentMethod': ?paymentMethod?.value,
    'actorId': ?actorId,
    if (q.isNotEmpty) 'q': q,
    if (mine) 'mine': '1',
  };

  TransactionsFilters copyWith({
    DateRangeValue? period,
    String? Function()? customerId,
    String? Function()? customerName,
    Set<TransactionStatusGroup>? statuses,
    Set<TransactionKind>? kinds,
    PaymentMethod? Function()? paymentMethod,
    String? Function()? actorId,
    String? q,
    bool? mine,
    bool? periodRejected,
  }) => TransactionsFilters(
    period: period ?? this.period,
    customerId: customerId == null ? this.customerId : customerId(),
    customerName: customerName == null ? this.customerName : customerName(),
    statuses: statuses ?? this.statuses,
    kinds: kinds ?? this.kinds,
    paymentMethod: paymentMethod == null ? this.paymentMethod : paymentMethod(),
    actorId: actorId == null ? this.actorId : actorId(),
    q: q ?? this.q,
    mine: mine ?? this.mine,
    periodRejected: periodRejected ?? false,
  );

  @override
  bool operator ==(Object other) =>
      other is TransactionsFilters &&
      other.period == period &&
      other.customerId == customerId &&
      setEquals(other.statuses, statuses) &&
      setEquals(other.kinds, kinds) &&
      other.paymentMethod == paymentMethod &&
      other.actorId == actorId &&
      other.q == q &&
      other.mine == mine;

  @override
  int get hashCode => Object.hash(
    period,
    customerId,
    Object.hashAllUnordered(statuses),
    Object.hashAllUnordered(kinds),
    paymentMethod,
    actorId,
    q,
    mine,
  );
}
