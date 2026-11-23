// HTTP-клиент node:http(s): TLS (--ca, --insecure), таймауты соединения и ответа, предел размера, замер
// времени, журнал заголовков без секретов (Authorization: Basic ***, X-POS-Client-Key: ***).
import http from 'node:http';
import https from 'node:https';
import tls from 'node:tls';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { USER_AGENT } from './util.mjs';

export const MAX_JSON_BYTES = 64 * 1024 * 1024;
export const MAX_IMAGE_BYTES = 32 * 1024 * 1024;

/** Разбор адреса публикации; адрес вида …/hs/pos/v1/health приводится к …/hs (S1). */
export function parseBaseUrl(raw) {
  const notes = [];
  let s = String(raw || '').trim();
  if (!s) throw new Error('адрес публикации не задан');
  if (!/^[a-z]+:\/\//i.test(s)) {
    notes.push('в адресе нет схемы — добавлено https://');
    s = 'https://' + s;
  }
  let u;
  // Введённый адрес не повторяется: в нём по ошибке может оказаться пароль.
  try { u = new URL(s); } catch { throw new Error('адрес публикации не разобран — нужен вид https://сервер/публикация/hs'); }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') throw new Error(`схема ${u.protocol} не поддерживается — нужен https://`);
  if (u.username || u.password) throw new Error('пользователь и пароль в адресе не допускаются — уберите их из адреса');
  let p = u.pathname.replace(/\/+$/, '');
  const i = p.indexOf('/pos/v1');
  if (i >= 0) { notes.push(`адрес сокращён до публикации: «…${p.slice(i)}» убрано`); p = p.slice(0, i); }
  u.search = '';
  u.hash = '';
  const segs = p.split('/').filter(Boolean);
  const publication = segs.length >= 2 && segs[segs.length - 1].toLowerCase() === 'hs' ? decodeURIComponent(segs[segs.length - 2])
    : (segs.length ? decodeURIComponent(segs[0]) : null);
  return {
    href: `${u.protocol}//${u.host}${p}`,
    scheme: u.protocol.slice(0, -1),
    host: u.hostname,
    port: Number(u.port) || (u.protocol === 'https:' ? 443 : 80),
    basePath: p,
    endsWithHs: /\/hs$/i.test(p),
    publication,
    notes,
  };
}

export class HttpClient {
  /**
   * @param {object} o
   * @param {ReturnType<typeof parseBaseUrl>} o.base
   * @param {{scheme:'basic'|'bearer', user:string, password?:string, token?:string}} o.auth
   * @param {string} o.clientKey
   * @param {string|null} o.caFile
   * @param {boolean} o.insecure
   * @param {number} o.timeoutScale
   */
  constructor({ base, auth, clientKey, caFile = null, insecure = false, timeoutScale = 1, connectTimeoutMs = 5000 }) {
    this.base = base;
    this.auth = auth;
    this.clientKey = clientKey;
    this.caFile = caFile;
    this.insecure = insecure;
    this.timeoutScale = timeoutScale;
    this.connectTimeoutMs = connectTimeoutMs;
    this.tlsInfo = null;
    this.ca = null;
    if (base.scheme === 'https') {
      if (caFile) {
        const extra = fs.readFileSync(caFile, 'utf8');
        let def = [];
        try { def = tls.getCACertificates('default'); } catch { def = [...tls.rootCertificates]; }
        this.ca = [...def, extra];
      }
      this.agent = new https.Agent({
        keepAlive: true, maxSockets: 16, minVersion: 'TLSv1.2',
        rejectUnauthorized: !insecure, ...(this.ca ? { ca: this.ca } : {}),
      });
    } else {
      this.agent = new http.Agent({ keepAlive: true, maxSockets: 16 });
    }
  }

  close() {
    try { this.agent.destroy(); } catch { /* уже закрыт */ }
  }

