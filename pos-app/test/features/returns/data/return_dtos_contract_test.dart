// Этап G (основа), ADR-085: DTO заявок на возврат == contracts/openapi/pos-api.v1.yaml 1.2.0 (тела —
// `additionalProperties: false`, суммы клиент не передаёт); репозиторий: пути, `rowVersion`, step-up, idempotency.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/returns/data/dto/return_dtos.dart';
import 'package:optomstroy/features/returns/data/repositories/dio_returns_repository.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../support/openapi_schemas.dart';

const List<String> _schemas = <String>[
  'ReturnRequest',
  'ReturnRequestItem',
  'ReturnsItemInput',
  'ReturnsCreateRequest',
  'ReturnsUpdateRequest',
  'ReturnsSubmitRequest',
  'ReturnsAcceptRequest',
  'ReturnsRejectRequest',
];

const ReturnDraftInput _draft = ReturnDraftInput(
  orderId: 'o1',
  reasonCode: ReturnReason.defect,
  items: <ReturnItemInput>[
    ReturnItemInput(
      orderLineNo: 1,
      quantity: LineQuantity(value: Qty(2000), unitId: 'u1'),
    ),
  ],
);

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(_schemas);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required) {
    expect(keys, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('ключи и обязательные поля == схемы OpenAPI 1.2.0', () {
    matches('ReturnRequest', ReturnRequestDto.jsonKeys, ReturnRequestDto.requiredKeys);
    matches('ReturnRequestItem', ReturnRequestItemDto.jsonKeys, ReturnRequestItemDto.requiredKeys);
    expect(ReturnItemInputDto.jsonKeys, api!.props('ReturnsItemInput'));
    matches('ReturnsCreateRequest', ReturnCreateRequestDto.jsonKeys, ReturnCreateRequestDto.requiredKeys);
    matches('ReturnsUpdateRequest', ReturnUpdateRequestDto.jsonKeys, ReturnUpdateRequestDto.requiredKeys);
    matches('ReturnsSubmitRequest', ReturnSubmitRequestDto.jsonKeys, ReturnSubmitRequestDto.requiredKeys);
    matches('ReturnsAcceptRequest', ReturnAcceptRequestDto.jsonKeys, ReturnAcceptRequestDto.requiredKeys);
    matches('ReturnsRejectRequest', ReturnRejectRequestDto.jsonKeys, ReturnRejectRequestDto.requiredKeys);
  }, skip: skip);

  test('пример ReturnRequest разбирается; тела запросов — только ключи схем', () {
    final ReturnRequest r = ReturnRequestDto.fromJson(jsonCopy(api!.example('ReturnRequest')));
    expect(r.status, ReturnRequestStatus.draft);
    expect(r.items.single.quantity.unitId, isNotEmpty);
    expect(r.approvalReason, ReturnApprovalReason.returnThresholdExceeded);
    expect(r.isDraft, isTrue);
    final Map<String, dynamic> create = ReturnCreateRequestDto.toJson(_draft);
    expect(api.props('ReturnsCreateRequest').containsAll(create.keys), isTrue);
    expect(create['items'], <Object?>[
      <String, Object?>{
        'orderLineNo': 1,
        'quantity': <String, Object?>{'value': '2.000', 'unitId': 'u1', 'packagingId': null},
      },
    ]);
    final Map<String, dynamic> patch = ReturnUpdateRequestDto.toJson(
      const ReturnDraftPatch(rowVersion: 3, clearRefundKind: true),
    );
    expect(patch, <String, dynamic>{'refundKind': null, 'rowVersion': 3});
  }, skip: skip);

  test('submit: Idempotency-Key + X-Step-Up-Token; 409 already_in_onec → ConflictFailure с reason', () async {
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
      if (o.path.endsWith('/submit')) {
        return json(200, <String, Object?>{
          'id': 'r1',
          'status': 'submitted',
          'orderId': 'o1',
          'items': <Object?>[],
          'rowVersion': 4,
        });
      }
      return json(
        409,
        problem(
          'ORDER_STATE_INVALID',
          409,
          extra: <String, Object?>{'resource': 'return_request', 'reason': 'already_in_onec'},
        ),
      );
    });
    final DioReturnsRepository repo = DioReturnsRepository(
      Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter,
    );
    final Result<ReturnRequest> submitted = await repo.submit(
      'r1',
      rowVersion: 3,
      idempotencyKey: 'k1',
      stepUpToken: 'su',
    );
    expect(submitted.valueOrNull!.status, ReturnRequestStatus.submitted);
    expect(adapter.requests.single.path, '/returns/r1/submit');
    expect(adapter.requests.single.headers[ApiHeaders.idempotencyKey], 'k1');
    expect(adapter.requests.single.headers[ApiHeaders.stepUpToken], 'su');
    expect(adapter.requests.single.data, <String, dynamic>{'rowVersion': 3});

    final Result<ReturnRequest> accepted = await repo.accept('r1', rowVersion: 4, idempotencyKey: 'k2');
    final Failure f = (accepted as FailureResult<ReturnRequest>).failure;
    expect(f, isA<ConflictFailure>().having((c) => c.reason, 'reason', 'already_in_onec'));
    expect(adapter.requests.last.path, '/returns/r1/accept');
  });

  test('delete: только с rowVersion в query', () async {
    late RequestOptions seen;
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
      seen = o;
      return json(204, null);
    });
    final DioReturnsRepository repo = DioReturnsRepository(
      Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter,
    );
    expect((await repo.delete('r1', rowVersion: 7)).isSuccess, isTrue);
    expect((seen.method, seen.uri.path, seen.uri.queryParameters['rowVersion']), ('DELETE', '/api/v1/returns/r1', '7'));
  });
}
