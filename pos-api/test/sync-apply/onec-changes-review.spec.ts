import type pg from 'pg';
import pino from 'pino';
import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import type { OnecChangesPage, OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import { ChangesSyncHandler } from '../../src/jobs/sync/changes-sync.handler.js';
import { SyncAlertService } from '../../src/sync/alerts/sync-alerts.service.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { CatalogFullLoadService } from '../../src/sync/apply/catalog-full-load.service.js';
import {
  type CatalogFullSource,
  type CatalogReadKind,
  SyntheticCatalogSource,
} from '../../src/sync/apply/catalog-source.js';
import { ONEC_PLAN_ENTITIES, OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { createRunTracker, DEFAULT_STATE_DEFAULTS, RegistryRunTracker } from '../../src/sync/apply/run-tracker.js';
import { SyncRunRegistry } from '../../src/sync/scheduler/sync-run.registry.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';

/**
 * Регрессии ревью этапа E (sync): singleton цикла `onec.changes` на весь цикл до ack (E-onec-sync-1, AC-SYNC-011),
 * след сбоя цикла вне откатанной транзакции и алерт о недоступности 1С (E-onec-sync-2, RM-E-002 п. 2, SYNC-038),
 * `hasMore=true` без курсора (E-onec-sync-6), пометка удалённых в инкременте фазы 0 (E-onec-sync-3, SYNC-006).
 * Данные — синтетический каталог и фейк 1С (тестовые данные, не реальная интеграция).
 */
const silent = pino({ level: 'silent' });
let server: EmbeddedPg;
let dbNo = 0;
const open: CatalogFixture[] = [];

async function fresh(skuCount = 40): Promise<CatalogFixture> {
  const f = await startCatalogFixture({ pg: server, database: `review_e_${++dbNo}`, skuCount });
  open.push(f);
  return f;
}

function changes(
  pool: pg.Pool,
  gateway: OnecGateway,
  catalogGw: FakeOnecGateway,
  opts: { pageSize?: number; tracker?: ReturnType<typeof createRunTracker> } = {},
): OnecChangesService {
  return new OnecChangesService(pool, gateway, new CatalogApplier(), opts.tracker ?? createRunTracker(pool), silent, {
    pageSize: opts.pageSize ?? 1000,
    reconcileWithHealth: false,
    slices: new SyntheticCatalogSource(catalogGw),
  });
}

/** Шлюз-обёртка: перехват выбранных методов, остальное — исходный фейк (общий план обмена). */
function wrap(real: FakeOnecGateway, overrides: Partial<OnecGateway>): FakeOnecGateway {
  return Object.assign(Object.create(real) as FakeOnecGateway, overrides);
}

async function staleNames(f: CatalogFixture, refs: readonly string[]): Promise<number> {
  const expected = new Map(f.catalog.productItems().map((p) => [p.ref, p.description]));
  const r = await f.pool.query<{ ref: string; name: string }>(
    `SELECT onec_ref::text AS ref, name FROM products WHERE onec_ref = ANY($1::uuid[])`,
    [refs],
  );
  return r.rows.filter((x) => x.name !== expected.get(x.ref)).length;
}

async function addStaff(pool: pg.Pool, role: string, phone: string): Promise<string> {
  const u = await pool.query<{ id: string }>(
    `INSERT INTO users (phone_e164, kind, status) VALUES ($1, 'staff', 'active') RETURNING id`,
    [phone],
  );
  const id = u.rows[0].id;
  await pool.query(`INSERT INTO user_roles (user_id, role_id) SELECT $1, id FROM roles WHERE code = $2::role_code`, [
    id,
    role,
  ]);
  return id;
}

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
});

afterAll(async () => {
  for (const f of open) await f.stop();
  await server?.stop();
});

