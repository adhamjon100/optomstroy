import 'reflect-metadata';
import type pg from 'pg';
import pino from 'pino';
import type { AuthenticatedPrincipal } from '../../src/common/auth/principal.js';
import type { AppConfig } from '../../src/common/config/app-config.js';
import { SYNC_ENTITY_VALUES } from '../../src/common/enums.js';
import type { PgBossService } from '../../src/common/jobs/pg-boss.service.js';
import type { PermissionCatalog } from '../../src/common/rbac/permission-catalog.js';
import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import type { OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import { ChangesSyncHandler } from '../../src/jobs/sync/changes-sync.handler.js';
import type { SyncEntityHandler } from '../../src/jobs/sync/sync-handler.js';
import { SyncJobProcessor } from '../../src/jobs/sync/sync-job.processor.js';
import {
  isApiVersionCompatible,
  OnecApiCompatibility,
  OnecApiPausedError,
} from '../../src/sync/alerts/onec-api-compat.js';
import { SyncAlertService } from '../../src/sync/alerts/sync-alerts.service.js';
import { DEFAULT_SYNC_API_OPTIONS } from '../../src/sync/api/sync-api.common.js';
import { SyncStatusService } from '../../src/sync/api/sync-status.service.js';
import type { ApplyRunTracker } from '../../src/sync/apply/apply.types.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { DEFAULT_STATE_DEFAULTS, RegistryRunTracker } from '../../src/sync/apply/run-tracker.js';
import { SyncRunRegistry } from '../../src/sync/scheduler/sync-run.registry.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';

/**
 * 12 T-SYNC-F13 / T-COMPAT-008 (05 ONEC-095, F13; SYNC-028, SYNC-037, SYNC-038): несовместимая `apiVersion` в
 * `GET /pos/v1/health` расширения → обмен `paused` без потери данных (`/changes` не читается, ack не уходит,
 * регистрации плана обмена остаются в 1С), понятная причина (`sync_state.paused_reason`, ручной прогон с причиной,
 * `GET /sync/status` → `paused`, `degraded`) и уведомление администратору; совместимая версия — возобновление.
 * Данные — фейк 1С и фикстуры (тестовые данные).
 */
const silent = pino({ level: 'silent' });
let server: EmbeddedPg;
let f: CatalogFixture;

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
  f = await startCatalogFixture({
    pg: server,
    database: 'api_compat',
    skuCount: 0,
    includeFixtures: false,
    skipLoad: true,
  });
  const u = await f.pool.query<{ id: string }>(
    `INSERT INTO users (phone_e164, kind, status) VALUES ('+996700000902', 'staff', 'active') RETURNING id`,
  );
  await f.pool.query(`INSERT INTO user_roles (user_id, role_id) SELECT $1, id FROM roles WHERE code = 'admin'`, [
    u.rows[0].id,
  ]);
  // Строки sync_state всех сущностей (как после seed этапа C): свежие, без ошибок — общий статус `ok`.
  for (const entity of SYNC_ENTITY_VALUES) {
    await f.pool.query(
      `INSERT INTO sync_state (entity, schedule_cron, max_age_warning_sec, last_success_at)
       VALUES ($1, '*/30 * * * *', 3600, now()) ON CONFLICT (entity) DO NOTHING`,
      [entity],
    );
  }
});

afterAll(async () => {
  await f?.stop();
  await server?.stop();
});

describe('isApiVersionCompatible (мажорная версия API расширения = 1)', () => {
  it('«1», «1.1», « 1 » — совместимы; «2», «0», «odata», «», «1a» — нет', () => {
    for (const v of ['1', '1.1', '1.0.3', ' 1 ']) expect(isApiVersionCompatible(v), v).toBe(true);
    for (const v of ['2', '2.0', '0', 'odata', '', '1a', 'v1']) expect(isApiVersionCompatible(v), v).toBe(false);
  });
});

