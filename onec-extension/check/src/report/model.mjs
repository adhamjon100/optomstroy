// Модель протокола (§3.3): одна структура для HTML, Markdown и JSON. Все строки — через маску ПДн и вычистку секретов.
import os from 'node:os';
import { TOOL_NAME, TOOL_VERSION, CHECKS_CATALOG } from '../util.mjs';
import { CATALOG, GROUPS } from '../checks/index.mjs';
import { VERDICT_RU, KIND_RU } from '../context.mjs';
import { isoBishkek, localOffsetIsBishkek } from './time.mjs';
import { percentile } from '../util.mjs';
import { adviceFor } from '../advice.mjs';

// Шаги контрольного примера (18 §7.2 = Требования §8.3), которые требуют действий в 1С и программа не выполняет.
export const MANUAL_KP = [
  { kp: 'КП-3', what: 'Изменить в 1С цену товара документом установки цен, удалить тестовую характеристику, затем /changes', expect: 'цена и ObjectDeletion в следующем сообщении (частично — C12)' },
  { kp: 'КП-9', what: 'Заказ с автоматической скидкой 1С', expect: 'recalculated=true и суммы 1С' },
  { kp: 'КП-10', what: 'Согласовать заказ в 1С, затем GET /orders/{uuid}/status и /changes', expect: 'статус «согласован» в обоих' },
  { kp: 'КП-11', what: 'Пробная QR-оплата в банке', expect: 'статус paid, документ поступления' },
  { kp: 'КП-12', what: 'POST /payments для этого платежа (kind=qr_bakai)', expect: '200 «уже существует», если интеграция создала документ, иначе 201; в 1С ровно один документ поступления' },
  { kp: 'КП-14', what: 'POST /payments наличными в счёт долга с allocations из двух документов; повтор', expect: 'ПКО с расшифровкой по двум документам; повтор не создаёт второй ПКО' },
  { kp: 'КП-16', what: 'Провести реализацию по заказу, затем /cancel', expect: '409 POS_E_STATE, документ не изменён' },
  { kp: 'КП-17', what: 'POST /returns на 1 шт. по реализации; затем на количество больше отгруженного; согласовать заявку в 1С', expect: '201 submitted; 409 POS_E_STATE; статус accepted' },
  { kp: 'КП-20', what: 'Заблокировать заказ другим сеансом и вызвать /cancel', expect: '503 POS_E_LOCKED (423 — только у /orders и /check)' },
];

/**
 * Полнота прогона: сколько обязательных проверок (не «необязательно», без групп E и L) выполнено и что не проверено.
 * ПРОПУЩЕНО — не проверено; МЕТОДА НЕТ, СВЕДЕНИЯ и остальные — проверено.
 */
export function coverageOf(ctx) {
  const sel = ctx.selected;
  const req = ctx.flags.expectNoAccess
    ? CATALOG.filter((d) => d.id === 'M2')
    : CATALOG.filter((d) => !d.optional && !['E', 'L'].includes(d.group) && (!sel || sel.has(d.id)));
  const groups = { write: [], manual: [], m2: [], other: [] };
  let checked = 0;
  for (const d of req) {
    const r = ctx.get(d.id);
    const v = r && ctx.order.includes(d.id) ? r.verdict : 'SKIP';
    if (v !== 'SKIP') { checked++; continue; }
    if (d.id === 'M2') groups.m2.push(d.id);
    else if (d.write && !ctx.writeAllowed) groups.write.push(d.id);
    else if (d.kind === 'manual' || d.kind === 'semi') groups.manual.push(d.id);
    else groups.other.push(d.id);
  }
  const parts = [];
  if (groups.write.length) parts.push(`запись — запустите Proverka_API_1C_zapis.cmd (${groups.write.join(', ')})`);
  if (groups.manual.length) parts.push(`ручные шаги (${groups.manual.join(', ')})`);
  if (groups.m2.length) parts.push('«нет доступа» с другого компьютера — Proverka_API_1C.cmd --expect-no-access (M2)');
  if (groups.other.length) parts.push(`прочие — причины в таблице (${groups.other.join(', ')})`);
  const complete = checked === req.length;
  const text = `Проверено обязательных ${checked} из ${req.length}${sel ? ' (среди выбранных)' : ''}${complete ? '.' : `; не проверено: ${parts.join('; ')}.`}`;
  return { required: req.length, checked, complete, notChecked: groups, text };
}

