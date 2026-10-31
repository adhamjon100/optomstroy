// WP-T1: все тесты демо-бэкенда одним запуском и сводка (plan §4 WP-T1, §5 пп. 3–6).
//
//   node demo/web/backend/test/run-all.mjs [--soak-min 20] [--no-browser] [--browser chrome|edge] [--skip-soak]
//        [--skip-unit] [--skip-diff] [--skip-critic] [--skip-flush] [--soak-storage idb|opfs] [--json <файл>]
//        [--cdp 9481] [--flush-cdp 9482]   (порты CDP браузерного soak и шага «медленный диск»; regress:final)
//
// Порядок (последовательно, чтобы замеры сторожа и памяти не мешали друг другу):
//   1. модульные тесты node --test: crypto-shim, net-guard, work-gate, pg-shim, shims, gate, storage-idb, bundle,
//      contract;
//   2. differential.test.mjs — набор API (README 1–6, негативные ветки, обход операций приложения) на бандле,
//      эталоне и повторно на бандле; OpenAPI; покрытие; → .build/t1/differential.json, .build/contract-report.md;
//   3. critic.test.mjs — перезагрузка, обрыв, часы +3/+10 дней, 0.1.0+1, «1С недоступна», сеть, долги после старта;
//   3б. review fixes, critic [18]: realpg/realpg-diff.mjs — тот же набор API на бандле и на НАСТОЯЩЕМ PostgreSQL 17
//      (embedded-postgres, база как у local-stack serve) и снова на бандле; отличия слоя БД, сортировка, аудит
//      (--skip-realpg — пропустить);
//   4. fix round 2: «медленный диск» в браузере — soak/browser-soak.mjs --minutes 2 --commit-delay-ms 3500 (каждый
//      commit IndexedDB +3,5 с): ответы изменяющих запросов ждут commit, сторож молчит (≈ 3 мин);
//   5. soak: scenarios/soak.mjs (Node) и soak/browser-soak.mjs (Chrome, IndexedDB) одновременно, --soak-min минут.
// Провалы, совпадающие с известным дефектом pos-api (test/pos-api-defects.json; воспроизводится и на эталоне — не
// шимы), помечаются в сводке (knownPosApiDefect), но остаются провалами (не скрываются).
// Нужна собранная demo/web/site (node demo/web/backend/build-backend.mjs). TEMP/TMP — D:\optomstroy\.tmp.
// Код выхода: 0 — всё зелёное; 1 — есть провалы демо (сводка перечисляет их); 3 — провалы есть, но ВСЕ — известные
// дефекты pos-api (review fixes: так CI отличает «сломалось демо» от «ждём решения pos-api», а провалы не прячутся).
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, rmSync, statfsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { OUT, ROOT } from '../lib/paths.mjs';
import { T1_DIR, CONTRACT_REPORT, writeJson } from './lib/report.mjs';

const HERE = dirname(fileURLToPath(import.meta.url)).replace(/\\/g, '/');
const argv = process.argv.slice(2);
const has = (k) => argv.includes(k);
const arg = (k, d) => (has(k) ? argv[argv.indexOf(k) + 1] : d);
const SOAK_MIN = Number(arg('--soak-min', 20));
const T0 = Date.now();
const el = () => `${((Date.now() - T0) / 60e3).toFixed(1)} мин`;
const say = (...a) => console.log(`[run-all ${el()}]`, ...a);
process.env.TEMP ||= `${ROOT}/.tmp`;
process.env.TMP ||= `${ROOT}/.tmp`;

const UNIT = ['crypto-shim', 'net-guard', 'work-gate', 'pg-shim', 'shims', 'gate', 'storage-idb', 'bundle', 'contract', 'durability'].map((n) => `${HERE}/${n}.test.mjs`);
/** Хранилище браузерного soak (review fixes: OPFS — основное хранилище Chrome/Edge — тоже прогоняется). */
const SOAK_STORAGE = arg('--soak-storage', 'idb');

