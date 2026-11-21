// Раунд исправлений fixo1 (ревью онлайн-обмена, 20.11.2026, сценарии .tmp/onec-check/hunt-o1): каждый неверный ответ 1С —
// через фасад test/helpers/front-1c.mjs, отдельный процесс программы. Неверные ответы — нужна ОШИБКА (или ЗАМЕЧАНИЕ) у
// названной проверки; «верно:» — необычный, но верный ответ, который ОШИБКИ давать не должен. Данные вымышленные.
//  - заказ и QR, созданные программой, приходят в /changes (C14): Document_ЗаказКлиента с externalId и ref заказа,
//    QrPaymentStatus с externalId, статусом cancelled и reference выданного QR; встроенный имитатор их регистрирует;
//  - неверный X-POS-Client-Key во всех методах (A6), не только в /health;
//  - отмена заказа (O6): заказ действительно отменён; статус и пакетный статус после отмены — то же состояние;
//  - ответ создания заказа (O1, O2): тот externalId, документ проведён, не согласован;
//  - 200 на неизвестный externalId у методов статуса (O0, R0, Q0) — ОШИБКА (§8.4);
//  - QR (Q1–Q3, Q6, Q8): сумма запроса, есть qrPayload или qrImagePng, повтор и статус — тот же QR;
//  - заявки на возврат не сделаны (1С их не принимает, Q-018) — МЕТОДА НЕТ, не ОШИБКА.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { jsonResponse, mutateJson, isoBishkek } from './helpers/front-1c.mjs';
import {
  frontWithSecrets, makeConfig, runMain, runInteractive, readProtocol, check, checkTexts, tmpDir, secretForms, leaks, limiter,
} from './helpers/env.mjs';

const dirs = [];
const closers = [];
after(async () => { for (const c of closers) await c(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });
const limit = limiter(4);

const is = (c, m, re) => c.method === m && re.test(c.sub || '');
const ORDERS = /^\/pos\/v1\/orders$/;
const ORDER_ST = /^\/pos\/v1\/orders\/[^/]+\/status$/;
const ORDER_BATCH = /^\/pos\/v1\/orders\/status$/;
const ORDER_CANCEL = /^\/pos\/v1\/orders\/[^/]+\/cancel$/;
const QR = /^\/pos\/v1\/payments\/qr$/;
const QR_ST = /^\/pos\/v1\/payments\/[^/]+\/status$/;
const RET = /^\/pos\/v1\/returns$/;
const RET_ST = /^\/pos\/v1\/returns\/[^/]+\/status$/;
const CHANGES = /^\/pos\/v1\/changes$/;
const HEALTH = /^\/pos\/v1\/health$/;
const ok2 = (r) => r.status >= 200 && r.status < 300;
const codes = (c) => c.findings.map((f) => `${f.severity} ${f.code}`);
const each = (j, type, fn) => { for (const it of (j && Array.isArray(j.items)) ? j.items : []) if (it && it.type === type) fn(it); };
const isoIn = (ms) => isoBishkek(new Date(Date.now() + ms));

/**
 * Прогон против фасада с дефектом. write — запись с подтверждением; на «Выполнить перерегистрацию?» — «н», на «Создать
 * пробный QR?» — «д» (qr: true); ручные шаги после записи получают «нет ввода» (ПРОПУЩЕНО).
 */
function runWith(defect, { write = true, qr = true, clientKey } = {}) {
  return limit(async () => {
    const { front, password, clientKey: ck } = await frontWithSecrets({ defect, ...(clientKey ? { clientKey } : {}) });
    closers.push(() => front.close());
    const dir = tmpDir(`oc-o1-${defect.id}-`);
    dirs.push(dir);
    const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey: ck });
    const base = ['--config', cfg, '--allow-http'];
    const r = write
      ? await runInteractive([...base, '--allow-write'], [
        [/введите имя публикации/, front.publication],
        [/Выполнить перерегистрацию[^\n]*: /, 'н'],
        ...(qr ? [[/Создать пробный QR[^\n]*: /, 'д']] : []),
      ], { timeoutMs: 240000 })
      : await runMain([...base, '--no-manual'], { timeoutMs: 240000 });
    const p = readProtocol(path.join(dir, 'protokoly'));
    assert.ok(p, `нет протокола: ${r.out.slice(-1500)}`);
    assert.deepEqual(leaks([r.out, ...p.texts], secretForms(password, ck)), [], 'секрет в выводе');
    return { ...r, p, journal: front.journal, inner: front.inner };
  });
}

