import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import {
  AUDIT_ANCHOR_CRON,
  AUDIT_VERIFY_CRON,
  AuditJobsBridge,
  auditAnchorExportDir,
  previousBishkekDate,
} from '../../src/admin/audit/audit-jobs.bridge.js';
import { AuditAnchorService } from '../../src/common/audit/audit-anchor.service.js';
import { AuditService } from '../../src/common/audit/audit.service.js';
import { QUEUES } from '../../src/common/jobs/contracts/queues.js';
import { AdminTestApp } from './support/admin-app.js';

/**
 * Задачи pos-worker `audit.anchor` / `audit.verify` (06 §7.5; 07 §9.3; 11 SEC-080, SEC-081; 13 RM-G-006 критерий 2;
 * ревью G-security-1) — **тестовые данные** на embedded PostgreSQL 17: регистрация очередей и расписаний 03:30/03:45
 * Asia/Bishkek на подменённом pg-boss; якорь прошедших суток в `audit_anchors` и файл `audit-anchors/YYYY-MM-DD.txt`
 * рядом с `MEDIA_DIR` (идемпотентно); проверка цепочки за 7 суток и сверка якорей; подмена строки → `audit.chain.broken`.
 */
type JobFn = (jobs: { data: unknown }[]) => Promise<unknown>;

