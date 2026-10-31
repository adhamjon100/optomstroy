// WP-T1: обязательные сценарии критика на собранном backend.js (scenarios/critic.mjs): C1 заголовки 0.1.0+1,
// C2 перезагрузка посреди работы, C3 обрыв воркера посреди задачи, C4 часы +3/+10 дней, C5 «1С недоступна» под
// сторожем, C6 ни одного внешнего сетевого запроса, C7 долги «1С» после холодного старта. Каждая проверка — тест.
//   node --test demo/web/backend/test/critic.test.mjs     (≈ 5–6 мин; T1_CRITIC_ONLY=c2Reload,c4Clock — выборочно)
// Итоги: demo/web/.build/t1/critic.json.
import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import { runCritic } from './scenarios/critic.mjs';
import { T1_DIR, writeJson } from './lib/report.mjs';

const only = process.env.T1_CRITIC_ONLY ? process.env.T1_CRITIC_ONLY.split(',') : undefined;
const t0 = Date.now();
const world = await runCritic({ log: process.env.T1_VERBOSE === '1' ? console.log : () => {}, only });
const checks = world.ctxs.flatMap((c) => c.checks);
const rec = world.ctxs.flatMap((c) => c.rec);
writeJson(`${T1_DIR}/critic.json`, {
  at: new Date().toISOString(),
  ms: Date.now() - t0,
  checks,
  requests: rec.length,
  status5xx: rec.filter((r) => r.status >= 500 || r.status === 0).map((r) => ({ key: r.key, status: r.status, code: r.json?.code })),
  unexpected: rec.filter((r) => !r.ok).map((r) => ({ key: r.key, status: r.status, expect: r.expect, code: r.json?.code, detail: r.json?.detail })),
  backends: world.backends.map((b) => b.label),
  netEvents: world.netEvents,
  netBlocked: world.netBlocked,
  workerErrors: world.errors.slice(0, 50),
});

describe('сценарии критика (бандл)', () => {
  for (const c of checks) test(`${c.name}`, () => assert.ok(c.ok, c.evidence));
  test('0 ответов 5xx во всех сценариях критика', () => assert.deepEqual(rec.filter((r) => r.status >= 500).map((r) => `${r.key} ${r.status}`), []));
  test('0 неожиданных статусов во всех сценариях критика', () => assert.deepEqual(rec.filter((r) => !r.ok).map((r) => `${r.key} ${r.status} ${r.json?.code ?? ''}`), []));
});
