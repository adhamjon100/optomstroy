import type pg from 'pg';
import pino from 'pino';
import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import { isOnecAuthFailure, OnecError } from '../../src/integrations/onec/onec-error.js';
import type { OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import { type SyncEntityHandler, SyncRunError } from '../../src/jobs/sync/sync-handler.js';
import { SyncJobProcessor } from '../../src/jobs/sync/sync-job.processor.js';
import { OnecAuthPause } from '../../src/sync/alerts/onec-auth-pause.js';
import { SyncAlertService } from '../../src/sync/alerts/sync-alerts.service.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { createRunTracker, DEFAULT_STATE_DEFAULTS } from '../../src/sync/apply/run-tracker.js';
import { SyncRunRegistry } from '../../src/sync/scheduler/sync-run.registry.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';

/**
 * Пауза чтения из 1С после отказа авторизации 401/403 (05 §6.5: «алерт администратору, `consecutive_errors++`,
 * следующий запрос сущности — не раньше чем через 15 мин, без backoff-ретраев»; ТЗ для 1С А.1; разбор расхождений
 * п. 89). Данные — фейк 1С и фикстуры (тестовые данные).
 */
const silent = pino({ level: 'silent' });
let server: EmbeddedPg;
let dbNo = 0;
const open: CatalogFixture[] = [];

async function fresh(): Promise<CatalogFixture> {
  const f = await startCatalogFixture({
    pg: server,
    database: `auth_pause_${++dbNo}`,
    skuCount: 0,
    includeFixtures: false,
    skipLoad: true,
  });
  open.push(f);
  return f;
}

async function addAdmin(pool: pg.Pool): Promise<void> {
  const u = await pool.query<{ id: string }>(
    `INSERT INTO users (phone_e164, kind, status) VALUES ('+996700000901', 'staff', 'active') RETURNING id`,
  );
  await pool.query(`INSERT INTO user_roles (user_id, role_id) SELECT $1, id FROM roles WHERE code = 'admin'`, [
    u.rows[0].id,
  ]);
}

function pause(pool: pg.Pool): OnecAuthPause {
  return new OnecAuthPause(pool, { alerts: new SyncAlertService(pool, silent), log: silent });
}

const unauthorized = () => new OnecError('getChanges', 401, 'POS_E_UNAUTHORIZED', 'неверный ключ X-POS-Client-Key');

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
});

afterAll(async () => {
  for (const f of open) await f.stop();
  await server?.stop();
});

describe('isOnecAuthFailure', () => {
  it('401/403 — да (в том числе внутри SyncRunError и в cause); 503, 400 и прочее — нет', () => {
    expect(isOnecAuthFailure(unauthorized())).toBe(true);
    expect(isOnecAuthFailure(new OnecError('getOrderStatusBatch', 403, 'POS_E_FORBIDDEN', 'нет прав'))).toBe(true);
    expect(isOnecAuthFailure(new OnecError('getChanges', 503, 'POS_E_MAINTENANCE', 'обновление'))).toBe(false);
    expect(isOnecAuthFailure(new OnecError('getChanges', 400, 'POS_E_BAD_REQUEST', 'since'))).toBe(false);
    const wrapped = new SyncRunError(
      'ONEC_UNAVAILABLE',
      `статусы заказов 1С недоступны: 401 POS_E_UNAUTHORIZED: ${unauthorized().message}`,
    );
    expect(isOnecAuthFailure(wrapped)).toBe(true);
    expect(isOnecAuthFailure(new Error('обёртка', { cause: unauthorized() }))).toBe(true);
    expect(isOnecAuthFailure(new Error('сеть недоступна'))).toBe(false);
    expect(isOnecAuthFailure(undefined)).toBe(false);
  });
});

describe('onec.changes: 401 → пауза 15 мин без обращений к 1С, тревога администратору', () => {
  it('отказ авторизации на /changes: отметка auth_error_at, уведомление admin; следующий цикл — paused_auth без вызова 1С; после 15 мин — снова читает', async () => {
    const f = await fresh();
    await addAdmin(f.pool);
    const real = new FakeOnecGateway();
    let calls = 0;
    let fail = true;
    const gw = Object.assign(Object.create(real) as FakeOnecGateway, {
      getChanges: (...a: Parameters<OnecGateway['getChanges']>) => {
        calls += 1;
        return fail ? Promise.reject(unauthorized()) : real.getChanges(...a);
      },
    });
    const svc = new OnecChangesService(f.pool, gw, new CatalogApplier(), createRunTracker(f.pool), silent, {
      reconcileWithHealth: false,
      authPause: pause(f.pool),
    });
    await expect(svc.pullOnce()).rejects.toBeInstanceOf(OnecError);
    expect(calls).toBe(1);
    const node = await f.pool.query<{ code: string; paused: boolean }>(
      `SELECT last_error_code AS code, auth_error_at > now() - interval '1 minute' AS paused FROM sync_node_state`,
    );
    expect(node.rows[0]).toEqual({ code: 'ONEC_REJECTED', paused: true });
    const n = await f.pool.query<{ title: string; trigger: string }>(
      `SELECT title_ru AS title, payload->>'trigger' AS trigger FROM notifications WHERE kind = 'sync_error'`,
    );
    expect(n.rows).toEqual([{ title: '1С отклонила доступ POS', trigger: 'onec_auth_failed' }]);

    fail = false;
    const second = await svc.pullOnce();
    expect(second.status).toBe('paused_auth');
    expect(second.pausedUntil).toBeDefined();
    expect(calls).toBe(1); // к 1С не обращались

    // Пауза истекла (отметка 16 мин назад) — цикл снова читает и применяет сообщение.
    await f.pool.query(`UPDATE sync_node_state SET auth_error_at = now() - interval '16 minutes'`);
    const third = await svc.pullOnce();
    expect(third.status).toBe('applied');
    expect(calls).toBeGreaterThan(1);
  });
});

