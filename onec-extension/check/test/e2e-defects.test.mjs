// Для каждого дефекта имитатора (§5.2) — отдельный прогон --demo --demo-defect: код 1 и ОШИБКА у ожидаемой
// проверки с ожидаемым русским фрагментом (D26 — ЗАМЕЧАНИЕ: язык message в контракте 1.2.0 и Требованиях не задан,
// код 0). Не больше 4 прогонов одновременно.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { DEFECTS } from '../src/mock/defects.mjs';
import { SAMPLE_PII, leaks } from './helpers/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MAIN = path.resolve(HERE, '..', 'src', 'main.mjs');
const TMP = fs.mkdtempSync(path.join(process.env.TEMP || os.tmpdir(), 'oc-defects-'));

function run(args) {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [MAIN, ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { out += d; });
    p.stdin.end();
    p.on('close', (code) => resolve({ code, out }));
  });
}

let active = 0;
const queue = [];
async function limited(fn) {
  if (active >= 4) await new Promise((r) => queue.push(r));
  active++;
  try { return await fn(); } finally { active--; const n = queue.shift(); if (n) n(); }
}

const results = new Map(DEFECTS.map((d) => [d.id, limited(async () => {
  const out = path.join(TMP, d.id);
  const args = ['--demo', '--no-manual', '--demo-defect', d.id, '--out', out];
  if (d.id === 'D51') args.push('--timeout-scale', '0.01');
  const r = await run(args);
  const f = fs.existsSync(out) ? fs.readdirSync(out).find((x) => x.endsWith('.json')) : null;
  const texts = f ? ['.html', '.md', '.json'].map((e) => fs.readFileSync(path.join(out, f.slice(0, -5) + e), 'utf8')) : [];
  return { ...r, texts, protocol: f ? JSON.parse(fs.readFileSync(path.join(out, f), 'utf8')) : null };
})]));

for (const d of DEFECTS) {
  test(`${d.id} ${d.what} → ${d.check} ${d.severity === 'WARN' ? 'ЗАМЕЧАНИЕ' : 'ОШИБКА'} «${d.fragment}»`, async () => {
    const r = await results.get(d.id);
    assert.ok(r.protocol, `нет протокола; вывод: ${r.out.slice(-500)}`);
    const c = r.protocol.checks.find((x) => x.id === d.check);
    assert.ok(c, `в протоколе нет проверки ${d.check}`);
    assert.equal(c.verdict, d.severity, `${d.check}: ${c.verdict} — ${c.summary}`);
    const texts = c.findings.map((f) => f.text).join(' | ') + ' | ' + c.summary;
    assert.ok(texts.includes(d.fragment), `${d.check}: нет фрагмента «${d.fragment}» в: ${texts.slice(0, 600)}`);
    // D51: таймаут запроса — ОШИБКА E10, прогон продолжается (не обрыв), поэтому тоже 1.
    const code = d.severity === 'WARN' ? 0 : 1;
    assert.equal(r.code, code, `код выхода ${r.code}`);
    assert.equal(r.protocol.exitCode, code);
    // ПДн образцов (в том числе из дефектов D13, D27 — телефон в кандидате и в тексте ошибки) нигде не видны.
    assert.deepEqual(leaks([r.out, ...r.texts], SAMPLE_PII), [], 'ПДн в выводе');
    // У каждой ОШИБКИ в протоколе — где и подсказка для 1С (design §3.1 п. 5).
    for (const ch of r.protocol.checks) {
      for (const f of ch.findings.filter((x) => x.severity === 'FAIL')) {
        assert.ok(f.where, `${ch.id}: нет «где» у «${f.text}»`);
        assert.ok(f.hint, `${ch.id}: нет подсказки у «${f.text}»`);
      }
    }
  });
}

test.after(async () => { await Promise.allSettled(results.values()); fs.rmSync(TMP, { recursive: true, force: true }); });
