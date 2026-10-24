// [SyncJournalPort] поверх единственного Dio-клиента (08 §4.17.2–§4.17.3; контракт `sync_runs_errors_list`,
// `sync_outbox_list`, `sync_outbox_retry`). Ошибки → Failure только через ErrorMapper (06 §6.8).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/core/sync/sync_journal.dart';

/// Пути API журнала обмена.
abstract final class SyncJournalApiPaths {
  static String runErrors(String runId) => '/sync/runs/${Uri.encodeComponent(runId)}/errors';
  static const String outbox = '/sync/outbox';
  static String retry(String id) => '/sync/outbox/${Uri.encodeComponent(id)}/retry';
}

/// DTO `SyncRunError` / `OutboxItem`.
abstract final class SyncJournalDto {
  static SyncRunErrorInfo runError(JsonMap j) => SyncRunErrorInfo(
    id: jReq<String>(j, 'id'),
    entityValue: jReq<String>(j, 'entity'),
    errorCodeValue: jReq<String>(j, 'errorCode'),
    message: jReq<String>(j, 'message'),
    onecRef: jOpt<String>(j, 'onecRef'),
    onecCode: jOpt<String>(j, 'onecCode'),
    resolvedAt: jDate(j, 'resolvedAt'),
  );

  static SyncOutboxItem outboxItem(JsonMap j) => SyncOutboxItem(
    id: jReq<String>(j, 'id'),
    aggregateTypeValue: jReq<String>(j, 'aggregateType'),
    aggregateId: jReq<String>(j, 'aggregateId'),
    statusValue: jReq<String>(j, 'status'),
    operationValue: jReq<String>(j, 'operation'),
    publicNumber: jOpt<String>(j, 'publicNumber'),
    attempts: jInt(j, 'attempts'),
    nextAttemptAt: jDate(j, 'nextAttemptAt'),
    lastErrorCode: jOpt<String>(j, 'lastErrorCode'),
    lastError: jOpt<String>(j, 'lastError'),
    onecNumber: jObject(j, 'onecResponse') == null ? null : jOpt<String>(jObject(j, 'onecResponse')!, 'number'),
    createdAt: jDate(j, 'createdAt'),
    sentAt: jDate(j, 'sentAt'),
  );
}

/// Реализация порта журнала.
final class DioSyncJournal implements SyncJournalPort {
  DioSyncJournal(this._dio);

  final Dio _dio;

  @override
  Future<Result<PageResult<SyncRunErrorInfo>>> runErrors(String runId, {int limit = 50, String? cursor}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.get<Object?>(
          SyncJournalApiPaths.runErrors(runId),
          queryParameters: <String, Object?>{'limit': limit, 'cursor': ?cursor},
          options: apiOptions(),
        );
        return PageDto.fromJson(jsonObject(r.data), SyncJournalDto.runError);
      });

  @override
  Future<Result<PageResult<SyncOutboxItem>>> outbox({
    Set<OutboxStatus> statuses = const <OutboxStatus>{OutboxStatus.failed, OutboxStatus.dead},
    OutboxAggregate? aggregateType,
    int limit = 50,
    String? cursor,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      SyncJournalApiPaths.outbox,
      queryParameters: <String, Object?>{
        // `style: form, explode: false` — значения через запятую.
        if (statuses.isNotEmpty) 'status': <String>[for (final OutboxStatus s in statuses) s.value].join(','),
        'aggregateType': ?aggregateType?.value,
        'limit': limit,
        'cursor': ?cursor,
      },
      options: apiOptions(),
    );
    return PageDto.fromJson(jsonObject(r.data), SyncJournalDto.outboxItem);
  });

  @override
  Future<Result<SyncOutboxItem>> retryOutbox(String id, {required String idempotencyKey}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.post<Object?>(
          SyncJournalApiPaths.retry(id),
          options: apiOptions(idempotencyKey: idempotencyKey),
        );
        return SyncJournalDto.outboxItem(jsonObject(r.data));
      });
}
