// Имитатор HTTP-сервиса 1С «OptomstroyPOS» для --demo и тестов: 127.0.0.1, случайный порт
// (не 3000/8080/8091/8092), ответы — из образцов контракта 1.2.0. Путей вне контракта нет — 404 «платформы».
import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import { MockState } from './state.mjs';
import { toCp1251 } from './defects.mjs';
import { isoBishkek } from '../report/time.mjs';

const FORBIDDEN_PORTS = new Set([3000, 8080, 8091, 8092]);
const PLATFORM_404 = '<html><head><title>404 Not Found</title></head><body>Not Found</body></html>';

function readBody(req, limit = 4 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let n = 0;
    req.on('data', (c) => { n += c.length; if (n > limit) { reject(new Error('too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

export async function startMock({ samplesDir, defect = null, user = 'pos_hs', password, clientKey, publication = 'demo_test', host = '127.0.0.1', tls = null }) {
  const state = new MockState(samplesDir, defect);
  const journal = [];
  const D = defect;
  const timers = new Set();

  const handler = async (req, res) => {
    const url = new URL(req.url, 'http://mock');
    const prefix = `/${publication}/hs`;
    const reqId = String(req.headers['x-request-id'] || crypto.randomUUID());
    let body = Buffer.alloc(0);
    try { body = await readBody(req); } catch { res.destroy(); return; }
    const sub = url.pathname.startsWith(prefix) ? url.pathname.slice(prefix.length) : null;
    const entry = { method: req.method, path: sub ?? url.pathname, query: url.search, at: new Date(), status: null };
    journal.push(entry);

    const sendRaw = (status, buf, headers = {}) => {
      entry.status = status;
      res.writeHead(status, { ...headers, ...(buf ? { 'Content-Length': buf.length } : {}) });
      res.end(buf || undefined);
    };
    const encode = (obj) => {
      let text = JSON.stringify(obj);
      let buf = D === 'D05' ? toCp1251(text) : Buffer.from(text, 'utf8');
      if (D === 'D04') buf = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), buf]);
      return buf;
    };
    const send = (status, obj, extra = {}) => {
      const h = { 'Content-Type': (D === 'D06' && status === 200) ? 'text/html; charset=utf-8' : (D === 'D05' ? 'application/json; charset=windows-1251' : 'application/json; charset=utf-8') };
      h['X-Request-Id'] = D === 'D02' ? crypto.randomUUID() : reqId;
      if (status >= 200 && status < 300 && D !== 'D01') h['X-POS-API-Version'] = '1';
      Object.assign(h, extra);
      if (obj === undefined) { sendRaw(status, null, h); return; }
      sendRaw(status, encode(obj), h);
    };
    const err = (status, code, message, details) => {
      if (D === 'D22') { send(status, { error: message }); return; }
      const b = { code, message: D === 'D26' ? 'Error occurred' : message };
      if (details) b.details = details;
      b.requestId = D === 'D03' ? crypto.randomUUID() : reqId;
      send(status, b);
    };
    const reply = (r) => {
      if (r.error) { const [st, code, msg, det] = r.error; err(st, code, msg, det); return; }
      send(r.status || 200, r.body);
    };
    const platform404 = () => sendRaw(404, Buffer.from(PLATFORM_404), { 'Content-Type': 'text/html' });

    if (sub === null) { platform404(); return; }

    // Платформа: пользователь и пароль (Basic).
    const auth = String(req.headers.authorization || '');
    const goodAuth = 'Basic ' + Buffer.from(`${user}:${password}`, 'utf8').toString('base64');
    if (auth !== goodAuth && !(D === 'D19' && auth)) {
      sendRaw(401, null, { 'WWW-Authenticate': 'Basic realm="1C:Enterprise"' });
      return;
    }

    // Маршруты.
    const m = req.method;
    const p = sub;
    let route = null;
    let mm;
    if (m === 'GET' && p === '/pos/v1/health') route = 'health';
    else if (m === 'GET' && p === '/pos/v1/changes') route = 'changes';
    else if (m === 'POST' && p === '/pos/v1/changes/ack') route = 'ack';
    else if (m === 'POST' && p === '/pos/v1/changes/reregister') route = 'rereg';
    else if (m === 'GET' && (mm = /^\/pos\/v1\/images\/([^/]+)$/.exec(p))) route = 'image';
    else if (m === 'GET' && p === '/pos/v1/external-ids') route = 'xid';
    else if (m === 'GET' && p === '/pos/v1/customers') route = 'findCustomers';
    else if (m === 'POST' && p === '/pos/v1/customers') route = 'createCustomer';
    else if (m === 'GET' && (mm = /^\/pos\/v1\/customers\/([^/]+)\/receivables$/.exec(p))) route = 'receivables';
    else if (m === 'POST' && p === '/pos/v1/payments') route = 'createPayment';
    else if (m === 'POST' && p === '/pos/v1/orders') route = 'createOrder';
    else if (m === 'POST' && p === '/pos/v1/orders/status') route = 'orderBatch';
    else if (m === 'GET' && (mm = /^\/pos\/v1\/orders\/([^/]+)\/status$/.exec(p))) route = 'orderStatus';
    else if (m === 'POST' && (mm = /^\/pos\/v1\/orders\/([^/]+)\/cancel$/.exec(p))) route = 'orderCancel';
    else if (m === 'POST' && p === '/pos/v1/payments/qr') route = 'createQr';
    else if (m === 'GET' && (mm = /^\/pos\/v1\/payments\/([^/]+)\/status$/.exec(p))) route = 'qrStatus';
    else if (m === 'POST' && (mm = /^\/pos\/v1\/payments\/([^/]+)\/qr\/cancel$/.exec(p))) route = 'qrCancel';
    else if (m === 'POST' && p === '/pos/v1/returns') route = 'createReturn';
    else if (m === 'GET' && (mm = /^\/pos\/v1\/returns\/([^/]+)\/status$/.exec(p))) route = 'returnStatus';
    else if (m === 'POST' && p === '/pos/v1/check') route = 'check';
    else if (m === 'GET' && (mm = /^\/pos\/v1\/catalog\/([^/]+)$/.exec(p))) route = 'catalog';
    if (!route) { platform404(); return; }
    entry.route = route;

    // Код расширения: ключ клиента.
    const key = req.headers['x-pos-client-key'];
    if (key !== clientKey) {
      const tolerate = D === 'D17' || (D === 'D18' && route === 'changes');
      if (!tolerate) {
        if (D === 'D51' && route === 'health') {
          await new Promise((r) => { const t = setTimeout(r, 35000); timers.add(t); });
        }
        if (D === 'D21') { sendRaw(401, null, {}); return; }
        err(401, 'POS_E_UNAUTHORIZED', D === 'D20' ? `Неверный X-POS-Client-Key (1С:Предприятие ${state.health.platform}, ${state.health.configuration})` : 'Неверный X-POS-Client-Key');
        return;
      }
    }

    // Константа «ОбменПриостановлен».
    if (state.maintenance) {
      if (D === 'D45') { if (route !== 'changes') { err(500, 'POS_E_INTERNAL', 'Ошибка'); return; } }
      else { err(503, 'POS_E_MAINTENANCE', 'Обмен приостановлен (константа ОбменПриостановлен)'); return; }
    }

    let json;
    const needJson = m === 'POST' && !['rereg'].includes(route);
    if (needJson) {
      try { json = JSON.parse(body.toString('utf8') || 'null'); } catch {
        if (D === 'D25') { err(500, 'POS_E_INTERNAL', 'Ошибка разбора JSON'); return; }
        err(400, 'POS_E_BAD_REQUEST', 'Неверный JSON в теле запроса');
        return;
      }
      if (!json || typeof json !== 'object') { err(400, 'POS_E_BAD_REQUEST', 'Тело запроса должно быть объектом JSON'); return; }
    }

    const q = Object.fromEntries(url.searchParams);
    switch (route) {
      case 'health': {
        const b = { ...state.health, serverTime: D === 'D11' ? isoBishkek().slice(0, 19) : isoBishkek(), registrationBacklog: state.backlog, lastAckMessageNumber: state.lastAck };
        send(200, b);
        return;
      }
      case 'changes': {
        const since = Number(q.since);
        if (!/^\d+$/.test(q.since || '')) { err(400, 'POS_E_BAD_REQUEST', 'Параметр since обязателен'); return; }
        const limit = q.limit ? Number(q.limit) : 1000;
        if (!Number.isInteger(limit) || limit < 1) { err(400, 'POS_E_BAD_REQUEST', 'Неверный limit'); return; }
        reply(state.changes(since, limit, q.cursor || null));
        return;
      }
      case 'ack': {
        if (!Number.isInteger(json.messageNumber) || json.messageNumber < 1) { err(400, 'POS_E_BAD_REQUEST', 'Нужен messageNumber'); return; }
        reply(state.ack(json.messageNumber));
        return;
      }
      case 'rereg': state.reregister(); send(202, undefined); return;
      case 'image': {
        const ref = mm[1];
        if (ref !== state.image.ref) { err(404, 'POS_E_NOT_FOUND', 'Файл не найден'); return; }
        const etag = D === 'D42' ? `"${'0'.repeat(64)}"` : `"${state.image.sha256}"`;
        if (req.headers['if-none-match'] === etag && D !== 'D43') {
          entry.status = 304;
          res.writeHead(304, { ETag: etag, 'X-Request-Id': reqId });
          res.end();
          return;
        }
        const h = { 'Content-Type': 'image/jpeg', ETag: etag, 'X-Request-Id': reqId };
        if (D !== 'D01') h['X-POS-API-Version'] = '1';
        if (D === 'D44') {
          entry.status = 200;
          res.writeHead(200, { ...h, 'Content-Length': state.image.bytes.length + 10, Connection: 'close' });
          res.end(state.image.bytes);
          return;
        }
        sendRaw(200, state.image.bytes, h);
        return;
      }
      case 'xid': {
        const limit = q.limit ? Number(q.limit) : 1000;
        reply(state.externalIds({ since: q.since || null, type: q.type || null, limit, cursor: q.cursor || null }));
        return;
      }
      case 'findCustomers': {
        if (!q.phone) { err(400, 'POS_E_BAD_REQUEST', 'Параметр phone обязателен'); return; }
        send(200, state.findCustomers(q.phone));
        return;
      }
      case 'createCustomer': {
        if (!json.externalId || !json.name || !json.dedupe) { err(400, 'POS_E_BAD_REQUEST', 'Не заполнены обязательные поля'); return; }
        reply(await state.createCustomer(json));
        return;
      }
      case 'receivables': reply(state.receivables(mm[1])); return;
      case 'createPayment': {
        if (!json.externalId || !json.amount || !json.customerRef) { err(400, 'POS_E_BAD_REQUEST', 'Не заполнены обязательные поля'); return; }
        reply(await state.createPayment(json));
        return;
      }
      case 'createOrder': {
        if (!json.externalId || !Array.isArray(json.lines)) { err(400, 'POS_E_BAD_REQUEST', 'Не заполнены обязательные поля'); return; }
        reply(await state.createOrder(json));
        return;
      }
      case 'orderBatch': {
        if (!Array.isArray(json.externalIds)) { err(400, 'POS_E_BAD_REQUEST', 'Нужен externalIds'); return; }
        const items = [], notFound = [];
        for (const id of json.externalIds) { const s = state.orderStatus(id); if (s) items.push(s); else notFound.push(id); }
        send(200, { items, notFound });
        return;
      }
      case 'orderStatus': { const s = state.orderStatus(mm[1]); if (s) send(200, s); else err(404, 'POS_E_NOT_FOUND', 'Заказ не найден'); return; }
      case 'orderCancel': reply(state.cancelOrder(mm[1])); return;
      case 'createQr': reply(state.createQr(json)); return;
      case 'qrStatus': { const s = state.qrStatus(mm[1]); if (s) send(200, s); else err(404, 'POS_E_NOT_FOUND', 'Оплата не найдена'); return; }
      case 'qrCancel': reply(state.cancelQr(mm[1])); return;
      case 'createReturn': {
        if (json.shipmentRef !== 'f1e2d3c4-0000-4000-8000-000000000020') { err(422, 'POS_E_VALIDATION', 'Реализация не найдена'); return; }
        const b = state.body('returns-create.201.json');
        b.ref = crypto.randomUUID();
        send(201, b);
        return;
      }
      case 'returnStatus': err(404, 'POS_E_NOT_FOUND', 'Заявка не найдена'); return;
      case 'check': {
        if (!Array.isArray(json.lines) || json.lines.length < 1 || json.lines.length > 100) { err(400, 'POS_E_BAD_REQUEST', 'Строк должно быть от 1 до 100'); return; }
        const lines = json.lines.map((l) => {
          const short = Number(l.quantity) > 10;
          return {
            productRef: l.productRef, variantRef: l.variantRef ?? null, price: '2350.00', available: '10.000', onHand: '12.000', reserved: '2.000',
            isAvailable: !short, warehouses: [{ warehouseRef: json.warehouseRef, available: '10.000' }], issues: short ? [{ code: 'STOCK_INSUFFICIENT' }] : [],
          };
        });
        // Блок долга — только при customerRef и paymentMethod=credit (контракт CheckResponse.receivables), из образца.
        const receivables = json.customerRef && json.paymentMethod === 'credit' ? { ...state.body('check.stock-prices.200.json').receivables, snapshotAt: isoBishkek() } : null;
        send(200, { checkedAt: isoBishkek(), lines, receivables, totals: null, issues: D === 'D16' ? null : [] });
        return;
      }
      case 'catalog': {
        if (mm[1] !== 'a1b2c3d4-0000-4000-8000-000000000001') { err(404, 'POS_E_NOT_FOUND', 'Товар не найден'); return; }
        const b = state.body('catalog-card.200.json');
        b.snapshotAt = isoBishkek();
        send(200, b);
        return;
      }
      default:
        platform404();
    }
  };
  const server = tls ? https.createServer({ key: tls.key, cert: tls.cert }, handler) : http.createServer(handler);

  server.keepAliveTimeout = 5000;
  let port = 0;
  for (let i = 0; i < 20; i++) {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, host, () => { server.removeListener('error', reject); resolve(); });
    });
    port = server.address().port;
    if (!FORBIDDEN_PORTS.has(port)) break;
    await new Promise((r) => server.close(r));
  }
  return {
    port,
    baseUrl: `${tls ? 'https' : 'http'}://${tls?.hostname || host}:${port}/${publication}/hs`,
    publication,
    state,
    journal,
    simulate: {
      changeProduct: (ref) => state.changeProduct(ref),
      deleteObject: () => state.deleteObject(),
      setMaintenance: (v) => { state.maintenance = !!v; },
    },
    close: () => new Promise((r) => {
      for (const t of timers) clearTimeout(t);
      server.closeAllConnections?.();
      server.close(() => r());
    }),
  };
}