function expectFinding(r, id, verdict, code, fragment = null) {
  const c = check(r.p, id);
  assert.ok(c, `нет проверки ${id}`);
  assert.equal(c.verdict, verdict, `${id}: ${c.verdict} — ${checkTexts(c)}`);
  const f = c.findings.find((x) => x.code === code);
  assert.ok(f, `${id}: нет находки ${code}; есть: ${codes(c).join(', ')}`);
  if (fragment) assert.match(f.text, fragment);
  return f;
}
const noFail = (r) => {
  const bad = r.p.json.checks.filter((c) => c.verdict === 'FAIL').map((c) => `${c.id}: ${checkTexts(c).slice(0, 300)}`);
  assert.deepEqual(bad, []);
  assert.equal(r.code, 0, r.out.slice(-1500));
};

// ---------------------------------------------------------------- C14: заказ и QR в /changes (O17, O18)

test('O17: встроенный имитатор регистрирует заказ и QR — C14 ПРОЙДЕНО «клиент, заказ, QR», в сообщении Document_ЗаказКлиента и QrPaymentStatus', async () => {
  const r = await runWith({ id: 'GOOD' });
  noFail(r);
  const c = check(r.p, 'C14');
  assert.equal(c.verdict, 'PASS', checkTexts(c));
  assert.match(c.summary, /с нашим externalId: клиент, заказ, QR/);
  // Ответы /changes после записи несут оба элемента с externalId программы.
  const ch = r.journal.filter((j) => j.path === '/pos/v1/changes' && j.status === 200);
  assert.ok(ch.length, 'чтений /changes нет');
  const o1 = r.p.json.createdObjects.find((o) => o.checkId === 'O1');
  const q1 = r.p.json.createdObjects.find((o) => o.checkId === 'Q1');
  assert.ok(o1 && q1, JSON.stringify(r.p.json.createdObjects));
  const st = r.inner.state;
  const order = [...st.registrations.values()].find((i) => i.type === 'Document_ЗаказКлиента');
  assert.equal(order, undefined, 'после ack C14 регистрации сняты');
  assert.ok(st.orders.has(o1.externalId) && st.qr.has(q1.externalId));
  const item = st.orderItem(o1.externalId);
  assert.equal(item.externalId, o1.externalId);
  assert.equal(item.status, 'Закрыт', 'отменённый заказ — в текущем состоянии');
  assert.equal(st.qrItem(q1.externalId).status, 'cancelled');
});

test('O17: заказа и QR нет в /changes (документ и регистр POS_ОплатыQR не регистрируются) — C14 ОШИБКА, код 1', async () => {
  const r = await runWith({
    id: 'O17',
    after: (c, res) => (is(c, 'GET', CHANGES) && res.status === 200 ? mutateJson(res, (j) => {
      if (Array.isArray(j.items)) j.items = j.items.filter((i) => i.type !== 'Document_ЗаказКлиента' && i.type !== 'QrPaymentStatus');
    }) : null),
  });
  expectFinding(r, 'C14', 'FAIL', 'order-not-found', /заказ из O1 .* не пришёл в сообщении \d+ элементом Document_ЗаказКлиента .*Требования §6\.6 «Регистрация изменений», §5\.1/);
  expectFinding(r, 'C14', 'FAIL', 'qr-not-found', /QR из Q1 .* не пришёл .* элементом QrPaymentStatus .*§6\.14 п\. 9, §7\.10.*вопрос 70/);
  assert.equal(r.code, 1);
});

