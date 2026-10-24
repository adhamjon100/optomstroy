import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/** Пути репозитория для тестов и генераторов RM-C-006 (относительно pos-api/test/db/support). */
export const POS_API_DIR = fileURLToPath(new URL('../../../', import.meta.url));
export const MIGRATIONS_DIR = fileURLToPath(new URL('../../../migrations/', import.meta.url));
export const SEEDS_DIR = fileURLToPath(new URL('../../../seeds/', import.meta.url));
export const SCHEMA_DIR = fileURLToPath(new URL('../../../src/db/schema/', import.meta.url));
export const CHECK_TABLES_SQL = fileURLToPath(new URL('../../../../scripts/check_tables.sql', import.meta.url));
export const SCHEMA_DUMP_SQL = fileURLToPath(new URL('../../../../docs/erd/schema_v1.sql', import.meta.url));

export interface ExpectedTable {
  readonly name: string;
  readonly domain: string;
  readonly card: string;
}

/**
 * Канонический список 64 таблиц (07 §5) — из scripts/check_tables.sql (RM-B-005): строки
 * `('table', 'domain', 'card')` блока `INSERT INTO expected_tables`.
 */
export function expectedTables(): ExpectedTable[] {
  const sql = readFileSync(CHECK_TABLES_SQL, 'utf8');
  const block = /INSERT INTO expected_tables[^;]*;/s.exec(sql)?.[0] ?? '';
  return [...block.matchAll(/\('([a-z_]+)',\s*'([a-z]+)',\s*'([^']*)'\)/g)].map((m) => ({
    name: m[1],
    domain: m[2],
    card: m[3],
  }));
}
