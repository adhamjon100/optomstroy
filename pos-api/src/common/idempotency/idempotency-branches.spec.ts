import { HTTP_CODE_METADATA } from '@nestjs/common/constants.js';
import { firstValueFrom, of, throwError } from 'rxjs';
import { ProblemException } from '../problem-details/problem.exception.js';
import { canonicalJson, requestFingerprint } from './fingerprint.js';
import { attachIdempotencyState, getIdempotencyState, markIdempotencyCommitted } from './idempotency.context.js';
import { IdempotencyInterceptor } from './idempotency.interceptor.js';
import { InMemoryIdempotencyStore } from './idempotency.memory-store.js';
import { PgIdempotencyStore } from './idempotency.repository.js';
import { IdempotencyService } from './idempotency.service.js';
import { IDEMPOTENCY_ACQUIRE_MAX_ATTEMPTS, type IdempotencyScope } from './idempotency.store.js';
import { IDEMPOTENT } from './idempotent.decorator.js';

/**
 * Ветви механизма `Idempotency-Key` (08 §2.7; 13 RM-F-009 «идемпотентность — 100 % веток»; ревью F-trace-2, FIX-F-23),
 * не задетые сценариями idempotency.spec и e2e: канонизация особых значений, контекст без состояния, интерсептор вне
 * HTTP / без метода / без субъекта, PUT без HttpCode, запрос без id, хранилища (память и PostgreSQL на фейке пула).
 */
const KEY = '3b241101-e2bb-4255-8caf-4136c566a962';
const USER = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55';
const scope: IdempotencyScope = { key: KEY, subjectKey: `user:${USER}`, userId: USER, route: 'POST /orders' };

describe('fingerprint: канонизация', () => {
  it('null/undefined, массив с undefined, Date, bigint, порядок ключей; отпечаток без параметров и тела', () => {
    expect(canonicalJson(null)).toBe('null');
    expect(canonicalJson(undefined)).toBe('null');
    expect(canonicalJson([1, undefined, 'a'])).toBe('[1,null,"a"]');
    expect(canonicalJson(new Date('2026-10-23T00:00:00Z'))).toBe('"2026-10-23T00:00:00.000Z"');
    expect(canonicalJson(10n)).toBe('"10"');
    expect(canonicalJson({ b: 1, a: 2, c: undefined })).toBe('{"a":2,"b":1}');
    expect(requestFingerprint(undefined, undefined).equals(requestFingerprint({}, null))).toBe(true);
  });
});

describe('контекст идемпотентности', () => {
  it('markIdempotencyCommitted без состояния — без ошибки; с состоянием — committed', () => {
    const req = {};
    markIdempotencyCommitted(req);
    expect(getIdempotencyState(req)).toBeUndefined();
    attachIdempotencyState(req, scope);
    markIdempotencyCommitted(req);
    expect(getIdempotencyState(req)?.committed).toBe(true);
  });
});

describe('IdempotencyService / хранилище в памяти: ветви', () => {
  it('завершённая запись без статуса ответа (3 попытки) → 409 IDEMPOTENCY_IN_PROGRESS', async () => {
    const hash = requestFingerprint({}, { a: 1 });
    const store = {
      acquire: () =>
        Promise.resolve({
          requestHash: hash,
          status: 'completed',
          responseStatus: null,
          responseBody: null,
          expiresAt: new Date(),
        }),
    };
    await expect(new IdempotencyService(store as never).begin(scope, hash)).rejects.toMatchObject({
      code: 'IDEMPOTENCY_IN_PROGRESS',
    });
  });

  it('recordInTransaction без состояния запроса — ничего не пишет', async () => {
    const store = new InMemoryIdempotencyStore();
    await new IdempotencyService(store).recordInTransaction({ query: () => Promise.resolve({}) }, {}, 200, {});
    expect(store.completeCalls).toBe(0);
  });

  it('память: complete без строки; тело undefined → null; release завершённой — без удаления; purge — только истёкшие', async () => {
    let now = 1_000;
    const store = new InMemoryIdempotencyStore(() => now);
    await store.complete(scope, 200, {});
    expect(store.size()).toBe(0);
    await store.acquire(scope, Buffer.from('h'), 10_000);
    await store.complete(scope, 200, undefined);
    expect((await store.acquire(scope, Buffer.from('h'), 10_000))?.responseBody).toBeNull();
    await store.release(scope);
    expect(store.statusOf(scope)).toBe('completed');
    expect(await store.purgeExpired()).toBe(0);
    now = 100_000;
    expect(await store.purgeExpired()).toBe(1);
  });
});

