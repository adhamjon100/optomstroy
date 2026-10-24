import 'reflect-metadata';
import pino from 'pino';
import { QUEUES } from '../../src/common/jobs/contracts/queues.js';
import { SyncRunError, type SyncEntityHandler } from '../../src/jobs/sync/sync-handler.js';
import { SyncJobProcessor } from '../../src/jobs/sync/sync-job.processor.js';
import { createSyncWorkerWiring } from '../../src/jobs/sync/sync-worker.wiring.js';
import { OutboxDispatcher } from '../../src/jobs/outbox/outbox-dispatcher.js';
import type { OutboxDeliveryPort } from '../../src/jobs/outbox/outbox-delivery.port.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { SyntheticCatalogSource } from '../../src/sync/apply/catalog-source.js';
import { ScheduleResolver } from '../../src/sync/scheduler/schedule-resolver.js';
import { schedulerConfigFromEnv } from '../../src/sync/scheduler/scheduler.config.js';
import { IMAGES_GC_CRON, SyncScheduler } from '../../src/sync/scheduler/sync-scheduler.js';
import { EXTENSION_POLLED_ENTITIES, IMAGES_GC_QUEUE } from '../../src/sync/scheduler/sync-queues.js';
import { SYNC_ENTITY_VALUES } from '../../src/common/enums.js';
import { testConfig } from '../support/test-app.js';
import { waitFor } from '../worker/helpers.js';
import { type Actor, SyncTestApp } from './support/sync-app.js';

/**
 * RM-E-002 (+ RM-E-014, часть sync) на embedded PostgreSQL 17 + pg-boss (D-44). 1С — FakeOnecGateway с синтетическим
 * каталогом: всё «на фикстурах, не реальная интеграция».
 */
const silent = pino({ level: 'silent' });

/** Управляемый обработчик `discounts` (этап G — своей загрузки ещё нет): ошибка адаптера по флагу. */
const discounts = { fail: false, calls: 0 };
const discountsHandler: SyncEntityHandler = {
  run: () => {
    discounts.calls++;
    if (discounts.fail) {
      return Promise.reject(new SyncRunError('ONEC_UNAVAILABLE', `тестовая ошибка адаптера 1С #${discounts.calls}`));
    }
    return Promise.resolve({ implemented: true, counts: { fetched: 0 } });
  },
};

