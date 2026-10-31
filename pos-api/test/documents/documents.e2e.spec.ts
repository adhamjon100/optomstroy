import { randomUUID } from 'node:crypto';
import { Money } from '../../src/common/money/money.js';
import { DOCUMENTS_PORT } from '../../src/common/ports/index.js';
import { formatMoney, formatQuantity } from '../../src/orders/documents/document-model.js';
import { DocumentsModule } from '../../src/orders/documents/documents.module.js';
import { type PosActor, PosTestApp } from '../support/pos-fixture.js';
import { parsePdf } from './support/pdf-text.js';

/**
 * RM-F-004, RM-F-012 п. 5 (e2e): `GET /orders/{id}/documents/{invoice|receipt|waybill}.pdf` на стенде pos-fixture
 * (embedded PostgreSQL 17, синтетический каталог; заказы — `seedOrder`, **тестовые данные**). Проверяются: PDF и
 * извлечённый текст (номер 1С, клиент, строки, суммы), момент печати (ядро §19.4: счёт — после номера 1С, чек —
 * после оплаты), 80 мм, «Нефискальный документ», права и IDOR (11 SEC-030), ETag/304, print_jobs, RL-PDF,
 * снимок наименований (PRINT-007), `DocumentsPort` для orders.
 */
const squash = (s: string) => s.replace(/\s+/g, '');
const norm = (s: string) => s.replace(/\s+/g, ' ');

let t: PosTestApp;
let a: Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>;

function pdfBuffer(res: { body: unknown }): Buffer {
  return Buffer.isBuffer(res.body) ? res.body : Buffer.from(String(res.body), 'binary');
}

/** supertest: бинарный ответ PDF целиком в Buffer. */
function binary(r: ReturnType<PosTestApp['req']>) {
  return r.buffer(true).parse((res, cb) => {
    const chunks: Buffer[] = [];
    res.on('data', (c: Buffer) => chunks.push(c));
    res.on('end', () => cb(null, Buffer.concat(chunks)));
  });
}

async function receive(orderId: string, paymentId: string, cashier: PosActor, received: string): Promise<void> {
  const [o] = await t.q<{ total: string }>('SELECT total::text AS total FROM orders WHERE id = $1', [orderId]);
  await t.q(
    `UPDATE payments SET status = 'received', received_amount = $2::numeric, change_amount = $2::numeric - amount,
            received_by_user_id = $3::uuid, received_at = now()
      WHERE id = $1::uuid`,
    [paymentId, received, cashier.userId],
  );
  await t.q(`UPDATE orders SET paid_amount = $2::numeric, paid_at = now() WHERE id = $1::uuid`, [orderId, o.total]);
}

beforeAll(async () => {
  t = await new PosTestApp().start({ modules: [DocumentsModule], jobs: false, skuCount: 60 });
  a = await t.actors();
  await t.q(`INSERT INTO user_profiles (user_id, full_name) VALUES ($1::uuid, 'Айгуль Кассирова')`, [a.cashier.userId]);
});

afterAll(async () => {
  await t?.stop();
});

