// Этап G (основа), ADR-085: DTO дашборда кассира `PosDashboard` == contracts/openapi/pos-api.v1.yaml 1.2.0;
// вложенные `OrderSummary`/`Payment`/`Customer` разбирают кодеки фич orders/customers через порты (FL-06).
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cashier/data/dto/pos_dashboard_dtos.dart';
import 'package:optomstroy/features/cashier/data/repositories/dio_cashier_repository.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/customers/data/customers_bindings.dart';
import 'package:optomstroy/features/orders/data/orders_bindings.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../support/openapi_schemas.dart';

const OrderDtoDecoder _orders = OrderDtoDecoder();
const CustomerDtoDecoder _customers = CustomerDtoDecoder();
final DashboardDecoders _decoders = DashboardDecoders(
  customer: _customers.decode,
  orderSummary: _orders.summary,
  payment: _orders.payment,
);

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(const <String>[
    'PosDashboard',
    'PosDashboardTotals',
    'PosDashboardOverdueItem',
    'PosDashboardSync',
  ]);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required) {
    expect(keys, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('ключи и обязательные поля == схемы OpenAPI 1.2.0', () {
    matches('PosDashboard', PosDashboardDto.jsonKeys, PosDashboardDto.requiredKeys);
    matches('PosDashboardTotals', PosDashboardTotalsDto.jsonKeys, PosDashboardTotalsDto.requiredKeys);
    matches('PosDashboardOverdueItem', PosDashboardOverdueItemDto.jsonKeys, PosDashboardOverdueItemDto.requiredKeys);
    matches('PosDashboardSync', PosDashboardSyncDto.jsonKeys, PosDashboardSyncDto.requiredKeys);
  }, skip: skip);

  test('пример PosDashboard разбирается целиком (ожидают оплаты, QR, долги, избранные, операции)', () {
    final PosDashboard d = PosDashboardDto.fromJson(jsonCopy(api!.example('PosDashboard')), _decoders);
    expect(d.totals.cash, isA<Money>());
    expect(d.awaitingPayment.single.id, isNotEmpty);
    expect(d.qrPending.single.amount, isA<Money>());
    expect(d.overdue.single.customer.id, isNotEmpty);
    expect(d.favoriteCustomers.single.id, isNotEmpty);
    expect(d.recentTransactions.single.number, isNotEmpty);
    expect(d.sync.overall, DashboardSyncOverall.ok);
  }, skip: skip);

  test('поля по роли отсутствуют (admin: без qrPending/manualConfirm) — пустые списки; date — YYYY-MM-DD', () async {
    late RequestOptions seen;
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
      seen = o;
      return json(200, <String, Object?>{
        'date': '2026-10-24',
        'totals': <String, Object?>{
          'cash': <String, String>{'amount': '0.00', 'currency': 'KGS'},
          'qr': <String, String>{'amount': '0.00', 'currency': 'KGS'},
          'credit': <String, String>{'amount': '0.00', 'currency': 'KGS'},
          'ordersCount': 0,
          'paymentsCount': 0,
        },
        'awaitingPayment': <Object?>[],
        'qrPendingCount': 0,
        'manualConfirmCount': 0,
        'recentTransactions': <Object?>[],
        'sync': <String, Object?>{'overall': 'degraded'},
        'notificationsUnread': 3,
      });
    });
    final Dio dio = Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;
    final Result<PosDashboard> r = await DioCashierRepository(dio, _decoders).dashboard(date: DateTime(2026, 10, 24));
    final PosDashboard d = r.valueOrNull!;
    expect(d.qrPending, isEmpty);
    expect(d.manualConfirm, isEmpty);
    expect(d.favoriteCustomers, isEmpty);
    expect(d.overdue, isEmpty);
    expect(d.sync.overall, DashboardSyncOverall.degraded);
    expect(seen.uri.path, '/api/v1/pos/dashboard');
    expect(seen.uri.queryParameters['date'], '2026-10-24');
  });
}
