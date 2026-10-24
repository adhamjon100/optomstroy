import { randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import EmbeddedPostgres from 'embedded-postgres';
import pg from 'pg';

/** LC_CTYPE тестовых БД с классификацией кириллицы: `en-US` (Windows) или `C.UTF-8` (glibc/macOS). */
export const UTF8_CTYPE = process.platform === 'win32' ? 'en-US' : 'C.UTF-8';

/**
 * Одноразовый PostgreSQL 17 для e2e без Docker (ядро R0 §0; тот же пакет, что tools/pg). В CI с Docker —
 * testcontainers (RM-C-012). Пароль генерируется на запуск, кластер удаляется в stop().
 */
export class EmbeddedPg {
  private server: EmbeddedPostgres | undefined;
  private readonly dir = mkdtempSync(join(tmpdir(), 'pos-api-pg-'));
  private readonly password = randomBytes(18).toString('base64url');
  port = 0;

  async start(): Promise<void> {
    this.port = await freePort();
    this.server = new EmbeddedPostgres({
      databaseDir: join(this.dir, 'data'),
      user: 'postgres',
      password: this.password,
      port: this.port,
      persistent: false,
      initdbFlags: ['--encoding=UTF8', '--locale=C'],
      postgresFlags: ['-c', 'listen_addresses=127.0.0.1', '-c', 'fsync=off', '-c', 'timezone=UTC'],
      onLog: () => undefined,
      onError: () => undefined,
    });
    await this.server.initialise();
    await this.server.start();
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
    await c.query(
      `CREATE DATABASE ${name} TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' LC_COLLATE 'C' LC_CTYPE '${UTF8_CTYPE}'`,
    );
    await c.end();
  }

  /** Применяет SQL-миграции pos-api/migrations/* (forward-only DDL RM-B-005 и seed RM-B-008). */
  async migrate(database: string, files: readonly string[]): Promise<void> {
    const c = new pg.Client({ connectionString: this.url(database) });
    await c.connect();
    try {
      for (const f of files) {
        const sql = readFileSync(fileURLToPath(new URL(`../../migrations/${f}`, import.meta.url)), 'utf8');
        await c.query(sql);
      }
    } finally {
      await c.end();
    }
  }

  async stop(): Promise<void> {
    await this.server?.stop().catch(() => undefined);
    rmSync(this.dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
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
