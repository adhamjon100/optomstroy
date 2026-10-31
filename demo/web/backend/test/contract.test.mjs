// WP-T1: самопроверка валидатора контракта (test/contract/openapi-validate.mjs). Синтетические схемы — для
// oneOf/anyOf/discriminator/additionalProperties/maxLength/minItems/строгого режима; настоящий pos-api.v1.yaml —
// для сопоставления путей, Problem, кодов и статусов по contracts/enums.json, PDF и пустых тел.
//   node --test demo/web/backend/test/contract.test.mjs
import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import { Contract, contract } from './contract/openapi-validate.mjs';

const doc = {
  openapi: '3.0.3',
  paths: {
    '/things/{id}': { get: { operationId: 'thing_get', responses: { 200: { content: { 'application/json': { schema: { $ref: '#/components/schemas/Thing' } } } } } } },
  },
  components: {
    schemas: {
      Money: { type: 'object', required: ['amount', 'currency'], properties: { amount: { type: 'string', pattern: '^-?\\d{1,12}\\.\\d{2}$' }, currency: { type: 'string', enum: ['KGS'] } } },
      Base: { type: 'object', required: ['id'], properties: { id: { type: 'string', format: 'uuid' }, note: { type: 'string', maxLength: 5, nullable: true } } },
      Thing: { allOf: [{ $ref: '#/components/schemas/Base' }, { type: 'object', properties: { price: { $ref: '#/components/schemas/Money' }, tags: { type: 'array', minItems: 1, maxItems: 2, items: { type: 'string', minLength: 2 } } } }] },
      Cat: { type: 'object', required: ['kind', 'meow'], properties: { kind: { type: 'string', enum: ['cat'] }, meow: { type: 'boolean' } } },
      Dog: { type: 'object', required: ['kind', 'bark'], properties: { kind: { type: 'string', enum: ['dog'] }, bark: { type: 'integer', minimum: 0, maximum: 3 } } },
      Pet: { oneOf: [{ $ref: '#/components/schemas/Cat' }, { $ref: '#/components/schemas/Dog' }], discriminator: { propertyName: 'kind', mapping: { cat: '#/components/schemas/Cat', dog: '#/components/schemas/Dog' } } },
      PetNoDisc: { oneOf: [{ $ref: '#/components/schemas/Cat' }, { $ref: '#/components/schemas/Dog' }] },
      Loose: { type: 'object', properties: { a: { type: 'integer' } }, additionalProperties: true },
      Closed: { type: 'object', properties: { a: { type: 'integer' } }, additionalProperties: false },
      MapOfMoney: { type: 'object', additionalProperties: { $ref: '#/components/schemas/Money' } },
      StrOrNum: { anyOf: [{ type: 'string', maxLength: 3 }, { type: 'number' }] },
      WithBranch: { allOf: [{ type: 'object', required: ['t'], properties: { t: { type: 'string' } } }, { oneOf: [{ type: 'object', properties: { t: { type: 'string', enum: ['x'] }, x: { type: 'integer' } } }, { type: 'object', properties: { t: { type: 'string', enum: ['y'] }, y: { type: 'string' } } }] }] },
    },
  },
};
const C = new Contract({ doc, enums: { problemCodes: [] } });
const ok = (schema, v, o) => assert.deepEqual(C.validate(schema, v, o), []);
const bad = (schema, v, re, o) => {
  const e = C.validate(schema, v, o);
  assert.ok(e.length > 0, `ожидалась ошибка для ${JSON.stringify(v)}`);
  if (re) assert.ok(e.some((x) => re.test(x)), `нет ошибки ${re}: ${e.join(' | ')}`);
};
const id = '0190f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55';

