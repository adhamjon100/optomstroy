// ops-tool.mjs — служебный инструмент скриптов установки Optomstroy под Windows Server (install.ps1, update.ps1,
// rollback.ps1, status.ps1, build-release.ps1). Запускается на node.exe из релиза, пакетов npm не требует; модуль pg
// берётся из папки api релиза (--modules). Значения секретов НЕ печатаются никогда: в выводе — только имена файлов.
//
// Команды (вывод — одна строка JSON в stdout; сообщения об ошибках — stderr):
//   gen-secrets --dir <secrets> --kid <JWT_KEY_ID> --db <база> --port <порт> [--cluster-exists]
//        создаёт недостающие секреты, как install.sh Linux-комплекта: pg_password, db_migrator_password,
//        db_backup_password (24 байта hex), database_url (pos_app@127.0.0.1:<порт>/<база>), otp_pepper, pin_pepper
//        (32 байта hex), jwt_private.pem (EC P-256, PKCS#8), jwt_public.json ({kid: PEM}), pgpass_backup.conf.
//        --cluster-exists: кластер PostgreSQL уже создан — нет pg_password/db_migrator_password/database_url → код 3
//        (новые значения не совпали бы с паролями ролей в базе).
//        --no-new-peppers: в BackupRoot уже есть копии базы — нет otp_pepper/pin_pepper → код 3 (восстановление: хэши
//        PIN и аварийных кодов из копий проверяются только старыми перцами).
//   secrets-export --dir <secrets> --public <backup-public.pem> --out-dir <папка> [--force] [--optbk <optbk.mjs>]
//        зашифрованная копия всех файлов secrets (OPTBK1, открытый ключ резервных копий), если состав изменился
//   secrets-import --in <расшифрованный secrets.json> --dir <secrets> [--overwrite]
//        возврат секретов из копии (расшифровка — pos-backup.mjs decrypt на ПК держателя ключа); код 1 — конфликт
//   check-secrets --dir <secrets> --db <база> --port <порт>
//        согласованность: database_url указывает на 127.0.0.1:<порт>/<база> и роль pos_app, pgpass_backup.conf
//        совпадает с db_backup_password, jwt_public.json содержит открытый ключ jwt_private.pem. Код 1 — расхождение.
//   sums-write --dir <папка> --out <файл>   SHA256SUMS (формат sha256sum: «<hex>  <путь/через/слеш>»)
//   sums-verify --dir <папка> [--sums <файл>]   сверка всех файлов и отсутствие лишних; код 1 — расхождение
//   db <подкоманда> --modules <api> --secrets <secrets> --port <порт> [--db <база>] [--superuser postgres]
//        state                       журнал миграций (pos_meta.schema_migrations) и версия схемы pg-boss
//        snapshot-create --name <имя> копия базы CREATE DATABASE … TEMPLATE (обновление: откат без ключа расшифровки)
//        snapshot-swap --name <имя> --failed-name <имя>  вернуть копию на место рабочей базы (рабочая переименовывается)
//        snapshot-drop --name <имя>
//        snapshots                   список копий <база>_preupd_*
// Коды выхода: 0 — успех; 1 — ошибка; 2 — неверный вызов; 3 — нужен секрет из защищённой копии.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

class UsageError extends Error {}

function parseArgs(argv) {
  const opts = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) opts[k] = true;
      else {
        opts[k] = next;
        i++;
      }
    } else opts._.push(a);
  }
  return opts;
}

function need(opts, k) {
  const v = opts[k];
  if (typeof v !== 'string' || v === '') throw new UsageError(`нужен --${k}`);
  return v;
}

const DB_RE = /^[a-z_][a-z0-9_]{0,62}$/;
const out = (o) => process.stdout.write(JSON.stringify(o) + '\n');

// ---------- секреты ----------
function readSecret(dir, name) {
  const p = path.join(dir, name);
  if (!fs.existsSync(p)) return null;
  const t = fs.readFileSync(p, 'utf8').replace(/\r?\n$/, '');
  return t === '' ? null : t;
}

// Запись без гонки: временный файл в той же папке (права наследуются от закрытой папки secrets), затем rename.
function writeSecret(dir, name, value) {
  const tmp = path.join(dir, `.${name}.${crypto.randomBytes(4).toString('hex')}.tmp`);
  fs.writeFileSync(tmp, value, { flag: 'wx' });
  fs.renameSync(tmp, path.join(dir, name));
}

