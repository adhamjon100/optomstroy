import { Inject, Injectable } from '@nestjs/common';
import type pg from 'pg';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { PG_POOL } from '../../common/db/database.module.js';
import { SYNC_ENTITY_VALUES, type SyncEntity } from '../../common/enums.js';
import { PgBossService } from '../../common/jobs/pg-boss.service.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { iso, SYNC_API_OPTIONS, type SyncApiOptions } from './sync-api.common.js';
import { presentCounts, type SyncCountsDto } from './sync-api.presenters.js';

interface EntityRow {
  entity: SyncEntity;
  schedule_cron: string | null;
  max_age_warning_sec: number | null;
  last_success_at: Date | null;
  consecutive_errors: number | null;
  last_error_at: Date | null;
  paused: boolean | null;
  last_run_at: Date | null;
  last_counts: unknown;
  active_run_id: string | null;
}

export interface SyncEntityStatusDto {
  entity: SyncEntity;
  lastSuccessAt: string | null;
  isStale: boolean;
  ageSec?: number;
  consecutiveErrors: number;
  lastRunAt?: string | null;
  running?: boolean;
  runId?: string | null;
  lastErrorAt?: string | null;
  paused?: boolean;
  nextRunAt?: string | null;
  intervalSec?: number;
  counts?: SyncCountsDto;
}

export interface SyncStatusDto {
  onecReachable: boolean;
  checkedAt: string;
  overall: 'ok' | 'degraded' | 'failed';
  entities: SyncEntityStatusDto[];
  outbox: { pending?: number; failed: number; dead: number };
  pendingManualOrders?: { count: number; oldestAt: string | null; slaMin: number; overSla: boolean };
}

const RULE_RE = /^FREQ=MINUTELY;INTERVAL=(\d+)$/;

/**
 * `GET /sync/status` (08 §4.17.1, §3.13; 05 §7.4, §7.6.1): состояние по каждой сущности `sync_entity`. Глубина —
 * по праву (field-level allowlist): `sync.status.read` — краткий ответ (`overall`, `onecReachable`, `checkedAt`,
 * `entities[].entity/lastSuccessAt/isStale/ageSec/consecutiveErrors`, `outbox.failed/dead`); `sync.runs.read` —
 * полный. `overall` (05 §7.6.1): `failed` — 1С недоступна дольше `SYNC_ALERT_UNREACHABLE_MIN`, либо сущность с
 * `consecutive_errors ≥ 3`, либо `outbox.dead > 0`; `degraded` — устаревшая сущность (порог 1: возраст > 2×
 * интервала = `max_age_warning_sec`), `outbox.failed > 0` или заказы ручного оформления старше SLA; иначе `ok`.
 */
@Injectable()
export class SyncStatusService {
  constructor(
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(SYNC_API_OPTIONS) private readonly options: SyncApiOptions,
    private readonly catalog: PermissionCatalog,
    private readonly boss: PgBossService,
  ) {}

  async status(principal: AuthenticatedPrincipal, now = new Date()): Promise<SyncStatusDto> {
    const full = this.catalog.effectivePermissions(principal).has('sync.runs.read');
    const [rows, node, outbox, manual] = await Promise.all([
      this.entityRows(),
      this.node(),
      this.outbox(),
      this.manualOrders(),
    ]);
    const byEntity = new Map(rows.map((r) => [r.entity, r]));
    const entities: SyncEntityStatusDto[] = [];
    let anyStale = false;
    let anyFailing = false;
    for (const entity of SYNC_ENTITY_VALUES) {
      const r = byEntity.get(entity);
      const maxAge = r?.max_age_warning_sec ?? null;
      const ageSec = r?.last_success_at
        ? Math.max(0, Math.floor((now.getTime() - r.last_success_at.getTime()) / 1000))
        : undefined;
      // Сущность без расписания (нет строки sync_state) в «устаревание» не входит; без успеха — устарела.
      const isStale = r?.schedule_cron ? ageSec === undefined || (maxAge !== null && ageSec > maxAge) : false;
      if (isStale) anyStale = true;
      const consecutiveErrors = Number(r?.consecutive_errors ?? 0);
      if (consecutiveErrors >= this.options.consecutiveErrorsThreshold) anyFailing = true;
      const e: SyncEntityStatusDto = {
        entity,
        lastSuccessAt: iso(r?.last_success_at),
        isStale,
        ...(ageSec !== undefined ? { ageSec } : {}),
        consecutiveErrors,
      };
      if (full) {
        const intervalSec = this.intervalSec(r);
        Object.assign(e, {
          lastRunAt: iso(r?.last_run_at),
          running: Boolean(r?.active_run_id),
          runId: r?.active_run_id ?? null,
          lastErrorAt: iso(r?.last_error_at),
          paused: Boolean(r?.paused),
          nextRunAt: r?.schedule_cron ? this.nextRunAt(r.schedule_cron) : null,
          ...(intervalSec !== undefined ? { intervalSec } : {}),
          counts: presentCounts(r?.last_counts),
        });
      }
      entities.push(e);
    }
    const unreachableFor = !node.reachable && node.since ? (now.getTime() - node.since.getTime()) / 60_000 : 0;
    const unreachableAlert = !node.reachable && unreachableFor >= this.config.SYNC_ALERT_UNREACHABLE_MIN;
    const slaMin = this.config.MANUAL_ORDER_SLA_MIN;
    const overSla = manual.oldestAt !== null && (now.getTime() - manual.oldestAt.getTime()) / 60_000 > slaMin;
    const overall: SyncStatusDto['overall'] =
      unreachableAlert || anyFailing || outbox.dead > 0
        ? 'failed'
        : anyStale || outbox.failed > 0 || overSla
          ? 'degraded'
          : 'ok';
    return {
      onecReachable: node.reachable,
      checkedAt: now.toISOString(),
      overall,
      entities,
      outbox: full ? outbox : { failed: outbox.failed, dead: outbox.dead },
      ...(full
        ? { pendingManualOrders: { count: manual.count, oldestAt: iso(manual.oldestAt), slaMin, overSla } }
        : {}),
    };
  }

