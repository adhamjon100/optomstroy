// Этап G (основа), ADR-085: DTO отчётов руководителя == contracts/openapi/pos-api.v1.yaml 1.2.0; запросы без
// `format` (CSV — R2, Q-217).
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/reports/data/dto/reports_dtos.dart';
import 'package:optomstroy/features/reports/data/repositories/dio_reports_repository.dart';
import 'package:optomstroy/features/reports/domain/entities/reports.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../support/openapi_schemas.dart';

const List<String> _schemas = <String>[
  'AdminReportsPeriod',
  'AdminReportsSalesByMethod',
  'AdminReportsSalesSummaryRow',
  'AdminReportsSalesSummaryTotals',
  'AdminReportsSalesSummary',
  'AdminReportsReceivables',
  'AdminReportsQrReconciliationRow',
  'AdminReportsQrReconciliation',
];

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(_schemas);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required) {
    expect(keys, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('ключи и обязательные поля == схемы OpenAPI 1.2.0', () {
    matches('AdminReportsPeriod', ReportPeriodDto.jsonKeys, ReportPeriodDto.requiredKeys);
    matches('AdminReportsSalesByMethod', SalesByMethodDto.jsonKeys, SalesByMethodDto.requiredKeys);
    matches('AdminReportsSalesSummaryRow', SalesSummaryRowDto.jsonKeys, SalesSummaryRowDto.requiredKeys);
    matches('AdminReportsSalesSummaryTotals', SalesSummaryFiguresDto.jsonKeys, SalesSummaryFiguresDto.requiredKeys);
    matches('AdminReportsSalesSummary', SalesSummaryReportDto.jsonKeys, SalesSummaryReportDto.requiredKeys);
    matches('AdminReportsReceivables', ReceivablesReportDto.jsonKeys, ReceivablesReportDto.requiredKeys);
    matches('AdminReportsQrReconciliationRow', QrReconciliationRowDto.jsonKeys, QrReconciliationRowDto.requiredKeys);
    matches('AdminReportsQrReconciliation', QrReconciliationReportDto.jsonKeys, QrReconciliationReportDto.requiredKeys);
  }, skip: skip);

  test('примеры разбираются', () {
    final SalesSummaryReport sales = SalesSummaryReportDto.fromJson(jsonCopy(api!.example('AdminReportsSalesSummary')));
    expect(sales.rows.single.figures.byMethod!.qrBakai, isA<Money>());
    expect(sales.source, 'pos');
    final ReceivablesReport debts = ReceivablesReportDto.fromJson(jsonCopy(api.example('AdminReportsReceivables')));
    expect(debts.totalBalance, isA<Money>());
    final QrReconciliationReport qr = QrReconciliationReportDto.fromJson(
      jsonCopy(api.example('AdminReportsQrReconciliation')),
    );
    expect(qr.rows.single.status, PaymentStatus.initiated);
  }, skip: skip);

  test('запросы: groupBy/status по контракту, format не передаётся', () async {
    final List<RequestOptions> seen = <RequestOptions>[];
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
      seen.add(o);
      return json(200, <String, Object?>{
        'period': <String, String>{'from': '2026-10-01T00:00:00Z', 'to': '2026-10-24T00:00:00Z'},
        'rows': <Object?>[],
        'source': 'pos',
        'summary': <String, int>{'webhook': 0, 'manual': 1, 'unmatched': 2},
      });
    });
    final DioReportsRepository repo = DioReportsRepository(
      Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter,
    );
    final JournalPeriod period = JournalPeriod.tryCreate(DateTime.utc(2026, 10), DateTime.utc(2026, 10, 24))!;
    await repo.salesSummary(period: period, groupBy: SalesGroupBy.paymentMethod);
    final QrReconciliationReport qr = (await repo.qrReconciliation(
      filter: QrReconciliationFilter.unmatched,
    )).valueOrNull!;
    expect(qr.summary.unmatched, 2);
    expect(seen.first.uri.queryParameters['groupBy'], 'paymentMethod');
    expect(seen.last.uri.queryParameters['status'], 'unmatched');
    for (final RequestOptions o in seen) {
      expect(o.uri.queryParameters.containsKey('format'), isFalse, reason: o.uri.path);
    }
  });
}
