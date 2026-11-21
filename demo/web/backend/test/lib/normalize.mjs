// Нормализация и сравнение записей ответов двух прогонов (WP-T1 differential.test.mjs): бандл ↔ эталон и
// бандл ↔ бандл (уровень шума). Маскируются значения, которые различаются от прогона к прогону сами по себе:
// UUID, время ISO, JWT и непрозрачные токены/курсоры, requestId, ETag, длительности и возраст в секундах.
// Номера заказов/платежей/«1С» НЕ маскируются: сценарий детерминирован (сид истории выключен), и расхождение
// в них — сигнал, а не шум.

const UUID_G = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
const TS_G = /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}(?::?\d{2})?)?/g;
const JWT = /^[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*$/;
/** Ключи, значения которых непрозрачны и меняются от прогона к прогону. */
const OPAQUE_KEYS = /^(accessToken|refreshToken|registrationToken|stepUpToken|previewToken|token|nextCursor|cursor|prevCursor|etag|requestId|instance|idempotencyKey|challengeId|linkId|code|payload|emergencyCode|loginCode|sid|jti|hash|chainHash|prevHash|rowHash|signature)$/;
/** Значения-идентификаторы имитатора «1С» со случайной или временной частью (QR, банковская ссылка, реализация). */
const FAKE_REFS = [
  [/\bQR-[0-9A-F]{8}\b/g, 'QR-<ref>'],
  [/\bBK-\d{10,}\b/g, 'BK-<ms>'],
  [/РТ-ДЕМО-[0-9a-f]{8}/g, 'РТ-ДЕМО-<id8>'],
];
/**
 * Ключи-длительности и «возраст»: зависят от темпа прогона. retryAfter — остаток паузы в секундах (тело ответа OTP
 * и Problem 429; заголовок Retry-After маскируется в normalizeRecord так же): на PostgreSQL прогон медленнее, и
 * остаток выходит на секунду меньше (realpg 2026-11-19, «login … otp/request» `$.retryAfter` 7 ≠ 6).
 */
const TIMING_KEYS = /^(ageSec|ageMinutes|ageSeconds|durationMs|ms|elapsedMs|remainingSec|remainingSeconds|expiresInSec|waitedMs|lagSec|staleForSec|retryAfter)$/;

export function normString(s, key) {
  if (key && (OPAQUE_KEYS.test(key) || /Hash$/.test(key))) {
    // code — также поле Problem (код ошибки) и кода OTP: коды ошибок (ЗАГЛАВНЫЕ) не маскируются
    if (key === 'code' && /^[A-Z][A-Z0-9_]+$/.test(s)) return s;
    if (key === 'payload' && !/\|/.test(s)) return s;
    return `<${key}>`;
  }
  if (JWT.test(s)) return '<jwt>';
  let out = s.replace(UUID_G, '<uuid>').replace(TS_G, '<ts>');
  for (const [re, to] of FAKE_REFS) out = out.replace(re, to);
  return out;
}

export function normalize(v, key = null) {
  if (v === null || v === undefined) return v;
  if (Array.isArray(v)) return v.map((x) => normalize(x, key));
  if (typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v).sort()) out[k] = normalize(v[k], k);
    return out;
  }
  if (typeof v === 'string') return normString(v, key);
  if (typeof v === 'number' && key && TIMING_KEYS.test(key)) return '<n>';
  return v;
}

/**
 * Фон — строки, время появления которых задаёт не шаг сценария, а задачи pg-boss и таймеры worker. Из списков
 * /sync/runs и /admin/audit-logs они убираются до сравнения; строки сценария остаются.
 *  - Прогоны синхронизации по cron (trigger 'schedule') и их записи аудита (actor null, sync.*): появляются по часам,
 *    их число зависит от длительности прогона — эталон в Node на 20–25 % медленнее бандла. Ручные прогоны сценария
 *    (trigger 'manual') остаются.
 *  - Системные записи заказов и outbox (actor null и вне HTTP-запроса — requestId null): order.submitted и
 *    order.status_changed пишет задача ordersOnecConfirmed (pos-api/src/orders/worker/order-onec-results.handler.ts),
 *    outbox.* — отправка outbox, customer.updated — подтверждение клиента «1С». Это задачи pg-boss. В демо (шим) задача
 *    просыпается сразу — NOTIFY в том же процессе. На настоящем pg-boss задачу забирает опрос очереди раз в 2 с
 *    (pos-api/src/jobs/orders/orders-worker.wiring.ts, pollingIntervalSeconds: 2). Поэтому на PostgreSQL строка
 *    встаёт после следующего шага сценария: README 5 «аудит за период» `$.items[1].action` auth.pin.set ≠
 *    order.submitted (realpg 2026-11-19, 3 из 4 прогонов PostgreSQL, wave2:DEMO-E2E). Те же действия проверка «Авторы
 *    действий аудита» (realpg/realpg-diff.mjs) считает темпом фона — автор «—».
 * Полную страницу (`limit=200`), с которой фон вытеснил разное число строк сценария, выравнивает
 * alignBackgroundPages: разница длин равна разнице убранных строк.
 */