/** Запустить процесс Node; → { code, out, ms }. */
function runNode(args, { timeoutMs = 3_600_000, label, quiet = true } = {}) {
  return new Promise((resolveP) => {
    const t = Date.now();
    const p = spawn(process.execPath, args, { cwd: ROOT, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    const onData = (d) => {
      out += d;
      if (!quiet) process.stdout.write(d);
      if (out.length > 30_000_000) out = out.slice(-10_000_000);
    };
    p.stdout.on('data', onData);
    p.stderr.on('data', onData);
    const timer = setTimeout(() => {
      say(`${label}: превышено время ${timeoutMs / 60e3} мин — процесс ${p.pid} остановлен`);
      p.kill();
    }, timeoutMs);
    p.on('close', (code) => {
      clearTimeout(timer);
      resolveP({ code, out, ms: Date.now() - t, pid: p.pid });
    });
  });
}

/** Разбор TAP node --test: итоги и провалившиеся тесты (с вложенностью). */
function parseTap(out) {
  const num = (k) => Number(new RegExp(`^# ${k} (\\d+)`, 'm').exec(out)?.[1] ?? NaN);
  const failed = [];
  const lines = out.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const m = /^(\s*)not ok \d+ - (.+?)(?:\s+#.*)?$/.exec(lines[i]);
    if (!m) continue;
    // подробности провала: строки после «not ok» до следующего теста
    let detail = '';
    for (let j = i + 1; j < Math.min(lines.length, i + 60); j++) {
      if (/^\s*(not )?ok \d+ -/.test(lines[j])) break;
      const e = /^(\s+)error: (.*)$/.exec(lines[j]);
      if (!e) continue;
      if (/^[|>]-?$/.test(e[2].trim())) {
        // блок YAML: строки глубже ключа error
        for (let k = j + 1; k < lines.length && /^\s/.test(lines[k]) && lines[k].search(/\S/) > e[1].length && detail.length < 700; k++) detail += `${lines[k].trim()} `;
      } else detail = e[2].replace(/^['"]|['"]$/g, '');
      break;
    }
    failed.push({ depth: m[1].length / 4, name: m[2].replace(/^['"]|['"]$/g, ''), detail: detail.trim() });
  }
  // в TAP node --test итог набора идёт ПОСЛЕ его подтестов: запись, перед которой стоит более глубокая, — набор (пропускаем)
  const leaves = failed.filter((f, i) => !(i > 0 && failed[i - 1].depth > f.depth));
  return { tests: num('tests'), pass: num('pass'), fail: num('fail'), cancelled: num('cancelled'), failed: leaves };
}

function freeMB(p) {
  try {
    const s = statfsSync(p);
    return Math.round((s.bavail * s.bsize) / 1048576);
  } catch {
    return null;
  }
}

const summary = { at: new Date().toISOString(), build: null, steps: {}, failures: [] };
const fail = (step, test, detail) => summary.failures.push({ step, test, detail: String(detail ?? '').slice(0, 900) });

// ---------------------------------------------------------------- 0. предусловия
if (!existsSync(`${OUT}/backend.js`)) {
  console.error('нет demo/web/site/backend/backend.js — сначала node demo/web/backend/build-backend.mjs');
  process.exit(1);
}
summary.build = (({ gitHead, posApiDiffSha256, epochKey, appVersion, backend }) => ({ gitHead, posApiDiffSha256, epochKey, appVersion, sha256: backend?.sha256, minBytes: backend?.minBytes, brotliBytes: backend?.brotliBytes }))(JSON.parse(readFileSync(`${OUT}/build.json`, 'utf8')));
summary.disk = { D: freeMB(ROOT), C: freeMB('C:/') };
say(`бандл ${summary.build.sha256?.slice(0, 12)}…, HEAD ${summary.build.gitHead?.slice(0, 7)}, эпоха ${summary.build.epochKey}; свободно D: ${summary.disk.D} МБ, C: ${summary.disk.C} МБ`);
if (summary.disk.D !== null && summary.disk.D < 400) {
  console.error(`мало места на D: (${summary.disk.D} МБ, нужно ≥ 400)`);
  process.exit(1);
}

// ---------------------------------------------------------------- 1. модульные тесты
if (!has('--skip-unit')) {
  summary.steps.unit = {};
  for (const f of UNIT) {
    const name = f.split('/').pop();
    const r = await runNode(['--test', '--test-reporter=tap', f], { label: name, timeoutMs: 600_000 });
    const t = parseTap(r.out);
    summary.steps.unit[name] = { code: r.code, ms: r.ms, tests: t.tests, pass: t.pass, fail: t.fail, failed: t.failed };
    for (const x of t.failed) fail(`unit ${name}`, x.name, x.detail);
    if (r.code !== 0 && !t.failed.length) fail(`unit ${name}`, '(процесс)', `код ${r.code}: ${r.out.slice(-600)}`);
    say(`${name}: ${t.pass}/${t.tests}${t.fail ? ` — провалов ${t.fail}` : ''} (${(r.ms / 1000).toFixed(0)} с)`);
  }
}

// ---------------------------------------------------------------- 2. дифференциальный + контракт + покрытие
if (!has('--skip-diff')) {
  say('differential.test.mjs: бандл → эталон → бандл (≈ 4–5 мин)…');
  const r = await runNode(['--test', '--test-reporter=tap', `${HERE}/differential.test.mjs`], { label: 'differential', timeoutMs: 1_800_000 });
  const t = parseTap(r.out);
  const d = existsSync(`${T1_DIR}/differential.json`) ? JSON.parse(readFileSync(`${T1_DIR}/differential.json`, 'utf8')) : null;
  const A = d?.runs?.[0];
  summary.steps.differential = {
    code: r.code,
    ms: r.ms,
    tests: t.tests,
    pass: t.pass,
    fail: t.fail,
    failed: t.failed,
    requests: d?.runs?.map((x) => ({ label: x.label, requests: x.summary.requests, checks: `${x.summary.checks - x.summary.checksFailed}/${x.summary.checks}`, status5xx: x.summary.status5xx.length, unexpected: x.summary.unexpected.length, ms: x.ms })),
    compared: d?.differential?.compared,
    realDiffs: d?.differential?.real?.length,
    noiseDiffs: d?.differential?.noise?.length,
    flakyDiffs: d?.differential?.flaky?.length ?? 0,
    recheck: d?.differential?.recheck ?? null,
    orderOnly: d?.differential?.orderOnlyAB?.length,
    contract: d && { both: d.contract.both, onlyBundle: d.contract.onlyBundle, report: CONTRACT_REPORT },
    coverage: A && { dio: `${A.coverage.dioCovered}/${A.coverage.dioTotal}`, app: `${A.coverage.appCovered}/${A.coverage.appTotal}`, uncovered: A.coverage.uncovered.map((o) => `${o.operationId}: ${o.reason}`) },
  };
  for (const x of t.failed) fail('differential', x.name, x.detail);
  if (r.code !== 0 && !t.failed.length) fail('differential', '(процесс)', `код ${r.code}: ${r.out.slice(-800)}`);
  say(`differential: ${t.pass}/${t.tests}; сравнено ${summary.steps.differential.compared}, расхождений шимов ${summary.steps.differential.realDiffs}; контракт: оба ${d?.contract?.both ?? '?'} групп, только бандл ${d?.contract?.onlyBundle ?? '?'}; покрытие ${summary.steps.differential.coverage?.dio}`);
}

// ---------------------------------------------------------------- 3. сценарии критика
if (!has('--skip-critic')) {
  say('critic.test.mjs: перезагрузка, обрыв, часы, версия, «1С недоступна», сеть, долги (≈ 6 мин)…');
  const r = await runNode(['--test', '--test-reporter=tap', `${HERE}/critic.test.mjs`], { label: 'critic', timeoutMs: 1_800_000 });
  const t = parseTap(r.out);
  const c = existsSync(`${T1_DIR}/critic.json`) ? JSON.parse(readFileSync(`${T1_DIR}/critic.json`, 'utf8')) : null;
  summary.steps.critic = { code: r.code, ms: r.ms, tests: t.tests, pass: t.pass, fail: t.fail, failed: t.failed, checks: c?.checks?.map((x) => ({ name: x.name, ok: x.ok })), requests: c?.requests, status5xx: c?.status5xx?.length, netEvents: c?.netEvents?.length };
  for (const x of t.failed) fail('critic', x.name, x.detail);
  if (r.code !== 0 && !t.failed.length) fail('critic', '(процесс)', `код ${r.code}: ${r.out.slice(-800)}`);
  say(`critic: ${t.pass}/${t.tests}`);
}

// ---------------------------------------------------------------- 3б. настоящий PostgreSQL (review fixes, critic [18])
if (!has('--skip-realpg')) {
  say('realpg-diff.mjs: бандл ↔ настоящий PostgreSQL 17 ↔ бандл (≈ 5–6 мин)…');
  const r = await runNode([`${HERE}/realpg/realpg-diff.mjs`, '--json', `${T1_DIR}/realpg.json`], { label: 'realpg', timeoutMs: 1_800_000 });
  const rp = existsSync(`${T1_DIR}/realpg.json`) ? JSON.parse(readFileSync(`${T1_DIR}/realpg.json`, 'utf8')) : null;
  summary.steps.realpg = rp && { code: r.code, ms: r.ms, postgres: rp.postgres, runs: rp.runs?.map((x) => ({ label: x.label, requests: x.requests, checks: x.checks, status5xx: x.status5xx?.length, audit: x.audit })), compared: rp.differential?.compared, dbLayerDiffs: rp.differential?.real?.length, flaky: rp.differential?.flaky?.length, orderOnly: rp.differential?.orderOnlyAR?.length, sameScenarioFailures: rp.checks?.sameScenarioFailures, collation: rp.probes?.collation && { sameOrder: rp.probes.collation.sameOrder, sameLower: rp.probes.collation.sameLower, sameIlike: rp.probes.collation.sameIlike, locale: [rp.probes.collation.pglite.locale, rp.probes.collation.postgres.locale] }, error: rp.error ?? null };
  if (!rp || rp.error) fail('realpg', '(процесс)', rp?.error ?? r.out.slice(-800));
  else {
    for (const d of rp.differential?.real ?? []) fail('realpg', `отличие слоя БД: ${d.key}`, `${d.kind} ${d.path}: ${JSON.stringify(d.a)?.slice(0, 200)} ≠ ${JSON.stringify(d.b)?.slice(0, 200)}`);
    if (!rp.checks?.sameScenarioFailures) fail('realpg', 'проверки сценариев на бандле и на PostgreSQL совпадают', JSON.stringify({ onlyBundle: rp.checks?.onlyBundle, onlyPostgres: rp.checks?.onlyPostgres }));
    if (!rp.probes?.collation?.sameOrder) fail('realpg', 'порядок сортировки PGlite = PostgreSQL', JSON.stringify(rp.probes?.collation));
    for (const x of rp.runs ?? []) if (x.status5xx?.length || x.audit?.ok === false) fail('realpg', `${x.label}: 0 ответов 5xx, цепочка аудита цела`, JSON.stringify({ s5xx: x.status5xx, audit: x.audit }));
  }
  say(`realpg: сравнено ${summary.steps.realpg?.compared ?? '?'}, отличий слоя БД ${summary.steps.realpg?.dbLayerDiffs ?? '?'}, гонок ${summary.steps.realpg?.flaky ?? '?'}`);
}

// ---------------------------------------------------------------- 4. «медленный диск» в браузере (fix round 2)
const FLUSH_DELAY_MS = Number(arg('--flush-delay-ms', 3500));
if (!has('--skip-flush') && !has('--no-browser')) {
  say(`браузер, commit IndexedDB +${FLUSH_DELAY_MS} мс (≈ 3 мин)…`);
  rmSync(`${T1_DIR}/browser-flush.json`, { force: true });
  const r = await runNode([`${HERE}/soak/browser-soak.mjs`, '--minutes', '2', '--browser', arg('--browser', 'chrome'), '--storage', 'idb', '--cdp', String(arg('--flush-cdp', 9482)), '--commit-delay-ms', String(FLUSH_DELAY_MS), '--json', `${T1_DIR}/browser-flush.json`], { label: 'browser-flush', timeoutMs: 15 * 60e3 });
  const sb = existsSync(`${T1_DIR}/browser-flush.json`) ? JSON.parse(readFileSync(`${T1_DIR}/browser-flush.json`, 'utf8')) : null;
  const fresh = sb && sb.commitDelayMs === FLUSH_DELAY_MS;
  summary.steps.browserFlush = { code: r.code, ms: r.ms, browser: sb?.browserVersion, commitDelayMs: FLUSH_DELAY_MS, orders: sb?.orders, last: sb?.samples?.at(-1) ? { gate: sb.samples.at(-1).gate, pg: sb.samples.at(-1).pg, bridge: sb.samples.at(-1).bridge, flush: sb.samples.at(-1).flush } : null, checks: sb?.checks };
  for (const c of sb?.checks ?? []) if (!c.ok) fail('браузер, медленный commit', c.name, c.evidence);
  if (!fresh || r.code === null) fail('браузер, медленный commit', '(процесс)', r.out.slice(-800));
  say(`медленный commit: ${(sb?.checks ?? []).filter((c) => c.ok).length}/${sb?.checks?.length ?? 0}`);
}

// ---------------------------------------------------------------- 5. soak (Node и браузер одновременно)
if (!has('--skip-soak')) {
  say(`soak ${SOAK_MIN} мин: Node (worker_threads) ${has('--no-browser') ? '' : `и ${arg('--browser', 'chrome')} (${SOAK_STORAGE === 'opfs' ? 'OPFS' : 'IndexedDB'}) одновременно`}…`);
  const jobs = [runNode([`${HERE}/scenarios/soak.mjs`, '--minutes', String(SOAK_MIN), '--json', `${T1_DIR}/soak.json`], { label: 'soak', timeoutMs: (SOAK_MIN + 15) * 60e3 })];
  if (!has('--no-browser')) jobs.push(runNode([`${HERE}/soak/browser-soak.mjs`, '--minutes', String(SOAK_MIN), '--browser', arg('--browser', 'chrome'), '--storage', SOAK_STORAGE, '--cdp', String(arg('--cdp', 9481)), '--json', `${T1_DIR}/browser-soak.json`], { label: 'browser-soak', timeoutMs: (SOAK_MIN + 15) * 60e3 }));
  const [rn, rb] = await Promise.all(jobs);
  const sn = existsSync(`${T1_DIR}/soak.json`) ? JSON.parse(readFileSync(`${T1_DIR}/soak.json`, 'utf8')) : null;
  summary.steps.soak = { code: rn.code, ms: rn.ms, minutes: sn?.minutes, orders: sn?.orders, extrapolation8h: sn?.extrapolation8h, volume: sn?.volume, criteria: sn?.criteria };
  for (const c of sn?.criteria ?? []) if (!c.ok) fail('soak (Node)', c.name, c.evidence);
  if (!sn) fail('soak (Node)', '(процесс)', rn.out.slice(-800));
  if (rb) {
    const sb = existsSync(`${T1_DIR}/browser-soak.json`) ? JSON.parse(readFileSync(`${T1_DIR}/browser-soak.json`, 'utf8')) : null;
    summary.steps.browserSoak = { code: rb.code, ms: rb.ms, browser: sb?.browserVersion, storage: sb?.storage ?? SOAK_STORAGE, minutes: sb?.minutes, orders: sb?.orders, extrapolation8h: sb?.extrapolation8h, checks: sb?.checks };
    for (const c of sb?.checks ?? []) if (!c.ok) fail('soak (браузер)', c.name, c.evidence);
    if (!sb) fail('soak (браузер)', '(процесс)', rb.out.slice(-800));
  }
  say(`soak: Node ${summary.steps.soak.criteria?.filter((c) => c.ok).length ?? 0}/${summary.steps.soak.criteria?.length ?? 0}${summary.steps.browserSoak ? `, браузер ${summary.steps.browserSoak.checks?.filter((c) => c.ok).length ?? 0}/${summary.steps.browserSoak.checks?.length ?? 0}` : ''}`);
}

// ---------------------------------------------------------------- известные дефекты pos-api (не скрываются)
// Провал критика помечается, только если его свидетельство само указывает на дефект (critic.json: knownPosApiDefect),
// а дефект перечислен в test/pos-api-defects.json с этим тестом.
try {
  const defects = JSON.parse(readFileSync(`${HERE}/pos-api-defects.json`, 'utf8')).items ?? [];
  const critic = existsSync(`${T1_DIR}/critic.json`) ? JSON.parse(readFileSync(`${T1_DIR}/critic.json`, 'utf8')) : null;
  for (const f of summary.failures) {
    if (f.step !== 'critic') continue;
    const chk = critic?.checks?.find((c) => c.name === f.test);
    let ev = null;
    try {
      ev = chk ? JSON.parse(chk.evidence) : null;
    } catch {
      ev = null;
    }
    const d = defects.find((x) => (x.tests ?? []).some((t) => `critic ${f.test}`.startsWith(t)) && ev?.knownPosApiDefect && String(ev.knownPosApiDefect).startsWith(x.id));
    if (d) f.knownPosApiDefect = d.id;
  }
} catch (e) {
  say(`pos-api-defects.json: ${e?.message ?? e}`);
}
summary.knownPosApiDefectFailures = summary.failures.filter((f) => f.knownPosApiDefect).length;
summary.demoFailures = summary.failures.length - summary.knownPosApiDefectFailures;

// ---------------------------------------------------------------- сводка
summary.totalMin = +((Date.now() - T0) / 60e3).toFixed(1);
summary.allGreen = summary.failures.length === 0;
writeJson(arg('--json', `${T1_DIR}/summary.json`), summary);
console.log('\n================ WP-T1: сводка');
if (summary.steps.unit) for (const [k, v] of Object.entries(summary.steps.unit)) console.log(`${v.fail ? 'FAIL' : 'OK  '} модульные ${k}: ${v.pass}/${v.tests}`);
if (summary.steps.differential) {
  const d = summary.steps.differential;
  console.log(`${d.fail ? 'FAIL' : 'OK  '} differential: ${d.pass}/${d.tests}; ${JSON.stringify(d.requests)}`);
  console.log(`      бандл ↔ эталон: сравнено ${d.compared}, расхождений шимов ${d.realDiffs} (шум бандл ↔ бандл ${d.noiseDiffs}, только порядок ${d.orderOnly})${d.flakyDiffs ? `; гонки с фоном, не повторившиеся (${d.recheck ?? 'C↔B'}): ${d.flakyDiffs}` : ''}`);
  console.log(`      контракт: расхождений pos-api с контрактом ${d.contract?.both} групп (не блокируют, ${d.contract?.report}), только у бандла ${d.contract?.onlyBundle}`);
  console.log(`      покрытие операций приложения: Dio ${d.coverage?.dio}, все ${d.coverage?.app}; без покрытия: ${(d.coverage?.uncovered ?? []).join('; ')}`);
}
if (summary.steps.critic) console.log(`${summary.steps.critic.fail ? 'FAIL' : 'OK  '} critic: ${summary.steps.critic.pass}/${summary.steps.critic.tests}`);
if (summary.steps.realpg) {
  const rp = summary.steps.realpg;
  console.log(`${rp.dbLayerDiffs === 0 && rp.sameScenarioFailures && !rp.error ? 'OK  ' : 'FAIL'} PostgreSQL ${rp.postgres}: сравнено ${rp.compared}, отличий слоя БД ${rp.dbLayerDiffs}, гонок с фоном ${rp.flaky}; ${JSON.stringify(rp.runs)}; сортировка ${JSON.stringify(rp.collation)}`);
}
if (summary.steps.browserFlush) console.log(`${(summary.steps.browserFlush.checks ?? []).length && summary.steps.browserFlush.checks.every((c) => c.ok) ? 'OK  ' : 'FAIL'} браузер, commit IndexedDB +${summary.steps.browserFlush.commitDelayMs} мс: ${JSON.stringify(summary.steps.browserFlush.last)}`);
if (summary.steps.soak) console.log(`${(summary.steps.soak.criteria ?? []).every((c) => c.ok) ? 'OK  ' : 'FAIL'} soak Node ${summary.steps.soak.minutes} мин → 8 ч: ${JSON.stringify(summary.steps.soak.extrapolation8h)}; том ${JSON.stringify(summary.steps.soak.volume)}`);
if (summary.steps.browserSoak) console.log(`${(summary.steps.browserSoak.checks ?? []).every((c) => c.ok) ? 'OK  ' : 'FAIL'} soak браузер ${summary.steps.browserSoak.minutes} мин → 8 ч: ${JSON.stringify(summary.steps.browserSoak.extrapolation8h)}`);
console.log(`\nпровалов: ${summary.failures.length}${summary.knownPosApiDefectFailures ? ` (из них известный дефект pos-api, есть и на эталоне: ${summary.knownPosApiDefectFailures}; провалов демо: ${summary.demoFailures})` : ''}`);
for (const f of summary.failures) console.log(`  ✖ [${f.step}] ${f.test}${f.knownPosApiDefect ? ` — дефект pos-api ${f.knownPosApiDefect} (contract-report.md)` : ''}${f.detail ? `\n      ${f.detail.slice(0, 400)}` : ''}`);
const onlyKnown = !summary.allGreen && summary.demoFailures === 0;
console.log(`\nвсего ${summary.totalMin} мин; сводка ${arg('--json', `${T1_DIR}/summary.json`)}; ${summary.allGreen ? 'ВСЁ ЗЕЛЁНОЕ' : onlyKnown ? 'ЕСТЬ ПРОВАЛЫ — только известные дефекты pos-api (код 3)' : 'ЕСТЬ ПРОВАЛЫ ДЕМО (код 1)'}`);
process.exit(summary.allGreen ? 0 : onlyKnown ? 3 : 1);
