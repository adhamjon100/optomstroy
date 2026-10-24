// DioReturnsRepository (08 §4.15; RM-G-009 п. 2 — покрытие data ≥ 80 %; ревью G-trace-12): пути, query фильтров,
// тела запросов, `Idempotency-Key`/`X-Step-Up-Token`, разбор ответа и ошибки через ErrorMapper.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/returns/data/repositories/dio_returns_repository.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';

import '../../../core/network/fake_adapter.dart';

Map<String, Object?> _ret({String status = 'draft', int rowVersion = 1}) => <String, Object?>{
  'id': 'r1',
  'publicNumber': 'RET-2026-000007',
  'status': status,
  'orderId': 'o1',
  'customerId': 'cu-1',
  'reasonCode': 'defect',
  'items': <Object?>[
    <String, Object?>{
      'orderLineNo': 1,
      'variantId': 'v1',
      'quantity': <String, Object?>{'value': '2.000', 'unitId': 'u1', 'packagingId': null},
      'maxReturnable': '3.000',
      'amount': <String, Object?>{'amount': '1200.00', 'currency': 'KGS'},
    },
  ],
  'totalAmount': <String, Object?>{'amount': '1200.00', 'currency': 'KGS'},
  'rowVersion': rowVersion,
  'createdAt': '2026-10-22T04:00:00Z',
};