describe('валидатор: синтетические схемы', () => {
  test('$ref + allOf + строгий режим: лишнее поле — ошибка, без strict — нет', () => {
    ok('Thing', { id, price: { amount: '10.00', currency: 'KGS' }, tags: ['ab'] });
    bad('Thing', { id, extra: 1 }, /поле вне схемы/);
    ok('Thing', { id, extra: 1 }, { strict: false });
    bad('Thing', { note: 'x' }, /id: обязательное поле/);
  });
  test('nullable, maxLength, pattern, format uuid, enum', () => {
    ok('Thing', { id, note: null });
    bad('Thing', { id, note: 'слишком' }, /maxLength 5/);
    bad('Thing', { id: 'not-a-uuid' }, /не uuid/);
    bad('Money', { amount: '10.5', currency: 'KGS' }, /pattern/);
    bad('Money', { amount: '10.50', currency: 'USD' }, /вне enum/);
  });
  test('minItems / maxItems / minLength элементов', () => {
    bad('Thing', { id, tags: [] }, /minItems 1/);
    bad('Thing', { id, tags: ['ab', 'cd', 'ef'] }, /maxItems 2/);
    bad('Thing', { id, tags: ['a'] }, /minLength 2/);
  });
  test('oneOf с discriminator: ветвь по mapping, неизвестное значение, нет поля', () => {
    ok('Pet', { kind: 'cat', meow: true });
    ok('Pet', { kind: 'dog', bark: 2 });
    bad('Pet', { kind: 'dog', bark: 9 }, /maximum 3/);
    bad('Pet', { kind: 'fish' }, /не сопоставлено/);
    bad('Pet', { meow: true }, /нет поля discriminator/);
  });
  test('oneOf без discriminator: ровно одна ветвь', () => {
    ok('PetNoDisc', { kind: 'cat', meow: false });
    bad('PetNoDisc', { kind: 'cow' }, /ни одна ветвь oneOf/);
  });
  test('anyOf: хотя бы одна ветвь', () => {
    ok('StrOrNum', 'abc');
    ok('StrOrNum', 12.5);
    bad('StrOrNum', 'abcd', /anyOf/);
    bad('StrOrNum', true, /anyOf/);
  });
  test('additionalProperties: true / false / схема', () => {
    ok('Loose', { a: 1, b: 'x' });
    bad('Closed', { a: 1, b: 'x' }, /additionalProperties: false/);
    ok('MapOfMoney', { cash: { amount: '1.00', currency: 'KGS' } });
    bad('MapOfMoney', { cash: { amount: '1', currency: 'KGS' } }, /pattern/);
  });
  test('oneOf внутри allOf: свойства ветвей не считаются «лишними» снаружи', () => {
    ok('WithBranch', { t: 'x', x: 1 });
    ok('WithBranch', { t: 'y', y: 'z' });
    bad('WithBranch', { t: 'x', x: 'строка' }, /oneOf/);
  });
  test('типы: integer / number / boolean / string / object / array', () => {
    bad({ type: 'integer' }, 1.5, /integer/);
    bad({ type: 'number' }, '1', /number/);
    bad({ type: 'boolean' }, 'true', /boolean/);
    bad({ type: 'string' }, 1, /строка/);
    bad({ type: 'object', properties: {} }, [], /объект/);
    bad({ type: 'array', items: { type: 'string' } }, {}, /массив/);
    bad({ type: 'string', format: 'date-time' }, '2026-10-30 12:00', /date-time/);
    ok({ type: 'string', format: 'date-time' }, '2026-10-30T12:00:00.123Z');
    ok({ type: 'string', format: 'date' }, '2026-10-30');
  });
  test('сопоставление пути: литеральный сегмент важнее параметра', () => {
    assert.equal(C.matchOperation('GET', '/api/v1/things/abc?x=1')?.operationId, 'thing_get');
    assert.equal(C.matchOperation('POST', '/api/v1/things/abc'), null);
  });
});