  /** Строгая TLS-попытка (S2): что именно не так с сертификатом, даже при --insecure. */
  probeTls() {
    const { host, port } = this.base;
    return new Promise((resolve) => {
      const timer = setTimeout(() => { sock.destroy(); resolve({ ok: false, error: Object.assign(new Error('connect timeout'), { code: 'CONNECT_TIMEOUT' }) }); },
        Math.max(50, this.connectTimeoutMs * this.timeoutScale));
      const sock = tls.connect({
        host, port, servername: /^[\d.]+$|:/.test(host) ? undefined : host,
        minVersion: 'TLSv1.2', rejectUnauthorized: true, ...(this.ca ? { ca: this.ca } : {}),
      });
      sock.once('secureConnect', () => {
        clearTimeout(timer);
        const info = describeTls(sock);
        sock.end();
        resolve({ ok: true, info });
      });
      sock.once('error', (error) => {
        clearTimeout(timer);
        let info = null;
        try { info = describeTls(sock); } catch { /* нет сертификата */ }
        resolve({ ok: false, error, info });
      });
    });
  }

  /**
   * Запрос. auth: 'normal' | 'none' | 'wrong'; key: 'normal' | 'none' | 'wrong'.
   * Возвращает запись обмена без исключений: при сетевой ошибке — {error}.
   */
  request({
    method = 'GET', path, query = null, body = undefined, contentType = 'application/json; charset=utf-8',
    headers = {}, auth = 'normal', key = 'normal', timeoutMs = 30000, maxBytes = MAX_JSON_BYTES, requestId = crypto.randomUUID(),
  }) {
    let qs = '';
    if (query && typeof query === 'object') {
      const parts = [];
      for (const [k, v] of Object.entries(query)) if (v !== undefined && v !== null) parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`);
      if (parts.length) qs = '?' + parts.join('&');
    } else if (typeof query === 'string' && query) qs = query.startsWith('?') ? query : '?' + query;
    const fullPath = this.base.basePath + path + qs;
    const h = { 'User-Agent': USER_AGENT, Accept: 'application/json', 'X-Request-Id': requestId, ...headers };
    const shown = { 'X-Request-Id': requestId };
    if (auth !== 'none') {
      if (this.auth.scheme === 'bearer') {
        const tok = auth === 'wrong' ? 'eyJhbGciOiJIUzI1NiJ9.e30.' + crypto.randomBytes(16).toString('hex') : this.auth.token;
        h.Authorization = `Bearer ${tok}`;
        shown.Authorization = auth === 'wrong' ? 'Bearer *** (заведомо неверный)' : 'Bearer ***';
      } else {
        const pw = auth === 'wrong' ? 'neverno-' + crypto.randomBytes(9).toString('hex') : this.auth.password;
        h.Authorization = 'Basic ' + Buffer.from(`${this.auth.user}:${pw}`, 'utf8').toString('base64');
        shown.Authorization = auth === 'wrong' ? 'Basic *** (заведомо неверный пароль)' : 'Basic ***';
      }
    } else shown.Authorization = '(нет)';
    if (key !== 'none') {
      h['X-POS-Client-Key'] = key === 'wrong' ? 'neverno-' + crypto.randomBytes(12).toString('hex') : this.clientKey;
      shown['X-POS-Client-Key'] = key === 'wrong' ? '*** (заведомо неверный)' : '***';
    } else shown['X-POS-Client-Key'] = '(нет)';
    let payload = null;
    if (body !== undefined) {
      payload = Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body), 'utf8');
      h['Content-Type'] = contentType;
      h['Content-Length'] = payload.length;
      shown['Content-Type'] = contentType;
    }
    for (const [k, v] of Object.entries(headers)) shown[k] = v;
    const mod = this.base.scheme === 'https' ? https : http;
    const respTimeout = Math.max(20, Math.round(timeoutMs * this.timeoutScale));
    const connTimeout = Math.max(20, Math.round(this.connectTimeoutMs * this.timeoutScale));
    const started = process.hrtime.bigint();
    const rec = {
      method, path: path + qs, fullPath, requestId, reqHeaders: shown,
      reqBody: payload ? payload.toString('utf8') : null,
      status: null, headers: {}, body: Buffer.alloc(0), ms: null, error: null, tls: null, timeoutMs, startedAt: new Date(),
    };
    return new Promise((resolve) => {
      let done = false;
      const finish = (err) => {
        if (done) return;
        done = true;
        clearTimeout(rt);
        clearTimeout(ct);
        rec.ms = Number(process.hrtime.bigint() - started) / 1e6;
        if (err) rec.error = err;
        resolve(rec);
      };
      const req = mod.request({
        host: this.base.host, port: this.base.port, method, path: fullPath, headers: h, agent: this.agent,
        servername: /^[\d.]+$|:/.test(this.base.host) ? undefined : this.base.host,
      });
      const ct = setTimeout(() => {
        const e = Object.assign(new Error('connect timeout'), { code: 'CONNECT_TIMEOUT' });
        req.destroy(e);
      }, connTimeout);
      const rt = setTimeout(() => {
        const e = Object.assign(new Error('response timeout'), { code: 'RESPONSE_TIMEOUT' });
        req.destroy(e);
      }, respTimeout);
      req.on('socket', (s) => {
        const ok = () => clearTimeout(ct);
        const isTls = this.base.scheme === 'https';
        if (s.connecting || (isTls && !s._secureEstablished)) s.once(isTls ? 'secureConnect' : 'connect', ok);
        else ok();
      });
      req.on('response', (res) => {
        clearTimeout(ct);
        rec.status = res.statusCode;
        rec.headers = lowerHeaders(res.headers);
        if (this.base.scheme === 'https' && res.socket) {
          try { rec.tls = describeTls(res.socket); this.tlsInfo = rec.tls; } catch { /* нет сведений */ }
        }
        const chunks = [];
        let size = 0;
        res.on('data', (c) => {
          size += c.length;
          if (size > maxBytes) {
            const e = Object.assign(new Error('body too large'), { code: 'BODY_TOO_LARGE' });
            res.destroy(e);
            req.destroy(e);
            return;
          }
          chunks.push(c);
        });
        const cut = (e) => {
          rec.body = Buffer.concat(chunks);
          const declared = Number(rec.headers['content-length']);
          if (Number.isFinite(declared) && declared !== rec.body.length && (!e || e.code !== 'BODY_TOO_LARGE')) {
            return finish(Object.assign(new Error('content-length mismatch'), { code: 'CONTENT_LENGTH_MISMATCH', declared, received: rec.body.length }));
          }
          return finish(e);
        };
        res.on('end', () => cut(null));
        res.on('error', (e) => cut(e));
        res.on('aborted', () => cut(Object.assign(new Error('aborted'), { code: 'ECONNRESET' })));
      });
      req.on('error', (e) => finish(e));
      if (payload) req.write(payload);
      req.end();
    });
  }
}

function lowerHeaders(hs) {
  const o = {};
  for (const [k, v] of Object.entries(hs || {})) o[k.toLowerCase()] = Array.isArray(v) ? v.join(', ') : v;
  return o;
}

export function describeTls(sock) {
  const cert = sock.getPeerCertificate ? sock.getPeerCertificate() : null;
  const name = (o) => (o ? Object.entries(o).map(([k, v]) => `${k}=${Array.isArray(v) ? v.join('+') : v}`).join(', ') : null);
  return {
    protocol: sock.getProtocol ? sock.getProtocol() : null,
    authorized: !!sock.authorized,
    authorizationError: sock.authorizationError ? String(sock.authorizationError) : null,
    subject: cert && cert.subject ? name(cert.subject) : null,
    issuer: cert && cert.issuer ? name(cert.issuer) : null,
    validFrom: cert?.valid_from || null,
    validTo: cert?.valid_to || null,
    altNames: cert?.subjectaltname || null,
  };
}
