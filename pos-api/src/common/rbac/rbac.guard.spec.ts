import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Controller, Get, Post } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import request from 'supertest';
import { parse } from 'yaml';
import { createTestApp, LogCapture } from '../../../test/support/test-app.js';
import { KIND_BOUND_PERMISSIONS, PermissionCatalog } from './permission-catalog.js';
import {
  PERMISSION_CODES,
  type PermissionCode,
  PERMISSIONS,
  PSEUDO_SETS,
  RBAC_ROLES,
  ROLE_GRANTS,
} from './permissions.generated.js';
import {
  type PermissionRequirement,
  Public,
  RequireAnyPermission,
  RequirePermission,
  RequirePermissionGroups,
  requirementCodes,
} from './rbac.decorators.js';
import { requirementSatisfied } from './rbac.guard.js';

@Controller()
class ProbeController {
  @Public()
  @Get('public')
  open() {
    return { ok: true };
  }

  @Get('no-policy')
  noPolicy() {
    return { leaked: true };
  }

  @RequirePermission('order.create')
  @Post('orders')
  create() {
    return { ok: true };
  }

  @RequireAnyPermission('order.read.own', 'order.read.all')
  @Get('orders')
  list() {
    return { ok: true };
  }

  @RequirePermission('users.manage', 'users.roles.assign')
  @Post('admin/users')
  adminCreate() {
    return { ok: true };
  }

  @RequirePermission('profile.manage.own')
  @Get('me')
  me() {
    return { ok: true };
  }

  /** Форма «И из ИЛИ» как у `POST /cart/checkout-preview` (ADR-115; 11 SEC-138). */
  @RequirePermissionGroups(['cart.manage.own'], ['order.create', 'kiosk.order.submit'])
  @Post('cart/checkout-preview')
  preview() {
    return { ok: true };
  }

  /** Одно из `profile.manage.own` | `kiosk.self.read`, как у `GET /me` (11 §4.3.1). */
  @RequireAnyPermission('profile.manage.own', 'kiosk.self.read')
  @Get('me-any')
  meAny() {
    return { ok: true };
  }

  @RequirePermission('kiosk.order.submit')
  @Post('kiosk/orders')
  kioskOrder() {
    return { ok: true };
  }
}

const USER_ID = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55';
const user = (roles: string[], status?: 'active' | 'pending_activation') =>
  JSON.stringify({ userId: USER_ID, kind: 'staff', roles, status });
/** Субъект с заданным видом; `kind: undefined` — поля нет в `x-test-principal`. */
const subject = (kind: string | undefined, roles: string[]) => JSON.stringify({ userId: USER_ID, kind, roles });

