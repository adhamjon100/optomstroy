import { randomBytes } from 'node:crypto';
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import EmbeddedPostgres from 'embedded-postgres';
import pg from 'pg';
import { installPgBoss } from '../../src/db/pgboss-install.js';

const SILENT = { info: () => undefined, warn: () => undefined };

/** LC_CTYPE тестовых БД с классификацией кириллицы: `en-US` (Windows) или `C.UTF-8` (glibc/macOS). */
export const UTF8_CTYPE = process.platform === 'win32' ? 'en-US' : 'C.UTF-8';

/** Префикс каталогов кластеров во временной папке (`os.tmpdir()`; в прогонах проекта — `TEMP`). */
export const EMBEDDED_PG_DIR_PREFIX = 'pos-api-pg-';
/** Метка владельца в каталоге кластера: PID процесса node, который его создал. */
const OWNER_FILE = 'owner.pid';
/**
 * Каталог без метки владельца (прежняя версия помощника или только что созданный другим процессом, ещё без метки)
 * и без живого postmaster считается брошенным только с этого возраста.
 */
const UNMARKED_MIN_AGE_MS = 6 * 3600_000;

export interface EmbeddedPgOptions {
  /** Где создать каталог кластера (по умолчанию `os.tmpdir()`). */
  readonly root?: string;
  /** Дополнительные `-c` параметры postgres (после штатных). */
  readonly postgresFlags?: readonly string[];
}

/**
 * Одноразовый PostgreSQL 17 для e2e без Docker (ядро R0 §0; тот же пакет, что tools/pg). В CI с Docker —
 * testcontainers (RM-C-012). Пароль генерируется на запуск, кластер удаляется в stop().
 *
 * Уборка (2026-11-19): каталог `pos-api-pg-*` создаётся в start(), не в конструкторе; при сбое
 * start() (initdb, ранний выход postgres) каталог удаляется сразу; stop() не ждёт уже завершившийся postgres. Прогон,
 * снятый целиком (таймаут, Ctrl+C, принудительное завершение воркера vitest), afterAll не выполняет — такие каталоги
 * убирает следующий start() через sweepAbandonedClusters(): только при мёртвых владельце и postmaster.
 */
export class EmbeddedPg {
  private server: EmbeddedPostgres | undefined;
  private dir: string | undefined;
  private postmasterPid: number | undefined;
  private readonly password = randomBytes(18).toString('base64url');
  port = 0;

  constructor(private readonly options: EmbeddedPgOptions = {}) {}

  async start(): Promise<void> {
    if (this.dir !== undefined) throw new Error('EmbeddedPg.start(): кластер уже запущен');
    const root = this.options.root ?? tmpdir();
    sweepAbandonedClusters(root);
    const dir = mkdtempSync(join(root, EMBEDDED_PG_DIR_PREFIX));
    writeFileSync(join(dir, OWNER_FILE), `${process.pid}\n`);
    this.dir = dir;
    try {
      this.port = await freePort();
      this.server = new EmbeddedPostgres({
        databaseDir: join(dir, 'data'),
        user: 'postgres',
        password: this.password,
        port: this.port,
        persistent: false,
        initdbFlags: ['--encoding=UTF8', '--locale=C'],
        postgresFlags: [
          '-c',
          'listen_addresses=127.0.0.1',
          '-c',
          'fsync=off',
          '-c',
          'timezone=UTC',
          ...(this.options.postgresFlags ?? []),
        ],
        onLog: () => undefined,
        onError: () => undefined,
      });
      await this.server.initialise();
      await this.server.start();
      this.postmasterPid = readPid(join(dir, 'data', 'postmaster.pid'));
    } catch (e) {
      // initdb не прошёл или postgres вышел до «ready» (например, порт занят между freePort() и запуском): процесса
      // уже нет, а stop() библиотеки ждал бы его событие 'exit' вечно. Каталог убираем здесь — вызывающий код
      // (startCatalogFixture и др.) после ошибки start() не всегда зовёт stop().
      this.server = undefined;
      this.dir = undefined;
      try {
        removeDir(dir);
      } catch {
        // Не заслоняем исходную ошибку; каталог уберёт sweepAbandonedClusters() после завершения процесса.
      }
      throw e instanceof Error ? e : new Error(`embedded PostgreSQL не запустился (порт ${this.port}, каталог ${dir})`);
    }
  }

  url(database: string): string {
    return `postgres://postgres:${encodeURIComponent(this.password)}@127.0.0.1:${this.port}/${database}`;
  }

