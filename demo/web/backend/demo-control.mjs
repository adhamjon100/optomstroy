// Маршруты управления демо `/__demo/*` (WP-B3; plan §3.3 таблица, §3.6; handoff WP-S1 «Worker protocol»).
// Только для демо-панели страницы: сообщение `control {id, action, args}` → `control:res {id, ok, data | error}`,
// мимо Dio и express. Каждая команда — «единица работы» kind 'panel' (запросы приложения идут раньше); изменяющая —
// durable: в конце единицы состояние имитатора 1С сохраняется в demo_meta, том сбрасывается на диск.
//
// Действия:
//   GET  state                                — роли и телефоны, эпоха, ожидающие QR, последние заказы, «1С», сид, счётчики
//   GET  logs {n}                             — кольцевой журнал воркера
//   POST qr/<paymentId>/pay {amount?}         — оплатить QR в имитаторе «1С»; следующий опрос → received
//   POST qr/<paymentId>/expire                — истечь QR
//   POST qr/config {paidAfterPolls}           — опросов до автооплаты (0 — только кнопкой)
//   POST onec/down {down}                     — «1С недоступна»
//   POST onec/orders/mode {mode, failNext}    — режим приёма заказов: accept | reject | unavailable
//   POST onec/check {mode, count?}            — ответ POST /pos/v1/check: ok | remarks | reject | unavailable
//   POST orders/<orderId>/onec-status {status, approved?} — статус документа в «1С» + задача синхронизации статусов
//   POST orders/<orderId>/ship                — «отгрузка» (тот же SQL, что local-stack shipOrderForTest) + реализация в «1С»
//   POST returns/<externalId>/status {status} — статус заявки на возврат в «1С» (completed — проводит возврат)
//   POST customers/<ref> {creditLimit?, creditAllowed?, creditDays?, discountPercent?} — условия клиента в «1С»
//   POST sync/catch-up                        — догоняние расписаний (как на холодном старте)
//   POST flush                                — сбросить том на диск
//   POST reset                                — остановить фоновые задачи перед очисткой хранилища страницей
//   fake {method, path, body}                 — (тесты) управляющий вызов имитатора /__fake/*
//   config {gate, shim}                       — (тесты) параметры единицы работы и pg-shim
import * as gate from './alias/work-gate.mjs';
import * as pgShim from './alias/pg-shim.mjs';
import { schedulePaymentPoll } from '@pos-api-dist/jobs/payments/payments-jobs.js';
import { QUEUES } from '@pos-api-dist/common/jobs/contracts/queues.js';
import { ENTITY_QUEUES } from '@pos-api-dist/sync/scheduler/sync-queues.js';
import { CHECK_MODES } from './demo-overlay.mjs';
import { LOGIN_HINTS, QR_DEFAULTS, OTP_TEST_CODE } from './demo-config.mjs';
import { catchUp } from './demo-init.mjs';

export class ControlError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}
const bad = (m) => new ControlError('BAD_ARGS', m);
const notFound = (m) => new ControlError('NOT_FOUND', m);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ONEC_STATUSES = ['НеСогласован', 'КВыполнению', 'Закрыт'];
// Review fixes: «Отгрузить» — только согласованный «1С» заказ (approved — оплачен или в долг, awaiting_shipment).
// Неоплаченный (awaiting_payment) или не согласованный (pending_approval) заказ демо не отгружает: иначе «отгружен»
// появлялся у заказа, который ещё ждёт оплаты, и это выглядело бы как ошибка продукта (local-stack shipOrderForTest
// так делает — там это тестовая утилита).
const SHIPPABLE = new Set(['approved', 'awaiting_shipment']);
const SHIP_HINT = {
  awaiting_payment: 'сначала примите оплату',
  pending_approval: 'сначала согласуйте заказ в «1С» («Согласовать»)',
  submitting: 'заказ ещё передаётся в «1С»',
  submit_failed: 'заказ не принят «1С»',
  draft: 'заказ ещё не оформлен',
};
const BISHKEK_OFFSET_MS = 6 * 3600 * 1000;
const bishkekToday = () => new Date(Date.now() + BISHKEK_OFFSET_MS).toISOString().slice(0, 10);
const qty3 = (x) => Number(x).toFixed(3);
const money = (x) => Number(x).toFixed(2); // money-double: allow — только формат строки суммы из numeric БД

