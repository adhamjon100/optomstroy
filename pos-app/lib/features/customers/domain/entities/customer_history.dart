// История покупок клиента (08 §4.11.5 `GET /customers/{id}/orders` → `CustomerHistory`; R0 §17.3 — проекция
// «Реализаций» 1С `shipments` + заказы POS; RM-G-011: `summary`, `historyFrom`). SCR-33; `customer` — только при
// `confirmed`-привязке (иначе 404, 10 CUST-025). Чистый Dart (FL-01).
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';

/// Вид записи истории (`CustomersHistoryEntry.kind`).
enum CustomerHistoryKind {
  order('order'),
  shipment('shipment'),
  returnValue('return');

  const CustomerHistoryKind(this.value);

  final String value;

  static CustomerHistoryKind? tryParse(String? value) {
    for (final CustomerHistoryKind k in values) {
      if (k.value == value) return k;
    }
    return null;
  }
}

/// Источник записи / фильтр `source` (`pos|onec|all`).
enum CustomerHistorySource {
  pos('pos'),
  onec('onec'),
  all('all');

  const CustomerHistorySource(this.value);

  final String value;

  static CustomerHistorySource? tryParse(String? value) {
    for (final CustomerHistorySource s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// Запись истории (`CustomersHistoryEntry`).
final class CustomerHistoryEntry {
  const CustomerHistoryEntry({
    required this.kind,
    required this.number,
    required this.date,
    required this.total,
    required this.status,
    required this.source,
    this.id,
    this.url,
  });

  final CustomerHistoryKind? kind;

  /// Заказ POS (`kind=order`) — id для перехода на SCR-24; для записей 1С — `null`.
  final String? id;
  final String number;
  final DateTime date;
  final Money total;

  /// Статус строкой контракта.
  final String status;
  final CustomerHistorySource? source;
  final String? url;
}

/// Итог истории за период (`CustomersHistorySummary`).
final class CustomerHistorySummary {
  const CustomerHistorySummary({required this.count, required this.total, this.lastOrderAt});

  final int count;
  final Money total;
  final DateTime? lastOrderAt;
}

/// Ответ истории (`CustomerHistory` = страница + итог + глубина).
final class CustomerHistory {
  const CustomerHistory({required this.page, required this.summary, this.historyFrom});

  final PageResult<CustomerHistoryEntry> page;
  final CustomerHistorySummary summary;

  /// С какой даты есть история 1С (`SALES_HISTORY_MONTHS`); `null` — граница неизвестна.
  final DateTime? historyFrom;
}
