// Сверка бандла с НАСТОЯЩИМ PostgreSQL (review fixes, critic [18] «parity with local-stack serve on real
// PostgreSQL»). local-stack serve сам занимает порты 3000/8080/8091/8092 (другой workflow) — поэтому тот же сервер
// PostgreSQL 17 (embedded-postgres, как у local-stack) поднимается на свободном порту, а pos-api — тем же кодом демо
// (test/realpg/realpg-runner.mjs): различается ТОЛЬКО слой базы данных (одна сессия PGlite с подсадкой ↔ пулы
// настоящих соединений).
//
//   node demo/web/backend/test/realpg/realpg-diff.mjs [--json <отчёт>] [--no-recheck] [--no-phase-shift]
//
// Прогоны: A — собранный backend.js (PGlite), R — эталон на PostgreSQL, C — снова бандл (шум прогона). Набор API тот
// же, что в differential.test.mjs (README 1–6, негативные ветки, обход операций приложения). Расхождение A↔R, которого
// нет в A↔C и которое повторяется против второго прогона R2, — отличие «одной сессии PGlite» от сервера. C и R2
// стартуют в другой фазе 5-минутной сетки cron, чем A и R (shiftPhase; --no-phase-shift — без пауз).
// Дополнительно:
//   - порядок сортировки: одинаковый набор строк (кириллица/латиница, регистр, ё, цифры) — ORDER BY без COLLATE,
//     lower()/upper()/ILIKE — в PGlite и в базе как у local-stack;
//   - цепочка аудита (audit_verify_chain) после набора на обоих;
//   - видимость незафиксированного и откат подсаженного оператора — по журналу подсадок бандла (pg-shim): какие
//     операторы выполнялись внутри чужой транзакции;
//   - set_config(…, true) держателя (контекст аудита) — по записям audit_logs: actor совпадает на обоих.
// Итог: demo/web/.build/realpg/report.json и report.md; у каждого отличия и каждой гонки — доказательства (evidence).
// Код выхода 0 — отличий слоя БД нет (кроме объяснённых).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { OUT, ROOT } from '../../lib/paths.mjs';
import { startWorkerBackend, SITE } from '../harness/worker-harness.mjs';
import { coverage, runApiSuite, summarize, validateRecords } from '../scenarios/api-suite.mjs';
import { compareRuns, normalizeRecord, subtractNoise } from '../lib/normalize.mjs';
import { buildRealPgReference, RPG_DIR, realPgInputsSha, startRealPg, startRealPgBackend } from './realpg-runner.mjs';

const argv = process.argv.slice(2);
const arg = (k, d) => (argv.includes(k) ? argv[argv.indexOf(k) + 1] : d);
const REPORT = arg('--json', `${RPG_DIR}/report.json`);
process.env.TEMP ||= `${ROOT}/.tmp`;
process.env.TMP ||= `${ROOT}/.tmp`;
const t0 = Date.now();
const say = (...a) => console.log(`[realpg-diff ${((Date.now() - t0) / 60e3).toFixed(1)} мин]`, ...a);
const diffKey = (d) => `${d.key}|${d.kind}|${String(d.path).replace(/\[\d+\]/g, '[]')}`;

async function runOn(label, start) {
  const t = Date.now();
  const errors = [];
  const be = await start({ strict: false, initOpts: { seed: false }, onLog: (lv, m) => lv === 'error' && errors.push(String(m).slice(0, 800)) });
  let ctx;
  let snap = null;
  let stats = null;
  try {
    ctx = await runApiSuite(be, { label });
    snap = (await be.rpc({ type: 'snapcheck' }, 120000)).data ?? null;
    stats = await be.stats().catch(() => null);
  } finally {
    await be.close();
  }
  const validations = validateRecords(ctx.rec);
  say(`${label}: ${ctx.rec.length} запросов, проверок ${ctx.checks.filter((c) => c.ok).length}/${ctx.checks.length}, ${Math.round((Date.now() - t) / 1000)} с`);
  return { label, ms: Date.now() - t, t0: ctx.t0, bootMs: ctx.t0 - t, ctx, summary: summarize(ctx), coverage: coverage(ctx.rec, validations), errors, audit: snap?.audit ?? null, auditActors: snap?.auditActors ?? [], stats, db: be.realPgDb ?? null };
}

