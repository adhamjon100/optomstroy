// Помощник проверочного прогона infra/windows/tests/postgres.tests.ps1 (только тест, на сервер не нужен).
// Подключается суперпользователем (пароль — из файла секрета pg_password) и выполняет одну проверку:
//   settings              — печатает JSON с параметрами сервера (listen_addresses, archive_command, …);
//   make-bad-db <имя>     — создаёт базу с локалью libc C (для отрицательной проверки стоп-условия локали);
//   archive-check <спул>  — пишет данные, переключает WAL и ждёт, пока сегмент окажется в спуле (failed_count = 0).
// Аргументы: <команда> --modules <папка api> --secrets <папка> --port <порт> [--db <база>] [--arg <значение>]
import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';

const argv = process.argv.slice(2);
const cmd = argv[0];
const o = {};
for (let i = 1; i < argv.length; i += 2) o[argv[i].replace(/^--/, '')] = argv[i + 1];
const pg = createRequire(join(resolve(o.modules), 'noop.cjs'))('pg');
const pw = readFileSync(join(o.secrets, 'pg_password'), 'utf8').replace(/[\r\n]/g, '');
const client = (db) => new pg.Client({ host: '127.0.0.1', port: Number(o.port), user: 'postgres', password: pw, database: db ?? 'postgres' });

const c = client(o.db);
await c.connect();
try {
  if (cmd === 'settings') {
    const names = ['listen_addresses', 'port', 'password_encryption', 'archive_mode', 'archive_command', 'wal_level', 'data_checksums',
      'shared_preload_libraries', 'shared_buffers', 'timezone', 'server_version', 'log_directory', 'unix_socket_directories'];
    const r = await c.query('SELECT lower(name) AS name, setting FROM pg_settings WHERE lower(name) = ANY($1)', [names]);
    const hba = await c.query('SELECT type, database, user_name, address, auth_method FROM pg_hba_file_rules ORDER BY rule_number');
    const db = await c.query(`SELECT datname, datlocprovider, datlocale, datcollate, datctype FROM pg_database WHERE datname IN ('postgres','template1')`);
    process.stdout.write(JSON.stringify({ settings: Object.fromEntries(r.rows.map((x) => [x.name, x.setting])), hba: hba.rows, dbs: db.rows }) + '\n');
  } else if (cmd === 'make-bad-db') {
    if (!/^[a-z_]+$/.test(o.arg)) throw new Error('bad name');
    await c.query(`CREATE DATABASE "${o.arg}" TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER libc LC_COLLATE 'C' LC_CTYPE 'C'`);
    process.stdout.write('created\n');
  } else if (cmd === 'archive-check') {
    const before = (await c.query('SELECT archived_count, failed_count FROM pg_stat_archiver')).rows[0];
    await c.query('CREATE TABLE IF NOT EXISTS public.optomstroy_wal_probe (id int)');
    await c.query('INSERT INTO public.optomstroy_wal_probe SELECT generate_series(1, 1000)');
    const seg = (await c.query('SELECT pg_walfile_name(pg_switch_wal()) AS f')).rows[0].f;
    const deadline = Date.now() + 30000;
    let st;
    while (Date.now() < deadline) {
      st = (await c.query('SELECT archived_count, failed_count, last_archived_wal, last_failed_wal FROM pg_stat_archiver')).rows[0];
      if (Number(st.archived_count) > Number(before.archived_count) && existsSync(join(o.arg, seg))) break;
      await new Promise((r) => setTimeout(r, 500));
    }
    await c.query('DROP TABLE public.optomstroy_wal_probe');
    const ok = existsSync(join(o.arg, seg)) && Number(st.failed_count) === 0;
    process.stdout.write(JSON.stringify({ segment: seg, inSpool: existsSync(join(o.arg, seg)), ...st }) + '\n');
    process.exitCode = ok ? 0 : 1;
  } else {
    throw new Error(`неизвестная команда ${cmd}`);
  }
} finally {
  await c.end();
}