describe('SyncJobProcessor: 401/403 — без повторов pg-boss, пауза и пропуск следующих запусков', () => {
  it('ошибка 401 внутри SyncRunError: прогон failed с ONEC_REJECTED, consecutive_errors растёт сразу, job не перезапускается; следующий плановый — skipped, ручной — failed с причиной', async () => {
    const f = await fresh();
    const registry = new SyncRunRegistry(f.pool, 900, DEFAULT_STATE_DEFAULTS);
    let runs = 0;
    const handler: SyncEntityHandler = {
      run: () => {
        runs += 1;
        return Promise.reject(
          new SyncRunError(
            'ONEC_UNAVAILABLE',
            `статусы заказов 1С недоступны: 401 POS_E_UNAUTHORIZED: ${new OnecError('getOrderStatusBatch', 401, 'POS_E_UNAUTHORIZED', 'x').message}`,
          ),
        );
      },
    };
    const processor = new SyncJobProcessor(registry, () => handler, f.pool, silent, pause(f.pool));
    // Первая попытка из пяти: без исправления — исключение (повтор pg-boss) и consecutive_errors без изменений.
    const first = await processor.process(
      { id: 'job-1', retryCount: 0, retryLimit: 5 },
      { entity: 'order_status', mode: 'incremental', trigger: 'schedule' },
    );
    expect(first).toMatchObject({ status: 'failed', code: 'ONEC_AUTH_FAILED' });
    const st = await f.pool.query<{ n: number }>(
      `SELECT consecutive_errors AS n FROM sync_state WHERE entity = 'order_status'`,
    );
    expect(st.rows[0]?.n).toBe(1);
    const errs = await f.pool.query<{ code: string; auth: string }>(
      `SELECT error_code AS code, payload->>'authFailure' AS auth FROM sync_errors WHERE entity = 'order_status'`,
    );
    expect(errs.rows).toEqual([{ code: 'ONEC_REJECTED', auth: 'true' }]);

    const next = await processor.process(
      { id: 'job-2', retryCount: 0, retryLimit: 5 },
      { entity: 'receivables', mode: 'incremental', trigger: 'schedule' },
    );
    expect(next).toMatchObject({ status: 'skipped', code: 'ONEC_AUTH_PAUSED' });
    expect(runs).toBe(1);
    const recv = await f.pool.query(`SELECT 1 FROM sync_runs WHERE entity = 'receivables'`);
    expect(recv.rowCount).toBe(0);

    const runId = await registry.enqueue({ entity: 'products', mode: 'incremental', trigger: 'manual' });
    const manual = await processor.process(
      { id: 'job-3', retryCount: 0, retryLimit: 2 },
      { entity: 'products', mode: 'incremental', trigger: 'manual', runId },
    );
    expect(manual).toMatchObject({ status: 'skipped', code: 'ONEC_AUTH_PAUSED', runId });
    const run = await f.pool.query<{ status: string; summary: string }>(
      `SELECT status::text AS status, error_summary AS summary FROM sync_runs WHERE id = $1`,
      [runId],
    );
    expect(run.rows[0]?.status).toBe('failed');
    expect(run.rows[0]?.summary).toMatch(/приостановлено/);
    expect(runs).toBe(1);
  });

  it('прочие ошибки — как раньше: исключение для повтора pg-boss, пауза не включается', async () => {
    const f = await fresh();
    const registry = new SyncRunRegistry(f.pool, 900, DEFAULT_STATE_DEFAULTS);
    const handler: SyncEntityHandler = {
      run: () => Promise.reject(new SyncRunError('ONEC_UNAVAILABLE', 'getChanges: 503 POS_E_MAINTENANCE — обновление')),
    };
    const processor = new SyncJobProcessor(registry, () => handler, f.pool, silent, pause(f.pool));
    await expect(
      processor.process(
        { id: 'job-1', retryCount: 0, retryLimit: 5 },
        { entity: 'order_status', mode: 'incremental', trigger: 'schedule' },
      ),
    ).rejects.toBeInstanceOf(SyncRunError);
    const node = await f.pool.query<{ at: Date | null }>(`SELECT auth_error_at AS at FROM sync_node_state`);
    expect(node.rows[0]?.at ?? null).toBeNull();
  });
});