describe('RbacGuard (deny by default, permissions.yaml)', () => {
  let app: NestExpressApplication;
  const logs = new LogCapture();

  beforeAll(async () => {
    app = await createTestApp({ controllers: [ProbeController], logStream: logs });
  });

  afterAll(async () => {
    await app.close();
  });

  it('@Public() — без субъекта 200', async () => {
    expect((await request(app.getHttpServer()).get('/api/v1/public')).status).toBe(200);
  });

  it('маршрут без политики → 403 FORBIDDEN даже для owner (deny by default)', async () => {
    const res = await request(app.getHttpServer())
      .get('/api/v1/no-policy')
      .set('x-test-principal', user(['owner']));
    expect(res.status).toBe(403);
    expect(res.body.code).toBe('FORBIDDEN');
    expect(logs.text).toContain('authz.denied');
  });

  it('C-MN-02: маршрут без политики и без субъекта → 401 (401 приоритетнее 403, 08 §2.4)', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/no-policy');
    expect(res.status).toBe(401);
    expect(res.body.code).toBe('UNAUTHENTICATED');
  });

  it('нет субъекта → 401 UNAUTHENTICATED', async () => {
    const res = await request(app.getHttpServer()).post('/api/v1/orders').send({});
    expect(res.status).toBe(401);
    expect(res.body.code).toBe('UNAUTHENTICATED');
  });

  it('seller: order.create есть → 201; users.manage нет → 403', async () => {
    const http = request(app.getHttpServer());
    expect(
      (
        await http
          .post('/api/v1/orders')
          .set('x-test-principal', user(['seller']))
          .send({})
      ).status,
    ).toBe(201);
    const denied = await http
      .post('/api/v1/admin/users')
      .set('x-test-principal', user(['seller']))
      .send({});
    expect(denied.status).toBe(403);
    expect(denied.body.code).toBe('FORBIDDEN');
  });

  it('RequireAnyPermission: cashier (order.read.all) и seller (order.read.own) проходят; integration — нет', async () => {
    const http = request(app.getHttpServer());
    expect((await http.get('/api/v1/orders').set('x-test-principal', user(['cashier']))).status).toBe(200);
    expect((await http.get('/api/v1/orders').set('x-test-principal', user(['seller']))).status).toBe(200);
    expect((await http.get('/api/v1/orders').set('x-test-principal', user(['integration']))).status).toBe(403);
  });

  it('неизвестная роль не даёт прав; pending_activation — только псевдо-набор 11 §4.2', async () => {
    const http = request(app.getHttpServer());
    expect(
      (
        await http
          .post('/api/v1/orders')
          .set('x-test-principal', user(['superuser']))
          .send({})
      ).status,
    ).toBe(403);
    expect((await http.get('/api/v1/me').set('x-test-principal', user(['seller'], 'pending_activation'))).status).toBe(
      200,
    );
    expect(
      (
        await http
          .post('/api/v1/orders')
          .set('x-test-principal', user(['seller'], 'pending_activation'))
          .send({})
      ).status,
    ).toBe(403);
  });

  it('«И из ИЛИ» (ADR-115): checkout-preview — seller и customer по order.create, планшет по kiosk.order.submit; owner и integration — 403', async () => {
    const http = request(app.getHttpServer());
    const preview = (who: string) => http.post('/api/v1/cart/checkout-preview').set('x-test-principal', who).send({});
    expect((await preview(subject('staff', ['seller']))).status).toBe(201);
    expect((await preview(subject('staff', ['cashier']))).status).toBe(201);
    expect((await preview(subject('customer', ['customer']))).status).toBe(201);
    expect((await preview(subject('kiosk', ['kiosk']))).status).toBe(201);
    // owner: нет cart.manage.own (первая группа); integration — ни одной группы
    const owner = await preview(subject('staff', ['owner']));
    expect(owner.status).toBe(403);
    expect(owner.body.code).toBe('FORBIDDEN');
    expect((await preview(subject('staff', ['integration']))).status).toBe(403);
  });

  it('SEC-138: коды kiosk.* засчитываются только при kind=kiosk — роль kiosk с другим видом или без вида их не даёт', async () => {
    const http = request(app.getHttpServer());
    const kioskOrder = (who: string) => http.post('/api/v1/kiosk/orders').set('x-test-principal', who).send({});
    const meAny = (who: string) => http.get('/api/v1/me-any').set('x-test-principal', who);
    expect((await kioskOrder(subject('kiosk', ['kiosk']))).status).toBe(201);
    expect((await meAny(subject('kiosk', ['kiosk']))).status).toBe(200);
    for (const kind of ['staff', 'customer', 'integration', undefined]) {
      const who = subject(kind, ['kiosk']);
      expect((await kioskOrder(who)).status, `kind=${String(kind)}`).toBe(403);
      expect((await meAny(who)).status, `kind=${String(kind)}`).toBe(403);
      // cart.manage.own у роли есть, но вторая группа держится только на kiosk.order.submit
      const preview = await http.post('/api/v1/cart/checkout-preview').set('x-test-principal', who).send({});
      expect(preview.status, `kind=${String(kind)}`).toBe(403);
    }
    // seller и customer: GET /me-any по profile.manage.own — как прежде; kind=kiosk без роли kiosk кодов не даёт
    expect((await meAny(subject('staff', ['seller']))).status).toBe(200);
    expect((await meAny(subject('customer', ['customer']))).status).toBe(200);
    expect((await kioskOrder(subject('kiosk', ['seller']))).status).toBe(403);
    // у роли kiosk нет profile.manage.own и order.create (11 §4.2)
    expect((await http.get('/api/v1/me').set('x-test-principal', subject('kiosk', ['kiosk']))).status).toBe(403);
    const order = await http
      .post('/api/v1/orders')
      .set('x-test-principal', subject('kiosk', ['kiosk']))
      .send({});
    expect(order.status).toBe(403);
  });
});

