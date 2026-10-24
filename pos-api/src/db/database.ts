import { drizzle, type NodePgDatabase } from 'drizzle-orm/node-postgres';
import type pg from 'pg';
import * as schema from './schema/index.js';

/**
 * Drizzle-клиент со схемой всех таблиц (RM-C-006). Пул создаёт common/db (DatabaseModule); модули этапов D–G
 * получают типизированный клиент через `createDatabase(pool)`. Схема — проекция SQL-миграций (столбцы, типы,
 * NOT NULL, DEFAULT, PK); ограничения, индексы и триггеры действуют на стороне БД.
 */
export { schema };
export type PosDatabase = NodePgDatabase<typeof schema>;

export function createDatabase(pool: pg.Pool): PosDatabase {
  return drizzle({ client: pool, schema });
}
