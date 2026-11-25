// Помощник комплекта PostgreSQL для Windows Server (infra/windows/postgres; план WINDOWS_NATIVE_PLAN §8 шаг 3).
// Выполняет SQL через модуль `pg` из пакета api релиза (releases\<версия>\api\node_modules) на node.exe релиза:
// psql в комплекте не нужен, а кириллица проверки локали не зависит от кодовой страницы консоли.
//
// Команды:
//   setup   — создаёт базу (как в Linux-комплекте: UTF8, builtin C.UTF-8, LC_COLLATE C, LC_CTYPE en-US), роли и права
//             roles.sql (точный перенос infra/docker/postgres/initdb/10-roles.sh), затем gate;
//   gate    — стоп-проверка lower('ЁЯ') = 'ёя', параметров базы и наличия расширений (код 3 — провал);
//   verify  — проверка прав ролей после установки (и после migrate): pos_app без DDL, pos_migrate — владелец,
//             pos_backup читает все таблицы и последовательности (как pg_dump) и подключается в режиме репликации;
//   archive — архивирование WAL работает (pg_switch_wal → сегмент сохранён archive_command, failed_count не растёт);
//   db-exists — есть ли база из database_url (JSON {"exists":…});
//   drop-db — удаление базы тестового стенда (install.ps1 -Stand -ResetStandData), только с --confirm <имя базы>.
//
// Пароли берутся только из файлов секретов (--secrets): pg_password (суперпользователь), db_migrator_password,
// db_backup_password, database_url (pos_app). На сервер уходят не пароли, а верификаторы SCRAM-SHA-256,
// вычисленные здесь (ни журнал сервера, ни текст ошибки не содержат пароль). Ничего из секретов не печатается.
// Коды выхода: 0 — успех; 1 — ошибка; 2 — неверные аргументы или секреты; 3 — провал стоп-проверки локали/расширений.
import { createHash, createHmac, pbkdf2Sync, randomBytes } from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REQUIRED_EXTENSIONS = ['pg_trgm', 'unaccent', 'pgcrypto', 'pg_stat_statements'];
const DB_NAME_RE = /^[a-z_][a-z0-9_]{0,62}$/;
const ROLES = ['pos_migrate', 'pos_app', 'pos_readonly', 'pos_backup'];

class UsageError extends Error {}
class GateError extends Error {}

function parseArgs(argv) {
  const [cmd, ...rest] = argv;
  const opts = {};
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (!a.startsWith('--')) throw new UsageError(`лишний аргумент: ${a}`);
    const key = a.slice(2);
    const val = rest[i + 1];
    if (val === undefined || val.startsWith('--')) throw new UsageError(`нет значения у --${key}`);
    opts[key] = val;
    i++;
  }
  return { cmd, opts };
}

function need(opts, key) {
  const v = opts[key];
  if (v === undefined || v === '') throw new UsageError(`не задан --${key}`);
  return v;
}

/** Секрет: файл целиком, CR/LF удаляются (как `tr -d '\r\n'` в 10-roles.sh). */
function readSecret(dir, name) {
  const p = join(dir, name);
  if (!existsSync(p)) throw new UsageError(`нет файла секрета ${name} в папке секретов`);
  let v = readFileSync(p, 'utf8');
  if (v.charCodeAt(0) === 0xfeff) v = v.slice(1); // BOM от Notepad/Set-Content
  v = v.replace(/[\r\n]/g, '');
  if (v === '') throw new UsageError(`пустой секрет ${name}`);
  return v;
}

/** Пароль роли: только печатные ASCII (SASLprep для них — тождество, верификатор совпадёт с серверным). */
function checkPassword(name, pw) {
  if (!/^[\x21-\x7e]+$/.test(pw)) throw new UsageError(`секрет ${name}: допускаются только печатные ASCII-символы без пробелов`);
  if (pw.length < 16) throw new UsageError(`секрет ${name}: пароль короче 16 символов`);
}

/** Верификатор SCRAM-SHA-256 в формате PostgreSQL (RFC 5802/7677; 4096 итераций — как password_encryption сервера). */
export function scramVerifier(password, salt = randomBytes(16), iterations = 4096) {
  const derived = pbkdf2Sync(Buffer.from(password, 'utf8'), salt, iterations, 32, 'sha256');
  const clientKey = createHmac('sha256', derived).update('Client Key').digest();
  const storedKey = createHash('sha256').update(clientKey).digest();
  const serverKey = createHmac('sha256', derived).update('Server Key').digest();
  return `SCRAM-SHA-256$${iterations}:${salt.toString('base64')}$${storedKey.toString('base64')}:${serverKey.toString('base64')}`;
}

