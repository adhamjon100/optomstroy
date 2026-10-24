import type { CatalogColumn, CatalogEnum, CatalogTable } from '../support/catalog.js';
import type { ExpectedTable } from '../support/paths.js';

/**
 * Генерация Drizzle-схемы (src/db/schema/*.ts) из каталога PostgreSQL после применения migrations/*.sql.
 * Генерируются: pgEnum-ы, таблицы, столбцы (тип, NOT NULL, DEFAULT, GENERATED, PK). Внешние ключи, UNIQUE,
 * CHECK, индексы и триггеры остаются только в SQL (источник истины — миграции): Drizzle-схема — типизированная
 * проекция для запросов, а не источник DDL (drizzle-kit generate не используется). Файлы — по доменам 07 §5
 * (A auth, B catalog, C customers, D sales, E sync) без импортов между ними — циклов нет (madge).
 */
export const GENERATED_BANNER = [
  '// СГЕНЕРИРОВАНО test/db/codegen/gen-drizzle-schema.ts из каталога PostgreSQL 17 после migrations/*.sql',
  '// (RM-C-006) — вручную не править: новая миграция → `npx tsx test/db/codegen/gen-drizzle-schema.ts`.',
  '// Сверка с БД — test/db/migrate-seed.db-spec.ts («Drizzle-схема совпадает с БД»).',
].join('\n');

const DOMAIN_TITLES: Record<string, string> = {
  auth: 'Домен auth (07 §5.A)',
  catalog: 'Домен catalog (07 §5.B)',
  customers: 'Домен customers/finance (07 §5.C)',
  sales: 'Домен sales (07 §5.D)',
  sync: 'Домен sync/audit/служебные (07 §5.E)',
};

export function camel(name: string): string {
  return name.replace(/_([a-z0-9])/g, (_, c: string) => c.toUpperCase());
}

export function enumVar(name: string): string {
  return `${camel(name)}Enum`;
}

function tsString(s: string): string {
  return `'${s.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
}

function sqlTemplate(expr: string): string {
  return 'sql`' + expr.replace(/\\/g, '\\\\').replace(/`/g, '\\`').replace(/\$\{/g, '\\${') + '`';
}

interface Imports {
  pg: Set<string>;
  custom: Set<string>;
  enums: Set<string>;
  sql: boolean;
}

function builderFor(c: CatalogColumn, imports: Imports): string {
  const n = tsString(c.name);
  const mods = /\(([^)]*)\)/.exec(c.type.replace(/\[\]$/, ''))?.[1];
  if (c.baseTypType === 'e') {
    imports.enums.add(enumVar(c.baseType));
    return `${enumVar(c.baseType)}(${n})`;
  }
  const use = (fn: string, args = ''): string => {
    imports.pg.add(fn);
    return `${fn}(${n}${args})`;
  };
  switch (c.baseType) {
    case 'uuid':
      return use('uuid');
    case 'text':
      return use('text');
    case 'varchar':
      return use('varchar', mods ? `, { length: ${mods} }` : '');
    case 'bpchar':
      return use('char', mods ? `, { length: ${mods} }` : '');
    case 'int2':
      return use('smallint');
    case 'int4':
      return use('integer');
    case 'int8':
      return use('bigint', ", { mode: 'number' }");
    case 'float4':
      return use('real');
    case 'float8':
      return use('doublePrecision');
    case 'numeric': {
      if (!mods) return use('numeric');
      const [p, s] = mods.split(',').map((x) => x.trim());
      return use('numeric', `, { precision: ${p}, scale: ${s ?? 0} }`);
    }
    case 'bool':
      return use('boolean');
    case 'timestamptz':
      return use('timestamp', `, { withTimezone: true${mods ? `, precision: ${mods}` : ''} }`);
    case 'timestamp':
      return use('timestamp', mods ? `, { precision: ${mods} }` : '');
    case 'date':
      return use('date', ", { mode: 'string' }");
    case 'time':
      return use('time');
    case 'interval':
      return use('interval');
    case 'json':
      return use('json');
    case 'jsonb':
      return use('jsonb');
    case 'inet':
      return use('inet');
    case 'point':
      return use('point', ", { mode: 'xy' }");
    case 'bytea':
      imports.custom.add('bytea');
      return `bytea(${n})`;
    case 'tsvector':
      imports.custom.add('tsvector');
      return `tsvector(${n})`;
    default:
      throw new Error(`drizzle-codegen: тип ${c.type} (${c.baseType}) столбца ${c.name} не поддержан`);
  }
}

