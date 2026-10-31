import type pg from 'pg';
import { PgBoss } from 'pg-boss';
import pino from 'pino';
import type { AuthenticatedPrincipal } from '../../src/common/auth/principal.js';
import { type AppConfig, loadAppConfig } from '../../src/common/config/app-config.js';
import type { SyncEntity } from '../../src/common/enums.js';
import type { PgBossService } from '../../src/common/jobs/pg-boss.service.js';
import type { PermissionCatalog } from '../../src/common/rbac/permission-catalog.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import { createSyncWorkerWiring } from '../../src/jobs/sync/sync-worker.wiring.js';
import { DEFAULT_SYNC_API_OPTIONS } from '../../src/sync/api/sync-api.common.js';
import { type SyncStatusDto, SyncStatusService } from '../../src/sync/api/sync-status.service.js';
import { SyntheticCatalogSource } from '../../src/sync/apply/catalog-source.js';
import { ONEC_PLAN_ENTITIES, type OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { ScheduleResolver } from '../../src/sync/scheduler/schedule-resolver.js';
import { schedulerConfigFromEnv } from '../../src/sync/scheduler/scheduler.config.js';
import { SyncScheduler } from '../../src/sync/scheduler/sync-scheduler.js';
import { EXTENSION_PLAN_ENTITIES, EXTENSION_POLLED_ENTITIES } from '../../src/sync/scheduler/sync-queues.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';

/**
 * POSAPI-T1-01 (демо WP-T1, critic C4.3b/C4.10b): в `ONEC_MODE=extension` справочники и документы плана обмена
 * становились `isStale` (и `GET /sync/status` — `degraded`, «Есть задержки») через час после **своего последнего
 * изменения в 1С**, хотя цикл `onec.changes` каждые 5 мин успешно опрашивал 1С и изменений не было. Свежесть по
 * 05 §7.2 (в конце цикла — `sync_state.last_success_at`), §7.4 (порог 1: возраст от `last_success_at`), SYNC-026,
 * SYNC-027 — от последнего **успешного обмена**: пустое сообщение плана обмена доказывает, что данные актуальны.
 * Стенд — та же сборка, что у `pos-worker` (`createSyncWorkerWiring`), embedded PostgreSQL 17, синтетический каталог
 * и фейк 1С (тестовые данные, не реальная интеграция).
 */
const silent = pino({ level: 'silent' });
const MIN = 60_000;
let server: EmbeddedPg;
let dbNo = 0;
const open: CatalogFixture[] = [];

async function fresh(): Promise<CatalogFixture> {
  const f = await startCatalogFixture({ pg: server, database: `freshness_${++dbNo}`, skuCount: 40 });
  open.push(f);
  return f;
}

function configFor(mode: AppConfig['ONEC_MODE']): AppConfig {
  const base = loadAppConfig({
    APP_ENV: 'dev',
    MIN_APP_VERSION: 'android=1.0.0',
    DATABASE_URL: 'postgres://x:y@127.0.0.1:1/none',
    ONEC_MODE: 'fixtures',
  });
  return { ...base, ONEC_MODE: mode };
}

/** Цикл `onec.changes` ровно как в `pos-worker` (шлюз — фейк 1С фикстуры). */
function changesFor(f: CatalogFixture, mode: AppConfig['ONEC_MODE']): OnecChangesService {
  const w = createSyncWorkerWiring({
    config: configFor(mode),
    pool: f.pool,
    log: silent,
    gateway: f.gateway,
    source: new SyntheticCatalogSource(f.gateway),
    images: null,
  });
  if (!w.changes) throw new Error('onec.changes не собран');
  return w.changes;
}

/** `GET /sync/status` полного вида (`sync.runs.read`) на момент `now`. */
function statusOf(pool: pg.Pool): (now?: Date) => Promise<SyncStatusDto> {
  const catalog = { effectivePermissions: () => new Set(['sync.runs.read']) } as unknown as PermissionCatalog;
  const boss = { instance: undefined } as unknown as PgBossService;
  const svc = new SyncStatusService(pool, configFor('extension'), DEFAULT_SYNC_API_OPTIONS, catalog, boss);
  return (now = new Date()) => svc.status({} as AuthenticatedPrincipal, now);
}

const staleOf = (s: SyncStatusDto): SyncEntity[] =>
  s.entities
    .filter((e) => e.isStale)
    .map((e) => e.entity)
    .sort();

/** Строки `sync_state` документов и скидок — как их создаёт первое изменение в 1С (умолчания реестра прогонов). */
async function addDocumentRows(pool: pg.Pool): Promise<void> {
  await pool.query(
    `INSERT INTO sync_state (entity, schedule_cron, max_age_warning_sec, last_success_at)
     SELECT e::sync_entity, '*/30 * * * *', 3600, now() FROM unnest($1::text[]) AS e
     ON CONFLICT (entity) DO NOTHING`,
    [['discounts', 'sales_history', 'return_docs']],
  );
}

/** Сущности плана обмена режима расширения, у которых есть строка `sync_state` с успешной загрузкой. */
async function planRows(pool: pg.Pool): Promise<SyncEntity[]> {
  const r = await pool.query<{ entity: SyncEntity }>(
    `SELECT entity::text AS entity FROM sync_state WHERE entity::text = ANY($1::text[]) AND last_success_at IS NOT NULL`,
    [[...EXTENSION_PLAN_ENTITIES]],
  );
  return r.rows.map((x) => x.entity).sort();
}

/** «Прошло N минут после последнего изменения в 1С»: сдвиг `last_success_at` назад. */
async function age(pool: pg.Pool, entities: readonly SyncEntity[], minutes: number): Promise<void> {
  await pool.query(
    `UPDATE sync_state SET last_success_at = now() - make_interval(mins => $2) WHERE entity::text = ANY($1::text[])`,
    [entities, minutes],
  );
}

interface StateRow {
  last_success_at: string | null;
  last_success_run_id: string | null;
  last_run_id: string | null;
  last_cursor: string | null;
  consecutive_errors: number;
}

async function states(pool: pg.Pool): Promise<Record<string, StateRow>> {
  const r = await pool.query<StateRow & { entity: string }>(
    `SELECT entity::text AS entity, last_success_at::text AS last_success_at, last_success_run_id::text AS last_success_run_id,
            last_run_id::text AS last_run_id, last_cursor, consecutive_errors
       FROM sync_state`,
  );
  return Object.fromEntries(r.rows.map(({ entity, ...row }) => [entity, row]));
}

const runCount = async (pool: pg.Pool): Promise<number> =>
  (await pool.query<{ n: number }>(`SELECT count(*)::int AS n FROM sync_runs`)).rows[0].n;

const pick = (s: Record<string, StateRow>, entities: readonly string[], k: keyof StateRow) =>
  Object.fromEntries(entities.map((e) => [e, s[e]?.[k]]));

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
});