function jwtPublicJson(kid, privatePem) {
  const pub = crypto.createPublicKey(crypto.createPrivateKey(privatePem)).export({ type: 'spki', format: 'pem' });
  return JSON.stringify({ [kid]: String(pub) }) + '\n';
}

function parseDbUrl(raw) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    throw new Error('database_url: не удалось разобрать строку подключения');
  }
  return {
    user: decodeURIComponent(u.username),
    password: decodeURIComponent(u.password),
    host: u.hostname,
    port: u.port === '' ? 5432 : Number(u.port),
    db: u.pathname.replace(/^\//, ''),
  };
}

function cmdGenSecrets(opts) {
  const dir = need(opts, 'dir');
  const kid = need(opts, 'kid');
  const db = need(opts, 'db');
  const port = Number(need(opts, 'port'));
  if (!/^[A-Za-z0-9._-]+$/.test(kid)) throw new UsageError('--kid: только латиница, цифры, . _ -');
  if (!DB_RE.test(db)) throw new UsageError('--db: латиница в нижнем регистре, цифры, _');
  if (!fs.existsSync(dir)) throw new UsageError(`нет папки секретов ${dir}`);
  if (opts['cluster-exists']) {
    const missing = ['pg_password', 'db_migrator_password', 'database_url'].filter((n) => readSecret(dir, n) === null);
    if (missing.length) {
      process.stderr.write(`кластер PostgreSQL уже создан, а секретов нет: ${missing.join(', ')} — восстановите их из защищённой копии, новые не создаются\n`);
      return 3;
    }
  }
  if (opts['no-new-peppers']) {
    // В BackupRoot уже есть копии базы: хэши PIN и аварийных кодов посчитаны со старыми перцами (восстановление).
    const missing = ['otp_pepper', 'pin_pepper'].filter((n) => readSecret(dir, n) === null);
    if (missing.length) {
      process.stderr.write(`есть резервные копии базы, а секретов нет: ${missing.join(', ')} — восстановите secrets из защищённой копии (secrets-import), новые не создаются\n`);
      return 3;
    }
  }
  const created = [];
  const hex = (n) => crypto.randomBytes(n).toString('hex');
  for (const [name, bytes] of [['pg_password', 24], ['db_migrator_password', 24], ['db_backup_password', 24], ['otp_pepper', 32], ['pin_pepper', 32]]) {
    if (readSecret(dir, name) === null) {
      writeSecret(dir, name, hex(bytes) + '\n');
      created.push(name);
    }
  }
  if (readSecret(dir, 'database_url') === null) {
    writeSecret(dir, 'database_url', `postgres://pos_app:${hex(24)}@127.0.0.1:${port}/${db}\n`);
    created.push('database_url');
  }
  if (readSecret(dir, 'jwt_private.pem') === null) {
    const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
    writeSecret(dir, 'jwt_private.pem', String(privateKey.export({ type: 'pkcs8', format: 'pem' })));
    created.push('jwt_private.pem');
    if (fs.existsSync(path.join(dir, 'jwt_public.json'))) fs.rmSync(path.join(dir, 'jwt_public.json'));
  }
  if (readSecret(dir, 'jwt_public.json') === null) {
    writeSecret(dir, 'jwt_public.json', jwtPublicJson(kid, readSecret(dir, 'jwt_private.pem')));
    created.push('jwt_public.json');
  }
  const bk = readSecret(dir, 'db_backup_password');
  const pgpassWanted = `127.0.0.1:${port}:*:pos_backup:${bk}\n`;   // check-secrets: allow — шаблон строки pgpass, пароль из файла секрета
  const pgpassNow = fs.existsSync(path.join(dir, 'pgpass_backup.conf')) ? fs.readFileSync(path.join(dir, 'pgpass_backup.conf'), 'utf8') : null;
  if (pgpassNow !== pgpassWanted) {
    writeSecret(dir, 'pgpass_backup.conf', pgpassWanted);
    created.push('pgpass_backup.conf');
  }
  out({ created });
  return 0;
}

