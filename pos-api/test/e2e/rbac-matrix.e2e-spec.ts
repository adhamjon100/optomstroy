import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { type INestApplication, RequestMethod } from '@nestjs/common';
import { METHOD_METADATA, PATH_METADATA } from '@nestjs/common/constants.js';
import { ModulesContainer } from '@nestjs/core';
import request from 'supertest';
import { parse } from 'yaml';
import { createApp } from '../../src/bootstrap/create-app.js';
import { JwtService } from '../../src/common/auth/jwt.service.js';
import { PinHasher } from '../../src/common/crypto/pin-hasher.service.js';
import { PermissionCatalog } from '../../src/common/rbac/permission-catalog.js';
import {
  type PermissionRequirement,
  PUBLIC_ROUTE,
  REQUIRED_PERMISSIONS,
  requirementCodes,
} from '../../src/common/rbac/rbac.decorators.js';
import { KIOSK_CLOSED_LIST } from '../../src/kiosk/common/kiosk-routes.js';
import type { RoleCode } from '../../src/users/users.types.js';
import { FoundationDb, seedSubject } from '../foundation/support/foundation-db.js';
import { LogCapture, testConfig } from '../support/test-app.js';
import { KioskE2eApp, type Res, type SaleableVariant, type Subject, type Tablet } from './kiosk/support/kiosk-e2e.js';

/**
 * RM-D-006 п. 1 (ревью D-MN-05), 12 T-SEC-018 (класс A), T-SEC-019: матрица «операция × роль» для всего
 * приложения AppModule этапа D, построенная из contracts/openapi (x-permissions, x-roles) и
 * contracts/rbac/permissions.yaml (через PermissionCatalog = permissions.generated.ts):
 *
 * 1. T-SEC-018: у каждого зарегистрированного маршрута объявлена политика — `@Public()` или непустое требование
 *    (`@RequirePermission`, `@RequireAnyPermission`, «И из ИЛИ» `@RequirePermissionGroups` — ADR-115); все коды
 *    требования (`requirementCodes`) ⊆ `x-permissions` операции контракта; публичные — только где контракт не
 *    требует прав.
 * 2. Статически по всему контракту (141 операция): роль из `x-roles` держит хотя бы один код операции; роль вне
 *    `x-roles` не держит ни одного кода — кроме перечисленных ниже объектных сужений; кассовые операции
 *    (`x-roles` ∋ cashier, ∌ admin/owner) недоступны `owner` и `admin` по правам (11 §4.4, SEC-036).
 * 3. HTTP для каждой реализованной операции этапа D × 6 ролей (реальные access-JWT и сессии в БД): роль вне
 *    `x-roles` → 403 FORBIDDEN; роль из `x-roles` не получает отказ RbacGuard (403 FORBIDDEN без `reason`).
 * 4. Колонка `kiosk` — планшет магазина (12 T-KIOSK-005, T-SEC-069; 11 SEC-046, SEC-137, SEC-138; 08 §4.25; ADR-115) —
 *    отдельный стенд ниже: каталог, `KIOSK_MODE=true`, планшет подключён настоящим `POST /admin/store-tablets`.
 */
const ROLES = ['seller', 'cashier', 'senior_seller', 'admin', 'owner', 'customer'] as const;
type Role = (typeof ROLES)[number];
type Method = 'get' | 'post' | 'put' | 'patch' | 'delete';

interface ContractOp {
  readonly method: Method;
  readonly path: string;
  readonly operationId: string;
  readonly permissions: readonly string[];
  readonly roles: readonly string[];
  /** `security: []` контракта — публичная операция (SEC-013); иначе — Bearer. */
  readonly isPublic: boolean;
}

/**
 * Право выдано, но контракт сужает операцию объектным правилом сервиса (не RBAC): проверяется HTTP-частью (роль
 * вне `x-roles` всё равно получает 403 FORBIDDEN — от сервиса, с `reason`). Остальные — операции этапов E–G.
 */
const OBJECT_LEVEL_NARROWING: ReadonlySet<string> = new Set([
  'DELETE /me/pin', // 09 §9.4: удалить PIN может только customer (staff — D-48, PIN обязателен)
  'POST /cart/park',
  'GET /cart/parked',
  'DELETE /cart/parked/{id}',
  'POST /cart/parked/{id}/resume',
  'GET /catalog/price-lists',
  'GET /orders/{id}/documents/receipt.pdf',
  'GET /orders/{id}/documents/waybill.pdf',
  'GET /payments/{id}/documents/receipt.pdf',
]);

/**
 * Коды `x-permissions` нужны вместе (И), а не одно из (contracts/openapi/NOTES.md §9 п. 5; 08 §4.25.4; ADR-115):
 * `POST /kiosk/reset` — `cart.manage.own` и `kiosk.order.submit`; второй код только у роли `kiosk`, поэтому роли
 * с одним `cart.manage.own` в `x-roles` не входят.
 */