/** database_url → { user, password, host, port, db } (пароль — только в памяти). */
function parseDatabaseUrl(raw) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    throw new UsageError('database_url: не удалось разобрать строку подключения');
  }
  if (u.protocol !== 'postgres:' && u.protocol !== 'postgresql:') throw new UsageError('database_url: схема должна быть postgres://');
  const db = decodeURIComponent(u.pathname.replace(/^\//, ''));
  return {
    user: decodeURIComponent(u.username),
    password: decodeURIComponent(u.password),
    host: u.hostname,
    port: u.port === '' ? 5432 : Number(u.port),
    db,
  };
}

function loadPg(modulesDir) {
  const base = resolve(modulesDir);
  const req = createRequire(join(base, 'noop.cjs'));
  try {
    return req('pg');
  } catch {
    throw new UsageError(`модуль pg не найден относительно ${base} (ожидается <релиз>\\api с node_modules\\pg)`);
  }
}

function makeClientFactory(pg, host, port) {
  return async (user, password, database, extra = {}) => {
    const c = new pg.Client({ host, port, user, password, database, application_name: 'optomstroy-pg-tool', ...extra });
    await c.connect();
    return c;
  };
}

function settings(opts) {
  const host = opts.host ?? '127.0.0.1';
  const port = Number(opts.port ?? '5433');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new UsageError('--port: целое 1..65535');
  if (host !== '127.0.0.1') throw new UsageError('--host: допускается только 127.0.0.1 (PostgreSQL слушает только его)');
  const secretsDir = need(opts, 'secrets');
  const superuser = opts.superuser ?? 'postgres';
  const ctype = opts.ctype ?? (process.platform === 'win32' ? 'en-US' : 'C.UTF-8');
  const suPw = readSecret(secretsDir, 'pg_password');
  const url = parseDatabaseUrl(readSecret(secretsDir, 'database_url'));
  if (url.user !== 'pos_app') throw new UsageError('database_url должен использовать пользователя pos_app (сейчас: другой пользователь)');
  if (url.host !== host) throw new UsageError(`database_url: хост должен быть ${host}`);
  if (url.port !== port) throw new UsageError(`database_url: порт ${url.port} не совпадает с портом PostgreSQL ${port}`);
  if (!DB_NAME_RE.test(url.db)) throw new UsageError('database_url: имя базы — латиница в нижнем регистре, цифры и _, до 63 символов');
  if (opts.db !== undefined && opts.db !== url.db) throw new UsageError(`--db ${opts.db} не совпадает с базой из database_url`);
  if (['postgres', 'template0', 'template1'].includes(url.db)) throw new UsageError('database_url: служебная база не допускается');
  return { host, port, secretsDir, superuser, ctype, suPw, url, db: url.db };
}

async function setup(pg, s, rolesSqlPath) {
  const migPw = readSecret(s.secretsDir, 'db_migrator_password');
  const bkPw = readSecret(s.secretsDir, 'db_backup_password');
  checkPassword('db_migrator_password', migPw);
  checkPassword('db_backup_password', bkPw);
  checkPassword('database_url (пароль pos_app)', s.url.password);
  if (new Set([migPw, bkPw, s.url.password]).size !== 3) throw new UsageError('пароли pos_migrate, pos_backup и pos_app должны различаться');
  if (!/^[a-z_][a-z0-9_]*$/.test(s.superuser)) throw new UsageError('--superuser: латиница в нижнем регистре');
  const rolesSql = readFileSync(rolesSqlPath, 'utf8').replace(/^﻿/, '');
  const connect = makeClientFactory(pg, s.host, s.port);

  const admin = await connect(s.superuser, s.suPw, 'postgres');
  try {
    const v = await admin.query('SELECT current_setting($1)::int AS n, current_setting($2) AS v', ['server_version_num', 'server_version']);
    if (v.rows[0].n < 170000) throw new UsageError(`нужен PostgreSQL 17+, сервер ${v.rows[0].v}`);
    log(`PostgreSQL ${v.rows[0].v} на ${s.host}:${s.port}`);
    const ex = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [s.db]);
    if (ex.rowCount === 0) {
      // Как local-stack.mjs и Linux-кластер: builtin C.UTF-8 (lower() по Unicode), побайтовая сортировка C,
      // LC_CTYPE с классификацией кириллицы для FTS/pg_trgm (16 §4.4 (а): на Windows — en-US). Имя проверено DB_NAME_RE.
      if (!/^[A-Za-z0-9_.\-]+$/.test(s.ctype)) throw new UsageError('--ctype: недопустимое имя локали');
      await admin.query(
        `CREATE DATABASE "${s.db}" TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' LC_COLLATE 'C' LC_CTYPE '${s.ctype}'`,
      );
      log(`база ${s.db} создана (UTF8, builtin C.UTF-8, LC_COLLATE C, LC_CTYPE ${s.ctype})`);
    } else {
      log(`база ${s.db} уже есть — параметры проверяются, роли и права применяются повторно`);
    }
  } finally {
    await admin.end();
  }

  const c = await connect(s.superuser, s.suPw, s.db);
  try {
    // Верификаторы передаются параметрами (в журнал сервера не попадают) в настройки сеанса, roles.sql читает их
    // через current_setting(); после выполнения сеанс закрывается.
    await c.query(
      `SELECT set_config('optomstroy.verifier_pos_migrate', $1, false),
              set_config('optomstroy.verifier_pos_app', $2, false),
              set_config('optomstroy.verifier_pos_backup', $3, false)`,
      [scramVerifier(migPw), scramVerifier(s.url.password), scramVerifier(bkPw)],
    );
    await c.query(rolesSql);
    log('роли pos_migrate, pos_app, pos_readonly, pos_backup и права на базу применены (roles.sql)');
  } finally {
    await c.end();
  }
  await gate(pg, s);
}

