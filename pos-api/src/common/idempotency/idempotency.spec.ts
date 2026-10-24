import { Body, Controller, HttpCode, Param, Post, Put, Req } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import request from 'supertest';
import { createTestApp } from '../../../test/support/test-app.js';
import { ProblemException } from '../problem-details/problem.exception.js';
import { RequirePermission } from '../rbac/rbac.decorators.js';
import { canonicalJson, requestFingerprint } from './fingerprint.js';
import { markIdempotencyCommitted } from './idempotency.context.js';
import { InMemoryIdempotencyStore } from './idempotency.memory-store.js';
import { PgIdempotencyStore } from './idempotency.repository.js';
import { IdempotencyService } from './idempotency.service.js';
import { IDEMPOTENCY_ACQUIRE_MAX_ATTEMPTS, IDEMPOTENCY_TTL_MS, type IdempotencyScope } from './idempotency.store.js';
import { Idempotent } from './idempotent.decorator.js';

const KEY = '3b241101-e2bb-4255-8caf-4136c566a962';
const USER = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55';
const scope: IdempotencyScope = { key: KEY, subjectKey: `user:${USER}`, userId: USER, route: 'POST /orders' };

describe('IdempotencyService (логика 08 §2.7)', () => {
  let now: number;
  let store: InMemoryIdempotencyStore;
  let service: IdempotencyService;
  const hashA = requestFingerprint({}, { items: [1, 2] });
  const hashB = requestFingerprint({}, { items: [2, 1] });

  beforeEach(() => {
    now = 1_000_000;
    store = new InMemoryIdempotencyStore(() => now);
    service = new IdempotencyService(store);
  });

  it('новый ключ → proceed; повтор во время выполнения → 409 IDEMPOTENCY_IN_PROGRESS c Retry-After 2', async () => {
    expect(await service.begin(scope, hashA)).toEqual({ kind: 'proceed' });
    const err = await service.begin(scope, hashA).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ProblemException);
    expect((err as ProblemException).code).toBe('IDEMPOTENCY_IN_PROGRESS');
    expect((err as ProblemException).getStatus()).toBe(409);
    expect((err as ProblemException).headers['Retry-After']).toBe('2');
  });

  it('completed → повтор того же статуса и тела; другой отпечаток → 422 IDEMPOTENCY_KEY_REUSED', async () => {
    await service.begin(scope, hashA);
    await service.complete(scope, 201, { id: 'o1', total: { amount: '10.00', currency: 'KGS' } });
    expect(await service.begin(scope, hashA)).toEqual({
      kind: 'replay',
      status: 201,
      body: { id: 'o1', total: { amount: '10.00', currency: 'KGS' } },
    });
    const err = (await service.begin(scope, hashB).catch((e: unknown) => e)) as ProblemException;
    expect(err.code).toBe('IDEMPOTENCY_KEY_REUSED');
    expect(err.getStatus()).toBe(422);
  });

  it('скоуп (key, subject, route): другой пользователь или маршрут не конфликтует', async () => {
    await service.begin(scope, hashA);
    expect(await service.begin({ ...scope, subjectKey: 'user:other', userId: 'other' }, hashB)).toEqual({
      kind: 'proceed',
    });
    expect(await service.begin({ ...scope, route: 'POST /payments' }, hashB)).toEqual({ kind: 'proceed' });
  });

  it('ключ старше 24 ч обрабатывается как новый; release освобождает захват', async () => {
    await service.begin(scope, hashA);
    await service.complete(scope, 201, { id: 'o1' });
    now += IDEMPOTENCY_TTL_MS + 1;
    expect(await service.begin(scope, hashB)).toEqual({ kind: 'proceed' });
    await service.release(scope);
    expect(await service.begin(scope, hashA)).toEqual({ kind: 'proceed' });
    now += IDEMPOTENCY_TTL_MS + 1;
    expect(await store.purgeExpired()).toBe(1);
  });

  it('отпечаток не зависит от порядка полей, но зависит от path-параметров и значений', () => {
    expect(canonicalJson({ b: 1, a: { d: [1, { y: 2, x: 1 }], c: undefined } })).toBe(
      '{"a":{"d":[1,{"x":1,"y":2}]},"b":1}',
    );
    expect(
      requestFingerprint({ id: '1' }, { a: 1, b: 2 }).equals(requestFingerprint({ id: '1' }, { b: 2, a: 1 })),
    ).toBe(true);
    expect(requestFingerprint({ id: '1' }, { a: 1 }).equals(requestFingerprint({ id: '2' }, { a: 1 }))).toBe(false);
  });
});

describe('PgIdempotencyStore.acquire (C-MN-08)', () => {
  it('гонка «строка исчезла между INSERT и SELECT» повторяется ограниченное число раз', async () => {
    let inserts = 0;
    const db = {
      query: (sql: string) => {
        if (sql.trimStart().startsWith('INSERT')) inserts++;
        return Promise.resolve({ rowCount: 0, rows: [] });
      },
    };
    const pgStore = new PgIdempotencyStore(db as never);
    await expect(pgStore.acquire(scope, Buffer.from('h'), 1000)).rejects.toThrow(/исчезала/);
    expect(inserts).toBe(IDEMPOTENCY_ACQUIRE_MAX_ATTEMPTS);
  });
});