describe('onec.changes: singleton узла на весь цикл до ack (AC-SYNC-011; ревью E-onec-sync-1)', () => {
  it('пока первый цикл ждёт ack, плановый и ручной (ChangesSyncHandler) циклы получают skipped_locked без обращения к 1С; изменения не теряются', async () => {
    const f = await fresh(60);
    const real = f.gateway;
    real.mutateCatalog({ renameProducts: 1 });
    let inAck!: () => void;
    const inAckP = new Promise<void>((r) => (inAck = r));
    let releaseAck!: () => void;
    const releaseAckP = new Promise<void>((r) => (releaseAck = r));
    const gwA = wrap(real, {
      ackChanges: async (n, o) => {
        inAck();
        await releaseAckP;
        return real.ackChanges(n, o);
      },
    });
    const aP = changes(f.pool, gwA, real).pullOnce();
    await inAckP; // цикл A: COMMIT выполнен, ack ещё не отправлен
    const m2 = real.mutateCatalog({ renameProducts: 4 }); // новые изменения в 1С после выборки A

    const bCalls: string[] = [];
    const gwB = wrap(real, {
      getChanges: (q, o) => {
        bCalls.push('getChanges');
        return real.getChanges(q, o);
      },
      getHealth: (o) => {
        bCalls.push('getHealth');
        return real.getHealth(o);
      },
    });
    // Плановый цикл.
    const b = await changes(f.pool, gwB, real, { pageSize: 1 }).pullOnce();
    expect(b.status).toBe('skipped_locked');
    // Ручной incremental сущности плана обмена (очередь sync.manual → ChangesSyncHandler → pullOnce).
    const registry = new SyncRunRegistry(f.pool, 900, DEFAULT_STATE_DEFAULTS);
    const tracker = new RegistryRunTracker(registry, f.pool);
    const handler = new ChangesSyncHandler(
      f.pool,
      tracker,
      (t) =>
        new OnecChangesService(f.pool, gwB, new CatalogApplier(), t, silent, {
          pageSize: 1,
          slices: new SyntheticCatalogSource(real),
        }),
    );
    const runId = await registry.acquire({ entity: 'products', mode: 'manual', trigger: 'manual' });
    const manual = await handler.run({
      runId,
      entity: 'products',
      mode: 'manual',
      trigger: 'manual',
      jobId: 'job-manual',
      attempt: 1,
      log: silent,
      touch: () => Promise.resolve(),
    });
    expect(manual).toMatchObject({ implemented: false, counts: { skipped: 'onec_changes_locked' } });
    await registry.finish({ runId, entity: 'products', status: 'success', implemented: false });
    expect(bCalls).toEqual([]); // GET /changes вызывает только один процесс

    releaseAck();
    const a = await aP;
    expect(a.status).toBe('applied');
    expect(a.messageNumber).toBe(1);

    // Изменения, зарегистрированные во время ack A, не сняты им: следующий цикл применяет их все.
    const refs = m2.changedKeys.map((k) => k.split(':')[1]);
    expect(await staleNames(f, refs)).toBe(4);
    const c = await changes(f.pool, real, real, { pageSize: 1 }).pullOnce();
    expect(c.status).toBe('applied');
    expect(c.messageNumber).toBe(2);
    expect(await staleNames(f, refs)).toBe(0);
    expect(real.exchange!.backlog).toBe(0);
    // Lock снят: следующий цикл не блокируется.
    expect((await changes(f.pool, real, real).pullOnce()).status).toBe('empty');
  });
});

