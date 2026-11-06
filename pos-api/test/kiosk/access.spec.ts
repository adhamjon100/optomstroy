import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { ExecutionContext } from '@nestjs/common';
import { APP_GUARD, Reflector } from '@nestjs/core';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { parse } from 'yaml';
import { GLOBAL_PROVIDERS } from '../../src/app.module.js';
import { AUTH_SESSION_ACTIVITY_GUARD } from '../../src/auth/sessions/session-activity.guard.js';
import { AUTH_APP_GUARD } from '../../src/common/auth/auth-core.module.js';
import { HTTP_RATE_LIMIT_ROUTES } from '../../src/common/rate-limit/http-rate-limit.js';
import { PermissionCatalog } from '../../src/common/rbac/permission-catalog.js';
import { RbacGuard } from '../../src/common/rbac/rbac.guard.js';
import { ReadOnlyGuard } from '../../src/common/read-only/read-only.guard.js';
import { KIOSK_ACCESS_GUARD, KioskAccessGuard } from '../../src/kiosk/common/kiosk-access.guard.js';
import {
  isKioskClosedListRoute,
  isKioskDisabledExempt,
  KIOSK_CLOSED_LIST,
  KIOSK_DISABLED_EXEMPT,
  kioskRouteKeyOf,
} from '../../src/kiosk/common/kiosk-routes.js';
import type { KioskTabletContext, KioskTabletReader } from '../../src/kiosk/common/kiosk-tablet.reader.js';
import type { PosActor, SaleableVariant } from '../support/pos-fixture.js';
import { validateAgainst } from '../settings/support/openapi-check.js';
import { KIOSK_OPERATIONS, type KioskTablet, KioskTestApp } from './support/kiosk-fixture.js';

/**
 * Доступ планшета магазина (P-002 §8.3; 06 ARCH-066; 08 §4.25 «Флаги», «Порядок проверок», «Закрытый список»;
 * 11 SEC-137, SEC-138; ADR-115) — **тестовые данные** стенда `kiosk-fixture` (embedded PostgreSQL 17):
 * - T-KIOSK-033 (сервер): `KIOSK_MODE=false` → любой маршрут с токеном планшета, в том числе все `/kiosk/*` и
 *   `POST /kiosk/exit`, — `403 KIOSK_DISABLED`; `GET /settings/public` (`features.storeTablet=false`) и `GET /me` —
 *   `200`; сотрудники и покупатель работают как прежде;
 * - T-KIOSK-046: `GET /me` планшета — только `{kind, tablet}` (строгая схема `MeKiosk`), `/me/*` — `403`;
 * - закрытый список: маршруты списка проходят по своему праву, остальные — `403 FORBIDDEN` `reason:
 *   kiosk_closed_list`; `/kiosk/*` сотрудникам и покупателю — `403` (права kind-bound, SEC-138); предпросмотр — по
 *   требованию «И из ИЛИ» с `canCreateOrder` по `kiosk.order.submit`; публичные маршруты guard не видит;
 * - статически: список = контракт, порядок глобальных guard-ов, fail-closed без шаблона маршрута и для вида вне
 *   `staff | customer | kiosk`, группы лимитов `/kiosk/*` = `x-rate-limit-group` контракта.
 */
type Method = 'get' | 'post' | 'put' | 'patch' | 'delete';

interface Res {
  readonly status: number;
  readonly body: { code?: string; reason?: string; [k: string]: unknown };
}

const CONTRACT = fileURLToPath(new URL('../../../contracts/openapi/pos-api.v1.yaml', import.meta.url));

interface ContractOp {
  readonly key: string;
  readonly roles: readonly string[];
  readonly rateLimitGroup: string | undefined;
}

