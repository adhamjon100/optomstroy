#!/usr/bin/env node
// Оптомстрой — одноразовый PostgreSQL 17 для проверки SQL-файлов без Docker.
// Использование: node tools/pg/run-sql.mjs [опции] file1.sql [file2.sql ...] [--check check.sql]
// Подробности — tools/pg/README.md, решения — tools/pg/NOTES.md.
//
// Коды выхода:
//   0 — все файлы и check применены без ошибок;
//   1 — ошибка SQL в применяемом файле или в check-файле (ON_ERROR_STOP),
//       а в режиме --repeat-strict также ошибка или изменения при повторном применении;
//   2 — ошибка использования или инфраструктуры (аргументы, файл не найден, кластер не стартовал).

import { randomUUID, randomBytes } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const TMP_ROOT = path.join(HERE, '.tmp');
const DB_NAME = 'pos_test';
const DB_USER = 'postgres';
const KNOWN_EXTENSIONS = ['pg_trgm', 'unaccent', 'pgcrypto'];

const EXIT_OK = 0;
const EXIT_SQL = 1;
const EXIT_INFRA = 2;

class UsageError extends Error {}
class InfraError extends Error {}

// ---------------------------------------------------------------------------
// Аргументы
// ---------------------------------------------------------------------------

const HELP = `Использование:
  node tools/pg/run-sql.mjs [опции] file1.sql [file2.sql ...] [--check check.sql]

Опции:
  --check <file>     выполнить файл проверок после применения (можно несколько раз);
                     результаты SELECT печатаются таблицей, ошибка — код выхода 1
  --repeat           повторно применить те же файлы (проверка идемпотентности);
                     печатается результат: ошибка / 0 изменений / найденные изменения
  --repeat-strict    как --repeat, но ошибка или изменения при повторе дают код 1
  --ext <list>       заранее создать расширения в ${DB_NAME} (через запятую;
                     all = ${KNOWN_EXTENSIONS.join(',')}); по умолчанию не создаются
  --keep             не удалять каталог кластера (сервер всё равно останавливается)
  --locale <name>    локаль кластера (по умолчанию: en-US на Windows, иначе en_US.UTF-8/C.UTF-8)
  --set <имя=значение>
                     задать пользовательский параметр сеанса (только имена вида prefix.name,
                     например app.env=test) до применения файлов — аналог PGOPTIONS='-c имя=значение';
                     можно несколько раз
  --verbose          печатать тег каждой команды и журнал сервера
  --clean            удалить все каталоги ${path.relative(process.cwd(), TMP_ROOT) || '.tmp'}/* и выйти
  -h, --help         эта справка

Коды выхода: 0 — успех; 1 — ошибка SQL (файлы/check, либо --repeat-strict); 2 — ошибка запуска.`;