  async createDatabase(name: string): Promise<void> {
    const c = new pg.Client({ connectionString: this.url('postgres') });
    await c.connect();
    // Встроенный провайдер локали PG17 «C.UTF-8»: lower()/upper() корректны для кириллицы (norm_search, name_norm —
    // 07 §10.1), сортировка — побайтовая, как у --locale=C кластера. LC_CTYPE — UTF-8 (как en_US.utf8 образа
    // postgres:17 в prod): при LC_CTYPE 'C' парсер FTS и pg_trgm не считают кириллицу буквами — show_trgm('смеситель')
    // пуст, to_tsvector не приводит регистр (EQ-SRCH-01; интеграция этапа E — общий помощник для всех наборов).
    try {
      await c.query(
        `CREATE DATABASE ${name} TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' LC_COLLATE 'C' LC_CTYPE '${UTF8_CTYPE}'`,
      );
    } finally {
      // При ошибке CREATE DATABASE соединение тоже закрывается: иначе остановка кластера рвёт его, и pg.Client без
      // обработчика 'error' роняет набор необработанной ошибкой ECONNRESET (найдено тестом secrets-dir.db-spec.ts).
      await c.end();
    }
  }

  /**
   * Применяет SQL-миграции pos-api/migrations/* (forward-only DDL RM-B-005 и seed RM-B-008) и, как `migrate.ts`,
   * ставит схему pg-boss с правами `pos_app` (07 DATA-012): api и worker сами её не создают.
   */
  async migrate(database: string, files: readonly string[]): Promise<void> {
    const c = new pg.Client({ connectionString: this.url(database) });
    await c.connect();
    try {
      for (const f of files) {
        const sql = readFileSync(fileURLToPath(new URL(`../../migrations/${f}`, import.meta.url)), 'utf8');
        await c.query(sql);
      }
      await installPgBoss(c, this.url(database), { logger: SILENT });
    } finally {
      await c.end();
    }
  }

  /** Останавливает postgres и удаляет каталог; повторный вызов и вызов без start() ничего не делают. */
  async stop(): Promise<void> {
    const { server, dir, postmasterPid } = this;
    this.server = undefined;
    this.dir = undefined;
    this.postmasterPid = undefined;
    // postgres, упавший сам, stop() библиотеки ждал бы вечно (событие 'exit' уже было) — тогда только удаляем каталог.
    if (server && (postmasterPid === undefined || isAlive(postmasterPid))) await server.stop().catch(() => undefined);
    if (dir !== undefined) removeDir(dir);
  }
}

/**
 * Удаляет из `root` каталоги `pos-api-pg-*`, брошенные прерванными прогонами, и возвращает их пути. Каталог занят и не
 * трогается, если жив процесс-владелец (`owner.pid`) или postmaster (`data/postmaster.pid`); каталог без метки
 * владельца — ещё и моложе UNMARKED_MIN_AGE_MS. Живой «осиротевший» postgres (воркер vitest снят, postgres остался)
 * тоже не трогается: каталог уберёт первый запуск после его завершения. Ошибки удаления не мешают запуску.
 */
export function sweepAbandonedClusters(root: string = tmpdir(), now: number = Date.now()): string[] {
  let names: string[];
  try {
    names = readdirSync(root);
  } catch {
    return [];
  }
  const removed: string[] = [];
  for (const name of names) {
    if (!name.startsWith(EMBEDDED_PG_DIR_PREFIX)) continue;
    const dir = join(root, name);
    try {
      if (!statSync(dir).isDirectory() || clusterInUse(dir, now)) continue;
      rmSync(dir, { recursive: true, force: true, maxRetries: 2, retryDelay: 100 });
      removed.push(dir);
    } catch {
      // Каталог исчез (его убрал параллельный прогон) или файл ещё занят — следующий запуск попробует снова.
    }
  }
  return removed;
}

function clusterInUse(dir: string, now: number): boolean {
  const owner = readPid(join(dir, OWNER_FILE));
  if (owner !== undefined && isAlive(owner)) return true;
  const postmaster = readPid(join(dir, 'data', 'postmaster.pid'));
  if (postmaster !== undefined && isAlive(postmaster)) return true;
  return owner === undefined && now - statSync(dir).mtimeMs < UNMARKED_MIN_AGE_MS;
}

/** Первая строка файла — PID (`owner.pid`, `postmaster.pid`); нет файла или не число — undefined. */
export function readPid(file: string): number | undefined {
  let text: string;
  try {
    text = readFileSync(file, 'utf8');
  } catch {
    return undefined;
  }
  const pid = Number.parseInt(text.split(/\r?\n/, 1)[0] ?? '', 10);
  return Number.isSafeInteger(pid) && pid > 0 ? pid : undefined;
}

/** Процесс существует (сигнал 0 работает и на Windows); EPERM — существует, но чужой. */
export function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'EPERM';
  }
}

function removeDir(dir: string): void {
  rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.once('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const addr = s.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      s.close(() => resolve(port));
    });
  });
}