// Фаза 5-минутной сетки cron (FIX-demo 2026-11-19). Расписания pg-boss по cron срабатывают по часам: order_status,
// служебные задачи outbox, цикл onec.changes — каждые 5 мин. Задача order_status применяет проекцию заказа и поднимает
// его rowVersion (pos-api/src/orders/order-projection.ts). Попадёт ли срабатывание между шагами набора — зависит от
// фазы прогона в этой сетке. Если прогон длится ≈ 150 с (половина периода; машина под нагрузкой), A и C попадают в одну
// фазу, R и R2 — в другую, и гонка повторяется в обоих прогонах PostgreSQL. Так было в run-all 2026-11-19 (FIX-demo):
// `GET /orders` `$.items[0].audit.rowVersion` 7 ≠ 8 — у A и C 7, у R и R2 8 — и это засчиталось «слоем БД». Поэтому C
// стартует со сдвигом фазы от A, а R2 — от R: разница 100–200 с из 300. Если её нет — пауза до середины периода
// (≤ 300 с). При прогоне ≈ 80 с сдвиг получается сам, пауз нет.
const CRON_PERIOD_MS = 300_000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const phaseWaits = {};
async function shiftPhase(ref, label) {
  if (!ref?.t0 || argv.includes('--no-phase-shift')) return;
  const mod = (x) => ((x % CRON_PERIOD_MS) + CRON_PERIOD_MS) % CRON_PERIOD_MS;
  const d0 = mod(Date.now() + (ref.bootMs ?? 0) - ref.t0);
  if (d0 >= 100_000 && d0 <= 200_000) {
    phaseWaits[label] = { from: ref.label, phaseSec: Math.round(d0 / 1000), waitSec: 0 };
    return;
  }
  const wait = mod(CRON_PERIOD_MS / 2 - d0);
  phaseWaits[label] = { from: ref.label, phaseSec: Math.round(d0 / 1000), waitSec: Math.round(wait / 1000) };
  say(`${label}: пауза ${Math.round(wait / 1000)} с — сдвиг фазы 5-минутной сетки cron от «${ref.label}» (было ${Math.round(d0 / 1000)} с из 300)`);
  await sleep(wait);
}

// Доказательства расхождения (FIX-demo 2026-11-19). Для каждого «отличия слоя БД» и каждой гонки в отчёт пишется
// нормализованное поддерево у пути расхождения во всех прогонах (A, R, C, R2) и время шага от начала набора
// (`at`, scenarios/dsl.mjs). Так следующий случай сразу несёт свой разбор, без разовой пробы. Поддерево — объект,
// в котором лежит отличающееся значение: для `$.items[2].related.length` это `$.items[2]`, для
// `$.entities[10].intervalSec` — `$.entities[10]`. У элемента списка добавляются соседи (±2), чтобы было видно сдвиг
// строк. Размер ограничен (clip), маскировка — как при сравнении (normalizeRecord).
const SEG_RE = /\.([^.[\]]+)|\[(\d+)\]/g;
function pathSegments(path) {
  const p = String(path ?? '');
  if (!p.startsWith('$')) return null;
  const out = [];
  for (const m of p.slice(1).matchAll(SEG_RE)) out.push(m[2] !== undefined ? Number(m[2]) : m[1]);
  return out;
}
function dig(v, segs) {
  let cur = v;
  for (const s of segs) {
    if (cur == null || typeof cur !== 'object') return undefined;
    cur = cur[s];
  }
  return cur;
}
function clip(v, max = 4000) {
  const s = JSON.stringify(v);
  if (s === undefined || s.length <= max) return v;
  if (Array.isArray(v)) return { clipped: true, length: v.length, head: v.slice(0, 3).map((x) => clip(x, Math.floor(max / 4))) };
  return { clipped: true, json: s.slice(0, max) };
}
// время ответа шага по часам (UTC): видно, пришёлся ли шаг рядом со срабатыванием cron
const wallOf = (r, rec) => (rec?.at === undefined || !r.t0 ? null : new Date(r.t0 + rec.at).toISOString());
function evidenceOf(d, runs) {
  const segs = pathSegments(d.path);
  if (d.kind !== 'body' || !segs) {
    // статус, заголовки, PDF, пропавший шаг — хватает статуса и кода ошибки каждого прогона
    return { path: d.path, runs: runs.map((r) => {
      const rec = r.ctx.rec.find((x) => x.key === d.key);
      return { label: r.label, atSec: rec?.at === undefined ? null : +(rec.at / 1000).toFixed(1), wall: wallOf(r, rec), status: rec?.status ?? null, code: rec?.json?.code ?? null };
    }) };
  }
  // `$.items[2].related.length` → `$.items[2]`; `$.items.length` → сам список `$.items` (длина и первые строки)
  const parent = segs.slice();
  if (parent[parent.length - 1] === 'length') {
    parent.pop();
    if (parent.length > 1) parent.pop();
  } else if (parent.length) parent.pop();
  const parentPath = `$${parent.map((s) => (typeof s === 'number' ? `[${s}]` : `.${s}`)).join('')}`;
  const idx = parent.length && typeof parent[parent.length - 1] === 'number' ? parent[parent.length - 1] : null;
  return {
    path: parentPath,
    runs: runs.map((r) => {
      const rec = r.ctx.rec.find((x) => x.key === d.key);
      if (!rec) return { label: r.label, atSec: null, status: null, value: '<нет шага>' };
      const body = normalizeRecord(rec).body;
      const out = { label: r.label, atSec: rec.at === undefined ? null : +(rec.at / 1000).toFixed(1), wall: wallOf(r, rec), status: rec.status, value: clip(dig(body, parent)) };
      if (idx !== null) {
        const list = dig(body, parent.slice(0, -1));
        if (Array.isArray(list)) out.around = list.slice(Math.max(0, idx - 2), idx + 3).map((x, i) => ({ i: Math.max(0, idx - 2) + i, v: clip(x, 800) }));
      }
      return out;
    }),
  };
}