let counter = 0;
const httpStore = new InMemoryIdempotencyStore();
/** Транзакция бизнес-операции для recordInTransaction (имитация клиента pg в транзакции). */
const fakeTx = { query: () => Promise.resolve({ rowCount: 1 }) };

@Controller()
class OrdersProbeController {
  constructor(private readonly idempotency: IdempotencyService) {}

  @RequirePermission('order.create')
  @Idempotent({ required: true })
  @Post('orders')
  create(@Body() body: { fail?: string }): { id: number } {
    counter++;
    if (body.fail === 'business') throw new ProblemException('CART_EMPTY');
    if (body.fail === 'crash') throw new Error('boom');
    return { id: counter };
  }

  /** Денежная операция: COMMIT выполнен, затем сбой (например, при построении ответа). */
  @RequirePermission('order.create')
  @Idempotent({ required: true })
  @Post('orders/:id/payments')
  pay(@Req() req: object, @Body() body: { fail?: string }): { n: number } {
    counter++;
    markIdempotencyCommitted(req);
    if (body.fail === 'after-commit') throw new Error('boom after commit');
    return { n: counter };
  }

  /** Итог записан в транзакции бизнес-операции (B-AR-04). */
  @RequirePermission('order.create')
  @Idempotent({ required: true })
  @Post('orders/:id/void')
  async void(@Req() req: object): Promise<{ n: number }> {
    counter++;
    const result = { n: counter };
    await this.idempotency.recordInTransaction(fakeTx, req, 201, result);
    return result;
  }

  @RequirePermission('cart.manage.own')
  @Idempotent({
    required: false,
    requiredWhen: (req) => (req.body as { mode?: string } | undefined)?.mode === 'increment',
  })
  @Put('cart/items/:variantId')
  @HttpCode(200)
  put(@Param('variantId') variantId: string): { variantId: string; n: number } {
    counter++;
    return { variantId, n: counter };
  }
}