function parseArgs(argv) {
  const opts = {
    files: [],
    checks: [],
    keep: false,
    repeat: false,
    repeatStrict: false,
    ext: [],
    locale: null,
    sets: [],
    verbose: false,
    clean: false,
    help: false,
  };
  const takeValue = (i, name) => {
    const v = argv[i + 1];
    if (v === undefined || v.startsWith('--')) throw new UsageError(`опции ${name} нужно значение`);
    return v;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const eq = a.indexOf('=');
    const [name, inline] = a.startsWith('--') && eq > 0 ? [a.slice(0, eq), a.slice(eq + 1)] : [a, undefined];
    const value = () => {
      if (inline !== undefined) return inline;
      const v = takeValue(i, name);
      i++;
      return v;
    };
    switch (name) {
      case '--check': opts.checks.push(value()); break;
      case '--keep': opts.keep = true; break;
      case '--repeat': opts.repeat = true; break;
      case '--repeat-strict': opts.repeat = true; opts.repeatStrict = true; break;
      case '--ext': {
        const list = value().split(',').map((s) => s.trim()).filter(Boolean);
        for (const e of list) {
          if (e === 'all') opts.ext.push(...KNOWN_EXTENSIONS);
          else if (/^[a-z_][a-z0-9_]*$/.test(e)) opts.ext.push(e);
          else throw new UsageError(`недопустимое имя расширения: ${e}`);
        }
        break;
      }
      case '--locale': opts.locale = value(); break;
      case '--set': {
        const v = value();
        const m = /^([a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*)=(.*)$/.exec(v);
        if (!m) throw new UsageError(`--set: ожидается prefix.name=value, получено: ${v}`);
        opts.sets.push([m[1], m[2]]);
        break;
      }
      case '--verbose': opts.verbose = true; break;
      case '--clean': opts.clean = true; break;
      case '-h': case '--help': opts.help = true; break;
      default:
        if (a.startsWith('-')) throw new UsageError(`неизвестная опция: ${a}`);
        opts.files.push(a);
    }
  }
  opts.ext = [...new Set(opts.ext)];
  return opts;
}

// ---------------------------------------------------------------------------
// Разбор SQL на команды (эквивалент лексера psql)
// ---------------------------------------------------------------------------

const isIdentStart = (c) => /[A-Za-z_]/.test(c) || c > '\u007f';
const isIdentChar = (c) => /[A-Za-z0-9_$]/.test(c) || c > '\u007f';
const DOLLAR_TAG = /\$([A-Za-z_\u0080-￿][A-Za-z0-9_\u0080-￿]*)?\$/y;

/**
 * Делит текст на команды по «;» так же, как psql: не внутри '...', E'...', "...",
 * $tag$...$tag$, комментариев -- и вложенных /* *\/, круглых скобок и блоков
 * BEGIN ... END в CREATE [OR REPLACE] FUNCTION|PROCEDURE (BEGIN ATOMIC).
 * Возвращает [{start, end, sql}], start — смещение первого значимого символа.
 */
export function splitSql(text) {
  const out = [];
  const n = text.length;
  let i = 0;
  let stmtStart = -1;
  let paren = 0;
  let beginDepth = 0;
  let identCount = 0;
  let idents = [];

  const reset = () => { stmtStart = -1; paren = 0; beginDepth = 0; identCount = 0; idents = []; };
  const emit = (end) => {
    let e = end;
    while (e > stmtStart && /\s/.test(text[e - 1])) e--;
    out.push({ start: stmtStart, end: e, sql: text.slice(stmtStart, e) });
    reset();
  };
  const isFuncDef = () => idents[0] === 'c' && (idents[1] === 'f' || idents[1] === 'p'
    || (idents[1] === 'o' && idents[2] === 'r' && (idents[3] === 'f' || idents[3] === 'p')));

  while (i < n) {
    const c = text[i];
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\f' || c === '\v') { i++; continue; }
    if (c === '-' && text[i + 1] === '-') {
      while (i < n && text[i] !== '\n') i++;
      continue;
    }
    if (c === '/' && text[i + 1] === '*') {
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (text[i] === '/' && text[i + 1] === '*') { depth++; i += 2; }
        else if (text[i] === '*' && text[i + 1] === '/') { depth--; i += 2; }
        else i++;
      }
      continue;
    }
    if (stmtStart < 0) {
      if (c === ';') { i++; continue; }
      stmtStart = i;
    }
    if (c === "'") {
      // E'...' — обратная косая экранирует; иначе только ''.
      const escape = i > stmtStart && (text[i - 1] === 'e' || text[i - 1] === 'E')
        && (i - 2 < stmtStart || !isIdentChar(text[i - 2]));
      i++;
      while (i < n) {
        if (escape && text[i] === '\\') { i += 2; continue; }
        if (text[i] === "'") {
          if (text[i + 1] === "'") { i += 2; continue; }
          break;
        }
        i++;
      }
      i++;
      continue;
    }
    if (c === '"') {
      i++;
      while (i < n) {
        if (text[i] === '"') {
          if (text[i + 1] === '"') { i += 2; continue; }
          break;
        }
        i++;
      }
      i++;
      continue;
    }
    if (c === '$') {
      if (/[0-9]/.test(text[i + 1] ?? '')) { i++; continue; } // $1 — параметр
      if (i === stmtStart || !isIdentChar(text[i - 1])) {
        DOLLAR_TAG.lastIndex = i;
        const m = DOLLAR_TAG.exec(text);
        if (m) {
          const tag = m[0];
          const close = text.indexOf(tag, i + tag.length);
          i = close < 0 ? n : close + tag.length;
          continue;
        }
      }
      i++;
      continue;
    }
    if (c === '(') { paren++; i++; continue; }
    if (c === ')') { if (paren > 0) paren--; i++; continue; }
    if (c === '\\') {
      const err = new Error('метакоманды psql (\\...) не поддерживаются: используйте только SQL');
      err.offset = i;
      throw err;
    }
    if (c === ';') {
      if (paren === 0 && beginDepth === 0) { emit(i); i++; continue; }
      i++;
      continue;
    }
    if (isIdentStart(c)) {
      let j = i + 1;
      while (j < n && isIdentChar(text[j])) j++;
      const word = text.slice(i, j).toLowerCase();
      if (identCount === 0) idents = [];
      if (['create', 'function', 'procedure', 'or', 'replace'].includes(word) && identCount < 4) {
        idents[identCount] = word[0];
      }
      identCount++;
      if (isFuncDef() && paren === 0) {
        if (word === 'begin') beginDepth++;
        else if (word === 'case') { if (beginDepth >= 1) beginDepth++; }
        else if (word === 'end') { if (beginDepth > 0) beginDepth--; }
      }
      i = j;
      continue;
    }
    if (/[0-9]/.test(c)) {
      let j = i + 1;
      while (j < n && /[0-9A-Za-z_.]/.test(text[j])) j++;
      i = j;
      continue;
    }
    i++;
  }
  if (stmtStart >= 0) emit(n);
  return out;
}

