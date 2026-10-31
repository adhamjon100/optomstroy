// Снимок БД веб-демо в формате S2 (WP-B4; plan §3.5 «Формат снимка»): построчная выгрузка таблиц командой
// `COPY … TO '/dev/blob'` в один файл data.copy со смещениями в manifest.json, плюс значения последовательностей.
// Восстановление в браузере: настоящие миграции → `SET LOCAL session_replication_role = replica` → DELETE строк, которые
// вставили сами миграции (manifest.migrationRows; без него — TRUNCATE всех таблиц снимка) → `COPY … FROM '/dev/blob'` → setval → перенос времени на момент восстановления → пересчёт хэш-цепочки
// аудита → REFRESH MATERIALIZED VIEW → проверка числа строк → COMMIT.
//
// Модуль без импортов: export* работает при сборке (Node), restoreSnapshot — и в воркере (backend.js), и в Node.
// db — экземпляр PGlite (query(sql, params, {blob}), exec(sql)). sha256 — WebCrypto (crypto.subtle).
//
// Время. Сборка снимка детерминирована (builder-entry.mjs): всё, что идёт от часов БД и JS при сборке, равно T0 или
// T0 + n мкс. Колонки времени, где есть такие значения, перечисляются в manifest.timeColumns и при восстановлении
// сдвигаются на (момент восстановления − T0) прямо в тексте COPY до загрузки (rebaseCopyText: без UPDATE всех строк,
// то есть без второй версии каждой строки и раздувания индексов). Поэтому в снимке нет «запечённой» свежести: каталог синхронизирован, сотрудники
// созданы и аудит записан «в момент восстановления» — как при загрузке каталога конвейером на холодном старте
// (critic [2]). Данные со сроком действия (приглашения, OTP, сессии, устройства, токены, лимиты, ключи
// идемпотентности) в снимок не входят вовсе: их таблицы исключены и при сборке обязаны быть пустыми.

export const SNAPSHOT_FORMAT = 'pos-demo-snapshot/s2-copy-text/1';

/** Схемы данных приложения (pos_meta/pos_dev — журналы мигратора: их пишет настоящий мигратор в браузере). */
export const SNAPSHOT_SCHEMAS = ['public', 'catalog_sync'];

/**
 * Таблицы, которые в снимок не входят, и почему. `mustBeEmpty` — при сборке в них не должно быть строк (иначе сборка
 * останавливается: значит, в снимок попало бы то, что истекает или принадлежит сеансу).
 */
export const EXCLUDED_TABLES = {
  'public.user_invitations': { mustBeEmpty: true, why: 'срок действия 7 дней; приглашение 902 создаёт/продлевает воркер на каждом старте (critic [2])' },
  'public.otp_challenges': { mustBeEmpty: true, why: 'коды OTP истекают' },
  'public.sessions': { mustBeEmpty: true, why: 'сессии и refresh-токены истекают' },
  'public.devices': { mustBeEmpty: true, why: 'устройства появляются при входе' },
  'public.app_pins': { mustBeEmpty: true, why: 'PIN задаёт пользователь при первом входе' },
  'public.token_denylist': { mustBeEmpty: true, why: 'отзыв токенов со сроком' },
  'public.rate_limit_counters': { mustBeEmpty: true, why: 'окна лимитов со сроком' },
  'public.idempotency_keys': { mustBeEmpty: true, why: 'ключи идемпотентности со сроком' },
  'public.integration_tokens': { mustBeEmpty: true, why: 'токены интеграций со сроком' },
  'public.sms_outbox': { mustBeEmpty: true, why: 'очередь SMS (OTP)' },
  'public.payment_webhook_events': { mustBeEmpty: true, why: 'события провайдера оплат' },
  'public.dev_outbox': { mustBeEmpty: true, why: 'журнал dev-outbox (local-stack)' },
};

/** Окно «времени сборки» после T0: значения в нём сдвигаются при восстановлении. */
export const REBASE_WINDOW_SEC = 24 * 3600;