const ALL_CODES_REQUIRED: ReadonlySet<string> = new Set(['POST /kiosk/reset']);

/**
 * Маршрут `@Public()` на уровне RbacGuard, право проверяет обработчик: без права — 404 NOT_FOUND (существование
 * документа не раскрывается; 08 §4.19.2, 16 §4.3 OPENAPI_PUBLIC).
 */
const IN_HANDLER_PERMISSION: ReadonlySet<string> = new Set(['GET /openapi.json']);

/**
 * Маршруты приложения вне `paths` контракта (сверка «маршруты ⊆ контракт», интеграция G): служебная публикация
 * документа OpenAPI под префиксом API и отказ `405` на `POST /registration/customer-match` (этап D, RM-D-005
 * критерий 4: путь — только GET, ответ `405 METHOD_NOT_ALLOWED` с `Allow: GET` — маршрут-«заглушка» метода).
 */
const ROUTES_OUTSIDE_CONTRACT: ReadonlySet<string> = new Set([
  'GET /api/v1/openapi.json',
  'POST /registration/customer-match',
]);

/**
 * Право выдано всем ролям из `x-roles`, но для `customer` операция сужена объектным правилом обработчика: без
 * подтверждённой (`confirmed`) привязки к карточке — `403 FORBIDDEN` (08 §4.12.2: «`customer` — только правила своей
 * привязанной карточки, иначе `FORBIDDEN`»). Покупатель матрицы не привязан; доступ привязанного покупателя проверяют
 * `test/e2e/cashier` и `test/discounts`.
 */
const CUSTOMER_LINK_REQUIRED: ReadonlySet<string> = new Set(['GET /discounts/rules']);

/**
 * Операции этапа D (модули auth, profile, registration, customers/links, admin users/invitations, settings) и
 * `/admin/settings` (RM-D-015 п. 2, бэклог E_spec_sync.md §3).
 */
const STAGE_D =
  /^\/(auth|me|registration|admin\/users|admin\/invitations|admin\/settings$|settings\/public|customers(\/\{id\}\/links.*)?$)/;

/**
 * Операции этапа E (RM-E-002, RM-E-004…RM-E-006, RM-E-014, RM-E-015, RM-E-017): каталог, поиск товаров, остатки,
 * избранное товаров, офлайн-API, синхронизация. `/search/customers` и `/favorites/customers` — этап G.
 */
const STAGE_E = /^\/(catalog\/|search\/(products|suggest|barcode)|inventory\/|favorites\/products|sync\/)/;

/**
 * Операции этапа F (RM-F-001…RM-F-008, RM-F-012, RM-F-015, RM-F-016): корзина, заказы, платежи, документы,
 * уведомления, минимальный `GET /search/customers` (SCR-21) и `GET /customers/{id}/orders` (заказы POS).
 */
const STAGE_F =
  /^\/(cart(\/|$)|orders(\/|$)|payments(\/|$)|notifications(\/|$)|search\/customers$|customers\/\{id\}\/orders$)/;

/**
 * Операции контракта с префиксами этапа F, которые этапом F не реализуются: оплата долга без заказа и её квитанция —
 * этап G (RM-G-013 условно, Q-152; ядро §19.2), вебхук банка — R2 (RM-F-014, ядро §24.4; в R1 маршрут не
 * регистрируется — 404, 11 SEC-135).
 */
// Этап G (RM-G-013, агент G-be-txn-returns): `POST /payments` и квитанция `receipt.pdf` зарегистрированы guard-ом
// (403 / 404 при `DEBT_PAYMENTS_FROM_POS=false`) — в перечне «не реализовано» остаётся только вебхук банка.
const STAGE_F_NOT_IN_F = ['POST /payments/qr/webhook'];

/**
 * Операции этапа G «Кассир» (RM-G-001…RM-G-008, RM-G-011, RM-G-012, RM-G-014; интеграция backend G, RM-G-009 п. 1):
 * карточка клиента, долги и их обновление, скидки и лимиты, избранные клиенты, дашборд кассира, просроченные долги,
 * возвраты, журнал транзакций, аудит и отчёты администратора. `GET/POST /customers` (этап D-перечень),
 * `GET /search/customers` и `GET /customers/{id}/orders` (этап F-перечень) доработаны в G и проверяются там же.
 */
const STAGE_G =
  /^\/(admin\/(audit-logs|discount-limits|reports\/)|customers\/\{id\}(\/(discounts|receivables(\/refresh)?))?$|discounts\/|favorites\/customers|pos\/dashboard$|receivables\/|returns(\/|$)|transactions(\/|$))/;

