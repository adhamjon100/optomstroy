// Адаптеры портов core/sync (RM-E-009) поверх портов фичи catalog: core не импортирует фичи (FL-04),
// поэтому `CatalogSyncEngine` и SCR-43 работают через `CatalogCachePort` / `SyncStatusPort`,
// а фича catalog реализует их своими репозиториями (`CatalogSyncRepository`, `SyncStatusRepository`).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_ports.dart';
import 'package:optomstroy/features/catalog/domain/entities/sync.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';

/// `CatalogCachePort` → `CatalogSyncRepository` (строки сущностей → `CatalogSyncEntity`).
final class CatalogCachePortAdapter implements CatalogCachePort {
  const CatalogCachePortAdapter(this._sync);

  final CatalogSyncRepository _sync;

  static CacheEntityProgress progressOf(CatalogSyncProgress p) => CacheEntityProgress(
    entity: p.entity.value,
    pages: p.pages,
    rows: p.upserted,
    deleted: p.deleted,
    completed: p.completed,
    fullReload: p.fullReload,
  );

  @override
  Future<Result<CacheEntityProgress>> syncEntity(
    String entity, {
    bool restart = false,
    int limit = 200,
    void Function(CacheEntityProgress progress)? onPage,
  }) async {
    final e = CatalogSyncEntity.tryParse(entity);
    if (e == null || !e.cached) {
      return FailureResult(UnknownFailure(cause: ArgumentError.value(entity, 'entity', 'не кэшируется')));
    }
    final r = await _sync.syncEntity(
      e,
      restart: restart,
      limit: limit,
      onPage: onPage == null ? null : (p) => onPage(progressOf(p)),
    );
    return r.map(progressOf);
  }

  @override
  Future<Result<DateTime?>> fullLoadedAt() => _sync.fullLoadedAt();

  @override
  Future<Result<void>> markFullLoaded(DateTime at) => _sync.markFullLoaded(at);
}

/// `SyncStatusPort` → `SyncStatusRepository`; ответ `GET /sync/status` попутно сохраняет пороги
/// устаревания в `sync_meta.stale_after_sec` (DATA-256: офлайн-признак устаревания).
final class SyncStatusPortAdapter implements SyncStatusPort {
  const SyncStatusPortAdapter({required SyncStatusRepository status, CatalogSyncRepository? cache})
    : _status = status,
      _cache = cache;

  final SyncStatusRepository _status;
  final CatalogSyncRepository? _cache;

  static SyncServerEntity entityOf(SyncEntityStatus e) => SyncServerEntity(
    entityValue: e.entityValue ?? e.entity?.value ?? '',
    lastSuccessAt: e.lastSuccessAt,
    lastRunAt: e.lastRunAt,
    running: e.running,
    runId: e.runId,
    consecutiveErrors: e.consecutiveErrors,
    nextRunAt: e.nextRunAt,
    intervalSec: e.intervalSec,
    ageSec: e.ageSec,
    isStale: e.isStale,
    paused: e.paused,
    fetched: e.counts?.fetched,
    sourceTotal: e.counts?.sourceTotal,
  );

  static SyncServerStatus statusOf(SyncStatusInfo s) => SyncServerStatus(
    onecReachable: s.onecReachable,
    checkedAt: s.checkedAt,
    overall: s.overall.value,
    entities: [for (final e in s.entities) entityOf(e)],
    outbox: s.outbox == null
        ? null
        : SyncServerOutbox(pending: s.outbox!.pending, failed: s.outbox!.failed, dead: s.outbox!.dead),
  );

  static SyncRunInfo runOf(SyncRun r) => SyncRunInfo(
    id: r.id,
    entityValue: r.entityValue,
    modeValue: r.modeValue,
    statusValue: r.statusValue,
    triggerValue: r.triggerValue.isEmpty ? null : r.triggerValue,
    startedAt: r.startedAt,
    finishedAt: r.finishedAt,
    triggeredByName: r.triggeredByName,
    fetched: r.counts?.fetched,
    sourceTotal: r.counts?.sourceTotal,
    errors: r.counts?.errors,
  );

  @override
  Future<Result<SyncServerStatus>> status() async {
    final r = await _status.status();
    final info = r.valueOrNull;
    if (info != null) await _cache?.saveStaleThresholds(info);
    return r.map(statusOf);
  }

  @override
  Future<Result<SyncRunsPage>> runs({SyncEntity? entity, int limit = 50, String? cursor}) async {
    final r = await _status.runs(entity: entity?.value, limit: limit, cursor: cursor);
    return r.map(
      (p) => SyncRunsPage(items: [for (final x in p.items) runOf(x)], nextCursor: p.nextCursor, hasMore: p.hasMore),
    );
  }

  @override
  Future<Result<SyncRunInfo>> run(String runId) async => (await _status.run(runId)).map(runOf);

  @override
  Future<Result<SyncRunInfo>> startRun({
    required SyncEntity entity,
    required SyncMode mode,
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    final requestMode = switch (mode) {
      SyncMode.full => SyncRunRequestMode.full,
      SyncMode.reconcile => SyncRunRequestMode.reconcile,
      SyncMode.incremental || SyncMode.manual => SyncRunRequestMode.incremental,
    };
    final r = await _status.startRun(
      entity: entity.value,
      mode: requestMode,
      idempotencyKey: idempotencyKey,
      stepUpToken: stepUpToken,
    );
    return r.map(runOf);
  }
}