function cmdCheckSecrets(opts) {
  const dir = need(opts, 'dir');
  const db = need(opts, 'db');
  const port = Number(need(opts, 'port'));
  const problems = [];
  for (const n of ['pg_password', 'db_migrator_password', 'db_backup_password', 'database_url', 'otp_pepper', 'pin_pepper', 'jwt_private.pem', 'jwt_public.json', 'pgpass_backup.conf']) {
    if (readSecret(dir, n) === null) problems.push(`нет или пуст: ${n}`);
  }
  const url = readSecret(dir, 'database_url');
  if (url !== null) {
    try {
      const u = parseDbUrl(url);
      if (u.user !== 'pos_app') problems.push('database_url: пользователь должен быть pos_app');
      if (u.host !== '127.0.0.1') problems.push('database_url: хост должен быть 127.0.0.1');
      if (u.port !== port) problems.push(`database_url: порт не ${port}`);
      if (u.db !== db) problems.push(`database_url: база не ${db}`);
      if (u.password.length < 16) problems.push('database_url: пароль pos_app короче 16 символов');
    } catch (e) {
      problems.push(e.message);
    }
  }
  const bk = readSecret(dir, 'db_backup_password');
  const pgpass = readSecret(dir, 'pgpass_backup.conf');
  if (bk !== null && pgpass !== null && pgpass !== `127.0.0.1:${port}:*:pos_backup:${bk}`) problems.push('pgpass_backup.conf не совпадает с db_backup_password (или другой порт)');
  const priv = readSecret(dir, 'jwt_private.pem');
  const pubJson = readSecret(dir, 'jwt_public.json');
  if (priv !== null && pubJson !== null) {
    try {
      const want = String(crypto.createPublicKey(crypto.createPrivateKey(priv)).export({ type: 'spki', format: 'pem' })).trim();
      const set = JSON.parse(pubJson);
      if (!Object.values(set).some((v) => String(v).trim() === want)) problems.push('jwt_public.json не содержит открытый ключ jwt_private.pem');
    } catch {
      problems.push('jwt_private.pem или jwt_public.json не разбираются');
    }
  }
  out({ ok: problems.length === 0, problems });
  return problems.length === 0 ? 0 : 1;
}

// ---------- защищённая копия secrets ----------
// Формат: JSON {kind, version, createdUtc, files: [{name, base64}]}, зашифрованный OPTBK1 открытым ключом резервных
// копий (backup-public.pem; закрытый — только у держателя ключа). Расшифровка — на ПК держателя ключа:
// pos-backup.mjs decrypt --key backup-private.pem <файл .optbk> <secrets.json>; возврат на сервер — secrets-import.
const SECRETS_BUNDLE_KIND = 'optomstroy-secrets'; // check-secrets: allow — метка формата копии, не значение
const SECRET_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$/;

async function loadOptbk(opts) {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const file = typeof opts.optbk === 'string' ? path.resolve(opts.optbk) : path.join(here, '..', 'backup', 'lib', 'optbk.mjs');
  if (!fs.existsSync(file)) throw new Error(`нет ${file} (модуль шифрования OPTBK1 из backup\\lib)`);
  return import(pathToFileURL(file).href);
}

function secretEntries(dir) {
  return fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && !e.name.startsWith('.') && !e.name.endsWith('.tmp') && SECRET_NAME_RE.test(e.name))
    .map((e) => e.name)
    .sort();
}

