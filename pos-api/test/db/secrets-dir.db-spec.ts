import { spawnSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AdminTestApp } from '../admin/support/admin-app.js';
import { EMBEDDED_PG_DIR_PREFIX } from '../support/embedded-pg.js';
import { createSecretsDir, removeSecretsDir, sweepAbandonedSecretsDirs } from '../support/secrets-dir.js';

/**
 * Уборка каталогов файлов секретов тестовых стендов (`test/support/secrets-dir.ts`, 2026-11-19): каталог с меткой
 * владельца создаётся в start() стенда и удаляется в stop() даже после сбоя; каталоги прерванных прогонов убирает
 * следующий createSecretsDir() — только при мёртвом владельце (без метки — старше 6 ч). Опыты с уборкой — в своей
 * временной папке теста; общая временная папка прогона не трогается.
 */
describe('Каталоги секретов тестовых стендов не остаются после stop(), сбоя запуска и прерванных прогонов', () => {
  // Папка — в beforeAll, не при сборе файла: если `-t` отфильтровал все тесты, хуки не выполняются и папки нет.
  let base: string | undefined;
  let seq = 0;
  const freshRoot = (): string => {
    if (base === undefined) throw new Error('beforeAll не выполнен');
    const r = join(base, String(seq++));
    mkdirSync(r);
    return r;
  };

  beforeAll(() => {
    base = mkdtempSync(join(tmpdir(), 'pos-secrets-dir-spec-'));
  });

  afterAll(() => {
    if (base !== undefined) rmSync(base, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    base = undefined;
  });

  it('createSecretsDir: каталог с меткой владельца; removeSecretsDir удаляет, повтор и undefined — ничего', () => {
    const root = freshRoot();
    const dir = createSecretsDir('pos-sales-secrets-', root);
    expect(readdirSync(root)).toEqual([dir.slice(root.length + 1)]);
    expect(dir.slice(root.length + 1)).toMatch(/^pos-sales-secrets-/);
    expect(readFileSync(join(dir, 'owner.pid'), 'utf8').trim()).toBe(String(process.pid));
    removeSecretsDir(dir);
    expect(readdirSync(root)).toEqual([]);
    removeSecretsDir(dir);
    removeSecretsDir(undefined);
    expect(() => createSecretsDir('pos-api-pg-', root)).toThrow(/pos-<стенд>-secrets-/);
    expect(readdirSync(root)).toEqual([]);
  });

  it('sweepAbandonedSecretsDirs: удаляет каталоги с мёртвым владельцем и старые без метки; живые, свежие и чужие — нет', () => {
    const root = freshRoot();
    const dead = deadPid();
    const make = (name: string, owner?: number): string => {
      const dir = join(root, name);
      mkdirSync(dir);
      writeFileSync(join(dir, 'jwt_private.pem'), 'тестовое значение');
      if (owner !== undefined) writeFileSync(join(dir, 'owner.pid'), `${owner}\n`);
      return dir;
    };
    const killedRun = make('pos-sales-secrets-killed', dead);
    const liveOwner = make('pos-admin-secrets-live', process.pid);
    const unmarkedFresh = make('pos-links-secrets-fresh');
    const unmarkedOld = make('pos-catalog-secrets-legacy');
    const old = new Date(Date.now() - 7 * 3600_000);
    utimesSync(unmarkedOld, old, old);
    const foreign = [make('pos-api-pg-x', dead), make('pos-audit-jobs-x', dead), make('pos-sales-secretsx', dead)];
    writeFileSync(join(root, 'pos-sync-secrets-file'), 'не каталог');

    expect(sweepAbandonedSecretsDirs(root).sort()).toEqual([killedRun, unmarkedOld].sort());
    for (const kept of [liveOwner, unmarkedFresh, ...foreign]) expect(existsSync(kept), kept).toBe(true);
    expect(existsSync(join(root, 'pos-sync-secrets-file'))).toBe(true);
    // Через 7 ч свежий каталог без метки тоже брошенный; каталог живого владельца — нет.
    expect(sweepAbandonedSecretsDirs(root, Date.now() + 7 * 3600_000)).toEqual([unmarkedFresh]);
    expect(existsSync(liveOwner)).toBe(true);
    expect(sweepAbandonedSecretsDirs(join(root, 'нет-такой-папки'))).toEqual([]);

    // createSecretsDir сначала убирает брошенные.
    const again = make('pos-reg-secrets-killed', dead);
    const dir = createSecretsDir('pos-reg-secrets-', root);
    expect(existsSync(again)).toBe(false);
    expect(existsSync(dir)).toBe(true);
    removeSecretsDir(dir);
  });

  it('стенд: сбой start() убирает каталог секретов и кластер сам; повторный stop() — ничего', async () => {
    // Каталоги этого процесса (метка owner.pid) во временной папке прогона: секреты стенда и кластер PostgreSQL.
    const own = (): string[] =>
      readdirSync(tmpdir())
        .filter((n) => n.startsWith('pos-admin-secrets-') || n.startsWith(EMBEDDED_PG_DIR_PREFIX))
        .filter((n) => {
          try {
            return readFileSync(join(tmpdir(), n, 'owner.pid'), 'utf8').trim() === String(process.pid);
          } catch {
            return false;
          }
        });
    expect(own()).toEqual([]);
    const t = new AdminTestApp();
    expect(own()).toEqual([]); // конструктор каталогов не создаёт
    // Имя базы с дефисом — синтаксическая ошибка CREATE DATABASE: кластер поднят, приложение — ещё нет.
    await expect(t.start('bad-name')).rejects.toThrow();
    expect(own()).toEqual([]);
    await t.stop();
    await t.stop();
    expect(own()).toEqual([]);
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