// Порядок сортировки и регистр: одинаковые строки в PGlite (как у бандла) и в базе как у local-stack.
const SAMPLE = ['Ёлка', 'ель', 'Елена', 'ёж', 'Арбуз', 'арбуз', 'Ящик', 'яблоко', 'Zebra', 'apple', 'Apple', '10 мешков', '2 мешка', 'Цемент М500', 'цемент м400', 'ОсОО «Без долга (тест)»', 'Клиент 10 (тест)', 'Клиент 2 (тест)', 'Ъ', 'ь', '_подчёркивание', '-дефис'];
const PROBE_SQL = `WITH s(v) AS (SELECT unnest($1::text[]))
  SELECT (SELECT array_agg(v ORDER BY v) FROM s) AS sorted,
         (SELECT array_agg(lower(v) ORDER BY v) FROM s) AS lowered,
         (SELECT array_agg(upper(v) ORDER BY v) FROM s) AS uppered,
         (SELECT array_agg(v ORDER BY v) FROM s WHERE v ILIKE '%ЦЕМЕНТ%') AS ilike_cement,
         (SELECT array_agg(v ORDER BY v) FROM s WHERE lower(v) LIKE '%ё%') AS like_yo,
         (SELECT datcollate::text || '/' || datctype::text || '/' || datlocprovider::text FROM pg_database WHERE datname = current_database()) AS locale`;

async function collationProbe(pgs) {
  const { PGlite } = await import(pathToFileURL(`${OUT}/pglite/index.js`).href);
  const lite = await PGlite.create('memory://');
  const norm = (r) => ({ ...r, sorted: [...(r.sorted ?? [])], lowered: [...(r.lowered ?? [])], uppered: [...(r.uppered ?? [])], ilike_cement: [...(r.ilike_cement ?? [])], like_yo: [...(r.like_yo ?? [])] });
  const a = norm((await lite.query(PROBE_SQL, [SAMPLE])).rows[0]);
  await lite.close();
  const db = await pgs.createDb();
  const b = norm((await pgs.query(db, PROBE_SQL, [SAMPLE])).rows[0]);
  const same = (k) => JSON.stringify(a[k]) === JSON.stringify(b[k]);
  return { pglite: a, postgres: b, sameOrder: same('sorted'), sameLower: same('lowered'), sameUpper: same('uppered'), sameIlike: same('ilike_cement'), sameLikeYo: same('like_yo') };
}