test('O18: заказ в /changes с externalId = null, QR — со статусом pending и чужим reference — C14 ОШИБКА', async () => {
  const r = await runWith({
    id: 'O18',
    after: (c, res) => (is(c, 'GET', CHANGES) && res.status === 200 ? mutateJson(res, (j) => {
      each(j, 'Document_ЗаказКлиента', (it) => { it.externalId = null; });
      each(j, 'QrPaymentStatus', (it) => { it.status = 'pending'; it.reference = 'QR-ДРУГОЙ-1'; });
    }) : null),
  });
  expectFinding(r, 'C14', 'FAIL', 'order-external-id', /externalId = null, нужен наш .*§6\.2 правило 8.*пропускает \(§5\.1\)/);
  expectFinding(r, 'C14', 'FAIL', 'qr-status', /status «pending», а QR отменён \(Q4\) — нужен cancelled/);
  expectFinding(r, 'C14', 'FAIL', 'qr-reference', /reference «QR-ДРУГОЙ-1», а QR выдан с reference/);
  assert.equal(r.code, 1);
});

// ---------------------------------------------------------------- A6: неверный ключ (A01)

test('A01: неверный X-POS-Client-Key принят всеми методами, кроме /health — A6 ОШИБКА «с неверным ключом», A3 ПРОЙДЕНО', async () => {
  const clientKey = 'Test-Klyuch-' + crypto.randomBytes(8).toString('hex');
  const r = await runWith({
    id: 'A01',
    before: (c) => {
      // Код 1С проверяет только, что ключ заполнен; значение сравнивает лишь /health.
      if (c.key && c.key !== clientKey && c.sub && !HEALTH.test(c.sub)) c.req.headers['x-pos-client-key'] = clientKey;
      return null;
    },
  }, { write: false, clientKey });
  assert.equal(check(r.p, 'A3').verdict, 'PASS');
  const f = expectFinding(r, 'A6', 'FAIL', 'wrong-key-accepted', /GET \/pos\/v1\/changes: с неверным ключом ответ 200 — ключ не сверяется/);
  assert.match(f.where, /с неверным ключом/);
  expectFinding(r, 'A6', 'FAIL', 'wrong-key-status', /с неверным ключом 404 POS_E_NOT_FOUND — ключ не проверяется в методе .*§4\.4 п\. 3/);
  // Без ключа методы по-прежнему отвечают 401 — находок «без ключа» нет.
  assert.ok(!check(r.p, 'A6').findings.some((x) => x.code === 'accepted' || x.code === 'status'), codes(check(r.p, 'A6')).join(', '));
  assert.equal(r.code, 1);
});

test('H14: неверный ключ → 403 POS_E_FORBIDDEN во всех методах — A3 и A6 ОШИБКА «нужен 401; 403 — только пользователь без роли»', async () => {
  const clientKey = 'Test-Klyuch-' + crypto.randomBytes(8).toString('hex');
  const r = await runWith({
    id: 'H14',
    before: (c) => (c.key && c.key !== clientKey && c.sub ? jsonResponse(403, { code: 'POS_E_FORBIDDEN', message: 'Доступ запрещён: неверный ключ клиента', requestId: c.reqId }, c.reqId) : null),
  }, { write: false, clientKey });
  assert.equal(check(r.p, 'A3').verdict, 'FAIL');
  expectFinding(r, 'A6', 'FAIL', 'wrong-key-status', /GET \/pos\/v1\/changes: с неверным ключом 403 POS_E_FORBIDDEN — нужен 401 POS_E_UNAUTHORIZED: 403 POS_E_FORBIDDEN — только пользователь без роли POS_ИнтеграцияPOS/);
  assert.equal(r.code, 1);
});

// ---------------------------------------------------------------- O6: отмена (O10, O07)

test('O10: отмена ответила 200, а заказ не отменён (КВыполнению, approved, deletionMark=false) — O6 ОШИБКА', async () => {
  const r = await runWith({
    id: 'O10',
    after: (c, res) => (is(c, 'POST', ORDER_CANCEL) && res.status === 200 ? mutateJson(res, (j) => { j.status = 'КВыполнению'; j.approved = true; j.deletionMark = false; }) : null),
  }, { qr: false });
  expectFinding(r, 'O6', 'FAIL', 'not-cancelled', /заказ не отменён: status «КВыполнению», deletionMark = false — признак отмены .*«Закрыт».*Требования §6\.7.*КП-15/);
  assert.equal(r.code, 1);
});