describe('PgIdempotencyStore (фейк пула): ветви', () => {
  const row = {
    request_hash: Buffer.from('h'),
    status: 'completed',
    response_status: 201,
    response_body: { a: 1 },
    expires_at: new Date(),
  };

  it('acquire: захват → null; существующая → запись; строка исчезает каждый раз → ошибка после N попыток', async () => {
    const calls: string[] = [];
    const db = (results: { rowCount: number | null; rows: unknown[] }[]): never =>
      ({
        query: (sql: string) => {
          calls.push(sql.trim().split(/\s+/)[0]);
          return Promise.resolve(results.shift() ?? { rowCount: 0, rows: [] });
        },
      }) as never;
    expect(
      await new PgIdempotencyStore(db([{ rowCount: 1, rows: [] }])).acquire(scope, Buffer.from('h'), 1000),
    ).toBeNull();
    expect(
      await new PgIdempotencyStore(
        db([
          { rowCount: 0, rows: [] },
          { rowCount: 1, rows: [row] },
        ]),
      ).acquire(scope, Buffer.from('h'), 1000),
    ).toMatchObject({ status: 'completed', responseStatus: 201 });
    await expect(new PgIdempotencyStore(db([])).acquire(scope, Buffer.from('h'), 1000)).rejects.toThrow(
      `${IDEMPOTENCY_ACQUIRE_MAX_ATTEMPTS} раз подряд`,
    );
  });

  it('complete через транзакцию вызывающего и через пул; тело/ресурс по умолчанию null; purge при rowCount null → 0', async () => {
    const params: unknown[][] = [];
    const exec = { query: (_s: string, p: unknown[]) => (params.push(p), Promise.resolve({ rowCount: 1, rows: [] })) };
    const pool = {
      query: (_s: string, p?: unknown[]) => (params.push(p ?? []), Promise.resolve({ rowCount: null, rows: [] })),
    };
    const store = new PgIdempotencyStore(pool as never);
    await store.complete(scope, 201, undefined, undefined, exec);
    await store.complete(scope, 200, { ok: true }, 'res-1');
    expect(params[0].slice(3)).toEqual([201, 'null', null]);
    expect(params[1].slice(3)).toEqual([200, '{"ok":true}', 'res-1']);
    expect(await store.purgeExpired()).toBe(0);
    await store.release(scope);
  });
});

describe('IdempotencyInterceptor: ветви', () => {
  const handler = () => undefined;
  function make(opts: { options?: unknown; httpCode?: number; store?: InMemoryIdempotencyStore } = {}) {
    const reflector = {
      get: (meta: unknown) =>
        meta === IDEMPOTENT ? opts.options : meta === HTTP_CODE_METADATA ? opts.httpCode : undefined,
    };
    const store = opts.store ?? new InMemoryIdempotencyStore();
    return { i: new IdempotencyInterceptor(reflector as never, new IdempotencyService(store), {}), store };
  }
  const ctx = (req: object, type = 'http') =>
    ({
      getType: () => type,
      switchToHttp: () => ({ getRequest: () => req }),
      getHandler: () => handler,
    }) as never;
  const req = (over: Record<string, unknown> = {}) => ({
    header: (n: string) => (n.toLowerCase() === 'idempotency-key' ? KEY : undefined),
    originalUrl: '/api/v1/things/1',
    ...over,
  });

  it('не HTTP и метод не указан (GET) — без обработки', async () => {
    const { i } = make();
    expect(await firstValueFrom(i.intercept(ctx({}, 'rpc'), { handle: () => of('rpc') }))).toBe('rpc');
    expect(await firstValueFrom(i.intercept(ctx(req()), { handle: () => of('get') }))).toBe('get');
  });

  it('нет субъекта: обязательный ключ → 500 INTERNAL; необязательный — запрос без хранения', async () => {
    const r = req({ method: 'POST' });
    expect(() => make({ options: { required: true } }).i.intercept(ctx(r), { handle: () => of(1) })).toThrow(
      ProblemException,
    );
    expect(
      await firstValueFrom(make({ options: { required: false } }).i.intercept(ctx(r), { handle: () => of(2) })),
    ).toBe(2);
  });

  it('PUT без HttpCode и без params — итог 200 сохраняется; ошибка обработчика без req.id — бизнес-ошибка сохраняется', async () => {
    const store = new InMemoryIdempotencyStore();
    const { i } = make({ options: { required: true }, store });
    const put = req({ method: 'PUT', principal: { userId: USER }, body: { a: 1 } });
    expect(await firstValueFrom(i.intercept(ctx(put), { handle: () => of({ ok: true }) }))).toEqual({ ok: true });
    const post = req({ method: 'POST', principal: { userId: USER }, originalUrl: '/api/v1/other', body: {} });
    await expect(
      firstValueFrom(
        i.intercept(ctx(post), {
          handle: () => throwError(() => new ProblemException('NOT_FOUND', { detail: 'нет' })),
        }),
      ),
    ).rejects.toMatchObject({ code: 'NOT_FOUND' });
    expect(store.size()).toBe(2);
  });

  it('сохранить бизнес-ошибку не удалось — ключ освобождается; сбой освобождения — только журнал', async () => {
    const store = new InMemoryIdempotencyStore();
    store.failNextCompletes = 1;
    const releases: string[] = [];
    store.release = (s: IdempotencyScope) => {
      releases.push(s.route);
      return Promise.reject(new Error('release failed (тест)'));
    };
    const { i } = make({ options: { required: true }, store });
    const post = req({ method: 'POST', principal: { userId: USER }, originalUrl: '/api/v1/fail', body: {}, id: 'r-1' });
    await expect(
      firstValueFrom(
        i.intercept(ctx(post), {
          handle: () => throwError(() => new ProblemException('NOT_FOUND', { detail: 'нет' })),
        }),
      ),
    ).rejects.toMatchObject({ code: 'NOT_FOUND' });
    expect(releases).toEqual(['POST /fail']);
  });
});