describe('счёт на оплату (invoice.pdf) — PRINT-002/003, 08 §4.8.5', () => {
  // 12: T-PRINT-002 (счёт на оплату PDF A4: номер 1С, клиент, суммы как в заказе)
  it('после получения номера 1С: PDF A4 с номером 1С, клиентом, строками и суммами; ETag/304; print_jobs', async () => {
    const o = await t.seedOrder({
      createdBy: a.seller,
      method: 'cash',
      status: 'pending_approval',
      discountPercent: '5',
    });
    const started = Date.now();
    const res = await binary(t.req('get', `/orders/${o.orderId}/documents/invoice.pdf`, a.seller));
    expect(Date.now() - started).toBeLessThan(2000);
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toBe('application/pdf');
    expect(res.headers['content-disposition']).toBe(`inline; filename="invoice-${o.publicNumber}.pdf"`);
    expect(res.headers['cache-control']).toBe('private, no-cache');
    const etag = String(res.headers.etag);
    expect(etag).toMatch(/^"[0-9a-f]{64}"$/);

    const pdf = parsePdf(pdfBuffer(res));
    expect(pdf.pages[0].width).toBeCloseTo(595.28, 1);
    const [order] = await t.q<{ onec_number: string; total: string; subtotal: string; discount_total: string }>(
      `SELECT onec_number, total::text AS total, subtotal::text AS subtotal, discount_total::text AS discount_total
         FROM orders WHERE id = $1`,
      [o.orderId],
    );
    expect(pdf.text).toContain(`Счёт на оплату № ${order.onec_number}`);
    expect(squash(pdf.text)).toContain(squash('Розничный покупатель'));
    const items = await t.q<{ product_name_snapshot: string; line_total: string }>(
      'SELECT product_name_snapshot, line_total::text AS line_total FROM order_items WHERE order_id = $1 ORDER BY line_no',
      [o.orderId],
    );
    expect(items.length).toBeGreaterThan(0);
    const flat = squash(pdf.text);
    for (const i of items) {
      expect(flat).toContain(squash(i.product_name_snapshot));
      expect(flat).toContain(squash(formatMoney(i.line_total)));
    }
    // Арифметика документа: сумма строк = итог; подытог − скидка = итог (D-19, C-CR-01).
    const sumLines = items.reduce((s, i) => s + BigInt(i.line_total.replace('.', '')), 0n);
    expect(sumLines).toBe(BigInt(order.total.replace('.', '')));
    expect(BigInt(order.subtotal.replace('.', '')) - BigInt(order.discount_total.replace('.', ''))).toBe(
      BigInt(order.total.replace('.', '')),
    );
    expect(flat).toContain(squash(`Итого к оплате: ${formatMoney(order.total)}`));
    expect(flat).toContain(squash(`−${formatMoney(order.discount_total)}`));
    expect(pdf.text).toContain('Не является фискальным документом');

    const again = await t.req('get', `/orders/${o.orderId}/documents/invoice.pdf`, a.seller).set('If-None-Match', etag);
    expect(again.status).toBe(304);
    expect(again.headers.etag).toBe(etag);

    const jobs = await t.q<{ document_kind: string; paper: string; status: string; sha: string; by: string }>(
      `SELECT document_kind::text, paper, status::text, encode(sha256, 'hex') AS sha, requested_by_user_id AS by
         FROM print_jobs WHERE order_id = $1`,
      [o.orderId],
    );
    expect(jobs).toEqual([
      { document_kind: 'invoice', paper: 'a4', status: 'ready', sha: etag.slice(1, -1), by: a.seller.userId },
    ]);
    // Аудит не пишется (08 §4.8.5).
    expect(await t.auditRows('order.document_printed')).toEqual([]);
  });

  // 12: T-PRINT-001 (печать не блокирует заказ)
  it('без номера 1С (submitting, submit_failed) → 409 ORDER_STATE_INVALID «Ожидает номер 1С»; печать не блокирует заказ', async () => {
    for (const status of ['submitting', 'submit_failed'] as const) {
      const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status });
      const res = await t.req('get', `/orders/${o.orderId}/documents/invoice.pdf`, a.seller);
      expect(res.status).toBe(409);
      expect(res.body).toMatchObject({
        code: 'ORDER_STATE_INVALID',
        resource: 'order',
        reason: 'onec_number_pending',
        currentStatus: status,
      });
      const [row] = await t.q<{ status: string }>('SELECT status::text FROM orders WHERE id = $1', [o.orderId]);
      expect(row.status).toBe(status);
    }
  });

  it('format=thermal80 — лента 80 мм; copy=true — «КОПИЯ»; неверный format → 400', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    const res = await binary(
      t.req('get', `/orders/${o.orderId}/documents/invoice.pdf?format=thermal80&copy=true`, a.seller),
    );
    expect(res.status).toBe(200);
    const pdf = parsePdf(pdfBuffer(res));
    expect(pdf.pages).toHaveLength(1);
    expect(pdf.pages[0].width).toBeCloseTo(226.77, 2);
    expect(pdf.text).toContain('КОПИЯ');
    expect(pdf.text).toContain('QR-код (Бакай Банк)');
    const bad = await t.req('get', `/orders/${o.orderId}/documents/invoice.pdf?format=80mm`, a.seller);
    expect(bad.status).toBe(400);
    expect(bad.body.code).toBe('VALIDATION_FAILED');
    expect(bad.body.errors[0]).toMatchObject({ field: 'format' });
  });

  it('реквизиты организации — из app_settings.print.organization (Q-019)', async () => {
    await t.setSetting(
      'print.organization',
      JSON.stringify({
        name: 'ОсОО «Тест-Реквизиты»',
        inn: '99988877766655',
        bankName: 'Тест Банк',
        account: '1180000012345678',
      }),
    );
    try {
      const o = await t.seedOrder({ createdBy: a.cashier, method: 'cash', status: 'awaiting_payment' });
      const res = await binary(t.req('get', `/orders/${o.orderId}/documents/invoice.pdf`, a.cashier));
      const flat = squash(parsePdf(pdfBuffer(res)).text);
      expect(flat).toContain(squash('ОсОО «Тест-Реквизиты»'));
      expect(flat).toContain('99988877766655');
      expect(flat).toContain('1180000012345678');
    } finally {
      await t.q(`DELETE FROM app_settings WHERE key = 'print.organization'`);
      t.app.get((await import('../../src/common/settings/settings-reader.js')).SettingsReader).invalidate();
    }
  });

  // 12: T-PRINT-006 (неизменность печатных форм: product_name_snapshot)
  it('снимок наименования (PRINT-007): переименование товара после заказа не меняет счёт', async () => {
    const [v] = await t.saleableVariants(1);
    const o = await t.seedOrder({
      createdBy: a.seller,
      method: 'cash',
      status: 'pending_approval',
      items: [{ variantId: v.variantId, quantity: '1' }],
    });
    await t.q(`UPDATE products SET name = 'Переименованный товар' WHERE id = $1`, [v.productId]);
    const res = await binary(t.req('get', `/orders/${o.orderId}/documents/invoice.pdf`, a.seller));
    const flat = squash(parsePdf(pdfBuffer(res)).text);
    expect(flat).toContain(squash(v.productName));
    expect(flat).not.toContain(squash('Переименованный товар'));
  });
});

