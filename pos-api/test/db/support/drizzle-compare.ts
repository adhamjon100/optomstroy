import { is } from 'drizzle-orm';
import { getTableConfig, isPgEnum, PgTable, type PgEnum } from 'drizzle-orm/pg-core';
import type { CatalogEnum, CatalogTable } from './catalog.js';

/**
 * Сверка Drizzle-схемы с каталогом БД (замена `drizzle-kit check` для схемы, которая не генерируется
 * drizzle-kit, — см. migrate-seed.db-spec.ts). Сравниваются: набор таблиц, столбцы (имя, тип, NOT NULL,
 * наличие DEFAULT, GENERATED и его выражение), первичные ключи, enum-ы (значения и порядок).
 */
export function normalizeType(t: string): string {
  return t
    .toLowerCase()
    .replace(/\s+\(/g, '(')
    .replace(/,\s+/g, ',')
    .replace(/^character varying/, 'varchar')
    .replace(/^character\(/, 'char(')
    .replace(/^timestamp(\(\d+\))? with time zone/, 'timestamptz$1')
    .replace(/^timestamp(\(\d+\))? without time zone/, 'timestamp$1')
    .replace(/^time(\(\d+\))? without time zone/, 'time$1')
    .replace(/"/g, '')
    .trim();
}

export interface SchemaDiff {
  readonly problems: string[];
  readonly tablesCompared: number;
  readonly columnsCompared: number;
  readonly enumsCompared: number;
}

export function compareDrizzleWithDb(
  schemaModule: Record<string, unknown>,
  dbTables: readonly CatalogTable[],
  dbEnums: readonly CatalogEnum[],
): SchemaDiff {
  const problems: string[] = [];
  const drizzleTables = Object.values(schemaModule).filter((v): v is PgTable => is(v, PgTable));
  const drizzleEnums = Object.values(schemaModule).filter((v): v is PgEnum<[string, ...string[]]> => isPgEnum(v));
  const byName = new Map(drizzleTables.map((t) => [getTableConfig(t).name, getTableConfig(t)]));
  let columnsCompared = 0;

  for (const name of byName.keys()) {
    if (!dbTables.some((t) => t.name === name)) problems.push(`таблица ${name}: есть в Drizzle, нет в БД`);
  }
  for (const db of dbTables) {
    const cfg = byName.get(db.name);
    if (!cfg) {
      problems.push(`таблица ${db.name}: есть в БД, нет в Drizzle`);
      continue;
    }
    const cols = new Map(cfg.columns.map((c) => [c.name, c]));
    for (const c of cfg.columns) {
      if (!db.columns.some((x) => x.name === c.name)) problems.push(`${db.name}.${c.name}: есть в Drizzle, нет в БД`);
    }
    for (const dc of db.columns) {
      const c = cols.get(dc.name);
      if (!c) {
        problems.push(`${db.name}.${dc.name}: есть в БД, нет в Drizzle`);
        continue;
      }
      columnsCompared++;
      const where = `${db.name}.${dc.name}`;
      const dType = normalizeType(c.getSQLType());
      const bType = normalizeType(dc.type);
      if (dType !== bType) problems.push(`${where}: тип Drizzle ${dType} ≠ БД ${bType}`);
      if (c.notNull !== dc.notNull) problems.push(`${where}: notNull Drizzle ${c.notNull} ≠ БД ${dc.notNull}`);
      const dbHasDefault = dc.default !== null || dc.identity !== '';
      if (c.hasDefault !== dbHasDefault && dc.generated === null) {
        problems.push(`${where}: DEFAULT Drizzle ${c.hasDefault} ≠ БД ${dbHasDefault}`);
      }
      // generatedAlwaysAs(sql) → c.generated; identity → c.generatedIdentity
      const genIsExpr = c.generated !== undefined;
      if ((dc.generated !== null) !== genIsExpr) {
        problems.push(`${where}: GENERATED Drizzle ${genIsExpr} ≠ БД ${dc.generated !== null}`);
      }
      const identity = (c as unknown as { generatedIdentity?: { type: 'always' | 'byDefault' } }).generatedIdentity;
      const dIdentity = identity === undefined ? '' : identity.type === 'always' ? 'a' : 'd';
      if (dIdentity !== dc.identity) problems.push(`${where}: IDENTITY Drizzle '${dIdentity}' ≠ БД '${dc.identity}'`);
    }
    const dbPk = db.primaryKey?.columns ?? [];
    const drizzlePk =
      cfg.primaryKeys.length > 0
        ? cfg.primaryKeys[0].columns.map((c) => c.name)
        : cfg.columns.filter((c) => c.primary).map((c) => c.name);
    if (dbPk.join(',') !== drizzlePk.join(',')) {
      problems.push(`${db.name}: PK Drizzle (${drizzlePk.join(',')}) ≠ БД (${dbPk.join(',')})`);
    }
  }

  const enumByName = new Map(drizzleEnums.map((e) => [e.enumName, e.enumValues]));
  for (const e of dbEnums) {
    const values = enumByName.get(e.name);
    if (!values) problems.push(`enum ${e.name}: есть в БД, нет в Drizzle`);
    else if (values.join(',') !== e.values.join(',')) problems.push(`enum ${e.name}: значения/порядок различаются`);
  }
  for (const name of enumByName.keys()) {
    if (!dbEnums.some((e) => e.name === name)) problems.push(`enum ${name}: есть в Drizzle, нет в БД`);
  }
  return { problems, tablesCompared: byName.size, columnsCompared, enumsCompared: dbEnums.length };
}
