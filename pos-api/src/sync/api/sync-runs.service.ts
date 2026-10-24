import { Inject, Injectable, Logger } from '@nestjs/common';
import type pg from 'pg';
import { StepUpTokenVerifier, type VerifiedStepUpToken } from '../../auth/step-up/step-up-token.verifier.js';
import type { AuditContext } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import { PG_POOL } from '../../common/db/database.module.js';
import { isSyncEntity, isSyncRunStatus, type SyncEntity } from '../../common/enums.js';
import { QUEUES } from '../../common/jobs/contracts/queues.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import type { SyncJobPayload } from '../scheduler/sync-queues.js';
import { SyncAlreadyRunningError, SyncRunRegistry } from '../scheduler/sync-run.registry.js';
import type { JobSender } from '../scheduler/sync-run.requester.js';
import {
  CURSOR_TS_SQL,
  type Page,
  parseDateRange,
  parseEntity,
  parseLimit,
  parseUuid,
  SYNC_API_OPTIONS,
  SYNC_JOB_SENDER,
  type SyncApiOptions,
  SyncCursorCodec,
  toPage,
  validation,
} from './sync-api.common.js';
import {
  presentError,
  presentRun,
  SYNC_RUN_COLUMNS,
  type SyncErrorRow,
  type SyncRunDto,
  type SyncRunRow,
} from './sync-api.presenters.js';
import { MANUAL_RUN_MODES, type ManualRunMode, manualRunRule } from './sync-run.policy.js';

export interface ManualRunBody {
  readonly entity: SyncEntity;
  readonly mode: ManualRunMode;
  readonly scope: { readonly customerId?: string | null; readonly variantIds?: readonly string[] } | null;
}

const BODY_KEYS = new Set(['entity', 'mode', 'scope']);
const SCOPE_KEYS = new Set(['customerId', 'variantIds']);

/** Разбор тела `SyncRunsCreateRequest` (`additionalProperties: false`): ошибки → 400 `VALIDATION_FAILED`. */
export function parseManualRunBody(raw: unknown): ManualRunBody {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw validation('body', 'type', 'Ожидается объект.');
  const b = raw as Record<string, unknown>;
  for (const k of Object.keys(b)) {
    if (!BODY_KEYS.has(k)) throw validation(k, 'unknown_property', 'Поле не предусмотрено контрактом.');
  }
  if (!isSyncEntity(b.entity)) throw validation('entity', 'enum', 'Значение вне перечня sync_entity.');
  if (!(MANUAL_RUN_MODES as readonly unknown[]).includes(b.mode)) {
    throw validation('mode', 'enum', 'Допустимо: incremental, full, reconcile (manual присваивает сервер).');
  }
  let scope: ManualRunBody['scope'] = null;
  if (b.scope !== undefined && b.scope !== null) {
    if (typeof b.scope !== 'object' || Array.isArray(b.scope)) throw validation('scope', 'type', 'Ожидается объект.');
    const s = b.scope as Record<string, unknown>;
    for (const k of Object.keys(s)) {
      if (!SCOPE_KEYS.has(k)) throw validation(`scope.${k}`, 'unknown_property', 'Поле не предусмотрено контрактом.');
    }
    const customerId =
      s.customerId === undefined || s.customerId === null
        ? null
        : parseUuid(s.customerId as string, 'scope.customerId');
    let variantIds: string[] | undefined;
    if (s.variantIds !== undefined) {
      if (!Array.isArray(s.variantIds)) throw validation('scope.variantIds', 'type', 'Ожидается массив UUID.');
      if (s.variantIds.length > 200) throw validation('scope.variantIds', 'max_items', 'Не более 200 элементов.');
      variantIds = s.variantIds.map((v) => parseUuid(v as string, 'scope.variantIds'));
    }
    scope = { customerId, ...(variantIds ? { variantIds } : {}) };
  }
  return { entity: b.entity, mode: b.mode as ManualRunMode, scope };
}

/**
 * Прогоны синхронизации (08 §4.17.2; R0 §17.2; 05 SYNC-023, SYNC-025): ручной запуск с правилом прав/step-up,
 * singleton на сущность (`sync_runs_singleton_uq` → 409 `SYNC_ALREADY_RUNNING`), лимит RL-ADMIN «10 / 10 мин на
 * сущность», вариант C-2 → 422 `inbound_mode`, аудит `sync.manual_started`; история и ошибки прогонов.
 */
@Injectable()
export class SyncRunsService {
  private readonly logger = new Logger('sync.api');
  private readonly runsCursor: SyncCursorCodec;
  private readonly errorsCursor: SyncCursorCodec;
  readonly registry: SyncRunRegistry;

