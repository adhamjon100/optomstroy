import type pg from 'pg';
import type { SyncEntity } from '../../common/enums.js';
import { OnecApiPausedError } from '../../sync/alerts/onec-api-compat.js';
import type { ApplyRunTracker } from '../../sync/apply/apply.types.js';
import {
  type ChangesPullResult,
  nodeErrorCode,
  type OnecChangesService,
} from '../../sync/apply/onec-changes.service.js';
import { type SyncEntityHandler, type SyncHandlerResult, type SyncRunContext, SyncRunError } from './sync-handler.js';
import { runCounts } from './sync-counts.js';

type FinishReq = Parameters<ApplyRunTracker['finish']>[0];

/**
 * Трекер прогонов цикла `onec.changes`, «усыновляющий» прогон ручного запуска: строка `sync_runs` сущности уже
 * создана `POST /sync/runs` и переведена `SyncJobProcessor` в `running` — повторно её не создаём (иначе singleton
 * сущности дал бы `SYNC_ALREADY_RUNNING`), а итог отдаём процессору. Прочие сущности сообщения — обычные прогоны.
 */
export class AdoptingRunTracker implements ApplyRunTracker {
  private adopted = false;
  finished: FinishReq | undefined;

  constructor(
    private readonly base: ApplyRunTracker,
    private readonly db: Pick<pg.Pool, 'query'>,
    private readonly adopt: { readonly entity: SyncEntity; readonly runId: string },
  ) {}

  get used(): boolean {
    return this.adopted;
  }

  async start(req: Parameters<ApplyRunTracker['start']>[0]): Promise<string> {
    if (req.entity === this.adopt.entity && !this.adopted) {
      this.adopted = true;
      await this.db.query(`UPDATE sync_runs SET cursor_from = $2, onec_endpoint = $3 WHERE id = $1`, [
        this.adopt.runId,
        req.cursorFrom ?? null,
        req.endpoint ?? null,
      ]);
      return this.adopt.runId;
    }
    return this.base.start(req);
  }

  async finish(req: FinishReq): Promise<void> {
    if (req.runId !== this.adopt.runId) return this.base.finish(req);
    this.finished = req;
    if (req.cursorTo !== undefined) {
      await this.db.query(`UPDATE sync_runs SET cursor_to = $2 WHERE id = $1`, [req.runId, req.cursorTo]);
    }
  }
}

export type ChangesServiceFactory = (tracker: ApplyRunTracker) => OnecChangesService;

/**
 * Ручной `incremental` сущности плана обмена в режиме расширения (ядро §22.8; 08 §4.17.2: «в режиме расширения —
 * одно задание `onec.changes` по плану обмена»): выполняет цикл `/changes` узла (под тем же advisory-lock, что и
 * плановый `onec.changes`, — одновременно идёт не более одного цикла) и отдаёт итог по запрошенной сущности.
 * Если сущности в сообщении нет — прогон успешен с нулевыми счётчиками (изменений в плане обмена нет).
 */
export class ChangesSyncHandler implements SyncEntityHandler {
  constructor(
    private readonly db: Pick<pg.Pool, 'query'>,
    private readonly baseTracker: ApplyRunTracker,
    private readonly changesFor: ChangesServiceFactory,
    private readonly afterPull?: () => Promise<unknown>,
  ) {}

  async run(ctx: SyncRunContext): Promise<SyncHandlerResult> {
    const tracker = new AdoptingRunTracker(this.baseTracker, this.db, { entity: ctx.entity, runId: ctx.runId });
    let result: ChangesPullResult;
    try {
      result = await this.changesFor(tracker).pullOnce({ trigger: ctx.trigger });
    } catch (e) {
      // Код `sync_errors` прогона ручного запуска (его пишет `SyncJobProcessor`) — как у прочих сущностей цикла.
      throw new SyncRunError(nodeErrorCode(e), e instanceof Error ? e.message : String(e));
    } finally {
      await this.afterPull?.().catch(() => undefined);
    }
    ctx.log.info(
      { status: result.status, messageNumber: result.messageNumber, items: result.items, adopted: tracker.used },
      'sync.changes.manual',
    );
    if (result.status === 'paused_api') {
      // 05 ONEC-095: версия API расширения несовместима — прогон не выполнялся (итог пишет SyncJobProcessor).
      throw new OnecApiPausedError(result.pausedReason ?? 'обмен с 1С приостановлен: несовместимая версия API');
    }
    if (result.status === 'skipped_locked') {
      // Идёт плановый цикл того же узла: он применит то же сообщение; свежесть сущности этим прогоном не сдвигаем.
      return { status: 'success', implemented: false, counts: { skipped: 'onec_changes_locked' } };
    }
    if (tracker.finished) {
      return {
        status: tracker.finished.status === 'partial' ? 'partial' : 'success',
        implemented: true,
        counts: { ...runCounts(tracker.finished.counts), messageNumber: result.messageNumber ?? null },
      };
    }
    return {
      status: 'success',
      implemented: true,
      counts: { fetched: 0, inserted: 0, updated: 0, errors: 0, messageNumber: result.messageNumber ?? null },
    };
  }
}
