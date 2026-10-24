// Дашборд кассира SCR-30 (08 §4.16 `GET /pos/dashboard` → `PosDashboard`; 10 CASH-; RM-G-004, RM-G-007).
// Блок «Ожидают оплаты» — заказы `submitting`, `pending_approval`, `approved`, `awaiting_payment` с открытым платежом
// (ядро §23 п. 7, §22.5). Поля по роли (`x-roles`): `qrPending`/`manualConfirm` — cashier, senior_seller, owner;
// `overdue` — cashier+; `favoriteCustomers` — cashier, senior_seller, admin. Финансовые данные — только память
// (CASH-015). Чистый Dart (FL-01).
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// Итоги дня (`PosDashboardTotals`).
final class PosDashboardTotals {
  const PosDashboardTotals({
    required this.cash,
    required this.qr,
    required this.credit,
    required this.ordersCount,
    required this.paymentsCount,
  });

  final Money cash;
  final Money qr;
  final Money credit;
  final int ordersCount;
  final int paymentsCount;
}

/// Строка блока «Долги и просрочки» (`PosDashboardOverdueItem`).
final class PosDashboardOverdueItem {
  const PosDashboardOverdueItem({
    required this.customer,
    required this.overdueAmount,
    required this.overdueDays,
    required this.asOf,
  });

  final Customer customer;
  final Money overdueAmount;
  final int overdueDays;
  final DateTime asOf;
}

/// Общее состояние синхронизации (`PosDashboardSync.overall`).
enum DashboardSyncOverall {
  ok('ok'),
  degraded('degraded'),
  failed('failed');

  const DashboardSyncOverall(this.value);

  final String value;

  static DashboardSyncOverall? tryParse(String? value) {
    for (final DashboardSyncOverall s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// Блок «Синхронизация с 1С» (`PosDashboardSync`).
final class PosDashboardSync {
  const PosDashboardSync({required this.overall, this.receivablesAsOf, this.stockAsOf});

  /// `null` — значение, неизвестное клиенту (показывается как `degraded`).
  final DashboardSyncOverall? overall;
  final DateTime? receivablesAsOf;
  final DateTime? stockAsOf;
}

/// Дашборд кассира (`PosDashboard`).
final class PosDashboard {
  const PosDashboard({
    required this.date,
    required this.totals,
    required this.awaitingPayment,
    required this.qrPendingCount,
    required this.manualConfirmCount,
    required this.recentTransactions,
    required this.sync,
    required this.notificationsUnread,
    this.qrPending = const <Payment>[],
    this.manualConfirm = const <Payment>[],
    this.overdue = const <PosDashboardOverdueItem>[],
    this.favoriteCustomers = const <Customer>[],
  });

  final DateTime date;
  final PosDashboardTotals totals;

  /// «Ожидают оплаты» (≤ 20).
  final List<OrderSummary> awaitingPayment;
  final List<Payment> qrPending;
  final List<Payment> manualConfirm;
  final int qrPendingCount;
  final int manualConfirmCount;

  /// «Долги и просрочки» (≤ 10).
  final List<PosDashboardOverdueItem> overdue;

  /// «Избранные клиенты» (≤ 12).
  final List<Customer> favoriteCustomers;

  /// «Недавние операции» (≤ 10).
  final List<Transaction> recentTransactions;
  final PosDashboardSync sync;
  final int notificationsUnread;
}