function columnCode(t: CatalogTable, c: CatalogColumn, imports: Imports): string {
  let code = builderFor(c, imports);
  if (c.isArray) code += '.array()';
  const singlePk = t.primaryKey?.columns.length === 1 && t.primaryKey.columns[0] === c.name;
  if (singlePk) code += '.primaryKey()';
  else if (c.notNull) code += '.notNull()';
  if (c.identity === 'a') code += '.generatedAlwaysAsIdentity()';
  if (c.identity === 'd') code += '.generatedByDefaultAsIdentity()';
  if (c.default !== null && c.identity === '') {
    imports.sql = true;
    code += `.default(${sqlTemplate(c.default)})`;
  }
  if (c.generated !== null) {
    imports.sql = true;
    code += `.generatedAlwaysAs(${sqlTemplate(c.generated)})`;
  }
  return `  ${camel(c.name)}: ${code},`;
}

function tableCode(t: CatalogTable, meta: ExpectedTable | undefined, imports: Imports): string {
  imports.pg.add('pgTable');
  const lines = [`/** ${t.name}${meta ? ` — 07 §${meta.card}` : ''} */`];
  lines.push(`export const ${camel(t.name)} = pgTable(`);
  lines.push(`  ${tsString(t.name)},`);
  lines.push('  {');
  for (const c of t.columns) lines.push(`  ${columnCode(t, c, imports)}`);
  lines.push('  },');
  if (t.primaryKey && t.primaryKey.columns.length > 1) {
    imports.pg.add('primaryKey');
    const cols = t.primaryKey.columns.map((c) => `t.${camel(c)}`).join(', ');
    lines.push(`  (t) => [primaryKey({ name: ${tsString(t.primaryKey.name)}, columns: [${cols}] })],`);
  }
  lines.push(');');
  return lines.join('\n');
}

export interface GeneratedFile {
  readonly file: string;
  readonly content: string;
}

export function generateSchema(
  tables: readonly CatalogTable[],
  enums: readonly CatalogEnum[],
  expected: readonly ExpectedTable[],
): GeneratedFile[] {
  const meta = new Map(expected.map((e) => [e.name, e]));
  const files: GeneratedFile[] = [];

  // enums.ts
  const enumLines = [GENERATED_BANNER, '', "import { pgEnum } from 'drizzle-orm/pg-core';", ''];
  enumLines.push('/** Enum-типы БД (07 §6.1; имена и порядок значений — как в migrations/0001_init.sql). */');
  for (const e of enums) {
    enumLines.push(
      `export const ${enumVar(e.name)} = pgEnum(${tsString(e.name)}, [${e.values.map(tsString).join(', ')}]);`,
    );
  }
  files.push({ file: 'enums.ts', content: enumLines.join('\n') + '\n' });

  const domains = [...new Set(expected.map((e) => e.domain))];
  const unknown = tables.filter((t) => !meta.has(t.name)).map((t) => t.name);
  if (unknown.length > 0)
    throw new Error(`drizzle-codegen: таблицы вне scripts/check_tables.sql: ${unknown.join(', ')}`);

  for (const domain of domains) {
    // порядок — как в 07 §5 (scripts/check_tables.sql)
    const order = expected.map((e) => e.name);
    const domainTables = tables
      .filter((t) => meta.get(t.name)?.domain === domain)
      .sort((a, b) => order.indexOf(a.name) - order.indexOf(b.name));
    if (domainTables.length === 0) continue;
    const imports: Imports = { pg: new Set(), custom: new Set(), enums: new Set(), sql: false };
    const body = domainTables.map((t) => tableCode(t, meta.get(t.name), imports)).join('\n\n');
    const head = [GENERATED_BANNER, '', `// ${DOMAIN_TITLES[domain] ?? domain}`, ''];
    if (imports.sql) head.push("import { sql } from 'drizzle-orm';");
    head.push(`import { ${[...imports.pg].sort().join(', ')} } from 'drizzle-orm/pg-core';`);
    if (imports.custom.size > 0) head.push(`import { ${[...imports.custom].sort().join(', ')} } from './types.js';`);
    if (imports.enums.size > 0) head.push(`import { ${[...imports.enums].sort().join(', ')} } from './enums.js';`);
    files.push({ file: `${domain}.ts`, content: `${head.join('\n')}\n\n${body}\n` });
  }

  const index = [GENERATED_BANNER, '', '/** Drizzle-схема «Оптомстрой POS»: все таблицы и enum-ы БД (RM-C-006). */'];
  index.push("export * from './enums.js';");
  for (const d of domains) index.push(`export * from './${d}.js';`);
  files.push({ file: 'index.ts', content: index.join('\n') + '\n' });
  return files;
}
