// HTTP-мост воркера (WP-B3; plan §3.3 «Протокол моста»): сообщение страницы `http {id, method, url, headers, body}`
// → IncomingMessage/ServerResponse шима node:http → express-обработчик Nest (app.getHttpAdapter().getInstance())
// → `http:res {id, status, headers, body}` (тело — передаваемый ArrayBuffer).
//
// - Каждый запрос — «единица работы» kind 'http' (alias/work-gate.mjs): `http:start {id}` уходит, когда запрос
//   получил слот (отсчёт таймаутов Dio, ADR-113 п. 2; ready.features: 'http:start').
// - `http:cancel {id}`: ещё не начатый запрос снимается из очереди; начатый обрывается как закрытое соединение
//   (req 'aborted', socket/req/res destroy — long-poll слушает res 'close') и отсоединяется через cancelGraceMs.
// - Изменяющий запрос (не GET/HEAD/OPTIONS) — единица durable: ответ уходит ПОСЛЕ конца единицы, где точка входа
//   сохраняет состояние имитатора 1С и сбрасывает PGlite на диск (critic [4]: данные не теряются, если вкладку
//   выгрузят сразу после ответа). GET отвечает сразу по окончании ответа express.
// - request() — внутренний запрос того же API (сид истории, kind 'seed'): тот же путь через express, без страницы.
//
// Review fixes (critic [4], сохранность):
// - Изменяющий запрос, данные которого НЕ дошли до диска (сброс тома вернул {error} — квота, отказ IndexedDB — или
//   том перехвачен другой вкладкой), не получает «успех»: 503 problem+json. Без поля code — так RetryInterceptor
//   приложения повторяет запрос сам (POST/PATCH — только с Idempotency-Key: pos-api вернёт сохранённый ответ, и он
//   уйдёт, когда запись удастся; PUT/DELETE — идемпотентны по смыслу). POST без ключа (вход по OTP и т. п.) повторять
//   нельзя — ответ уходит, но с заголовком x-demo-durability: failed; о сбое записи страница показывает плашку
//   (сообщение воркера `storage`).
// - GET-ответ ждёт идущий изменяющий сброс тома (оплата QR, записанная задачей pg-boss, номер «1С», статус заказа —
//   приложение увидит их только после записи) и сброс своей единицы, если она изменила состояние имитатора «1С».
// - Сервер демо мёртв (PGlite погиб после ready) — 503 без выполнения.
import http from 'node:http';
import { Buffer } from 'node:buffer';
import * as gate from './alias/work-gate.mjs';

const SAFE = new Set(['GET', 'HEAD', 'OPTIONS']);
const now = () => performance.now();
const path0 = (u) => String(u).split('?')[0];
const round1 = (x) => Math.round(x * 10) / 10;
const headerOf = (pairs, name) => {
  for (const [k, v] of pairs || []) if (String(k).toLowerCase() === name) return String(v);
  return null;
};

/** Итог конца единицы (work-gate unit.endHookError / unit.endResult) → почему данные не на диске, или null. */
export function durableFailure(unit) {
  if (!unit) return null;
  const r = unit.endResult;
  if (r && r.fenced) return 'fenced';
  if (r && r.error) return 'failed';
  if (r && r.skipped === 'closed') return 'failed';
  if (unit.endHookError) return 'failed';
  return null;
}

export class BridgeServer {
  /**
   * handler — express-приложение Nest; post(msg, transfer) — ответ странице; log(level, msg).
   * isFenced() → true, если том перехвачен другой вкладкой (запросы отклоняются 503 без выполнения);
   * isDead() → true, если PGlite погиб (503 без выполнения);
   * durability — { mustWait(): bool (GET-ответ ждать?), idle(): Promise (идущие изменяющие сбросы завершились) }.
   */
  constructor({ handler, post, log, isFenced = () => false, isDead = () => false, durability = null }) {
    this.handler = handler;
    this.post = post;
    this.log = log;
    this.isFenced = isFenced;
    this.isDead = isDead;
    this.durability = durability ?? { mustWait: () => false, idle: () => Promise.resolve() };
    this.inflight = new Map();
    this.reqStats = [];
    this.cancels = {};
    this.stats = { requests: 0, responses: 0, durable: 0, durableWaitMs: 0, maxDurableWaitMs: 0, errors: 0, fencedRejected: 0, deadRejected: 0, internal: 0, durableFailed: 0, durableFailed503: 0, durableFailedMarked: 0, getDeferred: 0, maxGetDeferMs: 0 };
  }