function makeLineIndex(text) {
  const starts = [0];
  for (let i = 0; i < text.length; i++) if (text[i] === '\n') starts.push(i + 1);
  return (offset) => {
    let lo = 0;
    let hi = starts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) lo = mid; else hi = mid - 1;
    }
    const lineEnd = text.indexOf('\n', starts[lo]);
    const lineText = text.slice(starts[lo], lineEnd < 0 ? text.length : lineEnd).replace(/\r$/, '');
    return { line: lo + 1, col: offset - starts[lo] + 1, lineText };
  };
}

// ---------------------------------------------------------------------------
// Вывод
// ---------------------------------------------------------------------------

const log = (...a) => console.log(...a);
const err = (...a) => console.error(...a);
const rel = (p) => path.relative(process.cwd(), p) || p;

const NUMERIC_OIDS = new Set([20, 21, 23, 26, 700, 701, 1700]);
const RAW_TYPES = { getTypeParser: () => (v) => v };

function formatTable(fields, rows) {
  const cell = (v) => (v === null || v === undefined ? '' : String(v).replace(/\r?\n/g, '↵'));
  const headers = fields.map((f) => f.name);
  const data = rows.map((r) => r.map(cell));
  const width = headers.map((h, k) => Math.max([...h].length, ...data.map((r) => [...r[k]].length)));
  const pad = (s, w, right) => (right ? ' '.repeat(w - [...s].length) + s : s + ' '.repeat(w - [...s].length));
  const center = (s, w) => {
    const left = Math.floor((w - [...s].length) / 2);
    return ' '.repeat(left) + s + ' '.repeat(w - [...s].length - left);
  };
  const lines = [];
  lines.push(' ' + headers.map((h, k) => center(h, width[k])).join(' | ') + ' ');
  lines.push(width.map((w) => '-'.repeat(w + 2)).join('+'));
  for (const r of data) {
    lines.push(' ' + r.map((v, k) => pad(v, width[k], NUMERIC_OIDS.has(fields[k].dataTypeID))).join(' | ') + ' ');
  }
  lines.push(`(${rows.length} ${rows.length === 1 ? 'row' : 'rows'})`);
  return lines.join('\n');
}

// node-postgres отдаёт только первое слово тега (CREATE); объект берём из текста команды.
const DDL_OBJECT = /^(CREATE|ALTER|DROP)\s+(?:OR\s+REPLACE\s+)?(?:(?:UNIQUE|TEMP|TEMPORARY|UNLOGGED|MATERIALIZED|CONSTRAINT|DEFAULT|TRUSTED|PROCEDURAL|EVENT|FOREIGN|TEXT\s+SEARCH)\s+)*([A-Z_]+)/i;

function commandTag(res, sql) {
  const cmd = res.command ?? sql.trim().split(/\s+/)[0].toUpperCase();
  if (res.rowCount === null || res.rowCount === undefined) {
    const m = DDL_OBJECT.exec(sql.trim());
    return m ? `${m[1]} ${m[2]}`.toUpperCase() : cmd;
  }
  return cmd === 'INSERT' ? `INSERT 0 ${res.rowCount}` : `${cmd} ${res.rowCount}`;
}

