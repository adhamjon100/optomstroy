import 'reflect-metadata';
import pg from 'pg';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import {
  NotConfiguredOutboxDelivery,
  type OutboxDeliveryPort,
  type OutboxRow,
} from '../../src/jobs/outbox/outbox-delivery.port.js';
import { SyncRunError, type SyncEntityHandler } from '../../src/jobs/sync/sync-handler.js';
import { OutboxDispatcher } from '../../src/jobs/outbox/outbox-dispatcher.js';
import { WorkerRuntime } from '../../src/jobs/worker-runtime.js';
import { schedulerConfigFromEnv } from '../../src/sync/scheduler/scheduler.config.js';
import { SyncRunRegistry } from '../../src/sync/scheduler/sync-run.registry.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { testConfig } from '../support/test-app.js';
import { capturedLogger, deferred, insertOutbox, waitFor } from './helpers.js';

/**
 * RM-C-007 (13 §3.3) на PostgreSQL 17 (embedded, без Docker): pg-boss без Redis (D-44).
 * Критерии: 1) две попытки запуска очереди-синглтона → вторая получает SYNC_ALREADY_RUNNING;
 * 2) задача с принудительной ошибкой уходит в dead-letter после N ретраев (интервалы уменьшены конфигом).
 */
const NEVER = '0 0 1 1 *'; // cron, не срабатывающий во время теста (1 января 00:00)
const MS_BACKOFF = [100, 200, 300];

/** Канал 1С для теста: поведение задаётся `payload.mode` строки outbox. */
class ScriptedDelivery implements OutboxDeliveryPort {
  readonly configured = true;
  readonly calls: string[] = [];
  deliver(row: OutboxRow) {
    this.calls.push(row.id);
    const mode = (row.payload as { mode?: string }).mode;
    if (mode === 'ok') {
      return Promise.resolve({
        kind: 'sent' as const,
        onecRef: '0b8f4a3e-6c1d-4f6a-9d3e-1a2b3c4d5e6f',
        onecNumber: 'ТД-000123',
        onecStatus: 'НаСогласовании',
        response: { ok: true },
      });
    }
    if (mode === 'reject')
      return Promise.resolve({ kind: 'rejected' as const, message: 'POS_E_STOCK: недостаточно остатка' });
    if (mode === 'fatal') return Promise.resolve({ kind: 'fatal' as const, message: 'HTTP 401 от 1С' });
    if (mode === 'throw') return Promise.reject(new Error('ECONNRESET (принудительная ошибка теста)'));
    return Promise.resolve({ kind: 'transient' as const, message: 'HTTP 503 от 1С (принудительная ошибка теста)' });
  }
}

