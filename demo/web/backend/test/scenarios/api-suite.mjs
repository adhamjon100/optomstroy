// Набор API WP-T1 на одном бэкенде (бандл или эталон): подготовка → README 1–6 → негативные ветки → обход операций
// приложения. Возвращает контекст с записями всех запросов (ctx.rec) и проверками (ctx.checks); затем
// validateRecords() сверяет каждый ответ с OpenAPI, coverage() считает покрытие операций приложения.
import { readFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { contract } from '../contract/openapi-validate.mjs';
import { createCtx } from './dsl.mjs';
import { README, setup } from './readme.mjs';
import { negatives } from './negative.mjs';
import { WALK } from './walk.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
export const APP_OPERATIONS = JSON.parse(readFileSync(`${HERE}/app-operations.json`, 'utf8'));

/** Причины, по которым операция приложения не вызывается на демо-бэкенде через мост (для отчёта). */
export const NOT_VIA_BRIDGE = {
  catalog_images_get: 'фото /images/{sha}/{size}.webp — статика сайта (Netlify), не бэкенд-воркер; файлы проверены WP-B4 (900 адресов /catalog/sync/images существуют)',
};

export async function runApiSuite(be, { log = () => {}, label = 'be', only } = {}) {
  const ctx = createCtx(be, { log, label });
  const steps = [['setup', setup], ...README.map((f) => [f.name, f]), ['negatives', negatives], ...WALK.map((f) => [f.name, f])];
  let w = null;
  for (const [name, f] of steps) {
    if (only && name !== 'setup' && !only.includes(name)) continue;
    try {
      if (name === 'setup') w = await f(ctx);
      else await f(w);
    } catch (e) {
      ctx.check(`${ctx.scenario}: сценарий без исключения`, false, String(e?.stack ?? e).slice(0, 1200));
      if (name === 'setup') break;
    }
  }
  ctx.world = w;
  ctx.totalMs = Date.now() - ctx.t0;
  return ctx;
}

/** Сверка записей с контрактом. → [{ key, method, path, status, operationId, errors, warnings }] */
export function validateRecords(records) {
  const C = contract();
  return records.map((r) => {
    const res = C.checkResponse({ method: r.method, url: r.url, status: r.status, headers: r.headers, json: r.json, size: r.size, magic: r.magic });
    return { key: r.key, method: r.method, path: r.path, status: r.status, operationId: res.operationId, template: res.template, errors: res.errors, warnings: res.warnings };
  });
}

/** Покрытие операций приложения: операция покрыта, если хотя бы один её ответ был ожидаемым (2xx или объявленный 4xx). */
export function coverage(records, validations) {
  const byOp = new Map();
  validations.forEach((v, i) => {
    if (!v.operationId) return;
    const r = records[i];
    const e = byOp.get(v.operationId) ?? { calls: 0, ok: 0, statuses: new Set() };
    e.calls++;
    if (r.ok) e.ok++;
    e.statuses.add(r.status);
    byOp.set(v.operationId, e);
  });
  const ops = APP_OPERATIONS.operations;
  const covered = ops.filter((o) => (byOp.get(o.operationId)?.ok ?? 0) > 0);
  const uncovered = ops.filter((o) => !((byOp.get(o.operationId)?.ok ?? 0) > 0)).map((o) => ({ ...o, reason: NOT_VIA_BRIDGE[o.operationId] ?? (byOp.has(o.operationId) ? `вызвана, но без ожидаемого ответа: ${[...byOp.get(o.operationId).statuses].join(',')}` : 'не вызвана сценариями') }));
  const dio = ops.filter((o) => o.viaDio);
  const dioCovered = dio.filter((o) => (byOp.get(o.operationId)?.ok ?? 0) > 0);
  const extra = [...byOp.keys()].filter((id) => !ops.some((o) => o.operationId === id));
  return {
    appTotal: ops.length,
    appCovered: covered.length,
    dioTotal: dio.length,
    dioCovered: dioCovered.length,
    uncovered,
    extraOps: extra,
    byOp: Object.fromEntries([...byOp].map(([k, v]) => [k, { calls: v.calls, ok: v.ok, statuses: [...v.statuses].sort() }])),
  };
}

/** Краткая сводка набора: проверки, неожиданные статусы, 5xx. */
export function summarize(ctx) {
  const failed = ctx.checks.filter((c) => !c.ok);
  const unexpected = ctx.rec.filter((r) => !r.ok);
  const s5xx = ctx.rec.filter((r) => r.status >= 500 || r.status === 0);
  return { checks: ctx.checks.length, checksFailed: failed.length, failed, requests: ctx.rec.length, unexpected: unexpected.map((r) => ({ key: r.key, status: r.status, expect: r.expect, code: r.json?.code ?? null, detail: r.json?.detail ?? null })), status5xx: s5xx.map((r) => ({ key: r.key, status: r.status, code: r.json?.code ?? null })), totalMs: ctx.totalMs };
}
