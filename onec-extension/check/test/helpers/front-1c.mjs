// Испытательный «фасад» 1С для тестов (в сборку не входит): HTTP-сервер на 127.0.0.1 перед имитатором
// src/mock/server.mjs в режиме «образцы» (GOOD). Запросы пересылаются имитатору; дефекты test/helpers/defects-extra.mjs
// подменяют ответ (after), отвечают сами (before) или задерживают ответ (delay). Путей вне контракта 1.2.0 фасад не
// знает — их отвечает имитатор (404 «платформы»). Все данные вымышленные.
import http from 'node:http';
import crypto from 'node:crypto';
import { startMock } from '../../src/mock/server.mjs';
import { isoBishkek } from '../../src/report/time.mjs';

const FORBIDDEN_PORTS = new Set([3000, 8080, 8091, 8092]);

export const IIS_500 = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">\r\n'
  + '<html xmlns="http://www.w3.org/1999/xhtml"><head><meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1"/>'
  + '<title>500 - Internal server error.</title></head><body><div id="header"><h1>Server Error</h1></div><div id="content">'
  + '<fieldset><h2>500 - Internal server error.</h2><h3>There is a problem with the resource you are looking for, and it cannot be displayed.</h3>'
  + '</fieldset></div></body></html>';
export const IIS_404 = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">\r\n'
  + '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>404 - File or directory not found.</title></head><body>'
  + '<div id="header"><h1>Server Error</h1></div><div id="content"><fieldset><h2>404 - File or directory not found.</h2>'
  + '<h3>The resource you are looking for might have been removed, had its name changed, or is temporarily unavailable.</h3></fieldset></div></body></html>';
export const IIS_WELCOME = '<!DOCTYPE html><html><head><meta charset="utf-8"/><title>IIS Windows Server</title></head>'
  + '<body><div id="container"><a href="https://go.microsoft.com/fwlink/?linkid=66138"><img src="iisstart.png" alt="IIS" width="960" height="600"/></a></div></body></html>';

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

/** Ответ как значение: {status, headers (имена в нижнем регистре), body: Buffer}. */
export function jsonResponse(status, obj, reqId, extra = {}) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  const headers = { 'content-type': 'application/json; charset=utf-8', 'x-request-id': reqId, ...extra };
  if (status >= 200 && status < 300) headers['x-pos-api-version'] = '1';
  return { status, headers, body };
}

export function htmlResponse(status, html) {
  return { status, headers: { 'content-type': 'text/html', server: 'Microsoft-IIS/10.0' }, body: Buffer.from(html, 'latin1') };
}

export function posError(status, code, message, reqId, details) {
  const b = { code, message };
  if (details) b.details = details;
  b.requestId = reqId;
  return jsonResponse(status, b, reqId);
}

/** Разбор JSON тела ответа и замена (для дефектов «after»). */
export function mutateJson(r, fn) {
  let j;
  try { j = JSON.parse(r.body.toString('utf8')); } catch { return r; }
  const out = fn(j);
  return { ...r, body: Buffer.from(JSON.stringify(out === undefined ? j : out), 'utf8') };
}

function parseJson(buf) {
  try { return { ok: true, value: JSON.parse(buf.toString('utf8') || 'null') }; } catch { return { ok: false }; }
}

/**
 * @param {object} o
 * @param {string} o.samplesDir
 * @param {string} o.password
 * @param {string} o.clientKey
 * @param {object|null} [o.defect] — элемент каталога defects-extra.mjs
 * @param {string} [o.publication]
 */
