// Отчёты руководителя SCR-48 (08 §4.18.8 `/admin/reports/*`; ядро §22.13 п. 3; RM-G-006): сводка продаж
// (`groupBy=day|seller|paymentMethod`, данные POS), долги без разбивки по срокам, QR-сверка. Разбивка по срокам,
// прочие разрезы и экспорт CSV — R2 (Q-217): `format=csv` клиент не запрашивает. Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';

/// Разрез сводки продаж.
enum SalesGroupBy {
  day('day'),
  seller('seller'),
  paymentMethod('paymentMethod');

  const SalesGroupBy(this.value);

  final String value;

  static SalesGroupBy? tryParse(String? value) {
    for (final SalesGroupBy g in values) {
      if (g.value == value) return g;
    }
    return null;
  }
}

/// Отчёт SCR-48 (`/reports?report=`).
enum ReportKind {
  sales('sales'),
  receivables('receivables'),
  qr('qr');

  const ReportKind(this.value);

  final String value;

  static ReportKind? tryParse(String? value) {
    for (final ReportKind k in values) {
      if (k.value == value) return k;
    }
    return null;
  }
}

/// Фильтр QR-сверки (`status=all|unmatched|manual`).
enum QrReconciliationFilter {
  all('all'),
  unmatched('unmatched'),
  manual('manual');

  const QrReconciliationFilter(this.value);

  final String value;
}

/// Период отчёта (`AdminReportsPeriod`).
final class ReportPeriod {
  const ReportPeriod({required this.from, required this.to});

  final DateTime from;
  final DateTime to;
}

/// Суммы по способам оплаты (`AdminReportsSalesByMethod`).
final class SalesByMethod {
  const SalesByMethod({this.cash, this.qrBakai, this.credit});

  final Money? cash;
  final Money? qrBakai;
  final Money? credit;
}

/// Строка / итог сводки продаж (`AdminReportsSalesSummaryRow`, `AdminReportsSalesSummaryTotals`).
final class SalesSummaryFigures {
  const SalesSummaryFigures({
    this.ordersCount,
    this.ordersTotal,
    this.paidTotal,
    this.byMethod,
    this.discountTotal,
    this.cancelledCount,
  });

  final int? ordersCount;
  final Money? ordersTotal;
  final Money? paidTotal;
  final SalesByMethod? byMethod;
  final Money? discountTotal;
  final int? cancelledCount;
}

/// Строка сводки: ключ разреза (дата `YYYY-MM-DD`, id продавца или способ оплаты) + показатели.
final class SalesSummaryRow {
  const SalesSummaryRow({required this.key, required this.figures});

  final String key;
  final SalesSummaryFigures figures;
}

/// Сводка продаж (`AdminReportsSalesSummary`).
final class SalesSummaryReport {
  const SalesSummaryReport({required this.period, required this.rows, this.totals, this.source = 'pos'});

  final ReportPeriod period;
  final List<SalesSummaryRow> rows;
  final SalesSummaryFigures? totals;

  /// Источник данных (`pos`).
  final String source;
}

/// Долги — сводно (`AdminReportsReceivables`; без разбивки по срокам).
final class ReceivablesReport {
  const ReceivablesReport({
    required this.isStale,
    this.asOf,
    this.totalBalance,
    this.totalOverdue,
    this.customersCount,
    this.overdueCount,
  });

  final DateTime? asOf;
  final bool isStale;
  final Money? totalBalance;
  final Money? totalOverdue;
  final int? customersCount;
  final int? overdueCount;
}

/// Вид подтверждения QR-платежа (`webhook|manual`).
enum QrConfirmationKind {
  webhook('webhook'),
  manual('manual');

  const QrConfirmationKind(this.value);

  final String value;

  static QrConfirmationKind? tryParse(String? value) {
    for (final QrConfirmationKind k in values) {
      if (k.value == value) return k;
    }
    return null;
  }
}

/// Строка QR-сверки (`AdminReportsQrReconciliationRow`).
final class QrReconciliationRow {
  const QrReconciliationRow({
    required this.paymentId,
    required this.amount,
    required this.status,
    this.orderNumber,
    this.bankReference,
    this.confirmationKind,
    this.confirmedBy,
    this.confirmedAt,
    this.reviewReason,
    this.bankAmount,
  });

  final String paymentId;
  final String? orderNumber;
  final Money amount;
  final String? bankReference;
  final QrConfirmationKind? confirmationKind;
  final UserRef? confirmedBy;
  final DateTime? confirmedAt;

  /// `null` — статус, неизвестный клиенту.
  final PaymentStatus? status;
  final ReviewReason? reviewReason;
  final Money? bankAmount;
}

/// Итог QR-сверки (`summary`).
final class QrReconciliationSummary {
  const QrReconciliationSummary({this.webhook = 0, this.manual = 0, this.unmatched = 0});

  final int webhook;
  final int manual;
  final int unmatched;
}

/// QR-сверка (`AdminReportsQrReconciliation`).
final class QrReconciliationReport {
  const QrReconciliationReport({required this.period, required this.rows, required this.summary});

  final ReportPeriod period;
  final List<QrReconciliationRow> rows;
  final QrReconciliationSummary summary;
}
