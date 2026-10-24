// Этап G (основа), ADR-085: ответ `GET /transactions` (Page + `summary`), `TransactionsSummary`, `TransactionsDetail`
// == contracts/openapi/pos-api.v1.yaml 1.2.0; запрос журнала — период обязателен, массивы повтором ключа.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/transactions/data/dto/transactions_dtos.dart';
import 'package:optomstroy/features/transactions/data/repositories/dio_transactions_repository.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../support/openapi_schemas.dart';

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(
    const <String>['TransactionsSummary', 'TransactionsDetail'],
    responses: const <String>['/transactions get 200'],
  );
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;
  final JournalPeriod period = JournalPeriod.tryCreate(DateTime.utc(2026, 10), DateTime.utc(2026, 10, 24))!;

  test('ключи и обязательные поля == схемы OpenAPI 1.2.0', () {
    expect(TransactionsSummaryDto.jsonKeys, api!.props('TransactionsSummary'));
    expect(TransactionsSummaryDto.requiredKeys, api.required('TransactionsSummary'));
    expect(TransactionDetailDto.jsonKeys, api.props('TransactionsDetail'));
    expect(TransactionDetailDto.requiredKeys, api.required('TransactionsDetail'));
    expect(TransactionsPageDto.jsonKeys, api.responseProps('/transactions get 200'));
  }, skip: skip);

  test('примеры разбираются: страница с итогами, деталь с аудитом (admin/owner)', () {
    final TransactionsPage page = TransactionsPageDto.fromJson(jsonCopy(api!.responseExample('/transactions get 200')));
    expect(page.page.items.single.amount, isA<Money>());
    expect(page.summary!.sumIn, isA<Money>());
    final TransactionDetail d = TransactionDetailDto.fromJson(jsonCopy(api.example('TransactionsDetail')));
    expect(d.audit.single.chainOk, isTrue);
  }, skip: skip);

  test('запрос журнала: from/to ISO-8601 UTC, status/kind повтором ключа, mine только при true', () async {
    late RequestOptions seen;
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
      seen = o;
      return json(200, <String, Object?>{'items': <Object?>[], 'nextCursor': null, 'hasMore': false});
    });
    final Dio dio = Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;
    final Result<TransactionsPage> r = await DioTransactionsRepository(dio).list(
      TransactionsQuery(
        period: period,
        statuses: const <TransactionStatusGroup>{TransactionStatusGroup.received, TransactionStatusGroup.pending},
        kinds: const <TransactionKind>{TransactionKind.paymentReceived},
        mine: true,
        paymentMethod: PaymentMethod.cash,
        amountMin: const Money(10000),
      ),
    );
    expect(r.isSuccess, isTrue);
    final Map<String, List<String>> q = seen.uri.queryParametersAll;
    expect(q['from'], <String>['2026-10-01T00:00:00.000Z']);
    expect(q['to'], <String>['2026-10-24T00:00:00.000Z']);
    expect(q['status'], <String>['received', 'pending']);
    expect(q['kind'], <String>['payment_received']);
    expect(q['mine'], <String>['true']);
    expect(q['paymentMethod'], <String>['cash']);
    expect(q['amountMin'], <String>['100.00']);
    expect(q['sort'], <String>['occurredAt:desc']);
    expect(DioTransactionsRepository.queryOf(TransactionsQuery(period: period)).containsKey('mine'), isFalse);
  });
}
