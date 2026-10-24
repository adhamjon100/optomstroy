import { QUEUES } from '../../common/jobs/contracts/queues.js';
import type { SyncEntity, SyncMode } from '../../common/enums.js';
import type { SyncJobPayload } from './sync-queues.js';
import { SyncAlreadyRunningError, type SyncRunRegistry } from './sync-run.registry.js';

/** Минимальный интерфейс публикации job (PgBoss.send). */
export interface JobSender {
  send(name: string, data: object, options?: { singletonKey?: string }): Promise<string | null>;
}

export interface ManualRunRequest {
  readonly entity: SyncEntity;
  readonly mode: SyncMode;
  readonly userId?: string;
  readonly requestId?: string;
}

export interface ManualRunAccepted {
  readonly runId: string;
  readonly jobId: string;
}

/**
 * Запуск прогона вне расписания (основа `POST /sync/runs` — RM-E-002; 06 §7.5 `sync.manual`).
 * Сначала строка `sync_runs (queued)` — она занимает singleton сущности (вторая попытка →
 * `SYNC_ALREADY_RUNNING`, 409), затем job в очередь `sync.manual`. Проверки прав, step-up и режима C-2
 * (`422 inbound_mode`) — в контроллере RM-E-002, не здесь.
 */
export class SyncRunRequester {
  constructor(
    private readonly registry: SyncRunRegistry,
    private readonly sender: JobSender,
  ) {}

  async request(req: ManualRunRequest): Promise<ManualRunAccepted> {
    const runId = await this.registry.enqueue({
      entity: req.entity,
      mode: req.mode,
      trigger: 'manual',
      ...(req.userId ? { userId: req.userId } : {}),
    });
    const payload: SyncJobPayload = {
      entity: req.entity,
      mode: req.mode,
      trigger: 'manual',
      runId,
      ...(req.userId ? { userId: req.userId } : {}),
      ...(req.requestId ? { requestId: req.requestId } : {}),
    };
    let jobId: string | null;
    try {
      jobId = await this.sender.send(QUEUES.syncManual, payload, { singletonKey: req.entity });
    } catch (e) {
      await this.registry.abandon(runId, 'не удалось поставить job в очередь').catch(() => undefined);
      throw e;
    }
    if (!jobId) {
      // Политика очереди (stately) отклонила job: для сущности уже есть ожидающая job.
      await this.registry.abandon(runId, 'в очереди уже есть job этой сущности').catch(() => undefined);
      throw new SyncAlreadyRunningError(req.entity, undefined);
    }
    return { runId, jobId };
  }
}
