// ADR-085, RM-F-006 (SCR-21 CustomerPicker, SCR-26): ручные DTO клиентов == contracts/openapi/pos-api.v1.yaml 1.1.0;
// `409 CUSTOMER_DUPLICATE_SUSPECTED` → кандидаты (DuplicateCandidate), а не ошибка; тело `POST /customers` —
// `forceReason` только при `forceCreate`.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/customers/data/dto/customer_dtos.dart';
import 'package:optomstroy/features/customers/data/repositories/dio_customers_repository.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/new_customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../support/openapi_schemas.dart';

const List<String> _schemas = <String>[
  'Customer',
  'SearchCustomerItem',
  'CustomerPhone',
  'PriceListRef',
  'ReceivableSummary',
  'CustomersCreateRequest',
];

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(_schemas);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required, {Set<String> ignored = const <String>{}}) {
    expect(<String>{...keys, ...ignored}, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('ключи и обязательные поля == схемы OpenAPI', () {
    matches('Customer', CustomerDto.jsonKeys, CustomerDto.requiredKeys, ignored: CustomerDto.ignoredKeys);
    matches(
      'SearchCustomerItem',
      CustomerDto.searchItemKeys,
      CustomerDto.requiredKeys,
      ignored: CustomerDto.ignoredKeys,
    );
    matches('CustomerPhone', CustomerPhoneDto.jsonKeys, CustomerPhoneDto.requiredKeys);
    matches('PriceListRef', PriceListRefDto.jsonKeys, PriceListRefDto.requiredKeys);
    matches('ReceivableSummary', ReceivableSummaryDto.jsonKeys, ReceivableSummaryDto.requiredKeys);
    matches('CustomersCreateRequest', NewCustomerRequestDto.jsonKeys, NewCustomerRequestDto.requiredKeys);
  }, skip: skip);

  test('пример SearchCustomerItem разбирается: телефоны, вид цены, сводка долга (только память), matchType', () {
    final Customer c = CustomerDto.fromJson(jsonCopy(api!.example('SearchCustomerItem')));
    expect(c.customerType, CustomerType.individual);
    expect(c.phones.single.valueE164, '+996700000001');
    expect(c.priceList!.id, isNotEmpty);
    expect(c.discountPercent, const Percent(500));
    expect(c.receivable!.balance, const Money(1600750));
    expect(c.onecStatus, CustomerOnecStatus.nA);
    expect(c.matchType, CustomerMatchType.name);
  }, skip: skip);

  test('тело POST /customers: forceReason только при forceCreate', () {
    const NewCustomerRequest base = NewCustomerRequest(
      name: 'Тестов Клиент',
      customerType: CustomerType.individual,
      phonesE164: <String>['+996700123456'],
    );
    expect(NewCustomerRequestDto.toJson(base), <String, dynamic>{
      'name': 'Тестов Клиент',
      'customerType': 'individual',
      'phones': <String>['+996700123456'],
      'forceCreate': false,
    });
    final Map<String, dynamic> force = NewCustomerRequestDto.toJson(
      const NewCustomerRequest(
        name: 'Тестов Клиент',
        customerType: CustomerType.legal,
        phonesE164: <String>['+996700123456'],
        forceCreate: true,
        forceReason: 'другой филиал',
      ),
    );
    expect((force['forceCreate'], force['forceReason']), (true, 'другой филиал'));
  });

  test('409 CUSTOMER_DUPLICATE_SUSPECTED → кандидаты; Idempotency-Key передан', () async {
    final FakeAdapter adapter = FakeAdapter(
      (RequestOptions o) async => json(
        409,
        problem(
          'CUSTOMER_DUPLICATE_SUSPECTED',
          409,
          extra: <String, Object?>{
            'candidates': <Object?>[
              <String, Object?>{
                'id': 'c-1',
                'displayName': 'ИП Асанов',
                'phoneMasked': '+996 *** ** 12',
                'source': 'onec',
              },
            ],
          },
        ),
      ),
    );
    final Dio dio = Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;
    final Result<NewCustomerOutcome> r = await DioCustomersRepository(dio).create(
      const NewCustomerRequest(
        name: 'Асанов',
        customerType: CustomerType.entrepreneur,
        phonesE164: <String>['+996700123412'],
      ),
      idempotencyKey: 'key-1',
    );
    final NewCustomerOutcome outcome = r.valueOrNull!;
    expect(outcome, isA<NewCustomerDuplicates>());
    final DuplicateCandidate c = (outcome as NewCustomerDuplicates).candidates.single;
    expect((c.id, c.displayName, c.source), ('c-1', 'ИП Асанов', CustomerSource.onec));
    expect(adapter.requests.single.headers[ApiHeaders.idempotencyKey], 'key-1');
  });

  test('AC-UI-26-008: 201 с warnings[STALE_DATA] → NewCustomerCreated.onecCheckSkipped; неверные элементы '
      'пропускаются', () async {
    final FakeAdapter adapter = FakeAdapter(
      (RequestOptions o) async => json(201, <String, Object?>{
        'id': 'cust-new',
        'name': 'Асанов',
        'warnings': <Object?>[
          'bad',
          <String, Object?>{'message': 'без кода'},
          <String, Object?>{'code': 'STALE_DATA', 'message': 'Проверка в 1С не выполнена'},
        ],
      }),
    );
    final Dio dio = Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;
    final NewCustomerOutcome outcome = (await DioCustomersRepository(dio).create(
      const NewCustomerRequest(
        name: 'Асанов',
        customerType: CustomerType.individual,
        phonesE164: <String>['+996700123412'],
      ),
      idempotencyKey: 'key-2',
    )).valueOrNull!;
    final NewCustomerCreated created = outcome as NewCustomerCreated;
    expect(created.customer.id, 'cust-new');
    expect(created.warningCodes, <String>['STALE_DATA']);
    expect(created.onecCheckSkipped, isTrue);

    final FakeAdapter plain = FakeAdapter(
      (RequestOptions o) async => json(201, <String, Object?>{'id': 'cust-2', 'name': 'Бекова'}),
    );
    final NewCustomerCreated ok =
        (await DioCustomersRepository(
                  Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = plain,
                ).create(
                  const NewCustomerRequest(
                    name: 'Бекова',
                    customerType: CustomerType.individual,
                    phonesE164: <String>['+996700123413'],
                  ),
                  idempotencyKey: 'key-3',
                ))
                .valueOrNull!
            as NewCustomerCreated;
    expect(ok.onecCheckSkipped, isFalse);
  });

  test('поиск: q, limit, include=receivable; страница', () async {
    final FakeAdapter adapter = FakeAdapter(
      (RequestOptions o) async => json(200, <String, Object?>{
        'items': <Object?>[
          <String, Object?>{'id': 'c-1', 'name': 'Асанов', 'phoneMasked': '+996 *** ** 12', 'matchType': 'phone'},
        ],
        'nextCursor': null,
        'hasMore': false,
      }),
    );
    final Dio dio = Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;
    final PageResult<Customer> page = (await DioCustomersRepository(
      dio,
    ).search(const CustomerSearchQuery(q: '0700123412', withReceivable: true))).valueOrNull!;
    expect(page.items.single.matchType, CustomerMatchType.phone);
    expect(adapter.requests.single.path, '/search/customers');
  });
}