  /** Сообщение `http` страницы. */
  handleHttp(msg) {
    const t0 = now();
    this.stats.requests++;
    const method = String(msg.method || 'GET').toUpperCase();
    const url = String(msg.url || '/');
    const path = path0(url);
    if (this.isFenced()) {
      this.stats.fencedRejected++;
      this.respondError(msg.id, 503, 'SERVICE_UNAVAILABLE', 'Демо открыто в другой вкладке: эта вкладка больше не пишет данные.');
      return;
    }
    if (this.isDead()) {
      this.stats.deadRejected++;
      this.respondError(msg.id, 503, 'SERVICE_UNAVAILABLE', 'Сервер демо остановился. Обновите страницу.');
      return;
    }
    const durable = !SAFE.has(method);
    const idemKey = headerOf(msg.headers, 'idempotency-key');
    let ready = null;
    let deferred = false;
    let unitRef = null;
    gate
      .run(
        {
          kind: 'http',
          name: `${method} ${path}`,
          label: `${method} ${url}`,
          key: msg.id,
          durable,
          onStart: () => this.post({ type: 'http:start', id: msg.id, queuedMs: round1(now() - t0) }),
        },
        (unit) => {
          unitRef = unit;
          return this.dispatch({ method, url, headers: msg.headers, body: msg.body }, unit, t0).then((r) => {
            if (!r || unit.cancelled) return;
            if (durable) ready = r;
            else if (this.durability.mustWait()) {
              // GET изменил состояние «1С» или идёт изменяющий сброс тома: ответ — после записи (после run()).
              ready = r;
              deferred = true;
            } else this.send(msg.id, r);
          });
        },
      )
      .then(async () => {
        if (!ready) return;
        if (deferred) {
          await this.durability.idle();
          const w = now() - ready.endedAt;
          this.stats.getDeferred++;
          this.stats.maxGetDeferMs = Math.max(this.stats.maxGetDeferMs, Math.round(w));
          ready.durableWaitMs = round1(w);
          this.send(msg.id, ready);
          return;
        }
        const w = now() - ready.endedAt;
        this.stats.durable++;
        this.stats.durableWaitMs += w;
        this.stats.maxDurableWaitMs = Math.max(this.stats.maxDurableWaitMs, Math.round(w));
        ready.durableWaitMs = round1(w);
        const fail = durableFailure(unitRef);
        if (fail) {
          this.stats.durableFailed++;
          if (fail === 'fenced') {
            this.respondError(msg.id, 503, 'SERVICE_UNAVAILABLE', 'Демо открыто в другой вкладке: изменение не сохранено.');
            return;
          }
          const retryable = method === 'PUT' || method === 'DELETE' || ((method === 'POST' || method === 'PATCH') && !!idemKey);
          if (retryable) {
            this.stats.durableFailed503++;
            this.log('warn', `bridge: ${method} ${path}: данные не записаны на диск (${unitRef?.endResult?.error ?? unitRef?.endHookError ?? '?'}) — 503 для повтора`);
            this.respondError(msg.id, 503, null, 'Браузер не дал сохранить данные демо. Действие будет повторено.');
            return;
          }
          this.stats.durableFailedMarked++;
          ready.headers.push(['x-demo-durability', 'failed']);
        }
        this.send(msg.id, ready);
      })
      .catch((e) => {
        if (e?.code === 'ERR_DEMO_CANCELLED') return; // снят из очереди: страница уже ответила Dio отменой
        this.stats.errors++;
        this.log('error', `bridge: единица запроса ${method} ${path}: ${e?.stack ?? e}`);
        this.respondError(msg.id, 500, 'INTERNAL', 'Сбой сервера демо при выполнении запроса.');
      });
  }

  cancel(id) {
    const r = gate.cancel(id);
    this.cancels[r] = (this.cancels[r] ?? 0) + 1;
    return r;
  }

  send(id, r) {
    this.stats.responses++;
    this.post(
      { type: 'http:res', id, status: r.status, headers: r.headers, body: r.body, workerMs: round1(now() - r.t0), execMs: r.execMs, ...(r.durableWaitMs !== undefined ? { durableWaitMs: r.durableWaitMs } : {}) },
      r.body ? [r.body] : [],
    );
  }

  /** Ответ-ошибка problem+json. code === null — без поля code (RetryInterceptor приложения повторяет 503 без кода). */
  respondError(id, status, code, detail) {
    const slug = code ? code.toLowerCase() : status === 503 ? 'storage-unavailable' : 'error';
    const problem = { type: `https://demo.invalid/problems/${slug}`, title: detail, status, ...(code ? { code } : {}), detail, requestId: 'demo' };
    const body = new TextEncoder().encode(JSON.stringify(problem)).buffer;
    this.post({ type: 'http:res', id, status, headers: [['content-type', 'application/problem+json; charset=utf-8']], body }, [body]);
  }