describe('RM-E-002: планировщик и управление синхронизацией', () => {
  const t = new SyncTestApp();
  const actors = {} as Record<'seller' | 'cashier' | 'senior' | 'admin' | 'owner' | 'customer', Actor>;

  beforeAll(async () => {
    await t.start({ handlers: { discounts: discountsHandler } });
    actors.seller = await t.actor('seller');
    actors.cashier = await t.actor('cashier');
    actors.senior = await t.actor('senior_seller');
    actors.admin = await t.actor('admin');
    actors.owner = await t.actor('owner');
    actors.customer = await t.actor('customer');
  });

  afterAll(async () => {
    await t.stop();
    const keep =
      /^(sync\.alert|sync\.count_check\.report|sync\.job\.skipped|onec\.changes\.applied|sync\.changes\.manual)/;
    const lines = t.worker.capture.lines.filter((l) => keep.test(String((JSON.parse(l) as { msg?: string }).msg)));
    console.error(`--- журнал worker (выдержка, ${lines.length} строк) ---\n${lines.join('\n')}`);
  });

  describe('расписания D-29 и singleton', () => {
    // 12 T-SYNC-020 (интервалы по умолчанию)
    it('env по умолчанию: остатки 10 мин (5–10), цены 15 (10–15), статусы 5, мастер-данные/клиенты/долги/история 30, фото — сутки, сверка — неделя', async () => {
      const cfg = schedulerConfigFromEnv(testConfig());
      const period = (expr: string) => {
        const [a, b] = t.runtime.boss.previewSchedule(expr, { tz: 'Asia/Bishkek', count: 2 });
        return (b.getTime() - a.getTime()) / 1000;
      };
      expect(period(cfg.cron.stock)).toBeGreaterThanOrEqual(300);
      expect(period(cfg.cron.stock)).toBeLessThanOrEqual(600);
      expect(period(cfg.cron.prices)).toBeGreaterThanOrEqual(600);
      expect(period(cfg.cron.prices)).toBeLessThanOrEqual(900);
      expect(period(cfg.cron.orderStatus)).toBe(300);
      expect(period(cfg.cron.master)).toBe(1800);
      expect(period(cfg.cron.images)).toBe(86_400);
      expect(period(cfg.cron.reconcile)).toBe(7 * 86_400);
      expect(period(cfg.cron.countCheck)).toBe(86_400);

      const settings = new SettingsReader(t.pool);
      const plan = async (mode: 'odata_only' | 'extension') => {
        const c = { ...cfg, onecMode: mode };
        return new SyncScheduler(t.runtime.boss, t.pool, c, new ScheduleResolver(c, settings), silent).desired();
      };
      // Фаза 0: задание на каждую сущность (ключ = сущность, singletonKey = сущность) + сверки.
      const p0 = await plan('odata_only');
      const byKey = new Map(p0.map((d) => [`${d.queue}|${d.key}`, d]));
      for (const e of SYNC_ENTITY_VALUES) {
        const d = p0.find((x) => x.entity === e);
        expect(d, e).toBeDefined();
        expect(d!.singletonKey).toBe(e);
      }
      expect(byKey.get('sync.stock|stock')?.expression).toBe(cfg.cron.stock);
      expect(byKey.get('sync.order_status|order_status')?.expression).toBe(cfg.cron.orderStatus);
      expect(byKey.get('sync.receivables|receivables')?.expression).toBe(cfg.cron.master);
      expect(byKey.get('sync.sales_history|sales_history')?.expression).toBe(cfg.cron.master);
      expect(byKey.get('sync.images|images')?.expression).toBe(cfg.cron.images);
      expect(byKey.get(`${QUEUES.syncReconcile}|default`)?.expression).toBe(cfg.cron.reconcile);
      expect(byKey.get(`${QUEUES.syncCountCheck}|default`)?.expression).toBe(cfg.cron.countCheck);
      // EQ-IMG-10: ежесуточная очистка осиротевших файлов фото.
      expect(byKey.get(`${IMAGES_GC_QUEUE}|default`)?.expression).toBe(IMAGES_GC_CRON);
      expect(p0.some((d) => d.queue === QUEUES.onecChanges)).toBe(false);
      // Фаза 1: одно задание onec.changes на узел; по сущностям — только срезы/статусы/фото.
      const p1 = await plan('extension');
      expect(p1.filter((d) => d.queue === QUEUES.onecChanges)).toHaveLength(1);
      expect(
        p1
          .filter((d) => d.entity)
          .map((d) => d.entity)
          .sort(),
      ).toEqual([...EXTENSION_POLLED_ENTITIES].sort());
    });

    // 12 T-SYNC-021
    it('singleton: одновременный запуск той же сущности невозможен (гонка двух процессов, ручной запуск при идущем прогоне → 409)', async () => {
      const race = await Promise.allSettled([
        t.wiring.registry.enqueue({ entity: 'warehouses', mode: 'full', trigger: 'manual' }),
        t.wiring.registry.acquire({ entity: 'warehouses', mode: 'incremental', trigger: 'schedule' }),
      ]);
      expect(race.filter((r) => r.status === 'fulfilled')).toHaveLength(1);
      expect(race.find((r) => r.status === 'rejected')).toMatchObject({ reason: { code: 'SYNC_ALREADY_RUNNING' } });
      const active = (race.find((r) => r.status === 'fulfilled') as PromiseFulfilledResult<string>).value;

      const res = await t
        .req('post', '/sync/runs', actors.admin, {
          idem: true,
          stepUp: await t.stepUp(actors.admin),
        })
        .send({ entity: 'warehouses', mode: 'full' });
      expect(res.status).toBe(409);
      expect(res.body).toMatchObject({ code: 'SYNC_ALREADY_RUNNING', runId: active });

      // Плановая job при идущем прогоне не стартует: завершается с SYNC_ALREADY_RUNNING, второй строки нет.
      const jobId = await t.runtime.boss.send(
        'sync.master',
        { entity: 'warehouses', mode: 'incremental', trigger: 'schedule' },
        { singletonKey: 'warehouses' },
      );
      const job = await waitFor(async () => {
        const [j] = await t.runtime.boss.findJobs<object>('sync.master', { id: jobId! });
        return j?.state === 'completed' ? j : undefined;
      });
      expect(job.output).toMatchObject({ status: 'skipped', code: 'SYNC_ALREADY_RUNNING', activeRunId: active });
      const n = await t.q<{ n: number }>(
        `SELECT count(*)::int AS n FROM sync_runs WHERE entity = 'warehouses' AND status IN ('queued','running')`,
      );
      expect(n[0].n).toBe(1);
      await t.wiring.registry.abandon(active, 'тест');
    });
  });

  describe('POST /sync/runs — матрица ролей и step-up (R0 §17.2; 11 №42, №42a)', () => {
    // 12 T-SYNC-023, T-SYNC-012
    it('критерий 6: senior_seller + incremental stock → 202 без step-up; прогон выполняется worker, trigger=manual', async () => {
      const res = await t
        .req('post', '/sync/runs', actors.senior, { idem: true })
        .send({ entity: 'stock', mode: 'incremental' });
      expect(res.status).toBe(202);
      expect(res.body).toMatchObject({ entity: 'stock', mode: 'incremental', trigger: 'manual', status: 'queued' });
      expect(res.body.triggeredBy).toMatchObject({ id: actors.senior.userId });
      expect(res.headers.location).toBe(`/api/v1/sync/runs/${res.body.id}`);
      const done = await t.waitRun(res.body.id);
      expect(done.status).toBe('success');
      expect(Number(done.counts.fetched)).toBeGreaterThan(0);
      const audit = await t.q<{ actor_user_id: string; after: Record<string, unknown>; step_up_method: string | null }>(
        `SELECT actor_user_id, after, step_up_method FROM audit_logs WHERE action = 'sync.manual_started' AND entity_id = $1`,
        [res.body.id],
      );
      expect(audit).toEqual([
        {
          actor_user_id: actors.senior.userId,
          after: { entity: 'stock', mode: 'incremental', scope: null },
          step_up_method: null,
        },
      ]);
    });

    // 12 T-SYNC-023, T-SYNC-012
    it('критерий 4: senior_seller + full → 403 FORBIDDEN; incremental вне stock/prices/order_status → 403', async () => {
      for (const body of [
        { entity: 'stock', mode: 'full' },
        { entity: 'prices', mode: 'reconcile' },
        { entity: 'products', mode: 'incremental' },
        { entity: 'customers', mode: 'incremental' },
      ]) {
        const res = await t.req('post', '/sync/runs', actors.senior, { idem: true }).send(body);
        expect(res.status, JSON.stringify(body)).toBe(403);
        expect(res.body.code).toBe('FORBIDDEN');
      }
    });

    // 12 T-SYNC-023, T-SYNC-012 (без ключа → 400)
    it('seller, cashier, customer → 403; без Idempotency-Key → 400; mode=manual → 400', async () => {
      for (const a of [actors.seller, actors.cashier, actors.customer]) {
        const res = await t.req('post', '/sync/runs', a, { idem: true }).send({ entity: 'stock', mode: 'incremental' });
        expect(res.status).toBe(403);
        expect(res.body.code).toBe('FORBIDDEN');
      }
      const noKey = await t.req('post', '/sync/runs', actors.admin).send({ entity: 'stock', mode: 'incremental' });
      expect(noKey.status).toBe(400);
      expect(noKey.body.errors[0].rule).toBe('idempotency_key_required');
      const manual = await t
        .req('post', '/sync/runs', actors.admin, { idem: true })
        .send({ entity: 'stock', mode: 'manual' });
      expect(manual.status).toBe(400);
      expect(manual.body).toMatchObject({ code: 'VALIDATION_FAILED' });
    });

    // 12 T-SYNC-023, T-SYNC-012
    it('критерий 5: admin + full без step-up → 403 STEP_UP_REQUIRED (sync.run.full); owner + incremental customers без step-up → STEP_UP_REQUIRED', async () => {
      const a = await t
        .req('post', '/sync/runs', actors.admin, { idem: true })
        .send({ entity: 'products', mode: 'full' });
      expect(a.status).toBe(403);
      expect(a.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: 'sync.run.full' } });
      const o = await t
        .req('post', '/sync/runs', actors.owner, { idem: true })
        .send({ entity: 'customers', mode: 'incremental' });
      expect(o.status).toBe(403);
      expect(o.body.code).toBe('STEP_UP_REQUIRED');
      // step-up другой операции не подходит
      const wrong = await t
        .req('post', '/sync/runs', actors.admin, { idem: true, stepUp: await t.stepUp(actors.admin, 'users.manage') })
        .send({ entity: 'products', mode: 'full' });
      expect(wrong.body.code).toBe('STEP_UP_REQUIRED');
    });

    // 12 T-SYNC-012, T-SYNC-001 (ручной full со step-up)
    it('admin + full со step-up → 202, прогон products full (синтетика) success; admin + incremental stock — без step-up', async () => {
      const res = await t
        .req('post', '/sync/runs', actors.admin, { idem: true, stepUp: await t.stepUp(actors.admin) })
        .send({ entity: 'products', mode: 'full' });
      expect(res.status).toBe(202);
      const done = await t.waitRun(res.body.id);
      expect(done.status).toBe('success');
      const audit = await t.q<{ step_up_method: string }>(
        `SELECT step_up_method::text FROM audit_logs WHERE action = 'sync.manual_started' AND entity_id = $1`,
        [res.body.id],
      );
      expect(audit[0]?.step_up_method).toBe('pin');

      const inc = await t
        .req('post', '/sync/runs', actors.admin, { idem: true })
        .send({ entity: 'prices', mode: 'incremental' });
      expect(inc.status).toBe(202);
      expect((await t.waitRun(inc.body.id)).status).toBe('success');
      const own = await t
        .req('post', '/sync/runs', actors.owner, { idem: true })
        .send({ entity: 'order_status', mode: 'incremental' });
      expect(own.status).toBe(202);
      await t.waitRun(own.body.id);
    });

    it('повтор с тем же Idempotency-Key → тот же прогон (Idempotent-Replayed), второй прогон не создаётся', async () => {
      const key = '6f1c2b8e-3d4a-4b5c-9d6e-7f8a9b0c1d2e';
      const first = await t
        .req('post', '/sync/runs', actors.senior, { idem: key })
        .send({ entity: 'order_status', mode: 'incremental' });
      expect(first.status).toBe(202);
      const again = await t
        .req('post', '/sync/runs', actors.senior, { idem: key })
        .send({ entity: 'order_status', mode: 'incremental' });
      expect(again.status).toBe(202);
      expect(again.body.id).toBe(first.body.id);
      expect(again.headers['idempotent-replayed']).toBe('true');
      await t.waitRun(first.body.id);
    });

    // 12 T-SYNC-023 (вариант C-2)
    it('C-2 (ONEC_INBOUND_ENABLED=true) → 422 VALIDATION_FAILED rule inbound_mode для любой роли', async () => {
      t.config.ONEC_INBOUND_ENABLED = true;
      try {
        for (const a of [actors.senior, actors.admin]) {
          const res = await t
            .req('post', '/sync/runs', a, { idem: true })
            .send({ entity: 'stock', mode: 'incremental' });
          expect(res.status).toBe(422);
          expect(res.body).toMatchObject({ code: 'VALIDATION_FAILED', rule: 'inbound_mode' });
          expect(res.body.errors[0].rule).toBe('inbound_mode');
        }
      } finally {
        t.config.ONEC_INBOUND_ENABLED = false;
      }
    });

    it('RL-ADMIN: 10 ручных запусков сущности за 10 мин → 429 RATE_LIMITED с Retry-After', async () => {
      await t.q(
        `INSERT INTO sync_runs (entity, mode, "trigger", status, finished_at)
         SELECT 'barcodes', 'incremental', 'manual', 'success', now() FROM generate_series(1, 10)`,
      );
      const res = await t
        .req('post', '/sync/runs', actors.admin, { idem: true, stepUp: await t.stepUp(actors.admin) })
        .send({ entity: 'barcodes', mode: 'incremental' });
      expect(res.status).toBe(429);
      expect(res.body.code).toBe('RATE_LIMITED');
      expect(Number(res.headers['retry-after'])).toBeGreaterThan(0);
    });

    // 12 T-SYNC-024 (GET /sync/status, runs)
    it('RM-E-014 крит. 3: ручной и плановый прогоны различаются полем trigger; GET /sync/runs и /runs/{id} — sync.runs.read', async () => {
      const jobId = await t.runtime.boss.send(
        'sync.stock',
        { entity: 'stock', mode: 'incremental', trigger: 'schedule' },
        { singletonKey: 'stock' },
      );
      await waitFor(async () => {
        const [j] = await t.runtime.boss.findJobs<object>('sync.stock', { id: jobId! });
        return j?.state === 'completed' ? j : undefined;
      });
      const list = await t.req('get', '/sync/runs?entity=stock&limit=200', actors.admin);
      expect(list.status).toBe(200);
      const triggers = new Set((list.body.items as { trigger: string }[]).map((r) => r.trigger));
      expect(triggers).toEqual(new Set(['manual', 'schedule']));
      const sched = (list.body.items as { trigger: string; triggeredBy: unknown; id: string }[]).find(
        (r) => r.trigger === 'schedule',
      );
      expect(sched?.triggeredBy).toBeNull();
      const one = await t.req('get', `/sync/runs/${sched!.id}`, actors.owner);
      expect(one.status).toBe(200);
      expect(one.body).toMatchObject({ id: sched!.id, trigger: 'schedule', entity: 'stock' });

      // Пагинация курсором: limit=1 → nextCursor → следующая страница без пересечений.
      const p1 = await t.req('get', '/sync/runs?limit=1', actors.admin);
      const p2 = await t.req(
        'get',
        `/sync/runs?limit=1&cursor=${encodeURIComponent(p1.body.nextCursor)}`,
        actors.admin,
      );
      expect(p1.body.hasMore).toBe(true);
      expect(p2.body.items[0].id).not.toBe(p1.body.items[0].id);
      expect((await t.req('get', '/sync/runs?cursor=forged.0000', actors.admin)).body.errors[0].rule).toBe('cursor');
      expect((await t.req('get', '/sync/runs?limit=201', actors.admin)).status).toBe(400);
      for (const a of [actors.seller, actors.cashier]) {
        expect((await t.req('get', '/sync/runs', a)).status).toBe(403);
      }
      expect((await t.req('get', '/sync/runs/0190a1b2-0000-7000-8000-000000000001', actors.admin)).status).toBe(404);
    });
  });

  describe('POST /sync/outbox/{id}/retry (ядро §22.1, §22.10, §19.4; R0 §18.2 п. 11)', () => {
    // 12: T-SYNC-036 (ручной повтор dead: admin без step-up → 202, attempts=0, аудит outbox.retried)
    it('admin без X-Step-Up-Token → 202 (dead → pending, attempts=0, nextAttemptAt=now), аудит outbox.retried', async () => {
      const id = await t.outbox('dead', { attempts: 20 });
      const res = await t.req('post', `/sync/outbox/${id}/retry`, actors.admin, { idem: true });
      expect(res.status).toBe(202);
      expect(res.body).toMatchObject({
        id,
        status: 'pending',
        attempts: 0,
        aggregateType: 'order',
        operation: 'create',
      });
      expect(Math.abs(Date.parse(res.body.nextAttemptAt) - Date.now())).toBeLessThan(60_000);
      const [row] = await t.q<{ requested_by_user_id: string; dead_at: Date | null }>(
        `SELECT requested_by_user_id, dead_at FROM onec_outbox WHERE id = $1`,
        [id],
      );
      expect(row).toEqual({ requested_by_user_id: actors.admin.userId, dead_at: null });
      const audit = await t.q<{
        actor_user_id: string;
        before: Record<string, unknown>;
        after: Record<string, unknown>;
      }>(`SELECT actor_user_id, before, after FROM audit_logs WHERE action = 'outbox.retried' AND entity_id = $1`, [
        id,
      ]);
      expect(audit).toEqual([
        {
          actor_user_id: actors.admin.userId,
          before: { status: 'dead', attempts: 20, lastErrorCode: 'ONEC_UNAVAILABLE' },
          after: { status: 'pending', attempts: 0 },
        },
      ]);
    });

    // 12: T-SYNC-036 (senior_seller, failed → pending → sent)
    it('senior_seller — любой элемент (фильтра «свой магазин» нет): failed → pending; затем автомат pending → sending → sent', async () => {
      const id = await t.outbox('failed', { attempts: 1 });
      const res = await t.req('post', `/sync/outbox/${id}/retry`, actors.senior, { idem: true });
      expect(res.status).toBe(202);
      expect(res.body.status).toBe('pending');
      const delivery: OutboxDeliveryPort = {
        configured: true,
        deliver: (row) =>
          Promise.resolve(
            row.id === id
              ? { kind: 'sent' as const, onecRef: '0b8f4a3e-6c1d-4f6a-9d3e-1a2b3c4d5e6f', onecNumber: 'ТД-000777' }
              : { kind: 'transient' as const, message: 'не этот тест' },
          ),
      };
      const dispatcher = new OutboxDispatcher(
        t.pool,
        delivery,
        { send: (name, data, options) => t.runtime.boss.send(name, data, options) },
        schedulerConfigFromEnv(testConfig()).outbox,
        'sync-test-dispatcher',
        silent,
      );
      await dispatcher.tick();
      const [row] = await t.q<{ status: string; attempts: number }>(
        `SELECT status::text AS status, attempts FROM onec_outbox WHERE id = $1`,
        [id],
      );
      expect(row).toEqual({ status: 'sent', attempts: 1 });
    });

    // 12: T-SYNC-036 (sent/confirmed/cancelled/sending → 409 с reason)
    it('409 ORDER_STATE_INVALID по автомату: sent/confirmed — already_delivered, cancelled — withdrawn, sending — in_progress, pending — invalid_transition', async () => {
      const cases: [string, string][] = [
        ['sent', 'already_delivered'],
        ['confirmed', 'already_delivered'],
        ['cancelled', 'withdrawn'],
        ['sending', 'in_progress'],
        ['pending', 'invalid_transition'],
      ];
      for (const [status, reason] of cases) {
        const id = await t.outbox(status);
        const res = await t.req('post', `/sync/outbox/${id}/retry`, actors.admin, { idem: true });
        expect(res.status, status).toBe(409);
        expect(res.body).toMatchObject({ code: 'ORDER_STATE_INVALID', resource: 'outbox_item', reason });
        const [row] = await t.q<{ status: string }>(`SELECT status::text AS status FROM onec_outbox WHERE id = $1`, [
          id,
        ]);
        expect(row.status).toBe(status);
      }
    });

    // 12: T-SYNC-036 (seller/cashier/owner → 403)
    it('права: seller, cashier, owner → 403; нет элемента → 404; без Idempotency-Key → 400; GET /sync/outbox — failed,dead по умолчанию', async () => {
      const id = await t.outbox('dead');
      for (const a of [actors.seller, actors.cashier, actors.owner, actors.customer]) {
        const res = await t.req('post', `/sync/outbox/${id}/retry`, a, { idem: true });
        expect(res.status).toBe(403);
      }
      const nf = await t.req('post', '/sync/outbox/0190a1b2-0000-7000-8000-00000000abcd/retry', actors.admin, {
        idem: true,
      });
      expect(nf.status).toBe(404);
      expect((await t.req('post', `/sync/outbox/${id}/retry`, actors.admin)).status).toBe(400);
      const list = await t.req('get', '/sync/outbox', actors.senior);
      expect(list.status).toBe(200);
      const statuses = new Set((list.body.items as { status: string }[]).map((i) => i.status));
      expect([...statuses].every((s) => s === 'failed' || s === 'dead')).toBe(true);
      expect((list.body.items as { id: string }[]).some((i) => i.id === id)).toBe(true);
      expect((await t.req('get', '/sync/outbox?status=bogus', actors.admin)).status).toBe(400);
      expect((await t.req('get', '/sync/outbox', actors.seller)).status).toBe(403);
    });
  });

  describe('consecutiveErrors, алерты sync_error и GET /sync/status', () => {
    const runDiscounts = async () => {
      const jobId = await t.runtime.boss.send(
        'sync.discounts',
        { entity: 'discounts', mode: 'incremental', trigger: 'schedule' },
        { singletonKey: 'discounts' },
      );
      return waitFor(
        async () => {
          const [j] = await t.runtime.boss.findJobs<object>('sync.discounts', { id: jobId! });
          return j && (j.state === 'completed' || j.state === 'failed') ? j : undefined;
        },
        { timeoutMs: 60_000, what: 'job sync.discounts' },
      );
    };
    const notes = (entityLike: string) =>
      t.q<{ user_id: string; severity: string; payload: Record<string, unknown> }>(
        `SELECT user_id, severity, payload FROM notifications WHERE kind = 'sync_error' AND dedupe_key LIKE $1`,
        [entityLike],
      );

    // 12 T-SYNC-006 (ретраи, consecutive_errors растёт), T-SYNC-024, T-SYNC-026 (sync_error админу)
    it('критерий 2: ошибка адаптера → failed + sync_errors; consecutiveErrors +1 за прогон (3 попытки, SYNC-029) → после 3 прогонов уведомление admin/owner/senior_seller', async () => {
      discounts.fail = true;
      const job = await runDiscounts();
      expect(job.state).toBe('failed');
      const runs = await t.q<{ status: string }>(
        `SELECT status::text AS status FROM sync_runs WHERE entity = 'discounts' ORDER BY created_at`,
      );
      expect(runs.map((r) => r.status)).toEqual(['failed', 'failed', 'failed']);
      const errs = await t.q<{ error_code: string }>(`SELECT error_code FROM sync_errors WHERE entity = 'discounts'`);
      expect(errs.map((e) => e.error_code)).toEqual(['ONEC_UNAVAILABLE', 'ONEC_UNAVAILABLE', 'ONEC_UNAVAILABLE']);
      const consecutive = async () =>
        (
          await t.q<{ consecutive_errors: number }>(
            `SELECT consecutive_errors FROM sync_state WHERE entity = 'discounts'`,
          )
        )[0].consecutive_errors;
      // 05 SYNC-029 (б), AC-SYNC-029: попытки внутри прогона счётчик не множат — +1 за прогон, алерта ещё нет.
      expect(await consecutive()).toBe(1);
      expect(await notes('sync_error:consecutive:discounts:%')).toHaveLength(0);
      for (let i = 0; i < 2; i += 1) expect((await runDiscounts()).state).toBe('failed');
      expect(await consecutive()).toBe(3);
      const [st] = await t.q<{ consecutive_errors: number }>(
        `SELECT consecutive_errors FROM sync_state WHERE entity = 'discounts'`,
      );
      expect(st.consecutive_errors).toBe(3);

      const alerts = await notes('sync_error:consecutive:discounts:%');
      const recipients = new Set(alerts.map((n) => n.user_id));
      expect(recipients).toEqual(new Set([actors.admin.userId, actors.owner.userId, actors.senior.userId]));
      expect(alerts[0]).toMatchObject({ severity: 'error', payload: { entity: 'discounts', consecutiveErrors: 3 } });
      expect(t.worker.entries('sync.alert.consecutive_errors').some((e) => e.level === 'error')).toBe(true);

      // Краткий ответ (seller): consecutiveErrors есть, полей полного ответа нет; overall = failed (≥ 3).
      const short = await t.req('get', '/sync/status', actors.seller);
      expect(short.status).toBe(200);
      expect(short.headers['cache-control']).toBe('private, max-age=15');
      expect(short.body.overall).toBe('failed');
      const d = (short.body.entities as Record<string, unknown>[]).find((e) => e.entity === 'discounts')!;
      expect(d).toMatchObject({ consecutiveErrors: 3 });
      expect(Object.keys(d).sort()).toEqual(['consecutiveErrors', 'entity', 'isStale', 'lastSuccessAt'].sort());
      expect(Object.keys(short.body.outbox).sort()).toEqual(['dead', 'failed']);
      expect(short.body.pendingManualOrders).toBeUndefined();
      expect(short.body.entities).toHaveLength(17);
      // Полный ответ (admin): lastErrorAt, running, counts, pendingManualOrders, outbox.pending.
      const full = await t.req('get', '/sync/status', actors.admin);
      const fd = (full.body.entities as Record<string, unknown>[]).find((e) => e.entity === 'discounts')!;
      expect(fd).toMatchObject({ consecutiveErrors: 3, running: false, paused: false });
      expect(typeof fd.lastErrorAt).toBe('string');
      expect(full.body.pendingManualOrders).toMatchObject({ count: 0, slaMin: 60, overSla: false });
      expect(typeof full.body.outbox.pending).toBe('number');
      const stock = (full.body.entities as Record<string, unknown>[]).find((e) => e.entity === 'stock')!;
      expect(stock).toMatchObject({ consecutiveErrors: 0, isStale: false });
      expect(typeof stock.lastSuccessAt).toBe('string');
      expect((await t.req('get', '/sync/status', actors.customer)).status).toBe(403);
    });

    // 12 T-SYNC-008 (сброс после успеха), T-SYNC-026
    it('успешный прогон сбрасывает consecutiveErrors в 0 и шлёт «синхронизация восстановлена»', async () => {
      discounts.fail = false;
      const job = await runDiscounts();
      expect(job.state).toBe('completed');
      const [st] = await t.q<{ consecutive_errors: number }>(
        `SELECT consecutive_errors FROM sync_state WHERE entity = 'discounts'`,
      );
      expect(st.consecutive_errors).toBe(0);
      const rec = await notes('sync_error:recovered:discounts:%');
      expect(new Set(rec.map((n) => n.user_id))).toEqual(
        new Set([actors.admin.userId, actors.owner.userId, actors.senior.userId]),
      );
      const s = await t.req('get', '/sync/status', actors.cashier);
      const d = (s.body.entities as Record<string, unknown>[]).find((e) => e.entity === 'discounts')!;
      expect(d.consecutiveErrors).toBe(0);
    });
  });

  describe('сверка $count (05 SYNC-003, SYNC-068) и еженедельный reconcile', () => {
    // 12 T-SYNC-007 (сверка $count), T-SYNC-025 (GET /sync/runs/{id}/errors)
    // 12: T-SYNC-F04 (расхождение $count → partial + COUNT_MISMATCH + уведомление)
    it('без расхождений → success по каждой сущности; расхождение → partial + COUNT_MISMATCH + уведомление admin', async () => {
      const clean = await t.wiring.countCheck.run({ trigger: 'manual' });
      expect(clean.mismatches).toBe(0);
      expect(
        clean.entities
          .filter((e) => e.status === 'success')
          .map((e) => e.entity)
          .sort(),
      ).toEqual(['barcodes', 'categories', 'prices', 'products', 'units', 'variants', 'warehouses'].sort());
      const before = await t.q<{ consecutive_errors: number; last_success_at: Date | null }>(
        `SELECT consecutive_errors, last_success_at FROM sync_state WHERE entity = 'products'`,
      );

      // Расхождение: товар есть в 1С, но в POS помечен удалённым (имитация потери данных).
      const ref = t.fixture.refs.anchors.F4252;
      await t.q(
        `UPDATE products SET deletion_mark = true, source_hash = 'tampered:' || source_hash WHERE onec_ref = $1`,
        [ref],
      );
      const jobId = await t.runtime.boss.send(QUEUES.syncCountCheck, {});
      const job = await waitFor(async () => {
        const [j] = await t.runtime.boss.findJobs<object>(QUEUES.syncCountCheck, { id: jobId! });
        return j?.state === 'completed' ? j : undefined;
      });
      const report = job.output as {
        mismatches: number;
        entities: { entity: string; status: string; runId: string; tables: { table: string; diff: number }[] }[];
      };
      expect(report.mismatches).toBe(1);
      const products = report.entities.find((e) => e.entity === 'products')!;
      expect(products.status).toBe('partial');
      expect(products.tables.find((x) => x.table === 'products')).toMatchObject({ diff: 1 });

      const [run] = await t.q<{ status: string; mode: string; counts: Record<string, unknown> }>(
        `SELECT status::text AS status, mode::text AS mode, counts FROM sync_runs WHERE id = $1`,
        [products.runId],
      );
      expect(run).toMatchObject({ status: 'partial', mode: 'reconcile' });
      const errs = await t.req('get', `/sync/runs/${products.runId}/errors`, actors.admin);
      expect(errs.status).toBe(200);
      expect(errs.body.items).toHaveLength(1);
      expect(errs.body.items[0]).toMatchObject({
        entity: 'products',
        errorCode: 'COUNT_MISMATCH',
        payload: { table: 'products', diff: 1 },
        resolvedAt: null,
      });
      const notified = await t.q<{ user_id: string }>(`SELECT user_id FROM notifications WHERE dedupe_key = $1`, [
        `sync_error:count_mismatch:products:${products.runId}`,
      ]);
      expect(notified.map((n) => n.user_id)).toEqual([actors.admin.userId]);
      // Сверка без загрузки данных не трогает sync_state (свежесть и счётчик ошибок сущности).
      const after = await t.q<{ consecutive_errors: number; last_success_at: Date | null }>(
        `SELECT consecutive_errors, last_success_at FROM sync_state WHERE entity = 'products'`,
      );
      expect(after).toEqual(before);
    });

    // 12 T-SYNC-007, T-SYNC-012 (еженедельный reconcile)
    it('еженедельный reconcile products (sync.reconcile → mode=reconcile) восстанавливает строку; следующая сверка чистая', async () => {
      const jobId = await t.runtime.boss.send(
        'sync.master',
        { entity: 'products', mode: 'reconcile', trigger: 'schedule' },
        { singletonKey: 'products' },
      );
      const job = await waitFor(async () => {
        const [j] = await t.runtime.boss.findJobs<{ status: string; runId: string }>('sync.master', { id: jobId! });
        return j?.state === 'completed' ? j : undefined;
      });
      expect(job.output).toMatchObject({ status: 'completed', implemented: true });
      const runId = (job.output as { runId: string }).runId;
      const run = await t.waitRun(runId);
      expect(run.status).toBe('success');
      const again = await t.wiring.countCheck.run({ entities: ['products'] });
      expect(again.entities[0]).toMatchObject({ entity: 'products', status: 'success' });
    });
  });

  describe('onec.changes (режим расширения, ядро §22.8)', () => {
    // 12 T-SYNC-002 (фаза 1 по расписанию)
    it('плановая job onec.changes применяет сообщение плана обмена (trigger=schedule), пустой план → empty', async () => {
      const send = async () => {
        const id = await t.runtime.boss.send(QUEUES.onecChanges, { node: 'POS' });
        return waitFor(async () => {
          const [j] = await t.runtime.boss.findJobs<object>(QUEUES.onecChanges, { id: id! });
          return j && (j.state === 'completed' || j.state === 'failed') ? j : undefined;
        });
      };
      const empty = await send();
      expect(empty.output).toMatchObject({ status: 'empty' });
      t.fixture.gateway.mutateCatalog({ renameProducts: 2 });
      const applied = await send();
      expect(applied.state).toBe('completed');
      expect(applied.output).toMatchObject({ status: 'applied' });
      expect((applied.output as { entities: string[] }).entities).toContain('products');
      const runs = await t.q<{ trigger: string; mode: string; cursor_to: string }>(
        `SELECT "trigger"::text AS trigger, mode::text AS mode, cursor_to FROM sync_runs
          WHERE entity = 'products' AND onec_endpoint = 'GET /pos/v1/changes' ORDER BY created_at DESC LIMIT 1`,
      );
      expect(runs[0]).toMatchObject({ trigger: 'schedule', mode: 'incremental' });
    });

    it('ручной incremental сущности плана обмена → цикл /changes усыновляет прогон (без SYNC_ALREADY_RUNNING)', async () => {
      const ext = createSyncWorkerWiring({
        config: { ...t.config, ONEC_MODE: 'extension' },
        pool: t.pool,
        log: silent,
        gateway: t.fixture.gateway,
        source: new SyntheticCatalogSource(t.fixture.gateway),
      });
      const processor = new SyncJobProcessor(ext.registry, (e) => ext.handlers[e] ?? discountsHandler, t.pool, silent);
      t.fixture.gateway.mutateCatalog({ renameProducts: 3 });
      const runId = await ext.registry.enqueue({
        entity: 'products',
        mode: 'incremental',
        trigger: 'manual',
        userId: actors.admin.userId,
      });
      const out = await processor.process(
        { id: 'manual-job-1', retryCount: 0, retryLimit: 2 },
        {
          entity: 'products',
          mode: 'incremental',
          trigger: 'manual',
          runId,
        },
      );
      expect(out).toMatchObject({ status: 'completed', runId, implemented: true });
      const [run] = await t.q<{ status: string; counts: Record<string, unknown>; onec_endpoint: string }>(
        `SELECT status::text AS status, counts, onec_endpoint FROM sync_runs WHERE id = $1`,
        [runId],
      );
      expect(run.status).toBe('success');
      expect(run.onec_endpoint).toBe('GET /pos/v1/changes');
      expect(Number(run.counts.updated)).toBeGreaterThanOrEqual(3);
      const active = await t.q(`SELECT 1 FROM sync_runs WHERE status IN ('queued','running')`);
      expect(active).toHaveLength(0);
    });
  });
});