function formatPgError(e, file, where) {
  const sev = e.severity || 'ERROR';
  const head = where ? `${rel(file)}:${where.line}:${where.col}` : rel(file);
  const lines = [`${head}: ${sev}:  ${e.message}${e.code ? ` (SQLSTATE ${e.code})` : ''}`];
  if (e.detail) lines.push(`DETAIL:  ${e.detail}`);
  if (e.hint) lines.push(`HINT:  ${e.hint}`);
  if (where && where.lineText !== undefined) {
    const prefix = `LINE ${where.line}: `;
    lines.push(prefix + where.lineText);
    if (where.caret) lines.push(' '.repeat(prefix.length + where.col - 1) + '^');
  }
  if (e.internalQuery) lines.push(`QUERY:  ${e.internalQuery}`);
  if (e.where) lines.push(`CONTEXT:  ${e.where}`);
  return lines.join('\n');
}

// ---------------------------------------------------------------------------
// Выполнение файла
// ---------------------------------------------------------------------------

/**
 * Применяет файл покомандно (autocommit, как psql). Первая ошибка — исключение
 * SqlFileError с текстом в формате psql (файл:строка:колонка).
 * mode: 'apply' — молча (с --verbose печатает теги), 'check' — печатает результаты.
 */
class SqlFileError extends Error {}

async function runFile(client, file, { mode, verbose, ctx }) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    throw new InfraError(`не удалось прочитать ${file}: ${e.message}`);
  }
  if (text.charCodeAt(0) === 0xfeff) text = ' ' + text.slice(1); // BOM → пробел, смещения сохраняются
  const where = makeLineIndex(text);
  let stmts;
  try {
    stmts = splitSql(text);
  } catch (e) {
    const w = where(e.offset ?? 0);
    throw new SqlFileError(`${rel(file)}:${w.line}:${w.col}: ERROR:  ${e.message}\nLINE ${w.line}: ${w.lineText}`);
  }
  const stats = { statements: 0, dmlRows: 0, tags: [] };
  for (const st of stmts) {
    const at = where(st.start);
    ctx.current = { file, line: at.line };
    if (/^copy\b[\s\S]*\bfrom\s+stdin\b/i.test(st.sql)) {
      throw new SqlFileError(`${rel(file)}:${at.line}: ERROR:  COPY ... FROM STDIN не поддерживается раннером`);
    }
    let res;
    try {
      res = await client.query({ text: st.sql, rowMode: 'array', types: RAW_TYPES });
    } catch (e) {
      if (!e || typeof e !== 'object' || !('severity' in e || 'code' in e)) throw e;
      let w = { line: at.line, col: 1, lineText: undefined, caret: false };
      const pos = Number.parseInt(e.position, 10);
      if (Number.isFinite(pos) && pos > 0) {
        w = { ...where(st.start + pos - 1), caret: true };
      } else {
        w = { ...at, caret: false };
      }
      throw new SqlFileError(formatPgError(e, file, w));
    }
    const results = Array.isArray(res) ? res : [res];
    for (const r of results) {
      stats.statements++;
      const tag = commandTag(r, st.sql);
      stats.tags.push({ line: at.line, tag });
      if (['INSERT', 'UPDATE', 'DELETE', 'MERGE', 'COPY'].includes(r.command) && r.rowCount) stats.dmlRows += r.rowCount;
      if (mode === 'check') {
        log(`-- ${rel(file)}:${at.line}`);
        log(r.fields && r.fields.length ? formatTable(r.fields, r.rows) : tag);
        log('');
      } else if (verbose) {
        log(`  ${rel(file)}:${at.line}: ${tag}`);
      }
    }
  }
  ctx.current = null;
  return stats;
}

// ---------------------------------------------------------------------------
// Отпечаток схемы и данных (для --repeat)
// ---------------------------------------------------------------------------

