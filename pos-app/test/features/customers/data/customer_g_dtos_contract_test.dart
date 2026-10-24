// Этап G (основа), ADR-085: DTO клиентов этапа G == contracts/openapi/pos-api.v1.yaml 1.2.0 (карточка с `contacts`,
// `discounts`, `links`; долги; история; скидки; избранные клиенты); репозитории строят запросы по контракту, долг
// кладётся только в память сессии (CASH-015), fail-closed разбор снимка без сальдо.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/customers/data/dto/customer_dtos.dart';
import 'package:optomstroy/features/customers/data/dto/customer_g_dtos.dart';
import 'package:optomstroy/features/customers/data/repositories/dio_customer_g_repositories.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_history.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/favorite_customers_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/receivables_repository.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../support/openapi_schemas.dart';

const List<String> _schemas = <String>[
  'Customer',
  'CustomersListItem',
  'CustomerContact',
  'CustomerLink',
  'CustomersLinkWithUser',
  'CustomersLinkUser',
  'DiscountRule',
  'CustomersCreditTerms',
  'CustomersDiscountsResponse',
  'DiscountsRulesResponse',
  'Receivable',
  'ReceivableDocument',
  'ReceivablesOverdueItem',
  'CustomerHistory',
  'CustomersHistoryEntry',
  'CustomersHistorySummary',
];

const List<String> _responses = <String>['/receivables/overdue get 200', '/favorites/customers get 200'];

Dio _dio(FakeAdapter adapter) => Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;