describe('T-SYNC-F13: несовместимая apiVersion → обмен paused, причина, уведомление; совместимая — возобновление', () => {
  const real = new FakeOnecGateway();
  const health = { apiVersion: '2', down: false };
  let changesCalls = 0;
  const gw = Object.assign(Object.create(real) as FakeOnecGateway, {
    getHealth: async (...a: Parameters<OnecGateway['getHealth']>) => {
      if (health.down) throw new OnecError('getHealth', 503, 'POS_E_MAINTENANCE', 'обновление конфигурации');
      const r = await real.getHealth(...a);
      return { ...r, body: { ...r.body, apiVersion: health.apiVersion, extensionVersion: '2.0.0' } };
    },
    getChanges: (...a: Parameters<OnecGateway['getChanges']>) => {
      changesCalls += 1;
      return real.getChanges(...a);
    },
  });
  let pool: pg.Pool;
  let compat: OnecApiCompatibility;
  let registry: SyncRunRegistry;
  let changesFor: (t: ApplyRunTracker) => OnecChangesService;
  let processor: SyncJobProcessor;
  let handlerCalls = 0;
  let status: SyncStatusService;

  const nodeNumber = async () =>
    (await pool.query<{ n: string }>(`SELECT last_message_number::text AS n FROM sync_node_state WHERE node = 'pos'`))
      .rows[0]?.n;
  const notifications = async () =>
    (
      await pool.query<{ title: string; trigger: string; body: string }>(
        `SELECT title_ru AS title, payload->>'trigger' AS trigger, body_ru AS body FROM notifications
          WHERE kind = 'sync_error' ORDER BY created_at, id`,
      )
    ).rows;
  const paused = async () =>
    (
      await pool.query<{ entity: string; paused: boolean; reason: string | null }>(
        `SELECT entity::text AS entity, paused, paused_reason AS reason FROM sync_state ORDER BY entity`,
      )
    ).rows;
  const full = {} as AuthenticatedPrincipal;

  beforeAll(() => {
    pool = f.pool;
    compat = new OnecApiCompatibility(pool, { alerts: new SyncAlertService(pool, silent), log: silent });
    registry = new SyncRunRegistry(pool, 900, DEFAULT_STATE_DEFAULTS);
    const tracker = new RegistryRunTracker(registry, pool);
    changesFor = (t) =>
      new OnecChangesService(pool, gw, new CatalogApplier(), t, silent, { apiCompat: compat, pageSize: 1000 });
    const plan = new ChangesSyncHandler(pool, tracker, changesFor);
    const polled: SyncEntityHandler = {
      run: () => {
        handlerCalls += 1;
        return Promise.resolve({ implemented: true, counts: {} });
      },
    };
    processor = new SyncJobProcessor(
      registry,
      (e) => (e === 'products' ? plan : polled),
      pool,
      silent,
      null,
      new OnecApiCompatibility(pool, { log: silent }),
    );
    status = new SyncStatusService(
      pool,
      { SYNC_ALERT_UNREACHABLE_MIN: 10, MANUAL_ORDER_SLA_MIN: 60, TZ: 'Asia/Bishkek' } as AppConfig,
      DEFAULT_SYNC_API_OPTIONS,
      { effectivePermissions: () => new Set(['sync.runs.read']) } as unknown as PermissionCatalog,
      { instance: undefined } as unknown as PgBossService,
    );
  });

  it('до проверки версии — общий статус ok, пауз нет', async () => {
    const s = await status.status(full);
    expect(s.overall).toBe('ok');
    expect(s.entities.every((e) => e.paused === false)).toBe(true);
  });

  it('ручной incremental сущности плана обмена: цикл видит apiVersion=2 → прогон failed с причиной, без роста consecutive_errors; /changes не читался', async () => {
    const before = await nodeNumber();
    const runId = await registry.enqueue({ entity: 'products', mode: 'incremental', trigger: 'manual' });
    const out = await processor.process(
      { id: 'job-manual-1', retryCount: 0, retryLimit: 2 },
      { entity: 'products', mode: 'incremental', trigger: 'manual', runId },
    );
    expect(out).toMatchObject({ status: 'skipped', code: 'ONEC_API_PAUSED', runId });
    expect(changesCalls).toBe(0);
    const run = await pool.query<{ status: string; summary: string }>(
      `SELECT status::text AS status, error_summary AS summary FROM sync_runs WHERE id = $1`,
      [runId],
    );
    expect(run.rows[0].status).toBe('failed');
    expect(run.rows[0].summary).toMatch(/^api_incompatible: .*«2».*расширение 2\.0\.0.*приостановлен/);
    const st = await pool.query<{ n: number }>(
      `SELECT consecutive_errors AS n FROM sync_state WHERE entity = 'products'`,
    );
    expect(st.rows[0].n).toBe(0);
    // Все сущности приостановлены с одной причиной; версия — в sync_node_state; номер узла не сдвинут.
    const rows = await paused();
    expect(rows).toHaveLength(SYNC_ENTITY_VALUES.length);
    expect(rows.every((r) => r.paused && r.reason === run.rows[0].summary)).toBe(true);
    const node = await pool.query<{ api: string; ext: string }>(
      `SELECT api_version AS api, extension_version AS ext FROM sync_node_state WHERE node = 'pos'`,
    );
    expect(node.rows[0]).toEqual({ api: '2', ext: '2.0.0' });
    expect(await nodeNumber()).toBe(before);
    // Уведомление администратору — одно (повтор не чаще раза в час).
    const n = await notifications();
    expect(n).toEqual([expect.objectContaining({ trigger: 'api_incompatible' })]);
    expect(n[0].body).toMatch(/«2».*данные не потеряны/);
  });

  it('плановый цикл onec.changes: paused_api, к /changes не обращается; /health недоступен — пауза сохраняется; повторного уведомления в течение часа нет', async () => {
    const svc = changesFor(new RegistryRunTracker(registry, pool));
    const r1 = await svc.pullOnce();
    expect(r1.status).toBe('paused_api');
    expect(r1.pausedReason).toMatch(/^api_incompatible/);
    health.down = true;
    const r2 = await svc.pullOnce();
    health.down = false;
    expect(r2.status).toBe('paused_api');
    expect(changesCalls).toBe(0);
    expect(await notifications()).toHaveLength(1);
    const runs = await pool.query(`SELECT 1 FROM sync_runs WHERE onec_endpoint = 'GET /pos/v1/changes'`);
    expect(runs.rowCount).toBe(0);
  });

  it('прогоны сущностей при паузе: плановый — пропуск без строки sync_runs и без обращения к обработчику; ручной — failed с причиной', async () => {
    const sched = await processor.process(
      { id: 'job-stock-1', retryCount: 0, retryLimit: 2 },
      { entity: 'stock', mode: 'incremental', trigger: 'schedule' },
    );
    expect(sched).toMatchObject({ status: 'skipped', code: 'ONEC_API_PAUSED' });
    expect((await pool.query(`SELECT 1 FROM sync_runs WHERE entity = 'stock'`)).rowCount).toBe(0);
    const runId = await registry.enqueue({ entity: 'receivables', mode: 'incremental', trigger: 'manual' });
    const manual = await processor.process(
      { id: 'job-recv-1', retryCount: 0, retryLimit: 2 },
      { entity: 'receivables', mode: 'incremental', trigger: 'manual', runId },
    );
    expect(manual).toMatchObject({ status: 'skipped', code: 'ONEC_API_PAUSED', runId });
    expect(handlerCalls).toBe(0);
    const run = await pool.query<{ status: string; summary: string }>(
      `SELECT status::text AS status, error_summary AS summary FROM sync_runs WHERE id = $1`,
      [runId],
    );
    expect(run.rows[0]).toMatchObject({ status: 'failed' });
    expect(run.rows[0].summary).toMatch(/^api_incompatible/);
    // Singleton занят — ручной прогон не создаётся, ответ — та же пауза.
    const busy = await registry.enqueue({ entity: 'customers', mode: 'incremental', trigger: 'manual' });
    const other = await processor.process(
      { id: 'job-cust-1', retryCount: 0, retryLimit: 2 },
      { entity: 'customers', mode: 'incremental', trigger: 'manual', runId: '00000000-0000-7000-8000-00000000c0de' },
    );
    expect(other).toMatchObject({ status: 'skipped', code: 'ONEC_API_PAUSED' });
    expect(other).not.toHaveProperty('runId');
    await registry.abandon(busy, 'тест');
  });

  it('GET /sync/status: сущности paused, общий статус degraded', async () => {
    const s = await status.status(full);
    expect(s.overall).toBe('degraded');
    expect(s.entities.filter((e) => e.paused)).toHaveLength(SYNC_ENTITY_VALUES.length);
  });

  it('совместимая версия снова: пауза снята, уведомление «обмен возобновлён», цикл читает /changes, прогоны выполняются', async () => {
    health.apiVersion = '1';
    const svc = changesFor(new RegistryRunTracker(registry, pool));
    const r = await svc.pullOnce();
    expect(r.status).not.toBe('paused_api');
    expect(changesCalls).toBeGreaterThan(0);
    expect((await paused()).every((x) => !x.paused && x.reason === null)).toBe(true);
    const n = await notifications();
    expect(n.map((x) => x.trigger)).toEqual(['api_incompatible', 'api_restored']);
    // Повторная совместимая проверка — без новых уведомлений.
    await svc.pullOnce();
    expect(await notifications()).toHaveLength(2);
    const out = await processor.process(
      { id: 'job-stock-2', retryCount: 0, retryLimit: 2 },
      { entity: 'stock', mode: 'incremental', trigger: 'schedule' },
    );
    expect(out).toMatchObject({ status: 'completed' });
    expect(handlerCalls).toBe(1);
    expect((await status.status(full)).overall).toBe('ok');
  });

  it('OnecApiPausedError несёт причину; ошибка чтения отметки паузу не включает', async () => {
    expect(new OnecApiPausedError('api_incompatible: x').reason).toBe('api_incompatible: x');
    const broken = new OnecApiCompatibility(
      { query: () => Promise.reject(new Error('БД недоступна')) },
      { log: silent },
    );
    expect(await broken.active()).toBeNull();
  });
});
