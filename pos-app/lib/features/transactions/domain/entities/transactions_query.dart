// Параметры и страница журнала операций SCR-36 (08 §4.16 `GET /transactions`; 10 TXN-; RM-G-004, RM-G-011).
// Сущность `Transaction` — core/models/transaction.dart (общая с SCR-30). Период — обязателен и не длиннее 366 дней
// (`JournalPeriod`); `seller` — только свои (`mine=true` принудительно, сервер проверяет сам). Экспорт CSV — R2.
// Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/audit_record.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/utils/money.dart';

/// Сортировка журнала.
enum TransactionsSort {
  occurredAtDesc('occurredAt:desc'),
  amountDesc('amount:desc');

  const TransactionsSort(this.value);

  final String value;
}

/// Фильтры `GET /transactions` (02 §4.1 SCR-36: `from,to,customerId,status,kind,paymentMethod,actorId,q,mine`).
final class TransactionsQuery {
  const TransactionsQuery({
    required this.period,
    this.customerId,
    this.statuses = const <TransactionStatusGroup>{},
    this.kinds = const <TransactionKind>{},
    this.source,
    this.mine = false,
    this.actorId,
    this.paymentMethod,
    this.amountMin,
    this.amountMax,
    this.q,
    this.limit,
    this.cursor,
    this.sort = TransactionsSort.occurredAtDesc,
  });

  /// Обязательный период ≤ 366 дней.
  final JournalPeriod period;
  final String? customerId;
  final Set<TransactionStatusGroup> statuses;
  final Set<TransactionKind> kinds;
  final TransactionSource? source;

  /// Только свои (`seller` — всегда).
  final bool mine;

  /// Сотрудник (`admin`/`owner`).
  final String? actorId;
  final PaymentMethod? paymentMethod;
  final Money? amountMin;
  final Money? amountMax;

  /// Поиск по номеру / клиенту (≤ 200).
  final String? q;
  final int? limit;
  final String? cursor;
  final TransactionsSort sort;

  static const int qMaxLength = 200;
}

/// Итоги периода (`TransactionsSummary`; только cashier, senior_seller, admin, owner).
final class TransactionsSummary {
  const TransactionsSummary({required this.count, required this.sumIn, required this.sumOut});

  final int count;
  final Money sumIn;
  final Money sumOut;
}

/// Страница журнала (+ `summary`, если роли разрешено).
final class TransactionsPage {
  const TransactionsPage({required this.page, this.summary});

  final PageResult<Transaction> page;
  final TransactionsSummary? summary;
}

/// Деталь транзакции (`TransactionsDetail` = Transaction + `audit[]` для admin/owner) — SCR-37.
final class TransactionDetail {
  const TransactionDetail({required this.transaction, this.audit = const <AuditRecord>[]});

  final Transaction transaction;

  /// Журнал изменений (только admin, owner; прочим ролям — пусто).
  final List<AuditRecord> audit;
}