function contractOps(): ContractOp[] {
  const doc = parse(readFileSync(CONTRACT, 'utf8')) as {
    paths: Record<string, Record<string, { 'x-roles'?: string[]; 'x-rate-limit-group'?: string; responses?: unknown }>>;
  };
  const out: ContractOp[] = [];
  for (const [path, ops] of Object.entries(doc.paths)) {
    for (const [method, op] of Object.entries(ops)) {
      if (typeof op !== 'object' || op === null || !('responses' in op)) continue;
      out.push({
        key: `${method.toUpperCase()} ${path}`,
        roles: op['x-roles'] ?? [],
        rateLimitGroup: op['x-rate-limit-group'],
      });
    }
  }
  return out;
}

const isDisabled = (r: Res) => r.status === 403 && r.body.code === 'KIOSK_DISABLED';
const isClosedList = (r: Res) =>
  r.status === 403 && r.body.code === 'FORBIDDEN' && r.body.reason === 'kiosk_closed_list';
/** Решение guard-ов «пропустить» (дальше — обработчик): не 401, не отказ guard-а планшета, не отказ RbacGuard. */
const passedGuards = (r: Res) =>
  r.status !== 401 && !isDisabled(r) && !isClosedList(r) && !(r.status === 403 && r.body.code === 'FORBIDDEN');

async function call(
  t: KioskTestApp,
  method: Method,
  path: string,
  a?: Pick<PosActor, 'token' | 'deviceKey'>,
  body?: object,
): Promise<Res> {
  const r = t.req(method, path, a);
  const res = await (body !== undefined ? r.send(body) : method === 'get' || method === 'delete' ? r : r.send({}));
  return { status: res.status, body: (res.body ?? {}) as Res['body'] };
}

const label = (method: string, path: string, r: Res) =>
  `${method.toUpperCase()} ${path} → ${r.status} ${r.body.code ?? ''}${r.body.reason ? `/${r.body.reason}` : ''}`;

/** Маршруты с Bearer вне закрытого списка (08 §4.25: «всё остальное с токеном планшета — 403»), есть на стенде. */
const OUTSIDE_LIST: readonly (readonly [Method, string, object?])[] = [
  ['post', '/orders'],
  ['get', '/orders'],
  ['patch', '/cart', { warehouseId: randomUUID(), rowVersion: 1 }],
  ['delete', '/cart?rowVersion=1'],
  ['post', '/cart/customer', { customerId: randomUUID(), rowVersion: 1 }],
  ['delete', '/cart/customer'],
  ['post', '/cart/discount', { percent: '1.00', rowVersion: 1 }],
  ['post', '/cart/park', { rowVersion: 1 }],
  ['get', '/cart/parked'],
  ['delete', `/cart/parked/${randomUUID()}`],
  ['post', `/cart/parked/${randomUUID()}/resume`],
  ['get', '/catalog/products/recent'],
  ['delete', '/catalog/products/recent'],
  ['get', '/search/barcode/4600000000001'],
  ['get', '/me/consents'],
  ['post', '/me/consents', { kind: 'marketing', granted: false }],
  ['patch', '/me/profile', { fullName: 'Планшет' }],
  ['put', '/me/settings', { idleLockMinutes: 5 }],
  ['post', '/auth/logout'],
  ['post', '/auth/logout-all'],
  ['get', '/auth/sessions'],
  ['post', '/auth/step-up', { operation: 'users.manage', method: 'pin', pin: '123456' }],
];