/**
 * ctx: { be (результат initBackend), bridge, seed, info: { epochKey, buildId, storage, generation }, counters(), logs(n),
 *        log(level, msg), onReset() }
 */
export function createControl(ctx) {
  const pool = new pgShim.default.Pool({ application_name: 'demo-panel' });
  const q = (text, values) => pool.query(text, values);
  const boss = () => ctx.be.runtime.boss;
  const fake = () => ctx.be.fake;
  const overlay = () => ctx.be.overlay;
  const send = async (queue, data, key) => {
    try {
      return (await boss().send(queue, data, key ? { singletonKey: key } : {})) ? 'sent' : 'dup';
    } catch (e) {
      ctx.log('warn', `панель: задача ${queue}: ${e?.message ?? e}`);
      return 'error';
    }
  };
  const syncJob = (entity) => send(ENTITY_QUEUES[entity].queue, { entity, mode: 'incremental', trigger: 'schedule' }, entity);
  const panel = (name, fn, durable = true) => gate.run({ kind: 'panel', name, label: `panel ${name}`, durable }, fn);
  const fakeCall = (method, path, body = {}) => {
    const r = fake().handle(method, path, body, new URLSearchParams());
    if (r.status >= 400) throw new ControlError(r.status === 404 ? 'NOT_FOUND' : 'FAKE_ERROR', `«1С»: ${JSON.stringify(r.body).slice(0, 200)}`);
    return r.body;
  };

  // ------------------------------------------------------------------ состояние для панели
  async function state() {
    return panel(
      'state',
      async () => {
        const f = fake();
        const ov = overlay();
        const qr = await q(
          `SELECT p.id::text AS id, p.order_id::text AS order_id, o.public_number, p.amount::text AS amount, p.status::text AS status
             FROM payments p LEFT JOIN orders o ON o.id = p.order_id
            WHERE p.qr_provider = 'onec' AND p.status IN ('qr_pending', 'qr_shown') ORDER BY p.created_at DESC LIMIT 20`,
        );
        const orders = await q(
          `SELECT o.id::text AS id, o.public_number, o.onec_number, o.onec_status_raw, o.status::text AS status, o.total::text AS total,
                  o.shipped_at, o.created_at, o.onec_sync_state::text AS sync_state,
                  EXISTS (SELECT 1 FROM shipments s WHERE s.order_id = o.id) AS has_shipment
             FROM orders o ORDER BY o.created_at DESC LIMIT 10`,
        );
        const rets = await q(
          `SELECT r.id::text AS id, r.order_id::text AS order_id, r.public_number, r.status::text AS status FROM return_requests r ORDER BY r.created_at DESC LIMIT 20`,
        );
        const returns = rets.rows.map((r) => {
          const fr = ctx.be.cs.cashier.returnRequest(r.id);
          return { externalId: r.id, orderId: r.order_id, number: r.public_number, status: fr?.status ?? r.status, posStatus: r.status, inOnec: !!fr };
        });
        const ordersOut = orders.rows.map((o) => {
          const fo = f.orders.get(o.id) ?? ov.manualDocs.get(o.id) ?? null;
          const onecStatus = fo?.status ?? o.onec_status_raw ?? null;
          const actions = [];
          if (fo && onecStatus === 'НеСогласован') actions.push('approve');
          if (SHIPPABLE.has(o.status) && !o.has_shipment) actions.push('ship');
          if (fo && onecStatus !== 'Закрыт') actions.push('close');
          const myRets = returns.filter((r) => r.orderId === o.id);
          // «Выполнить возврат»: заявка отправлена (submitted/accepted) — в «1С» её проводит оператор (демо).
          const openRets = myRets.filter((r) => r.posStatus !== 'draft' && r.status !== 'completed' && r.status !== 'rejected');
          if (openRets.length) actions.push('return');
          return {
            id: o.id,
            number: o.public_number,
            onecNumber: o.onec_number ?? fo?.number ?? null,
            onecStatus,
            approved: fo ? !!fo.approved : onecStatus === 'КВыполнению',
            shipped: !!o.shipped_at || o.status === 'shipped' || o.status === 'partially_returned',
            status: o.status,
            syncState: o.sync_state,
            total: o.total,
            manualOnecNumber: ov.manualDocs.get(o.id)?.number ?? null,
            actions,
            returns: myRets.filter((r) => r.posStatus !== 'draft').map((r) => ({ externalId: r.externalId, status: r.status })),
          };
        });
        return {
          epoch: ctx.info.epochKey,
          buildId: ctx.info.buildId,
          storage: ctx.be.storage.kind,
          generation: ctx.info.generation,
          warm: ctx.be.warm,
          code: OTP_TEST_CODE,
          roles: LOGIN_HINTS,
          qr: {
            paidAfterPolls: f.paidAfterPolls,
            pollSeconds: QR_DEFAULTS.pollSeconds,
            pending: qr.rows.map((p) => ({ paymentId: p.id, externalId: p.id, orderId: p.order_id, orderNumber: p.public_number, amount: p.amount, status: p.status, polls: f.qr.get(p.id)?.polls ?? 0, onecStatus: f.qr.get(p.id)?.status ?? null })),
          },
          onec: { down: f.down, orderMode: f.orderMode, failNext: f.failNext, checkMode: ov.check.mode, checkRemaining: ov.check.remaining, orderSeq: f.orderSeq },
          orders: ordersOut,
          returns,
          seed: ctx.seed?.state() ?? null,
          counters: ctx.counters(),
        };
      },
      false,
    );
  }

  // ------------------------------------------------------------------ «отгрузка» заказа
  async function ship(orderId) {
    return panel(`ship ${orderId}`, async () => {
      const o = (await q(`SELECT o.id, o.status::text AS status, o.total::text AS total, c.onec_ref::text AS customer_ref FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.id = $1`, [orderId])).rows[0];
      if (!o) throw notFound('Заказ не найден');
      if (!SHIPPABLE.has(o.status)) throw new ControlError('STATE', `Отгрузить нельзя: заказ в статусе ${o.status}${SHIP_HINT[o.status] ? ` — ${SHIP_HINT[o.status]}` : ''}`);
      const c = await pool.connect();
      let shipment;
      try {
        await c.query('BEGIN');
        const upd = await c.query(`UPDATE orders SET status = 'shipped', shipped_at = now() WHERE id = $1 RETURNING id`, [orderId]);
        if (upd.rowCount !== 1) throw notFound('Заказ не найден');
        shipment = (
          await c.query(
            `INSERT INTO shipments (onec_ref, onec_code, onec_data_version, synced_at, source_hash, onec_doc_type, onec_date,
                                    posted, order_id, customer_id, warehouse_id, total, discount_total, returned_total)
             SELECT gen_random_uuid(), 'РТ-ДЕМО-' || left(o.id::text, 8), 'AAAAAQ==', now(), 'web-demo',
                    'Document_РеализацияТоваровУслуг', now(), true, o.id, o.customer_id,
                    (SELECT id FROM warehouses WHERE is_active AND NOT deletion_mark ORDER BY is_default_for_pos DESC, id LIMIT 1),
                    o.total, 0, 0
               FROM orders o WHERE o.id = $1
             RETURNING id::text AS id, onec_ref::text AS onec_ref, onec_code`,
            [orderId],
          )
        ).rows[0];
        // Все строки заказа (local-stack отгружает только первую): номера строк реализации 1…N.
        await c.query(
          `INSERT INTO shipment_items (shipment_id, onec_line_no, variant_id, product_name_snapshot, quantity, base_quantity,
                                       unit_price, line_total, discount_amount, returned_quantity, synced_at, source_hash)
           SELECT $1, row_number() OVER (ORDER BY oi.line_no), oi.variant_id, oi.product_name_snapshot, oi.quantity, oi.quantity,
                  oi.unit_price, oi.line_total, 0, 0, now(), 'web-demo'
             FROM order_items oi WHERE oi.order_id = $2`,
          [shipment.id, orderId],
        );
        await c.query(`UPDATE order_items SET shipped_quantity = quantity WHERE order_id = $1`, [orderId]);
        await c.query('COMMIT');
      } catch (e) {
        await c.query('ROLLBACK').catch(() => undefined);
        throw e;
      } finally {
        c.release();
      }
      // Реализация в «1С» — для заявки на возврат (POST /pos/v1/returns ищет её по shipmentRef и номеру строки).
      const lines = (
        await q(
          `SELECT si.onec_line_no AS line, p.onec_ref::text AS product_ref, v.onec_ref::text AS variant_ref, v.is_default,
                  si.product_name_snapshot AS name, si.quantity::text AS quantity, si.unit_price::text AS price, si.line_total::text AS amount
             FROM shipment_items si JOIN product_variants v ON v.id = si.variant_id JOIN products p ON p.id = v.product_id
            WHERE si.shipment_id = $1 ORDER BY si.onec_line_no`,
          [shipment.id],
        )
      ).rows;
      ctx.be.cs.addShipment({
        ref: shipment.onec_ref,
        number: shipment.onec_code,
        date: bishkekToday(),
        customerRef: o.customer_ref ?? '00000000-0000-4000-8000-000000000000',
        orderExternalId: orderId,
        total: money(o.total),
        discountTotal: '0.00',
        paymentDueDate: null,
        lines: lines.map((l) => ({
          lineNumber: Number(l.line),
          productRef: l.product_ref,
          variantRef: l.is_default ? null : l.variant_ref,
          productName: l.name,
          quantity: qty3(l.quantity),
          price: money(l.price),
          amount: money(l.amount),
          discountAmount: '0.00',
          returnedQuantity: '0.000',
        })),
        returnedTotal: '0.00',
        dataVersion: 1,
      });
      overlay().markDirty();
      return { orderId, shipmentId: shipment.id, shipmentRef: shipment.onec_ref, number: shipment.onec_code, lines: lines.length, status: 'shipped' };
    });
  }

  // ------------------------------------------------------------------ диспетчер действий
  return async function control(action, args) {
    const a = args && typeof args === 'object' ? args : {};
    const act = String(action ?? '').trim();
    const [method, path = ''] = act.includes(' ') ? act.split(/\s+/, 2) : [act, ''];
    let m;
    if (method === 'GET' && path === 'state') return state();
    if (method === 'GET' && path === 'logs') return ctx.logs(Number(a.n) || 100);
    if (method === 'POST' && (m = /^qr\/([^/]+)\/pay$/.exec(path))) {
      const id = m[1];
      if (!UUID_RE.test(id)) throw bad('paymentId');
      if (a.amount !== undefined && a.amount !== null && a.amount !== '' && !/^\d+(\.\d{1,2})?$/.test(String(a.amount))) throw bad('amount: число, например 1250.00');
      return panel(`qr pay ${id}`, async () => {
        if (!fake().qr.has(id)) throw notFound('QR не найден в «1С» (ещё не выдан или уже завершён)');
        const amount = a.amount ? Number(a.amount).toFixed(2) : undefined; // money-double: allow — формат суммы панели
        const body = fakeCall('POST', `/__fake/qr/${id}/pay`, amount ? { amount } : {});
        await schedulePaymentPoll(boss(), id, 0).catch(() => undefined);
        return { paymentId: id, onec: body };
      });
    }
    if (method === 'POST' && (m = /^qr\/([^/]+)\/expire$/.exec(path))) {
      const id = m[1];
      return panel(`qr expire ${id}`, async () => {
        const qq = overlay().expireQr(id);
        if (!qq) throw notFound('QR не найден в «1С»');
        await schedulePaymentPoll(boss(), id, 0).catch(() => undefined);
        return { paymentId: id, status: qq.status };
      });
    }
    if (method === 'POST' && path === 'qr/config') {
      const n = Number(a.paidAfterPolls);
      if (!Number.isInteger(n) || n < 0 || n > 600) throw bad('paidAfterPolls: целое 0…600');
      return panel('qr config', async () => fakeCall('POST', '/__fake/qr/config', { paidAfterPolls: n }));
    }
    if (method === 'POST' && path === 'onec/down') {
      return panel('onec down', async () => {
        const r = fakeCall('POST', '/__fake/down', { down: a.down === true });
        if (a.down !== true) await send(QUEUES.onecChanges, { node: 'POS' }, 'POS');
        return r;
      });
    }
    if (method === 'POST' && path === 'onec/orders/mode') {
      const mode = String(a.mode ?? 'accept');
      if (!['accept', 'reject', 'unavailable'].includes(mode)) throw bad('mode: accept | reject | unavailable');
      return panel('onec orders mode', async () => fakeCall('POST', '/__fake/orders/mode', { mode, failNext: Number(a.failNext ?? (mode === 'accept' ? 0 : 1)) }));
    }
    if (method === 'POST' && path === 'onec/check') {
      const mode = String(a.mode ?? 'ok');
      if (!CHECK_MODES.includes(mode)) throw bad(`mode: ${CHECK_MODES.join(' | ')}`);
      return panel('onec check', async () => overlay().setCheckMode(mode, a.count ?? 0));
    }
    if (method === 'POST' && (m = /^orders\/([^/]+)\/onec-status$/.exec(path))) {
      const id = m[1];
      const status = String(a.status ?? '');
      if (!UUID_RE.test(id)) throw bad('orderId');
      if (!ONEC_STATUSES.includes(status)) throw bad(`status: ${ONEC_STATUSES.join(' | ')}`);
      return panel(`order onec-status ${id}`, async () => {
        const o = overlay().setOrderStatus(id, status, a.approved === undefined ? undefined : a.approved === true);
        if (!o) throw notFound('Заказа нет в «1С» (ещё не передан или отклонён)');
        const job = await syncJob('order_status');
        return { orderId: id, onecNumber: o.number, status: o.status, approved: o.approved, sync: job };
      });
    }
    if (method === 'POST' && (m = /^orders\/([^/]+)\/ship$/.exec(path))) {
      if (!UUID_RE.test(m[1])) throw bad('orderId');
      return ship(m[1]);
    }
    if (method === 'POST' && (m = /^returns\/([^/]+)\/status$/.exec(path))) {
      const id = m[1];
      const status = String(a.status ?? '');
      if (!['submitted', 'accepted', 'rejected', 'completed'].includes(status)) throw bad('status: submitted | accepted | rejected | completed');
      return panel(`return status ${id}`, async () => {
        let manual = false;
        if (!ctx.be.cs.cashier.returnRequest(id)) {
          // RETURNS_FROM_POS_ENABLED=false (умолчание продукта, ADR-025): заявка в «1С» через outbox не уходит —
          // её оформляет оператор 1С по распечатке. Демо делает это за него по данным заявки POS.
          const rr = (
            await q(
              `SELECT r.id::text AS id, r.status::text AS status, r.reason::text AS reason, s.onec_ref::text AS shipment_ref, c.onec_ref::text AS customer_ref
                 FROM return_requests r JOIN shipments s ON s.id = r.shipment_id JOIN customers c ON c.id = r.customer_id WHERE r.id = $1`,
              [id],
            )
          ).rows[0];
          if (!rr) throw notFound('Заявка на возврат не найдена');
          if (!['submitted', 'accepted'].includes(rr.status)) throw new ControlError('STATE', `Заявка в статусе ${rr.status}: сначала «Отправить» в приложении`);
          const lines = (
            await q(
              `SELECT si.onec_line_no AS line, i.quantity::text AS quantity FROM return_request_items i JOIN shipment_items si ON si.id = i.shipment_item_id WHERE i.return_request_id = $1`,
              [id],
            )
          ).rows;
          const r = ctx.be.cs.cashier.createReturnRequest({
            externalId: id,
            shipmentRef: rr.shipment_ref,
            customerRef: rr.customer_ref ?? '00000000-0000-4000-8000-000000000000',
            reasonCode: rr.reason,
            lines: lines.map((l) => ({ shipmentLineNumber: Number(l.line), quantity: qty3(l.quantity) })),
          });
          if (r.status !== 201 && r.status !== 200) throw new ControlError('FAKE_ERROR', `«1С» не приняла заявку: ${JSON.stringify(r.body).slice(0, 200)}`);
          manual = true;
        }
        const body = fakeCall('POST', `/__fake/cashier/returns/${id}/status`, { status });
        const jobs = { returnDocs: await syncJob('return_docs'), changes: await send(QUEUES.onecChanges, { node: 'POS' }, 'POS') };
        return { externalId: id, onec: body, jobs, enteredByOperator: manual };
      });
    }
    if (method === 'POST' && (m = /^customers\/([^/]+)$/.exec(path))) {
      const ref = m[1];
      if (!UUID_RE.test(ref)) throw bad('ref клиента 1С');
      const patch = {};
      if (a.creditLimit !== undefined) {
        if (a.creditLimit !== null && !/^\d+(\.\d{2})?$/.test(String(a.creditLimit))) throw bad('creditLimit: «50000.00» или null');
        patch.creditLimit = a.creditLimit === null ? null : Number(a.creditLimit).toFixed(2); // money-double: allow — формат
      }
      if (a.creditAllowed !== undefined) patch.creditAllowed = a.creditAllowed === true;
      if (a.creditDays !== undefined) patch.creditDays = a.creditDays === null ? null : Number(a.creditDays);
      if (a.discountPercent !== undefined) patch.discountPercent = a.discountPercent === null ? null : String(a.discountPercent);
      return panel(`customer ${ref}`, async () => {
        const body = fakeCall('POST', `/__fake/cashier/customers/${ref}`, patch);
        const jobs = { changes: await send(QUEUES.onecChanges, { node: 'POS' }, 'POS'), receivables: await syncJob('receivables') };
        return { ref, onec: body, jobs };
      });
    }
    if (method === 'POST' && path === 'sync/catch-up') return panel('catch-up', () => catchUp(ctx.be.runtime, ctx.log));
    if (method === 'POST' && path === 'flush') return ctx.be.storage.flush('control');
    if (method === 'POST' && path === 'reset') return ctx.onReset();
    if (act === 'fake') {
      const p = String(a.path ?? '');
      if (!p.startsWith('/__fake/')) throw bad('fake: путь /__fake/*');
      return panel(`fake ${p}`, async () => {
        const r = fake().handle(String(a.method ?? 'POST'), p, a.body ?? {}, new URLSearchParams());
        return { status: r.status, body: r.body };
      });
    }
    if (act === 'config') return { gate: gate.configureGate(a.gate ?? {}), shim: pgShim.configureShim(a.shim ?? {}) };
    throw new ControlError('UNSUPPORTED', `команда не поддерживается сервером демо: ${act}`);
  };
}
