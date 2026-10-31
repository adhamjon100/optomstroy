// WP-T1: набор API (README 1–6, негативные ветки, обход операций приложения) на трёх бэкендах подряд:
//   A — собранный site/backend/backend.js (браузерные шимы Node), B — эталон native-runner.mjs (те же модули демо и
//   pos-api, встроенные модули Node настоящие), C — снова бандл (уровень шума прогона: фоновые задачи, случайные
//   ссылки имитатора). Нормализованные ответы A и B сравниваются; расхождение, которого нет между A и C, — артефакт
//   шимов. Каждый ответ A и B сверяется с OpenAPI; несоответствия обоих — в demo/web/.build/contract-report.md.
//
// Fix round 2: расхождение A↔B считается артефактом шимов, только если оно есть и у C↔B и повторяется против второго
// прогона эталона B2 (запускается лишь при таких кандидатах): гонки с фоновыми задачами («заказ → сразу отмена»
// против отправки outbox, cron статусов заказов) детерминированными не бывают; отсеянное — `flaky` в отчёте.
//   node --test demo/web/backend/test/differential.test.mjs     (≈ 4–5 мин; T1_DIFF_NO_NOISE=1 — без прогона C;
//        T1_DIFF_NO_RECHECK=1 — без B2)
// Итоги: demo/web/.build/t1/differential.json, demo/web/.build/contract-report.md.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { before, describe, test } from 'node:test';
import { SITE, startWorkerBackend } from './harness/worker-harness.mjs';
import { buildNativeReference, startNativeBackend } from './harness/native-runner.mjs';
import { coverage, runApiSuite, summarize, validateRecords } from './scenarios/api-suite.mjs';
import { compareRuns, subtractNoise } from './lib/normalize.mjs';
import { T1_DIR, groupContract, groupWarnings, writeContractReport, writeJson } from './lib/report.mjs';

const VERBOSE = process.env.T1_VERBOSE === '1';
const log = VERBOSE ? console.log : () => {};
const runs = {};

async function runOn(label, start) {
  const t = Date.now();
  const errors = [];
  const be = await start({ sku: 500, strict: true, initOpts: { seed: false }, boot: { netRecorder: true }, onLog: (lv, m) => lv === 'error' && errors.push(String(m).slice(0, 800)) });
  let ctx;
  let stats = null;
  try {
    ctx = await runApiSuite(be, { log, label });
  } finally {
    stats = await be.stats().catch(() => null);
    await be.close();
  }
  const validations = validateRecords(ctx.rec);
  const r = {
    label,
    ms: Date.now() - t,
    initMs: be.initMs,
    ctx,
    summary: summarize(ctx),
    validations,
    coverage: coverage(ctx.rec, validations),
    errors,
    netEvents: be.netEvents,
    stats: stats && { pg: { waitsOver3s: stats.pg.waitsOver3s, maxWaitMs: stats.pg.maxWaitMs, breakerRejects: stats.pg.breakerRejects, outsideWhitelist: stats.pg.outsideWhitelist, outsideWhitelistList: stats.pg.outsideWhitelistList, nestedBeginForeign: stats.pg.nestedBeginForeign, orphanedNested: stats.pg.orphanedNested }, gate: { holdsOver3s: stats.gate.stats.holdsOver3s, queueWaitsOver3s: stats.gate.stats.queueWaitsOver3s, maxHoldMs: stats.gate.stats.maxHoldMs, overruns: stats.gate.stats.overruns }, net: stats.net, onec: { byStatus: stats.onec.byStatus, gatewaySleeps: stats.onec.gateway.sleeps } },
  };
  runs[label] = r;
  return r;
}

