// Подмена dist/integrations/onec/onec-http-transport.js (WP-B2, plan §3.3): вместо node:http(s) — вызов в том же
// воркере управляемого имитатора 1С (scripts/pos_fake_onec.ts, PosFakeOnec.handle); поверх работает боевой
// OnecExtensionGateway (alias/onec-gateway.mjs: одна попытка GET в демо). Сети нет: адрес ONEC_BASE_URL
// (https://fake-1c.invalid) только разбирается на путь.
//
// Отмена (AbortSignal шлюза) и таймаут запроса соблюдаются: обрыв → OnecTransportError('aborted'), как у
// настоящего транспорта; ответ имитатора больше maxResponseBytes → 'too_large'.
import { Buffer } from 'node:buffer';

export class OnecTransportError extends Error {
  name = 'OnecTransportError';
  constructor(kind, causeCode) {
    super(`1С transport: ${kind}${causeCode ? ` (${causeCode})` : ''}`);
    this.kind = kind;
    this.causeCode = causeCode;
  }
}
export const DEFAULT_CONNECT_TIMEOUT_MS = 5_000;
export const DEFAULT_MAX_RESPONSE_BYTES = 64 * 1024 * 1024;
export const transportStats = { calls: 0, errors: 0, aborted: 0, byPath: {}, byStatus: {} };

/** Задержка «сети» имитатора (мс): ответ всегда асинхронный, как у настоящего транспорта. */
export const transportConfig = { latencyMs: 5, hsPrefix: '/ut11/hs' };

let fakeRef = null;
/** Подключить имитатор 1С (WP-B3); по умолчанию берётся globalThis.__posFakeOnec. */
export function setFakeOnec(fake) {
  fakeRef = fake;
}
const fakeOnec = () => fakeRef ?? globalThis.__posFakeOnec ?? null;

function delay(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(new OnecTransportError('aborted'));
    const t = setTimeout(() => {
      signal?.removeEventListener?.('abort', onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(t);
      reject(new OnecTransportError('aborted'));
    };
    signal?.addEventListener?.('abort', onAbort, { once: true });
  });
}

export class NodeOnecTransport {
  constructor(options = {}) {
    this.maxBytes = options.maxResponseBytes ?? DEFAULT_MAX_RESPONSE_BYTES;
  }
  async request(req) {
    const fake = fakeOnec();
    if (!fake) throw new OnecTransportError('network', 'NO_FAKE');
    try {
      await delay(transportConfig.latencyMs, req.signal);
    } catch (e) {
      transportStats.aborted++;
      throw e;
    }
    const url = new URL(req.url);
    const prefix = transportConfig.hsPrefix;
    const path = url.pathname.startsWith(prefix) ? url.pathname.slice(prefix.length) : url.pathname;
    let body = {};
    if (req.body && req.body.length) {
      try {
        body = JSON.parse(Buffer.from(req.body).toString('utf8'));
      } catch {
        body = {};
      }
    }
    transportStats.calls++;
    const key = `${req.method} ${path.replace(/[0-9a-f]{8}-[0-9a-f-]{27}/g, ':id')}`;
    transportStats.byPath[key] = (transportStats.byPath[key] ?? 0) + 1;
    let r;
    try {
      r = fake.handle(req.method, decodeURIComponent(path), body, url.searchParams);
    } catch (e) {
      transportStats.errors++;
      r = { status: 500, body: { code: 'POS_E_INTERNAL', message: String(e?.message ?? e) } };
    }
    transportStats.byStatus[r.status] = (transportStats.byStatus[r.status] ?? 0) + 1;
    if (req.signal?.aborted) {
      transportStats.aborted++;
      throw new OnecTransportError('aborted');
    }
    const payload = Buffer.from(r.body === undefined ? '' : JSON.stringify(r.body), 'utf8');
    if (payload.length > this.maxBytes) throw new OnecTransportError('too_large');
    const headers = { 'x-pos-api-version': '1' };
    if (r.body !== undefined) headers['content-type'] = 'application/json; charset=utf-8';
    const rid = req.headers?.['X-Request-Id'] ?? req.headers?.['x-request-id'];
    if (rid) headers['x-request-id'] = String(rid);
    return { status: r.status, headers, body: payload };
  }
}
