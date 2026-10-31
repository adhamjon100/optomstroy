// Отчёты WP-T1: группировка несоответствий контракту (бандл / эталон) и demo/web/.build/contract-report.md.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { BUILD } from '../../lib/paths.mjs';

export const T1_DIR = `${BUILD}/t1`;
export const CONTRACT_REPORT = `${BUILD}/contract-report.md`;
/** Дефекты pos-api, видимые и на эталоне (не шимы): test/pos-api-defects.json — в отчёт, не скрываются (fix round 1). */
export const POS_API_DEFECTS = fileURLToPath(new URL('../pos-api-defects.json', import.meta.url));
export function loadPosApiDefects() {
  try {
    return existsSync(POS_API_DEFECTS) ? (JSON.parse(readFileSync(POS_API_DEFECTS, 'utf8')).items ?? []) : [];
  } catch {
    return [];
  }
}

export function writeJson(file, data) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(data, (k, v) => (typeof v === 'bigint' ? `${v}n` : v), 1));
}

/** Ошибку проверки → обобщённый вид (индексы массивов, значения) для группировки. */
const genericError = (e) => e.replace(/\[\d+\]/g, '[]').replace(/: "[^"]*"/g, ': "…"').replace(/(\d{2,})/g, (m) => (m.length > 6 ? '…' : m));

/**
 * Сгруппировать несоответствия контракту двух прогонов. → [{ operationId, status, error, bundle, reference, examples }]
 * bundle/reference — число ответов с этой ошибкой в прогоне. «Только бандл» — артефакт шимов (блокирует); «оба» —
 * расхождение pos-api с контрактом (в отчёт, не блокирует).
 */
export function groupContract(valA, valB) {
  const groups = new Map();
  const add = (v, side) => {
    for (const e of v.errors) {
      const k = `${v.operationId ?? v.path}|${v.status}|${genericError(e)}`;
      const g = groups.get(k) ?? { operationId: v.operationId ?? '(нет в контракте)', template: v.template ?? v.path, status: v.status, error: genericError(e), bundle: 0, reference: 0, examples: [] };
      g[side]++;
      if (g.examples.length < 3 && !g.examples.includes(v.key)) g.examples.push(v.key);
      groups.set(k, g);
    }
  };
  for (const v of valA) add(v, 'bundle');
  for (const v of valB ?? []) add(v, 'reference');
  return [...groups.values()].sort((a, b) => a.operationId.localeCompare(b.operationId) || a.status - b.status);
}

const md = (t) => String(t ?? '').replace(/\|/g, '\\|').replace(/\n/g, ' ');