/**
 * Операции дорожки TAB «Планшет магазина» (P-002, ADR-115; 08 §4.18.11–§4.18.15, §4.25; OpenAPI 1.3.0
 * `70_kiosk.yaml`): `/admin/store-tablets*` (admin, список — и owner) и `/kiosk/*` (только `kind=kiosk`).
 */
const STAGE_K = /^\/(admin\/store-tablets|kiosk\/)/;

function contractOps(): ContractOp[] {
  const file = fileURLToPath(new URL('../../../contracts/openapi/pos-api.v1.yaml', import.meta.url));
  const doc = parse(readFileSync(file, 'utf8')) as {
    security?: unknown[];
    paths: Record<
      string,
      Record<string, { operationId?: string; 'x-permissions'?: string[]; 'x-roles'?: string[]; security?: unknown[] }>
    >;
  };
  const out: ContractOp[] = [];
  for (const [path, ops] of Object.entries(doc.paths)) {
    for (const [method, op] of Object.entries(ops)) {
      if (!op?.operationId) continue;
      out.push({
        method: method as Method,
        path,
        operationId: op.operationId,
        permissions: op['x-permissions'] ?? [],
        roles: op['x-roles'] ?? [],
        isPublic: (op.security ?? doc.security ?? []).length === 0,
      });
    }
  }
  return out;
}

interface Route {
  readonly method: Method;
  /** Шаблон пути без префикса `/api/v1` в нотации контракта (`{id}`). */
  readonly path: string;
  readonly isPublic: boolean;
  readonly requirement: PermissionRequirement | undefined;
  readonly handler: string;
}

const METHODS: Partial<Record<RequestMethod, Method>> = {
  [RequestMethod.GET]: 'get',
  [RequestMethod.POST]: 'post',
  [RequestMethod.PUT]: 'put',
  [RequestMethod.PATCH]: 'patch',
  [RequestMethod.DELETE]: 'delete',
};

function joinPath(...parts: (string | string[] | undefined)[]): string {
  const segs = parts
    .flatMap((p) => (Array.isArray(p) ? p.slice(0, 1) : [p]))
    .filter((p): p is string => typeof p === 'string' && p !== '' && p !== '/');
  return `/${segs.map((s) => s.replace(/^\/+|\/+$/g, '')).join('/')}`.replace(/:([A-Za-z]+)/g, '{$1}');
}

/** Все маршруты HTTP-контроллеров приложения с их политикой (метаданные Nest, как читает RbacGuard). */
function discoverRoutes(app: INestApplication): Route[] {
  const routes: Route[] = [];
  for (const mod of app.get(ModulesContainer).values()) {
    for (const wrapper of mod.controllers.values()) {
      const ctrl = wrapper.metatype as (new (...a: never[]) => unknown) | undefined;
      if (!ctrl) continue;
      const base = Reflect.getMetadata(PATH_METADATA, ctrl) as string | string[] | undefined;
      const proto = ctrl.prototype as Record<string, unknown>;
      for (const name of Object.getOwnPropertyNames(proto)) {
        const fn = proto[name];
        if (name === 'constructor' || typeof fn !== 'function') continue;
        const sub = Reflect.getMetadata(PATH_METADATA, fn) as string | string[] | undefined;
        const verb = Reflect.getMetadata(METHOD_METADATA, fn) as RequestMethod | undefined;
        if (sub === undefined || verb === undefined) continue;
        const method = METHODS[verb];
        if (!method) continue;
        const pick = <T>(key: string): T | undefined =>
          (Reflect.getMetadata(key, fn) as T | undefined) ?? (Reflect.getMetadata(key, ctrl) as T | undefined);
        routes.push({
          method,
          path: joinPath(base, sub),
          isPublic: pick<boolean>(PUBLIC_ROUTE) === true,
          requirement: pick<PermissionRequirement>(REQUIRED_PERMISSIONS),
          handler: `${ctrl.name}.${name}`,
        });
      }
    }
  }
  return routes;
}

