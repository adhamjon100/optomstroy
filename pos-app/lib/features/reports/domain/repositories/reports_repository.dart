// Порт отчётов руководителя SCR-48 (08 §4.18.8; права — `reports.*.read`: owner, admin). Только онлайн; период —
// не длиннее 366 дней (`JournalPeriod`). Экспорт CSV — R2 (Q-217). Чистый Dart (FL-01).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/features/reports/domain/entities/reports.dart';

abstract interface class ReportsRepository {
  /// `GET /admin/reports/sales-summary?from=&to=&groupBy=`.
  Future<Result<SalesSummaryReport>> salesSummary({JournalPeriod? period, SalesGroupBy groupBy = SalesGroupBy.day});

  /// `GET /admin/reports/receivables?asOfOnly=`.
  Future<Result<ReceivablesReport>> receivables({bool asOfOnly = false});

  /// `GET /admin/reports/qr-reconciliation?from=&to=&status=`.
  Future<Result<QrReconciliationReport>> qrReconciliation({
    JournalPeriod? period,
    QrReconciliationFilter filter = QrReconciliationFilter.all,
  });
}
