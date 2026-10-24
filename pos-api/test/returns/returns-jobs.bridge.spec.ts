import { describe, expect, it, vi } from 'vitest';
import { QUEUES } from '../../src/common/jobs/contracts/queues.js';
import { ReturnsJobsBridge, ReturnsStatusSyncHandler } from '../../src/returns/onec/returns-jobs.bridge.js';

/**
 * Мост pg-boss модуля `returns` (`src/returns/onec/returns-jobs.bridge.ts`; 06 §7.4 п. (б), §7.5; ревью G-fresh-run-3,
 * G-trace-10) на подменённом pg-boss (**тестовые данные**, без БД): очереди результата outbox `returns.onec-*`
 * (гонка `createQueue` двух процессов), обработчики событий, задача сроков хранения `retention.daily` с расписанием
 * 03:30 Asia/Bishkek; без воркеров / без pg-boss — ничего; сбой старта pg-boss — только журнал. Прогон `return_docs`
 * (`ReturnsStatusSyncHandler`): `partial` при ошибках опроса.
 */
type JobFn = (jobs: { data: unknown }[]) => Promise<unknown>;

function fakeBoss(opts: { race?: boolean; failCreate?: boolean } = {}) {
  const handlers = new Map<string, JobFn>();
  const queues = new Map<string, unknown>();
  const schedules: { name: string; cron: string; options: unknown }[] = [];
  let race = opts.race ?? false;
  const boss = {
    getQueue: (n: string) => Promise.resolve(queues.has(n) ? { name: n } : null),
    createQueue: (n: string, o: unknown) => {
      if (opts.failCreate) return Promise.reject(new Error('pg-boss: нет прав на очередь'));
      queues.set(n, o);
      if (race) {
        race = false;
        return Promise.reject(new Error('queue already exists'));
      }
      return Promise.resolve();
    },
    work: (n: string, _o: unknown, fn: JobFn) => {
      handlers.set(n, fn);
      return Promise.resolve('worker-id');
    },
    schedule: (name: string, cron: string, _data: unknown, options: unknown) => {
      schedules.push({ name, cron, options });
      return Promise.resolve();
    },
  };
  return { boss, handlers, queues, schedules };
}

function bridge(boss: unknown, opts: { workers?: boolean; start?: () => Promise<void> } = {}) {
  const onec = {
    onConfirmed: vi.fn(() => Promise.resolve('applied')),
    onFailed: vi.fn(() => Promise.resolve('skipped')),
  };
  const retention = { purgeExpiredDrafts: vi.fn(() => Promise.resolve({ deleted: 2 })) };
  const service = boss === undefined ? undefined : { start: opts.start ?? (() => Promise.resolve()), instance: boss };
  const b = new ReturnsJobsBridge(
    { WORKERS_ENABLED: opts.workers ?? true },
    onec as never,
    retention as never,
    service as never,
  );
  return { b, onec, retention };
}

describe('ReturnsJobsBridge (pg-boss подменён)', () => {
  it('регистрирует returns.onec-confirmed/failed и retention.daily (03:30 Asia/Bishkek); обработчики вызывают сервисы', async () => {
    const f = fakeBoss({ race: true });
    const { b, onec, retention } = bridge(f.boss);
    b.onApplicationBootstrap();
    await vi.waitFor(() => expect(f.schedules).toHaveLength(1));
    expect([...f.handlers.keys()].sort()).toEqual(
      [QUEUES.retentionDaily, QUEUES.returnsOnecConfirmed, QUEUES.returnsOnecFailed].sort(),
    );
    expect(f.queues.get(QUEUES.retentionDaily)).toMatchObject({ policy: 'singleton' });
    expect(f.queues.get(QUEUES.returnsOnecConfirmed)).toMatchObject({ retryLimit: 1000 });
    expect(f.schedules[0]).toEqual({
      name: QUEUES.retentionDaily,
      cron: '30 3 * * *',
      options: { tz: 'Asia/Bishkek', singletonKey: QUEUES.retentionDaily },
    });
    const confirmed = f.handlers.get(QUEUES.returnsOnecConfirmed)!;
    const failed = f.handlers.get(QUEUES.returnsOnecFailed)!;
    expect(await confirmed([])).toBeUndefined();
    expect(await failed([])).toBeUndefined();
    expect(await confirmed([{ data: { outboxId: 'o1' } }])).toEqual({ outcome: 'applied' });
    expect(await failed([{ data: { outboxId: 'o2' } }])).toEqual({ outcome: 'skipped' });
    expect(onec.onConfirmed).toHaveBeenCalledWith({ outboxId: 'o1' });
    expect(onec.onFailed).toHaveBeenCalledWith({ outboxId: 'o2' });
    expect(await f.handlers.get(QUEUES.retentionDaily)!([])).toEqual({ deleted: 2 });
    expect(retention.purgeExpiredDrafts).toHaveBeenCalledTimes(1);
  });

  it('уже созданные очереди не пересоздаются; без воркеров или без pg-boss — ничего; без instance — ничего', async () => {
    const f = fakeBoss();
    for (const q of [QUEUES.returnsOnecConfirmed, QUEUES.returnsOnecFailed, QUEUES.retentionDaily])
      f.queues.set(q, 'old');
    const { b } = bridge(f.boss);
    b.onApplicationBootstrap();
    await vi.waitFor(() => expect(f.handlers.size).toBe(3));
    expect([...f.queues.values()]).toEqual(['old', 'old', 'old']);

    const off = fakeBoss();
    bridge(off.boss, { workers: false }).b.onApplicationBootstrap();
    bridge(undefined).b.onApplicationBootstrap();
    bridge(null).b.onApplicationBootstrap();
    await new Promise((r) => setTimeout(r, 10));
    expect(off.handlers.size).toBe(0);
  });

  it('сбой createQueue (очереди нет и после ошибки) и сбой старта pg-boss — только журнал, исключение не всплывает', async () => {
    const f = fakeBoss({ failCreate: true });
    const { b } = bridge(f.boss);
    const errSpy = vi.spyOn((b as unknown as { logger: { error: () => void } }).logger, 'error');
    b.onApplicationBootstrap();
    await vi.waitFor(() => expect(errSpy).toHaveBeenCalled());
    expect(f.handlers.size).toBe(0);
    const failing = bridge(fakeBoss().boss, { start: () => Promise.reject(new Error('pg-boss недоступен')) }).b;
    const spy2 = vi.spyOn((failing as unknown as { logger: { error: () => void } }).logger, 'error');
    failing.onApplicationBootstrap();
    await vi.waitFor(() => expect(spy2).toHaveBeenCalled());
  });
});

describe('ReturnsStatusSyncHandler (прогон return_docs)', () => {
  it('ошибки опроса → partial; без ошибок → success; счётчики — из опроса', async () => {
    const log = { info: vi.fn() };
    const ctx = { entity: 'return_docs', log } as never;
    const ok = new ReturnsStatusSyncHandler({ pollOpen: () => Promise.resolve({ polled: 2, failed: 0 }) } as never);
    expect(await ok.run(ctx)).toEqual({ implemented: true, status: 'success', counts: { polled: 2, failed: 0 } });
    const bad = new ReturnsStatusSyncHandler({ pollOpen: () => Promise.resolve({ polled: 2, failed: 1 }) } as never);
    expect(await bad.run(ctx)).toMatchObject({ status: 'partial' });
    expect(log.info).toHaveBeenCalledTimes(2);
  });
});