describe('нефискальный товарный чек (receipt.pdf) — PRINT-005, D-26, ядро §19.4', () => {
  // 12: T-PRINT-004 (товарный чек: до оплаты недоступен, после — 80 мм/A4 с «Получено/Сдача»), T-PAY-010 (квитанция после оплаты, нефискальная)
  it('до получения оплаты → 409 ORDER_STATE_INVALID; после received — A4 и 80 мм с «Получено/Сдача»', async () => {
    const o = await t.seedOrder({ createdBy: a.cashier, method: 'cash', status: 'submitting' });
    const before = await t.req('get', `/orders/${o.orderId}/documents/receipt.pdf`, a.cashier);
    expect(before.status).toBe(409);
    expect(before.body).toMatchObject({
      code: 'ORDER_STATE_INVALID',
      resource: 'order',
      reason: 'payment_not_received',
    });

    const port = t.registry.get(DOCUMENTS_PORT);
    const actor = { userId: a.cashier.userId, roles: ['cashier'], isCustomer: false };
    expect(await port.availability(o.orderId, actor)).toEqual({
      invoice: null,
      receipt: null,
      waybill: { available: false, reason: 'waybill_from_onec' },
    });

    const received = Money.of(o.total).plus(Money.of('100.00')).toString();
    await receive(o.orderId, o.paymentId, a.cashier, received);
    expect((await port.availability(o.orderId, actor)).receipt).toBe(
      `/api/v1/orders/${o.orderId}/documents/receipt.pdf`,
    );

    const res = await binary(t.req('get', `/orders/${o.orderId}/documents/receipt.pdf`, a.cashier));
    expect(res.status).toBe(200);
    expect(res.headers['content-disposition']).toBe(`inline; filename="receipt-${o.publicNumber}.pdf"`);
    const pdf = parsePdf(pdfBuffer(res));
    const text = norm(pdf.text);
    // Номер 1С ещё не получен (submitting) — внутренний номер заказа POS.
    expect(text).toContain(`Товарный чек № ${o.publicNumber}`);
    expect(text).toContain('(не является фискальным документом)');
    expect(text).toContain('Нефискальный документ');
    const changeStr = '100.00';
    expect(squash(pdf.text)).toContain(squash(`Получено: ${formatMoney(received)}`));
    expect(squash(pdf.text)).toContain(squash(`Сдача: ${formatMoney(changeStr)}`));
    expect(squash(pdf.text)).toContain(squash('Кассир Айгуль Кассирова'));

    const thermal = await binary(
      t.req('get', `/orders/${o.orderId}/documents/receipt.pdf?format=thermal80`, a.cashier),
    );
    expect(thermal.status).toBe(200);
    const tp = parsePdf(pdfBuffer(thermal));
    expect(tp.pages[0].width).toBeCloseTo(226.77, 2);
    expect(norm(tp.text)).toContain('Нефискальный документ. Не является фискальным документом');
    expect(squash(tp.text)).toContain(squash(`Получено${formatMoney(received)}`));
    expect(squash(tp.text)).toContain(squash(`Сдача${formatMoney(changeStr)}`));
  });

  // 10 PRINT-002/005 «кол-во, ед.»: единица — наименование из справочника `units`, а не код ОКЕИ снимка
  // (веб-демо uiA-05: «1 796 × 43 348,00» — количество 1 и код 796 читались как 1796 единиц).
  it('строки чека и счёта: «кол-во ед. × цена» с наименованием единицы, не с кодом', async () => {
    const o = await t.seedOrder({ createdBy: a.cashier, method: 'cash', status: 'awaiting_payment' });
    await receive(o.orderId, o.paymentId, a.cashier, o.total);
    const [line] = await t.q<{ quantity: string; code: string; name: string; unit_price: string }>(
      `SELECT i.quantity::text AS quantity, i.unit_code_snapshot AS code, u.name, i.unit_price::text AS unit_price
         FROM order_items i JOIN units u ON u.code = i.unit_code_snapshot
        WHERE i.order_id = $1::uuid ORDER BY i.line_no LIMIT 1`,
      [o.orderId],
    );
    expect(line.name).not.toBe(line.code);
    const qty = formatQuantity(line.quantity);
    const thermal = await binary(
      t.req('get', `/orders/${o.orderId}/documents/receipt.pdf?format=thermal80`, a.cashier),
    );
    expect(thermal.status).toBe(200);
    const text = squash(parsePdf(pdfBuffer(thermal)).text);
    expect(text).toContain(squash(`${qty} ${line.name} × ${formatMoney(line.unit_price)}`));
    expect(text).not.toContain(squash(`${qty} ${line.code} ×`));
  });

  // 10 INV-002, 07 DATA-137: в строке с упаковкой `quantity` — в упаковках, `unit_price` — за упаковку, а снимок
  // единицы — базовая единица товара. «Ед.» в документе — упаковка, иначе «2 кг × 450,00» за 2 мешка (ревью F2).
  // Упаковка с единицей = базовой (худший случай данных 1С) — всё равно печатается упаковка. Тестовые данные.
  it('строка в упаковках: «Ед.» — упаковка, не базовая единица (чек и счёт, 80 мм и A4)', async () => {
    const o = await t.seedOrder({ createdBy: a.cashier, method: 'cash', status: 'awaiting_payment' });
    await receive(o.orderId, o.paymentId, a.cashier, o.total);
    const [line] = await t.q<{
      id: string;
      product_id: string;
      quantity: string;
      unit_price: string;
      base_name: string;
      unit_id: string;
    }>(
      `SELECT i.id::text AS id, i.product_id::text AS product_id, i.quantity::text AS quantity,
              i.unit_price::text AS unit_price, u.name AS base_name, u.id::text AS unit_id
         FROM order_items i JOIN units u ON u.code = i.unit_code_snapshot
        WHERE i.order_id = $1::uuid ORDER BY i.line_no LIMIT 1`,
      [o.orderId],
    );
    const packName = `Упаковка тест (47 ${line.base_name})`;
    const [pk] = await t.q<{ id: string }>(
      `INSERT INTO packagings (synced_at, source_hash, product_id, unit_id, name, factor)
       VALUES (now(), 'test', $1::uuid, $2::uuid, $3, 47) RETURNING id::text AS id`,
      [line.product_id, line.unit_id, packName],
    );
    // Строки заказа неизменяемы после отправки (trg_order_items_freeze) — правка сида в обход, как миграция.
    const c = await t.pool.connect();
    try {
      await c.query('BEGIN');
      await c.query(`SELECT set_config('app.system', 'migration', true)`);
      await c.query(
        `UPDATE order_items SET packaging_id = $2::uuid, packaging_name_snapshot = $3, packaging_factor_snapshot = 47,
                base_quantity = quantity * 47
          WHERE id = $1::uuid`,
        [line.id, pk.id, packName],
      );
      await c.query('COMMIT');
    } catch (e) {
      await c.query('ROLLBACK');
      throw e;
    } finally {
      c.release();
    }
    const qty = formatQuantity(line.quantity);
    const price = formatMoney(line.unit_price);
    const docs = [
      ['receipt', 'thermal80', a.cashier],
      ['receipt', 'a4', a.cashier],
      ['invoice', 'thermal80', a.cashier],
      ['invoice', 'a4', a.cashier],
    ] as const;
    for (const [kind, format, actor] of docs) {
      const res = await binary(t.req('get', `/orders/${o.orderId}/documents/${kind}.pdf?format=${format}`, actor));
      expect(res.status, `${kind} ${format}`).toBe(200);
      const text = squash(parsePdf(pdfBuffer(res)).text);
      // 80 мм: «кол-во ед. × цена» в одной ячейке; A4: колонки «Кол-во», «Ед.», «Цена» подряд.
      const want = format === 'thermal80' ? `${qty} ${packName} × ${price}` : `${qty} ${packName} ${price}`;
      const wrong =
        format === 'thermal80' ? `${qty} ${line.base_name} × ${price}` : `${qty} ${line.base_name} ${price}`;
      expect(text, `${kind} ${format}`).toContain(squash(want));
      expect(text, `${kind} ${format}`).not.toContain(squash(wrong));
    }
  });

  it('DocumentsPort.render (для orders) — PDF; customer — счёт без чека в availability', async () => {
    const o = await t.seedOrder({ createdBy: a.cashier, method: 'cash', status: 'awaiting_payment' });
    await receive(o.orderId, o.paymentId, a.cashier, o.total);
    const port = t.registry.get(DOCUMENTS_PORT);
    const doc = await port.render('receipt', o.orderId, 'thermal80', {
      userId: a.cashier.userId,
      roles: ['cashier'],
      isCustomer: false,
    });
    expect(doc.contentType).toBe('application/pdf');
    expect(doc.fileName).toBe(`receipt-${o.publicNumber}.pdf`);
    expect(parsePdf(doc.body).pages[0].width).toBeCloseTo(226.77, 2);
    const av = await port.availability(o.orderId, { userId: a.customer.userId, roles: ['customer'], isCustomer: true });
    expect(av.invoice).toBe(`/api/v1/orders/${o.orderId}/documents/invoice.pdf`);
    expect(av.receipt).toBeNull();
  });
});