const report = { at: new Date().toISOString(), build: JSON.parse(readFileSync(`${SITE}/backend/build.json`, 'utf8')).backend.sha256, runs: [], differential: null, probes: {} };
let pgs = null;
try {
  await buildRealPgReference({});
  report.realPgInputs = realPgInputsSha();
  pgs = await startRealPg({ log: say });
  report.postgres = pgs.version;
  report.probes.collation = await collationProbe(pgs);
  say(`сортировка/регистр PGlite ↔ PostgreSQL: порядок ${report.probes.collation.sameOrder ? 'тот же' : 'РАЗНЫЙ'}, lower ${report.probes.collation.sameLower ? '=' : '≠'}, upper ${report.probes.collation.sameUpper ? '=' : '≠'}, ILIKE ${report.probes.collation.sameIlike ? '=' : '≠'}; locale ${report.probes.collation.pglite.locale} ↔ ${report.probes.collation.postgres.locale}`);

  const A = await runOn('бандл (PGlite)', startWorkerBackend);
  const R = await runOn('PostgreSQL', (o) => startRealPgBackend(pgs, o));
  await shiftPhase(A, 'бандл (повтор)');
  const C = await runOn('бандл (повтор)', startWorkerBackend);
  const cmpAR = compareRuns(A.ctx.rec, R.ctx.rec);
  const cmpAC = compareRuns(A.ctx.rec, C.ctx.rec);
  let split = subtractNoise(cmpAR.diffs, cmpAC.diffs);
  let flaky = [];
  let R2 = null;
  if (split.real.length) {
    const cr = new Set(compareRuns(C.ctx.rec, R.ctx.rec).diffs.map(diffKey));
    let cand = split.real.filter((d) => cr.has(diffKey(d)));
    flaky = split.real.filter((d) => !cr.has(diffKey(d))).map((d) => ({ ...d, why: 'нет в C↔R: гонка в прогоне A' }));
    if (cand.length && !argv.includes('--no-recheck')) {
      await shiftPhase(R, 'PostgreSQL (повтор)');
      R2 = await runOn('PostgreSQL (повтор)', (o) => startRealPgBackend(pgs, o));
      const ar2 = new Set(compareRuns(A.ctx.rec, R2.ctx.rec).diffs.map(diffKey));
      flaky.push(...cand.filter((d) => !ar2.has(diffKey(d))).map((d) => ({ ...d, why: 'нет в A↔R2: гонка в прогоне R' })));
      cand = cand.filter((d) => ar2.has(diffKey(d)));
    }
    split = { real: cand, noisy: split.noisy };
  }
  const brief = (r) => r && { label: r.label, ms: r.ms, suiteStartedAt: new Date(r.t0).toISOString(), requests: r.ctx.rec.length, checks: `${r.ctx.checks.filter((c) => c.ok).length}/${r.ctx.checks.length}`, failedChecks: r.ctx.checks.filter((c) => !c.ok).map((c) => `${c.scenario} | ${c.name}`), status5xx: r.summary.status5xx, unexpected: r.summary.unexpected.length, coverage: `${r.coverage.dioCovered}/${r.coverage.dioTotal}`, audit: r.audit, errors: r.errors.slice(0, 10), piggyback: r.stats?.pg ? { piggyback: r.stats.pg.piggyback, byKey: r.stats.pg.piggybackByKey, scope: r.stats.pg.piggyScope, unit: r.stats.pg.piggyUnit, idle: r.stats.pg.piggyIdle, boss: r.stats.pg.piggyBoss } : null };
  report.runs = [brief(A), brief(R), brief(C), brief(R2)].filter(Boolean);
  report.differential = { compared: cmpAR.compared, diffsAR: cmpAR.diffs.length, orderOnlyAR: cmpAR.order, alignedAR: cmpAR.aligned, noiseAC: cmpAC.diffs.length, real: split.real, noise: split.noisy.length, flaky };
  // Авторы действий аудита (set_config(…, true) держателя не «перетекает» на подсаженные операторы): счётчики
  // (действие, телефон автора, роль, итог); расхождение A↔R, которого нет в A↔C (и нет в A↔R2, если был), — отличие.
  const actorMap = (r) => new Map((r?.auditActors ?? []).map((x) => [`${x.action}|${x.actor}|${x.role}|${x.result}`, x.n]));
  const mA = actorMap(A);
  const mR = actorMap(R);
  const mC = actorMap(C);
  const keys = new Set([...mA.keys(), ...mR.keys()]);
  // системные действия (автор «—»: синхронизации по расписанию) зависят от темпа прогона — только для сведения
  const userKey = (k) => k.split('|')[1] !== '—';
  const cand = () => [...keys].filter((k) => userKey(k) && (mA.get(k) ?? 0) !== (mR.get(k) ?? 0) && (mA.get(k) ?? 0) === (mC.get(k) ?? 0));
  if (cand().length && !R2 && !argv.includes('--no-recheck')) {
    await shiftPhase(R, 'PostgreSQL (повтор)');
    R2 = await runOn('PostgreSQL (повтор)', (o) => startRealPgBackend(pgs, o));
  }
  if (R2 && !report.runs.some((r) => r.label === R2.label)) report.runs.push(brief(R2));
  const mR2 = R2 ? actorMap(R2) : null;
  const actorDiffs = [...keys].filter((k) => (mA.get(k) ?? 0) !== (mR.get(k) ?? 0)).map((k) => ({ key: k, user: userKey(k), bundle: mA.get(k) ?? 0, postgres: mR.get(k) ?? 0, repeatBundle: mC.get(k) ?? 0, repeatPostgres: mR2 ? mR2.get(k) ?? 0 : null }));
  const actorReal = actorDiffs.filter((d) => d.user && d.bundle === d.repeatBundle && (d.repeatPostgres === null || d.repeatPostgres === d.postgres));
  report.auditActors = { keys: keys.size, diffs: actorDiffs, real: actorReal };
  report.phaseShift = phaseWaits;
  // доказательства — после всех повторов: R2 мог запустить и разбор авторов аудита
  const evRuns = [A, R, C, R2].filter(Boolean);
  for (const d of [...report.differential.real, ...report.differential.flaky]) d.evidence = evidenceOf(d, evRuns);
  const failsA = A.ctx.checks.filter((c) => !c.ok).map((c) => c.name).sort();
  const failsR = R.ctx.checks.filter((c) => !c.ok).map((c) => c.name).sort();
  report.checks = {
    sameScenarioFailures: JSON.stringify(failsA) === JSON.stringify(failsR),
    onlyBundle: failsA.filter((x) => !failsR.includes(x)),
    onlyPostgres: failsR.filter((x) => !failsA.includes(x)),
    auditChain: { bundle: A.audit, postgres: R.audit },
    zero5xx: { bundle: A.summary.status5xx.length, postgres: R.summary.status5xx.length },
  };
  say(`A↔R: сравнено ${cmpAR.compared}, расхождений ${cmpAR.diffs.length} (шум A↔C ${cmpAC.diffs.length}); слой БД: ${split.real.length}; гонки: ${flaky.length}; только порядок: ${cmpAR.order.length}`);
} catch (e) {
  report.error = String(e?.stack ?? e);
  console.error(report.error);
} finally {
  await pgs?.stop();
}

