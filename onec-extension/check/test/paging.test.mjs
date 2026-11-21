// Постраничное чтение (src/paging.mjs): предохранители и находки по-русски.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readPages } from '../src/paging.mjs';

/** pagesList: массив ответов {status?, body} по номеру страницы (курсор — номер следующей страницы). */
async function read(pagesList, opts = {}) {
  const found = [];
  const res = await readPages({
    maxPages: opts.maxPages || 50, limit: opts.limit || 3, hardMax: opts.hardMax ?? null, sameMessage: opts.sameMessage ?? true,
    keyOf: (i) => (i && i.k) || null,
    report: (f) => found.push(f),
    fetchPage: async (cursor) => {
      const i = cursor ? Number(cursor) : 0;
      const p = pagesList[Math.min(i, pagesList.length - 1)];
      if (p.error) return { ex: { error: new Error('сбой'), status: null }, body: null };
      return { ex: { status: p.status ?? 200, ms: 1 }, body: p.body };
    },
  });
  return { res, found, text: found.map((f) => `${f.severity} ${f.text}`).join('\n') };
}

const pg = (n, items, more, cursor, extra = {}) => ({ body: { messageNumber: n, items, hasMore: more, cursor, ...extra } });

test('обычное чтение двух страниц: без находок, complete, счёт элементов', async () => {
  const { res, found } = await read([pg(7, [{ k: 'a' }, { k: 'b' }], true, '1'), pg(7, [{ k: 'c' }], false, null)]);
  assert.deepEqual(found, []);
  assert.equal(res.pages, 2);
  assert.equal(res.items, 3);
  assert.equal(res.messageNumber, 7);
  assert.equal(res.complete, true);
});

test('три пустые страницы подряд с hasMore=true — ОШИБКА и остановка', async () => {
  const list = Array.from({ length: 10 }, (_, i) => pg(1, [], true, String(i + 1)));
  const { res, text } = await read(list);
  assert.match(text, /FAIL 3 пустые страницы подряд с hasMore=true — чтение остановлено/);
  assert.equal(res.stoppedBy, 'emptyPages');
  assert.equal(res.pages, 3);
});

test('hasMore не true/false — ОШИБКА', async () => {
  const { text } = await read([pg(1, [{ k: 'a' }], 'false', null)]);
  assert.match(text, /hasMore должно быть true или false/);
});

test('больше 5000 элементов на странице и больше limit — две ОШИБКИ', async () => {
  const items = Array.from({ length: 5001 }, (_, i) => ({ k: 'x' + i }));
  const { text } = await read([pg(1, items, false, null)], { limit: 1000, hardMax: 5000 });
  assert.match(text, /5001 элементов — больше limit=1000/);
  assert.match(text, /5001 элементов — больше 5000/);
});

test('ответ 200 без JSON-объекта — ОШИБКА «не JSON-объект», чтение остановлено', async () => {
  const { res, text } = await read([{ status: 200, body: undefined }]);
  assert.match(text, /страница 1: ответ 200 не JSON-объект — чтение остановлено/);
  assert.equal(res.complete, false);
});

test('статус не 200 или сбой связи — остановка без своей находки (её пишет вызывающая проверка)', async () => {
  const a = await read([{ status: 500, body: { code: 'POS_E_INTERNAL' } }]);
  assert.deepEqual(a.found, []);
  assert.equal(a.res.stoppedBy, 'error');
  const b = await read([{ error: true }]);
  assert.deepEqual(b.found, []);
  assert.equal(b.res.stoppedBy, 'error');
});

test('нет списка items — ОШИБКА', async () => {
  const { text, res } = await read([{ body: { messageNumber: 1, hasMore: false, cursor: null } }]);
  assert.match(text, /нет списка items/);
  assert.equal(res.stoppedBy, 'shape');
});

test('повторы элементов: первые 5 подробно, остальные — одной строкой', async () => {
  const p1 = Array.from({ length: 8 }, (_, i) => ({ k: 'd' + i }));
  const { found } = await read([pg(1, p1, true, '1'), pg(1, p1, false, null)], { limit: 10 });
  const dups = found.filter((f) => f.code === 'dup-item');
  assert.equal(dups.length, 5);
  assert.match(dups[0].text, /элемент повторяется на страницах 1 и 2 \(d0\)/);
  assert.match(found.find((f) => f.code === 'dup-item-more').text, /ещё 3 повторов/);
});

test('один и тот же элемент дважды на одной странице — не «повтор на страницах»', async () => {
  const { found } = await read([pg(1, [{ k: 'a' }, { k: 'a' }], false, null)]);
  assert.deepEqual(found.filter((f) => f.code === 'dup-item'), []);
});

test('предел страниц — ЗАМЕЧАНИЕ, не ОШИБКА', async () => {
  const list = Array.from({ length: 30 }, (_, i) => pg(1, [{ k: 'm' + i }], true, String(i + 1)));
  const { found, res } = await read(list, { maxPages: 4 });
  assert.equal(found.length, 1);
  assert.equal(found[0].severity, 'WARN');
  assert.match(found[0].text, /по пределу: 4 страниц/);
  assert.equal(res.stoppedBy, 'maxPages');
});

test('sameMessage=false (сверка /external-ids): номер сообщения не сравнивается', async () => {
  const { found } = await read([{ body: { items: [{ k: 'a' }], hasMore: true, cursor: '1' } }, { body: { items: [{ k: 'b' }], hasMore: false, cursor: null } }], { sameMessage: false });
  assert.deepEqual(found, []);
});