// secrets-export --dir <secrets> --public <backup-public.pem> --out-dir <папка> [--force]
// Новая зашифрованная копия, только если состав secrets (имя, размер, время изменения) или ключ изменились с прошлой
// (отметка last-export.json — без значений и без производных от них). Старые копии не удаляются.
async function cmdSecretsExport(opts) {
  const dir = path.resolve(need(opts, 'dir'));
  const pubFile = path.resolve(need(opts, 'public'));
  const outDir = path.resolve(need(opts, 'out-dir'));
  const { encryptStream, loadPublicKey, publicKeyId, inspectStream } = await loadOptbk(opts);
  const pub = loadPublicKey(pubFile);
  const keyId = publicKeyId(pub).toString('hex');
  const names = secretEntries(dir);
  if (!names.length) throw new UsageError(`в ${dir} нет секретов`);
  const sig = names.map((n) => {
    const st = fs.statSync(path.join(dir, n));
    return `${n}:${st.size}:${Math.trunc(st.mtimeMs)}`;
  });
  fs.mkdirSync(outDir, { recursive: true });
  const markFile = path.join(outDir, 'last-export.json');
  let mark = null;
  try {
    mark = JSON.parse(fs.readFileSync(markFile, 'utf8'));
  } catch {
    mark = null;
  }
  if (!opts.force && mark && mark.keyId === keyId && JSON.stringify(mark.files) === JSON.stringify(sig) && fs.existsSync(path.join(outDir, String(mark.file)))) {
    out({ exported: null, unchanged: true, file: path.join(outDir, String(mark.file)), keyId, files: names.length });
    return 0;
  }
  const bundle = {
    kind: SECRETS_BUNDLE_KIND,
    version: 1,
    createdUtc: new Date().toISOString(),
    files: names.map((n) => ({ name: n, base64: fs.readFileSync(path.join(dir, n)).toString('base64') })),
  };
  const stampStr = new Date().toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 15);
  const name = `secrets-${stampStr}.json.optbk`;
  const dst = path.join(outDir, name);
  const tmp = `${dst}.partial`;
  try {
    await pipeline(Readable.from([Buffer.from(JSON.stringify(bundle), 'utf8')]), encryptStream(pub), fs.createWriteStream(tmp, { flags: 'wx' }));
    const fd = fs.openSync(tmp, 'r+');
    try {
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    const info = await inspectStream(fs.createReadStream(tmp));
    if (info.keyId !== keyId) throw new Error('keyId записанной копии не совпал с ключом');
    if (fs.existsSync(dst)) throw new Error(`${dst} уже есть`);
    fs.renameSync(tmp, dst);
  } catch (e) {
    fs.rmSync(tmp, { force: true });
    throw e;
  }
  bundle.files = null;
  fs.writeFileSync(markFile, JSON.stringify({ file: name, keyId, files: sig, createdUtc: bundle.createdUtc }) + '\n');
  out({ exported: dst, unchanged: false, keyId, files: names.length, bytes: fs.statSync(dst).size });
  return 0;
}

// secrets-import --in <расшифрованный secrets.json> --dir <secrets> [--overwrite]
// Возвращает файлы секретов. Существующий файл с другим содержимым — код 1 (без --overwrite), совпадающий — пропуск.
function cmdSecretsImport(opts) {
  const inp = path.resolve(need(opts, 'in'));
  const dir = path.resolve(need(opts, 'dir'));
  let bundle;
  try {
    bundle = JSON.parse(fs.readFileSync(inp, 'utf8'));
  } catch {
    throw new UsageError(`${inp}: не JSON (расшифруйте копию: pos-backup.mjs decrypt --key <закрытый.pem> <файл .optbk> <выход>)`);
  }
  if (bundle?.kind !== SECRETS_BUNDLE_KIND || bundle.version !== 1 || !Array.isArray(bundle.files)) throw new UsageError(`${inp}: не копия secrets Optomstroy`);
  if (!fs.existsSync(dir)) throw new UsageError(`нет папки секретов ${dir}`);
  const written = [];
  const same = [];
  const conflicts = [];
  for (const f of bundle.files) {
    if (typeof f?.name !== 'string' || !SECRET_NAME_RE.test(f.name) || typeof f.base64 !== 'string') throw new UsageError('копия secrets повреждена: неверная запись файла');
    const data = Buffer.from(f.base64, 'base64');
    const p = path.join(dir, f.name);
    if (fs.existsSync(p)) {
      if (Buffer.compare(fs.readFileSync(p), data) === 0) {
        same.push(f.name);
        continue;
      }
      if (!opts.overwrite) {
        conflicts.push(f.name);
        continue;
      }
    }
    writeSecret(dir, f.name, data);
    written.push(f.name);
  }
  out({ written, same, conflicts, createdUtc: bundle.createdUtc ?? null });
  if (conflicts.length) process.stderr.write(`уже есть с другим содержимым (не заменены; --overwrite — заменить): ${conflicts.join(', ')}\n`);
  return conflicts.length ? 1 : 0;
}

// ---------- SHA256SUMS ----------
function listFiles(root) {
  const res = [];
  const walk = (d, rel) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isSymbolicLink()) throw new Error(`ссылка в релизе не допускается: ${r}`);
      if (e.isDirectory()) walk(p, r);
      else if (e.isFile()) res.push(r);
    }
  };
  walk(root, '');
  return res.sort();
}