const SYSTEM_JOB_AUDIT = /^(?:order\.(?:submitted|status_changed)|customer\.updated|outbox\..+)$/;
const isBackgroundAudit = (it) =>
  it?.actor == null &&
  ((/^sync\./.test(it?.action ?? '') && it?.after?.trigger !== 'manual') || (it?.requestId == null && SYSTEM_JOB_AUDIT.test(it?.action ?? '')));
const BACKGROUND_FILTERS = [
  [/^\/api\/v1\/sync\/runs$/, (it) => it?.trigger !== 'schedule'],
  [/^\/api\/v1\/admin\/audit-logs$/, (it) => !isBackgroundAudit(it)],
];
function dropBackground(r) {
  const f = BACKGROUND_FILTERS.find(([re]) => re.test(r.path ?? ''));
  if (!f || !Array.isArray(r.json?.items)) return r.json;
  return { ...r.json, items: r.json.items.filter(f[1]) };
}

/**
 * Страница списка с фоном по расписанию: { full, dropped } | null. full — сервер вернул страницу целиком (строк
 * столько, сколько `limit` запроса; без `limit` — есть курсор продолжения), dropped — сколько фоновых строк убрал
 * dropBackground.
 */
function backgroundPage(r) {
  const f = BACKGROUND_FILTERS.find(([re]) => re.test(r.path ?? ''));
  if (!f || !Array.isArray(r.json?.items)) return null;
  const items = r.json.items;
  const limit = Number((/[?&]limit=(\d+)/.exec(r.url ?? '') ?? [])[1] ?? NaN);
  const full = Number.isFinite(limit) ? items.length >= limit : r.json.nextCursor != null;
  return { full, dropped: items.length - items.filter(f[1]).length };
}

/**
 * Выравнивание полной страницы с фоном (run-all 2026-11-18, сверка с PostgreSQL: «аудит за период» `limit=200` —
 * `$.items.length` 189 ≠ 188). Новые строки идут сверху, страница обрезана по `limit`; фоновые строки (синхронизации
 * по расписанию, их число зависит от темпа прогона) вытесняют с конца столько же строк сценария: на бандле страница
 * полная (200 строк и курсор), фоновых 11 — dropBackground оставляет 189, на PostgreSQL фоновых на одну больше — 188.
 * Если обе страницы полные и разница длин равна разнице убранных фоновых строк — строки сценария сравниваются по
 * общей части (более длинная укорачивается до длины другой), курсор продолжения — как «есть». Иначе ничего не
 * меняется. Пропавшая или лишняя строка сценария в общей части остаётся расхождением (сдвигает строки за ней).
 * → { a, b, droppedA, droppedB } (для отчёта) | null.
 */
function alignBackgroundPages(a, b, na, nb) {
  const pa = backgroundPage(a);
  const pb = backgroundPage(b);
  const ia = na.body?.items;
  const ib = nb.body?.items;
  if (!pa || !pb || !pa.full || !pb.full || !Array.isArray(ia) || !Array.isArray(ib) || ia.length === ib.length) return null;
  if (ia.length - ib.length !== pb.dropped - pa.dropped) return null;
  const n = Math.min(ia.length, ib.length);
  const out = { a: ia.length, b: ib.length, droppedA: pa.dropped, droppedB: pb.dropped };
  na.body = { ...na.body, items: ia.slice(0, n) };
  nb.body = { ...nb.body, items: ib.slice(0, n) };
  if ('nextCursor' in na.body || 'nextCursor' in nb.body) na.body.nextCursor = nb.body.nextCursor = '<nextCursor>';
  return out;
}

const HEADER_KEYS = ['content-type', 'cache-control', 'idempotent-replayed', 'x-min-app-version', 'x-recommended-app-version', 'content-disposition', 'content-language', 'retry-after'];
export function normalizeRecord(r) {
  const headers = {};
  for (const h of HEADER_KEYS) if (r.headers?.[h] !== undefined) headers[h] = h === 'retry-after' ? '<n>' : normString(String(r.headers[h]).replace(/;\s*charset=utf-8/i, '; charset=utf-8'));
  headers.etag = r.headers?.etag ? '<present>' : undefined;
  const isPdf = /application\/pdf/.test(r.headers?.['content-type'] ?? '');
  return {
    status: r.status,
    headers,
    body: isPdf ? { pdf: r.magic, size: r.size } : r.json !== undefined ? normalize(dropBackground(r)) : { size: r.size > 0 ? 'non-empty' : 0 },
  };
}