describe('kiosk: статически — закрытый список, порядок guard-ов, лимиты (06 ARCH-066; 08 §4.25; 11 SEC-137)', () => {
  const ops = contractOps();

  it('закрытый список = операции контракта с kiosk в x-roles + GET /catalog/price-lists (08 §4.25, AC-API-186)', () => {
    const contractKiosk = ops.filter((o) => o.roles.includes('kiosk')).map((o) => o.key);
    expect([...KIOSK_CLOSED_LIST].sort()).toEqual([...contractKiosk, 'GET /catalog/price-lists'].sort());
    expect(KIOSK_CLOSED_LIST).toHaveLength(23);
    // Каждая запись — операция контракта; `GET /catalog/price-lists` в контракте без kiosk (ответ 403, как у customer).
    const keys = new Set(ops.map((o) => o.key));
    expect(KIOSK_CLOSED_LIST.filter((k) => !keys.has(k))).toEqual([]);
    expect(ops.find((o) => o.key === 'GET /catalog/price-lists')?.roles).not.toContain('kiosk');
    expect([...KIOSK_DISABLED_EXEMPT]).toEqual(['GET /settings/public', 'GET /me']);
    // Явно вне списка (08 §4.25, ADR-115 п. 21, Р-15).
    for (const k of [
      'POST /orders',
      'GET /sync/status',
      'GET /catalog/products/recent',
      'GET /search/barcode/{value}',
      'POST /auth/logout',
      'PATCH /cart',
      'DELETE /cart',
      'POST /cart/customer',
    ]) {
      expect(KIOSK_CLOSED_LIST as readonly string[], k).not.toContain(k);
    }
  });

  it('ключ маршрута — метод и шаблон Express; без шаблона — null (fail-closed); литерал recent ≠ {id}', () => {
    expect(kioskRouteKeyOf({ method: 'GET', route: { path: '/api/v1/catalog/products/:id' } })).toBe(
      'GET /catalog/products/{}',
    );
    expect(
      isKioskClosedListRoute(kioskRouteKeyOf({ method: 'GET', route: { path: '/api/v1/catalog/products/:id' } })),
    ).toBe(true);
    expect(
      isKioskClosedListRoute(kioskRouteKeyOf({ method: 'GET', route: { path: '/api/v1/catalog/products/recent' } })),
    ).toBe(false);
    expect(
      isKioskClosedListRoute(kioskRouteKeyOf({ method: 'POST', route: { path: '/api/v1/cart/checkout-preview' } })),
    ).toBe(true);
    expect(isKioskClosedListRoute(kioskRouteKeyOf({ method: 'DELETE', route: { path: '/api/v1/cart' } }))).toBe(false);
    expect(kioskRouteKeyOf({ method: 'GET' })).toBeNull();
    expect(kioskRouteKeyOf({ route: { path: '/api/v1/me' } })).toBeNull();
    expect(isKioskClosedListRoute(null)).toBe(false);
    expect(isKioskDisabledExempt(null)).toBe(false);
    expect(isKioskDisabledExempt(kioskRouteKeyOf({ method: 'GET', route: { path: '/api/v1/me' } }))).toBe(true);
    expect(isKioskDisabledExempt(kioskRouteKeyOf({ method: 'GET', route: { path: '/api/v1/me/consents' } }))).toBe(
      false,
    );
  });

  it('порядок глобальных guard-ов: ReadOnly → Auth → SessionActivity → KioskAccess → Rbac (06 §7.4 п. (1), AC-ARCH-066 (2))', () => {
    const guards = GLOBAL_PROVIDERS.filter((p) => (p as { provide?: unknown }).provide === APP_GUARD);
    expect(guards).toHaveLength(5);
    expect((guards[0] as { useClass?: unknown }).useClass).toBe(ReadOnlyGuard);
    expect(guards[1]).toBe(AUTH_APP_GUARD);
    expect(guards[2]).toBe(AUTH_SESSION_ACTIVITY_GUARD);
    expect(guards[3]).toBe(KIOSK_ACCESS_GUARD);
    expect((guards[3] as { useClass?: unknown }).useClass).toBe(KioskAccessGuard);
    expect((guards[4] as { useClass?: unknown }).useClass).toBe(RbacGuard);
  });

  it('лимиты: /kiosk/* в HTTP_RATE_LIMIT_ROUTES = x-rate-limit-group контракта (RL-READ, RL-CART, RL-FIN)', () => {
    const kioskOps = ops.filter((o) => o.key.includes(' /kiosk/'));
    expect(kioskOps).toHaveLength(5);
    for (const o of kioskOps) {
      const group = (Object.keys(HTTP_RATE_LIMIT_ROUTES) as (keyof typeof HTTP_RATE_LIMIT_ROUTES)[]).find((g) =>
        HTTP_RATE_LIMIT_ROUTES[g].includes(o.key),
      );
      if (o.rateLimitGroup === 'RL-OTP-SEND' || o.rateLimitGroup === 'RL-PIN') expect(group, o.key).toBeUndefined();
      else expect(group, o.key).toBe(o.rateLimitGroup);
    }
  });

  describe('KioskAccessGuard без HTTP: fail-closed', () => {
    const tablet: KioskTabletContext = {
      tabletId: randomUUID(),
      userId: randomUUID(),
      deviceId: randomUUID(),
      name: 'Планшет у входа',
      warehouseId: randomUUID(),
    };
    const reflector = { getAllAndOverride: () => undefined } as unknown as Reflector;
    const reader = (found: KioskTabletContext | null) => {
      const calls: string[] = [];
      return {
        calls,
        reader: {
          findActiveByUserId: (id: string) => {
            calls.push(id);
            return Promise.resolve(found);
          },
        } as unknown as KioskTabletReader,
      };
    };
    const ctx = (req: Record<string, unknown>): ExecutionContext =>
      ({
        getType: () => 'http',
        getHandler: () => undefined,
        getClass: () => undefined,
        switchToHttp: () => ({ getRequest: () => req }),
      }) as unknown as ExecutionContext;
    const principal = (kind: string) => ({
      userId: tablet.userId,
      kind,
      roles: [kind === 'kiosk' ? 'kiosk' : 'seller'],
    });

    it('kind=kiosk без шаблона маршрута (req.route нет) → 403 kiosk_closed_list; планшет не читается', async () => {
      const r = reader(tablet);
      const g = new KioskAccessGuard(reflector, { KIOSK_MODE: true }, r.reader);
      await expect(
        g.canActivate(ctx({ method: 'GET', url: '/api/v1/me', principal: principal('kiosk'), headers: {} })),
      ).rejects.toMatchObject({ code: 'FORBIDDEN', extensions: { reason: 'kiosk_closed_list' } });
      expect(r.calls).toEqual([]);
    });

    it('вид вне staff | customer | kiosk (integration, неизвестный) → 403; staff и customer — без чтения планшета', async () => {
      const r = reader(tablet);
      const g = new KioskAccessGuard(reflector, { KIOSK_MODE: true }, r.reader);
      const route = { path: '/api/v1/orders' };
      for (const kind of ['integration', 'robot']) {
        await expect(
          g.canActivate(ctx({ method: 'POST', route, principal: principal(kind), headers: {} })),
        ).rejects.toMatchObject({ code: 'FORBIDDEN' });
      }
      for (const kind of ['staff', 'customer']) {
        expect(await g.canActivate(ctx({ method: 'POST', route, principal: principal(kind), headers: {} }))).toBe(true);
      }
      expect(await g.canActivate(ctx({ method: 'POST', route, headers: {} }))).toBe(true); // нет субъекта — RBAC 401
      expect(r.calls).toEqual([]);
    });

    it('@Public() — пропуск без проверок (11 SEC-013); KIOSK_MODE=false, GET /me — планшет в req.kiosk', async () => {
      const r = reader(tablet);
      const pub = new KioskAccessGuard(
        { getAllAndOverride: () => true } as unknown as Reflector,
        {
          KIOSK_MODE: false,
        },
        r.reader,
      );
      expect(await pub.canActivate(ctx({ method: 'POST', principal: principal('kiosk'), headers: {} }))).toBe(true);
      const g = new KioskAccessGuard(reflector, { KIOSK_MODE: false }, r.reader);
      const req: Record<string, unknown> = {
        method: 'GET',
        route: { path: '/api/v1/me' },
        principal: principal('kiosk'),
        headers: {},
      };
      expect(await g.canActivate(ctx(req))).toBe(true);
      expect(req.kiosk).toEqual(tablet);
      await expect(g.canActivate(ctx({ ...req, route: { path: '/api/v1/cart' } }))).rejects.toMatchObject({
        code: 'KIOSK_DISABLED',
      });
      const gone = new KioskAccessGuard(reflector, { KIOSK_MODE: true }, reader(null).reader);
      const err = (await gone.canActivate(ctx({ ...req })).catch((e: unknown) => e)) as {
        code?: string;
        extensions?: { reason?: string };
      };
      expect([err.code, err.extensions?.reason]).toEqual(['FORBIDDEN', undefined]);
    });
  });
});

