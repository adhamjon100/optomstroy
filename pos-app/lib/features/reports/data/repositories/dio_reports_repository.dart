// `ReportsRepository` поверх единственного Dio-клиента. Ошибки → Failure только через ErrorMapper (06 §6.8).
// `format` не передаётся (по умолчанию `json`; CSV — R2, Q-217).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/transaction_dtos.dart' show isoUtc;
import 'package:optomstroy/features/reports/data/dto/reports_dtos.dart';
import 'package:optomstroy/features/reports/domain/entities/reports.dart';
import 'package:optomstroy/features/reports/domain/repositories/reports_repository.dart';

/// Пути API отчётов (08 §4.18.8).
abstract final class ReportsApiPaths {
  static const String salesSummary = '/admin/reports/sales-summary';
  static const String receivables = '/admin/reports/receivables';
  static const String qrReconciliation = '/admin/reports/qr-reconciliation';
}

final class DioReportsRepository implements ReportsRepository {
  DioReportsRepository(this._dio);

  final Dio _dio;

  static Map<String, Object?> _period(JournalPeriod? p) => <String, Object?>{
    if (p != null) 'from': isoUtc(p.from),
    if (p != null) 'to': isoUtc(p.to),
  };

  @override
  Future<Result<SalesSummaryReport>> salesSummary({JournalPeriod? period, SalesGroupBy groupBy = SalesGroupBy.day}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.get<Object?>(
          ReportsApiPaths.salesSummary,
          queryParameters: <String, Object?>{..._period(period), 'groupBy': groupBy.value},
          options: apiOptions(),
        );
        return SalesSummaryReportDto.fromJson(jsonObject(r.data));
      });

  @override
  Future<Result<ReceivablesReport>> receivables({bool asOfOnly = false}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      ReportsApiPaths.receivables,
      queryParameters: <String, Object?>{if (asOfOnly) 'asOfOnly': true},
      options: apiOptions(),
    );
    return ReceivablesReportDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<QrReconciliationReport>> qrReconciliation({
    JournalPeriod? period,
    QrReconciliationFilter filter = QrReconciliationFilter.all,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      ReportsApiPaths.qrReconciliation,
      queryParameters: <String, Object?>{..._period(period), 'status': filter.value},
      options: apiOptions(),
    );
    return QrReconciliationReportDto.fromJson(jsonObject(r.data));
  });
}