async function gate(pg, s) {
  const connect = makeClientFactory(pg, s.host, s.port);
  const c = await connect(s.superuser, s.suPw, s.db);
  try {
    // Две формы: литерал из этого файла (UTF-8) и байты UTF-8 (не зависит от клиента и консоли). COLLATE "default"
    // обязателен: аргумент 'UTF8' имеет тип name с правилом сортировки "C", и результат convert_from наследует "C".
    const r = await c.query(
      `SELECT lower('ЁЯ') = 'ёя' AS lit,
              lower(convert_from('\\xd081d0af'::bytea, 'UTF8') COLLATE "default")
                = convert_from('\\xd191d18f'::bytea, 'UTF8') COLLATE "default" AS bytes,
              upper('ёя') = 'ЁЯ' AS up,
              d.datlocprovider AS provider, d.datlocale AS locale, d.datcollate AS collate, d.datctype AS ctype,
              pg_encoding_to_char(d.encoding) AS enc
         FROM pg_database d WHERE d.datname = current_database()`,
    );
    const g = r.rows[0];
    log(`база ${s.db}: encoding=${g.enc} provider=${g.provider} locale=${g.locale} collate=${g.collate} ctype=${g.ctype}`);
    if (!(g.lit && g.bytes && g.up)) {
      throw new GateError(
        `СТОП: lower('ЁЯ') <> 'ёя' — локаль базы не приводит кириллицу к нижнему регистру (07 §10.1; литерал=${g.lit}, байты=${g.bytes}, upper=${g.up})`,
      );
    }
    if (g.enc !== 'UTF8') throw new GateError(`СТОП: кодировка базы ${g.enc}, нужна UTF8`);
    if (g.provider !== 'b' || g.locale !== 'C.UTF-8') throw new GateError('СТОП: база создана не с LOCALE_PROVIDER builtin C.UTF-8');
    if (g.collate !== 'C') throw new GateError(`СТОП: LC_COLLATE ${g.collate}, нужна C`);
    if (g.ctype === 'C' || g.ctype === 'POSIX') throw new GateError('СТОП: LC_CTYPE C — триграммы и FTS по-русски не работают (16 §4.4)');
    log("стоп-проверка lower('ЁЯ') = 'ёя': пройдена");
    const ext = await c.query('SELECT name, default_version FROM pg_available_extensions WHERE name = ANY($1)', [REQUIRED_EXTENSIONS]);
    const have = new Map(ext.rows.map((x) => [x.name, x.default_version]));
    const missing = REQUIRED_EXTENSIONS.filter((n) => !have.has(n));
    if (missing.length > 0) throw new GateError(`СТОП: нет расширений в сборке PostgreSQL: ${missing.join(', ')}`);
    log(`расширения доступны: ${REQUIRED_EXTENSIONS.map((n) => `${n} ${have.get(n)}`).join(', ')}`);
    const spl = await c.query("SELECT current_setting('shared_preload_libraries') AS v");
    if (!String(spl.rows[0].v).split(',').map((x) => x.trim()).includes('pg_stat_statements')) {
      throw new GateError('СТОП: shared_preload_libraries не содержит pg_stat_statements (optomstroy.conf не подключён?)');
    }
  } finally {
    await c.end();
  }
}