test('O07: отмена ответила «Закрыт», а статус и пакетный статус после неё — прежние — O6 ОШИБКА (без кэширования, §6.8)', async () => {
  const r = await runWith({
    id: 'O07',
    after: (c, res) => {
      const pre = (j) => { j.status = 'НеСогласован'; j.approved = false; j.deletionMark = false; };
      if (is(c, 'GET', ORDER_ST) && res.status === 200) return mutateJson(res, pre);
      if (is(c, 'POST', ORDER_BATCH) && res.status === 200) return mutateJson(res, (j) => { for (const it of j.items || []) pre(it); });
      return null;
    },
  }, { qr: false });
  expectFinding(r, 'O6', 'FAIL', 'status-after-cancel', /после отмены GET \/orders\/\{uuid\}\/status отдаёт status «НеСогласован», deletionMark = false, а отмена ответила status «Закрыт».*§6\.8 «без кэширования»/);
  expectFinding(r, 'O6', 'FAIL', 'batch-after-cancel', /после отмены POST \/orders\/status отдаёт status «НеСогласован»/);
  assert.equal(r.code, 1);
});

test('O6: статус отмены, которого POS не знает («Отменен»), во всех ответах — ЗАМЕЧАНИЕ «пришлите статус отмены», код 0', async () => {
  const r = await runWith({
    id: 'O6UNK',
    after: (c, res) => {
      const fix = (j) => { if (j && j.status === 'Закрыт') { j.status = 'Отменен'; j.deletionMark = false; } };
      if ((is(c, 'POST', ORDER_CANCEL) || is(c, 'GET', ORDER_ST)) && res.status === 200) return mutateJson(res, fix);
      if (is(c, 'POST', ORDER_BATCH) && res.status === 200) return mutateJson(res, (j) => { for (const it of j.items || []) fix(it); });
      if (is(c, 'GET', CHANGES) && res.status === 200) return mutateJson(res, (j) => each(j, 'Document_ЗаказКлиента', fix));
      return null;
    },
  }, { qr: false });
  expectFinding(r, 'O6', 'WARN', 'cancel-status-unknown', /status «Отменен», deletionMark = false: такой статус POS не знает .*пришлите статус отмены вашей конфигурации/);
  noFail(r);
});

test('верно: отмена пометкой удаления (НеСогласован, deletionMark=true) — в отмене, статусах, /changes и /external-ids одинаково — O6, O7 без ОШИБКИ', async () => {
  const r = await runWith({
    id: 'V03B',
    after: (c, res) => {
      const fix = (j) => { if (j && j.status === 'Закрыт') { j.status = 'НеСогласован'; j.approved = false; j.deletionMark = true; } };
      // fixo2: помеченный заказ и в /external-ids — с deletionMark: true (Требования §6.20), иначе X4 ОШИБКА (сценарий G17).
      const cx = (c.state.cx ||= new Set());
      if (is(c, 'POST', ORDER_CANCEL) && res.status === 200) cx.add((c.sub || '').split('/')[4]);
      if (c.method === 'GET' && c.sub === '/pos/v1/external-ids' && res.status === 200) return mutateJson(res, (j) => { for (const it of j.items || []) if (cx.has(it.externalId)) it.deletionMark = true; });
      if ((is(c, 'POST', ORDER_CANCEL) || is(c, 'GET', ORDER_ST)) && res.status === 200) return mutateJson(res, fix);
      if (is(c, 'POST', ORDER_BATCH) && res.status === 200) return mutateJson(res, (j) => { for (const it of j.items || []) fix(it); });
      if (is(c, 'GET', CHANGES) && res.status === 200) return mutateJson(res, (j) => each(j, 'Document_ЗаказКлиента', fix));
      return null;
    },
  }, { qr: false });
  for (const id of ['O6', 'O7', 'C14']) assert.equal(check(r.p, id).verdict, 'PASS', `${id}: ${checkTexts(check(r.p, id))}`);
  noFail(r);
});

// ---------------------------------------------------------------- O1, O2: ответ создания (O01, O02, O15)