void main() {
  late FakeAdapter adapter;
  late List<RequestOptions> seen;
  late DioReturnsRepository repo;

  void serve(ResponseBody Function(RequestOptions o) respond) {
    seen = <RequestOptions>[];
    adapter = FakeAdapter((RequestOptions o) async {
      seen.add(o);
      return respond(o);
    });
    repo = DioReturnsRepository(Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter);
  }

  test('list: фильтры статуса, заказа, клиента, периода и курсора; страница ReturnRequest', () async {
    serve(
      (_) => json(200, <String, Object?>{
        'items': <Object?>[_ret()],
        'nextCursor': 'c2',
        'hasMore': true,
      }),
    );
    final Result<PageResult<ReturnRequest>> r = await repo.list(
      ReturnsQuery(
        status: ReturnRequestStatus.submitted,
        orderId: 'o1',
        customerId: 'cu-1',
        from: DateTime.utc(2026, 10, 1),
        to: DateTime.utc(2026, 10, 22),
        limit: 20,
        cursor: 'c1',
      ),
    );
    final Map<String, String> q = seen.single.uri.queryParameters;
    expect(seen.single.uri.path, '/api/v1/returns');
    expect(q['status'], 'submitted');
    expect(q['orderId'], 'o1');
    expect(q['customerId'], 'cu-1');
    expect(q['from'], startsWith('2026-10-01T00:00:00'));
    expect(q['to'], startsWith('2026-10-22T00:00:00'));
    expect(q['limit'], '20');
    expect(q['cursor'], 'c1');
    final PageResult<ReturnRequest> page = r.valueOrNull!;
    expect(page.items.single.publicNumber, 'RET-2026-000007');
    expect(page.items.single.isDraft, isTrue);
    expect(page.items.single.items.single.maxReturnable, const Qty(3000));
    expect(page.items.single.toString(), 'ReturnRequest(r1, draft)');
    expect(page.nextCursor, 'c2');
  });

  test('list без фильтров — без query-параметров фильтра', () async {
    serve((_) => json(200, <String, Object?>{'items': <Object?>[], 'nextCursor': null, 'hasMore': false}));
    expect((await repo.list(const ReturnsQuery())).valueOrNull!.items, isEmpty);
    expect(seen.single.uri.queryParameters, isEmpty);
  });

  test('get / create / update: пути, Idempotency-Key, тела', () async {
    serve((RequestOptions o) => json(o.method == 'POST' ? 201 : 200, _ret(rowVersion: 2)));
    expect((await repo.get('r 1')).valueOrNull!.rowVersion, 2);
    expect(seen.last.uri.path, '/api/v1/returns/r%201');

    const ReturnDraftInput draft = ReturnDraftInput(
      orderId: 'o1',
      reasonCode: ReturnReason.defect,
      items: <ReturnItemInput>[
        ReturnItemInput(
          orderLineNo: 1,
          quantity: LineQuantity(value: Qty(2000), unitId: 'u1'),
        ),
      ],
    );
    expect((await repo.create(draft, idempotencyKey: 'k-create')).isSuccess, isTrue);
    expect(seen.last.method, 'POST');
    expect(seen.last.headers[ApiHeaders.idempotencyKey], 'k-create');
    expect((seen.last.data as Map<String, dynamic>)['orderId'], 'o1');

    expect(
      (await repo.update(
        'r1',
        const ReturnDraftPatch(rowVersion: 2, clearRefundKind: true),
        idempotencyKey: 'k-up',
      )).isSuccess,
      isTrue,
    );
    expect(seen.last.method, 'PATCH');
    expect(seen.last.headers[ApiHeaders.idempotencyKey], 'k-up');
    expect(seen.last.data, <String, dynamic>{'refundKind': null, 'rowVersion': 2});
  });

  test('accept и reject: тела, step-up; submit без step-up — без заголовка токена', () async {
    serve((RequestOptions o) => json(200, _ret(status: o.uri.path.endsWith('/reject') ? 'rejected' : 'accepted')));
    final Result<ReturnRequest> accepted = await repo.accept(
      'r1',
      rowVersion: 4,
      idempotencyKey: 'k-a',
      comment: 'ок',
      stepUpToken: 'su-a',
    );
    expect(accepted.valueOrNull!.status, ReturnRequestStatus.accepted);
    expect(seen.last.uri.path, '/api/v1/returns/r1/accept');
    expect(seen.last.headers[ApiHeaders.stepUpToken], 'su-a');
    expect(seen.last.data, <String, dynamic>{'rowVersion': 4, 'comment': 'ок'});

    final Result<ReturnRequest> rejected = await repo.reject(
      'r1',
      reason: 'не наш товар',
      rowVersion: 5,
      idempotencyKey: 'k-r',
      stepUpToken: 'su-r',
    );
    expect(rejected.valueOrNull!.status, ReturnRequestStatus.rejected);
    expect(seen.last.uri.path, '/api/v1/returns/r1/reject');
    expect(seen.last.data, <String, dynamic>{'reason': 'не наш товар', 'rowVersion': 5});
    expect(seen.last.headers[ApiHeaders.idempotencyKey], 'k-r');

    await repo.submit('r1', rowVersion: 6, idempotencyKey: 'k-s', comment: 'проверьте');
    expect(seen.last.uri.path, '/api/v1/returns/r1/submit');
    expect(seen.last.headers.containsKey(ApiHeaders.stepUpToken), isFalse);
    expect(seen.last.data, <String, dynamic>{'rowVersion': 6, 'comment': 'проверьте'});
  });

  test('ошибки: 422 RETURN_QTY_EXCEEDED → ServerFailure; 404 → ошибка; нет соединения → NetworkFailure', () async {
    serve((RequestOptions o) {
      if (o.uri.path.endsWith('/r404')) return json(404, problem('NOT_FOUND', 404));
      if (o.method == 'POST') return json(422, problem('RETURN_QTY_EXCEEDED', 422));
      return transportError(o, DioExceptionType.connectionError);
    });
    final Failure qty = (await repo.submit('r1', rowVersion: 1, idempotencyKey: 'k')).failureOrNull!;
    expect(qty, isA<ServerFailure>().having((ServerFailure f) => f.code, 'code', 'RETURN_QTY_EXCEEDED'));
    expect((await repo.get('r404')).failureOrNull, isNotNull);
    expect((await repo.delete('r1', rowVersion: 1)).failureOrNull, isA<NetworkFailure>());
  });
}