/** Ожидание ошибки PostgreSQL с данным SQLSTATE; иначе — провал проверки. */
async function expectDenied(label, fn, codes = ['42501']) {
  try {
    await fn();
  } catch (e) {
    if (codes.includes(e?.code)) {
      log(`  ok  ${label}: отказ ${e.code}`);
      return;
    }
    throw new Error(`${label}: ожидался отказ ${codes.join('/')}, получено ${e?.code ?? ''} ${e?.message ?? e}`);
  }
  throw new Error(`${label}: операция прошла, а должна быть запрещена`);
}

function ok(label, cond, detail = '') {
  if (!cond) throw new Error(`${label}: не выполнено ${detail}`);
  log(`  ok  ${label}${detail ? ` (${detail})` : ''}`);
}

async function verify(pg, s) {
  const connect = makeClientFactory(pg, s.host, s.port);
  const migPw = readSecret(s.secretsDir, 'db_migrator_password');
  const bkPw = readSecret(s.secretsDir, 'db_backup_password');
  log('проверка прав ролей:');

  const su = await connect(s.superuser, s.suPw, s.db);
  try {
    const r = await su.query(
      `SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls, rolcanlogin,
              rolpassword IS NOT NULL AS has_pw, left(coalesce(rolpassword, ''), 14) AS pw_kind
         FROM pg_authid WHERE rolname = ANY($1) ORDER BY rolname`,
      [ROLES],
    );
    const by = new Map(r.rows.map((x) => [x.rolname, x]));
    for (const n of ROLES) ok(`роль ${n} есть`, by.has(n));
    for (const n of ROLES) {
      const x = by.get(n);
      ok(`роль ${n}: без SUPERUSER/CREATEROLE/CREATEDB/BYPASSRLS`, !x.rolsuper && !x.rolcreaterole && !x.rolcreatedb && !x.rolbypassrls);
      ok(`роль ${n}: REPLICATION только у pos_backup`, x.rolreplication === (n === 'pos_backup'));
    }
    for (const n of ['pos_migrate', 'pos_app', 'pos_backup']) ok(`роль ${n}: пароль SCRAM`, by.get(n).pw_kind === 'SCRAM-SHA-256$');
    ok('роль pos_readonly: без пароля', !by.get('pos_readonly').has_pw);
    const m = await su.query(
      `SELECT pg_get_userbyid(d.datdba) AS db_owner,
              (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'public') AS public_owner,
              has_database_privilege('pos_app', current_database(), 'CREATE') AS app_db_create,
              has_database_privilege('pos_app', current_database(), 'TEMP') AS app_db_temp,
              has_schema_privilege('pos_app', 'public', 'CREATE') AS app_public_create,
              pg_has_role('pos_backup', 'pg_read_all_data', 'MEMBER') AS bk_read_all,
              has_database_privilege('public', current_database(), 'CONNECT') AS public_connect
         FROM pg_database d WHERE d.datname = current_database()`,
    );
    const p = m.rows[0];
    ok('владелец базы — pos_migrate', p.db_owner === 'pos_migrate', p.db_owner);
    ok('владелец схемы public — pos_migrate (pg_database_owner)', p.public_owner === 'pg_database_owner' || p.public_owner === 'pos_migrate', p.public_owner);
    ok('pos_app: нет CREATE на базу, есть TEMPORARY', !p.app_db_create && p.app_db_temp);
    ok('pos_app: нет CREATE в схеме public', !p.app_public_create);
    ok('pos_backup: член pg_read_all_data', p.bk_read_all);
    ok('PUBLIC: нет CONNECT к базе', !p.public_connect);
  } finally {
    await su.end();
  }

  const app = await connect('pos_app', s.url.password, s.db);
  try {
    const who = await app.query('SELECT current_user AS u');
    ok('pos_app входит по паролю из database_url', who.rows[0].u === 'pos_app');
    await expectDenied('pos_app: CREATE TABLE public.x', () => app.query('CREATE TABLE public.optomstroy_probe (id int)'));
    await expectDenied('pos_app: CREATE SCHEMA', () => app.query('CREATE SCHEMA optomstroy_probe'));
    await app.query('CREATE TEMP TABLE optomstroy_probe_tmp (id int)');
    ok('pos_app: временная таблица создаётся (TEMPORARY)', true);
  } finally {
    await app.end();
  }

  const mig = await connect('pos_migrate', migPw, s.db);
  try {
    await mig.query('BEGIN');
    await mig.query('CREATE TABLE public.optomstroy_probe (id int)');
    await mig.query('CREATE SCHEMA optomstroy_probe_schema');
    await mig.query('ROLLBACK');
    ok('pos_migrate: CREATE TABLE в public и CREATE SCHEMA (откатано)', true);
  } finally {
    await mig.end();
  }

  // pos_backup: то, что делает pg_dump, — чтение каждой таблицы и последовательности всех пользовательских схем
  // (в том числе pgboss и pos_meta, на которые GRANT миграций не распространяется) в одной транзакции снимка.
  const bk = await connect('pos_backup', bkPw, s.db);
  let tables = 0;
  let seqs = 0;
  try {
    await bk.query('BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY');
    const t = await bk.query(
      `SELECT c.oid::regclass::text AS rel, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r','p','S','m') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%'
          AND n.nspname NOT LIKE 'pg_temp%' ORDER BY 1`,
    );
    for (const row of t.rows) {
      if (row.relkind === 'S') {
        await bk.query(`SELECT last_value, is_called FROM ${row.rel}`);
        seqs++;
      } else {
        // Без count(*): на рабочей базе (~10 ГБ) полный проход всех таблиц держал бы блокировки ACCESS SHARE
        // (они мешают миграциям и DDL) до конца транзакции. LIMIT 1 уже доказывает право SELECT.
        if (row.relkind !== 'm') await bk.query(`LOCK TABLE ${row.rel} IN ACCESS SHARE MODE`);
        await bk.query(`SELECT * FROM ${row.rel} LIMIT 1`);
        tables++;
      }
    }
    await bk.query('COMMIT');
    ok('pos_backup: чтение всех таблиц и последовательностей (как pg_dump)', true, `таблиц ${tables}, последовательностей ${seqs}`);
    await expectDenied('pos_backup: CREATE TABLE', () => bk.query('CREATE TABLE public.optomstroy_probe2 (id int)'));
  } finally {
    await bk.end();
  }

  // Подключение репликации (pg_basebackup): атрибут REPLICATION + строка `host replication pos_backup` в pg_hba.conf.
  const repl = await connect('pos_backup', bkPw, undefined, { replication: 'true' });
  try {
    const id = await repl.query('IDENTIFY_SYSTEM');
    ok('pos_backup: подключение репликации (IDENTIFY_SYSTEM)', id.rows.length === 1, `timeline ${id.rows[0].timeline}`);
  } finally {
    await repl.end();
  }

  // pos_readonly без пароля: вход по паролю невозможен (scram требует пароль, у роли его нет).
  await expectDenied('pos_readonly: вход по паролю', async () => {
    const c = await connect('pos_readonly', 'x'.repeat(20), s.db);
    await c.end();
  }, ['28P01']);
  log('проверка прав ролей: пройдена');
}