test('O01, O02, O15: заказ не проведён, уже согласован, в ответе чужой externalId — O1 и O2 ОШИБКА', async () => {
  const r = await runWith({
    id: 'O01',
    after: (c, res) => (is(c, 'POST', ORDERS) && ok2(res) ? mutateJson(res, (j) => {
      j.posted = false; j.status = 'Согласован'; j.approved = true; j.externalId = crypto.randomUUID();
    }) : null),
  }, { qr: false });
  for (const id of ['O1', 'O2']) {
    expectFinding(r, id, 'FAIL', 'posted', /posted = false — ответ 201 .*«документ создан и проведён».*§6\.6/);
    expectFinding(r, id, 'FAIL', 'approved', /заказ уже согласован или закрыт \(status «Согласован», approved = true\) — при создании статус «Не согласован».*КП-8/);
    expectFinding(r, id, 'FAIL', 'external-id', /externalId ответа «[0-9a-f-]{36}», а в запросе 5e1f7e57-.*§6\.6 «Ответ»/);
  }
  assert.equal(r.code, 1);
});

test('верно: заказ «Не согласован» (с пробелом), автоскидка 1С (итог 0.97, recalculated=true), предупреждение и лишние поля — O1, O2 без ОШИБКИ', async () => {
  const r = await runWith({
    id: 'V01',
    after: (c, res) => (is(c, 'POST', ORDERS) && ok2(res) ? mutateJson(res, (j) => {
      j.status = 'Не согласован'; j.totals = { subtotal: '1.00', discount: '0.03', total: '0.97', currency: 'KGS' }; j.recalculated = true;
      j.warnings = ['Применена автоматическая скидка 1С']; j.manager = 'Менеджер POS';
    }) : null),
  }, { qr: false });
  for (const id of ['O1', 'O2', 'O3']) assert.equal(check(r.p, id).verdict, 'PASS', `${id}: ${checkTexts(check(r.p, id))}`);
  noFail(r);
});

// ---------------------------------------------------------------- O0, R0, Q0: 200 на неизвестный externalId (O09b, R03b, Q00b)

test('O09b, R03b, Q00b: неизвестный externalId → 200 «фантом» у статусов заказа, заявки и QR — O0, R0, Q0 ОШИБКА (§8.4)', async () => {
  const r = await runWith({
    id: 'O09B',
    after: (c, res) => {
      const id = (c.sub || '').split('/')[4];
      if (is(c, 'GET', ORDER_ST) && res.status === 404) {
        return jsonResponse(200, { externalId: id, ref: id, number: '', date: isoBishkek(), status: '', approved: false, fulfillmentState: null, deletionMark: false, total: '0.00', shipments: [] }, c.reqId);
      }
      if (is(c, 'GET', RET_ST) && res.status === 404) return jsonResponse(200, { ref: id, number: '', status: 'submitted', onecStatus: null }, c.reqId);
      if (is(c, 'GET', QR_ST) && res.status === 404) {
        return jsonResponse(200, { externalId: id, status: 'expired', reference: '', amount: '0.00', paidAmount: null, paidAt: null, bankReference: null, expiresAt: isoIn(-60e3), documentRef: null, documentType: null }, c.reqId);
      }
      return null;
    },
  }, { write: false });
  expectFinding(r, 'O0', 'FAIL', '200', /на случайный GUID \(неизвестный externalId\) ответ 200 — нужен 404 POS_E_NOT_FOUND \(Требования §6\.8 .*§8\.4/);
  expectFinding(r, 'R0', 'FAIL', '200', /ответ 200 — нужен 404 POS_E_NOT_FOUND \(Требования §6\.18 .*§8\.4/);
  expectFinding(r, 'Q0', 'FAIL', '200', /ответ 200 — нужен 404 POS_E_NOT_FOUND \(Требования §6\.15 .*§8\.4/);
  assert.equal(r.code, 1);
});

// ---------------------------------------------------------------- QR (Q01, Q03, Q04, Q06, Q13)

test('Q01, Q03: QR на 100.00 при запросе 1.00 (тыйыны), ни qrPayload, ни qrImagePng — Q1 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Q01',
    after: (c, res) => {
      const x100 = (j) => { if (j.amount) j.amount = (Number(j.amount) * 100).toFixed(2); };
      if (is(c, 'POST', QR) && ok2(res)) return mutateJson(res, (j) => { x100(j); j.qrPayload = null; j.qrImagePng = null; });
      if (is(c, 'GET', QR_ST) && res.status === 200) return mutateJson(res, x100);
      return null;
    },
  });
  expectFinding(r, 'Q1', 'FAIL', 'amount', /amount «100\.00», а QR запрошен на 1\.00 KGS .*§6\.14 п\. 4/);
  expectFinding(r, 'Q1', 'FAIL', 'no-qr', /qrPayload null и qrImagePng null — покупателю нечего показать.*одно из двух/);
  assert.equal(r.code, 1);
});

