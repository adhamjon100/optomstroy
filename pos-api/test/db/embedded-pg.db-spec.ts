import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';
import { EMBEDDED_PG_DIR_PREFIX, EmbeddedPg, sweepAbandonedClusters } from '../support/embedded-pg.js';

/**
 * Уборка каталогов одноразового PostgreSQL 17 (`test/support/embedded-pg.ts`, 2026-11-19): каталог появляется только в
 * start() и исчезает в stop(); сбой запуска не оставляет каталога и не вешает stop(); каталоги прерванных прогонов
 * убирает sweepAbandonedClusters() — только при мёртвых владельце и postmaster. Всё — в своей временной папке теста,
 * общие `pos-api-pg-*` параллельных прогонов не затрагиваются.
 */
describe('EmbeddedPg: каталоги кластеров не остаются после stop(), сбоя запуска и прерванных прогонов', () => {
  // Папка — в beforeAll, не при сборе файла: если `-t` отфильтровал все тесты, хуки не выполняются и папки нет.
  let base: string | undefined;
  const roots: string[] = [];
  const freshRoot = (): string => {
    if (base === undefined) throw new Error('beforeAll не выполнен');
    const r = join(base, String(roots.length));
    mkdirSync(r);
    roots.push(r);
    return r;
  };

  beforeAll(() => {
    base = mkdtempSync(join(tmpdir(), 'pos-embedded-pg-spec-'));
  });

  afterAll(() => {
    if (base !== undefined) rmSync(base, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    base = undefined;
  });

  it('конструктор каталога не создаёт; start() — каталог с меткой владельца; stop() — каталога нет; повторный stop() — ничего', async () => {
    const root = freshRoot();
    const db = new EmbeddedPg({ root });
    expect(readdirSync(root)).toEqual([]);
    await db.stop(); // без start() — ничего
    await db.start();
    const [dir, ...more] = readdirSync(root);
    expect(more).toEqual([]);
    expect(dir).toMatch(new RegExp(`^${EMBEDDED_PG_DIR_PREFIX}`));
    expect(readFileSync(join(root, dir, 'owner.pid'), 'utf8').trim()).toBe(String(process.pid));
    const c = new pg.Client({ connectionString: db.url('postgres') });
    await c.connect();
    expect((await c.query<{ one: number }>('SELECT 1 AS one')).rows[0]?.one).toBe(1);
    await c.end();
    // Занятый каталог уборка не трогает (владелец — этот процесс, postmaster жив).
    expect(sweepAbandonedClusters(root, Date.now() + 7 * 24 * 3600_000)).toEqual([]);
    await db.stop();
    expect(readdirSync(root)).toEqual([]);
    await db.stop();
  });

  it('postgres вышел до «ready»: start() отклоняется ошибкой, каталог удалён сразу, stop() не ждёт вечно', async () => {
    const root = freshRoot();
    const db = new EmbeddedPg({ root, postgresFlags: ['-c', 'no_such_parameter_flake_check=1'] });
    await expect(db.start()).rejects.toBeInstanceOf(Error);
    expect(readdirSync(root)).toEqual([]);
    await db.stop();
  });

  it('sweepAbandonedClusters: удаляет каталоги с мёртвыми владельцем и postmaster; живые, свежие без метки и чужие — нет', () => {
    const root = freshRoot();
    const dead = deadPid();
    const make = (name: string, files: Record<string, string>): string => {
      const dir = join(root, name);
      mkdirSync(join(dir, 'data'), { recursive: true });
      for (const [f, text] of Object.entries(files)) writeFileSync(join(dir, f), text);
      return dir;
    };
    const killedRun = make(`${EMBEDDED_PG_DIR_PREFIX}killed`, {
      'owner.pid': `${dead}\n`,
      'data/postmaster.pid': `${dead}\nD:/x/data\n`,
    });
    const liveOwner = make(`${EMBEDDED_PG_DIR_PREFIX}live-owner`, { 'owner.pid': `${process.pid}\n` });
    const orphanPostgres = make(`${EMBEDDED_PG_DIR_PREFIX}orphan-pg`, {
      'owner.pid': `${dead}\n`,
      'data/postmaster.pid': `${process.pid}\n`,
    });
    const unmarkedOld = make(`${EMBEDDED_PG_DIR_PREFIX}legacy`, { 'data/postmaster.pid': `${dead}\n` });
    const unmarkedFresh = make(`${EMBEDDED_PG_DIR_PREFIX}fresh`, {});
    const foreign = make('pos-other-dir', { 'owner.pid': `${dead}\n` });
    writeFileSync(join(root, `${EMBEDDED_PG_DIR_PREFIX}file`), 'не каталог');

    // Сейчас: убран только каталог прерванного прогона; каталоги без метки моложе 6 ч считаются занятыми.
    expect(sweepAbandonedClusters(root)).toEqual([killedRun]);
    // Через 7 ч: убраны и каталоги без метки (прежняя версия помощника); занятые и чужие остаются.
    expect(sweepAbandonedClusters(root, Date.now() + 7 * 3600_000).sort()).toEqual([unmarkedFresh, unmarkedOld].sort());
    for (const kept of [liveOwner, orphanPostgres, foreign]) expect(existsSync(kept), kept).toBe(true);
    expect(existsSync(join(root, `${EMBEDDED_PG_DIR_PREFIX}file`))).toBe(true);
    expect(sweepAbandonedClusters(join(root, 'нет-такой-папки'))).toEqual([]);
  });
});

/** PID завершившегося процесса (проверен сигналом 0: такого процесса нет). */
function deadPid(): number {
  for (let i = 0; i < 5; i++) {
    const pid = spawnSync(process.execPath, ['-e', '']).pid;
    if (pid === undefined) continue;
    try {
      process.kill(pid, 0);
    } catch {
      return pid;
    }
  }
  throw new Error('не удалось получить PID завершившегося процесса');
}