describe('Требование прав «И из ИЛИ» и права, привязанные к виду субъекта (ADR-115; 11 SEC-138)', () => {
  const set = (...codes: PermissionCode[]) => new Set<PermissionCode>(codes);
  const cnf = (...groups: PermissionCode[][]): PermissionRequirement => ({ mode: 'cnf', groups });

  it('requirementSatisfied: all — все коды, any — любой, cnf — каждая группа хотя бы одним правом', () => {
    const all: PermissionRequirement = { mode: 'all', codes: ['cart.manage.own', 'order.create'] };
    const any: PermissionRequirement = { mode: 'any', codes: ['order.read.own', 'order.read.all'] };
    expect(requirementSatisfied(all, set('cart.manage.own', 'order.create'))).toBe(true);
    expect(requirementSatisfied(all, set('cart.manage.own'))).toBe(false);
    expect(requirementSatisfied(any, set('order.read.all'))).toBe(true);
    expect(requirementSatisfied(any, set('cart.manage.own'))).toBe(false);
    const preview = cnf(['cart.manage.own'], ['order.create', 'kiosk.order.submit']);
    expect(requirementSatisfied(preview, set('cart.manage.own', 'order.create'))).toBe(true);
    expect(requirementSatisfied(preview, set('cart.manage.own', 'kiosk.order.submit'))).toBe(true);
    expect(requirementSatisfied(preview, set('cart.manage.own'))).toBe(false);
    expect(requirementSatisfied(preview, set('order.create', 'kiosk.order.submit'))).toBe(false);
    expect(requirementSatisfied(preview, set())).toBe(false);
  });

  it('пустые требования не выполняются (deny by default): без кодов, cnf без групп или с пустой группой, неизвестная форма', () => {
    const everything = new Set<PermissionCode>(PERMISSION_CODES);
    expect(requirementSatisfied({ mode: 'all', codes: [] }, everything)).toBe(false);
    expect(requirementSatisfied({ mode: 'any', codes: [] }, everything)).toBe(false);
    expect(requirementSatisfied(cnf(), everything)).toBe(false);
    expect(requirementSatisfied(cnf(['cart.manage.own'], []), everything)).toBe(false);
    expect(requirementSatisfied({ mode: 'xor', codes: ['cart.manage.own'] } as never, everything)).toBe(false);
  });

  it('RequirePermissionGroups: пустая группа — ошибка объявления; requirementCodes — все коды без повторов', () => {
    expect(() => RequirePermissionGroups([] as never)).toThrow(/пустая группа/);
    expect(() => RequirePermissionGroups(['cart.manage.own'], [] as never)).toThrow(/пустая группа/);
    const codes = requirementCodes(cnf(['cart.manage.own'], ['order.create', 'kiosk.order.submit'], ['order.create']));
    expect(codes).toEqual(['cart.manage.own', 'order.create', 'kiosk.order.submit']);
    expect(requirementCodes({ mode: 'any', codes: ['order.read.own', 'order.read.all'] })).toEqual([
      'order.read.own',
      'order.read.all',
    ]);
  });

  it('KIND_BOUND_PERMISSIONS: коды №79–81, выдаются только роли kiosk (11 §4.3; SEC-138)', () => {
    expect(Object.entries(KIND_BOUND_PERMISSIONS)).toEqual([
      ['kiosk.order.submit', 'kiosk'],
      ['kiosk.self.read', 'kiosk'],
      ['kiosk.self.exit', 'kiosk'],
    ]);
    for (const code of Object.keys(KIND_BOUND_PERMISSIONS)) {
      expect(PERMISSION_CODES as readonly string[]).toContain(code);
      expect(RBAC_ROLES.filter((r) => (ROLE_GRANTS[r] as readonly string[]).includes(code))).toEqual(['kiosk']);
    }
  });

  it('effectivePermissions: роль kiosk — коды kiosk.* только при kind=kiosk; без вида (вызов с {roles}) — исключены', () => {
    const catalog = new PermissionCatalog();
    const bound = Object.keys(KIND_BOUND_PERMISSIONS) as PermissionCode[];
    const withKiosk = catalog.effectivePermissions({ roles: ['kiosk'], status: 'active', kind: 'kiosk' });
    expect([...withKiosk].sort()).toEqual([...ROLE_GRANTS.kiosk].sort());
    for (const kind of [undefined, 'staff', 'customer', 'integration'] as const) {
      const granted = catalog.effectivePermissions({ roles: ['kiosk'], status: 'active', kind });
      for (const code of bound) expect(granted.has(code), `${String(kind)} × ${code}`).toBe(false);
      expect([...granted].sort()).toEqual(ROLE_GRANTS.kiosk.filter((c) => !bound.includes(c)).sort());
    }
    expect([...catalog.effectivePermissions({ roles: ['kiosk'] })].some((c) => bound.includes(c))).toBe(false);
    // pending_activation — только псевдо-набор, коды kiosk.* в нём не появляются
    const pending = catalog.effectivePermissions({ roles: ['kiosk'], status: 'pending_activation', kind: 'kiosk' });
    expect([...pending].sort()).toEqual([...(PSEUDO_SETS.pending_activation ?? [])].sort());
  });

  it('effectivePermissions прежних ролей не зависит от вида субъекта (паритет staff и customer)', () => {
    const catalog = new PermissionCatalog();
    for (const role of RBAC_ROLES.filter((r) => r !== 'kiosk')) {
      const plain = [...catalog.effectivePermissions({ roles: [role] })].sort();
      for (const kind of ['staff', 'customer', 'kiosk'] as const) {
        expect([...catalog.effectivePermissions({ roles: [role], kind })].sort(), `${role} × ${kind}`).toEqual(plain);
      }
    }
  });
});

