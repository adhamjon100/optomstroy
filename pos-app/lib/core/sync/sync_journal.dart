// Журнал обмена с 1С для SCR-43 в полном режиме (02 SCR-43 UI-43-007, UI-43-008, UI-43-013…015; 08 §4.17.2–§4.17.3;
// 04 FLOW-033.S6; ядро §18.2 п. 11, §19.4, §22.1, §22.10): ошибки прогона `GET /sync/runs/{id}/errors` (`sync.runs.read`)
// и очередь документов «в 1С» `GET /sync/outbox` с ручным повтором `POST /sync/outbox/{id}/retry` (`sync.outbox.manage`:
// `admin`, `senior_seller`; без step-up; `Idempotency-Key` обязателен). Чистые модели и порт (core не импортирует фичи).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';

/// Строка журнала ошибок прогона (`SyncRunError`). `errorCode` — код журнала синхронизации (не `Problem.code`).
final class SyncRunErrorInfo {
  const SyncRunErrorInfo({
    required this.id,
    required this.entityValue,
    required this.errorCodeValue,
    required this.message,
    this.onecRef,
    this.onecCode,
    this.resolvedAt,
  });

  final String id;
  final String entityValue;
  final String errorCodeValue;

  /// Сообщение сервера (без ПДн, SYNC-039).
  final String message;
  final String? onecRef;

  /// Код объекта в 1С (копируется по тапу, UI-43-007).
  final String? onecCode;

  /// Только чтение («пометить решённой» — R2, Q-219).
  final DateTime? resolvedAt;

  SyncEntity? get entity => SyncEntity.tryParse(entityValue);
  SyncErrorCode? get errorCode => SyncErrorCode.tryParse(errorCodeValue);
}

/// Элемент очереди «в 1С» (`OutboxItem`).
final class SyncOutboxItem {
  const SyncOutboxItem({
    required this.id,
    required this.aggregateTypeValue,
    required this.aggregateId,
    required this.statusValue,
    required this.operationValue,
    this.publicNumber,
    this.attempts,
    this.nextAttemptAt,
    this.lastErrorCode,
    this.lastError,
    this.onecNumber,
    this.createdAt,
    this.sentAt,
  });

  final String id;
  final String aggregateTypeValue;
  final String aggregateId;
  final String statusValue;
  final String operationValue;
  final String? publicNumber;
  final int? attempts;
  final DateTime? nextAttemptAt;
  final String? lastErrorCode;
  final String? lastError;

  /// `onecResponse.number` — номер документа 1С.
  final String? onecNumber;
  final DateTime? createdAt;
  final DateTime? sentAt;

  OutboxAggregate? get aggregateType => OutboxAggregate.tryParse(aggregateTypeValue);
  OutboxStatus? get status => OutboxStatus.tryParse(statusValue);

  /// Ручной повтор — только `failed`/`dead` (08 §4.17.3; ядро §22.1).
  bool get retryable => status == OutboxStatus.failed || status == OutboxStatus.dead;
}

/// Журнал прогонов и очередь «в 1С».
abstract interface class SyncJournalPort {
  /// `GET /sync/runs/{id}/errors`.
  Future<Result<PageResult<SyncRunErrorInfo>>> runErrors(String runId, {int limit = 50, String? cursor});

  /// `GET /sync/outbox?status=&aggregateType=` (по умолчанию `failed,dead`).
  Future<Result<PageResult<SyncOutboxItem>>> outbox({
    Set<OutboxStatus> statuses = const <OutboxStatus>{OutboxStatus.failed, OutboxStatus.dead},
    OutboxAggregate? aggregateType,
    int limit = 50,
    String? cursor,
  });

  /// `POST /sync/outbox/{id}/retry` + `Idempotency-Key` → `202 OutboxItem(pending)`.
  Future<Result<SyncOutboxItem>> retryOutbox(String id, {required String idempotencyKey});
}
