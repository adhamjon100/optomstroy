import pg from 'pg';
import { EmbeddedPg, UTF8_CTYPE } from '../../support/embedded-pg.js';

/**
 * Встроенный PostgreSQL 17 для тестов поиска с **UTF-8 локалью классификации символов** (LC_CTYPE).
 *
 * Общий `EmbeddedPg.createDatabase` создаёт БД с `LC_CTYPE 'C'`: при ней PostgreSQL не считает кириллицу буквами —
 * `show_trgm('смеситель')` = `{}`, а `to_tsvector('russian', 'Смеситель')` оставляет прописную «С», поэтому FTS и
 * триграммы по-русски не работают (EQ-SRCH-01). Продуктовый образ `postgres:17` создаёт кластер с `en_US.utf8`;
 * здесь — `en-US` (Windows) или `C.UTF-8` (glibc). Порядок строк — по-прежнему `LC_COLLATE 'C'` + builtin.
 */
export const SEARCH_LC_CTYPE = UTF8_CTYPE;

export class SearchPg extends EmbeddedPg {
  override async createDatabase(name: string): Promise<void> {
    if (!/^[a-z_][a-z0-9_]{0,62}$/.test(name)) throw new Error(`недопустимое имя БД: ${name}`);
    const c = new pg.Client({ connectionString: this.url('postgres') });
    await c.connect();
    try {
      await c.query(
        `CREATE DATABASE ${name} TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8'
           LC_COLLATE 'C' LC_CTYPE '${SEARCH_LC_CTYPE}'`,
      );
    } finally {
      await c.end();
    }
  }
}

/** Миграции для тестов поиска: все `migrations/*.sql` (0005_search — индексы поиска этого агента). */
export { allMigrations } from '../../support/catalog-fixture.js';

/** Проверка, что БД классифицирует кириллицу (иначе тесты поиска бессмысленны). */
export async function assertCyrillicCtype(pool: pg.Pool): Promise<void> {
  const r = await pool.query<{ n: number; v: string }>(
    `SELECT cardinality(show_trgm('смеситель')) AS n, to_tsvector('public.ru_unaccent', 'Смесители')::text AS v`,
  );
  if (r.rows[0].n === 0 || !r.rows[0].v.includes('смесител')) {
    throw new Error(`LC_CTYPE ${SEARCH_LC_CTYPE} не классифицирует кириллицу: ${JSON.stringify(r.rows[0])}`);
  }
}