describe('permissions.generated.ts ↔ contracts/rbac/permissions.yaml', () => {
  const yaml = parse(
    readFileSync(fileURLToPath(new URL('../../../../contracts/rbac/permissions.yaml', import.meta.url)), 'utf8'),
  ) as {
    roles: { code: string }[];
    permissions: { code: string; step_up: boolean; reserved?: boolean }[];
    grants: Record<string, string[]>;
    pseudo_sets: Record<string, string[]>;
  };

  it('совпадают роли, коды, step-up, grants и псевдо-наборы', () => {
    expect([...RBAC_ROLES]).toEqual(yaml.roles.map((r) => r.code));
    expect([...PERMISSION_CODES]).toEqual(yaml.permissions.map((p) => p.code));
    expect(PERMISSIONS.map((p) => [p.code, p.stepUp, p.reserved])).toEqual(
      yaml.permissions.map((p) => [p.code, Boolean(p.step_up), Boolean(p.reserved)]),
    );
    for (const role of RBAC_ROLES) expect([...ROLE_GRANTS[role]]).toEqual(yaml.grants[role] ?? []);
    expect(PSEUDO_SETS).toEqual(yaml.pseudo_sets);
  });

  it('зарезервированные коды (R2) никому не выдаются', () => {
    const catalog = new PermissionCatalog();
    const reserved = PERMISSIONS.filter((p) => p.reserved).map((p) => p.code);
    for (const role of RBAC_ROLES) {
      const granted = catalog.effectivePermissions({ roles: [role] });
      for (const code of reserved) expect(granted.has(code)).toBe(false);
    }
  });
});