describe('AuditJobsBridge (audit.anchor, audit.verify)', () => {
  const t = new AdminTestApp();
  const media = join(mkdtempSync(join(tmpdir(), 'pos-audit-jobs-')), 'media');

  beforeAll(async () => {
    await t.start('audit_jobs_e2e', { audit: true });
    const audit = t.app.get(AuditService);
    for (const name of ['sales-summary', 'receivables']) {
      await audit.write({ system: 'test' }, { action: 'report.viewed', entityType: 'report', after: { name } });
    }
  }, 600_000);

  afterAll(async () => {
    await t.stop();
  });

  function bridge(boss?: unknown, workers = true, start: () => Promise<void> = () => Promise.resolve()) {
    return new AuditJobsBridge(
      { WORKERS_ENABLED: workers, MEDIA_DIR: media },
      t.app.get(AuditAnchorService),
      t.fdb.db,
      boss === undefined ? undefined : ({ start, instance: boss } as never),
    );
  }

  it('сутки якоря — прошедшие сутки Asia/Bishkek; файл якоря — MEDIA_DIR/../audit-anchors', () => {
    expect(previousBishkekDate(new Date('2026-10-24T21:30:00Z'))).toBe('2026-10-24'); // 03:30 25.10 по Бишкеку
    expect(previousBishkekDate(new Date('2026-10-24T17:59:00Z'))).toBe('2026-10-23'); // 23:59 24.10 по Бишкеку
    expect(auditAnchorExportDir('/data/media')).toBe(join('/data', 'audit-anchors'));
  });

  it('регистрация на pg-boss: очереди (гонка createQueue), обработчики и расписания с часовым поясом', async () => {
    const handlers = new Map<string, JobFn>();
    const queues = new Set<string>([QUEUES.auditVerify]);
    const schedules: unknown[][] = [];
    let race = true;
    const boss = {
      getQueue: (n: string) => Promise.resolve(queues.has(n) ? { name: n } : null),
      createQueue: (n: string) => {
        queues.add(n);
        if (race) {
          race = false;
          return Promise.reject(new Error('queue already exists'));
        }
        return Promise.resolve();
      },
      work: (n: string, _o: unknown, fn: JobFn) => {
        handlers.set(n, fn);
        return Promise.resolve('w');
      },
      schedule: (...a: unknown[]) => {
        schedules.push(a);
        return Promise.resolve();
      },
    };
    bridge(boss).onApplicationBootstrap();
    await vi.waitFor(() => expect(schedules).toHaveLength(2));
    expect([...handlers.keys()].sort()).toEqual([QUEUES.auditAnchor, QUEUES.auditVerify]);
    expect(schedules).toEqual([
      [QUEUES.auditAnchor, AUDIT_ANCHOR_CRON, {}, { tz: 'Asia/Bishkek', singletonKey: QUEUES.auditAnchor }],
      [QUEUES.auditVerify, AUDIT_VERIFY_CRON, {}, { tz: 'Asia/Bishkek', singletonKey: QUEUES.auditVerify }],
    ]);
    // Без воркеров / без pg-boss / без instance — ничего; сбой старта или createQueue — только журнал.
    bridge(boss, false).onApplicationBootstrap();
    bridge(undefined).onApplicationBootstrap();
    bridge(null).onApplicationBootstrap();
    const broken = bridge({
      ...boss,
      getQueue: () => Promise.resolve(null),
      createQueue: () => Promise.reject(new Error('x')),
    });
    const spy = vi.spyOn((broken as unknown as { logger: { error: () => void } }).logger, 'error');
    broken.onApplicationBootstrap();
    await vi.waitFor(() => expect(spy).toHaveBeenCalled());
    const failing = bridge(boss, true, () => Promise.reject(new Error('pg-boss недоступен')));
    const spy2 = vi.spyOn((failing as unknown as { logger: { error: () => void } }).logger, 'error');
    failing.onApplicationBootstrap();
    await vi.waitFor(() => expect(spy2).toHaveBeenCalled());
  });

  it('audit.anchor: якорь прошедших суток + файл; повтор идемпотентен; пустой период — null; audit.verify — цепочка цела', async () => {
    const b = bridge();
    // «Завтра 03:30» — прошедшие сутки = сегодня (строки аудита теста уже есть).
    b.now = () => new Date(Date.now() + 86_400_000);
    const today = previousBishkekDate(b.now());
    const a = await b.anchor();
    expect(a).toMatchObject({ anchorDate: today, created: true });
    expect(a?.exportPath).toBe(join(auditAnchorExportDir(media), `${today}.txt`));
    expect(existsSync(a!.exportPath!)).toBe(true);
    const row = (
      await t.fdb.pool.query<{ s: string; h: Buffer }>(
        `SELECT last_chain_seq::text AS s, last_row_hash AS h FROM audit_anchors WHERE anchor_date = $1::date`,
        [today],
      )
    ).rows[0];
    expect(readFileSync(a!.exportPath!, 'utf8').trim()).toBe(`${today};${row.s};${row.h.toString('hex')}`);
    expect(await b.anchor()).toMatchObject({ anchorDate: today, created: false });
    const empty = bridge();
    empty.now = () => new Date('2001-01-02T00:00:00Z');
    expect(await empty.anchor()).toBeNull();

    const v = await b.verify();
    expect(v).toEqual({ chainOk: true, brokenAtChainSeq: null, anchorsBroken: [] });
    const verified = await t.fdb.pool.query<{ r: string }>(
      `SELECT verify_result AS r FROM audit_anchors WHERE anchor_date = $1::date`,
      [today],
    );
    expect(verified.rows[0]?.r).toBe('ok');
    // Нет записей за 7 суток — цепочка не проверяется, только якоря.
    const far = bridge();
    far.now = () => new Date(Date.now() + 30 * 86_400_000);
    expect(await far.verify()).toEqual({ chainOk: true, brokenAtChainSeq: null, anchorsBroken: [] });
  });

  it('audit.verify: подмена строки якоря суперпользователем → audit.chain.broken (цепочка и якорь)', async () => {
    const b = bridge();
    const seq = (await t.fdb.pool.query<{ s: string }>(`SELECT max(last_chain_seq)::text AS s FROM audit_anchors`))
      .rows[0].s;
    const su = await t.fdb.client();
    try {
      await su.query('ALTER TABLE audit_logs DISABLE TRIGGER trg_audit_logs_immutable');
      await su.query(`UPDATE audit_logs SET row_hash = sha256('x'::bytea) WHERE chain_seq = $1::bigint`, [seq]);
      await su.query('ALTER TABLE audit_logs ENABLE TRIGGER trg_audit_logs_immutable');
    } finally {
      await su.end();
    }
    const spy = vi.spyOn((b as unknown as { logger: { error: () => void } }).logger, 'error');
    const v = await b.verify();
    expect(v.chainOk).toBe(false);
    expect(v.anchorsBroken.length).toBe(1);
    expect(spy).toHaveBeenCalledWith(expect.objectContaining({ event: 'audit.chain.broken' }), 'audit.chain.broken');
  });
});