test('Q04, Q06, Q13: повтор при действующем QR — новые qrPayload и срок; статус — референс операции банка и пересчитанный срок — Q2, Q3, Q6, Q8 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Q04',
    after: (c, res) => {
      if (is(c, 'POST', QR) && res.status === 200) {
        c.state.q4 = (c.state.q4 || 0) + 1;
        return mutateJson(res, (j) => { j.qrPayload = (j.qrPayload || 'X') + '-R' + c.state.q4; j.expiresAt = isoIn(900e3 + 30e3); });
      }
      if (is(c, 'GET', QR_ST) && res.status === 200) {
        return mutateJson(res, (j) => { j.reference = 'OP-' + crypto.randomBytes(4).toString('hex').toUpperCase(); j.expiresAt = isoIn(900e3 + 5e3 + crypto.randomInt(1000) * 1e3); });
      }
      return null;
    },
  });
  expectFinding(r, 'Q2', 'FAIL', 'same-qr', /повтор при действующем QR: reference тот же, а qrPayload, expiresAt .* другие — похоже, банк вызван снова.*§6\.14 п\. 2/);
  expectFinding(r, 'Q3', 'FAIL', 'reference', /статус: reference «OP-[0-9A-F]+», а QR выдан с reference «QR-DEMO-\d+».*§7\.3 п\. 7/);
  expectFinding(r, 'Q3', 'FAIL', 'expires-changed', /срок действия выданного QR не пересчитывается/);
  expectFinding(r, 'Q6', 'FAIL', 'reference');
  expectFinding(r, 'Q8', 'FAIL', 'reference');
  assert.equal(r.code, 1);
});

test('верно: QR картинкой (qrPayload = null, qrImagePng), срок банка короче запрошенного, bankReference при pending, лишние поля — Q1–Q8 без ОШИБКИ', async () => {
  const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
  const r = await runWith({
    id: 'V05',
    after: (c, res) => {
      if (!((is(c, 'POST', QR) || is(c, 'GET', QR_ST)) && ok2(res))) return null;
      c.state.qrT ||= Date.now();
      return mutateJson(res, (j) => {
        if ('qrPayload' in j) { j.qrPayload = null; j.qrImagePng = png; }
        j.expiresAt = isoBishkek(new Date(c.state.qrT + 120e3));
        if (is(c, 'GET', QR_ST)) j.bankReference = 'BK-OP-000777';
        j.bankName = 'Тестовый банк';
      });
    },
  });
  for (const id of ['Q1', 'Q2', 'Q3', 'Q4', 'Q5', 'Q6', 'Q7', 'Q8', 'C14']) assert.equal(check(r.p, id).verdict, 'PASS', `${id}: ${checkTexts(check(r.p, id))}`);
  noFail(r);
});

// ---------------------------------------------------------------- R0: заявки на возврат не сделаны (V11)

test('V11: 1С не принимает заявки на возврат (Q-018) — платформа 404 на /returns — R0, R1 МЕТОДА НЕТ, не ОШИБКА, код 0', async () => {
  const r = await runWith({
    id: 'V11',
    before: (c) => ((is(c, 'POST', RET) || is(c, 'GET', RET_ST))
      ? { status: 404, headers: { 'content-type': 'text/html; charset=utf-8' }, body: Buffer.from('<html><body>404 Not Found</body></html>') } : null),
  }, { qr: false });
  for (const id of ['R0', 'R1']) assert.equal(check(r.p, id).verdict, 'ABSENT', `${id}: ${checkTexts(check(r.p, id))}`);
  assert.match(check(r.p, 'R0').summary, /МЕТОДА НЕТ — заявки на возврат .*обязательны, если 1С принимает заявки на возврат извне .*Q-018, вопрос 77.*сообщите/);
  noFail(r);
});