export function buildModel(ctx, { startedAt, finishedAt, exitCode, aborted, nothingChecked = false }) {
  // Сначала вычистка секретов, затем маска ПДн, затем ещё раз вычистка (маска не должна «разрезать» секрет).
  const clean = (s) => (typeof s === 'string' ? ctx.redactor.redact(ctx.masker.maskText(ctx.redactor.redact(s))) : s);
  const deep = (v) => {
    if (typeof v === 'string') return clean(v);
    if (Array.isArray(v)) return v.map(deep);
    if (v && typeof v === 'object') { const o = {}; for (const [k, x] of Object.entries(v)) o[k] = deep(x); return o; }
    return v;
  };
  const summary = { PASS: 0, FAIL: 0, WARN: 0, SKIP: 0, MANUAL_YES: 0, MANUAL_NO: 0, ABSENT: 0, INFO: 0 };
  const checks = [];
  const ids = new Set(ctx.order);
  for (const d of CATALOG) {
    if (!ids.has(d.id)) continue;
    const r = ctx.get(d.id);
    if (!r) continue;
    const v = r.verdict;
    summary[v]++;
    // Где: у находки без места — первый запрос проверки (метод и путь) или сама проверка.
    const defWhere = r.requests.length ? `${d.id}: ${r.requests[0].method} ${r.requests[0].path}` : `${d.id}: ${d.title}`;
    checks.push({
      id: d.id, group: d.group, groupTitle: GROUPS[d.group], title: d.title, kind: d.kind, kindRu: KIND_RU[d.kind] || d.kind,
      write: d.write, optional: d.optional, sources: d.sources,
      verdict: v, verdictRu: VERDICT_RU[v], summary: clean(r.summaryLine),
      findings: r.findings.map((f) => ({
        severity: f.severity, rule: f.rule, code: f.code, where: clean(f.where || (f.severity === 'FAIL' ? defWhere : null)), text: clean(f.text),
        hint: f.severity === 'FAIL' || f.severity === 'WARN' ? adviceFor(d, f) : f.hint, count: f.count,
      })),
      findingsTruncated: r.findingsTruncated,
      advice: v === 'MANUAL_NO' ? adviceFor(d, { code: 'manual-no' }) : null,
      notes: r.notes.map(clean),
      manual: r.manual ? { question: clean(r.manual.question), answer: r.manual.answer, at: isoBishkek(r.manual.at) } : null,
      requests: r.requests.map((q) => ({ ...q, path: clean(q.path), error: clean(q.error) })),
      exchanges: deep(r.exchanges),
      evidence: deep(r.evidence),
      ms: r.ms,
    });
  }
  const timings = {};
  for (const [op, t] of ctx.timings) {
    timings[op] = { count: t.ms.length, p50: Math.round(percentile(t.ms, 50)), p95: Math.round(percentile(t.ms, 95)), max: Math.round(Math.max(...t.ms)), timeoutMs: t.timeoutMs };
  }
  const h = ctx.data.health || {};
  const b = ctx.http?.base;
  const tls = ctx.data.tls;
  return {
    format: 'optomstroy-onec-check-protocol', formatVersion: 2,
    tool: { name: TOOL_NAME, version: TOOL_VERSION, checksCatalog: CHECKS_CATALOG, programSha256: ctx.contract.meta.programSha256 || null, programModified: !!ctx.contract.meta.programModified },
    contract: { version: ctx.contract.version, yamlSha256: ctx.contract.meta.yamlSha256, jsonSha256: ctx.contract.meta.jsonSha256 || null, gitBlob: ctx.contract.meta.gitBlob },
    requirements: '1.2.1',
    startedAt: isoBishkek(startedAt), finishedAt: isoBishkek(finishedAt),
    timezoneNote: localOffsetIsBishkek() ? null : 'часовой пояс компьютера не +06:00 — время в протоколе приведено к Бишкеку',
    target: b ? {
      host: b.host, port: b.port, scheme: b.scheme,
      tls: b.scheme === 'https' ? {
        protocol: tls?.protocol || null, verified: !!tls?.verified && !ctx.flags.insecure, insecure: !!ctx.flags.insecure,
        caFile: !!ctx.caFile, subject: clean(tls?.subject || null), issuer: clean(tls?.issuer || null), validTo: tls?.validTo || null,
      } : null,
    } : null,
    auth: { user: ctx.settings?.user || null, scheme: ctx.settings?.auth || null },
    mode: {
      allowWrite: !!ctx.flags.allowWrite || !!ctx.demo, writeConfirmed: !!ctx.writeConfirmed, demo: !!ctx.demo, demoDefect: ctx.flags.demoDefect || null,
      manual: ctx.manualAllowed, expectNoAccess: !!ctx.flags.expectNoAccess,
    },
    health: { apiVersion: h.apiVersion ?? null, extensionVersion: h.extensionVersion ?? null, platform: h.platform ?? null, configuration: h.configuration ?? null, configurationVersion: h.configurationVersion ?? null },
    summary, exitCode, aborted: aborted ? clean(aborted) : null, nothingChecked,
    coverage: coverageOf(ctx),
    banners: ctx.banners.map(clean),
    checks,
    createdObjects: deep(ctx.registry.created),
    exchangePlanChanges: deep(ctx.registry.exchangePlan),
    timings,
    environment: { node: process.version, os: `${os.type()} ${os.release()}`, arch: process.arch },
    manualKp: MANUAL_KP,
  };
}