const USER_NS = `n.nspname NOT IN ('pg_catalog','information_schema','pg_toast') AND n.nspname NOT LIKE 'pg_temp_%' AND n.nspname NOT LIKE 'pg_toast_temp_%'`;
const FINGERPRINT_QUERIES = {
  'schemas': `SELECT n.nspname FROM pg_namespace n WHERE ${USER_NS} ORDER BY 1`,
  'relations': `SELECT n.nspname||'.'||c.relname||' '||c.relkind::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE ${USER_NS} ORDER BY 1`,
  'columns': `SELECT n.nspname||'.'||c.relname||'.'||a.attname||' '||format_type(a.atttypid,a.atttypmod)||CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END||coalesce(' DEFAULT '||pg_get_expr(d.adbin,d.adrelid),'')||CASE WHEN a.attidentity<>'' THEN ' IDENTITY '||a.attidentity::text ELSE '' END||CASE WHEN a.attgenerated<>'' THEN ' GENERATED' ELSE '' END FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum WHERE ${USER_NS} AND a.attnum>0 AND NOT a.attisdropped AND c.relkind IN ('r','p','v','m','f','c') ORDER BY 1`,
  'constraints': `SELECT n.nspname||'.'||coalesce(c.relname,t.typname)||'.'||k.conname||' '||pg_get_constraintdef(k.oid) FROM pg_constraint k JOIN pg_namespace n ON n.oid=k.connamespace LEFT JOIN pg_class c ON c.oid=k.conrelid LEFT JOIN pg_type t ON t.oid=k.contypid WHERE ${USER_NS} ORDER BY 1`,
  'indexes': `SELECT pg_get_indexdef(i.indexrelid) FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE ${USER_NS} ORDER BY 1`,
  'functions': `SELECT n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||') '||p.prokind::text||' '||md5(coalesce(p.prosrc,'')||coalesce(pg_get_function_result(p.oid),'')) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace LEFT JOIN pg_depend dep ON dep.objid=p.oid AND dep.deptype='e' WHERE ${USER_NS} AND dep.objid IS NULL ORDER BY 1`,
  'triggers': `SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE ${USER_NS} AND NOT t.tgisinternal ORDER BY 1`,
  'types': `SELECT n.nspname||'.'||t.typname||' '||t.typtype::text||coalesce(' ['||(SELECT string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid=t.oid)||']','') FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace LEFT JOIN pg_depend dep ON dep.objid=t.oid AND dep.deptype='e' WHERE ${USER_NS} AND t.typtype IN ('e','d','c','r','m') AND dep.objid IS NULL AND NOT (t.typtype='c' AND EXISTS (SELECT 1 FROM pg_class c WHERE c.oid=t.typrelid AND c.relkind<>'c')) ORDER BY 1`,
  'policies': `SELECT n.nspname||'.'||c.relname||'.'||p.polname||' '||p.polcmd::text||' '||coalesce(pg_get_expr(p.polqual,p.polrelid),'')||' '||coalesce(pg_get_expr(p.polwithcheck,p.polrelid),'') FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid JOIN pg_namespace n ON n.oid=c.relnamespace ORDER BY 1`,
  'extensions': `SELECT extname||' '||extversion FROM pg_extension ORDER BY 1`,
  'roles': `SELECT rolname||' '||rolsuper::text||rolinherit::text||rolcreaterole::text||rolcreatedb::text||rolcanlogin::text FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY 1`,
  'grants': `SELECT n.nspname||'.'||c.relname||' '||coalesce(c.relacl::text,'') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE ${USER_NS} AND c.relacl IS NOT NULL ORDER BY 1`,
};

async function fingerprint(client) {
  const fp = {};
  for (const [k, q] of Object.entries(FINGERPRINT_QUERIES)) {
    const r = await client.query({ text: q, rowMode: 'array', types: RAW_TYPES });
    fp[k] = r.rows.map((row) => row[0]);
  }
  const tables = await client.query(`SELECT quote_ident(n.nspname)||'.'||quote_ident(c.relname) AS t FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE ${USER_NS} AND c.relkind='r' ORDER BY 1`);
  fp.data = [];
  for (const { t } of tables.rows) {
    const r = await client.query(`SELECT count(*)::text AS n, coalesce(md5(string_agg(x::text, E'\\n' ORDER BY x::text)), '-') AS h FROM ${t} x`);
    fp.data.push(`${t} rows=${r.rows[0].n} md5=${r.rows[0].h}`);
  }
  return fp;
}

