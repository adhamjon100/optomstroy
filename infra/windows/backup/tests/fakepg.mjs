// Подмена psql.exe и pg_restore.exe для проверок на ПК разработчика: в наборе @embedded-postgres этих программ нет.
// Запускается из fakepg.exe (собирается csc.exe в tests/drill.test.mjs) как `node fakepg.mjs <psql|pg_restore> <аргументы>`.
// SQL выполняется НАСТОЯЩИМ PostgreSQL через модуль pg из pos-api; «дамп» для pg_restore — открытый SQL-текст в stdin
// (формат -Fc не воспроизводится: проверяются скрипты вокруг pg_restore, а не сам pg_restore).
//   psql: -h -p -U -d, -f <файл> или -c <запрос>, -v ON_ERROR_STOP=1, -A -t (строки «a|b|c»), -X -q -w — без действия;
//   pg_restore: -h -p -U -d, --exit-on-error; SQL из stdin.
// Пароль — PGPASSWORD или файл PGPASSFILE (формат pgpass). Коды: 0 — успех; psql 3 — ошибка при ON_ERROR_STOP,
// 2 — нет подключения; pg_restore 1 — ошибка.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(here, '..', '..', '..', '..');
const require = createRequire(path.join(REPO, 'pos-api', 'package.json'));
const { Client } = require('pg');

const [tool, ...argv] = process.argv.slice(2);
const o = { h: '127.0.0.1', p: '5432', U: 'postgres', d: 'postgres', v: [] };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  const m = /^-([hpUdfcv])$/.exec(a);
  if (m) {
    const val = argv[++i];
    if (m[1] === 'v') o.v.push(val);
    else o[m[1]] = val;
  } else if (/^--dbname=/.test(a)) o.d = a.slice(9);
}

function password() {
  if (process.env.PGPASSWORD) return process.env.PGPASSWORD;
  const f = process.env.PGPASSFILE;
  if (!f || !fs.existsSync(f)) return undefined;
  for (const line of fs.readFileSync(f, 'utf8').split(/\r?\n/)) {
    const [h, p, d, u, ...pw] = line.split(':');
    const ok = (x, want) => x === '*' || x === want;
    if (pw.length && ok(h, o.h) && ok(p, String(o.p)) && ok(d, o.d) && ok(u, o.U)) return pw.join(':');
  }
  return undefined;
}

// Разбиение на операторы: «;» в конце строки вне $…$ (блоки DO и функции).
function splitSql(sql) {
  const out = [];
  let buf = [];
  let inDollar = false;
  for (const line of sql.replace(/^﻿/, '').split(/\r?\n/)) {
    buf.push(line);
    for (const _ of line.matchAll(/\$[A-Za-z_]*\$/g)) inDollar = !inDollar;
    if (!inDollar && /;\s*$/.test(line)) {
      const s = buf.join('\n').trim();
      if (s) out.push(s);
      buf = [];
    }
  }
  const rest = buf.join('\n').trim();
  if (rest) out.push(rest);
  return out;
}

const cell = (v) => (v === null ? '' : v === true ? 't' : v === false ? 'f' : String(v));

async function main() {
  let sql;
  if (tool === 'psql') sql = o.f ? fs.readFileSync(o.f, 'utf8') : o.c ?? '';
  else if (tool === 'pg_restore') sql = fs.readFileSync(0, 'utf8');
  else {
    process.stderr.write(`fakepg: неизвестная программа ${tool}\n`);
    return 2;
  }
  const stop = tool === 'pg_restore' || o.v.includes('ON_ERROR_STOP=1');
  const c = new Client({ host: o.h, port: Number(o.p), user: o.U, password: password(), database: o.d });
  try {
    await c.connect();
  } catch (e) {
    process.stderr.write(`${tool}: error: connection to server failed: ${e.message}\n`);
    return 2;
  }
  let failed = false;
  let last = null;
  try {
    for (const s of splitSql(sql)) {
      try {
        last = await c.query({ text: s, rowMode: 'array' });
      } catch (e) {
        failed = true;
        process.stderr.write(`${tool}: ERROR: ${e.message}\n`);
        if (stop) return tool === 'psql' ? 3 : 1;
      }
    }
  } finally {
    await c.end();
  }
  if (tool === 'psql' && last?.rows?.length) {
    for (const r of last.rows) process.stdout.write(`${r.map(cell).join('|')}\n`);
  }
  return failed && tool === 'pg_restore' ? 1 : 0;
}

main().then((code) => process.exit(code), (e) => {
  process.stderr.write(`fakepg: ${e.message}\n`);
  process.exit(2);
});
