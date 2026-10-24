// DTO-кодеки отчётов (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): `AdminReportsSalesSummary`,
// `AdminReportsSalesSummaryRow`, `AdminReportsSalesSummaryTotals`, `AdminReportsSalesByMethod`, `AdminReportsPeriod`,
// `AdminReportsReceivables`, `AdminReportsQrReconciliation`, `AdminReportsQrReconciliationRow`.
// Сверка ключей — test/features/reports/data/reports_dtos_contract_test.dart.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/features/reports/domain/entities/reports.dart';

/// `AdminReportsPeriod`.
abstract final class ReportPeriodDto {
  static const Set<String> jsonKeys = {'from', 'to'};
  static const Set<String> requiredKeys = {'from', 'to'};

  static ReportPeriod fromJson(JsonMap j) => ReportPeriod(from: jReqDate(j, 'from'), to: jReqDate(j, 'to'));
}

/// `AdminReportsSalesByMethod`.
abstract final class SalesByMethodDto {
  static const Set<String> jsonKeys = {'cash', 'qr_bakai', 'credit'};
  static const Set<String> requiredKeys = <String>{};

  static SalesByMethod fromJson(JsonMap j) =>
      SalesByMethod(cash: jMoney(j, 'cash'), qrBakai: jMoney(j, 'qr_bakai'), credit: jMoney(j, 'credit'));
}

/// `AdminReportsSalesSummaryTotals` (показатели строки без `key`).
abstract final class SalesSummaryFiguresDto {
  static const Set<String> jsonKeys = {
    'ordersCount',
    'ordersTotal',
    'paidTotal',
    'byMethod',
    'discountTotal',
    'cancelledCount',
  };
  static const Set<String> requiredKeys = <String>{};

  static SalesSummaryFigures fromJson(JsonMap j) {
    final JsonMap? byMethod = jObject(j, 'byMethod');
    return SalesSummaryFigures(
      ordersCount: jInt(j, 'ordersCount'),
      ordersTotal: jMoney(j, 'ordersTotal'),
      paidTotal: jMoney(j, 'paidTotal'),
      byMethod: byMethod == null ? null : SalesByMethodDto.fromJson(byMethod),
      discountTotal: jMoney(j, 'discountTotal'),
      cancelledCount: jInt(j, 'cancelledCount'),
    );
  }
}

/// `AdminReportsSalesSummaryRow` (= `key` + показатели).
abstract final class SalesSummaryRowDto {
  static const Set<String> jsonKeys = {'key', ...SalesSummaryFiguresDto.jsonKeys};
  static const Set<String> requiredKeys = {'key'};

  static SalesSummaryRow fromJson(JsonMap j) =>
      SalesSummaryRow(key: jReq<String>(j, 'key'), figures: SalesSummaryFiguresDto.fromJson(j));
}

/// `AdminReportsSalesSummary`.
abstract final class SalesSummaryReportDto {
  static const Set<String> jsonKeys = {'period', 'rows', 'totals', 'source'};
  static const Set<String> requiredKeys = {'period', 'rows', 'source'};

  static SalesSummaryReport fromJson(JsonMap j) {
    final JsonMap? totals = jObject(j, 'totals');
    return SalesSummaryReport(
      period: ReportPeriodDto.fromJson(jReqObject(j, 'period')),
      rows: jObjects(j, 'rows', SalesSummaryRowDto.fromJson, required: true),
      totals: totals == null ? null : SalesSummaryFiguresDto.fromJson(totals),
      source: jReq<String>(j, 'source'),
    );
  }
}

/// `AdminReportsReceivables`.
abstract final class ReceivablesReportDto {
  static const Set<String> jsonKeys = {
    'asOf',
    'isStale',
    'totalBalance',
    'totalOverdue',
    'customersCount',
    'overdueCount',
  };

  /// `asOf` обязателен, но nullable.
  static const Set<String> requiredKeys = {'asOf', 'isStale'};

  static ReceivablesReport fromJson(JsonMap j) {
    if (!j.containsKey('asOf')) throw const DtoFormatException('asOf');
    return ReceivablesReport(
      asOf: jDate(j, 'asOf'),
      isStale: jReq<bool>(j, 'isStale'),
      totalBalance: jMoney(j, 'totalBalance'),
      totalOverdue: jMoney(j, 'totalOverdue'),
      customersCount: jInt(j, 'customersCount'),
      overdueCount: jInt(j, 'overdueCount'),
    );
  }
}

/// `AdminReportsQrReconciliationRow`.
abstract final class QrReconciliationRowDto {
  static const Set<String> jsonKeys = {
    'paymentId',
    'orderNumber',
    'amount',
    'bankReference',
    'confirmationKind',
    'confirmedBy',
    'confirmedAt',
    'status',
    'reviewReason',
    'bankAmount',
  };
  static const Set<String> requiredKeys = {'paymentId', 'amount', 'status'};

  static QrReconciliationRow fromJson(JsonMap j) => QrReconciliationRow(
    paymentId: jReq<String>(j, 'paymentId'),
    orderNumber: jOpt<String>(j, 'orderNumber'),
    amount: jReqMoney(j, 'amount'),
    bankReference: jOpt<String>(j, 'bankReference'),
    confirmationKind: jEnum(j, 'confirmationKind', QrConfirmationKind.tryParse),
    confirmedBy: UserRefDto.optional(j, 'confirmedBy'),
    confirmedAt: jDate(j, 'confirmedAt'),
    status: PaymentStatus.tryParse(jReq<String>(j, 'status')),
    reviewReason: jEnum(j, 'reviewReason', ReviewReason.tryParse),
    bankAmount: jMoney(j, 'bankAmount'),
  );
}

/// `AdminReportsQrReconciliation`.
abstract final class QrReconciliationReportDto {
  static const Set<String> jsonKeys = {'period', 'rows', 'summary'};
  static const Set<String> requiredKeys = {'period', 'rows', 'summary'};
  static const Set<String> summaryKeys = {'webhook', 'manual', 'unmatched'};

  static QrReconciliationReport fromJson(JsonMap j) {
    final JsonMap s = jReqObject(j, 'summary');
    return QrReconciliationReport(
      period: ReportPeriodDto.fromJson(jReqObject(j, 'period')),
      rows: jObjects(j, 'rows', QrReconciliationRowDto.fromJson, required: true),
      summary: QrReconciliationSummary(
        webhook: jInt(s, 'webhook') ?? 0,
        manual: jInt(s, 'manual') ?? 0,
        unmatched: jInt(s, 'unmatched') ?? 0,
      ),
    );
  }
}