const TIME_TYPES = new Set(['timestamp with time zone', 'timestamp without time zone', 'date']);
/** Формат вывода COPY при выгрузке (и разбора при восстановлении): ISO, UTC, hex. */
const EXPORT_SESSION = `SET TimeZone = 'UTC'; SET DateStyle = 'ISO, YMD'; SET IntervalStyle = 'postgres'; SET bytea_output = 'hex'; SET extra_float_digits = 1; SET client_encoding = 'UTF8';`;
const q = (ident) => `"${String(ident).replace(/"/g, '""')}"`;
const qn = (t) => `${q(t.schema)}.${q(t.name)}`;

async function sha256Hex(bytes) {
  const d = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// ======================================================================== выгрузка (сборка, Node)
/** Таблицы схем снимка: колонки (без генерируемых и удалённых), первичный ключ, число строк. */
export async function listTables(db, schemas = SNAPSHOT_SCHEMAS) {
  const rel = await db.query(
    `SELECT n.nspname AS schema, c.relname AS name, c.oid::int AS oid
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind IN ('r', 'p') AND n.nspname = ANY($1::text[]) AND NOT c.relispartition
      ORDER BY n.nspname, c.relname`,
    [schemas],
  );
  const out = [];
  for (const r of rel.rows) {
    const cols = await db.query(
      `SELECT a.attname AS name, format_type(a.atttypid, a.atttypmod) AS type, a.attgenerated <> '' AS generated
         FROM pg_attribute a WHERE a.attrelid = $1 AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum`,
      [r.oid],
    );
    const pk = await db.query(
      `SELECT a.attname AS name FROM pg_index i JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum, ord) ON true
         JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
        WHERE i.indrelid = $1 AND i.indisprimary ORDER BY k.ord`,
      [r.oid],
    );
    const t = { schema: r.schema, name: r.name, key: `${r.schema}.${r.name}` };
    t.columns = cols.rows.filter((c) => !c.generated).map((c) => c.name);
    t.types = Object.fromEntries(cols.rows.filter((c) => !c.generated).map((c) => [c.name, c.type]));
    t.generated = cols.rows.filter((c) => c.generated).map((c) => c.name);
    t.primaryKey = pk.rows.map((x) => x.name);
    t.rows = Number((await db.query(`SELECT count(*)::bigint AS n FROM ${qn(t)}`)).rows[0].n);
    out.push(t);
  }
  return out;
}

/**
 * Выгрузка S2. o: { t0 (ISO), now (Date — реальное время сборки, для проверки утечек часов), schemas }.
 * → { manifest (без builtAt), data: Uint8Array, report }.
 */
export async function exportSnapshot(db, o) {
  const t0 = new Date(o.t0);
  await db.exec(EXPORT_SESSION);
  const tables = await listTables(db, o.schemas ?? SNAPSHOT_SCHEMAS);
  const problems = [];
  const excluded = [];
  const included = [];
  for (const t of tables) {
    const ex = EXCLUDED_TABLES[t.key];
    if (ex) {
      if (ex.mustBeEmpty && t.rows > 0) problems.push(`${t.key}: ${t.rows} строк, а таблица исключена из снимка (${ex.why})`);
      excluded.push({ table: t.key, rows: t.rows, why: ex.why });
      continue;
    }
    if (t.rows > 0) included.push(t);
  }
  const chunks = [];
  let offset = 0;
  const outTables = [];
  const timeColumns = [];
  for (const t of included) {
    const order = (t.primaryKey.length ? t.primaryKey : t.columns).map((c) => `${q(c)}${t.primaryKey.length ? '' : '::text'}`).join(', ');
    const cols = t.columns.map(q).join(', ');
    const r = await db.query(`COPY (SELECT ${cols} FROM ${qn(t)} ORDER BY ${order}) TO '/dev/blob'`);
    const bytes = new Uint8Array(await r.blob.arrayBuffer());
    chunks.push(bytes);
    // Колонки времени: значения от часов сборки (окно T0) — сдвигаются при восстановлении; от реальных часов — утечка.
    for (const c of t.columns) {
      const type = t.types[c];
      if (!TIME_TYPES.has(type)) continue;
      const isDate = type === 'date';
      const s = await db.query(
        `SELECT count(*) FILTER (WHERE ${q(c)} >= $1::timestamptz AND ${q(c)} < $1::timestamptz + make_interval(secs => $2))::int AS in_window,
                count(*) FILTER (WHERE ${q(c)} >= $3::timestamptz - interval '2 days' AND ${q(c)} < $3::timestamptz + interval '2 days')::int AS near_real,
                min(${q(c)})::text AS min, max(${q(c)})::text AS max
           FROM ${qn(t)}`,
        [t0.toISOString(), REBASE_WINDOW_SEC, (o.now ?? new Date()).toISOString()],
      );
      const x = s.rows[0];
      if (x.near_real > 0) problems.push(`${t.key}.${c} (${type}): ${x.near_real} значений около реального времени сборки (${x.min}…${x.max}) — недетерминированные часы`);
      if (x.in_window > 0) {
        if (isDate) problems.push(`${t.key}.${c}: дата от часов сборки — сдвиг дат не поддержан`);
        else timeColumns.push({ table: t.key, column: c, index: t.columns.indexOf(c), type, rows: x.in_window });
      }
    }
    // UUID — в каноническом формате с версией 1–8 и вариантом 10xx (так их проверяют zod и class-validator pos-api).
    for (const c of t.columns.filter((x) => t.types[x] === 'uuid')) {
      const bad = Number((await db.query(`SELECT count(*)::int AS n FROM ${qn(t)} WHERE ${q(c)} IS NOT NULL AND ${q(c)}::text !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'`)).rows[0].n);
      if (bad) problems.push(`${t.key}.${c}: ${bad} значений UUID не в формате версии 1–8 / варианта 10xx`);
    }
    outTables.push({ schema: t.schema, name: t.name, columns: t.columns, generated: t.generated, primaryKey: t.primaryKey, rows: t.rows, offset, bytes: bytes.length, sha256: await sha256Hex(bytes) });
    offset += bytes.length;
  }
  const data = new Uint8Array(offset);
  {
    let p = 0;
    for (const c of chunks) {
      data.set(c, p);
      p += c.length;
    }
  }
  // Последовательности схем снимка: значение после сборки (в браузере после миграций — setval).
  const seqs = await db.query(
    `SELECT n.nspname AS schema, c.relname AS name FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'S' AND n.nspname = ANY($1::text[]) ORDER BY 1, 2`,
    [o.schemas ?? SNAPSHOT_SCHEMAS],
  );
  const sequences = [];
  for (const s of seqs.rows) {
    const v = (await db.query(`SELECT last_value::text AS v, is_called FROM ${qn(s)}`)).rows[0];
    sequences.push({ schema: s.schema, name: s.name, value: v.v, isCalled: !!v.is_called });
  }
  const mviews = (await db.query(
    `SELECT n.nspname AS schema, c.relname AS name FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'm' AND n.nspname = ANY($1::text[]) ORDER BY 1, 2`,
    [o.schemas ?? SNAPSHOT_SCHEMAS],
  )).rows.map((m) => ({ schema: m.schema, name: m.name }));
  const audit = outTables.find((t) => t.schema === 'public' && t.name === 'audit_logs');
  const manifest = {
    format: SNAPSHOT_FORMAT,
    t0: t0.toISOString(),
    rebaseWindowSec: REBASE_WINDOW_SEC,
    data: { file: 'data.copy', bytes: data.length, sha256: await sha256Hex(data), encoding: 'COPY text, UTF8' },
    tables: outTables,
    sequences,
    timeColumns,
    materializedViews: mviews,
    auditChain: audit ? { table: 'public.audit_logs', rows: audit.rows, recompute: true } : null,
    excluded,
    // Таблицы, заполненные самими миграциями (до seeds): в браузере после миграций их строки удаляются перед COPY.
    migrationRows: (o.migrationRows ?? []).filter((m) => outTables.some((t) => `${t.schema}.${t.name}` === m.table)),
  };
  for (const m of o.migrationRows ?? []) if (!outTables.some((t) => `${t.schema}.${t.name}` === m.table)) problems.push(`${m.table}: строки от миграций (${m.rows}), но таблицы нет в снимке`);
  return { manifest, data, report: { tables: tables.length, included: included.length, excluded, problems, emptyTables: tables.filter((t) => !t.rows && !EXCLUDED_TABLES[t.key]).map((t) => t.key) } };
}

// ======================================================================== восстановление (воркер и Node)
const TS_RE = /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(?:\.(\d{1,6}))?(\+00(?::?00)?)?$/;
const p2 = (n) => String(n).padStart(2, '0');
const NL = '\n';
const TAB = '\t';
const NULL_FIELD = '\\N';

/**
 * Сдвиг времени сборки в тексте COPY (формат выгрузки: ISO, UTC): значения колонок cols ({ index, type }) из окна
 * [T0, T0 + windowSec) → + (nowMs − T0), с точностью до микросекунды. Строки — по переводу строки, поля — по
 * табуляции (в формате text они внутри значений экранированы). → { text, changed }.
 */
export function rebaseCopyText(text, cols, t0Ms, nowMs, windowSec) {
  const shiftUs = (nowMs - t0Ms) * 1000;
  const lo = t0Ms * 1000;
  const hi = lo + windowSec * 1e6;
  let changed = 0;
  const lines = text.split(NL);
  for (let li = 0; li < lines.length; li++) {
    if (!lines[li]) continue;
    const f = lines[li].split(TAB);
    let touched = false;
    for (const c of cols) {
      const v = f[c.index];
      if (v === undefined || v === NULL_FIELD) continue;
      const m = TS_RE.exec(v);
      if (!m) throw new Error(`снимок: значение времени «${v.slice(0, 40)}» не в формате выгрузки`);
      const us = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) * 1000 + Number((m[7] ?? '').padEnd(6, '0') || 0);
      if (us < lo || us >= hi) continue;
      const nu = us + shiftUs;
      const d = new Date(Math.floor(nu / 1000));
      const frac = String(nu % 1e6).padStart(6, '0');
      const tz = c.type === 'timestamp with time zone' ? '+00' : '';
      f[c.index] = `${d.getUTCFullYear()}-${p2(d.getUTCMonth() + 1)}-${p2(d.getUTCDate())} ${p2(d.getUTCHours())}:${p2(d.getUTCMinutes())}:${p2(d.getUTCSeconds())}.${frac}${tz}`;
      touched = true;
    }
    if (touched) {
      lines[li] = f.join(TAB);
      changed++;
    }
  }
  return { text: lines.join(NL), changed };
}