  private intervalSec(r: EntityRow | undefined): number | undefined {
    if (!r?.schedule_cron) return undefined;
    const m = RULE_RE.exec(r.schedule_cron);
    if (m) return Number(m[1]) * 60;
    // Порог устаревания планировщик ставит в 2 периода расписания (SyncScheduler.maxAgeWarningSec).
    return r.max_age_warning_sec ? Math.round(r.max_age_warning_sec / 2) : undefined;
  }

  private nextRunAt(expression: string): string | null {
    const boss = this.boss.instance;
    if (!boss) return null;
    try {
      const tz = this.config.TZ && this.config.TZ.trim() !== '' ? this.config.TZ : 'Asia/Bishkek';
      const [next] = boss.previewSchedule(expression, { tz, count: 1 });
      return next ? next.toISOString() : null;
    } catch {
      return null;
    }
  }

  private async entityRows(): Promise<EntityRow[]> {
    const r = await this.pool.query<EntityRow>(
      `SELECT s.entity::text AS entity, s.schedule_cron, s.max_age_warning_sec, s.last_success_at,
              s.consecutive_errors, s.last_error_at, s.paused,
              COALESCE(lr.started_at, lr.created_at) AS last_run_at, lr.counts AS last_counts,
              (SELECT a.id FROM sync_runs a WHERE a.entity = s.entity AND a.status IN ('queued','running') LIMIT 1)
                AS active_run_id
         FROM sync_state s
         LEFT JOIN sync_runs lr ON lr.id = s.last_run_id
       UNION ALL
       SELECT a.entity::text, NULL, NULL, NULL, NULL, NULL, NULL, a.started_at, a.counts, a.id
         FROM sync_runs a
        WHERE a.status IN ('queued','running') AND NOT EXISTS (SELECT 1 FROM sync_state s WHERE s.entity = a.entity)`,
    );
    return r.rows;
  }

  private async node(): Promise<{ reachable: boolean; since: Date | null }> {
    const r = await this.pool.query<{ onec_reachable: boolean; unreachable_since: Date | null }>(
      `SELECT onec_reachable, unreachable_since FROM sync_node_state ORDER BY node LIMIT 1`,
    );
    const row = r.rows[0];
    return { reachable: row ? row.onec_reachable : true, since: row?.unreachable_since ?? null };
  }

  private async outbox(): Promise<{ pending: number; failed: number; dead: number }> {
    const r = await this.pool.query<{ pending: number; failed: number; dead: number }>(
      `SELECT count(*) FILTER (WHERE status IN ('pending','sending'))::int AS pending,
              count(*) FILTER (WHERE status = 'failed')::int AS failed,
              count(*) FILTER (WHERE status = 'dead')::int AS dead
         FROM onec_outbox WHERE status IN ('pending','sending','failed','dead')`,
    );
    return r.rows[0] ?? { pending: 0, failed: 0, dead: 0 };
  }

  /**
   * Заказы фазы 0, ждущие ручного оформления в 1С (05 SYNC-066/067): элемент outbox `order/create`, запаркованный
   * без канала записи (`pending`, `next_attempt_at IS NULL`, `NO_WRITE_CHANNEL`).
   */
  private async manualOrders(): Promise<{ count: number; oldestAt: Date | null }> {
    const r = await this.pool.query<{ count: number; oldest: Date | null }>(
      `SELECT count(*)::int AS count, min(created_at) AS oldest FROM onec_outbox
        WHERE aggregate_type = 'order' AND operation = 'create' AND status = 'pending'
          AND next_attempt_at IS NULL AND last_error_code = 'NO_WRITE_CHANNEL'`,
    );
    return { count: r.rows[0]?.count ?? 0, oldestAt: r.rows[0]?.oldest ?? null };
  }
}
