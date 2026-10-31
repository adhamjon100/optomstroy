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
/** Ключи-длительности и «возраст»: зависят от темпа прогона. */
const TIMING_KEYS = /^(ageSec|ageMinutes|ageSeconds|durationMs|ms|elapsedMs|remainingSec|remainingSeconds|expiresInSec|waitedMs|lagSec|staleForSec)$/;

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
 * Фон по расписанию: прогоны синхронизации pg-boss по cron (trigger 'schedule') и их записи аудита (actor null,
 * sync.*) появляются по часам, и их число зависит от длительности прогона — эталон в Node на 20–25 % медленнее
 * бандла. Из списков /sync/runs и /admin/audit-logs они убираются до сравнения; ручные прогоны сценария остаются.
 */
const BACKGROUND_FILTERS = [
  [/^\/api\/v1\/sync\/runs$/, (it) => it?.trigger !== 'schedule'],
  [/^\/api\/v1\/admin\/audit-logs$/, (it) => !(it?.actor == null && /^sync\./.test(it?.action ?? '') && it?.after?.trigger !== 'manual')],
];
function dropBackground(r) {
  const f = BACKGROUND_FILTERS.find(([re]) => re.test(r.path ?? ''));
  if (!f || !Array.isArray(r.json?.items)) return r.json;
  return { ...r.json, items: r.json.items.filter(f[1]) };
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
 * порядке элементов массивов — 'order' (отдельно, не считается расхождением данных).
 */
export function compareRuns(recA, recB, { pdfTolerance = 0.05 } = {}) {
  const ma = new Map(recA.map((r) => [r.key, r]));
  const mb = new Map(recB.map((r) => [r.key, r]));
  const diffs = [];
  const order = [];
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
    const bd = firstDiff(na.body, nb.body, '$');
    if (bd) {
      if (!firstDiff(sortDeep(na.body), sortDeep(nb.body))) order.push({ key: k, kind: 'order', ...bd });
      else diffs.push({ key: k, kind: 'body', ...bd });
    }
  }
  return { compared, keysA: ma.size, keysB: mb.size, diffs, order };
}

/** Расхождения A↔B, которых нет среди расхождений A↔C (шум прогона бандла с самим собой). */
export function subtractNoise(diffsAB, diffsAC) {
  const noise = new Set(diffsAC.map((d) => `${d.key}|${d.kind}|${String(d.path).replace(/\[\d+\]/g, '[]')}`));
  const real = [];
  const noisy = [];
  for (const d of diffsAB) (noise.has(`${d.key}|${d.kind}|${String(d.path).replace(/\[\d+\]/g, '[]')}`) ? noisy : real).push(d);
  return { real, noisy };
}