function diffFingerprint(a, b) {
  const changes = [];
  for (const k of Object.keys(a)) {
    const sa = new Set(a[k]);
    const sb = new Set(b[k]);
    for (const x of b[k]) if (!sa.has(x)) changes.push(`  + ${k}: ${x}`);
    for (const x of a[k]) if (!sb.has(x)) changes.push(`  - ${k}: ${x}`);
  }
  return changes;
}

// ---------------------------------------------------------------------------
// Кластер
// ---------------------------------------------------------------------------

function platformPackage() {
  const plat = { win32: 'windows', darwin: 'darwin', linux: 'linux' }[os.platform()];
  if (!plat) throw new InfraError(`платформа ${os.platform()} не поддерживается embedded-postgres`);
  return `@embedded-postgres/${plat}-${os.arch()}`;
}

function defaultLocale() {
  if (os.platform() === 'win32') return 'en-US';
  try {
    const all = new Set(execFileSync('locale', ['-a'], { encoding: 'utf8' }).split(/\r?\n/).map((s) => s.trim()));
    for (const l of ['en_US.utf8', 'en_US.UTF-8', 'C.utf8', 'C.UTF-8']) if (all.has(l)) return l;
  } catch { /* нет locale -a */ }
  return 'C.UTF-8';
}

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

async function removeDir(dir) {
  await fsp.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
}

class Cluster {
  constructor({ locale, verbose }) {
    this.id = randomUUID();
    this.dir = path.join(TMP_ROOT, this.id);
    this.locale = locale;
    this.verbose = verbose;
    this.password = randomBytes(18).toString('base64url');
    this.serverLog = [];
    this.pg = null;
    this.port = null;
    this.bins = null;
  }

  async start() {
    let EmbeddedPostgres;
    try {
      ({ default: EmbeddedPostgres } = await import('embedded-postgres'));
      this.bins = await import(platformPackage());
    } catch (e) {
      throw new InfraError(`embedded-postgres не установлен (выполните: npm --prefix tools/pg install): ${e.message}`);
    }
    await fsp.mkdir(TMP_ROOT, { recursive: true });
    const onLog = (m) => {
      this.serverLog.push(m);
      if (this.verbose) process.stderr.write(`[server] ${m}${m.endsWith('\n') ? '' : '\n'}`);
    };
    let lastErr;
    for (let attempt = 1; attempt <= 3; attempt++) {
      this.port = await freePort();
      this.pg = new EmbeddedPostgres({
        databaseDir: this.dir,
        user: DB_USER,
        password: this.password,
        port: this.port,
        authMethod: 'scram-sha-256',
        persistent: true, // удаление делаем сами (с повторами — Windows держит файлы)
        initdbFlags: ['--encoding=UTF8', `--locale=${this.locale}`, '--data-checksums'],
        postgresFlags: [
          '-c', 'listen_addresses=127.0.0.1',
          '-c', 'unix_socket_directories=',
          '-c', 'fsync=off',
          '-c', 'synchronous_commit=off',
          '-c', 'full_page_writes=off',
          '-c', 'timezone=UTC',
          '-c', 'max_connections=20',
        ],
        onLog,
        onError: onLog,
      });
      try {
        if (attempt === 1) await this.pg.initialise();
        await this.pg.start();
        return;
      } catch (e) {
        lastErr = e;
        if (!fs.existsSync(path.join(this.dir, 'PG_VERSION'))) break; // initdb не прошёл — повтор бесполезен
      }
    }
    const tail = this.serverLog.join('').split(/\r?\n/).slice(-15).join('\n');
    throw new InfraError(`кластер не запустился: ${lastErr?.message ?? 'процесс postgres завершился'}\n${tail}`);
  }

  client(database) {
    return import('pg').then(({ default: pg }) => new pg.Client({
      host: '127.0.0.1',
      port: this.port,
      user: DB_USER,
      password: this.password,
      database,
      application_name: 'optomstroy-run-sql',
    }));
  }

