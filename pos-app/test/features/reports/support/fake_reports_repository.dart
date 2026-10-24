// Фейк порта отчётов SCR-48 (RM-G-008): сводка продаж (заказ 16 850,00 со скидкой 5 % → 16 007,50 и 842,50 —
// пример ядра §17.2), долги по снимку 1С, QR-сверка с расхождением. Записывает запросы (разрез, фильтр, период).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/reports/domain/entities/reports.dart';
import 'package:optomstroy/features/reports/domain/repositories/reports_repository.dart';

final DateTime r0 = DateTime.utc(2026, 10, 22, 9);

const SalesSummaryFigures salesTotals = SalesSummaryFigures(
  ordersCount: 2,
  ordersTotal: Money(1650750),
  paidTotal: Money(1600750),
  byMethod: SalesByMethod(cash: Money(1000750), qrBakai: Money(600000), credit: Money(50000)),
  discountTotal: Money(84250),
  cancelledCount: 1,
);

final class FakeReportsRepository implements ReportsRepository {
  FakeReportsRepository({this.salesFailure, this.debtsFailure, this.qrFailure, this.stale = false});

  Failure? salesFailure;
  Failure? debtsFailure;
  Failure? qrFailure;
  bool stale;
  final List<SalesGroupBy> groupBys = <SalesGroupBy>[];
  final List<QrReconciliationFilter> qrFilters = <QrReconciliationFilter>[];
  final List<JournalPeriod?> periods = <JournalPeriod?>[];
  int receivablesCalls = 0;

  @override
  Future<Result<SalesSummaryReport>> salesSummary({
    JournalPeriod? period,
    SalesGroupBy groupBy = SalesGroupBy.day,
  }) async {
    groupBys.add(groupBy);
    periods.add(period);
    if (salesFailure != null) return FailureResult<SalesSummaryReport>(salesFailure!);
    final List<SalesSummaryRow> rows = switch (groupBy) {
      SalesGroupBy.day => const <SalesSummaryRow>[
        SalesSummaryRow(
          key: '2026-10-21',
          figures: SalesSummaryFigures(
            ordersCount: 1,
            ordersTotal: Money(1600750),
            paidTotal: Money(1600750),
            discountTotal: Money(84250),
          ),
        ),
        SalesSummaryRow(
          key: '2026-10-22',
          figures: SalesSummaryFigures(
            ordersCount: 1,
            ordersTotal: Money(50000),
            paidTotal: Money(0),
            discountTotal: Money(0),
          ),
        ),
      ],
      SalesGroupBy.seller => const <SalesSummaryRow>[
        SalesSummaryRow(
          key: 'seller-1',
          figures: SalesSummaryFigures(
            ordersCount: 2,
            ordersTotal: Money(1650750),
            paidTotal: Money(1600750),
            discountTotal: Money(84250),
          ),
        ),
      ],
      SalesGroupBy.paymentMethod => const <SalesSummaryRow>[
        SalesSummaryRow(
          key: 'cash',
          figures: SalesSummaryFigures(ordersCount: 1, ordersTotal: Money(1000750)),
        ),
        SalesSummaryRow(
          key: 'qr_bakai',
          figures: SalesSummaryFigures(ordersCount: 1, ordersTotal: Money(600000)),
        ),
      ],
    };
    return Success<SalesSummaryReport>(
      SalesSummaryReport(
        period: ReportPeriod(from: r0, to: r0),
        rows: rows,
        totals: salesTotals,
      ),
    );
  }

  @override
  Future<Result<ReceivablesReport>> receivables({bool asOfOnly = false}) async {
    receivablesCalls++;
    if (debtsFailure != null) return FailureResult<ReceivablesReport>(debtsFailure!);
    return Success<ReceivablesReport>(
      ReceivablesReport(
        isStale: stale,
        asOf: r0.subtract(const Duration(minutes: 20)),
        totalBalance: const Money(12500000),
        totalOverdue: const Money(2300000),
        customersCount: 14,
        overdueCount: 3,
      ),
    );
  }

  @override
  Future<Result<QrReconciliationReport>> qrReconciliation({
    JournalPeriod? period,
    QrReconciliationFilter filter = QrReconciliationFilter.all,
  }) async {
    qrFilters.add(filter);
    if (qrFailure != null) return FailureResult<QrReconciliationReport>(qrFailure!);
    final List<QrReconciliationRow> all = <QrReconciliationRow>[
      QrReconciliationRow(
        paymentId: 'p1',
        orderNumber: '1024',
        amount: const Money(600000),
        status: PaymentStatus.received,
        confirmationKind: QrConfirmationKind.webhook,
        confirmedAt: r0,
      ),
      QrReconciliationRow(
        paymentId: 'p2',
        orderNumber: '1025',
        amount: const Money(120000),
        status: PaymentStatus.manualConfirm,
        confirmationKind: QrConfirmationKind.manual,
        reviewReason: ReviewReason.noWebhook,
        confirmedBy: const UserRef(id: 'u1', displayName: 'Кассир'),
        confirmedAt: r0,
      ),
    ];
    final List<QrReconciliationRow> rows = switch (filter) {
      QrReconciliationFilter.all => all,
      QrReconciliationFilter.unmatched ||
      QrReconciliationFilter.manual => all.where((r) => r.reviewReason != null).toList(),
    };
    return Success<QrReconciliationReport>(
      QrReconciliationReport(
        period: ReportPeriod(from: r0, to: r0),
        rows: rows,
        summary: const QrReconciliationSummary(webhook: 1, manual: 1, unmatched: 1),
      ),
    );
  }
}