  constructor(
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(SYNC_JOB_SENDER) private readonly sender: JobSender,
    @Inject(SYNC_API_OPTIONS) private readonly options: SyncApiOptions,
    private readonly catalog: PermissionCatalog,
    private readonly stepUp: StepUpTokenVerifier,
    private readonly audit: AuditService,
    hmac: OtpHmacService,
  ) {
    this.runsCursor = new SyncCursorCodec(hmac, 'sync_runs');
    this.errorsCursor = new SyncCursorCodec(hmac, 'sync_run_errors');
    this.registry = new SyncRunRegistry(pool, options.staleRunSeconds, () => ({
      scheduleCron: config.SYNC_MASTER_CRON,
      maxAgeWarningSec: 3600,
    }));
  }

  /** `POST /sync/runs` → 202 `SyncRun` (status=queued). */
  async create(
    principal: AuthenticatedPrincipal,
    rawBody: unknown,
    stepUpToken: string | undefined,
    audit: AuditContext,
    requestId: string | undefined,
  ): Promise<SyncRunDto> {
    const body = parseManualRunBody(rawBody);
    const rule = manualRunRule(body.entity, body.mode);
    if (!this.catalog.effectivePermissions(principal).has(rule.permission)) {
      this.logger.warn(
        { event: 'authz.denied', requestId, reason: 'sync_run_rule', entity: body.entity, mode: body.mode },
        'authz.denied',
      );
      throw new ProblemException('FORBIDDEN', {
        detail:
          rule.permission === 'sync.run.full'
            ? 'Полная синхронизация, сверка и запуск этой сущности доступны только администратору и владельцу.'
            : 'Недостаточно прав для операции.',
      });
    }
    if (this.config.ONEC_INBOUND_ENABLED) {
      // Вариант C-2 (ядро §22.8; 05 SYNC-025): обмен инициирует 1С, ручной запуск недоступен любой роли.
      throw new ProblemException('VALIDATION_FAILED', {
        status: 422,
        detail: 'Данные присылает 1С по расписанию: ручной запуск синхронизации недоступен.',
        rule: 'inbound_mode',
        errors: [{ field: 'entity', rule: 'inbound_mode', message: 'Включён входящий обмен (ONEC_INBOUND_ENABLED).' }],
      });
    }
    let verified: VerifiedStepUpToken | undefined;
    if (rule.stepUp) verified = await this.stepUp.verify(stepUpToken, principal, { operation: 'sync.run.full' });
    await this.checkRate(body.entity);

    const runId = await this.registry.enqueue({
      entity: body.entity,
      mode: body.mode,
      trigger: 'manual',
      userId: principal.userId,
    });
    try {
      await this.audit.write(audit, {
        action: 'sync.manual_started',
        entityType: 'sync_run',
        entityId: runId,
        after: { entity: body.entity, mode: body.mode, scope: body.scope },
        stepUpMethod: verified?.method ?? null,
      });
      const payload: SyncJobPayload = {
        entity: body.entity,
        mode: body.mode,
        trigger: 'manual',
        runId,
        userId: principal.userId,
        ...(requestId ? { requestId } : {}),
      };
      const jobId = await this.sender.send(QUEUES.syncManual, payload, { singletonKey: body.entity });
      if (!jobId) throw new SyncAlreadyRunningError(body.entity, undefined);
      await this.pool.query(`UPDATE sync_runs SET worker_job_id = $2 WHERE id = $1 AND worker_job_id IS NULL`, [
        runId,
        jobId,
      ]);
    } catch (e) {
      await this.registry.abandon(runId, 'ручной запуск не поставлен в очередь').catch(() => undefined);
      throw e;
    }
    this.logger.log({ event: 'sync.manual_started', runId, entity: body.entity, mode: body.mode, requestId });
    const run = await this.find(runId);
    if (!run) throw new ProblemException('INTERNAL');
    return run;
  }

  /** RL-ADMIN `POST /sync/runs` (08 §4.17.2): не более N ручных запусков сущности за окно (счёт по `sync_runs`). */
  private async checkRate(entity: SyncEntity): Promise<void> {
    const { manualRunsPerWindow: limit, manualRunsWindowSec: windowSec } = this.options;
    const r = await this.pool.query<{ n: number; retry: number | null }>(
      `SELECT count(*)::int AS n,
              ceil(extract(epoch FROM (min(created_at) + make_interval(secs => $2) - now())))::int AS retry
         FROM sync_runs
        WHERE entity = $1 AND "trigger" = 'manual' AND created_at > now() - make_interval(secs => $2)`,
      [entity, windowSec],
    );
    const row = r.rows[0];
    if (row && row.n >= limit) {
      throw new ProblemException('RATE_LIMITED', {
        detail: `Не более ${limit} ручных запусков синхронизации сущности за ${Math.round(windowSec / 60)} мин.`,
        retryAfter: Math.max(1, row.retry ?? windowSec),
        headers: { 'X-RateLimit-Limit': String(limit), 'X-RateLimit-Remaining': '0' },
      });
    }
  }

