// DTO-кодеки дашборда кассира (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): `PosDashboard`,
// `PosDashboardTotals`, `PosDashboardOverdueItem`, `PosDashboardSync`. Вложенные `OrderSummary`/`Payment` и
// `Customer` разбирают кодеки фич orders и customers через их порты (FL-06): [PosDashboardDto.fromJson] получает
// функции разбора. Сверка ключей — test/features/cashier/data/pos_dashboard_dtos_contract_test.dart.
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/models/transaction_dtos.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// Разборщики вложенных схем других фич.
final class DashboardDecoders {
  const DashboardDecoders({required this.customer, required this.orderSummary, required this.payment});

  final Customer Function(JsonMap json) customer;
  final OrderSummary Function(JsonMap json) orderSummary;
  final Payment Function(JsonMap json) payment;
}

/// `PosDashboardTotals`.
abstract final class PosDashboardTotalsDto {
  static const Set<String> jsonKeys = {'cash', 'qr', 'credit', 'ordersCount', 'paymentsCount'};
  static const Set<String> requiredKeys = jsonKeys;

  static PosDashboardTotals fromJson(JsonMap j) => PosDashboardTotals(
    cash: jReqMoney(j, 'cash'),
    qr: jReqMoney(j, 'qr'),
    credit: jReqMoney(j, 'credit'),
    ordersCount: jReqInt(j, 'ordersCount'),
    paymentsCount: jReqInt(j, 'paymentsCount'),
  );
}

/// `PosDashboardOverdueItem`.
abstract final class PosDashboardOverdueItemDto {
  static const Set<String> jsonKeys = {'customer', 'overdueAmount', 'overdueDays', 'asOf'};
  static const Set<String> requiredKeys = jsonKeys;

  static PosDashboardOverdueItem fromJson(JsonMap j, Customer Function(JsonMap json) customer) =>
      PosDashboardOverdueItem(
        customer: customer(jReqObject(j, 'customer')),
        overdueAmount: jReqMoney(j, 'overdueAmount'),
        overdueDays: jReqInt(j, 'overdueDays'),
        asOf: jReqDate(j, 'asOf'),
      );
}

/// `PosDashboardSync`.
abstract final class PosDashboardSyncDto {
  static const Set<String> jsonKeys = {'receivablesAsOf', 'stockAsOf', 'overall'};
  static const Set<String> requiredKeys = {'overall'};

  static PosDashboardSync fromJson(JsonMap j) => PosDashboardSync(
    overall: DashboardSyncOverall.tryParse(jReq<String>(j, 'overall')),
    receivablesAsOf: jDate(j, 'receivablesAsOf'),
    stockAsOf: jDate(j, 'stockAsOf'),
  );
}

/// `PosDashboard`.
abstract final class PosDashboardDto {
  static const Set<String> jsonKeys = {
    'date',
    'totals',
    'awaitingPayment',
    'qrPending',
    'manualConfirm',
    'qrPendingCount',
    'manualConfirmCount',
    'overdue',
    'favoriteCustomers',
    'recentTransactions',
    'sync',
    'notificationsUnread',
  };
  static const Set<String> requiredKeys = {
    'date',
    'totals',
    'awaitingPayment',
    'qrPendingCount',
    'manualConfirmCount',
    'recentTransactions',
    'sync',
    'notificationsUnread',
  };

  static PosDashboard fromJson(JsonMap j, DashboardDecoders d) => PosDashboard(
    date: jReqDate(j, 'date'),
    totals: PosDashboardTotalsDto.fromJson(jReqObject(j, 'totals')),
    awaitingPayment: jObjects(j, 'awaitingPayment', d.orderSummary, required: true),
    qrPending: jObjects(j, 'qrPending', d.payment),
    manualConfirm: jObjects(j, 'manualConfirm', d.payment),
    qrPendingCount: jReqInt(j, 'qrPendingCount'),
    manualConfirmCount: jReqInt(j, 'manualConfirmCount'),
    overdue: jObjects(j, 'overdue', (JsonMap o) => PosDashboardOverdueItemDto.fromJson(o, d.customer)),
    favoriteCustomers: jObjects(j, 'favoriteCustomers', d.customer),
    recentTransactions: jObjects(j, 'recentTransactions', TransactionDto.fromJson, required: true),
    sync: PosDashboardSyncDto.fromJson(jReqObject(j, 'sync')),
    notificationsUnread: jReqInt(j, 'notificationsUnread'),
  );
}
