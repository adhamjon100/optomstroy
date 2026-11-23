import { mkdtempSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { isAlive, readPid } from './embedded-pg.js';

/**
 * Временные каталоги файлов секретов тестовых стендов pos-api (`*_FILE`: ключи JWT, pepper, HMAC — **тестовые
 * значения**, генерируются на запуск) — `pos-<стенд>-secrets-*` во временной папке (`os.tmpdir()`; в прогонах
 * проекта — `TEMP`).
 *
 * Уборка (2026-11-19, как у каталогов `pos-api-pg-*` в `embedded-pg.ts`): каталог создаётся в start() стенда, а не
 * при сборе файла тестов (файл, все тесты которого отфильтрованы `-t`, не создаёт ничего); stop() удаляет его в
 * `finally` — даже если остановка приложения или базы упала; сбой start() стенд убирает сам. Каталоги прогонов,
 * снятых целиком (afterAll не выполнился), убирает следующий createSecretsDir(): каталог с меткой `owner.pid` — только
 * если процесс-владелец завершился, каталог без метки (стенды до 2026-11-19) — только старше 6 ч.
 */
export const SECRETS_DIR_PATTERN = /^pos-[a-z]+-secrets-/;
const OWNER_FILE = 'owner.pid';
/** Каталог без метки владельца считается брошенным только с этого возраста. */
const UNMARKED_MIN_AGE_MS = 6 * 3600_000;

/** Новый каталог секретов `<prefix>XXXXXX` с меткой владельца; перед созданием — уборка брошенных. */
export function createSecretsDir(prefix: string, root: string = tmpdir()): string {
  if (!SECRETS_DIR_PATTERN.test(prefix)) {
    throw new Error(`createSecretsDir: префикс «${prefix}» не вида pos-<стенд>-secrets-`);
  }
  sweepAbandonedSecretsDirs(root);
  const dir = mkdtempSync(join(root, prefix));
  try {
    writeFileSync(join(dir, OWNER_FILE), `${process.pid}\n`);
  } catch (e) {
    removeSecretsDir(dir);
    throw e;
  }
  return dir;
}

/** Удаляет каталог секретов; `undefined` — ничего. Ошибку удаления не бросает: каталог уберёт следующая уборка. */
export function removeSecretsDir(dir: string | undefined): void {
  if (dir === undefined) return;
  try {
    rmSync(dir, { recursive: true, force: true, maxRetries: 2, retryDelay: 100 });
  } catch {
    // Не заслоняем исходную ошибку stop(); владелец завершится — каталог уберёт sweepAbandonedSecretsDirs().
  }
}

/**
 * Удаляет из `root` каталоги `pos-*-secrets-*`, брошенные прерванными прогонами, и возвращает их пути. Каталог занят
 * и не трогается, если жив процесс-владелец (`owner.pid`); каталог без метки — ещё и моложе UNMARKED_MIN_AGE_MS
 * (прежние версии стендов и только что созданный параллельным прогоном, ещё без метки). Ошибки не мешают запуску.
 */
export function sweepAbandonedSecretsDirs(root: string = tmpdir(), now: number = Date.now()): string[] {
  let names: string[];
  try {
    names = readdirSync(root);
  } catch {
    return [];
  }
  const removed: string[] = [];
  for (const name of names) {
    if (!SECRETS_DIR_PATTERN.test(name)) continue;
    const dir = join(root, name);
    try {
      if (!statSync(dir).isDirectory()) continue;
      const owner = readPid(join(dir, OWNER_FILE));
      const inUse = owner !== undefined ? isAlive(owner) : now - statSync(dir).mtimeMs < UNMARKED_MIN_AGE_MS;
      if (inUse) continue;
      rmSync(dir, { recursive: true, force: true, maxRetries: 2, retryDelay: 100 });
      removed.push(dir);
    } catch {
      // Каталог исчез (его убрал параллельный прогон) или файл ещё занят — следующий запуск попробует снова.
    }
  }
  return removed;
}