describe('RM-C-007: worker pg-boss на PostgreSQL 17 — singleton, dead-letter, расписания, outbox', () => {
  const db = new EmbeddedPg();
  const logs = capturedLogger();
  let pool: pg.Pool;
  let settings: SettingsReader;
  let runtime: WorkerRuntime;
  const stockGate = deferred();
  const stockStarted = deferred();
  const delivery = new ScriptedDelivery();
  let pricesAttempts = 0;

  const handlers: Partial<Record<string, SyncEntityHandler>> = {
    // Долгий прогон остатков: держит singleton, пока тест не отпустит.
    stock: {
      run: async (ctx) => {
        ctx.log.info('test.stock.started');
        stockStarted.resolve();
        await stockGate.promise;
        await ctx.touch({ rows: 42 });
        return { implemented: true, counts: { rows: 42 } };
      },
    },
    // Принудительная ошибка на каждой попытке → после retryLimit job в dead-letter.
    prices: {
      run: () => {
        pricesAttempts++;
        return Promise.reject(new SyncRunError('ONEC_UNAVAILABLE', `принудительная ошибка теста #${pricesAttempts}`));
      },
    },
  };

  beforeAll(async () => {
    await db.start();
    await db.createDatabase('pos_worker');
    await db.migrate('pos_worker', ['0001_init.sql', '0002_rbac_seed.sql']);
    pool = new pg.Pool({ connectionString: db.url('pos_worker'), max: 8 });
    settings = new SettingsReader(pool);
    const env = testConfig({ DATABASE_URL: db.url('pos_worker'), WORKERS_ENABLED: 'true', OUTBOX_MAX_ATTEMPTS: '4' });
    runtime = new WorkerRuntime({
      enabled: env.WORKERS_ENABLED,
      connectionString: env.DATABASE_URL,
      pool,
      settings,
      log: logs.log,
      handlers: handlers,
      outboxDelivery: delivery,
      workerId: 'test-worker',
      scheduler: schedulerConfigFromEnv(env, {
        pollingIntervalSeconds: 0.5,
        scheduleRefreshMs: 3_600_000,
        cron: {
          stock: NEVER,
          prices: NEVER,
          orderStatus: NEVER,
          master: NEVER,
          images: NEVER,
          reconcile: NEVER,
          countCheck: NEVER,
        },
        sync: { retryLimit: 2, retryDelay: 0, retryBackoff: false },
        outbox: { backoffMs: MS_BACKOFF, backoffTailMs: 300, tickMs: 200, leaseMs: 2_000 },
      }),
    });
    expect(await runtime.start()).toBe(true);
  });

  afterAll(async () => {
    stockGate.resolve();
    await runtime?.stop();
    await pool?.end();
    await db.stop();
    // Вывод для отчёта: ключевые записи журнала worker'а.
    const keep = /^(worker\.|scheduler\.scheduled|sync\.job|sync\.run\.failed|outbox\.(retry|dead))/;
    const lines = logs.capture.lines.filter((l) => keep.test(String((JSON.parse(l) as { msg?: string }).msg)));
    console.error(`--- журнал worker (выдержка, ${lines.length} строк) ---\n${lines.join('\n')}`);
  });

  it('очереди созданы в pg-boss (схема pgboss в той же БД, без Redis): stately + dead-letter, retryLimit из конфига', async () => {
    const q = await runtime.boss.getQueue('sync.stock');
    expect(q).toMatchObject({ policy: 'stately', deadLetter: 'sync.dead_letter', retryLimit: 2 });
    expect(await runtime.boss.getQueue('sync.dead_letter')).not.toBeNull();
    expect(await runtime.boss.getQueue('outbox.dispatch')).toMatchObject({ policy: 'exclusive', retryLimit: 0 });
    const schema = await pool.query(`SELECT 1 FROM information_schema.schemata WHERE schema_name = 'pgboss'`);
    expect(schema.rowCount).toBe(1);
  });

  it('расписания: env SYNC_*_CRON по сущностям (ключ = сущность), sync_state заполнен; WORKERS_ENABLED=false — не стартует', async () => {
    const schedules = await runtime.boss.getSchedules();
    const master = schedules
      .filter((s) => s.name === 'sync.master')
      .map((s) => s.key)
      .sort();
    expect(master).toEqual(['attributes', 'barcodes', 'categories', 'products', 'units', 'variants', 'warehouses']);
    const stock = schedules.find((s) => s.name === 'sync.stock' && s.key === 'stock');
    expect(stock).toMatchObject({ cron: NEVER, timezone: 'Asia/Bishkek' });
    expect(stock?.options).toMatchObject({ singletonKey: 'stock' });
    expect(schedules.some((s) => s.name === 'onec.changes')).toBe(false); // ONEC_MODE=fixtures → по сущностям
    const st = await pool.query<{ n: number }>(`SELECT count(*)::int AS n FROM sync_state`);
    expect(st.rows[0]?.n).toBe(17);

    const disabled = new WorkerRuntime({
      enabled: false,
      connectionString: db.url('pos_worker'),
      pool,
      settings,
      log: logs.log,
      scheduler: schedulerConfigFromEnv(testConfig()),
    });
    expect(await disabled.start()).toBe(false);
    expect(() => disabled.boss).toThrow();
    expect(logs.entries('worker.disabled')).toHaveLength(1);
  });

  // 12 T-SYNC-020 (переопределение без перезапуска)
  it('app_settings.sync_interval.stock переопределяет env без перезапуска (D-29, AC-SYNC-021)', async () => {
    await pool.query(
      `INSERT INTO app_settings (key, value, value_type, description_ru) VALUES ('sync_interval.stock', '5', 'integer', 'тест')`,
    );
    await pool.query(
      `INSERT INTO app_settings (key, value, value_type, description_ru) VALUES ('sync_interval.prices', '1', 'integer', 'тест: ниже минимума')`,
    );
    settings.invalidate();
    await runtime.scheduler.apply();
    const stock = await runtime.boss.getSchedule('sync.stock', 'stock');
    expect(stock?.cron).toBe('FREQ=MINUTELY;INTERVAL=5');
    const prices = await runtime.boss.getSchedule('sync.prices', 'prices');
    expect(prices?.cron).toBe(NEVER); // 1 мин < минимума 2 мин → действует env
    expect(logs.entries('scheduler.setting_invalid').some((e) => e.key === 'sync_interval.prices')).toBe(true);
    const st = await pool.query<{ schedule_cron: string; max_age_warning_sec: number }>(
      `SELECT schedule_cron, max_age_warning_sec FROM sync_state WHERE entity = 'stock'`,
    );
    expect(st.rows[0]).toEqual({ schedule_cron: 'FREQ=MINUTELY;INTERVAL=5', max_age_warning_sec: 600 });
    // Возврат к env: строку убрали → следующий пересчёт снова ставит SYNC_STOCK_CRON.
    await pool.query(`DELETE FROM app_settings WHERE key IN ('sync_interval.stock', 'sync_interval.prices')`);
    settings.invalidate();
    await runtime.scheduler.apply();
    expect((await runtime.boss.getSchedule('sync.stock', 'stock'))?.cron).toBe(NEVER);
  });

  // 12 T-SYNC-021 (SYNC_ALREADY_RUNNING)
  it('критерий 1: две попытки запуска одной сущности → вторая получает SYNC_ALREADY_RUNNING (409)', async () => {
    const first = await runtime.requester.request({ entity: 'stock', mode: 'incremental', userId: undefined });
    await stockStarted.promise; // прогон #1 в обработчике (running)

    const second = runtime.requester.request({ entity: 'stock', mode: 'incremental' });
    await expect(second).rejects.toMatchObject({
      code: 'SYNC_ALREADY_RUNNING',
      entity: 'stock',
      activeRunId: first.runId,
    });
    await expect(second).rejects.toSatisfy((e: { getStatus(): number }) => e.getStatus() === 409);

    // Плановая job той же сущности при идущем прогоне не стартует: job завершается с SYNC_ALREADY_RUNNING.
    const jobId = await runtime.boss.send(
      'sync.stock',
      { entity: 'stock', mode: 'incremental', trigger: 'schedule' },
      { singletonKey: 'stock' },
    );
    const skipped = await waitFor(
      async () => {
        const [j] = await runtime.boss.findJobs<object>('sync.stock', { id: jobId! });
        return j?.state === 'completed' ? j : undefined;
      },
      { what: 'плановая job sync.stock завершена' },
    );
    expect(skipped.output).toMatchObject({ status: 'skipped', code: 'SYNC_ALREADY_RUNNING', activeRunId: first.runId });

    // Параллельно (гонка двух процессов) по другой сущности: ровно один запуск принят.
    const registry = new SyncRunRegistry(pool, 3600, () => ({ scheduleCron: NEVER, maxAgeWarningSec: 60 }));
    const race = await Promise.allSettled([
      registry.enqueue({ entity: 'customers', mode: 'incremental', trigger: 'manual' }),
      registry.enqueue({ entity: 'customers', mode: 'incremental', trigger: 'manual' }),
    ]);
    expect(race.filter((r) => r.status === 'fulfilled')).toHaveLength(1);
    expect(race.find((r) => r.status === 'rejected')).toMatchObject({ reason: { code: 'SYNC_ALREADY_RUNNING' } });
    const won = race.find((r) => r.status === 'fulfilled') as PromiseFulfilledResult<string>;
    await registry.abandon(won.value, 'тест');

    // Прогон #1 завершился → singleton освобождён, следующий запуск принимается.
    stockGate.resolve();
    const done = await waitFor(
      async () => {
        const r = await pool.query<{ status: string; counts: object }>(
          `SELECT status, counts FROM sync_runs WHERE id = $1`,
          [first.runId],
        );
        return r.rows[0]?.status === 'success' ? r.rows[0] : undefined;
      },
      { what: 'прогон stock success' },
    );
    expect(done.counts).toEqual({ rows: 42 });
    const third = await runtime.requester.request({ entity: 'stock', mode: 'incremental' });
    expect(third.runId).not.toBe(first.runId);
    const state = await waitFor(async () => {
      const r = await pool.query<{ last_success_run_id: string | null; consecutive_errors: number }>(
        `SELECT last_success_run_id, consecutive_errors FROM sync_state WHERE entity = 'stock'`,
      );
      return r.rows[0]?.last_success_run_id === third.runId ? r.rows[0] : undefined;
    });
    expect(state.consecutive_errors).toBe(0);
    expect(logs.entries('sync.job.skipped').length).toBeGreaterThanOrEqual(1);
  });

  it('критерий 2: job с принудительной ошибкой → после retryLimit=2 (3 попытки) уходит в dead-letter sync.dead_letter', async () => {
    const jobId = await runtime.boss.send(
      'sync.prices',
      { entity: 'prices', mode: 'incremental', trigger: 'schedule' },
      { singletonKey: 'prices' },
    );
    expect(jobId).toBeTruthy();
    const failed = await waitFor(
      async () => {
        const [j] = await runtime.boss.findJobs<object>('sync.prices', { id: jobId! });
        return j?.state === 'failed' ? j : undefined;
      },
      { what: 'job sync.prices в состоянии failed', timeoutMs: 60_000 },
    );
    expect(failed.retryCount).toBe(2);
    expect(pricesAttempts).toBe(3);

    const dead = await waitFor(
      async () => {
        const jobs = await runtime.boss.findJobs<{ entity?: string }>('sync.dead_letter');
        return jobs.find((j) => j.data.entity === 'prices');
      },
      { what: 'копия job в sync.dead_letter' },
    );
    expect(dead.data).toMatchObject({ entity: 'prices', mode: 'incremental', trigger: 'schedule' });
    expect(dead).toMatchObject({ sourceName: 'sync.prices', sourceId: jobId, sourceRetryCount: 2 });

    const runs = await pool.query<{ status: string; trigger: string }>(
      `SELECT status, "trigger" FROM sync_runs WHERE entity = 'prices' ORDER BY created_at`,
    );
    expect(runs.rows.map((r) => r.status)).toEqual(['failed', 'failed', 'failed']);
    expect(runs.rows.map((r) => r.trigger)).toEqual(['schedule', 'retry', 'retry']);
    const errs = await pool.query<{ error_code: string; n: number }>(
      `SELECT error_code, count(*)::int AS n FROM sync_errors WHERE entity = 'prices' GROUP BY error_code`,
    );
    expect(errs.rows).toEqual([{ error_code: 'ONEC_UNAVAILABLE', n: 3 }]);
    const st = await pool.query<{ consecutive_errors: number; last_success_at: Date | null }>(
      `SELECT consecutive_errors, last_success_at FROM sync_state WHERE entity = 'prices'`,
    );
    // 05 SYNC-029 (б), AC-SYNC-029: 3 попытки одного прогона — consecutive_errors +1 (а не +3).
    expect(st.rows[0]).toEqual({ consecutive_errors: 1, last_success_at: null });
    const deadLog = logs.entries('sync.job.dead_letter');
    expect(deadLog).toHaveLength(1);
    expect(deadLog[0]).toMatchObject({ level: 'error', entity: 'prices', attempt: 3, retryLimit: 2 });
  });

  // 12 T-ONEC-014 (outbox: временные → ретрай, затем dead)
  // 12: T-SYNC-034 (1) (временные ошибки → backoff → dead + sync_errors), T-SYNC-F01
  it('outbox: временная ошибка 1С → backoff по графику → dead при OUTBOX_MAX_ATTEMPTS=4 + sync_errors', async () => {
    const id = await insertOutbox(pool, { payload: { mode: 'transient' } });
    const row = await waitFor(
      async () => {
        const r = await pool.query<{
          status: string;
          attempts: number;
          last_error_code: string;
          dead_at: Date | null;
          lease_until: Date | null;
        }>(`SELECT status, attempts, last_error_code, dead_at, lease_until FROM onec_outbox WHERE id = $1`, [id]);
        return r.rows[0]?.status === 'dead' ? r.rows[0] : undefined;
      },
      { what: 'onec_outbox → dead', timeoutMs: 60_000 },
    );
    expect(row).toMatchObject({ status: 'dead', attempts: 4, last_error_code: 'ONEC_UNAVAILABLE', lease_until: null });
    expect(row.dead_at).toBeInstanceOf(Date);
    const retries = logs.entries('outbox.retry').filter((e) => e.outboxId === id);
    expect(retries.map((e) => e.nextInMs)).toEqual(MS_BACKOFF); // после попыток 1, 2, 3
    expect(retries.map((e) => e.attempts)).toEqual([1, 2, 3]);
    const err = await pool.query(`SELECT entity, error_code, severity FROM sync_errors WHERE outbox_id = $1`, [id]);
    expect(err.rows).toEqual([{ entity: 'order_status', error_code: 'ONEC_UNAVAILABLE', severity: 'error' }]);
    expect(logs.entries('outbox.dead').find((e) => e.outboxId === id)).toMatchObject({
      level: 'error',
      attempts: 4,
      reason: 'max_attempts',
    });
  });

  // 12 T-ONEC-014 (outbox: 401 → dead сразу)
  // 12: T-SYNC-034 (2)–(4) (возраст > OUTBOX_MAX_AGE_HOURS → dead; 401 → dead сразу)
  it('outbox: возраст > OUTBOX_MAX_AGE_HOURS → dead с первой временной ошибки; 401 → dead сразу; исключение = временная ошибка', async () => {
    const old = await insertOutbox(pool, { payload: { mode: 'transient' }, createdAgoHours: 25 });
    const fatal = await insertOutbox(pool, { payload: { mode: 'fatal' }, aggregateType: 'payment' });
    const thrown = await insertOutbox(pool, { payload: { mode: 'throw' }, aggregateType: 'customer' });
    const st = async (id: string) =>
      (
        await pool.query<{ status: string; attempts: number; last_error_code: string }>(
          `SELECT status, attempts, last_error_code FROM onec_outbox WHERE id = $1`,
          [id],
        )
      ).rows[0];
    await waitFor(async () => (await st(old))?.status === 'dead' && (await st(fatal))?.status === 'dead', {
      what: 'dead по возрасту и 401',
    });
    expect(await st(old)).toMatchObject({ attempts: 1, last_error_code: 'ONEC_UNAVAILABLE' });
    expect(await st(fatal)).toMatchObject({ attempts: 1, last_error_code: 'OTHER' });
    expect(logs.entries('outbox.dead').find((e) => e.outboxId === old)).toMatchObject({ reason: 'max_age' });
    const t = await waitFor(async () => {
      const r = await st(thrown);
      return r && r.attempts >= 1 && r.status !== 'sending' ? r : undefined;
    });
    expect(['pending', 'dead']).toContain(t.status);
    expect(t.last_error_code).toBe('ONEC_UNAVAILABLE');
  });

  it('outbox: ручной повтор dead по возрасту → окно OUTBOX_MAX_AGE_HOURS от момента повтора (10 ORD-031): временная ошибка → pending, не dead', async () => {
    const id = await insertOutbox(pool, { payload: { mode: 'transient' }, createdAgoHours: 30, status: 'dead' });
    // Ручной повтор, как POST /sync/outbox/{id}/retry: аудит outbox.retried + сброс попыток в одной транзакции.
    const c = await pool.connect();
    try {
      await c.query('BEGIN');
      await c.query(
        `INSERT INTO audit_logs (level, action, entity_type, entity_id, result, severity)
         VALUES ('app', 'outbox.retried', 'onec_outbox', $1, 'ok', 'info')`,
        [id],
      );
      await c.query(
        `UPDATE onec_outbox SET status = 'pending', attempts = 0, next_attempt_at = now(), dead_at = NULL,
                lease_until = NULL, locked_by = NULL WHERE id = $1`,
        [id],
      );
      await c.query('COMMIT');
    } finally {
      c.release();
    }
    await waitFor(
      () =>
        Promise.resolve(
          logs.entries('outbox.retry').some((e) => e.outboxId === id) ||
            logs.entries('outbox.dead').some((e) => e.outboxId === id),
        ),
      { what: 'первая попытка после ручного повтора' },
    );
    expect(logs.entries('outbox.dead').find((e) => e.outboxId === id && e.reason === 'max_age')).toBeUndefined();
    const first = logs.entries('outbox.retry').find((e) => e.outboxId === id);
    expect(first).toMatchObject({ attempts: 1 });
  });

  it('outbox: 1С вернула Ref_Key → sent + orders.onec-confirmed в той же транзакции; бизнес-отказ → failed + orders.onec-failed', async () => {
    const ok = await insertOutbox(pool, { payload: { mode: 'ok' } });
    const rej = await insertOutbox(pool, { payload: { mode: 'reject' } });
    const st = async (id: string) =>
      (
        await pool.query<{
          status: string;
          onec_ref: string | null;
          sent_at: Date | null;
          last_error_code: string | null;
        }>(`SELECT status, onec_ref, sent_at, last_error_code FROM onec_outbox WHERE id = $1`, [id])
      ).rows[0];
    await waitFor(async () => (await st(ok))?.status === 'sent' && (await st(rej))?.status === 'failed', {
      what: 'sent/failed',
    });
    expect(await st(ok)).toMatchObject({ onec_ref: '0b8f4a3e-6c1d-4f6a-9d3e-1a2b3c4d5e6f', last_error_code: null });
    expect(await st(rej)).toMatchObject({ last_error_code: 'ONEC_REJECTED' });
    const confirmed = await runtime.boss.findJobs<{ outboxId: string }>('orders.onec-confirmed', {
      data: { outboxId: ok },
    });
    expect(confirmed).toHaveLength(1);
    expect(confirmed[0]?.data).toMatchObject({ outboxId: ok, onecNumber: 'ТД-000123', attempt: 1 });
    const failedEvt = await runtime.boss.findJobs<{ outboxId: string }>('orders.onec-failed', {
      data: { outboxId: rej },
    });
    expect(failedEvt[0]?.data).toMatchObject({ outboxId: rej, errorCode: 'ONEC_REJECTED' });
    const rejErr = await pool.query(`SELECT error_code FROM sync_errors WHERE outbox_id = $1`, [rej]);
    expect(rejErr.rows).toEqual([{ error_code: 'ONEC_REJECTED' }]);
  });

  // 12: T-SYNC-037 (payload зафиксирован: payload_hash сверяется перед отправкой; изменение → ошибка); 07 DATA-228
  it('outbox: payload изменён после постановки (payload_hash не совпадает) → dead + sync_errors HASH_MISMATCH, в 1С не отправлено', async () => {
    const id = await insertOutbox(pool, { payload: { mode: 'ok' }, parked: true });
    // Снимок изменён в обход OutboxService (ручная правка БД) — хеш прежний.
    await pool.query(
      `UPDATE onec_outbox SET payload = '{"mode":"ok","total":"999.00"}'::jsonb, next_attempt_at = now() WHERE id = $1`,
      [id],
    );
    const st = async () =>
      (
        await pool.query<{ status: string; last_error_code: string | null; dead_at: Date | null }>(
          `SELECT status, last_error_code, dead_at FROM onec_outbox WHERE id = $1`,
          [id],
        )
      ).rows[0];
    await waitFor(async () => (await st())?.status === 'dead', { what: 'dead по HASH_MISMATCH' });
    expect(await st()).toMatchObject({ status: 'dead', last_error_code: 'HASH_MISMATCH' });
    expect(delivery.calls).not.toContain(id);
    const errs = await pool.query<{ error_code: string; payload: { reason: string } }>(
      `SELECT error_code, payload FROM sync_errors WHERE outbox_id = $1`,
      [id],
    );
    expect(errs.rows).toEqual([
      expect.objectContaining({
        error_code: 'HASH_MISMATCH',
        payload: expect.objectContaining({ reason: 'hash_mismatch' }),
      }),
    ]);
    // Неизменённый снимок (хеш совпадает) доставляется как обычно.
    const ok = await insertOutbox(pool, { payload: { mode: 'ok' } });
    await waitFor(
      async () =>
        (await pool.query<{ status: string }>(`SELECT status FROM onec_outbox WHERE id = $1`, [ok])).rows[0]?.status ===
        'sent',
      { what: 'sent при совпадающем хеше' },
    );
  });

  it('outbox.unlock: sending с истёкшей арендой → pending с backoff (attempts не увеличивается повторно)', async () => {
    const id = await insertOutbox(pool, { payload: { mode: 'ok' }, status: 'sending', attempts: 1, leaseAgoSec: 30 });
    expect(await runtime.dispatcher.unlockExpired()).toBeGreaterThanOrEqual(1);
    const r = await waitFor(
      async () => {
        const x = await pool.query<{ status: string; attempts: number }>(
          `SELECT status, attempts FROM onec_outbox WHERE id = $1`,
          [id],
        );
        return x.rows[0]?.status === 'sent' ? x.rows[0] : undefined;
      },
      { what: 'после unlock строка доставлена тикером' },
    );
    expect(r.attempts).toBe(2);
    expect(logs.entries('outbox.unlock')).not.toHaveLength(0);
  });

  it('заглушка канала 1С (этап C): диспетчер не захватывает строки — попытки не тратятся', async () => {
    // Строка скрыта от тикера runtime (next_attempt_at в будущем); заглушка в БД не обращается вовсе.
    const id = await insertOutbox(pool, { payload: { mode: 'transient' }, parked: true });
    const d = new OutboxDispatcher(
      pool,
      new NotConfiguredOutboxDelivery(),
      runtime.boss,
      schedulerConfigFromEnv(testConfig()).outbox,
      'stub',
      logs.log,
    );
    expect(await d.tick()).toEqual({ claimed: 0, sent: 0, retried: 0, failed: 0, dead: 0 });
    const r = await pool.query(`SELECT status, attempts FROM onec_outbox WHERE id = $1`, [id]);
    expect(r.rows[0]).toEqual({ status: 'pending', attempts: 0 });
    expect(logs.entries('outbox.dispatch.skipped')).toHaveLength(1);
  });
});