export async function startFront({ samplesDir, password, clientKey, user = 'pos_hs', defect = null, publication = 'proverka_test' }) {
  const inner = await startMock({ samplesDir, password, clientKey, user, publication });
  const journal = [];
  const timers = new Set();
  const state = { seen: new Map(), payments: new Set() };
  const prefix = `/${publication}/hs`;
  const agent = new http.Agent({ keepAlive: false });

  const forward = (req, body) => new Promise((resolve, reject) => {
    const headers = { ...req.headers };
    delete headers.host;
    headers['content-length'] = String(body.length);
    const fr = http.request({ host: '127.0.0.1', port: inner.port, method: req.method, path: req.url, headers, agent }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const h = {};
        for (const [k, v] of Object.entries(res.headers)) h[k.toLowerCase()] = v;
        delete h['content-length'];
        delete h['transfer-encoding'];
        delete h.connection;
        delete h['keep-alive'];
        delete h.date;
        resolve({ status: res.statusCode, headers: h, body: Buffer.concat(chunks) });
      });
      res.on('error', reject);
    });
    fr.on('error', reject);
    fr.end(body);
  });

  const handler = async (req, res) => {
    let body;
    try { body = await readBody(req); } catch { res.destroy(); return; }
    const url = new URL(req.url, 'http://front');
    const sub = url.pathname.startsWith(prefix) ? url.pathname.slice(prefix.length) : null;
    const c = {
      req, url, sub, body, method: req.method, query: url.searchParams,
      reqId: String(req.headers['x-request-id'] || crypto.randomUUID()),
      auth: String(req.headers.authorization || ''), key: req.headers['x-pos-client-key'],
      json: () => parseJson(body), state, inner,
    };
    const entry = { method: req.method, path: sub ?? url.pathname, query: url.search, status: null, by: 'front', body: req.method === 'POST' ? body.toString('utf8').slice(0, 2000) : null };
    journal.push(entry);
    let r = null;
    try {
      if (defect?.delay && defect.delay.match(c)) {
        await new Promise((ok) => { const t = setTimeout(ok, defect.delay.ms); timers.add(t); });
        if (res.destroyed || req.socket.destroyed) return;
      }
      if (defect?.before) r = await defect.before(c);
      if (!r) {
        r = await forward(req, body);
        entry.by = 'mock';
        if (defect?.after) r = (await defect.after(c, r)) || r;
      }
    } catch (e) {
      r = posError(500, 'POS_E_INTERNAL', `Сбой фасада теста: ${e.message}`, c.reqId);
    }
    entry.status = r.status;
    if (res.destroyed) return;
    const headers = { ...r.headers };
    if (r.body && r.body.length && headers['content-length'] === undefined) headers['content-length'] = r.body.length;
    if (r.status === 304) delete headers['content-length'];
    try {
      res.writeHead(r.status, headers);
      res.end(r.status === 304 ? undefined : r.body);
    } catch { /* клиент ушёл */ }
  };

  const server = http.createServer(handler);
  server.keepAliveTimeout = 5000;
  let port = 0;
  for (let i = 0; i < 20; i++) {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', () => { server.removeListener('error', reject); resolve(); });
    });
    port = server.address().port;
    if (!FORBIDDEN_PORTS.has(port)) break;
    await new Promise((r) => server.close(r));
  }
  return {
    port,
    publication,
    baseUrl: `http://127.0.0.1:${port}/${publication}/hs`,
    inner,
    journal,
    close: async () => {
      for (const t of timers) clearTimeout(t);
      server.closeAllConnections?.();
      await new Promise((r) => server.close(() => r()));
      agent.destroy();
      await inner.close();
    },
  };
}

/** Сервер, который принимает TCP и молчит (для таймаутов): ни TLS-рукопожатия, ни ответа HTTP. */
export async function startSilent() {
  const net = await import('node:net');
  const sockets = new Set();
  const server = net.createServer((s) => { sockets.add(s); s.on('error', () => {}); s.on('close', () => sockets.delete(s)); });
  let port = 0;
  for (let i = 0; i < 20; i++) {
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    port = server.address().port;
    if (!FORBIDDEN_PORTS.has(port)) break;
    await new Promise((r) => server.close(r));
  }
  return {
    port,
    accepted: () => sockets.size,
    close: () => new Promise((r) => { for (const s of sockets) s.destroy(); server.close(() => r()); }),
  };
}

export { isoBishkek };