// Архивирование WAL работает: запись в WAL без таблиц (pg_logical_emit_message), pg_switch_wal и ожидание, пока
// archive_command сохранит этот сегмент (pg_stat_archiver). Рост failed_count — провал сразу (обычно — нет прав
// учётной записи службы на node.exe, pos-backup.mjs, backup.json или спул WAL).
async function archiveCheck(pg, s, timeoutMs = 60000) {
  const connect = makeClientFactory(pg, s.host, s.port);
  const c = await connect(s.superuser, s.suPw, 'postgres');
  try {
    const mode = (await c.query("SELECT current_setting('archive_mode') AS m")).rows[0].m;
    if (mode === 'off') {
      log('archive_mode = off — проверка архивирования пропущена (PITR выключен)');
      return;
    }
    const q = 'SELECT archived_count, failed_count, last_archived_wal, last_failed_wal FROM pg_stat_archiver';
    const before = (await c.query(q)).rows[0];
    await c.query("SELECT pg_logical_emit_message(false, 'optomstroy', 'archive-check')");
    const seg = (await c.query('SELECT pg_walfile_name(pg_switch_wal()) AS f')).rows[0].f;
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const st = (await c.query(q)).rows[0];
      if (Number(st.failed_count) > Number(before.failed_count)) {
        throw new Error(`archive_command завершается ошибкой (failed_count ${before.failed_count} → ${st.failed_count}, сегмент ${st.last_failed_wal}); журнал сервера — logs\\pg, права — README «archive_command»`);
      }
      if (st.last_archived_wal !== null && st.last_archived_wal.slice(0, 24) >= seg) {
        log(`архивирование WAL: сегмент ${seg} сохранён (archived_count ${st.archived_count}, failed_count ${st.failed_count})`);
        return;
      }
      if (Date.now() > deadline) throw new Error(`сегмент ${seg} не заархивирован за ${timeoutMs / 1000} с (last_archived_wal ${st.last_archived_wal})`);
      await new Promise((r) => setTimeout(r, 500));
    }
  } finally {
    await c.end();
  }
}

