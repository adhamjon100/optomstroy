import type pg from 'pg';

/**
 * Чтение каталога PostgreSQL для проверок RM-C-006: сверка Drizzle-схемы с БД, генерация Drizzle-схемы,
 * «отпечаток» схемы (повторный migrate — 0 изменений) и выгрузка DDL (docs/erd/schema_v1.sql).
 * Объекты расширений (pg_depend deptype 'e') исключаются.
 */
export interface CatalogColumn {
  readonly name: string;
  readonly num: number;
  /** format_type(atttypid, atttypmod), например `numeric(14,2)`, `text[]`, `role_code`. */
  readonly type: string;
  /** Имя базового типа (для массивов — тип элемента) и его typtype: b — базовый, e — enum. */
  readonly baseType: string;
  readonly baseTypType: string;
  readonly isArray: boolean;
  readonly notNull: boolean;
  /** Выражение DEFAULT (pg_get_expr) или null; для generated-столбцов — null. */
  readonly default: string | null;
  /** Выражение GENERATED ALWAYS AS (…) STORED или null. */
  readonly generated: string | null;
  /** '' | 'a' (ALWAYS) | 'd' (BY DEFAULT). */
  readonly identity: string;
}

export interface CatalogTable {
  readonly name: string;
  readonly columns: readonly CatalogColumn[];
  readonly primaryKey: { readonly name: string; readonly columns: readonly string[] } | null;
}

export interface CatalogEnum {
  readonly name: string;
  readonly values: readonly string[];
}

export async function readTables(client: pg.ClientBase, schema = 'public'): Promise<CatalogTable[]> {
  const cols = await client.query<{
    table_name: string;
    name: string;
    num: number;
    type: string;
    base_type: string;
    base_typtype: string;
    is_array: boolean;
    not_null: boolean;
    def: string | null;
    generated: string;
    identity: string;
  }>(
    `SELECT c.relname AS table_name, a.attname AS name, a.attnum::int AS num,
            format_type(a.atttypid, a.atttypmod) AS type,
            bt.typname AS base_type, bt.typtype::text AS base_typtype,
            (t.typelem <> 0 AND t.typcategory = 'A') AS is_array,
            a.attnotnull AS not_null,
            pg_get_expr(d.adbin, d.adrelid) AS def,
            a.attgenerated::text AS generated, a.attidentity::text AS identity
       FROM pg_class c
       JOIN pg_namespace n ON n.oid = c.relnamespace
       JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
       JOIN pg_type t ON t.oid = a.atttypid
       JOIN pg_type bt ON bt.oid = CASE WHEN t.typelem <> 0 AND t.typcategory = 'A' THEN t.typelem ELSE t.oid END
       LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
      WHERE n.nspname = $1 AND c.relkind IN ('r', 'p')
      ORDER BY c.relname, a.attnum`,
    [schema],
  );
  const pks = await client.query<{ table_name: string; name: string; columns: string[] }>(
    `SELECT c.relname AS table_name, k.conname AS name,
            array_agg(a.attname ORDER BY u.ord)::text[] AS columns
       FROM pg_constraint k
       JOIN pg_class c ON c.oid = k.conrelid
       JOIN pg_namespace n ON n.oid = c.relnamespace
       CROSS JOIN LATERAL unnest(k.conkey) WITH ORDINALITY AS u(attnum, ord)
       JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = u.attnum
      WHERE n.nspname = $1 AND k.contype = 'p'
      GROUP BY c.relname, k.conname`,
    [schema],
  );
  const pkByTable = new Map(pks.rows.map((r) => [r.table_name, { name: r.name, columns: r.columns }]));
  const tables = new Map<string, CatalogColumn[]>();
  for (const r of cols.rows) {
    const list = tables.get(r.table_name) ?? [];
    list.push({
      name: r.name,
      num: r.num,
      type: r.type,
      baseType: r.base_type,
      baseTypType: r.base_typtype,
      isArray: r.is_array,
      notNull: r.not_null,
      default: r.generated === 's' ? null : r.def,
      generated: r.generated === 's' ? r.def : null,
      identity: r.identity,
    });
    tables.set(r.table_name, list);
  }
  return [...tables.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([name, columns]) => ({ name, columns, primaryKey: pkByTable.get(name) ?? null }));
}

export async function readEnums(client: pg.ClientBase, schema = 'public'): Promise<CatalogEnum[]> {
  const r = await client.query<{ name: string; values: string[] }>(
    `SELECT t.typname AS name, array_agg(e.enumlabel ORDER BY e.enumsortorder)::text[] AS values
       FROM pg_type t
       JOIN pg_namespace n ON n.oid = t.typnamespace
       JOIN pg_enum e ON e.enumtypid = t.oid
      WHERE n.nspname = $1
      GROUP BY t.typname
      ORDER BY t.typname`,
    [schema],
  );
  return r.rows;
}