describe('RBAC: матрица операция × роль из контракта и permissions.yaml (RM-D-006 п. 1; T-SEC-018/019)', () => {
  const fdb = new FoundationDb();
  let app: INestApplication;
  let routes: Route[];
  let catalog: PermissionCatalog;
  const actors = {} as Record<Role, { token: string; deviceKey: string }>;
  const ops = contractOps();

  beforeAll(async () => {
    await fdb.start('rbac_matrix_e2e');
    // Этап F: корзине нужны склад и вид цены (реплика 1С после первичной загрузки, RM-E-011) — минимальные строки.
    await fdb.pool.query(
      `INSERT INTO warehouses (synced_at, source_hash, name, is_default_for_pos) VALUES (now(), 'rbac', 'Склад RBAC', true)`,
    );
    await fdb.pool.query(
      `INSERT INTO price_lists (synced_at, source_hash, name, is_default)
       SELECT now(), 'rbac', 'Розничная RBAC', true WHERE NOT EXISTS (SELECT 1 FROM price_lists WHERE is_default)`,
    );
    app = await createApp(testConfig({ DATABASE_URL: fdb.url, LOG_LEVEL: 'silent' }), { logStream: new LogCapture() });
    routes = discoverRoutes(app);
    catalog = app.get(PermissionCatalog);
    const jwt = app.get(JwtService);
    const hasher = app.get(PinHasher);
    for (const role of ROLES) {
      const kind = role === 'customer' ? 'customer' : 'staff';
      const s = await seedSubject(fdb.db, { role: role as RoleCode, kind });
      // staff без PIN — ограниченная сессия (403 pin_not_set раньше RBAC): PIN задаётся
      const h = await hasher.hash('482913', s.userId);
      await fdb.pool.query(
        `INSERT INTO app_pins (user_id, pin_hash, pepper_version, pin_length, changed_at) VALUES ($1, $2, $3, $4, now())`,
        [s.userId, h.pinHash, h.pepperVersion, h.pinLength],
      );
      const token = (
        await jwt.signAccess({
          sub: s.userId,
          kind,
          roles: [role as RoleCode] as never,
          permissionsVersion: 1,
          deviceId: s.deviceKey,
          sid: s.session.id,
        })
      ).token;
      actors[role] = { token, deviceKey: s.deviceKey };
    }
  });

  afterAll(async () => {
    await app?.close();
    await fdb.stop();
  });

  const grants = (role: Role) => catalog.effectivePermissions({ roles: [role as RoleCode], status: 'active' } as never);
  const holdsAny = (role: Role, codes: readonly string[]) => codes.some((c) => grants(role).has(c as never));
  const key = (o: { method: string; path: string }) => `${o.method.toUpperCase()} ${o.path}`;

  it('T-SEC-018: у каждого маршрута объявлена политика; коды маршрута ⊆ x-permissions контракта', () => {
    expect(routes.length).toBeGreaterThan(40);
    const undeclared = routes.filter(
      (r) => !r.isPublic && (!r.requirement || requirementCodes(r.requirement).length === 0),
    );
    expect(undeclared.map((r) => `${key(r)} (${r.handler})`)).toEqual([]);
    const byKey = new Map(ops.map((o) => [key(o), o]));
    const problems: string[] = [];
    for (const r of routes) {
      const op = byKey.get(key(r));
      if (!op) continue; // служебные маршруты вне контракта API (health, openapi) — проверены выше
      if (r.isPublic) {
        if (op.permissions.length > 0 && !IN_HANDLER_PERMISSION.has(key(r)))
          problems.push(`${key(r)}: @Public, а контракт требует ${op.permissions.join(',')}`);
        continue;
      }
      if (op.permissions.length === 0) problems.push(`${key(r)}: контракт публичный, а маршрут требует права`);
      for (const c of r.requirement ? requirementCodes(r.requirement) : []) {
        if (!op.permissions.includes(c))
          problems.push(`${key(r)}: код ${c} вне x-permissions ${op.permissions.join(',')}`);
      }
    }
    expect(problems).toEqual([]);
    // все операции этапа D реализованы
    const implemented = new Set(routes.map(key));
    const missing = ops.filter((o) => STAGE_D.test(o.path) && !implemented.has(key(o))).map(key);
    // этап E: все операции контракта реализованы с теми же путями и методами (интеграция этапа E)
    const missingE = ops.filter((o) => STAGE_E.test(o.path) && !implemented.has(key(o))).map(key);
    const stageE = ops.filter((o) => STAGE_E.test(o.path)).length;
    console.error(
      `[RBAC] маршрутов ${routes.length}; операций контракта ${ops.length}; этапа D не реализованы: ${missing.join(', ') || '—'}; этапа E: ${stageE} операций, не реализованы: ${missingE.join(', ') || '—'}`,
    );
    expect(stageE).toBe(25);
    expect(missingE).toEqual([]);
    // этап F: все операции контракта этапа F реализованы с теми же путями и методами (интеграция этапа F)
    const stageF = ops.filter((o) => STAGE_F.test(o.path));
    const missingF = stageF.filter((o) => !implemented.has(key(o))).map(key);
    console.error(
      `[RBAC] этап F: ${stageF.length} операций контракта, не реализованы: ${missingF.join(', ') || '—'} (ожидаемо: G/R2)`,
    );
    expect(stageF.length).toBe(34);
    expect(missingF.sort()).toEqual([...STAGE_F_NOT_IN_F].sort());
    // вебхук банка в R1 не регистрируется (RM-F-014 — R2)
    expect(routes.filter((r) => r.path.startsWith('/payments/qr'))).toEqual([]);
    // маршрутов этапа F вне контракта нет
    const contractKeys = new Set(ops.map(key));
    const extraF = routes.filter((r) => STAGE_F.test(r.path) && !contractKeys.has(key(r))).map(key);
    expect(extraF).toEqual([]);
    // этап G: все операции контракта 1.2.0 этапа G реализованы с теми же путями и методами; лишних маршрутов нет
    const stageG = ops.filter((o) => STAGE_G.test(o.path));
    const missingG = stageG.filter((o) => !implemented.has(key(o))).map(key);
    console.error(`[RBAC] этап G: ${stageG.length} операций контракта, не реализованы: ${missingG.join(', ') || '—'}`);
    expect(stageG.length).toBe(26);
    expect(missingG).toEqual([]);
    const extraG = routes.filter((r) => STAGE_G.test(r.path) && !contractKeys.has(key(r))).map(key);
    expect(extraG).toEqual([]);
    // дорожка TAB: все 10 операций планшета магазина (OpenAPI 1.3.0) реализованы; лишних маршрутов нет
    const stageK = ops.filter((o) => STAGE_K.test(o.path));
    const missingK = stageK.filter((o) => !implemented.has(key(o))).map(key);
    console.error(
      `[RBAC] дорожка TAB: ${stageK.length} операций контракта, не реализованы: ${missingK.join(', ') || '—'}`,
    );
    expect(stageK.length).toBe(10);
    expect(missingK).toEqual([]);
    expect(routes.filter((r) => STAGE_K.test(r.path) && !contractKeys.has(key(r))).map(key)).toEqual([]);
    // маршрутов приложения вне контракта нет (кроме перечня ROUTES_OUTSIDE_CONTRACT)
    expect(routes.filter((r) => !contractKeys.has(key(r)) && !ROUTES_OUTSIDE_CONTRACT.has(key(r))).map(key)).toEqual(
      [],
    );
  });

  it('T-SEC-019 (статически, весь контракт): x-roles ⇔ права permissions.yaml; owner/admin без кассовых операций', () => {
    const problems: string[] = [];
    let cells = 0;
    for (const op of ops) {
      if (op.permissions.length === 0) continue;
      for (const role of ROLES) {
        cells += 1;
        const has = ALL_CODES_REQUIRED.has(key(op))
          ? op.permissions.every((c) => grants(role).has(c as never))
          : holdsAny(role, op.permissions);
        const listed = op.roles.includes(role);
        if (listed && !has) problems.push(`${key(op)} × ${role}: в x-roles, но прав нет`);
        if (!listed && has && !OBJECT_LEVEL_NARROWING.has(key(op))) {
          problems.push(`${key(op)} × ${role}: вне x-roles, но право выдано`);
        }
      }
    }
    expect(problems).toEqual([]);
    const cashierOps = ops.filter(
      (o) => o.roles.includes('cashier') && !o.roles.includes('admin') && !o.roles.includes('owner'),
    );
    expect(cashierOps.map(key).sort()).toEqual(
      [
        'POST /orders/{id}/payments',
        'POST /payments',
        'POST /payments/{id}/confirm-manual',
        'POST /payments/{id}/void',
        // Песочница банка (ADR-123; только тестовый контур, BANK_QR_ADAPTER=sandbox) — право payment.qr.confirm_manual.
        'POST /sandbox/bank/qr/{reference}/pay',
      ].sort(),
    );
    for (const op of cashierOps) {
      expect(holdsAny('admin', op.permissions), `${key(op)} × admin`).toBe(false);
      expect(holdsAny('owner', op.permissions), `${key(op)} × owner`).toBe(false);
    }
    expect(cells).toBeGreaterThan(600);
  });

  it('HTTP: каждая реализованная операция этапов D, E, F и G (и дорожки TAB) × 6 ролей — вне x-roles 403 FORBIDDEN, в x-roles нет отказа RbacGuard, без 5xx', async () => {
    const implemented = new Map(routes.map((r) => [key(r), r]));
    // `/auth/logout` завершает сессию — последней
    const targets = ops
      .filter(
        (o) =>
          (STAGE_D.test(o.path) ||
            STAGE_E.test(o.path) ||
            STAGE_F.test(o.path) ||
            STAGE_G.test(o.path) ||
            STAGE_K.test(o.path)) &&
          o.permissions.length > 0 &&
          implemented.has(key(o)),
      )
      .sort((a, b) => Number(a.path === '/auth/logout') - Number(b.path === '/auth/logout'));
    expect(targets.length).toBeGreaterThan(50);
    const matrix: string[] = [];
    const problems: string[] = [];
    for (const op of targets) {
      const path = `/api/v1${op.path.replace(/\{[A-Za-z]+\}/g, () => randomUUID())}`;
      for (const role of ROLES) {
        const a = actors[role];
        let r = request(app.getHttpServer())
          [op.method](path)
          .set('Authorization', `Bearer ${a.token}`)
          .set('X-Device-Id', a.deviceKey)
          .set('X-App-Version', '99.0.0')
          .set('X-Platform', 'android');
        if (op.method !== 'get') r = r.set('Idempotency-Key', randomUUID());
        const res = await r.send({});
        const body = res.body as { code?: string; reason?: string };
        const cell = `${op.operationId} × ${role}: ${res.status} ${body.code ?? ''}${body.reason ? `/${body.reason}` : ''}`;
        matrix.push(cell);
        const rbacDenied = res.status === 403 && body.code === 'FORBIDDEN' && body.reason === undefined;
        if (res.status >= 500) {
          problems.push(`${cell} — ошибка сервера`);
        }
        if (op.roles.includes(role)) {
          const objectDenied = role === 'customer' && CUSTOMER_LINK_REQUIRED.has(key(op)) && res.status === 403;
          if ((rbacDenied && !objectDenied) || res.status === 401) problems.push(`${cell} — ожидался доступ`);
        } else if (!(res.status === 403 && body.code === 'FORBIDDEN')) {
          problems.push(`${cell} — ожидался 403 FORBIDDEN`);
        }
      }
    }
    console.error(`[RBAC] HTTP-матрица: ${targets.length} операций × ${ROLES.length} ролей = ${matrix.length} ячеек`);
    // все операции этапа G и дорожки TAB — в HTTP-матрице (`/kiosk/*` 6 ролям — 403: только kind=kiosk, T-KIOSK-005 (2))
    expect(targets.filter((o) => STAGE_G.test(o.path))).toHaveLength(26);
    expect(targets.filter((o) => STAGE_K.test(o.path))).toHaveLength(10);
    expect(problems).toEqual([]);
    expect(matrix).toHaveLength(targets.length * ROLES.length);
  });
});