  async stop() {
    const proc = this.pg?.process;
    if (proc && proc.exitCode === null && proc.signalCode === null) {
      const exited = new Promise((resolve) => proc.once('exit', resolve));
      await new Promise((resolve) => {
        const c = spawn(this.bins.pg_ctl, ['stop', '-D', this.dir, '-m', 'fast', '-w', '-t', '30'], { stdio: 'ignore' });
        c.on('error', resolve);
        c.on('close', resolve);
      });
      const timeout = new Promise((resolve) => setTimeout(() => resolve('timeout'), 15000).unref());
      if ((await Promise.race([exited, timeout])) === 'timeout') {
        await this.pg.stop(); // принудительно (taskkill / SIGINT)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Основной сценарий
// ---------------------------------------------------------------------------

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    err(`run-sql: ${e.message}\n\n${HELP}`);
    return EXIT_INFRA;
  }
  if (opts.help) { log(HELP); return EXIT_OK; }
  if (opts.clean) {
    const entries = fs.existsSync(TMP_ROOT) ? fs.readdirSync(TMP_ROOT) : [];
    for (const e of entries) await removeDir(path.join(TMP_ROOT, e));
    log(`[pg] удалено каталогов: ${entries.length} (${rel(TMP_ROOT)})`);
    return EXIT_OK;
  }
  if (opts.files.length === 0 && opts.checks.length === 0) {
    err(`run-sql: не указан ни один SQL-файл\n\n${HELP}`);
    return EXIT_INFRA;
  }
  for (const f of [...opts.files, ...opts.checks]) {
    if (!fs.existsSync(f) || !fs.statSync(f).isFile()) {
      err(`run-sql: файл не найден: ${f}`);
      return EXIT_INFRA;
    }
  }

  const cluster = new Cluster({ locale: opts.locale ?? defaultLocale(), verbose: opts.verbose });
  const ctx = { current: null };
  let client = null;
  let code = EXIT_OK;
  let stopping = false;

  const cleanup = async () => {
    if (stopping) return;
    stopping = true;
    if (client) await client.end().catch(() => {});
    await cluster.stop().catch((e) => err(`[pg] остановка: ${e.message}`));
    if (opts.keep) {
      log(`[pg] кластер остановлен, каталог сохранён (--keep): ${rel(cluster.dir)}`);
      log(`[pg] запуск вручную: "${cluster.bins?.pg_ctl ?? 'pg_ctl'}" -D "${cluster.dir}" -o "-p ${cluster.port}" -l "${path.join(cluster.dir, 'server.log')}" start`);
      const connFile = path.join(cluster.dir, 'run-sql.conn');
      try {
        fs.writeFileSync(connFile, `postgresql://${DB_USER}:${encodeURIComponent(cluster.password)}@127.0.0.1:${cluster.port}/${DB_NAME}\n`, { mode: 0o600 });
        log(`[pg] строка подключения (одноразовый пароль кластера) — в ${rel(connFile)}`);
      } catch (e) {
        err(`[pg] не удалось записать ${rel(connFile)}: ${e.message}`);
      }
    } else {
      await removeDir(cluster.dir).catch((e) => err(`[pg] не удалось удалить ${rel(cluster.dir)}: ${e.message}`));
      log(`[pg] кластер остановлен и удалён`);
    }
  };
  const onSignal = (sig) => {
    err(`\n[pg] получен ${sig}, останавливаю кластер…`);
    cleanup().finally(() => process.exit(130));
  };
  process.once('SIGINT', onSignal);
  process.once('SIGTERM', onSignal);
  // Закрытый канал вывода (например, `| head`) не должен оставлять кластер на диске.
  for (const s of [process.stdout, process.stderr]) s.on('error', () => {});
  process.once('uncaughtException', (e) => {
    try { err(`run-sql: ${e?.stack ?? e}`); } catch { /* вывод недоступен */ }
    cleanup().finally(() => process.exit(EXIT_INFRA));
  });

  try {
    const t0 = Date.now();
    await cluster.start();

    const admin = await cluster.client('postgres');
    await admin.connect();
    await admin.query(`CREATE DATABASE ${DB_NAME} TEMPLATE template0 ENCODING 'UTF8'`);
    await admin.end();

    client = await cluster.client(DB_NAME);
    client.on('error', (e) => err(`[pg] соединение: ${e.message}`));
    client.on('notice', (m) => {
      const at = ctx.current ? `${rel(ctx.current.file)}:${ctx.current.line}: ` : '';
      err(`${at}${m.severity}:  ${m.message}`);
    });
    await client.connect();

    const info = await client.query(`SELECT version() AS v, current_setting('server_version') AS sv,
      pg_encoding_to_char(d.encoding) AS enc, d.datcollate AS coll, d.datctype AS ctype
      FROM pg_database d WHERE d.datname = current_database()`);
    const exts = await client.query(`SELECT name, default_version FROM pg_available_extensions WHERE name = ANY($1) ORDER BY name`, [KNOWN_EXTENSIONS]);
    const i0 = info.rows[0];
    log(`[pg] ${i0.v}`);
    log(`[pg] кластер ${rel(cluster.dir)}, порт ${cluster.port}, БД ${DB_NAME} (${i0.enc}, collate ${i0.coll}, ctype ${i0.ctype}), старт ${Date.now() - t0} мс`);
    log(`[pg] доступные расширения: ${exts.rows.map((r) => `${r.name} ${r.default_version}`).join(', ') || 'нет'}`);
    if (!i0.sv.startsWith('17.')) throw new InfraError(`ожидался PostgreSQL 17, получен ${i0.sv}`);

    for (const [name, val] of opts.sets) {
      await client.query('SELECT set_config($1, $2, false)', [name, val]);
      log(`[pg] параметр сеанса ${name} = '${val}' (--set)`);
    }

    for (const e of opts.ext) {
      await client.query(`CREATE EXTENSION IF NOT EXISTS ${e}`);
      log(`[pg] расширение ${e} создано (--ext)`);
    }

    // 1. Применение файлов
    for (const f of opts.files) {
      const t = Date.now();
      const s = await runFile(client, f, { mode: 'apply', verbose: opts.verbose, ctx });
      log(`[apply] ${rel(f)}: ${s.statements} команд — OK (${Date.now() - t} мс)`);
    }

    // 2. Повторное применение (идемпотентность)
    if (opts.repeat && opts.files.length) {
      const before = await fingerprint(client);
      let failure = null;
      let total = { statements: 0, dmlRows: 0 };
      for (const f of opts.files) {
        try {
          const s = await runFile(client, f, { mode: 'apply', verbose: true, ctx });
          total.statements += s.statements;
          total.dmlRows += s.dmlRows;
          log(`[repeat] ${rel(f)}: ${s.statements} команд, затронуто строк DML: ${s.dmlRows}`);
        } catch (e) {
          if (!(e instanceof SqlFileError)) throw e;
          failure = e;
          log(`[repeat] ${rel(f)}: ОШИБКА при повторном применении`);
          log(e.message);
          // Если файл открыл транзакцию — закрыть её, чтобы снять отпечаток и выполнить check.
          await client.query('ROLLBACK').catch(() => {});
          break;
        }
      }
      const after = await fingerprint(client);
      const changes = diffFingerprint(before, after);
      if (changes.length) {
        log(`[repeat] изменения схемы/данных после повтора (${changes.length}):`);
        log(changes.join('\n'));
      }
      const verdict = failure
        ? (changes.length ? 'ошибка при повторе; до ошибки внесены изменения' : 'ошибка при повторе; изменений нет')
        : (changes.length ? 'ПОВТОР ВНЁС ИЗМЕНЕНИЯ' : '0 изменений (схема и данные совпадают)');
      log(`[repeat] ИТОГ: ${verdict}; команд выполнено: ${total.statements}, строк DML: ${total.dmlRows}`);
      if (opts.repeatStrict && (failure || changes.length)) code = EXIT_SQL;
    }

    // 3. Проверки
    for (const f of opts.checks) {
      log(`[check] ${rel(f)}`);
      await runFile(client, f, { mode: 'check', verbose: opts.verbose, ctx });
      log(`[check] ${rel(f)}: OK`);
    }
  } catch (e) {
    if (e instanceof SqlFileError) {
      err(e.message);
      code = EXIT_SQL;
    } else if (e instanceof InfraError) {
      err(`run-sql: ${e.message}`);
      code = EXIT_INFRA;
    } else {
      err(`run-sql: ${e?.stack ?? e}`);
      code = EXIT_INFRA;
    }
  } finally {
    await cleanup();
  }
  return code;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then((code) => {
    process.exitCode = code;
    // embedded-postgres вешает обработчики выхода — завершаемся явно.
    setTimeout(() => process.exit(code), 50).unref();
  });
}