  /**
   * Выполнить запрос в express; промис — { status, headers: [[k, v]], body: ArrayBuffer, t0, endedAt, execMs } по
   * окончании ответа или null после отмены (начатый запрос оборван).
   */
  dispatch({ method, url, headers: hdrs, body: rawBody }, unit, t0 = now()) {
    return new Promise((resolve) => {
      const tStart = now();
      const socket = new http.FakeSocket('127.0.0.1');
      const req = new http.IncomingMessage(socket);
      req.method = method;
      req.url = url;
      const headers = {};
      const raw = [];
      for (const [k, v] of hdrs || []) {
        const lk = String(k).toLowerCase();
        raw.push(k, v);
        if (lk === 'set-cookie') headers[lk] = [...(headers[lk] || []), v];
        else if (lk in headers) headers[lk] = `${headers[lk]}, ${v}`;
        else headers[lk] = v;
      }
      if (!headers.host) headers.host = 'demo.local';
      const body = rawBody ? Buffer.from(new Uint8Array(rawBody)) : null;
      if (body && body.length) headers['content-length'] = String(body.length);
      req.headers = headers;
      req.rawHeaders = raw;
      const res = new http.ServerResponse(req);
      const key = unit?.key ?? `internal-${Math.random().toString(36).slice(2)}`;
      this.inflight.set(key, { req, res, socket, unit });
      let done = false;
      const finish = (value) => {
        if (done) return;
        done = true;
        this.inflight.delete(key);
        resolve(value);
      };
      res._onEnd = (buf) => {
        const ms = now() - t0;
        this.reqStats.push({ m: method, u: path0(url), s: res.statusCode, ms: Math.round(ms), q: Math.round(tStart - t0), k: unit?.kind, c: unit?.cancelled || undefined });
        if (this.reqStats.length > 2000) this.reqStats.splice(0, 1000);
        if (unit?.cancelled) return finish(null);
        const out = [];
        for (const [k, v] of Object.entries(res.getHeaders())) {
          if (Array.isArray(v)) for (const x of v) out.push([k, String(x)]);
          else if (v !== undefined) out.push([k, String(v)]);
        }
        const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
        finish({ status: res.statusCode, headers: out, body: ab, t0, endedAt: now(), execMs: round1(now() - tStart) });
      };
      // Отмена начатого запроса: обрыв как у закрытого соединения; ответ не шлётся.
      unit?.onCancel(() => {
        req.aborted = true;
        req.emit('aborted');
        socket.destroy();
        req.destroy();
        res.destroy();
        // Промис не завершается здесь: код запроса может ещё держать транзакцию (step-up хэширует PIN внутри неё).
        // Если express не закончит ответ за cancelGraceMs, work-gate отсоединит единицу (WP-B2).
      });
      if (body && body.length) req.push(body);
      req.push(null);
      try {
        this.handler(req, res);
      } catch (e) {
        this.log('error', `bridge: handler threw ${e?.stack ?? e}`);
        const err = Buffer.from(JSON.stringify({ code: 'INTERNAL', status: 500 }));
        finish({ status: 500, headers: [['content-type', 'application/problem+json']], body: err.buffer.slice(err.byteOffset, err.byteOffset + err.byteLength), t0, endedAt: now(), execMs: 0 });
      }
    });
  }

  /**
   * Внутренний запрос API (сид истории): отдельная единица kind (по умолчанию 'seed'); изменяющий — durable.
   * Возвращает { status, headers: {k: v}, json, bytes }.
   */
  async request(method, url, { headers = {}, body, kind = 'seed', name } = {}) {
    this.stats.internal++;
    const m = method.toUpperCase();
    const h = Object.entries(headers).filter(([, v]) => v !== undefined && v !== null).map(([k, v]) => [k, String(v)]);
    let b = null;
    if (body !== undefined && body !== null) {
      b = new TextEncoder().encode(JSON.stringify(body)).buffer;
      h.push(['content-type', 'application/json']);
    }
    const r = await gate.run({ kind, name: name ?? `${m} ${path0(url)}`, label: `${kind} ${m} ${url}`, durable: !SAFE.has(m) }, (unit) => this.dispatch({ method: m, url, headers: h, body: b }, unit));
    const hdr = Object.fromEntries((r?.headers ?? []).map(([k, v]) => [k.toLowerCase(), v]));
    const bytes = r?.body ? new Uint8Array(r.body) : new Uint8Array(0);
    let json;
    if (/json/.test(hdr['content-type'] ?? '') && bytes.length) {
      try {
        json = JSON.parse(new TextDecoder().decode(bytes));
      } catch {
        json = undefined;
      }
    }
    return { status: r?.status ?? 0, headers: hdr, json, bytes };
  }
}