let A;
let B;
let C;
let B2 = null;
let cmpAB;
let cmpAC;
let split;
let flaky = [];
let groups;
const diffKey = (d) => `${d.key}|${d.kind}|${String(d.path).replace(/\[\d+\]/g, '[]')}`;
before(async () => {
  await buildNativeReference({ quiet: true });
  A = await runOn('бандл', startWorkerBackend);
  B = await runOn('эталон', startNativeBackend);
  if (process.env.T1_DIFF_NO_NOISE !== '1') C = await runOn('бандл (повтор)', startWorkerBackend);
  cmpAB = compareRuns(A.ctx.rec, B.ctx.rec);
  cmpAC = C ? compareRuns(A.ctx.rec, C.ctx.rec) : { diffs: [], order: [], compared: 0 };
  split = subtractNoise(cmpAB.diffs, cmpAC.diffs);
  // Fix round 2: артефакт шимов детерминирован — бандл отличается от эталона в КАЖДОЙ паре прогонов; гонка с фоном
  // (отправка заказа outbox против немедленной отмены, cron */5 статусов заказов → rowVersion) — нет. Кандидат в
  // артефакт: расхождение A↔B, которое есть и у C↔B (иначе гонка была в A) и повторяется против второго прогона
  // эталона B2 (иначе гонка была в B). B2 запускается, только если кандидаты есть. Отсеянное — `flaky` в отчёте.
  if (C && split.real.length) {
    const cb = new Set(compareRuns(C.ctx.rec, B.ctx.rec).diffs.map(diffKey));
    let cand = split.real.filter((d) => cb.has(diffKey(d)));
    flaky = split.real.filter((d) => !cb.has(diffKey(d))).map((d) => ({ ...d, why: 'нет в C↔B: гонка в прогоне бандла A' }));
    if (cand.length && process.env.T1_DIFF_NO_RECHECK !== '1') {
      B2 = await runOn('эталон (повтор)', startNativeBackend);
      const ab2 = new Set(compareRuns(A.ctx.rec, B2.ctx.rec).diffs.map(diffKey));
      flaky.push(...cand.filter((d) => !ab2.has(diffKey(d))).map((d) => ({ ...d, why: 'нет в A↔B2: гонка в прогоне эталона B' })));
      cand = cand.filter((d) => ab2.has(diffKey(d)));
    }
    split = { real: cand, noisy: split.noisy };
  }
  groups = groupContract(A.validations, B.validations);
  const build = JSON.parse(readFileSync(`${SITE}/backend/build.json`, 'utf8'));
  writeContractReport({ groups, warnings: groupWarnings(A.validations), coverage: A.coverage, build, at: new Date().toISOString(), runs: [A, B].map((r) => ({ label: r.label, requests: r.ctx.rec.length })) });
  const brief = (r) => r && { label: r.label, ms: r.ms, initMs: r.initMs, summary: r.summary, coverage: { ...r.coverage, byOp: undefined }, stats: r.stats, errors: r.errors.slice(0, 20), netEvents: r.netEvents, checks: r.ctx.checks };
  writeJson(`${T1_DIR}/differential.json`, {
    at: new Date().toISOString(),
    build: { sha256: build.backend.sha256, gitHead: build.gitHead, epochKey: build.epochKey },
    runs: [brief(A), brief(B), brief(C), brief(B2)].filter(Boolean),
    differential: { compared: cmpAB.compared, diffsAB: cmpAB.diffs, orderOnlyAB: cmpAB.order, diffsAC: cmpAC.diffs, real: split.real, noise: split.noisy, flaky, recheck: B2 ? B2.label : null },
    contract: { groups, onlyBundle: groups.filter((g) => g.bundle > 0 && g.reference === 0).length, both: groups.filter((g) => g.bundle > 0 && g.reference > 0).length },
    coverageByOp: A.coverage.byOp,
  });
  writeJson(`${T1_DIR}/api-records-bundle.json`, A.ctx.rec.map((r) => ({ ...r, json: r.size > 20000 ? '<…>' : r.json })));
});

describe('набор API на бандле, эталон, шум', () => {
  test('README 1–6, негативные ветки и обход: все проверки сценариев на бандле', () => {
    const failed = A.ctx.checks.filter((c) => !c.ok).map((c) => `${c.scenario} | ${c.name} | ${c.evidence.slice(0, 300)}`);
    assert.deepEqual(failed, []);
  });
  test('0 ответов 5xx и 0 неожиданных статусов на бандле', () => {
    assert.deepEqual(A.summary.status5xx, []);
    assert.deepEqual(A.summary.unexpected, []);
  });
  test('0 расхождений бандл ↔ эталон (нормализованные ответы; за вычетом шума бандл ↔ бандл)', () => {
    assert.ok(cmpAB.compared >= 300, `сравнено ${cmpAB.compared}`);
    assert.deepEqual(split.real.map((d) => `${d.kind} | ${d.key} | ${d.path} | ${JSON.stringify(d.a)?.slice(0, 80)} ≠ ${JSON.stringify(d.b)?.slice(0, 80)}`), []);
  });
  test('эталон проходит те же проверки сценариев, что бандл (одинаковые провалы — дефекты pos-api/демо, не шимов)', () => {
    const fails = (r) => r.ctx.checks.filter((c) => !c.ok).map((c) => c.name).sort();
    const fa = fails(A);
    // второй прогон эталона (если был, fix round 2): провал только в одном прогоне эталона — гонка, не шимы
    if (B2 && JSON.stringify(fa) === JSON.stringify(fails(B2))) return;
    assert.deepEqual(fa, fails(B));
  });
  test('контракт: несоответствий только у бандла — 0 (несоответствия обоих — в contract-report.md)', () => {
    assert.deepEqual(groups.filter((g) => g.bundle > 0 && g.reference === 0).map((g) => `${g.operationId} ${g.status}: ${g.error}`), []);
  });
  test('покрыто не меньше 106 из 116 операций приложения (Dio)', () => {
    assert.ok(A.coverage.dioTotal === 116, `операций Dio ${A.coverage.dioTotal}`);
    assert.ok(A.coverage.dioCovered >= 106, `покрыто ${A.coverage.dioCovered}: ${A.coverage.uncovered.map((o) => o.operationId).join(', ')}`);
  });
  test('единица работы и pg-shim на бандле: 0 ожиданий замка > 3 с, 0 удержаний/ожиданий слота > 3 с, 0 подсадок вне белого списка, 0 BEGIN из чужой единицы', () => {
    const s = A.stats;
    assert.deepEqual({ waits3s: s.pg.waitsOver3s, breaker: s.pg.breakerRejects, holds3s: s.gate.holdsOver3s, queue3s: s.gate.queueWaitsOver3s, outside: s.pg.outsideWhitelist, foreign: s.pg.nestedBeginForeign }, { waits3s: 0, breaker: 0, holds3s: 0, queue3s: 0, outside: 0, foreign: 0 }, JSON.stringify(s.pg.outsideWhitelistList));
  });
  test('ни одного сетевого вызова воркера до платформы (fetch, WebSocket, net, http) во всех прогонах', () => {
    for (const r of [A, B, C, B2].filter(Boolean)) {
      assert.deepEqual(r.netEvents, [], r.label);
      assert.equal(r.stats.net.blocked, 0, `${r.label}: запрет сети сработал ${r.stats.net.blocked} раз`);
    }
  });
});