/** Проверить манифест и данные: формат, размер, sha256 файла и каждой таблицы. Бросает Error с причиной. */
export async function verifySnapshot(manifest, data) {
  if (manifest?.format !== SNAPSHOT_FORMAT) throw new Error(`снимок: формат ${manifest?.format}, ожидается ${SNAPSHOT_FORMAT}`);
  if (data.byteLength !== manifest.data.bytes) throw new Error(`снимок: ${data.byteLength} байт, в манифесте ${manifest.data.bytes}`);
  const sha = await sha256Hex(data);
  if (sha !== manifest.data.sha256) throw new Error(`снимок: sha256 ${sha.slice(0, 12)}… ≠ ${String(manifest.data.sha256).slice(0, 12)}…`);
  return sha;
}

/**
 * Восстановить снимок в БД с применёнными настоящими миграциями (схема пустая). Одна транзакция; при ошибке —
 * ROLLBACK, и вызывающий может перейти на запасной путь. → { ms, rows, tables, rebased, audit, steps }.
 * o: { now?: Date (момент восстановления; по умолчанию now() БД) }.
 */
export async function restoreSnapshot(db, manifest, data, o = {}) {
  const t = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
  const t0 = t();
  const steps = {};
  const mark = (k, s) => (steps[k] = Math.round(t() - s));
  const tables = manifest.tables;
  // Время сборки → момент восстановления: в тексте COPY, до загрузки.
  let s = t();
  const nowMs = (o.now ?? new Date()).getTime();
  const byTable = new Map();
  for (const c of manifest.timeColumns) {
    if (!byTable.has(c.table)) byTable.set(c.table, []);
    byTable.get(c.table).push(c);
  }
  const dec = new TextDecoder('utf-8', { fatal: true });
  const enc = new TextEncoder();
  let rebased = 0;
  const payload = new Map();
  for (const tb of tables) {
    const slice = data.subarray(tb.offset, tb.offset + tb.bytes);
    const cols = byTable.get(`${tb.schema}.${tb.name}`);
    if (!cols) {
      payload.set(tb, slice);
      continue;
    }
    const r = rebaseCopyText(dec.decode(slice), cols, Date.parse(manifest.t0), nowMs, Number(manifest.rebaseWindowSec));
    rebased += r.changed;
    payload.set(tb, enc.encode(r.text));
  }
  mark('rebase', s);
  await db.query('BEGIN');
  try {
    await db.query(`SET LOCAL session_replication_role = replica`);
    s = t();
    // Таблицы, которые заполнили миграции (роли, права, аудит…): строки снимка — их полная версия. DELETE (без
    // триггеров и проверок FK — режим replica) только этих таблиц: остальные после настоящих миграций пусты, а TRUNCATE
    // создаёт новые файлы отношений (на OPFS ~0,3 с). Старый манифест без migrationRows — TRUNCATE всех (CASCADE —
    // из-за внешних ключей пустых таблиц).
    if (Array.isArray(manifest.migrationRows)) {
      for (const m of manifest.migrationRows) {
        const [schema, name] = m.table.split('.');
        await db.query(`DELETE FROM ONLY ${q(schema)}.${q(name)}`);
      }
    } else await db.query(`TRUNCATE ONLY ${tables.map(qn).join(', ')} CASCADE`);
    mark('clear', s);
    s = t();
    for (const tb of tables) {
      await db.query(`COPY ${qn(tb)} (${tb.columns.map(q).join(', ')}) FROM '/dev/blob'`, [], { blob: new Blob([payload.get(tb)]) });
    }
    mark('copy', s);
    s = t();
    for (const sq of manifest.sequences) await db.query(`SELECT setval($1::regclass, $2::bigint, $3)`, [`${q(sq.schema)}.${q(sq.name)}`, sq.value, sq.isCalled]);
    mark('setval', s);
    // Хэш-цепочка аудита: occurred_at входит в канон строки (audit_canon) — после сдвига цепочка пересчитывается тем
    // же способом, что триггер audit_logs_chain (prev_hash предыдущей строки по chain_seq, sha256 канона).
    s = t();
    let audit = null;
    if (manifest.auditChain) {
      await db.exec(`DO $$
        DECLARE r audit_logs; prev bytea := decode(repeat('00', 32), 'hex'); h bytea;
        BEGIN
          FOR r IN SELECT * FROM audit_logs ORDER BY chain_seq LOOP
            h := digest(prev || convert_to(audit_canon(r), 'UTF8'), 'sha256');
            UPDATE audit_logs SET prev_hash = prev, row_hash = h WHERE id = r.id;
            prev := h;
          END LOOP;
        END $$`);
      const v = (await db.query(`SELECT ok, broken_at_chain_seq::text AS broken, gaps FROM audit_verify_chain(0, 9223372036854775807)`)).rows[0];
      audit = { ok: !!v?.ok, broken: v?.broken ?? null, gaps: v?.gaps ?? null };
      if (!audit.ok) throw new Error(`снимок: цепочка аудита после пересчёта не сходится (chain_seq ${audit.broken})`);
    }
    mark('audit', s);
    s = t();
    for (const m of manifest.materializedViews ?? []) await db.query(`REFRESH MATERIALIZED VIEW ${q(m.schema)}.${q(m.name)}`);
    mark('refresh', s);
    s = t();
    let rows = 0;
    const bad = [];
    for (const tb of tables) {
      const n = Number((await db.query(`SELECT count(*)::bigint AS n FROM ${qn(tb)}`)).rows[0].n);
      rows += n;
      if (n !== tb.rows) bad.push(`${tb.schema}.${tb.name}: ${n} ≠ ${tb.rows}`);
    }
    if (bad.length) throw new Error(`снимок: число строк не совпало: ${bad.join('; ')}`);
    mark('verify', s);
    await db.query('COMMIT');
    return { ms: Math.round(t() - t0), rows, tables: tables.length, rebased, audit, steps };
  } catch (e) {
    await db.query('ROLLBACK').catch(() => undefined);
    throw e;
  }
}