const BIG = Buffer.allocUnsafe(4 << 20);
function sha256(file) {
  const h = crypto.createHash('sha256');
  const fd = fs.openSync(file, 'r');
  try {
    let n;
    while ((n = fs.readSync(fd, BIG, 0, BIG.length, null)) > 0) h.update(BIG.subarray(0, n));
  } finally {
    fs.closeSync(fd);
  }
  return h.digest('hex');
}

function cmdSumsWrite(opts) {
  const dir = path.resolve(need(opts, 'dir'));
  const outFile = path.resolve(need(opts, 'out'));
  const lines = [];
  let bytes = 0;
  for (const r of listFiles(dir)) {
    const full = path.join(dir, ...r.split('/'));
    if (path.resolve(full) === outFile) continue;
    lines.push(`${sha256(full)}  ${r}`);
    bytes += fs.statSync(full).size;
  }
  fs.writeFileSync(outFile, lines.join('\n') + '\n');
  out({ files: lines.length, bytes });
  return 0;
}

function cmdSumsVerify(opts) {
  const dir = path.resolve(need(opts, 'dir'));
  const sumsFile = path.resolve(typeof opts.sums === 'string' ? opts.sums : path.join(dir, 'SHA256SUMS.txt'));
  const want = new Map();
  for (const line of fs.readFileSync(sumsFile, 'utf8').split(/\r?\n/)) {
    if (!line) continue;
    const m = /^([0-9a-f]{64}) {2}(.+)$/.exec(line);
    if (!m) throw new Error(`строка SHA256SUMS не разобрана: ${line.slice(0, 80)}`);
    want.set(m[2], m[1]);
  }
  const problems = [];
  const have = listFiles(dir).filter((r) => path.resolve(path.join(dir, ...r.split('/'))) !== sumsFile);
  for (const r of have) {
    const w = want.get(r);
    if (w === undefined) problems.push(`лишний файл: ${r}`);
    else if (sha256(path.join(dir, ...r.split('/'))) !== w) problems.push(`SHA256 не совпадает: ${r}`);
    want.delete(r);
  }
  for (const r of want.keys()) problems.push(`нет файла: ${r}`);
  out({ ok: problems.length === 0, files: have.length, problems: problems.slice(0, 50), problemCount: problems.length });
  return problems.length === 0 ? 0 : 1;
}

// ---------- база ----------
function loadPg(modules) {
  const req = createRequire(path.join(path.resolve(modules), 'package.json'));
  return req('pg');
}

async function withClient(opts, dbName, fn) {
  const pg = loadPg(need(opts, 'modules'));
  const dir = need(opts, 'secrets');
  const password = readSecret(dir, 'pg_password');
  if (password === null) throw new Error('нет секрета pg_password');
  const client = new pg.Client({
    host: '127.0.0.1',
    port: Number(need(opts, 'port')),
    user: typeof opts.superuser === 'string' ? opts.superuser : 'postgres',
    password,
    database: dbName,
    application_name: 'optomstroy-ops',
    connectionTimeoutMillis: 10000,
  });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end().catch(() => undefined);
  }
}

function dbName(opts) {
  let db = typeof opts.db === 'string' ? opts.db : null;
  if (db === null) {
    const url = readSecret(need(opts, 'secrets'), 'database_url');
    if (url === null) throw new Error('нет секрета database_url');
    db = parseDbUrl(url).db;
  }
  if (!DB_RE.test(db)) throw new UsageError('имя базы: латиница в нижнем регистре, цифры, _');
  return db;
}

const ident = (s) => {
  if (!DB_RE.test(s)) throw new UsageError(`недопустимое имя базы: ${s}`);
  return `"${s}"`;
};

async function terminate(client, names) {
  await client.query('SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = ANY($1) AND pid <> pg_backend_pid()', [names]);
}

async function dbExists(client, name) {
  return (await client.query('SELECT 1 FROM pg_database WHERE datname = $1', [name])).rowCount === 1;
}

