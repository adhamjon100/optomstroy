// fix2: повтор GET при временной ошибке, как у POS (контракт 1.2.0, info.x-get-retry: до 3 попыток, паузы 0,5 и 1 с):
// одна 503 POS_E_LOCKED на первом /changes — не ОШИБКА (G18); ответ только с 3-й попытки — ЗАМЕЧАНИЕ; три временные
// ошибки подряд — ОШИБКА проверки; запросы, где ошибка ожидается нарочно (C5, K9, I3), не повторяются.
// Фасад test/helpers/front-1c.mjs, данные вымышленные.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { posError } from './helpers/front-1c.mjs';
import { frontWithSecrets, makeConfig, runMain, readProtocol, check, checkTexts, tmpDir, secretForms, leaks } from './helpers/env.mjs';

const dirs = [];
const fronts = [];
after(async () => { for (const f of fronts) await f.close(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

async function runWith(defect, args = []) {
  const { front, password, clientKey } = await frontWithSecrets({ defect });
  fronts.push(front);
  const dir = tmpDir(`oc-fix2-${defect.id}-`);
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
  // --timeout-scale 0.2: паузы повтора 0,1 и 0,2 с вместо 0,5 и 1 с (таймауты методов — 6 с и больше).
  const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', '--timeout-scale', '0.2', ...args]);
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.ok(p, `нет протокола: ${r.out.slice(-1200)}`);
  assert.deepEqual(leaks([r.out, ...p.texts], secretForms(password, clientKey)), []);
  return { ...r, p, journal: front.journal };
}

const isChanges = (c) => c.method === 'GET' && c.sub === '/pos/v1/changes';
const isXid = (c) => c.method === 'GET' && c.sub === '/pos/v1/external-ids';

test('G18: одна 503 POS_E_LOCKED на первом GET /changes — повтор, C1 ПРОЙДЕНО, код 0; в протоколе — СВЕДЕНИЯ о повторе', async () => {
  const r = await runWith({
    id: 'G18',
    before: (c) => {
      if (!isChanges(c) || !c.key || c.state.locked18) return null;
      c.state.locked18 = true;
      return posError(503, 'POS_E_LOCKED', 'База заблокирована другим сеансом, повторите позже', c.reqId);
    },
  });
  assert.equal(r.code, 0, r.out.slice(-1500));
  const c1 = check(r.p, 'C1');
  assert.equal(c1.verdict, 'PASS', checkTexts(c1));
  assert.ok(c1.findings.some((f) => f.severity === 'INFO' && /временная ошибка \(503 POS_E_LOCKED\) — ответ получен с 2-й попытки/.test(f.text)), checkTexts(c1));
  assert.ok(c1.requests.some((q) => q.status === 503) && c1.requests.some((q) => /повтор 2 из 3/.test(q.label || '')), JSON.stringify(c1.requests));
  assert.equal(check(r.p, 'E7').verdict !== 'FAIL', true);
});

test('ответ только с 3-й попытки — ЗАМЕЧАНИЕ (у POS запаса нет); три временные ошибки — ОШИБКА; C5 не повторяется', async () => {
  let n = 0;
  const r = await runWith({
    id: 'RETRY',
    before: (c) => {
      // X2 (/external-ids без since и type): первые две попытки — 503 POS_E_LOCKED и 500 HTML-страница, третья — ответ.
      if (isXid(c) && c.key && !c.query.get('type') && !c.query.get('since') && n < 2) {
        n++;
        return n === 1 ? posError(503, 'POS_E_LOCKED', 'Регистр заблокирован, повторите позже', c.reqId)
          : { status: 500, headers: { 'content-type': 'text/html' }, body: Buffer.from('<html><head><title>500</title></head></html>') };
      }
      // /external-ids с type — всегда 503 POS_E_LOCKED.
      if (isXid(c) && c.key && c.query.get('type')) return posError(503, 'POS_E_LOCKED', 'Регистр заблокирован, повторите позже', c.reqId);
      // C5: неверный since → 503 вместо 400 — ошибка ожидается нарочно, повтора быть не должно.
      if (isChanges(c) && c.key && c.query.get('limit') === '1') return posError(503, 'POS_E_LOCKED', 'База заблокирована, повторите позже', c.reqId);
      return null;
    },
  });
  assert.equal(r.code, 1, r.out.slice(-1500));
  const x2 = check(r.p, 'X2');
  assert.equal(x2.verdict, 'WARN', checkTexts(x2));
  assert.match(checkTexts(x2), /ответ получен только с последней, 3-й попытки \(до этого: 503 POS_E_LOCKED; 500\)/);
  const x3 = check(r.p, 'X3');
  assert.equal(x3.verdict, 'FAIL', checkTexts(x3));
  assert.match(checkTexts(x3), /временная ошибка во всех 3 попытках/);
  // C5: каждый неверный since — ровно один запрос. Верный since (= lastAck, как у C1) с limit=1 шлёт A6 — без ключа и с
  // неверным ключом (раунд fixo1), это не C5.
  const valid = new URLSearchParams(r.journal.find((j) => j.method === 'GET' && j.path === '/pos/v1/changes' && !/limit=1(&|$)/.test(j.query)).query).get('since');
  const c5 = r.journal.filter((j) => j.method === 'GET' && j.path === '/pos/v1/changes' && /limit=1(&|$)/.test(j.query) && new URLSearchParams(j.query).get('since') !== valid);
  const bySince = {};
  for (const j of c5) { const s = new URLSearchParams(j.query).get('since'); bySince[s] = (bySince[s] || 0) + 1; }
  assert.ok(Object.keys(bySince).length >= 1, JSON.stringify(c5));
  for (const [s, k] of Object.entries(bySince)) assert.equal(k, 1, `since=${s}: запросов ${k}`);
  assert.equal(check(r.p, 'C5').verdict, 'FAIL');
});