  async find(id: string): Promise<SyncRunDto | undefined> {
    const r = await this.pool.query<SyncRunRow>(
      `SELECT ${SYNC_RUN_COLUMNS}, ${CURSOR_TS_SQL('r.created_at')} AS cursor_ts
         FROM sync_runs r LEFT JOIN user_profiles up ON up.user_id = r.triggered_by_user_id
        WHERE r.id = $1`,
      [id],
    );
    return r.rows[0] ? presentRun(r.rows[0]) : undefined;
  }

  async get(id: string): Promise<SyncRunDto> {
    const run = await this.find(parseUuid(id, 'id'));
    if (!run) throw new ProblemException('NOT_FOUND', { detail: 'Прогон синхронизации не найден.' });
    return run;
  }

  /** `GET /sync/runs` — Page<SyncRun>, новые сверху. */
  async list(q: Record<string, unknown>): Promise<Page<SyncRunDto>> {
    const entity = parseEntity(q.entity);
    let status: string | undefined;
    if (q.status !== undefined && q.status !== '') {
      if (!isSyncRunStatus(q.status)) throw validation('status', 'enum', 'Значение вне перечня sync_run_status.');
      status = q.status;
    }
    const range = parseDateRange(q.from, q.to);
    const limit = parseLimit(q.limit);
    const after = this.runsCursor.decode(q.cursor);
    const where: string[] = [];
    const params: unknown[] = [];
    const add = (cond: (n: number) => string, v: unknown) => {
      params.push(v);
      where.push(cond(params.length));
    };
    if (entity) add((n) => `r.entity = $${n}`, entity);
    if (status) add((n) => `r.status = $${n}::sync_run_status`, status);
    if (range.from) add((n) => `r.created_at >= $${n}`, range.from);
    if (range.to) add((n) => `r.created_at <= $${n}`, range.to);
    if (after) {
      params.push(after.createdAt, after.id);
      where.push(`(r.created_at, r.id) < ($${params.length - 1}::timestamptz, $${params.length}::uuid)`);
    }
    params.push(limit + 1);
    const r = await this.pool.query<SyncRunRow>(
      `SELECT ${SYNC_RUN_COLUMNS}, ${CURSOR_TS_SQL('r.created_at')} AS cursor_ts
         FROM sync_runs r LEFT JOIN user_profiles up ON up.user_id = r.triggered_by_user_id
        ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
        ORDER BY r.created_at DESC, r.id DESC
        LIMIT $${params.length}`,
      params,
    );
    return toPage(r.rows, limit, this.runsCursor, presentRun);
  }

  /** `GET /sync/runs/{id}/errors` — Page<SyncRunError> (коды журнала синхронизации, не Problem.code). */
  async errors(id: string, q: Record<string, unknown>): Promise<Page<Record<string, unknown>>> {
    const runId = parseUuid(id, 'id');
    const limit = parseLimit(q.limit);
    const after = this.errorsCursor.decode(q.cursor);
    const exists = await this.pool.query(`SELECT 1 FROM sync_runs WHERE id = $1`, [runId]);
    if (exists.rowCount === 0) throw new ProblemException('NOT_FOUND', { detail: 'Прогон синхронизации не найден.' });
    const params: unknown[] = [runId];
    let cond = '';
    if (after) {
      params.push(after.createdAt, after.id);
      cond = `AND (e.created_at, e.id) > ($2::timestamptz, $3::uuid)`;
    }
    params.push(limit + 1);
    const r = await this.pool.query<SyncErrorRow>(
      `SELECT e.id, e.entity::text AS entity, e.onec_ref, e.onec_code, e.error_code, e.message, e.payload,
              e.resolved_at, ${CURSOR_TS_SQL('e.created_at')} AS cursor_ts
         FROM sync_errors e
        WHERE e.sync_run_id = $1 ${cond}
        ORDER BY e.created_at, e.id
        LIMIT $${params.length}`,
      params,
    );
    return toPage(r.rows, limit, this.errorsCursor, presentError);
  }
}