async function cmdDb(sub, opts) {
  const db = dbName(opts);
  switch (sub) {
    case 'state': {
      const res = await withClient(opts, db, async (c) => {
        const hasJournal = (await c.query("SELECT to_regclass('pos_meta.schema_migrations') IS NOT NULL AS ok")).rows[0].ok;
        const migrations = hasJournal ? (await c.query('SELECT version FROM pos_meta.schema_migrations ORDER BY version')).rows.map((r) => r.version) : [];
        const hasBoss = (await c.query("SELECT to_regclass('pgboss.version') IS NOT NULL AS ok")).rows[0].ok;
        const pgboss = hasBoss ? String((await c.query('SELECT version FROM pgboss.version LIMIT 1')).rows[0]?.version ?? '') : null;
        const size = Number((await c.query('SELECT pg_database_size(current_database()) AS s')).rows[0].s);
        return { db, migrations, pgboss, sizeBytes: size };
      });
      out(res);
      return 0;
    }
    case 'snapshot-create': {
      const name = need(opts, 'name');
      await withClient(opts, 'postgres', async (c) => {
        if (await dbExists(c, name)) throw new Error(`база ${name} уже есть`);
        // CREATE DATABASE … TEMPLATE требует, чтобы к исходной базе никто не был подключён (api и worker остановлены;
        // служба резервного копирования подключается на секунды — повторяем).
        let lastErr = null;
        for (let i = 0; i < 5; i++) {
          await terminate(c, [db]);
          try {
            await c.query(`CREATE DATABASE ${ident(name)} TEMPLATE ${ident(db)} OWNER pos_migrate`);
            lastErr = null;
            break;
          } catch (e) {
            lastErr = e;
            await new Promise((r) => setTimeout(r, 1000));
          }
        }
        if (lastErr) throw lastErr;
      });
      out({ created: name });
      return 0;
    }
    case 'snapshot-swap': {
      const name = need(opts, 'name');
      const failed = need(opts, 'failed-name');
      await withClient(opts, 'postgres', async (c) => {
        if (!(await dbExists(c, name))) throw new Error(`копии ${name} нет`);
        if (await dbExists(c, failed)) throw new Error(`база ${failed} уже есть`);
        let lastErr = null;
        for (let i = 0; i < 5; i++) {
          await terminate(c, [db, name]);
          try {
            await c.query(`ALTER DATABASE ${ident(db)} RENAME TO ${ident(failed)}`);
            lastErr = null;
            break;
          } catch (e) {
            lastErr = e;
            await new Promise((r) => setTimeout(r, 1000));
          }
        }
        if (lastErr) throw lastErr;
        await c.query(`ALTER DATABASE ${ident(name)} RENAME TO ${ident(db)}`);
      });
      out({ restored: db, from: name, failedKeptAs: failed });
      return 0;
    }
    case 'snapshot-drop': {
      const name = need(opts, 'name');
      if (name === db) throw new UsageError('рабочую базу удалять нельзя');
      await withClient(opts, 'postgres', async (c) => {
        await c.query(`DROP DATABASE IF EXISTS ${ident(name)} WITH (FORCE)`);
      });
      out({ dropped: name });
      return 0;
    }
    case 'snapshots': {
      const rows = await withClient(opts, 'postgres', async (c) =>
        (await c.query("SELECT datname, pg_database_size(datname) AS s FROM pg_database WHERE datname LIKE $1 ORDER BY datname", [`${db}\\_%`])).rows,
      );
      out({ db, others: rows.map((r) => ({ name: r.datname, sizeBytes: Number(r.s) })) });
      return 0;
    }
    default:
      throw new UsageError(`неизвестная подкоманда db «${sub ?? ''}»`);
  }
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const opts = parseArgs(rest);
  switch (cmd) {
    case 'gen-secrets': return cmdGenSecrets(opts);
    case 'check-secrets': return cmdCheckSecrets(opts);
    case 'secrets-export': return cmdSecretsExport(opts);
    case 'secrets-import': return cmdSecretsImport(opts);
    case 'sums-write': return cmdSumsWrite(opts);
    case 'sums-verify': return cmdSumsVerify(opts);
    case 'db': return cmdDb(opts._[0], opts);
    default: throw new UsageError(`неизвестная команда «${cmd ?? ''}». Команды: gen-secrets, check-secrets, secrets-export, secrets-import, sums-write, sums-verify, db`);
  }
}

main().then(
  (code) => process.exit(code ?? 0),
  (e) => {
    // Сообщения pg и наши — без значений секретов (пароль в текст ошибки pg не попадает).
    process.stderr.write(`ops-tool: ${e instanceof Error ? e.message : String(e)}\n`);
    process.exit(e instanceof UsageError ? 2 : 1);
  },
);