Map<String, Object?> _receivableJson({
  Object? balance = const <String, String>{'amount': '1500.00', 'currency': 'KGS'},
}) => <String, Object?>{
  'customerId': 'c1',
  'balance': balance,
  'overdueAmount': <String, String>{'amount': '0.00', 'currency': 'KGS'},
  'asOf': '2026-10-24T08:00:00Z',
  'isStale': false,
};

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(_schemas, responses: _responses);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required) {
    expect(keys, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('ключи и обязательные поля == схемы OpenAPI 1.2.0', () {
    matches('Customer', CustomerDto.jsonKeys, CustomerDto.requiredKeys);
    matches('CustomersListItem', CustomerDto.jsonKeys, CustomerDto.requiredKeys);
    expect(CustomerDto.ignoredKeys, isEmpty, reason: 'этап G: все поля Customer переносятся');
    matches('CustomerContact', CustomerContactDto.jsonKeys, CustomerContactDto.requiredKeys);
    matches('CustomerLink', CustomerLinkDto.jsonKeys, CustomerLinkDto.requiredKeys);
    matches('CustomersLinkWithUser', CustomerLinkDto.withUserKeys, CustomerLinkDto.withUserRequiredKeys);
    matches('CustomersLinkUser', CustomerLinkUserDto.jsonKeys, CustomerLinkUserDto.requiredKeys);
    matches('DiscountRule', DiscountRuleDto.jsonKeys, DiscountRuleDto.requiredKeys);
    matches('CustomersCreditTerms', CustomerCreditTermsDto.jsonKeys, CustomerCreditTermsDto.requiredKeys);
    matches('CustomersDiscountsResponse', CustomerDiscountsDto.jsonKeys, CustomerDiscountsDto.requiredKeys);
    matches('DiscountsRulesResponse', DiscountRulesDto.jsonKeys, DiscountRulesDto.requiredKeys);
    matches('Receivable', ReceivableDto.jsonKeys, ReceivableDto.requiredKeys);
    matches('ReceivableDocument', ReceivableDocumentDto.jsonKeys, ReceivableDocumentDto.requiredKeys);
    matches('ReceivablesOverdueItem', OverdueReceivableDto.jsonKeys, OverdueReceivableDto.requiredKeys);
    matches('CustomerHistory', CustomerHistoryDto.jsonKeys, CustomerHistoryDto.requiredKeys);
    matches('CustomersHistoryEntry', CustomerHistoryEntryDto.jsonKeys, CustomerHistoryEntryDto.requiredKeys);
    matches('CustomersHistorySummary', CustomerHistorySummaryDto.jsonKeys, CustomerHistorySummaryDto.requiredKeys);
    expect(OverdueReceivableDto.pageKeys, api!.responseProps('/receivables/overdue get 200'));
    expect(FavoriteCustomersPageDto.jsonKeys, api.responseProps('/favorites/customers get 200'));
  }, skip: skip);

  test('примеры схем разбираются (карточка с include, долг, история, скидки)', () {
    final Customer card = CustomerDto.fromJson(jsonCopy(api!.example('Customer')));
    expect(card.contacts.single.kind, ContactKind.phone);
    expect(card.discounts, isNotNull);
    expect(card.discounts!.rules, isNotEmpty);
    expect(card.links.single.status, CustomerLinkStatus.proposed);
    final Customer listItem = CustomerDto.fromJson(jsonCopy(api.example('CustomersListItem')));
    expect(listItem.links.single.user, isNotNull);
    final Receivable r = ReceivableDto.fromJson(jsonCopy(api.example('Receivable')));
    expect(r.balance, isA<Money>());
    expect(r.documents, isNotEmpty);
    expect(r.reason, ReceivableAbsenceReason.notInOnec);
    final CustomerHistory h = CustomerHistoryDto.fromJson(jsonCopy(api.example('CustomerHistory')));
    expect(h.page.items.single.kind, CustomerHistoryKind.order);
    expect(h.summary.total, isA<Money>());
    expect(CustomerDiscountsDto.fromJson(jsonCopy(api.example('CustomersDiscountsResponse'))).creditTerms, isNotNull);
    expect(DiscountRulesDto.fromJson(jsonCopy(api.example('DiscountsRulesResponse'))).rules, isNotEmpty);
    expect(
      OverdueReceivableDto.pageFromJson(jsonCopy(api.responseExample('/receivables/overdue get 200'))).isStale,
      isTrue,
    );
  }, skip: skip);

  test('fail-closed: снимок без сальдо и без метки — «нет данных», а не «0»; без ключей — ошибка формата', () {
    final Receivable none = ReceivableDto.fromJson(<String, dynamic>{
      'customerId': 'c1',
      'balance': null,
      'asOf': null,
      'reason': 'not_in_onec',
    });
    expect((none.balance, none.asOf, none.isCompleteAndFresh), (null, null, false));
    expect(() => ReceivableDto.fromJson(<String, dynamic>{'customerId': 'c1'}), throwsA(anything));
    final Receivable incomplete = ReceivableDto.fromJson(<String, dynamic>{
      ..._receivableJson(),
      'overdueAmount': null,
    });
    expect(incomplete.isCompleteAndFresh, isFalse, reason: 'просрочка неизвестна — ядро §22.4 шаг 3');
    expect(ReceivableDto.fromJson(jsonCopy(_receivableJson().cast<String, dynamic>())).isCompleteAndFresh, isTrue);
  });

  test('долг: GET с include=documents и step-up токеном; ответ — только в памяти сессии (CASH-015)', () async {
    late RequestOptions seen;
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
      seen = o;
      return json(200, _receivableJson());
    });
    final InMemoryCustomerFinanceMemory memory = InMemoryCustomerFinanceMemory();
    final DioReceivablesRepository repo = DioReceivablesRepository(_dio(adapter), memory);
    final Result<Receivable> r = await repo.get('c1', withDocuments: true, stepUpToken: 'su-1');
    expect(r.isSuccess, isTrue);
    expect(adapter.requests.single.path, '/customers/c1/receivables');
    expect(seen.uri.queryParameters['include'], 'documents');
    expect(adapter.requests.single.headers[ApiHeaders.stepUpToken], 'su-1');
    expect(memory.receivable('c1')!.balance, const Money(150000));
    memory.clear();
    expect(memory.receivable('c1'), isNull);
  });

  test('«Обновить»: POST /customers/{id}/receivables/refresh; 429 — Failure, память не меняется', () async {
    final FakeAdapter adapter = FakeAdapter(
      (RequestOptions o) async =>
          json(429, problem('RATE_LIMITED', 429), headers: <String, String>{'Retry-After': '30'}),
    );
    final InMemoryCustomerFinanceMemory memory = InMemoryCustomerFinanceMemory();
    final Result<Receivable> r = await DioReceivablesRepository(
      _dio(adapter),
      memory,
    ).refresh('c1', idempotencyKey: 'k');
    expect(r.isSuccess, isFalse);
    expect(adapter.requests.single.method, 'POST');
    expect(adapter.requests.single.path, '/customers/c1/receivables/refresh');
    expect(memory.receivable('c1'), isNull);
  });

  test('справочник: GET /customers — массивы query повтором ключа; карточка с include', () async {
    final List<RequestOptions> seen = <RequestOptions>[];
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
      seen.add(o);
      if (o.path.endsWith('/customers')) {
        return json(200, <String, Object?>{'items': <Object?>[], 'nextCursor': null, 'hasMore': false});
      }
      return json(200, <String, Object?>{'id': 'c1', 'name': 'Асанов'});
    });
    final DioCustomerDirectoryRepository repo = DioCustomerDirectoryRepository(_dio(adapter));
    await repo.list(
      const CustomersListQuery(
        q: '0555',
        favoriteOnly: true,
        hasDebt: true,
        linkStatuses: <CustomerLinkStatus>{CustomerLinkStatus.proposed, CustomerLinkStatus.conflict},
        withReceivable: true,
        sort: CustomersSort.nameAsc,
      ),
    );
    final Map<String, List<String>> q = seen.first.uri.queryParametersAll;
    expect(q['linkStatus'], <String>['proposed', 'conflict']);
    expect(q['favorite'], <String>['true']);
    expect(q['hasDebt'], <String>['true']);
    expect(q['include'], <String>['receivable']);
    expect(q['sort'], <String>['name:asc']);
    await repo.card('c1', include: const <CustomerInclude>{CustomerInclude.discounts, CustomerInclude.contacts});
    expect(seen.last.uri.queryParametersAll['include'], <String>['discounts', 'contacts']);
  });

  test('избранные клиенты: лимит 12, PUT/DELETE /favorites/customers/{id}', () async {
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async => json(204, null));
    final DioFavoriteCustomersRepository repo = DioFavoriteCustomersRepository(_dio(adapter));
    expect(FavoriteCustomersRepository.maxFavorites, 12);
    expect((await repo.add('c1', idempotencyKey: 'k1')).isSuccess, isTrue);
    expect((await repo.remove('c1')).isSuccess, isTrue);
    expect(adapter.requests.map((r) => '${r.method} ${r.path}'), <String>[
      'PUT /favorites/customers/c1',
      'DELETE /favorites/customers/c1',
    ]);
  });
}