afterAll(async () => {
  for (const f of open) await f.stop();
  await server?.stop();
});

describe('onec.changes: свежесть сущностей плана обмена от последнего успешного цикла (POSAPI-T1-01; 05 §7.2, §7.4, SYNC-026)', () => {
  it('пустой успешный цикл: через 61 мин без изменений в 1С сущности плана свежие, overall=ok; прогонов sync_runs и ack нет; порог 60 мин отсчитывается от цикла', async () => {
    const f = await fresh();
    const changes = changesFor(f, 'extension');
    const status = statusOf(f.pool);
    await addDocumentRows(f.pool);
    const plan = await planRows(f.pool);
    expect(plan).toEqual(
      expect.arrayContaining(['categories', 'products', 'discounts', 'sales_history', 'return_docs']),
    );
    await age(f.pool, plan, 61);
    // Проявление дефекта до цикла: устарели ровно сущности плана, overall=degraded.
    const before = await status();
    expect(before.overall).toBe('degraded');
    expect(staleOf(before)).toEqual(plan);
    const s0 = await states(f.pool);
    const runs0 = await runCount(f.pool);

    const r = await changes.pullOnce();
    expect(r.status).toBe('empty');
    expect([...(r.freshConfirmed ?? [])].sort()).toEqual(plan);

    const after = await status();
    expect(after.overall).toBe('ok');
    expect(staleOf(after)).toEqual([]);
    for (const e of after.entities.filter((x) => plan.includes(x.entity))) expect(e.ageSec).toBeLessThan(60);
    // Порог по-прежнему действует: без следующих циклов через 59 мин — свежие, через 61 мин — снова устарели.
    const t = Date.now();
    const planStale = async (offsetMin: number) =>
      staleOf(await status(new Date(t + offsetMin * MIN))).filter((e) => plan.includes(e));
    expect(await planStale(59)).toEqual([]);
    expect(await planStale(61)).toEqual(plan);

    // sync_runs и аудит прогонов — без изменений: пустой цикл прогонов не пишет, ссылки и курсоры прежние.
    expect(await runCount(f.pool)).toBe(runs0);
    const s1 = await states(f.pool);
    expect(pick(s1, plan, 'last_success_run_id')).toEqual(pick(s0, plan, 'last_success_run_id'));
    expect(pick(s1, plan, 'last_run_id')).toEqual(pick(s0, plan, 'last_run_id'));
    expect(pick(s1, plan, 'last_cursor')).toEqual(pick(s0, plan, 'last_cursor'));
    // Срезы (stock, prices) свежесть от цикла плана обмена не получают.
    expect(pick(s1, ['stock', 'prices'], 'last_success_at')).toEqual(pick(s0, ['stock', 'prices'], 'last_success_at'));
    expect(f.gateway.calls.some((c) => c.operation === 'ackChanges')).toBe(false);
  });

  it('сбойный цикл свежесть не сдвигает: через 61 мин — degraded, после 3 сбоев подряд — failed; восстановление пустым циклом → ok, consecutive_errors 0', async () => {
    const f = await fresh();
    const changes = changesFor(f, 'extension');
    const status = statusOf(f.pool);
    const plan = await planRows(f.pool);
    await age(f.pool, plan, 61);
    const aged = pick(await states(f.pool), plan, 'last_success_at');
    const fail = async () => {
      f.gateway.exchange!.injectError(1, new OnecError('getChanges', 0, 'TRANSPORT', 'таймаут соединения'));
      await expect(changes.pullOnce()).rejects.toMatchObject({ code: 'TRANSPORT' });
    };

    await fail();
    expect(pick(await states(f.pool), plan, 'last_success_at')).toEqual(aged);
    const s1 = await status();
    expect(s1.overall).toBe('degraded');
    expect(staleOf(s1)).toEqual(plan);
    // След сбоя — как прежде (SYNC-029 (б), SYNC-038): прогоны failed по сущностям плана, consecutive_errors +1.
    const failed = await f.pool.query<{ entity: string }>(
      `SELECT DISTINCT entity::text AS entity FROM sync_runs WHERE status = 'failed'`,
    );
    expect(failed.rows.map((x) => x.entity).sort()).toEqual([...ONEC_PLAN_ENTITIES].sort());

    await fail();
    await fail();
    expect(pick(await states(f.pool), plan, 'last_success_at')).toEqual(aged);
    const s3 = await status();
    expect(s3.overall).toBe('failed');
    expect(s3.entities.filter((e) => plan.includes(e.entity)).every((e) => e.consecutiveErrors === 3)).toBe(true);

    const ok = await changes.pullOnce();
    expect(ok.status).toBe('empty');
    const s4 = await status();
    expect(s4.overall).toBe('ok');
    expect(s4.onecReachable).toBe(true);
    expect(
      s4.entities
        .filter((e) => plan.includes(e.entity))
        .every((e) => e.consecutiveErrors === 0 && !e.isStale && (e.ageSec ?? Infinity) < 60),
    ).toBe(true);
  });

  it('непустой цикл: прогон и sync_state затронутой сущности — как прежде; незатронутые сущности плана свежие без новых прогонов', async () => {
    const f = await fresh();
    const changes = changesFor(f, 'extension');
    const status = statusOf(f.pool);
    const plan = await planRows(f.pool);
    await age(f.pool, plan, 61);
    const s0 = await states(f.pool);
    const runs0 = await runCount(f.pool);
    f.gateway.mutateCatalog({ renameProducts: 2 });

    const r = await changes.pullOnce();
    expect(r.status).toBe('applied');
    const touched = Object.keys(r.runIds);
    expect(touched).toContain('products');
    expect(await runCount(f.pool)).toBe(runs0 + touched.length);
    const run = await f.pool.query<{ status: string; mode: string; cursor_to: string; endpoint: string }>(
      `SELECT status::text AS status, mode::text AS mode, cursor_to, onec_endpoint AS endpoint FROM sync_runs WHERE id = $1`,
      [r.runIds.products],
    );
    expect(run.rows[0]).toEqual({
      status: 'success',
      mode: 'incremental',
      cursor_to: String(r.messageNumber),
      endpoint: 'GET /pos/v1/changes',
    });
    const s1 = await states(f.pool);
    expect(s1.products).toMatchObject({
      last_success_run_id: r.runIds.products,
      last_run_id: r.runIds.products,
      last_cursor: String(r.messageNumber),
      consecutive_errors: 0,
    });

    const untouched = plan.filter((e) => !touched.includes(e));
    expect(untouched.length).toBeGreaterThan(0);
    expect([...(r.freshConfirmed ?? [])].sort()).toEqual(untouched);
    expect(pick(s1, untouched, 'last_success_run_id')).toEqual(pick(s0, untouched, 'last_success_run_id'));
    expect(pick(s1, untouched, 'last_cursor')).toEqual(pick(s0, untouched, 'last_cursor'));
    const s = await status();
    expect(s.overall).toBe('ok');
    expect(staleOf(s)).toEqual([]);
    expect(f.gateway.calls.some((c) => c.operation === 'ackChanges')).toBe(true);
  });

  it('ни разу не загруженная и приостановленная сущности свежими не становятся; вне режима расширения (у сущностей свои задания) пустой цикл свежесть не подтверждает', async () => {
    const f = await fresh();
    const status = statusOf(f.pool);
    // Строка без успешной загрузки (её создал сбой цикла) и пауза с причиной не по версии API.
    await f.pool.query(
      `INSERT INTO sync_state (entity, schedule_cron, max_age_warning_sec, consecutive_errors)
       VALUES ('payment_docs', '*/30 * * * *', 3600, 1)`,
    );
    await f.pool.query(
      `UPDATE sync_state SET paused = true, paused_reason = 'тест: пауза' WHERE entity = 'warehouses'`,
    );
    const plan = await planRows(f.pool);
    await age(f.pool, plan, 61);
    const aged = pick(await states(f.pool), plan, 'last_success_at');

    const fixtures = await changesFor(f, 'fixtures').pullOnce();
    expect(fixtures.status).toBe('empty');
    expect(fixtures.freshConfirmed).toBeUndefined();
    expect(pick(await states(f.pool), plan, 'last_success_at')).toEqual(aged);

    const ext = await changesFor(f, 'extension').pullOnce();
    expect(ext.status).toBe('empty');
    expect([...(ext.freshConfirmed ?? [])].sort()).toEqual(plan.filter((e) => e !== 'warehouses'));
    const s1 = await states(f.pool);
    expect(s1.warehouses.last_success_at).toBe(aged.warehouses);
    const st = await status();
    expect(st.entities.find((e) => e.entity === 'payment_docs')).toMatchObject({
      lastSuccessAt: null,
      isStale: true,
      consecutiveErrors: 0,
    });
    expect(st.entities.find((e) => e.entity === 'warehouses')).toMatchObject({ isStale: true, paused: true });
    expect(st.overall).toBe('degraded');
  });

  // Ревью F6, F7: применённое, но не подтверждённое сообщение (ack не прошёл) и `stale` свежесть незатронутых
  // сущностей не подтверждают — иначе непрерывные `applied_not_acked` выглядели бы как overall=ok.
  it('applied_not_acked и stale свежесть незатронутых не подтверждают; повтор сообщения с успешным ack — подтверждает', async () => {
    const f = await fresh();
    const changes = changesFor(f, 'extension');
    const status = statusOf(f.pool);
    const plan = await planRows(f.pool);
    await age(f.pool, plan, 61);
    const aged = pick(await states(f.pool), plan, 'last_success_at');
    f.gateway.mutateCatalog({ renameProducts: 2 });
    const realAck = f.gateway.ackChanges.bind(f.gateway);
    let failAck = true;
    f.gateway.ackChanges = (n, o) =>
      failAck ? Promise.reject(new OnecError('ackChanges', 0, 'TRANSPORT', 'сеть')) : realAck(n, o);

    const r1 = await changes.pullOnce();
    expect(r1.status).toBe('applied_not_acked');
    expect(r1.freshConfirmed).toBeUndefined();
    const touched = Object.keys(r1.runIds);
    const untouched = plan.filter((e) => !touched.includes(e));
    expect(untouched.length).toBeGreaterThan(0);
    const agedUntouched = Object.fromEntries(untouched.map((e) => [e, aged[e]]));
    expect(pick(await states(f.pool), untouched, 'last_success_at')).toEqual(agedUntouched);
    const s1 = await status();
    expect(s1.overall).toBe('degraded');
    expect(staleOf(s1)).toEqual(untouched);

    // `stale`: номер сообщения не больше применённого — только ack, свежесть не сдвигается.
    const realGet = f.gateway.getChanges.bind(f.gateway);
    f.gateway.getChanges = async (q, o) => {
      const res = await realGet(q, o);
      return { ...res, body: { ...res.body, messageNumber: q.since } };
    };
    failAck = false;
    const r2 = await changes.pullOnce();
    expect(r2.status).toBe('stale');
    expect(r2.freshConfirmed).toBeUndefined();
    expect(pick(await states(f.pool), untouched, 'last_success_at')).toEqual(agedUntouched);
    f.gateway.getChanges = realGet;

    // Повтор того же сообщения, ack прошёл — незатронутые сущности свежие.
    const r3 = await changes.pullOnce();
    expect(r3.status).toBe('applied');
    const touched3 = Object.keys(r3.runIds);
    expect([...(r3.freshConfirmed ?? [])].sort()).toEqual(plan.filter((e) => !touched3.includes(e)));
    const s3 = await status();
    expect(s3.overall).toBe('ok');
    expect(staleOf(s3)).toEqual([]);
  });

  // Ревью F5: свежесть не уходит назад, а сущность с идущим прогоном (full/reconcile/ручной) цикл не трогает.
  it('last_success_at не уходит назад (GREATEST); сущность с прогоном queued/running пропускается вместе со счётчиком ошибок', async () => {
    const f = await fresh();
    const changes = changesFor(f, 'extension');
    const plan = await planRows(f.pool);
    expect(plan).toEqual(expect.arrayContaining(['categories', 'products']));
    await age(f.pool, plan, 61);
    // categories — «прогон закончился позже начала цикла»: время успеха впереди момента цикла.
    await f.pool.query(
      `UPDATE sync_state SET last_success_at = now() + interval '10 minutes' WHERE entity = 'categories'`,
    );
    // products — идёт ручной полный прогон, у сущности 2 сбоя подряд.
    await f.pool.query(`UPDATE sync_state SET consecutive_errors = 2 WHERE entity = 'products'`);
    const run = await f.pool.query<{ id: string }>(
      `INSERT INTO sync_runs (entity, mode, "trigger", status, started_at)
       VALUES ('products', 'full', 'manual', 'running', now()) RETURNING id::text AS id`,
    );
    const s0 = await states(f.pool);

    const r = await changes.pullOnce();
    expect(r.status).toBe('empty');
    const confirmed = [...(r.freshConfirmed ?? [])].sort();
    expect(confirmed).toContain('categories');
    expect(confirmed).not.toContain('products');
    const s1 = await states(f.pool);
    expect(s1.categories.last_success_at).toBe(s0.categories.last_success_at);
    expect(s1.products).toMatchObject({ last_success_at: s0.products.last_success_at, consecutive_errors: 2 });
    for (const e of plan.filter((x) => x !== 'categories' && x !== 'products')) {
      expect(Date.parse(s1[e].last_success_at!), e).toBeGreaterThan(Date.parse(s0[e].last_success_at!));
    }
    await f.pool.query(`UPDATE sync_runs SET status = 'failed', finished_at = now() WHERE id = $1::uuid`, [
      run.rows[0].id,
    ]);
  });

  // Ревью F4: в режиме расширения «расписание» и порог 1 сущностей плана — от цикла onec.changes (2 его периода),
  // а не SYNC_MASTER_CRON/3600 с: при sync_interval ≥ 60 мин overall не «мигает» degraded перед каждым циклом.
  it('планировщик (extension): schedule_cron и max_age_warning_sec сущностей плана — от onec.changes; строки не создаются', async () => {
    const f = await fresh();
    const changes = changesFor(f, 'extension');
    const status = statusOf(f.pool);
    const plan = await planRows(f.pool);
    const entityList = async () =>
      (
        await f.pool.query<{ entity: string }>(
          `SELECT entity::text AS entity FROM sync_state WHERE entity::text = ANY($1::text[]) ORDER BY 1`,
          [[...EXTENSION_PLAN_ENTITIES]],
        )
      ).rows.map((x) => x.entity);
    const polled0 = await f.pool.query<{ entity: string; schedule_cron: string }>(
      `SELECT entity::text AS entity, schedule_cron FROM sync_state WHERE entity::text = ANY($1::text[])`,
      [[...EXTENSION_POLLED_ENTITIES]],
    );
    const rows0 = await entityList();
    // Только previewSchedule настоящего pg-boss (без подключения к БД); расписания pg-boss здесь не нужны.
    const preview = new PgBoss({ connectionString: 'postgres://x:y@127.0.0.1:1/none' });
    const boss = {
      getSchedules: () => Promise.resolve([]),
      schedule: () => Promise.resolve(),
      unschedule: () => Promise.resolve(),
      previewSchedule: (e: string, o: { tz: string; count: number }) => preview.previewSchedule(e, o),
    } as unknown as PgBoss;
    const cfg = schedulerConfigFromEnv(configFor('extension'));
    const settings = { get: (k: string) => Promise.resolve(k === 'sync_interval.customers' ? 60 : undefined) };
    const scheduler = new SyncScheduler(boss, f.pool, cfg, new ScheduleResolver(cfg, settings), silent);
    await scheduler.apply();

    expect(await entityList()).toEqual(rows0);
    const r = await f.pool.query<{ entity: string; schedule_cron: string; max_age_warning_sec: number }>(
      `SELECT entity::text AS entity, schedule_cron, max_age_warning_sec FROM sync_state`,
    );
    const byEntity = new Map(r.rows.map((x) => [x.entity, x]));
    for (const e of plan) {
      expect(byEntity.get(e), e).toMatchObject({
        schedule_cron: 'FREQ=MINUTELY;INTERVAL=60',
        max_age_warning_sec: 7200,
      });
    }
    // Срезы — по своим расписаниям, как и раньше.
    for (const p of polled0.rows) {
      expect(byEntity.get(p.entity)?.schedule_cron, p.entity).not.toBe('FREQ=MINUTELY;INTERVAL=60');
    }
    // Цикл раз в 60 мин: через 61 мин после пустого цикла сущности плана ещё свежие, через 121 — устарели.
    expect((await changes.pullOnce()).status).toBe('empty');
    const t = Date.now();
    const planStale = async (offsetMin: number) =>
      staleOf(await status(new Date(t + offsetMin * MIN))).filter((e) => plan.includes(e));
    expect(await planStale(61)).toEqual([]);
    expect(await planStale(121)).toEqual(plan);
  });
});