describe('валидатор: настоящий контракт pos-api.v1.yaml', () => {
  const R = contract();
  const problem = (status, code, extra = {}) => ({ type: `https://api.example/problems/${code.toLowerCase()}`, title: 't', status, code, requestId: 'r', ...extra });
  test('операции: 141, пути с литералами и параметрами', () => {
    assert.equal(R.ops.length, 141);
    assert.equal(R.matchOperation('GET', '/api/v1/catalog/products/recent').operationId, 'catalog_products_recent_list');
    assert.equal(R.matchOperation('GET', `/api/v1/catalog/products/${id}`).operationId, 'catalog_products_get');
    assert.equal(R.matchOperation('GET', '/health').operationId, 'health_liveness_get');
    assert.equal(R.matchOperation('GET', `/api/v1/orders/${id}/documents/invoice.pdf?format=a4`).operationId, 'orders_document_invoice');
    assert.equal(R.matchOperation('DELETE', '/api/v1/cart?rowVersion=3').operationId, 'cart_clear');
  });
  test('4xx/5xx: Problem, code ∈ ProblemCode, статус по enums.json, status = HTTP', () => {
    const h = { 'content-type': 'application/problem+json; charset=utf-8' };
    assert.deepEqual(R.checkResponse({ method: 'GET', url: `/api/v1/orders/${id}`, status: 404, headers: h, json: problem(404, 'NOT_FOUND'), size: 1 }).errors, []);
    assert.ok(R.checkResponse({ method: 'GET', url: `/api/v1/orders/${id}`, status: 409, headers: h, json: problem(409, 'NOT_FOUND'), size: 1 }).errors.some((e) => /enums\.json/.test(e)));
    assert.ok(R.checkResponse({ method: 'GET', url: `/api/v1/orders/${id}`, status: 404, headers: h, json: problem(404, 'NO_SUCH_CODE'), size: 1 }).errors.some((e) => /вне enum|problemCodes/.test(e)));
    assert.ok(R.checkResponse({ method: 'GET', url: `/api/v1/orders/${id}`, status: 404, headers: { 'content-type': 'application/json' }, json: problem(404, 'NOT_FOUND'), size: 1 }).errors.some((e) => /problem\+json/.test(e)));
    assert.ok(R.checkResponse({ method: 'GET', url: `/api/v1/orders/${id}`, status: 404, headers: h, json: problem(400, 'NOT_FOUND'), size: 1 }).errors.some((e) => /≠ HTTP/.test(e)));
    assert.ok(R.checkResponse({ method: 'GET', url: `/api/v1/orders/${id}`, status: 404, headers: h, json: { code: 'NOT_FOUND' }, size: 1 }).errors.some((e) => /обязательное поле/.test(e)));
  });
  test('PDF: application/pdf и %PDF; 204 — пустое тело', () => {
    const url = `/api/v1/orders/${id}/documents/receipt.pdf`;
    assert.deepEqual(R.checkResponse({ method: 'GET', url, status: 200, headers: { 'content-type': 'application/pdf' }, magic: '%PDF-', size: 100 }).errors, []);
    assert.ok(R.checkResponse({ method: 'GET', url, status: 200, headers: { 'content-type': 'application/pdf' }, magic: 'GIF89', size: 100 }).errors.length > 0);
    assert.ok(R.checkResponse({ method: 'GET', url, status: 200, headers: { 'content-type': 'application/json' }, json: {}, size: 2 }).errors.length > 0);
    assert.deepEqual(R.checkResponse({ method: 'DELETE', url: `/api/v1/favorites/products/${id}`, status: 204, headers: {}, size: 0 }).errors, []);
    assert.ok(R.checkResponse({ method: 'DELETE', url: `/api/v1/favorites/products/${id}`, status: 204, headers: {}, size: 3 }).errors.length > 0);
  });
  test('2xx JSON: строгая проверка схемы операции (лишнее поле, неверный тип)', () => {
    const url = '/health';
    const h = { 'content-type': 'application/json; charset=utf-8' };
    const good = { status: 'ok', apiVersion: '1.0', serverTime: '2026-10-30T00:00:00.000Z' };
    assert.deepEqual(R.checkResponse({ method: 'GET', url, status: 200, headers: h, json: good, size: 30 }).errors, []);
    assert.ok(R.checkResponse({ method: 'GET', url, status: 200, headers: h, json: { ...good, unexpectedField: 1 }, size: 30 }).errors.some((e) => /unexpectedField: поле вне схемы/.test(e)));
    assert.ok(R.checkResponse({ method: 'GET', url, status: 200, headers: h, json: { status: 'ok', apiVersion: '1.0' }, size: 30 }).errors.some((e) => /serverTime: обязательное/.test(e)));
    assert.ok(R.checkResponse({ method: 'GET', url, status: 200, headers: h, json: { ...good, status: 'down' }, size: 30 }).errors.some((e) => /вне enum/.test(e)));
  });
});