describe('onec.changes: сбой цикла оставляет след вне транзакции (RM-E-002 п. 2; SYNC-029 (б), SYNC-038; ревью E-onec-sync-2)', () => {
  // 12 T-SYNC-006 (каталожная часть: недоступность 1С → failed, consecutive_errors), T-SYNC-026
  it('1С недоступна на первом /changes: прогоны failed + sync_errors ONEC_UNAVAILABLE по сущностям плана; consecutive_errors +1 за цикл; алерт о недоступности и о восстановлении', async () => {
    const f = await fresh();
    const admin = await addStaff(f.pool, 'admin', '+996700000101');
    const owner = await addStaff(f.pool, 'owner', '+996700000102');
    const senior = await addStaff(f.pool, 'senior_seller', '+996700000103');
    await addStaff(f.pool, 'seller', '+996700000104');
    f.gateway.mutateCatalog({ renameProducts: 2 });
    const svc = changes(f.pool, f.gateway, f.gateway);
    for (let i = 0; i < 3; i += 1) {
      f.gateway.exchange!.injectError(1, new OnecError('getChanges', 0, 'TRANSPORT', 'таймаут соединения'));
      await expect(svc.pullOnce()).rejects.toMatchObject({ code: 'TRANSPORT' });
    }
    const runs = await f.pool.query<{ entity: string; n: number }>(
      `SELECT entity::text AS entity, count(*)::int AS n FROM sync_runs
        WHERE mode = 'incremental' AND status = 'failed' GROUP BY entity ORDER BY entity`,
    );
    expect(runs.rows.map((r) => r.entity)).toEqual([...ONEC_PLAN_ENTITIES].sort());
    expect(runs.rows.every((r) => r.n === 3)).toBe(true);
    const errs = await f.pool.query<{ code: string; n: number; linked: number }>(
      `SELECT e.error_code AS code, count(*)::int AS n, count(e.sync_run_id)::int AS linked
         FROM sync_errors e JOIN sync_runs r ON r.id = e.sync_run_id
        WHERE r.mode = 'incremental' GROUP BY e.error_code`,
    );
    expect(errs.rows).toEqual([
      { code: 'ONEC_UNAVAILABLE', n: 3 * ONEC_PLAN_ENTITIES.length, linked: 3 * ONEC_PLAN_ENTITIES.length },
    ]);
    const st = await f.pool.query<{ entity: string; ce: number }>(
      `SELECT entity::text AS entity, consecutive_errors AS ce FROM sync_state WHERE entity::text = ANY($1::text[])`,
      [[...ONEC_PLAN_ENTITIES]],
    );
    expect(st.rows).toHaveLength(ONEC_PLAN_ENTITIES.length);
    expect(st.rows.every((r) => r.ce === 3)).toBe(true);
    expect(f.gateway.calls.some((c) => c.operation === 'ackChanges')).toBe(false);

    // SYNC-038 п. 1: недоступность дольше SYNC_ALERT_UNREACHABLE_MIN (10 мин) → уведомление admin/owner/senior_seller.
    const alerts = new SyncAlertService(f.pool, silent, { unreachableMinutes: 10 });
    const unreachable = () =>
      f.pool.query<{ user_id: string }>(
        `SELECT user_id FROM notifications WHERE kind = 'sync_error' AND dedupe_key LIKE 'sync_error:unreachable:%'`,
      );
    await f.pool.query(`UPDATE sync_node_state SET unreachable_since = now() - interval '9 minutes'`);
    await alerts.evaluateNode();
    expect((await unreachable()).rows).toHaveLength(0);
    await f.pool.query(`UPDATE sync_node_state SET unreachable_since = now() - interval '11 minutes'`);
    await alerts.sweep();
    expect(new Set((await unreachable()).rows.map((r) => r.user_id))).toEqual(new Set([admin, owner, senior]));
    // Повтора в течение 60 мин нет (T+15).
    await f.pool.query(`UPDATE sync_node_state SET unreachable_since = now() - interval '15 minutes'`);
    await alerts.sweep();
    expect((await unreachable()).rows).toHaveLength(3);

    // Восстановление: цикл применяет сообщение, узел снова доступен → одно уведомление о восстановлении.
    const ok = await svc.pullOnce();
    expect(ok.status).toBe('applied');
    expect(
      (await f.pool.query<{ r: boolean }>(`SELECT onec_reachable AS r FROM sync_node_state WHERE node = 'pos'`)).rows[0]
        .r,
    ).toBe(true);
    await alerts.sweep();
    await alerts.sweep();
    const recovered = await f.pool.query(
      `SELECT user_id FROM notifications WHERE kind = 'sync_error' AND dedupe_key LIKE 'sync_error:onec_recovered:%'`,
    );
    expect(recovered.rows).toHaveLength(3);
  });

  it('сбой на второй странице: прогоны затронутых сущностей failed и строки sync_errors записаны, хотя транзакция сообщения откатана', async () => {
    const f = await fresh();
    f.gateway.mutateCatalog({ renameProducts: 6 });
    f.gateway.exchange!.injectError(2, new OnecError('getChanges', 503, 'POS_E_MAINTENANCE', 'обновление'));
    await expect(changes(f.pool, f.gateway, f.gateway, { pageSize: 2 }).pullOnce()).rejects.toMatchObject({
      code: 'POS_E_MAINTENANCE',
    });
    const r = await f.pool.query<{ entity: string; status: string; code: string | null }>(
      `SELECT r.entity::text AS entity, r.status::text AS status, e.error_code AS code
         FROM sync_runs r LEFT JOIN sync_errors e ON e.sync_run_id = r.id
        WHERE r.mode = 'incremental'`,
    );
    expect(r.rows.length).toBeGreaterThan(0);
    expect(r.rows.every((x) => x.status === 'failed' && x.code === 'ONEC_UNAVAILABLE')).toBe(true);
    expect(r.rows.some((x) => x.entity === 'products')).toBe(true);
  });
});