/** Первая разница двух нормализованных значений → { path, a, b } | null. */
export function firstDiff(a, b, path = '$') {
  if (a === b) return null;
  if (typeof a !== typeof b || a === null || b === null || Array.isArray(a) !== Array.isArray(b)) return { path, a, b };
  if (Array.isArray(a)) {
    if (a.length !== b.length) return { path: `${path}.length`, a: a.length, b: b.length };
    for (let i = 0; i < a.length; i++) {
      const d = firstDiff(a[i], b[i], `${path}[${i}]`);
      if (d) return d;
    }
    return null;
  }
  if (typeof a === 'object') {
    const ka = Object.keys(a);
    const kb = Object.keys(b);
    for (const k of new Set([...ka, ...kb])) {
      if (!(k in a)) return { path: `${path}.${k}`, a: '<нет>', b: b[k] };
      if (!(k in b)) return { path: `${path}.${k}`, a: a[k], b: '<нет>' };
      const d = firstDiff(a[k], b[k], `${path}.${k}`);
      if (d) return d;
    }
    return null;
  }
  return { path, a, b };
}

const sortDeep = (v) => (Array.isArray(v) ? v.map(sortDeep).map((x) => JSON.stringify(x)).sort() : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, sortDeep(x)])) : v);

/**
 * Сравнить записи прогонов A и B по ключам шагов. → { compared, equal, diffs: [{ key, kind, path, a, b }] }
 * kind: 'missing' (шаг есть только в одном прогоне), 'status', 'headers', 'body', 'pdf-size'; разница только в
 * порядке элементов массивов — 'order' (отдельно, не считается расхождением данных). aligned — полные страницы с
 * фоном, сравненные по общей части (alignBackgroundPages): { key, a, b, droppedA, droppedB }.
 */
export function compareRuns(recA, recB, { pdfTolerance = 0.05 } = {}) {
  const ma = new Map(recA.map((r) => [r.key, r]));
  const mb = new Map(recB.map((r) => [r.key, r]));
  const diffs = [];
  const order = [];
  const aligned = [];
  let compared = 0;
  for (const k of new Set([...ma.keys(), ...mb.keys()])) {
    const a = ma.get(k);
    const b = mb.get(k);
    if (!a || !b) {
      diffs.push({ key: k, kind: 'missing', path: '', a: a ? `${a.status}` : '<нет шага>', b: b ? `${b.status}` : '<нет шага>' });
      continue;
    }
    compared++;
    const na = normalizeRecord(a);
    const nb = normalizeRecord(b);
    if (na.status !== nb.status) {
      diffs.push({ key: k, kind: 'status', path: 'status', a: `${na.status} ${a.json?.code ?? ''}`.trim(), b: `${nb.status} ${b.json?.code ?? ''}`.trim() });
      continue;
    }
    const hd = firstDiff(na.headers, nb.headers, 'headers');
    if (hd) diffs.push({ key: k, kind: 'headers', ...hd });
    if (na.body?.pdf !== undefined || nb.body?.pdf !== undefined) {
      if (na.body?.pdf !== nb.body?.pdf) diffs.push({ key: k, kind: 'body', path: 'pdf', a: na.body?.pdf, b: nb.body?.pdf });
      else if (Math.abs((na.body.size ?? 0) - (nb.body.size ?? 0)) > pdfTolerance * Math.max(na.body.size ?? 0, nb.body.size ?? 0)) diffs.push({ key: k, kind: 'pdf-size', path: 'size', a: na.body.size, b: nb.body.size });
      continue;
    }
    const al = alignBackgroundPages(a, b, na, nb);
    if (al) aligned.push({ key: k, ...al });
    const bd = firstDiff(na.body, nb.body, '$');
    if (bd) {
      if (!firstDiff(sortDeep(na.body), sortDeep(nb.body))) order.push({ key: k, kind: 'order', ...bd });
      else diffs.push({ key: k, kind: 'body', ...bd });
    }
  }
  return { compared, keysA: ma.size, keysB: mb.size, diffs, order, aligned };
}

/** Расхождения A↔B, которых нет среди расхождений A↔C (шум прогона бандла с самим собой). */
export function subtractNoise(diffsAB, diffsAC) {
  const noise = new Set(diffsAC.map((d) => `${d.key}|${d.kind}|${String(d.path).replace(/\[\d+\]/g, '[]')}`));
  const real = [];
  const noisy = [];
  for (const d of diffsAB) (noise.has(`${d.key}|${d.kind}|${String(d.path).replace(/\[\d+\]/g, '[]')}`) ? noisy : real).push(d);
  return { real, noisy };
}