/** Коды, которые засчитываются только при `kind=kiosk` (11 SEC-138; `KIND_BOUND_PERMISSIONS`). */
const KIOSK_KIND_CODES = ['kiosk.order.submit', 'kiosk.self.read', 'kiosk.self.exit'] as const;

/** Маршрут списка отвечает планшету `403`, как покупателю (08 AC-API-186): справочник видов цен не отдаётся. */
const KIOSK_LIST_FORBIDDEN_AS_CUSTOMER = 'GET /catalog/price-lists';

describe('RBAC: колонка kiosk — планшет магазина (T-KIOSK-005 (1)(2), T-SEC-069; SEC-046, SEC-137, SEC-138)', () => {
  const t = new KioskE2eApp();
  const ops = contractOps();
  const closed = new Set<string>(KIOSK_CLOSED_LIST);
  let routes: Route[];
  let catalog: PermissionCatalog;
  let tablet: Tablet;
  let v: SaleableVariant[];
  const others = {} as Record<Role, Subject>;
  const key = (o: { method: string; path: string }) => `${o.method.toUpperCase()} ${o.path}`;
  const cell = (r: Res) => `${r.status} ${r.body.code ?? ''}${r.body.reason ? `/${r.body.reason}` : ''}`;

  beforeAll(async () => {
    // Каталог (синтетика конвейером 1С), KIOSK_MODE=true; планшет — настоящим подключением с устройства администратора.
    await t.start('rbac_kiosk_e2e', { LOG_LEVEL: 'silent' }, 20);
    routes = discoverRoutes(t.app);
    catalog = t.app.get(PermissionCatalog);
    tablet = await t.enroll({ name: 'Планшет у входа' });
    v = await t.saleableVariants(2);
    for (const role of ROLES) others[role] = await t.subject(role);
  });

  afterAll(async () => {
    await t.stop();
  });

  const kioskGrants = () =>
    catalog.effectivePermissions({ roles: ['kiosk'], status: 'active', kind: 'kiosk' } as never);

  it('T-SEC-069 (статически): x-roles ∋ kiosk ⇔ закрытый список; коды списка у роли kiosk; kiosk.* — только при kind=kiosk', () => {
    // Закрытый список = операции контракта с kiosk в x-roles + GET /catalog/price-lists (в списке, ответ 403).
    const listed = ops.filter((o) => o.roles.includes('kiosk')).map(key);
    expect([...listed, KIOSK_LIST_FORBIDDEN_AS_CUSTOMER].sort()).toEqual([...KIOSK_CLOSED_LIST].sort());
    expect(KIOSK_CLOSED_LIST).toHaveLength(23);
    // Публичных операций в списке нет: список сужает только маршруты с Bearer.
    expect(ops.filter((o) => o.isPublic && closed.has(key(o))).map(key)).toEqual([]);
    // Роль kiosk (kind=kiosk) держит право каждой операции списка; «все коды» — где контракт требует И.
    const g = kioskGrants();
    const problems: string[] = [];
    for (const op of ops.filter((o) => o.roles.includes('kiosk'))) {
      const has = ALL_CODES_REQUIRED.has(key(op))
        ? op.permissions.every((c) => g.has(c as never))
        : op.permissions.some((c) => g.has(c as never));
      if (!has) problems.push(`${key(op)}: роль kiosk без права ${op.permissions.join(',')}`);
    }
    expect(problems).toEqual([]);
    // Коды kind=kiosk — только в x-permissions операций списка и засчитываются только при kind=kiosk (SEC-138).
    const kindBound = ops.filter((o) => o.permissions.some((c) => (KIOSK_KIND_CODES as readonly string[]).includes(c)));
    expect(kindBound.filter((o) => !closed.has(key(o))).map(key)).toEqual([]);
    for (const kind of ['staff', 'customer', undefined] as const) {
      const set = catalog.effectivePermissions({
        roles: ['kiosk'],
        status: 'active',
        ...(kind ? { kind } : {}),
      } as never);
      expect(
        KIOSK_KIND_CODES.filter((c) => set.has(c as never)),
        String(kind),
      ).toEqual([]);
    }
    expect(KIOSK_KIND_CODES.filter((c) => !g.has(c as never))).toEqual([]);
    // Прежние роли кодов kind=kiosk не держат ни при каком виде (паритет 7 ролей).
    for (const role of [...ROLES, 'integration'] as const) {
      const set = catalog.effectivePermissions({ roles: [role], status: 'active', kind: 'kiosk' } as never);
      expect(
        KIOSK_KIND_CODES.filter((c) => set.has(c as never)),
        role,
      ).toEqual([]);
    }
    // Управление планшетами — не планшету: /admin/store-tablets* вне x-roles kiosk.
    expect(ops.filter((o) => o.path.startsWith('/admin/store-tablets') && o.roles.includes('kiosk')).map(key)).toEqual(
      [],
    );
  });

  it('T-KIOSK-005 (2): /kiosk/* токенами сотрудников и покупателя → 403 FORBIDDEN (нет права kind=kiosk)', async () => {
    const kioskOps = ops.filter((o) => o.path.startsWith('/kiosk/'));
    expect(kioskOps.map(key).sort()).toEqual(
      [
        'GET /kiosk/orders',
        'POST /kiosk/exit',
        'POST /kiosk/order-otp',
        'POST /kiosk/orders',
        'POST /kiosk/reset',
      ].sort(),
    );
    const problems: string[] = [];
    for (const op of kioskOps) {
      for (const role of ROLES) {
        const r = await t.call(op.method, op.path, others[role], {
          ...(op.method === 'get' ? {} : { body: {}, idem: true }),
        });
        if (!(r.status === 403 && r.body.code === 'FORBIDDEN' && r.body.reason === undefined)) {
          problems.push(`${key(op)} × ${role}: ${cell(r)}`);
        }
      }
    }
    expect(problems).toEqual([]);
  });

  it('T-KIOSK-005 (1), T-SEC-069 kiosk column closed list: каждая Bearer-операция контракта вне списка → 403 kiosk_closed_list или 404', async () => {
    const registered = new Set(routes.map(key));
    // `/auth/logout` вне списка — тоже 403: сессия планшета не завершается (проверка ниже).
    const outside = ops.filter((o) => !o.isPublic && !closed.has(key(o)));
    expect(outside.length).toBeGreaterThan(100);
    const problems: string[] = [];
    const matrix: string[] = [];
    for (const op of outside) {
      const path = op.path.replace(/\{[A-Za-z]+\}/g, () => randomUUID());
      const r = await t.call(op.method, path, tablet, { ...(op.method === 'get' ? {} : { body: {}, idem: true }) });
      matrix.push(`${op.operationId} × kiosk: ${cell(r)}`);
      const closedListDenied = r.status === 403 && r.body.code === 'FORBIDDEN' && r.body.reason === 'kiosk_closed_list';
      if (registered.has(key(op)) && !IN_HANDLER_PERMISSION.has(key(op))) {
        if (!closedListDenied) problems.push(`${key(op)}: ${cell(r)} — ожидался 403 FORBIDDEN kiosk_closed_list`);
      } else if (r.status !== 404) {
        problems.push(`${key(op)}: ${cell(r)} — маршрут не отвечает планшету, ожидался 404`);
      }
    }
    console.error(`[RBAC] колонка kiosk: ${outside.length} операций вне закрытого списка проверены токеном планшета`);
    expect(problems).toEqual([]);
    expect(matrix).toHaveLength(outside.length);
    // Сессия планшета жива: ни `POST /auth/logout`, ни `/auth/sessions*` её не тронули.
    expect((await t.call('get', '/me', tablet)).status).toBe(200);
  });

  it('T-KIOSK-005 (1), T-SEC-069 kiosk column closed list: каждый маршрут списка — 2xx по своему праву; GET /catalog/price-lists — 403, как у customer', async () => {
    const seen = new Map<string, Res>();
    const at = async (k: string, path: string, body?: unknown, idem?: string | true): Promise<Res> => {
      const [m] = k.split(' ');
      const r = await t.call(m.toLowerCase() as Method, path, tablet, {
        ...(body !== undefined ? { body } : {}),
        ...(idem ? { idem } : {}),
      });
      seen.set(k, r);
      return r;
    };
    const q = encodeURIComponent(v[0].productName.slice(0, 4));
    await at('GET /settings/public', '/settings/public');
    const me = await at('GET /me', '/me');
    expect(Object.keys(me.body).sort()).toEqual(['kind', 'tablet']);
    await at('GET /catalog/categories', '/catalog/categories');
    await at('GET /catalog/price-lists', '/catalog/price-lists');
    await at('GET /catalog/products', '/catalog/products?limit=20');
    await at('GET /catalog/products/{id}', `/catalog/products/${v[0].productId}`);
    await at('GET /catalog/products/{id}/variants', `/catalog/products/${v[0].productId}/variants`);
    await at('GET /catalog/units', '/catalog/units');
    await at('GET /catalog/warehouses', '/catalog/warehouses');
    await at('GET /catalog/sync/{entity}', '/catalog/sync/units');
    await at('GET /search/products', `/search/products?q=${q}`);
    await at('GET /search/suggest', `/search/suggest?q=${q}`);
    await at('GET /inventory/balances', `/inventory/balances?variantIds=${v[0].variantId}`);
    await at('POST /inventory/check', '/inventory/check', {
      warehouseId: tablet.warehouseId,
      items: [{ variantId: v[0].variantId, quantity: { value: '1', unitId: v[0].unitId, packagingId: null } }],
    });
    const c0 = await at('GET /cart', '/cart');
    const put = await at('PUT /cart/items/{variantId}', `/cart/items/${v[1].variantId}`, {
      quantity: { value: '1', unitId: v[1].unitId, packagingId: null },
      rowVersion: c0.body.rowVersion as number,
    });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    await at('DELETE /cart/items/{variantId}', `/cart/items/${v[1].variantId}`);
    await t.putItem(tablet, v[0]);
    const c1 = await t.call('get', '/cart', tablet);
    const preview = await at('POST /cart/checkout-preview', '/cart/checkout-preview', {
      cartId: c1.body.id,
      cartRowVersion: c1.body.rowVersion,
      paymentMethod: 'cash',
      delivery: { method: 'pickup' },
      receiver: { kind: 'customer' },
    });
    const otp = await at('POST /kiosk/order-otp', '/kiosk/order-otp', {
      phone: '+996555008201',
      cartId: c1.body.id,
      noticeVersion: '2026-11-04',
    });
    const orderKey = randomUUID();
    await at(
      'POST /kiosk/orders',
      '/kiosk/orders',
      {
        challengeId: otp.body.challengeId,
        code: '246810',
        cartId: preview.body.cartId,
        cartRowVersion: preview.body.cartRowVersion,
        previewToken: preview.body.previewToken,
      },
      orderKey,
    );
    await at('GET /kiosk/orders', `/kiosk/orders?idempotencyKey=${orderKey}`);
    const c2 = await t.call('get', '/cart', tablet);
    await at('POST /kiosk/reset', '/kiosk/reset', { cartId: c2.body.id }, true);
    // Аварийный выход — последним: он завершает сессию планшета.
    await at('POST /kiosk/exit', '/kiosk/exit', { code: tablet.exitCode });

    expect([...seen.keys()].sort()).toEqual([...KIOSK_CLOSED_LIST].sort());
    const problems: string[] = [];
    for (const [k, r] of seen) {
      if (k === KIOSK_LIST_FORBIDDEN_AS_CUSTOMER) continue;
      if (r.status < 200 || r.status >= 300) problems.push(`${k}: ${cell(r)} ${JSON.stringify(r.body).slice(0, 200)}`);
    }
    expect(problems).toEqual([]);
    // GET /catalog/price-lists — ответ планшету тот же, что покупателю: 403 по правилу покупателя, не закрытый список.
    const pl = seen.get(KIOSK_LIST_FORBIDDEN_AS_CUSTOMER) as Res;
    const asCustomer = await t.call('get', '/catalog/price-lists', others.customer);
    expect(pl.status).toBe(403);
    expect(pl.body.reason).not.toBe('kiosk_closed_list');
    expect(cell(pl)).toBe(cell(asCustomer));
  });
});
