// Долг и взаиморасчёты клиента (08 §4.11.7–§4.11.8, §4.13 `Receivable`, `ReceivableDocument`,
// `ReceivablesOverdueItem`; 10 DEBT-, D-24). Долги — только из 1С (снимок `receivables` + метка `asOf`), fail-closed:
// отсутствующий/неполный/устаревший снимок — «Нет данных из 1С» / «устарело», никогда — «долга нет».
// Финансовые данные клиента — только в памяти сессии (CASH-015, 07 §11.1 п. 5): не пишутся в drift/secure storage.
// Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';

/// Документ взаиморасчётов (`ReceivableDocument`; детализация — step-up, 11 №62).
final class ReceivableDocument {
  const ReceivableDocument({
    required this.kind,
    required this.status,
    required this.amount,
    this.number,
    this.date,
    this.paid,
    this.remaining,
    this.dueDate,
    this.overdueDays,
    this.onecRef,
  });

  /// `null` — вид, неизвестный клиенту.
  final ReceivableDocumentKind? kind;
  final ReceivableDocumentStatus? status;
  final String? number;
  final DateTime? date;
  final Money amount;
  final Money? paid;
  final Money? remaining;
  final DateTime? dueDate;
  final int? overdueDays;
  final String? onecRef;
}

/// Причина отсутствия сальдо (`Receivable.reason`).
enum ReceivableAbsenceReason {
  /// Клиент ещё не создан в 1С (`onecStatus=pending`) — долга в 1С нет и быть не может.
  notInOnec('not_in_onec');

  const ReceivableAbsenceReason(this.value);

  final String value;

  static ReceivableAbsenceReason? tryParse(String? value) {
    for (final ReceivableAbsenceReason r in values) {
      if (r.value == value) return r;
    }
    return null;
  }
}

/// Снимок долга клиента (`Receivable`, SCR-34; `GET /customers/{id}/receivables`, `POST …/refresh`).
final class Receivable {
  const Receivable({
    required this.customerId,
    this.balance,
    this.reason,
    this.overdueAmount,
    this.overdueDays,
    this.creditLimit,
    this.openOrdersAmount,
    this.limitRemaining,
    this.creditAllowed,
    this.paymentTermDays,
    this.asOf,
    this.isStale = false,
    this.staleAfterMinutes,
    this.refreshed = false,
    this.documents,
  });

  final String customerId;

  /// `null` — снимка нет (см. [reason]); показывается «Нет данных из 1С», не «0».
  final Money? balance;
  final ReceivableAbsenceReason? reason;

  /// `null` — просрочка неизвестна (неполный снимок, ядро §22.4 шаг 3).
  final Money? overdueAmount;
  final int? overdueDays;
  final Money? creditLimit;
  final Money? openOrdersAmount;
  final Money? limitRemaining;
  final bool? creditAllowed;
  final int? paymentTermDays;

  /// Метка снимка 1С; `null` — снимка нет.
  final DateTime? asOf;

  /// Снимок старше `RECEIVABLES_MAX_AGE_MIN` (60 мин по умолчанию).
  final bool isStale;
  final int? staleAfterMinutes;

  /// Снимок обновлён этим запросом (`refresh`).
  final bool refreshed;

  /// Детализация; `null` — не запрашивалась (`include=documents` — step-up).
  final List<ReceivableDocument>? documents;

  /// Снимок полный и свежий (ядро §22.4: только такой разрешает долг без обращения к 1С).
  bool get isCompleteAndFresh => balance != null && overdueAmount != null && asOf != null && !isStale;

  @override
  String toString() => 'Receivable($customerId)';
}

/// Строка просроченной задолженности (`ReceivablesOverdueItem`, `GET /receivables/overdue`).
final class OverdueReceivable {
  const OverdueReceivable({
    required this.customer,
    required this.balance,
    required this.overdueAmount,
    required this.overdueDays,
    required this.asOf,
    this.oldestDueDate,
  });

  final Customer customer;
  final Money balance;
  final Money overdueAmount;
  final int overdueDays;
  final DateTime? oldestDueDate;
  final DateTime asOf;
}

/// Страница `GET /receivables/overdue` (+ `isStale`).
final class OverdueReceivablesPage {
  const OverdueReceivablesPage({required this.page, this.isStale = false});

  final PageResult<OverdueReceivable> page;
  final bool isStale;
}

/// Сортировка `GET /receivables/overdue`.
enum OverdueSort {
  overdueAmountDesc('overdueAmount:desc'),
  overdueDaysDesc('overdueDays:desc'),
  customerNameAsc('customerName:asc');

  const OverdueSort(this.value);

  final String value;
}