/**
 * Отпечаток схемы `public` (+ журнал мигратора): таблицы, столбцы, ограничения, индексы, триггеры, функции,
 * enum-ы, последовательности, права. Два одинаковых отпечатка — схемы совпадают (0 изменений).
 */
export async function schemaFingerprint(
  client: pg.ClientBase,
  schemas: readonly string[] = ['public'],
): Promise<string[]> {
  const q = async (sql: string): Promise<string[]> =>
    (await client.query<{ v: string }>(sql, [schemas])).rows.map((r) => r.v);
  // последовательно: один клиент не выполняет запросы параллельно (pg@9)
  const queries: (() => Promise<string[]>)[] = [
    () =>
      q(`SELECT 'relation ' || n.nspname || '.' || c.relname || ' ' || c.relkind::text || ' owner=' || pg_get_userbyid(c.relowner)
              || ' acl=' || coalesce((SELECT string_agg(pg_get_userbyid(x.grantee) || ':' || x.privilege_type, ','
                                                        ORDER BY pg_get_userbyid(x.grantee), x.privilege_type)
                                        FROM aclexplode(c.relacl) x), '<default>') AS v
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = ANY($1) AND c.relkind IN ('r','p','v','m','S','f')
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')`),
    () =>
      q(`SELECT 'schema ' || n.nspname || ' owner=' || pg_get_userbyid(n.nspowner) || ' acl='
              || coalesce((SELECT string_agg(g.e, ',' ORDER BY g.e)
                             FROM (SELECT CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END
                                          || ':' || x.privilege_type AS e
                                     FROM aclexplode(n.nspacl) x) g), '<default>') AS v
         FROM pg_namespace n WHERE n.nspname = ANY($1)`),
    () =>
      q(`SELECT 'column ' || c.relname || '.' || a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
              || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
              || coalesce(' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid), '') || ' gen=' || a.attgenerated::text
              || ' id=' || a.attidentity::text || ' #' || a.attnum AS v
         FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
         LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
        WHERE n.nspname = ANY($1) AND c.relkind IN ('r','p') AND a.attnum > 0 AND NOT a.attisdropped`),
    () =>
      q(`SELECT 'constraint ' || c.relname || '.' || k.conname || ' ' || pg_get_constraintdef(k.oid, true) AS v
         FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = ANY($1)`),
    () =>
      q(`SELECT 'index ' || pg_get_indexdef(i.indexrelid) AS v
         FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = ANY($1)`),
    () =>
      q(`SELECT 'trigger ' || pg_get_triggerdef(t.oid, true) || ' enabled=' || t.tgenabled::text AS v
         FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = ANY($1) AND NOT t.tgisinternal`),
    () =>
      q(`SELECT 'function ' || p.oid::regprocedure::text || ' ' || md5(pg_get_functiondef(p.oid)) AS v
         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = ANY($1) AND p.prokind IN ('f','p')
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')`),
    () =>
      q(`SELECT 'enum ' || t.typname || ' ' || string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder) AS v
         FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace JOIN pg_enum e ON e.enumtypid = t.oid
        WHERE n.nspname = ANY($1) GROUP BY t.typname`),
    () =>
      q(`SELECT 'sequence ' || schemaname || '.' || sequencename || ' ' || data_type::text || ' ' || start_value
              || ' ' || increment_by || ' ' || min_value || ' ' || max_value || ' ' || cache_size || ' ' || cycle AS v
         FROM pg_sequences WHERE schemaname = ANY($1)`),
    () =>
      q(`SELECT 'tsconfig ' || c.cfgname || ' ' || string_agg(m.maptokentype || ':' || m.mapseqno || ':' || d.dictname, ','
              ORDER BY m.maptokentype, m.mapseqno) AS v
         FROM pg_ts_config c JOIN pg_namespace n ON n.oid = c.cfgnamespace
         JOIN pg_ts_config_map m ON m.mapcfg = c.oid JOIN pg_ts_dict d ON d.oid = m.mapdict
        WHERE n.nspname = ANY($1) GROUP BY c.cfgname`),
    () =>
      q(`SELECT 'defacl ' || pg_get_userbyid(a.defaclrole) || ' ' || coalesce(n.nspname, '') || ' ' || a.defaclobjtype::text
              || ' ' || a.defaclacl::text AS v
         FROM pg_default_acl a LEFT JOIN pg_namespace n ON n.oid = a.defaclnamespace
        WHERE n.nspname = ANY($1) OR n.nspname IS NULL`),
    () =>
      q(
        `SELECT 'extension ' || e.extname || ' ' || e.extversion AS v FROM pg_extension e WHERE $1::text[] IS NOT NULL`,
      ),
  ];
  const parts: string[][] = [];
  for (const fn of queries) parts.push(await fn());
  return parts.flat().sort();
}