// ---------------------------------------------------------------- отчёт
mkdirSync(RPG_DIR, { recursive: true });
writeFileSync(REPORT, `${JSON.stringify(report, null, 1)}\n`);
const md = [];
md.push('# Бандл (PGlite) ↔ настоящий PostgreSQL — набор API WP-T1 (review fixes, critic [18])', '');
md.push(`- Когда: ${report.at}; бандл ${String(report.build).slice(0, 12)}…; PostgreSQL ${report.postgres ?? '?'} (embedded-postgres, база как у local-stack serve: builtin C.UTF-8, LC_COLLATE C)`);
if (report.error) md.push('', `**Ошибка прогона:** \`${report.error.split('\n')[0]}\``);
for (const r of report.runs) md.push(`- ${r.label}: ${r.requests} запросов, проверки ${r.checks}, 5xx ${r.status5xx.length}, неожиданных ${r.unexpected}, покрытие Dio ${r.coverage}, цепочка аудита ${JSON.stringify(r.audit)}`);
// сдвиг фазы 5-минутной сетки cron (shiftPhase): фаза — с какой секунды периода начался бы прогон без паузы
for (const [label, p] of Object.entries(report.phaseShift ?? {})) md.push(`- сдвиг фазы cron «${label}» от «${p.from}»: было ${p.phaseSec} с из 300, пауза ${p.waitSec} с`);
if (report.differential) {
  const d = report.differential;
  md.push('', `## Сравнение A↔R`, '', `- сравнено ответов: ${d.compared}; расхождений A↔R ${d.diffsAR}, шум A↔C ${d.noiseAC}; **отличий слоя БД: ${d.real.length}**; гонки с фоном: ${d.flaky.length}; только порядок элементов: ${d.orderOnlyAR.length}`);
  // доказательства (evidenceOf): поддерево у пути и время шага в каждом прогоне; целиком — в report.json
  const evidenceMd = (x) => {
    const e = x.evidence;
    if (!e) return [];
    const lines = [`    - поддерево \`${e.path}\`:`];
    for (const r of e.runs) {
      const v = 'value' in r ? JSON.stringify(r.value)?.slice(0, 400) : `статус ${r.status}${r.code ? ` ${r.code}` : ''}`;
      lines.push(`      - ${r.label}${r.atSec === null ? '' : ` (${r.atSec} с от начала набора${r.wall ? `, ${r.wall.slice(11, 19)} UTC` : ''})`}: \`${v}\``);
      if (r.around) lines.push(`        соседи: ${r.around.map((n) => `[${n.i}] ${JSON.stringify(n.v)?.slice(0, 90)}`).join(' · ')}`);
    }
    return lines;
  };
  for (const x of d.real.slice(0, 40)) md.push(`  - \`${x.kind}\` ${x.key} — \`${x.path}\`: ${JSON.stringify(x.a)?.slice(0, 120)} ≠ ${JSON.stringify(x.b)?.slice(0, 120)}`, ...evidenceMd(x));
  for (const x of d.flaky.slice(0, 40)) md.push(`  - гонка (${x.why}): \`${x.kind}\` ${x.key} — \`${x.path}\`: ${JSON.stringify(x.a)?.slice(0, 120)} ≠ ${JSON.stringify(x.b)?.slice(0, 120)}`, ...evidenceMd(x));
  for (const x of d.orderOnlyAR.slice(0, 20)) md.push(`  - порядок: ${typeof x === 'string' ? x : JSON.stringify(x).slice(0, 200)}`);
  // полные страницы с фоном по расписанию, сравненные по общей части (lib/normalize.mjs alignBackgroundPages)
  for (const x of d.alignedAR ?? []) md.push(`  - фон на полной странице: ${x.key} — строк сценария ${x.a} и ${x.b} (фоновых убрано ${x.droppedA} и ${x.droppedB}), сравнены первые ${Math.min(x.a, x.b)}`);
}
if (report.auditActors) md.push('', '## Авторы действий аудита', '', `- групп (действие, автор, роль, итог): ${report.auditActors.keys}; различий A↔R ${report.auditActors.diffs.length}, из них не объясняемых темпом прогона: ${report.auditActors.real.length}`, ...report.auditActors.diffs.slice(0, 20).map((d) => `  - ${d.key}: бандл ${d.bundle} (повтор ${d.repeatBundle}), PostgreSQL ${d.postgres}${d.repeatPostgres === null ? '' : ` (повтор ${d.repeatPostgres})`}`));
if (report.checks) md.push('', '## Проверки', '', `- одинаковые провалы сценариев: ${report.checks.sameScenarioFailures} (только бандл: ${JSON.stringify(report.checks.onlyBundle)}; только PostgreSQL: ${JSON.stringify(report.checks.onlyPostgres)})`, `- цепочка аудита: бандл ${JSON.stringify(report.checks.auditChain.bundle)}, PostgreSQL ${JSON.stringify(report.checks.auditChain.postgres)}`);
if (report.probes.collation) {
  const c = report.probes.collation;
  md.push('', '## Сортировка и регистр', '', `- locale PGlite ${c.pglite.locale}, PostgreSQL ${c.postgres.locale}`, `- ORDER BY без COLLATE: ${c.sameOrder ? 'одинаково' : 'РАЗНЫЙ порядок'}; lower(): ${c.sameLower ? '=' : '≠'}; upper(): ${c.sameUpper ? '=' : '≠'}; ILIKE: ${c.sameIlike ? '=' : '≠'}; lower LIKE ё: ${c.sameLikeYo ? '=' : '≠'}`, `- порядок PGlite: ${c.pglite.sorted.join(' · ')}`, `- порядок PostgreSQL: ${c.postgres.sorted.join(' · ')}`);
}
writeFileSync(REPORT.replace(/\.json$/, '.md'), `${md.join('\n')}\n`);
say(`отчёт ${REPORT} и .md`);
const ok = !report.error && report.differential && report.differential.real.length === 0 && report.checks?.sameScenarioFailures && report.probes.collation?.sameOrder && (report.auditActors?.real?.length ?? 0) === 0;
process.exit(ok ? 0 : 1);
