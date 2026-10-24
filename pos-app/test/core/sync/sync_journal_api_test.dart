// DioSyncJournal (08 §4.17.2–§4.17.3; контракт sync_runs_errors_list, sync_outbox_list, sync_outbox_retry): пути,
// `status=failed,dead` через запятую (`style: form, explode: false`), `Idempotency-Key` у повтора, разбор
// `SyncRunError` и `OutboxItem` (в том числе `onecResponse.number`), ошибки — через ErrorMapper.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/sync/sync_journal.dart';
import 'package:optomstroy/core/sync/sync_journal_api.dart';

final class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final (int, Object) Function(RequestOptions o) respond;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (int status, Object body) = respond(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[status >= 400 ? 'application/problem+json' : Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const Map<String, Object?> _item = <String, Object?>{
  'id': '7d1f0000-0000-4000-8000-000000000001',
  'aggregateType': 'order',
  'aggregateId': '7d1f0000-0000-4000-8000-000000000002',
  'publicNumber': 'POS-2026-000123',
  'status': 'pending',
  'attempts': 0,
  'nextAttemptAt': '2026-10-19T09:42:00Z',
  'lastErrorCode': null,
  'lastError': null,
  'onecResponse': <String, Object?>{'ref': '7d1f0000-0000-4000-8000-000000000003', 'number': 'ЗК-000045'},
  'createdAt': '2026-10-19T07:00:00Z',
  'sentAt': null,
  'operation': 'create',
};

void main() {
  late _Adapter adapter;
  late DioSyncJournal api;

  void serve((int, Object) Function(RequestOptions o) respond) {
    adapter = _Adapter(respond);
    api = DioSyncJournal(Dio(BaseOptions(baseUrl: 'http://127.0.0.1/api/v1'))..httpClientAdapter = adapter);
  }

  test('GET /sync/outbox: status=failed,dead, limit; разбор OutboxItem', () async {
    serve(
      (_) => (
        200,
        <String, Object?>{
          'items': <Object>[_item],
          'nextCursor': null,
          'hasMore': false,
        },
      ),
    );
    final Result<PageResult<SyncOutboxItem>> r = await api.outbox(aggregateType: OutboxAggregate.order);
    final RequestOptions o = adapter.requests.single;
    expect(o.path, '/sync/outbox');
    expect(o.queryParameters['status'], 'failed,dead');
    expect(o.queryParameters['aggregateType'], 'order');
    expect(o.queryParameters['limit'], 50);
    final SyncOutboxItem i = r.valueOrNull!.items.single;
    expect(i.status, OutboxStatus.pending);
    expect(i.aggregateType, OutboxAggregate.order);
    expect(i.publicNumber, 'POS-2026-000123');
    expect(i.onecNumber, 'ЗК-000045');
    expect(i.retryable, isFalse);
  });

  test('POST /sync/outbox/{id}/retry — Idempotency-Key, без тела; 202 → OutboxItem', () async {
    serve((_) => (202, _item));
    final Result<SyncOutboxItem> r = await api.retryOutbox('x 1', idempotencyKey: 'k-1');
    final RequestOptions o = adapter.requests.single;
    expect(o.method, 'POST');
    expect(o.path, '/sync/outbox/x%201/retry');
    expect(o.headers['Idempotency-Key'], 'k-1');
    expect(o.data, isNull);
    expect(r.valueOrNull!.statusValue, 'pending');
  });

  test('409 ORDER_STATE_INVALID (already_delivered) → ConflictFailure', () async {
    serve(
      (_) => (
        409,
        <String, Object?>{
          'type': 'about:blank',
          'title': 'Conflict',
          'status': 409,
          'code': 'ORDER_STATE_INVALID',
          'reason': 'already_delivered',
          'requestId': 'req-1',
        },
      ),
    );
    final Result<SyncOutboxItem> r = await api.retryOutbox('x1', idempotencyKey: 'k-1');
    final Failure f = r.failureOrNull!;
    expect(f, isA<ConflictFailure>());
    expect((f as ConflictFailure).kind, ConflictKind.orderStateInvalid);
  });

  test('GET /sync/runs/{id}/errors — разбор SyncRunError', () async {
    serve(
      (_) => (
        200,
        <String, Object?>{
          'items': <Object>[
            <String, Object?>{
              'id': 'e1',
              'entity': 'customers',
              'onecRef': null,
              'onecCode': '000123',
              'errorCode': 'VALIDATION',
              'message': 'Не заполнен ИНН',
              'payload': null,
              'resolvedAt': null,
            },
          ],
          'nextCursor': 'c2',
          'hasMore': true,
        },
      ),
    );
    final Result<PageResult<SyncRunErrorInfo>> r = await api.runErrors('r-1', limit: 20, cursor: 'c1');
    final RequestOptions o = adapter.requests.single;
    expect(o.path, '/sync/runs/r-1/errors');
    expect(o.queryParameters, <String, Object?>{'limit': 20, 'cursor': 'c1'});
    final SyncRunErrorInfo e = r.valueOrNull!.items.single;
    expect(e.entity, SyncEntity.customers);
    expect(e.errorCode, SyncErrorCode.validation);
    expect(e.onecCode, '000123');
    expect(r.valueOrNull!.nextCursor, 'c2');
  });
}