describe('onec.changes: hasMore=true без cursor — ответ не по контракту (ревью E-onec-sync-6)', () => {
  it('ROLLBACK, ack не отправлен, данные не применены, регистрации остаются; ошибка INVALID_RESPONSE', async () => {
    const f = await fresh();
    const m = f.gateway.mutateCatalog({ renameProducts: 3 });
    const gw = wrap(f.gateway, {
      getChanges: async (q, o) => {
        const r = await f.gateway.getChanges(q, o);
        const body: OnecChangesPage = { ...r.body, hasMore: true, cursor: null };
        return { ...r, body };
      },
    });
    await expect(changes(f.pool, gw, f.gateway).pullOnce()).rejects.toMatchObject({ code: 'INVALID_RESPONSE' });
    expect(f.gateway.calls.some((c) => c.operation === 'ackChanges')).toBe(false);
    expect(f.gateway.exchange!.backlog).toBe(3);
    expect(
      await staleNames(
        f,
        m.changedKeys.map((k) => k.split(':')[1]),
      ),
    ).toBe(3);
    const node = await f.pool.query<{ n: string; err: string }>(
      `SELECT last_message_number::text AS n, last_error_code AS err FROM sync_node_state WHERE node = 'pos'`,
    );
    expect(node.rows[0]).toEqual({ n: '0', err: 'ONEC_REJECTED' });
  });
});

describe('фаза 0: пометка удалённых в инкременте (SYNC-006, SYNC-012; ревью E-onec-sync-3)', () => {
  function glitchSource(f: CatalogFixture, victim: string, withCount: boolean): CatalogFullSource {
    const base = new SyntheticCatalogSource(f.gateway);
    let drop = true;
    return {
      name: 'test',
      read: (k: CatalogReadKind) => base.read(k),
      versions: (k: CatalogReadKind) => {
        const it = base.versions(k);
        const skip = drop && k === 'products';
        if (k === 'products') drop = false;
        return (async function* () {
          for await (const page of it) yield skip ? page.filter((v) => v.key !== victim) : page;
        })();
      },
      fetchByKeys: (k: CatalogReadKind, keys: readonly string[]) => base.fetchByKeys(k, keys),
      ...(withCount ? { count: (k: CatalogReadKind) => base.count(k) } : {}),
      priceSlice: (r: readonly string[]) => base.priceSlice(r),
      stockSlice: (w?: readonly string[]) => base.stockSlice(w),
    };
  }

  const mark = async (f: CatalogFixture, ref: string) =>
    (await f.pool.query<{ dm: boolean }>(`SELECT deletion_mark AS dm FROM products WHERE onec_ref = $1`, [ref])).rows[0]
      .dm;

  it('листинг версий пропустил живой ключ, $count не совпал → пометки нет, прогон partial + COUNT_MISMATCH', async () => {
    const f = await fresh();
    const victim = f.catalog.productItems().find((p) => !p.deletionMark && p.sku !== 'KX-1245')!.ref;
    const svc = new CatalogFullLoadService(f.pool, new CatalogApplier(), createRunTracker(f.pool), silent);
    const r = await svc.run({ entity: 'products', mode: 'incremental', source: glitchSource(f, victim, true) });
    expect(await mark(f, victim)).toBe(false);
    expect(r.status).toBe('partial');
    const e = await f.pool.query<{ code: string }>(
      `SELECT error_code AS code FROM sync_errors WHERE sync_run_id = $1`,
      [r.runId],
    );
    expect(e.rows.map((x) => x.code)).toEqual(['COUNT_MISMATCH']);
  });

  it('источник без $count: ключ помечен после пропуска, но при следующем инкременте (ключ снова в листинге) дочитан и восстановлен', async () => {
    const f = await fresh();
    const victim = f.catalog.productItems().find((p) => !p.deletionMark && p.sku !== 'KX-1245')!.ref;
    const svc = new CatalogFullLoadService(f.pool, new CatalogApplier(), createRunTracker(f.pool), silent);
    const src = glitchSource(f, victim, false);
    await svc.run({ entity: 'products', mode: 'incremental', source: src });
    expect(await mark(f, victim)).toBe(true);
    await svc.run({ entity: 'products', mode: 'incremental', source: src });
    expect(await mark(f, victim)).toBe(false);
    expect(
      (
        await f.pool.query<{ dm: boolean }>(
          `SELECT v.deletion_mark AS dm FROM product_variants v JOIN products p ON p.id = v.product_id
            WHERE p.onec_ref = $1 AND v.is_default`,
          [victim],
        )
      ).rows[0]?.dm,
    ).toBe(false);
  });
});