function log(msg) {
  process.stdout.write(`pg-tool: ${msg}\n`);
}

/**
 * Есть ли база из database_url (последняя строка вывода — JSON {"exists":true|false}). Для -ResetStandData install.ps1:
 * копия перед удалением делается, только если база есть (повторный запуск после сбоя — базы уже нет).
 */
async function dbExists(pg, s) {
  const connect = makeClientFactory(pg, s.host, s.port);
  const admin = await connect(s.superuser, s.suPw, 'postgres');
  try {
    const ex = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [s.db]);
    process.stdout.write(`${JSON.stringify({ exists: ex.rowCount > 0 })}\n`);
  } finally {
    await admin.end();
  }
}

/**
 * Удаление базы стенда (install.ps1 -Stand -ResetStandData): только с --confirm <имя базы>; подключения к базе
 * закрываются (WITH (FORCE)). Роли и кластер не трогаются; базу заново создаёт setup (apply-roles.ps1).
 */
async function dropDb(pg, s, confirm) {
  if (confirm !== s.db) throw new UsageError(`drop-db: подтвердите удаление именем базы: --confirm ${s.db}`);
  const connect = makeClientFactory(pg, s.host, s.port);
  const admin = await connect(s.superuser, s.suPw, 'postgres');
  try {
    const ex = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [s.db]);
    if (ex.rowCount === 0) {
      log(`базы ${s.db} нет — удалять нечего`);
      return;
    }
    await admin.query(`DROP DATABASE "${s.db}" WITH (FORCE)`); // имя проверено DB_NAME_RE (settings)
    log(`база ${s.db} удалена`);
  } finally {
    await admin.end();
  }
}

async function main() {
  let parsed;
  try {
    parsed = parseArgs(process.argv.slice(2));
    if (!['setup', 'gate', 'verify', 'archive', 'db-exists', 'drop-db'].includes(parsed.cmd)) {
      throw new UsageError('использование: pg-tool.mjs setup|gate|verify|archive|db-exists|drop-db --modules <папка api> --secrets <папка> [--port 5433] [--superuser postgres] [--db имя] [--ctype en-US] [--roles-sql путь] [--confirm <имя базы> — для drop-db]');
    }
  } catch (e) {
    process.stderr.write(`pg-tool: ${e.message}\n`);
    return 2;
  }
  const { cmd, opts } = parsed;
  try {
    const pg = loadPg(need(opts, 'modules'));
    const s = settings(opts);
    if (cmd === 'setup') await setup(pg, s, opts['roles-sql'] ?? join(HERE, 'roles.sql'));
    else if (cmd === 'gate') await gate(pg, s);
    else if (cmd === 'archive') await archiveCheck(pg, s);
    else if (cmd === 'db-exists') await dbExists(pg, s);
    else if (cmd === 'drop-db') await dropDb(pg, s, opts.confirm);
    else await verify(pg, s);
    return 0;
  } catch (e) {
    if (e instanceof UsageError) {
      process.stderr.write(`pg-tool: ${e.message}\n`);
      return 2;
    }
    if (e instanceof GateError) {
      process.stderr.write(`pg-tool: ${e.message}\n`);
      return 3;
    }
    // Сообщения PostgreSQL не содержат паролей (на сервер уходят только верификаторы).
    process.stderr.write(`pg-tool: ошибка: ${e?.code ? `[${e.code}] ` : ''}${e?.message ?? e}\n`);
    return 1;
  }
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main();
}
