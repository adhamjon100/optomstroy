import type pg from 'pg';

/**
 * Выгрузка DDL схемы из каталога PostgreSQL — замена `pg_dump --schema-only` (RM-C-006 п. 5): в пакете
 * embedded-postgres нет клиента pg_dump, Docker на машине нет (B-KI-02). Порядок объектов — как у pg_dump
 * (зависимости): расширения → схемы → enum-ы → конфигурации FTS → последовательности → функции без
 * зависимости от таблиц → таблицы → функции с типом-строкой таблицы → OWNED BY → PK/UNIQUE/CHECK → индексы →
 * FK → триггеры → права → права по умолчанию. Вывод детерминирован (сортировка по имени), без данных.
 * Корректность проверяет test/db/migrate-seed.db-spec.ts: DDL применяется к пустой БД и даёт тот же
 * отпечаток схемы, что migrations/*.sql.
 */
export interface DumpOptions {
  readonly schemas: readonly string[];
  readonly header: readonly string[];
}

type Row = Record<string, unknown>;

async function rows<T extends Row>(client: pg.ClientBase, sql: string, params: unknown[] = []): Promise<T[]> {
  return (await client.query<T>(sql, params)).rows;
}

export async function dumpSchema(client: pg.ClientBase, options: DumpOptions): Promise<string> {
  const schemas = [...options.schemas];
  const out: string[] = [...options.header.map((l) => `-- ${l}`.trimEnd()), ''];
  const section = (title: string) => out.push('', `-- ${'-'.repeat(100)}`, `-- ${title}`, `-- ${'-'.repeat(100)}`);

  out.push('SET check_function_bodies = false;', 'SET client_min_messages = warning;');

  section('Расширения');
  for (const r of await rows<{ extname: string; nspname: string; extversion: string }>(
    client,
    `SELECT e.extname, n.nspname, e.extversion FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname <> 'plpgsql' ORDER BY e.extname`,
  )) {
    out.push(`CREATE EXTENSION IF NOT EXISTS ${r.extname} WITH SCHEMA ${r.nspname}; -- версия ${r.extversion}`);
  }

  section('Роли БД (кластерные объекты; создаются migrations/0001_init.sql или эксплуатацией, 16 §4.3)');
  for (const r of await rows<{ rolname: string; rolcanlogin: boolean }>(
    client,
    `SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname LIKE 'pos\\_%' ORDER BY rolname`,
  )) {
    out.push(`-- ROLE ${r.rolname}${r.rolcanlogin ? ' LOGIN' : ''}`);
  }

  section('Схемы');
  for (const r of await rows<{ nspname: string }>(
    client,
    `SELECT nspname FROM pg_namespace WHERE nspname = ANY($1) AND nspname <> 'public' ORDER BY nspname`,
    [schemas],
  )) {
    out.push(`CREATE SCHEMA ${r.nspname};`);
  }

  section('Enum-типы');
  for (const r of await rows<{ name: string; vals: string }>(
    client,
    `SELECT quote_ident(n.nspname) || '.' || quote_ident(t.typname) AS name,
            string_agg(quote_literal(e.enumlabel), ', ' ORDER BY e.enumsortorder) AS vals
       FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace JOIN pg_enum e ON e.enumtypid = t.oid
      WHERE n.nspname = ANY($1) GROUP BY n.nspname, t.typname ORDER BY n.nspname, t.typname`,
    [schemas],
  )) {
    out.push(`CREATE TYPE ${r.name} AS ENUM (${r.vals});`);
  }

  section('Конфигурации полнотекстового поиска');
  for (const cfg of await rows<{ oid: number; name: string; parser: string }>(
    client,
    `SELECT c.oid::int AS oid, quote_ident(n.nspname) || '.' || quote_ident(c.cfgname) AS name,
            quote_ident(pn.nspname) || '.' || quote_ident(p.prsname) AS parser
       FROM pg_ts_config c JOIN pg_namespace n ON n.oid = c.cfgnamespace
       JOIN pg_ts_parser p ON p.oid = c.cfgparser JOIN pg_namespace pn ON pn.oid = p.prsnamespace
      WHERE n.nspname = ANY($1) ORDER BY 2`,
    [schemas],
  )) {
    out.push(`CREATE TEXT SEARCH CONFIGURATION ${cfg.name} (PARSER = ${cfg.parser});`);
    const maps = await rows<{ dicts: string; tokens: string }>(
      client,
      `SELECT dicts, string_agg(alias, ', ' ORDER BY alias) AS tokens FROM (
         SELECT tt.alias, string_agg(quote_ident(dn.nspname) || '.' || quote_ident(d.dictname), ', ' ORDER BY m.mapseqno) AS dicts
           FROM pg_ts_config_map m
           JOIN pg_ts_config c ON c.oid = m.mapcfg
           JOIN ts_token_type(c.cfgparser) tt ON tt.tokid = m.maptokentype
           JOIN pg_ts_dict d ON d.oid = m.mapdict JOIN pg_namespace dn ON dn.oid = d.dictnamespace
          WHERE m.mapcfg = $1 GROUP BY tt.alias) s
        GROUP BY dicts ORDER BY tokens`,
      [cfg.oid],
    );
    for (const m of maps)
      out.push(`ALTER TEXT SEARCH CONFIGURATION ${cfg.name} ADD MAPPING FOR ${m.tokens} WITH ${m.dicts};`);
  }

  section('Последовательности (кроме identity)');
  const seqs = await rows<{ name: string; def: string; owned: string | null }>(
    client,
    `SELECT quote_ident(s.schemaname) || '.' || quote_ident(s.sequencename) AS name,
            'AS ' || s.data_type::text || ' START WITH ' || s.start_value || ' INCREMENT BY ' || s.increment_by
              || ' MINVALUE ' || s.min_value || ' MAXVALUE ' || s.max_value || ' CACHE ' || s.cache_size
              || CASE WHEN s.cycle THEN ' CYCLE' ELSE '' END AS def,
            (SELECT quote_ident(tn.nspname) || '.' || quote_ident(t.relname) || '.' || quote_ident(a.attname)
               FROM pg_depend d JOIN pg_class t ON t.oid = d.refobjid JOIN pg_namespace tn ON tn.oid = t.relnamespace
               JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
              WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'a') AS owned
       FROM pg_sequences s
       JOIN pg_namespace n ON n.nspname = s.schemaname
       JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = s.sequencename
      WHERE s.schemaname = ANY($1)
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'i')
      ORDER BY 1`,
    [schemas],
  );
  for (const s of seqs) out.push(`CREATE SEQUENCE ${s.name} ${s.def};`);

  const functions = await rows<{ def: string; late: boolean; name: string }>(
    client,
    `SELECT pg_get_functiondef(p.oid) AS def, p.oid::regprocedure::text AS name,
            EXISTS (SELECT 1 FROM pg_type t WHERE t.typrelid <> 0
                     AND (t.oid = p.prorettype OR t.oid = ANY (p.proargtypes::oid[]))) AS late
       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = ANY($1) AND p.prokind IN ('f','p')
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
      ORDER BY 2`,
    [schemas],
  );
  section('Функции (не зависящие от типов-строк таблиц)');
  for (const f of functions.filter((x) => !x.late)) out.push(`${f.def.trimEnd()};`, '');

  section('Таблицы');
  const tables = await rows<{ oid: number; name: string }>(
    client,
    `SELECT c.oid::int AS oid, quote_ident(n.nspname) || '.' || quote_ident(c.relname) AS name
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = ANY($1) AND c.relkind IN ('r','p') ORDER BY n.nspname, c.relname`,
    [schemas],
  );
  for (const t of tables) {
    const cols = await rows<{ line: string }>(
      client,
      `SELECT '    ' || quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod)
              || CASE WHEN a.attcollation <> ty.typcollation AND a.attcollation <> 0
                      THEN ' COLLATE ' || quote_ident(co.collname) ELSE '' END
              || CASE WHEN a.attgenerated = 's' THEN ' GENERATED ALWAYS AS (' || pg_get_expr(d.adbin, d.adrelid) || ') STORED'
                      ELSE '' END
              || CASE a.attidentity
                   WHEN 'a' THEN ' GENERATED ALWAYS AS IDENTITY (SEQUENCE NAME ' || pg_get_serial_sequence(c.oid::regclass::text, a.attname) || ' ' || sq.opts || ')'
                   WHEN 'd' THEN ' GENERATED BY DEFAULT AS IDENTITY (SEQUENCE NAME ' || pg_get_serial_sequence(c.oid::regclass::text, a.attname) || ' ' || sq.opts || ')'
                   ELSE '' END
              || CASE WHEN a.attgenerated = '' AND d.adbin IS NOT NULL THEN ' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid) ELSE '' END
              || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END AS line
         FROM pg_attribute a
         JOIN pg_class c ON c.oid = a.attrelid
         JOIN pg_type ty ON ty.oid = a.atttypid
         LEFT JOIN pg_collation co ON co.oid = a.attcollation
         LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
         LEFT JOIN LATERAL (
           SELECT 'START WITH ' || s.seqstart || ' INCREMENT BY ' || s.seqincrement || ' MINVALUE ' || s.seqmin
                  || ' MAXVALUE ' || s.seqmax || ' CACHE ' || s.seqcache || CASE WHEN s.seqcycle THEN ' CYCLE' ELSE '' END AS opts
             FROM pg_sequence s
            WHERE a.attidentity <> '' AND s.seqrelid = pg_get_serial_sequence(c.oid::regclass::text, a.attname)::regclass
         ) sq ON true
        WHERE a.attrelid = $1 AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum`,
      [t.oid],
    );
    out.push(`CREATE TABLE ${t.name} (`, cols.map((c) => c.line).join(',\n'), ');', '');
  }

  section('Функции с типом-строкой таблицы в сигнатуре');
  for (const f of functions.filter((x) => x.late)) out.push(`${f.def.trimEnd()};`, '');

  // Представления и материализованные представления (0004_search: словарь `search_words`, EQ-SRCH-14) — после
  // таблиц и функций, от которых зависят; данные matview не выгружаются (WITH NO DATA, как pg_dump --schema-only).
  const views = await rows<{ name: string; kind: string; def: string }>(
    client,
    `SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname) AS name, c.relkind::text AS kind,
            pg_get_viewdef(c.oid, true) AS def
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = ANY($1) AND c.relkind IN ('v','m')
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
      ORDER BY n.nspname, c.relname`,
    [schemas],
  );
  if (views.length > 0) {
    section('Представления и материализованные представления');
    for (const v of views) {
      const body = v.def.trim().replace(/;$/, '');
      out.push(
        v.kind === 'm'
          ? `CREATE MATERIALIZED VIEW ${v.name} AS
${body}
WITH NO DATA;`
          : `CREATE VIEW ${v.name} AS
${body};`,
        '',
      );
    }
  }

  const owned = seqs.filter((s) => s.owned !== null);
  if (owned.length > 0) {
    section('Владение последовательностями');
    for (const s of owned) out.push(`ALTER SEQUENCE ${s.name} OWNED BY ${s.owned};`);
  }

  const constraints = async (where: string) =>
    rows<{ tbl: string; name: string; def: string }>(
      client,
      `SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname) AS tbl, quote_ident(k.conname) AS name,
              pg_get_constraintdef(k.oid) AS def
         FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = ANY($1) AND ${where}
        ORDER BY n.nspname, c.relname, CASE k.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'x' THEN 2 ELSE 3 END, k.conname`,
      [schemas],
    );
  section('Первичные ключи, UNIQUE, EXCLUDE, CHECK');
  for (const k of await constraints(`k.contype IN ('p','u','x','c')`)) {
    out.push(`ALTER TABLE ONLY ${k.tbl} ADD CONSTRAINT ${k.name} ${k.def};`);
  }

  section('Индексы');
  for (const r of await rows<{ def: string }>(
    client,
    `SELECT pg_get_indexdef(i.indexrelid) AS def
       FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = ANY($1) AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid AND k.contype IN ('p','u','x'))
      ORDER BY n.nspname, c.relname, ic.relname`,
    [schemas],
  )) {
    out.push(`${r.def};`);
  }

  section('Внешние ключи');
  for (const k of await constraints(`k.contype = 'f'`)) {
    out.push(`ALTER TABLE ONLY ${k.tbl} ADD CONSTRAINT ${k.name} ${k.def};`);
  }

  section('Триггеры');
  for (const r of await rows<{ def: string; tbl: string; name: string; enabled: string }>(
    client,
    `SELECT pg_get_triggerdef(t.oid) AS def, t.tgenabled::text AS enabled, quote_ident(t.tgname) AS name,
            quote_ident(n.nspname) || '.' || quote_ident(c.relname) AS tbl
       FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = ANY($1) AND NOT t.tgisinternal
      ORDER BY n.nspname, c.relname, t.tgname`,
    [schemas],
  )) {
    out.push(`${r.def};`);
    if (r.enabled === 'D') out.push(`ALTER TABLE ${r.tbl} DISABLE TRIGGER ${r.name};`);
  }

  section('Права (GRANT); владелец объектов — роль мигратора');
  for (const r of await rows<{ stmt: string }>(
    client,
    `SELECT 'GRANT ' || string_agg(x.privilege_type, ', ' ORDER BY x.privilege_type) || ' ON SCHEMA '
            || quote_ident(n.nspname) || ' TO ' || quote_ident(pg_get_userbyid(x.grantee)) || ';' AS stmt
       FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) x
      WHERE n.nspname = ANY($1) AND x.grantee <> 0 AND x.grantee <> n.nspowner
      GROUP BY n.nspname, x.grantee ORDER BY 1`,
    [schemas],
  )) {
    out.push(r.stmt);
  }
  for (const r of await rows<{ stmt: string }>(
    client,
    `SELECT 'GRANT ' || string_agg(x.privilege_type, ', ' ORDER BY x.privilege_type)
            || CASE WHEN c.relkind = 'S' THEN ' ON SEQUENCE ' ELSE ' ON TABLE ' END
            || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
            || ' TO ' || quote_ident(pg_get_userbyid(x.grantee)) || ';' AS stmt
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN LATERAL aclexplode(c.relacl) x
      WHERE n.nspname = ANY($1) AND c.relkind IN ('r','p','S','v','m') AND x.grantee <> c.relowner
      GROUP BY n.nspname, c.relname, c.relkind, x.grantee ORDER BY n.nspname, c.relname, 1`,
    [schemas],
  )) {
    out.push(r.stmt);
  }

  section('Права по умолчанию для будущих объектов');
  for (const r of await rows<{ stmt: string }>(
    client,
    `SELECT 'ALTER DEFAULT PRIVILEGES FOR ROLE ' || quote_ident(pg_get_userbyid(a.defaclrole))
            || coalesce(' IN SCHEMA ' || quote_ident(n.nspname), '') || ' GRANT '
            || string_agg(x.privilege_type, ', ' ORDER BY x.privilege_type)
            || CASE a.defaclobjtype WHEN 'r' THEN ' ON TABLES' WHEN 'S' THEN ' ON SEQUENCES' WHEN 'f' THEN ' ON FUNCTIONS'
                                    WHEN 'T' THEN ' ON TYPES' ELSE ' ON SCHEMAS' END
            || ' TO ' || quote_ident(pg_get_userbyid(x.grantee)) || ';' AS stmt
       FROM pg_default_acl a LEFT JOIN pg_namespace n ON n.oid = a.defaclnamespace
       CROSS JOIN LATERAL aclexplode(a.defaclacl) x
      WHERE n.nspname = ANY($1) AND x.grantee <> 0
      GROUP BY a.defaclrole, n.nspname, a.defaclobjtype, x.grantee ORDER BY 1`,
    [schemas],
  )) {
    out.push(r.stmt);
  }
  return `${out.join('\n')}\n`;
}
