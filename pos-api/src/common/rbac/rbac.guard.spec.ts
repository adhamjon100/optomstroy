import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Controller, Get, Post } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import request from 'supertest';
import { parse } from 'yaml';
import { createTestApp, LogCapture } from '../../../test/support/test-app.js';
import { PermissionCatalog } from './permission-catalog.js';
import { PERMISSION_CODES, PERMISSIONS, PSEUDO_SETS, RBAC_ROLES, ROLE_GRANTS } from './permissions.generated.js';
import { Public, RequireAnyPermission, RequirePermission } from './rbac.decorators.js';

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
}

const user = (roles: string[], status?: 'active' | 'pending_activation') =>
  JSON.stringify({ userId: '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55', kind: 'staff', roles, status });

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
