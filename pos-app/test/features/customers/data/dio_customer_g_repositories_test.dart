// Репозитории клиентов этапа G поверх Dio (08 §4.11–§4.14; RM-G-009 п. 2 — покрытие data ≥ 80 %; ревью G-trace-12):
// история покупок (`GET /customers/{id}/orders` — период, источник, курсор), скидки клиента, правила скидок,
// просрочки (`GET /receivables/overdue` — фильтры и сортировка), избранные клиенты (страница с `count`), отмена
// устаревшего запроса. Ответы — примеры схем contracts/openapi/pos-api.v1.yaml 1.2.0.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/customers/data/repositories/dio_customer_g_repositories.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_history.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/favorite_customers_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/receivables_repository.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../support/openapi_schemas.dart';

const List<String> _schemas = <String>['CustomerHistory', 'CustomersDiscountsResponse', 'DiscountsRulesResponse'];
const List<String> _responses = <String>['/receivables/overdue get 200', '/favorites/customers get 200'];

Dio _dio(FakeAdapter adapter) => Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(_schemas, responses: _responses);
  final String? skip = api == null ? 'нет python с PyYAML — примеры схем недоступны' : null;
  late List<RequestOptions> seen;

  FakeAdapter adapter(Object? Function(RequestOptions o) body, {int status = 200}) {
    seen = <RequestOptions>[];
    return FakeAdapter((RequestOptions o) async {
      seen.add(o);
      return json(status, body(o));
    });
  }

  test('история: период, источник, лимит, курсор; разбор CustomerHistory', () async {
    final DioCustomerDirectoryRepository repo = DioCustomerDirectoryRepository(
      _dio(adapter((_) => jsonCopy(api!.example('CustomerHistory')))),
    );
    final Result<CustomerHistory> r = await repo.history(
      'c 1',
      CustomerHistoryQuery(
        from: DateTime.utc(2026, 7, 24),
        to: DateTime.utc(2026, 10, 22),
        source: CustomerHistorySource.onec,
        limit: 50,
        cursor: 'c2',
      ),
    );
    expect(seen.single.uri.path, '/api/v1/customers/c%201/orders');
    final Map<String, String> q = seen.single.uri.queryParameters;
    expect(q['from'], startsWith('2026-07-24T00:00:00'));
    expect(q['to'], startsWith('2026-10-22T00:00:00'));
    expect(q['source'], 'onec');
    expect(q['limit'], '50');
    expect(q['cursor'], 'c2');
    expect(r.valueOrNull, isNotNull);
  }, skip: skip);

  test('скидки клиента и правила скидок (customerId, cartId)', () async {
    final DioCustomerDirectoryRepository repo = DioCustomerDirectoryRepository(
      _dio(
        adapter(
          (RequestOptions o) => o.uri.path.endsWith('/discounts')
              ? jsonCopy(api!.example('CustomersDiscountsResponse'))
              : jsonCopy(api!.example('DiscountsRulesResponse')),
        ),
      ),
    );
    final Result<CustomerDiscounts> d = await repo.discounts('c1');
    expect(seen.last.uri.path, '/api/v1/customers/c1/discounts');
    expect(d.valueOrNull!.creditTerms, isNotNull);
    final Result<DiscountRulesInfo> rules = await repo.discountRules(customerId: 'c1', cartId: 'cart-1');
    expect(seen.last.uri.path, '/api/v1/discounts/rules');
    expect(seen.last.uri.queryParameters, <String, String>{'customerId': 'c1', 'cartId': 'cart-1'});
    expect(rules.valueOrNull!.rules, isNotEmpty);
    await repo.discountRules();
    expect(seen.last.uri.queryParameters, isEmpty);
  }, skip: skip);

  test('просрочки: minOverdueDays, minAmount, sort, курсор; страница OverdueReceivablesPage', () async {
    final DioReceivablesRepository repo = DioReceivablesRepository(
      _dio(adapter((_) => jsonCopy(api!.responseExample('/receivables/overdue get 200')))),
      InMemoryCustomerFinanceMemory(),
    );
    final Result<OverdueReceivablesPage> r = await repo.overdue(
      const OverdueReceivablesQuery(
        minOverdueDays: 5,
        minAmount: Money(100000),
        limit: 50,
        cursor: 'c3',
        sort: OverdueSort.overdueAmountDesc,
      ),
    );
    final Map<String, String> q = seen.single.uri.queryParameters;
    expect(seen.single.uri.path, '/api/v1/receivables/overdue');
    expect(q['minOverdueDays'], '5');
    expect(q['minAmount'], '1000.00');
    expect(q['limit'], '50');
    expect(q['cursor'], 'c3');
    expect(q['sort'], OverdueSort.overdueAmountDesc.value);
    expect(r.valueOrNull, isNotNull);
  }, skip: skip);

  test('избранные клиенты: страница и count; ошибка сервера — Failure', () async {
    final DioFavoriteCustomersRepository repo = DioFavoriteCustomersRepository(
      _dio(adapter((_) => jsonCopy(api!.responseExample('/favorites/customers get 200')))),
    );
    final Result<FavoriteCustomersPage> r = await repo.list(limit: 12, cursor: 'c1');
    expect(seen.single.uri.queryParameters, <String, String>{'limit': '12', 'cursor': 'c1'});
    expect(r.valueOrNull!.count, greaterThanOrEqualTo(0));

    final DioFavoriteCustomersRepository failing = DioFavoriteCustomersRepository(
      _dio(adapter((_) => problem('INTERNAL', 500), status: 500)),
    );
    expect((await failing.list()).failureOrNull, isA<ServerFailure>());
    expect((await failing.remove('c1')).failureOrNull, isA<ServerFailure>());
  }, skip: skip);

  test('справочник: отменённый сигнал отменяет запрос (D-31) — ошибка, без ответа', () async {
    final Completer<void> never = Completer<void>();
    seen = <RequestOptions>[];
    final FakeAdapter hanging = FakeAdapter((RequestOptions o) async {
      seen.add(o);
      await never.future;
      return json(200, <String, Object?>{});
    });
    final DioCustomerDirectoryRepository repo = DioCustomerDirectoryRepository(_dio(hanging));
    final CancelSignal signal = CancelSignal()..cancel();
    final Result<Object?> r = await repo.list(const CustomersListQuery(q: 'Азамат'), cancel: signal);
    expect(r.failureOrNull, isNotNull);
  });
}