export function contractMarkdown({ groups, warnings, coverage, build, at, runs, defects = loadPosApiDefects() }) {
  const both = groups.filter((g) => g.bundle > 0 && g.reference > 0);
  const onlyBundle = groups.filter((g) => g.bundle > 0 && g.reference === 0);
  const onlyRef = groups.filter((g) => g.bundle === 0 && g.reference > 0);
  const row = (g) => `| \`${g.operationId}\` | ${g.status} | ${g.error.replace(/\|/g, '\\|')} | ${g.bundle} | ${g.reference} | ${g.examples.map((x) => x.replace(/\|/g, '/')).join('<br>')} |`;
  const head = '| Операция | HTTP | Несоответствие | Бандл | Эталон | Примеры шагов |\n|---|---|---|---|---|---|';
  const lines = [
    '# WP-T1: ответы демо-бэкенда против contracts/openapi/pos-api.v1.yaml',
    '',
    `Сформировано: ${at}. Бандл \`site/backend/backend.js\` sha256 \`${build?.backend?.sha256?.slice(0, 12) ?? '?'}…\`, HEAD \`${build?.gitHead?.slice(0, 12) ?? '?'}\`, ключ эпохи \`${build?.epochKey ?? '?'}\`.`,
    `Прогоны: ${runs.map((r) => `${r.label} — ${r.requests} ответов`).join('; ')}. Проверка: test/contract/openapi-validate.mjs (строгий режим: поля вне схемы — ошибка; 4xx/5xx — Problem, code ∈ ProblemCode, HTTP-статус по contracts/enums.json).`,
    '',
    '## Итог',
    '',
    `- Несоответствий, которые есть **и у бандла, и у эталона** (pos-api в Node без браузерных шимов): **${both.length}** групп — это расхождения pos-api с контрактом, демо они не блокируют (plan §4 WP-T1).`,
    `- Несоответствий **только у бандла** (артефакт шимов, блокирует): **${onlyBundle.length}**.`,
    `- Только у эталона: ${onlyRef.length}.`,
    `- Покрытие операций приложения: ${coverage.dioCovered} из ${coverage.dioTotal} операций Dio (все операции приложения: ${coverage.appCovered} из ${coverage.appTotal}).`,
    `- Дефектов pos-api вне контракта, видимых и на эталоне: открытых ${defects.filter((d) => d.status !== 'исправлен').length} (${defects.filter((d) => d.status !== 'исправлен').map((d) => d.id).join(', ') || '—'}), исправленных ${defects.filter((d) => d.status === 'исправлен').length} (${defects.filter((d) => d.status === 'исправлен').map((d) => d.id).join(', ') || '—'}) — раздел ниже.`,
    '',
    '## Расхождения pos-api с контрактом (бандл и эталон)',
    '',
    both.length ? head : '_нет_',
    ...both.map(row),
    '',
    '## Дефекты pos-api вне контракта (бандл и эталон, не шимы)',
    '',
    'Найдены сценариями WP-T1 и воспроизводятся на эталоне (тот же pos-api в Node без браузерных шимов). В демо не скрываются: исходники pos-api не меняются, подмен сборкой нет. Источник — `demo/web/backend/test/pos-api-defects.json`.',
    '',
    ...(defects.length
      ? ['| № | Дефект | Проявление и доказательство | Причина | Файлы | Направление исправления | Тесты | Статус |', '|---|---|---|---|---|---|---|---|', ...defects.map((d) => `| ${d.id} | ${md(d.title)} | ${md(d.symptom)}<br>${md(d.evidence)} | ${md(d.cause)} | ${(d.files ?? []).map(md).join('<br>')} | ${md(d.fix_direction)} | ${(d.tests ?? []).map(md).join(', ')} | ${md(d.status)} |`)]
      : ['_нет_']),
    '',
    '## Только у бандла (артефакт шимов)',
    '',
    onlyBundle.length ? head : '_нет_',
    ...onlyBundle.map(row),
    '',
    ...(onlyRef.length ? ['## Только у эталона', '', head, ...onlyRef.map(row), ''] : []),
    '## Статусы, не объявленные в responses операции (предупреждения, покрыты `default: Problem`)',
    '',
    warnings.length ? '| Операция | HTTP | Раз |\n|---|---|---|' : '_нет_',
    ...warnings.map((w) => `| \`${w.operationId}\` | ${w.status} | ${w.n} |`),
    '',
    '## Операции приложения без покрытия',
    '',
    coverage.uncovered.length ? '| Операция | Метод и путь | Причина |\n|---|---|---|' : '_нет_',
    ...coverage.uncovered.map((o) => `| \`${o.operationId}\` | ${o.method} ${o.path} | ${o.reason} |`),
    '',
    '## Не проверено здесь',
    '',
    '- Паритет с настоящим PostgreSQL (local-stack serve) отложен на следующий этап: порты 3000/8080/8091/8092 заняты другим workflow. Эталон дифференциального теста — тот же pg-shim на PGlite, поэтому различия одного соединения (подсадка, видимость незафиксированных данных, сортировка `datcollate=C`) этим отчётом не ловятся. Разбор типов приведён к node-postgres (pg-types 2.2.0 и `types` drizzle, fix round 1) и закреплён тестами pg-shim.test.mjs, а не сравнением с настоящим PostgreSQL.',
    '',
  ];
  return lines.join('\n');
}

export function writeContractReport(data) {
  mkdirSync(BUILD, { recursive: true });
  writeFileSync(CONTRACT_REPORT, contractMarkdown(data));
  return CONTRACT_REPORT;
}

/** Предупреждения (необъявленные статусы) — сводно. */
export function groupWarnings(vals) {
  const m = new Map();
  for (const v of vals)
    for (const w of v.warnings) {
      if (!/не объявлен/.test(w)) continue;
      const k = `${v.operationId}|${v.status}`;
      m.set(k, { operationId: v.operationId, status: v.status, n: (m.get(k)?.n ?? 0) + 1 });
    }
  return [...m.values()].sort((a, b) => a.operationId.localeCompare(b.operationId));
}
