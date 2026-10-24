// DioTransactionsRepository (08 §4.16; RM-G-009 п. 2 — покрытие data ≥ 80 %; ревью G-trace-12): все фильтры журнала
// в query (клиент, источник, сотрудник, сумма до, текст, лимит, курсор), деталь `GET /transactions/{id}`, ошибки.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/transactions/data/repositories/dio_transactions_repository.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../support/openapi_schemas.dart';

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(const <String>['TransactionsDetail']);
  final JournalPeriod period = JournalPeriod.tryCreate(DateTime.utc(2026, 10), DateTime.utc(2026, 10, 24))!;

  test('queryOf: клиент, источник, сотрудник, сумма до, текст, лимит, курсор; пустой текст не уходит', () {
    final Map<String, Object?> q = DioTransactionsRepository.queryOf(
      TransactionsQuery(
        period: period,
        customerId: 'cu-1',
        source: TransactionSource.onec,
        actorId: 'u-7',
        amountMax: const Money(500000),
        q: '1024',
        limit: 50,
        cursor: 'c2',
      ),
    );
    expect(q['customerId'], 'cu-1');
    expect(q['source'], 'onec');
    expect(q['actorId'], 'u-7');
    expect(q['amountMax'], '5000.00');
    expect(q['q'], '1024');
    expect(q['limit'], 50);
    expect(q['cursor'], 'c2');
    expect(DioTransactionsRepository.queryOf(TransactionsQuery(period: period, q: '')).containsKey('q'), isFalse);
  });

  test(
    'деталь: путь с кодированием id, разбор TransactionDetail; 404 — Failure',
    () async {
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
        if (o.uri.path.endsWith('/missing')) return json(404, problem('NOT_FOUND', 404));
        return json(200, jsonCopy(api!.example('TransactionsDetail')));
      });
      final DioTransactionsRepository repo = DioTransactionsRepository(
        Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter,
      );
      final Result<TransactionDetail> r = await repo.get('t 1');
      expect(adapter.requests.single.path, '/transactions/t%201');
      expect(r.valueOrNull!.transaction.id, isNotEmpty);
      final Failure f = (await repo.get('missing')).failureOrNull!;
      expect(f, isNot(isA<NetworkFailure>()));
    },
    skip: api == null ? 'нет python с PyYAML' : null,
  );
}