describe('T-KIOSK-033 KIOSK_MODE=false: планшет — 403 KIOSK_DISABLED, кроме GET /settings/public и GET /me', () => {
  const t = new KioskTestApp();
  let tab: KioskTablet;
  let seller: PosActor;
  let customer: PosActor;

  beforeAll(async () => {
    await t.startKiosk({ kioskMode: false });
    tab = await t.tablet({ name: 'Планшет у входа' });
    seller = await t.actor({ role: 'seller' });
    customer = await t.actor({ role: 'customer' });
  });
  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-033 /kiosk/* 403 KIOSK_DISABLED — все пять операций, в том числе POST /kiosk/exit (ADR-115 п. 28)', async () => {
    const problems: string[] = [];
    for (const op of KIOSK_OPERATIONS) {
      const r = await call(t, op.method, op.path, tab);
      if (!isDisabled(r)) problems.push(label(op.method, op.path, r));
    }
    expect(problems).toEqual([]);
  });

  it('T-KIOSK-033 маршруты списка и вне списка — 403 KIOSK_DISABLED; /settings/public (storeTablet=false) и /me — 200', async () => {
    const problems: string[] = [];
    const routes: (readonly [Method, string, object?])[] = [
      ['get', '/cart'],
      ['get', '/catalog/categories'],
      ['get', '/catalog/products'],
      ['post', '/cart/checkout-preview'],
      ...OUTSIDE_LIST,
    ];
    for (const [method, path, body] of routes) {
      const r = await call(t, method, path, tab, body);
      if (!isDisabled(r)) problems.push(label(method, path, r));
    }
    expect(problems).toEqual([]);
    const settings = await call(t, 'get', '/settings/public', tab);
    expect(settings.status).toBe(200);
    expect(settings.body).toMatchObject({
      features: { storeTablet: false },
      kiosk: { idleSeconds: 120, idleWarningSeconds: 15, doneSeconds: 60 },
    });
    const me = await call(t, 'get', '/me', tab);
    expect(me.status).toBe(200);
    expect(me.body).toEqual({
      kind: 'kiosk',
      tablet: { id: tab.tabletId, name: 'Планшет у входа', warehouseId: tab.warehouseId },
    });
  });

  it('публичные маршруты guard не видит: с токеном планшета ответ тот же, что без него (11 SEC-013)', async () => {
    // Тот же `X-Device-Id` (device_key планшета) — запросы различаются только заголовком Bearer.
    const send = async (method: 'get' | 'post', path: string, bearer: boolean, body?: object): Promise<Res> => {
      let r = t.req(method, path).set('X-Device-Id', tab.deviceKey);
      if (bearer) r = r.set('Authorization', `Bearer ${tab.token}`);
      const res = await (body !== undefined ? r.send(body) : r);
      return { status: res.status, body: (res.body ?? {}) as Res['body'] };
    };
    for (const [method, path, body] of [
      ['post', '/auth/refresh', { refreshToken: randomUUID() }],
      ['get', `/auth/otp/challenges/${randomUUID()}`, undefined],
    ] as const) {
      const anon = await send(method, path, false, body);
      const withTablet = await send(method, path, true, body);
      expect([withTablet.status, withTablet.body.code], path).toEqual([anon.status, anon.body.code]);
      expect(isDisabled(withTablet), path).toBe(false);
    }
  });

  it('сотрудник и покупатель при KIOSK_MODE=false работают как прежде; /kiosk/* им — 403 FORBIDDEN (не KIOSK_DISABLED)', async () => {
    for (const a of [seller, customer]) {
      expect((await call(t, 'get', '/cart', a)).status, a.kind).toBe(200);
      const me = await call(t, 'get', '/me', a);
      expect(me.status, a.kind).toBe(200);
      expect(me.body).toMatchObject({ id: a.userId, kind: a.kind, roles: [a.role] });
      expect((await call(t, 'get', '/settings/public', a)).body).toMatchObject({ features: { storeTablet: false } });
      for (const op of KIOSK_OPERATIONS) {
        const r = await call(t, op.method, op.path, a);
        expect([r.status, r.body.code, r.body.reason], `${a.kind} ${op.method} ${op.path}`).toEqual([
          403,
          'FORBIDDEN',
          undefined,
        ]);
      }
    }
  });
});

describe('KIOSK_MODE=true: закрытый список планшета, GET /me, предпросмотр (08 §4.25; 11 SEC-137, SEC-138)', () => {
  const t = new KioskTestApp();
  let tab: KioskTablet;
  let seller: PosActor;
  let customer: PosActor;
  let v: SaleableVariant[];

  beforeAll(async () => {
    await t.startKiosk({ kioskMode: true });
    tab = await t.tablet({ name: 'Планшет у кассы' });
    seller = await t.actor({ role: 'seller' });
    customer = await t.actor({ role: 'customer' });
    v = await t.saleableVariants(3);
  });
  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-046 GET /me kiosk form, /me/* 403: только {kind, tablet} по kiosk.self.read, без ПДн; схема MeKiosk', async () => {
    const me = await call(t, 'get', '/me', tab);
    expect(me.status).toBe(200);
    expect(me.body).toEqual({
      kind: 'kiosk',
      tablet: { id: tab.tabletId, name: 'Планшет у кассы', warehouseId: tab.warehouseId },
    });
    expect(validateAgainst('MeKiosk', me.body)).toEqual([]);
    expect(JSON.stringify(me.body)).not.toMatch(/phone|fullName|roles|permissions|session|customer|profile|\+996/i);
    // Права profile.manage.own у роли kiosk нет: GET /me — по kiosk.self.read (засчитывается только при kind=kiosk).
    const granted = t.app.get(PermissionCatalog).effectivePermissions({ roles: ['kiosk'], kind: 'kiosk' });
    expect([granted.has('profile.manage.own'), granted.has('kiosk.self.read')]).toEqual([false, true]);
    const problems: string[] = [];
    for (const [method, path, body] of [
      ['get', '/me/consents'],
      ['post', '/me/consents', { kind: 'marketing', granted: false }],
      ['patch', '/me/profile', { fullName: 'Планшет' }],
      ['put', '/me/settings', { idleLockMinutes: 5 }],
    ] as const) {
      const r = await call(t, method, path, tab, body);
      if (!isClosedList(r)) problems.push(label(method, path, r));
    }
    expect(problems).toEqual([]);
    // У сотрудника и покупателя GET /me — прежняя форма Me (паритет).
    for (const a of [seller, customer]) {
      const r = await call(t, 'get', '/me', a);
      expect(r.status).toBe(200);
      expect(r.body).toMatchObject({ id: a.userId, kind: a.kind, roles: [a.role], apiVersion: '1.0' });
      expect(r.body).not.toHaveProperty('tablet');
    }
  });

  it('маршруты закрытого списка — по своему праву (guard планшета и RBAC пропускают); GET /settings/public — storeTablet=true', async () => {
    const problems: string[] = [];
    const check = async (method: Method, path: string, body?: object, expectStatus = 200) => {
      const r = await call(t, method, path, tab, body);
      if (!passedGuards(r) || r.status !== expectStatus) problems.push(label(method, path, r));
      return r;
    };
    await check('get', '/catalog/categories');
    await check('get', '/catalog/products');
    await check('get', `/catalog/products/${v[0].productId}`);
    await check('get', `/catalog/products/${v[0].productId}/variants`);
    await check('get', '/catalog/units');
    await check('get', '/catalog/warehouses');
    await check('get', '/catalog/sync/units');
    await check('get', `/search/products?q=${encodeURIComponent(v[0].productName.slice(0, 4))}`);
    await check('get', `/search/suggest?q=${encodeURIComponent(v[0].productName.slice(0, 4))}`);
    await check('get', `/inventory/balances?variantIds=${v[0].variantId}`);
    await check('post', '/inventory/check', {
      warehouseId: tab.warehouseId,
      items: [{ variantId: v[0].variantId, quantity: { value: '1', unitId: v[0].unitId, packagingId: null } }],
    });
    const settings = await check('get', '/settings/public');
    expect(settings.body).toMatchObject({ features: { storeTablet: true } });
    const cart = await check('get', '/cart');
    const put = await check('put', `/cart/items/${v[1].variantId}`, {
      quantity: { value: '1', unitId: v[1].unitId, packagingId: null },
      rowVersion: cart.body.rowVersion as number,
    });
    await check('delete', `/cart/items/${v[1].variantId}`);
    // GET /catalog/price-lists — в списке (guard пропускает), ответ — по правилу покупателя (08 AC-API-186, WP-S1B).
    const pl = await call(t, 'get', '/catalog/price-lists', tab);
    if (isClosedList(pl) || isDisabled(pl) || pl.status >= 500) problems.push(label('get', '/catalog/price-lists', pl));
    expect(problems).toEqual([]);
    expect(put.body).toHaveProperty('items');
  });

  it('POST /cart/checkout-preview: «cart.manage.own и одно из order.create | kiosk.order.submit»; canCreateOrder по kiosk.order.submit', async () => {
    const preview = async (a: PosActor) => {
      const c0 = await call(t, 'get', '/cart', a);
      const c1 = await call(t, 'put', `/cart/items/${v[2].variantId}`, a, {
        quantity: { value: '1', unitId: v[2].unitId, packagingId: null },
        rowVersion: c0.body.rowVersion as number,
      });
      expect(c1.status, a.kind).toBe(200);
      return call(t, 'post', '/cart/checkout-preview', a, {
        cartId: c1.body.id as string,
        cartRowVersion: c1.body.rowVersion as number,
        paymentMethod: 'cash',
        delivery: { method: 'pickup' },
        receiver: { kind: 'customer' },
      });
    };
    const kiosk = await preview(tab);
    expect(kiosk.status, JSON.stringify(kiosk.body)).toBe(200);
    expect(kiosk.body.permissions).toMatchObject({ canCreateOrder: true });
    // Паритет: сотрудник и покупатель — по order.create, как прежде.
    for (const a of [seller, customer]) {
      const r = await preview(a);
      expect(r.status, a.kind).toBe(200);
      expect(r.body.permissions, a.kind).toMatchObject({ canCreateOrder: true });
    }
  });

  it('вне закрытого списка → 403 FORBIDDEN reason kiosk_closed_list (в том числе POST /orders, /me/*, /auth/*, PATCH /cart)', async () => {
    const problems: string[] = [];
    for (const [method, path, body] of OUTSIDE_LIST) {
      const r = await call(t, method, path, tab, body);
      if (!isClosedList(r)) problems.push(label(method, path, r));
    }
    expect(problems).toEqual([]);
    // Сотруднику тот же POST /orders guard планшета не отказывает (решает RBAC и обработчик).
    const staff = await call(t, 'get', '/orders', seller);
    expect(isClosedList(staff)).toBe(false);
  });

  it('/kiosk/*: планшет проходит guard и RBAC; сотрудник и покупатель — 403 FORBIDDEN (права только при kind=kiosk, SEC-138)', async () => {
    const problems: string[] = [];
    for (const op of KIOSK_OPERATIONS) {
      const k = await call(t, op.method, op.path, tab);
      if (!passedGuards(k)) problems.push(`kiosk ${label(op.method, op.path, k)}`);
      for (const a of [seller, customer]) {
        const r = await call(t, op.method, op.path, a);
        if (!(r.status === 403 && r.body.code === 'FORBIDDEN' && r.body.reason === undefined)) {
          problems.push(`${a.kind} ${label(op.method, op.path, r)}`);
        }
      }
    }
    expect(problems).toEqual([]);
  });

  it('строка store_tablets не active при живой сессии → запасной 403 FORBIDDEN guard-а; склада нет → GET /me 403 kiosk_warehouse_unavailable', async () => {
    // `revokeTablet()` стенда меняет только `store_tablets`, сессии не отзывает: AuthGuard пропускает, отказывает
    // guard планшета (`kiosk_tablet_inactive`). Настоящее отключение (`POST /admin/store-tablets/{id}/revoke`) —
    // `401 KIOSK_REVOKED` в AuthGuard — проверяет lifecycle-reconnect.spec.ts.
    const gone = await t.tablet();
    await t.revokeTablet(gone.tabletId);
    for (const path of ['/me', '/settings/public', '/cart']) {
      const r = await call(t, 'get', path, gone);
      expect([r.status, r.body.code, r.body.reason], path).toEqual([403, 'FORBIDDEN', undefined]);
    }
    const noWarehouse = await t.tablet({ warehouseId: null });
    const me = await call(t, 'get', '/me', noWarehouse);
    expect([me.status, me.body.code, me.body.reason]).toEqual([403, 'FORBIDDEN', 'kiosk_warehouse_unavailable']);
    expect(t.logs.text).not.toContain(noWarehouse.token);
  });

  it('T-KIOSK-046 склад задан, но неактивен: GET /me — 200 MeKiosk, каталог и корзина — 403 kiosk_warehouse_unavailable', async () => {
    // Текущее поведение (spec-drift-12): GET /me проверяет только «склад не задан»; неактивный склад (is_active=false
    // или deletion_mark) отклоняют каталог, корзина и заявка (10 KIOSK-007; ADR-115 п. 23).
    for (const flag of ['is_active = false', 'deletion_mark = true'] as const) {
      const ins = await t.q<{ id: string }>(
        `INSERT INTO warehouses (synced_at, source_hash, name, sort_order) VALUES (now(), 'kiosk-test', $1, 97) RETURNING id`,
        [`Склад стенда (${flag})`],
      );
      const warehouseId = ins[0].id;
      await t.q(`UPDATE warehouses SET ${flag} WHERE id = $1`, [warehouseId]);
      const k = await t.tablet({ warehouseId });
      const me = await call(t, 'get', '/me', k);
      expect(me.status, `${flag} ${JSON.stringify(me.body)}`).toBe(200);
      expect(me.body).toEqual({ kind: 'kiosk', tablet: { id: k.tabletId, name: k.name, warehouseId } });
      expect(validateAgainst('MeKiosk', me.body)).toEqual([]);
      for (const path of ['/catalog/categories', '/cart']) {
        const r = await call(t, 'get', path, k);
        expect([r.status, r.body.code, r.body.reason], `${flag} ${path}`).toEqual([
          403,
          'FORBIDDEN',
          'kiosk_warehouse_unavailable',
        ]);
      }
    }
  });
});