describe('IdempotencyInterceptor (HTTP)', () => {
  let app: NestExpressApplication;
  const principal = { userId: USER, kind: 'staff' as const, roles: ['seller'] };

  beforeAll(async () => {
    app = await createTestApp({ controllers: [OrdersProbeController], principal, idempotencyStore: httpStore });
  });

  afterAll(async () => {
    await app.close();
  });

  beforeEach(() => {
    counter = 0;
    httpStore.failNextCompletes = 0;
  });

  it('обязательный ключ: отсутствие → 400 idempotency_key_required; не UUID v4 → 400 idempotency_key_format', async () => {
    const a = await request(app.getHttpServer()).post('/api/v1/orders').send({});
    expect(a.status).toBe(400);
    expect(a.body.errors[0].rule).toBe('idempotency_key_required');
    const b = await request(app.getHttpServer()).post('/api/v1/orders').set('Idempotency-Key', 'abc').send({});
    expect(b.body.errors[0].rule).toBe('idempotency_key_format');
    expect(counter).toBe(0);
  });

  it('повтор с тем же ключом → тот же ответ + Idempotent-Replayed: true, обработчик не вызывается второй раз', async () => {
    const key = '6f1c2d4e-8a9b-4c3d-9e1f-0a1b2c3d4e5f';
    const first = await request(app.getHttpServer()).post('/api/v1/orders').set('Idempotency-Key', key).send({ x: 1 });
    expect(first.status).toBe(201);
    const second = await request(app.getHttpServer()).post('/api/v1/orders').set('Idempotency-Key', key).send({ x: 1 });
    expect(second.status).toBe(201);
    expect(second.headers['idempotent-replayed']).toBe('true');
    expect(second.body).toEqual(first.body);
    expect(counter).toBe(1);
    const reused = await request(app.getHttpServer()).post('/api/v1/orders').set('Idempotency-Key', key).send({ x: 2 });
    expect(reused.status).toBe(422);
    expect(reused.body.code).toBe('IDEMPOTENCY_KEY_REUSED');
  });

  it('бизнес-ошибка 4xx сохраняется и повторяется; 5xx освобождает ключ', async () => {
    const k1 = '11111111-2222-4333-8444-555555555555';
    const e1 = await request(app.getHttpServer())
      .post('/api/v1/orders')
      .set('Idempotency-Key', k1)
      .send({ fail: 'business' });
    expect(e1.status).toBe(422);
    const e2 = await request(app.getHttpServer())
      .post('/api/v1/orders')
      .set('Idempotency-Key', k1)
      .send({ fail: 'business' });
    expect(e2.status).toBe(422);
    expect(e2.headers['idempotent-replayed']).toBe('true');
    expect(e2.headers['content-type']).toMatch(/problem\+json/);
    expect(e2.body.code).toBe('CART_EMPTY');
    expect(counter).toBe(1);

    const k2 = '11111111-2222-4333-8444-666666666666';
    expect(
      (await request(app.getHttpServer()).post('/api/v1/orders').set('Idempotency-Key', k2).send({ fail: 'crash' }))
        .status,
    ).toBe(500);
    expect(
      (await request(app.getHttpServer()).post('/api/v1/orders').set('Idempotency-Key', k2).send({ fail: 'crash' }))
        .status,
    ).toBe(500);
    expect(counter).toBe(3); // 1 бизнес-ошибка (повтор из хранилища) + 2 выполнения после 5xx
  });

  it('C-CR-02: complete падает после успешного обработчика → ключ не освобождён, повтор не выполняет операцию', async () => {
    const key = '22222222-3333-4444-8555-666666666666';
    const keyScope: IdempotencyScope = { key, subjectKey: `user:${USER}`, userId: USER, route: 'POST /orders' };
    httpStore.failNextCompletes = 3; // все попытки записи итога падают (сбой БД/пула после COMMIT)
    const first = await request(app.getHttpServer()).post('/api/v1/orders').set('Idempotency-Key', key).send({ x: 1 });
    expect(first.status).toBe(201); // клиент получает настоящий результат операции
    expect(httpStore.statusOf(keyScope)).toBe('in_progress'); // не release
    const retry = await request(app.getHttpServer()).post('/api/v1/orders').set('Idempotency-Key', key).send({ x: 1 });
    expect(retry.status).toBe(409);
    expect(retry.body.code).toBe('IDEMPOTENCY_IN_PROGRESS');
    expect(counter).toBe(1); // операция выполнена ровно один раз
  });

  it('C-CR-02: сбой записи итога со второй попытки — итог сохранён, повтор отдаёт сохранённый ответ', async () => {
    const key = '22222222-3333-4444-8555-777777777777';
    httpStore.failNextCompletes = 1;
    const first = await request(app.getHttpServer()).post('/api/v1/orders').set('Idempotency-Key', key).send({ x: 2 });
    expect(first.status).toBe(201);
    const retry = await request(app.getHttpServer()).post('/api/v1/orders').set('Idempotency-Key', key).send({ x: 2 });
    expect(retry.status).toBe(201);
    expect(retry.headers['idempotent-replayed']).toBe('true');
    expect(counter).toBe(1);
  });

  it('C-CR-02: 5xx после markIdempotencyCommitted → ключ не освобождён (повтор → 409, без второго платежа)', async () => {
    const key = '22222222-3333-4444-8555-888888888888';
    const path = `/api/v1/orders/${USER}/payments`;
    const first = await request(app.getHttpServer())
      .post(path)
      .set('Idempotency-Key', key)
      .send({ fail: 'after-commit' });
    expect(first.status).toBe(500);
    const retry = await request(app.getHttpServer())
      .post(path)
      .set('Idempotency-Key', key)
      .send({ fail: 'after-commit' });
    expect(retry.status).toBe(409);
    expect(retry.body.code).toBe('IDEMPOTENCY_IN_PROGRESS');
    expect(counter).toBe(1);
  });

  it('B-AR-04: итог, записанный в транзакции бизнес-операции, перехватчик не перезаписывает и повторяет', async () => {
    const key = '22222222-3333-4444-8555-999999999999';
    const path = `/api/v1/orders/${USER}/void`;
    const before = httpStore.completeCalls;
    const first = await request(app.getHttpServer()).post(path).set('Idempotency-Key', key).send({});
    expect(first.status).toBe(201);
    expect(httpStore.completeCalls - before).toBe(1); // только запись в транзакции, без второй команды
    expect(httpStore.lastExecutor).toBe(fakeTx);
    const retry = await request(app.getHttpServer()).post(path).set('Idempotency-Key', key).send({});
    expect(retry.status).toBe(201);
    expect(retry.headers['idempotent-replayed']).toBe('true');
    expect(retry.body).toEqual(first.body);
    expect(counter).toBe(1);
  });

  it('PUT /cart/items/{variantId}: ключ обязателен только при mode=increment; path-параметр входит в отпечаток', async () => {
    const http = request(app.getHttpServer());
    expect((await http.put('/api/v1/cart/items/v1').send({ mode: 'set' })).status).toBe(200);
    const missing = await http.put('/api/v1/cart/items/v1').send({ mode: 'increment' });
    expect(missing.status).toBe(400);
    const key = '7a7a7a7a-1b1b-4c4c-8d8d-9e9e9e9e9e9e';
    expect(
      (await http.put('/api/v1/cart/items/v1').set('Idempotency-Key', key).send({ mode: 'increment' })).status,
    ).toBe(200);
    const other = await http.put('/api/v1/cart/items/v2').set('Idempotency-Key', key).send({ mode: 'increment' });
    // другой path-параметр — тот же шаблон маршрута, но другой отпечаток
    expect(other.status).toBe(422);
  });
});
