// Сверка бандла с НАСТОЯЩИМ PostgreSQL (review fixes, critic [18] «parity with local-stack serve on real
// PostgreSQL»). local-stack serve сам занимает порты 3000/8080/8091/8092 (другой workflow) — поэтому тот же сервер
// PostgreSQL 17 (embedded-postgres, как у local-stack) поднимается на свободном порту, а pos-api — тем же кодом демо
// (test/realpg/realpg-runner.mjs): различается ТОЛЬКО слой базы данных (одна сессия PGlite с подсадкой ↔ пулы
// настоящих соединений).
//
//   node demo/web/backend/test/realpg/realpg-diff.mjs [--json <отчёт>] [--no-recheck]
//
// Прогоны: A — собранный backend.js (PGlite), R — эталон на PostgreSQL, C — снова бандл (шум прогона). Набор API тот
// же, что в differential.test.mjs (README 1–6, негативные ветки, обход операций приложения). Расхождение A↔R, которого
// нет в A↔C и которое повторяется против второго прогона R2, — отличие «одной сессии PGlite» от сервера.
// Дополнительно:
//   - порядок сортировки: одинаковый набор строк (кириллица/латиница, регистр, ё, цифры) — ORDER BY без COLLATE,
//     lower()/upper()/ILIKE — в PGlite и в базе как у local-stack;
//   - цепочка аудита (audit_verify_chain) после набора на обоих;
//   - видимость незафиксированного и откат подсаженного оператора — по журналу подсадок бандла (pg-shim): какие
//     операторы выполнялись внутри чужой транзакции;
//   - set_config(…, true) держателя (контекст аудита) — по записям audit_logs: actor совпадает на обоих.
// Итог: demo/web/.build/realpg/report.json и report.md. Код выхода 0 — отличий слоя БД нет (кроме объяснённых).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { OUT, ROOT } from '../../lib/paths.mjs';
import { startWorkerBackend, SITE } from '../harness/worker-harness.mjs';
import { coverage, runApiSuite, summarize, validateRecords } from '../scenarios/api-suite.mjs';
import { compareRuns, subtractNoise } from '../lib/normalize.mjs';
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
  const be = await start({ sku: 500, strict: false, initOpts: { seed: false }, onLog: (lv, m) => lv === 'error' && errors.push(String(m).slice(0, 800)) });
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
  return { label, ms: Date.now() - t, ctx, summary: summarize(ctx), coverage: coverage(ctx.rec, validations), errors, audit: snap?.audit ?? null, auditActors: snap?.auditActors ?? [], stats, db: be.realPgDb ?? null };
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
      R2 = await runOn('PostgreSQL (повтор)', (o) => startRealPgBackend(pgs, o));
      const ar2 = new Set(compareRuns(A.ctx.rec, R2.ctx.rec).diffs.map(diffKey));
      flaky.push(...cand.filter((d) => !ar2.has(diffKey(d))).map((d) => ({ ...d, why: 'нет в A↔R2: гонка в прогоне R' })));
      cand = cand.filter((d) => ar2.has(diffKey(d)));
    }
    split = { real: cand, noisy: split.noisy };
  }
  const brief = (r) => r && { label: r.label, ms: r.ms, requests: r.ctx.rec.length, checks: `${r.ctx.checks.filter((c) => c.ok).length}/${r.ctx.checks.length}`, failedChecks: r.ctx.checks.filter((c) => !c.ok).map((c) => `${c.scenario} | ${c.name}`), status5xx: r.summary.status5xx, unexpected: r.summary.unexpected.length, coverage: `${r.coverage.dioCovered}/${r.coverage.dioTotal}`, audit: r.audit, errors: r.errors.slice(0, 10), piggyback: r.stats?.pg ? { piggyback: r.stats.pg.piggyback, byKey: r.stats.pg.piggybackByKey, scope: r.stats.pg.piggyScope, unit: r.stats.pg.piggyUnit, idle: r.stats.pg.piggyIdle, boss: r.stats.pg.piggyBoss } : null };
  report.runs = [brief(A), brief(R), brief(C), brief(R2)].filter(Boolean);
  report.differential = { compared: cmpAR.compared, diffsAR: cmpAR.diffs.length, orderOnlyAR: cmpAR.order, noiseAC: cmpAC.diffs.length, real: split.real, noise: split.noisy.length, flaky };
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
  if (cand().length && !R2 && !argv.includes('--no-recheck')) R2 = await runOn('PostgreSQL (повтор)', (o) => startRealPgBackend(pgs, o));
  if (R2 && !report.runs.some((r) => r.label === R2.label)) report.runs.push(brief(R2));
  const mR2 = R2 ? actorMap(R2) : null;
  const actorDiffs = [...keys].filter((k) => (mA.get(k) ?? 0) !== (mR.get(k) ?? 0)).map((k) => ({ key: k, user: userKey(k), bundle: mA.get(k) ?? 0, postgres: mR.get(k) ?? 0, repeatBundle: mC.get(k) ?? 0, repeatPostgres: mR2 ? mR2.get(k) ?? 0 : null }));
  const actorReal = actorDiffs.filter((d) => d.user && d.bundle === d.repeatBundle && (d.repeatPostgres === null || d.repeatPostgres === d.postgres));
  report.auditActors = { keys: keys.size, diffs: actorDiffs, real: actorReal };
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
if (report.differential) {
  const d = report.differential;
  md.push('', `## Сравнение A↔R`, '', `- сравнено ответов: ${d.compared}; расхождений A↔R ${d.diffsAR}, шум A↔C ${d.noiseAC}; **отличий слоя БД: ${d.real.length}**; гонки с фоном: ${d.flaky.length}; только порядок элементов: ${d.orderOnlyAR.length}`);
  for (const x of d.real.slice(0, 40)) md.push(`  - \`${x.kind}\` ${x.key} — \`${x.path}\`: ${JSON.stringify(x.a)?.slice(0, 120)} ≠ ${JSON.stringify(x.b)?.slice(0, 120)}`);
  for (const x of d.orderOnlyAR.slice(0, 20)) md.push(`  - порядок: ${typeof x === 'string' ? x : JSON.stringify(x).slice(0, 200)}`);
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
