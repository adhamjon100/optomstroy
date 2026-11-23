// Помощники тестов: имитатор в процессе теста, запуск программы отдельным процессом, временные настройки.
// Данные тестов — явно вымышленные.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { startMock } from '../../src/mock/server.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const CHECK_DIR = path.resolve(HERE, '..', '..');
export const MAIN = path.join(CHECK_DIR, 'src', 'main.mjs');
export const SAMPLES = path.join(CHECK_DIR, 'contract', '1.2.0', 'obrazcy_json');

export function tmpDir(prefix) {
  return fs.mkdtempSync(path.join(process.env.TEMP || os.tmpdir(), prefix));
}

export async function mockWithSecrets(opts = {}) {
  const password = opts.password || 'Test-Parol-' + crypto.randomBytes(6).toString('hex');
  const clientKey = opts.clientKey || 'Test-Klyuch-' + crypto.randomBytes(8).toString('hex');
  const mock = await startMock({ samplesDir: SAMPLES, password, clientKey, ...opts });
  return { mock, password, clientKey };
}

/** Каталог с nastrojki.json и файлами секретов (секреты — в отдельных файлах, как в инструкции). */
export function makeConfig(dir, { baseUrl, password, clientKey, extra = {} }) {
  fs.writeFileSync(path.join(dir, 'parol.txt'), password + '\r\n');
  fs.writeFileSync(path.join(dir, 'klyuch.txt'), clientKey + '\n');
  const cfg = {
    settingsVersion: 1, baseUrl, user: 'pos_hs', auth: 'basic', passwordFile: 'parol.txt', clientKeyFile: 'klyuch.txt', // check-secrets: allow — вымышленное тестовое значение, не секрет
    outDir: 'protokoly', ...extra,
  };
  const file = path.join(dir, 'nastrojki.json');
  fs.writeFileSync(file, JSON.stringify(cfg, null, 2));
  return file;
}

export function runMain(args, { input = '', timeoutMs = 120000, env = {} } = {}) {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [MAIN, ...args], { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, ...env } });
    let out = '';
    const t = setTimeout(() => p.kill(), timeoutMs);
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { out += d; });
    p.stdin.end(input);
    p.on('close', (code) => { clearTimeout(t); resolve({ code, out }); });
  });
}

export function readProtocol(dir) {
  const files = fs.existsSync(dir) ? fs.readdirSync(dir) : [];
  const j = files.find((f) => f.endsWith('.json'));
  if (!j) return null;
  const base = j.slice(0, -5);
  return {
    json: JSON.parse(fs.readFileSync(path.join(dir, j), 'utf8')),
    texts: ['.html', '.md', '.json'].map((e) => fs.readFileSync(path.join(dir, base + e), 'utf8')),
  };
}

export function check(proto, id) {
  return proto.json.checks.find((c) => c.id === id);
}

/** Все тексты находок и итога проверки одной строкой (для поиска русского фрагмента). */
export function checkTexts(c) {
  return c ? c.findings.map((f) => f.text).join(' | ') + ' | ' + (c.summary || '') : '';
}

/** Фасад 1С (test/helpers/front-1c.mjs) с известными тестовыми паролем и ключом. */
export async function frontWithSecrets(opts = {}) {
  const { startFront } = await import('./front-1c.mjs');
  const password = opts.password || 'Test-Parol-' + crypto.randomBytes(6).toString('hex');
  const clientKey = opts.clientKey || 'Test-Klyuch-' + crypto.randomBytes(8).toString('hex');
  const front = await startFront({ samplesDir: SAMPLES, password, clientKey, ...opts });
  return { front, password, clientKey };
}

/** ПДн из образцов 1.2.0 (вымышленные, но в протоколе они должны быть скрыты как настоящие). */
export const SAMPLE_PII = ['ООО Пример', 'Клиент Пример', '+996700000001', '0700 000 001', '996700000001', '0700000001'];

/** Формы секретов, которых не должно быть нигде: сам секрет, URL-кодирование, base64, base64(user:password). */
export function secretForms(password, clientKey, user = 'pos_hs') {
  const out = new Set();
  for (const s of [password, clientKey]) {
    if (!s) continue;
    out.add(s);
    out.add(encodeURIComponent(s));
    out.add(Buffer.from(s, 'utf8').toString('base64').replace(/=+$/, ''));
  }
  if (password) out.add(Buffer.from(`${user}:${password}`, 'utf8').toString('base64').replace(/=+$/, ''));
  return [...out].filter((x) => x.length >= 6);
}

/** Список нарушений приватности в текстах: [{what, where}]. */
export function leaks(texts, needles) {
  const found = [];
  for (const [i, t] of texts.entries()) for (const n of needles) if (n && t.includes(n)) found.push({ what: n.slice(0, 4) + '…', where: i });
  return found;
}

/**
 * Запуск с ответами по подсказкам (поток ввода открыт, пока есть ответы; потом закрывается —
 * оставшиеся вопросы получают «нет ввода»). answers: [[RegExp, string | (m) => string]].
 */
export function runInteractive(args, answers, { timeoutMs = 180000, env = {} } = {}) {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [MAIN, ...args], { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, ...env } });
    let out = '';
    let pos = 0;
    const left = [...answers];
    const t = setTimeout(() => p.kill(), timeoutMs);
    const scan = () => {
      for (;;) {
        if (!left.length) { if (!p.stdin.writableEnded) p.stdin.end(); return; }
        const rest = out.slice(pos);
        let hit = null;
        for (const [i, [re, fn]] of left.entries()) {
          const m = re.exec(rest);
          if (m && (!hit || m.index < hit.m.index)) hit = { m, fn, i };
        }
        if (!hit) return;
        left.splice(hit.i, 1);
        pos += hit.m.index + hit.m[0].length;
        p.stdin.write((typeof hit.fn === 'function' ? hit.fn(hit.m) : hit.fn) + '\n');
      }
    };
    p.stdout.on('data', (d) => { out += d; scan(); });
    p.stderr.on('data', (d) => { out += d; });
    p.stdin.on('error', () => {});
    p.on('close', (code) => { clearTimeout(t); resolve({ code, out, unanswered: left.map(([re]) => String(re)) }); });
  });
}

/** Ограничитель одновременных прогонов (не больше n). */
export function limiter(n) {
  let active = 0;
  const queue = [];
  return async (fn) => {
    if (active >= n) await new Promise((r) => queue.push(r));
    active++;
    try { return await fn(); } finally { active--; const next = queue.shift(); if (next) next(); }
  };
}