describe('накладная (waybill.pdf) — статус документа 1С, PRINT-004, D-27', () => {
  // 12: T-PRINT-003 (накладная — из 1С: available:false)
  it('по умолчанию 200 JSON {available:false, reason: waybill_from_onec, onecNumber}; customer → 403', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_shipment' });
    const res = await t.req('get', `/orders/${o.orderId}/documents/waybill.pdf`, a.seller);
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/application\/json/);
    const [row] = await t.q<{ onec_number: string }>('SELECT onec_number FROM orders WHERE id = $1', [o.orderId]);
    expect(res.body).toEqual({ available: false, reason: 'waybill_from_onec', onecNumber: row.onec_number });
    const cust = await t.req('get', `/orders/${o.orderId}/documents/waybill.pdf`, a.customer);
    expect(cust.status).toBe(403);
    expect(cust.body.code).toBe('FORBIDDEN');
  });
});

describe('права и IDOR (11 §4.4, SEC-030; 08 §4.8.5)', () => {
  it('seller — только свои заказы (чужой → 404); cashier/senior_seller/admin/owner — любой; без токена → 401', async () => {
    const other = await t.actor({ role: 'seller' });
    const o = await t.seedOrder({ createdBy: other, method: 'cash', status: 'pending_approval' });
    const foreign = await t.req('get', `/orders/${o.orderId}/documents/invoice.pdf`, a.seller);
    expect(foreign.status).toBe(404);
    expect(foreign.body.code).toBe('NOT_FOUND');
    const missing = await t.req('get', `/orders/${randomUUID()}/documents/invoice.pdf`, a.seller);
    expect(missing.status).toBe(404);
    const foreignWaybill = await t.req('get', `/orders/${o.orderId}/documents/waybill.pdf`, a.seller);
    expect(foreignWaybill.status).toBe(404);
    for (const role of ['cashier', 'senior_seller', 'admin', 'owner'] as const) {
      const r = await t.req('get', `/orders/${o.orderId}/documents/invoice.pdf`, a[role]);
      expect(r.status, role).toBe(200);
    }
    const anon = await t.req('get', `/orders/${o.orderId}/documents/invoice.pdf`);
    expect(anon.status).toBe(401);
  });

  it('customer: счёт своего заказа (подтверждённая привязка) → 200, чек → 403, чужой заказ → 404', async () => {
    const customerId = await t.createOnecCustomer({ name: 'ИП Клиентов (тест)' });
    const me = await t.actor({ role: 'customer' });
    await t.linkCustomer(me.userId, customerId, 'confirmed');
    const mine = await t.seedOrder({ createdBy: a.cashier, customerId, method: 'cash', status: 'awaiting_payment' });
    await receive(mine.orderId, mine.paymentId, a.cashier, mine.total);
    const inv = await binary(t.req('get', `/orders/${mine.orderId}/documents/invoice.pdf`, me));
    expect(inv.status).toBe(200);
    expect(squash(parsePdf(pdfBuffer(inv)).text)).toContain(squash('ИП Клиентов (тест)'));
    const rec = await t.req('get', `/orders/${mine.orderId}/documents/receipt.pdf`, me);
    expect(rec.status).toBe(403);
    expect(rec.body.code).toBe('FORBIDDEN');

    const stranger = await t.actor({ role: 'customer' });
    const proposed = await t.actor({ role: 'customer' });
    await t.linkCustomer(proposed.userId, customerId, 'proposed');
    for (const who of [stranger, proposed]) {
      const r = await t.req('get', `/orders/${mine.orderId}/documents/invoice.pdf`, who);
      expect(r.status).toBe(404);
    }
  });

  it('RL-PDF: 20 запросов в минуту на пользователя, 21-й → 429 RATE_LIMITED с Retry-After', async () => {
    const u = await t.actor({ role: 'cashier' });
    const id = randomUUID();
    for (let i = 0; i < 20; i += 1) {
      const r = await t.req('get', `/orders/${id}/documents/invoice.pdf`, u);
      expect(r.status).toBe(404);
    }
    const r = await t.req('get', `/orders/${id}/documents/invoice.pdf`, u);
    expect(r.status).toBe(429);
    expect(r.body.code).toBe('RATE_LIMITED');
    expect(Number(r.headers['retry-after'])).toBeGreaterThan(0);
    // Лимит — на пользователя: другой пользователь не затронут.
    const other = await t.req('get', `/orders/${id}/documents/invoice.pdf`, a.owner);
    expect(other.status).toBe(404);
  });
});
