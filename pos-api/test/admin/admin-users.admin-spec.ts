import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { parse } from 'yaml';
import { PinHasher } from '../../src/common/crypto/pin-hasher.service.js';
import { UsersRepository } from '../../src/users/users.repository.js';
import { testPhone } from '../foundation/support/foundation-db.js';
import { type Actor, AdminTestApp } from './support/admin-app.js';

const ROLES = ['seller', 'cashier', 'senior_seller', 'admin', 'owner', 'customer'] as const;

interface ContractOp {
  readonly method: 'get' | 'post' | 'put' | 'patch' | 'delete';
  readonly path: string;
  readonly operationId: string;
  readonly roles: readonly string[];
  readonly stepUp: boolean;
}

/** Операции `/admin/users*` и `/admin/invitations*` из contracts/openapi/pos-api.v1.yaml (x-roles, x-step-up). */
function contractOps(): ContractOp[] {
  const file = fileURLToPath(new URL('../../../contracts/openapi/pos-api.v1.yaml', import.meta.url));
  const doc = parse(readFileSync(file, 'utf8')) as {
    paths: Record<string, Record<string, { operationId?: string; 'x-roles'?: string[]; 'x-step-up'?: boolean }>>;
  };
  const out: ContractOp[] = [];
  for (const [path, ops] of Object.entries(doc.paths)) {
    if (!/^\/admin\/(users|invitations)/.test(path)) continue;
    for (const [method, op] of Object.entries(ops)) {
      if (!op?.operationId) continue;
      out.push({
        method: method as ContractOp['method'],
        path,
        operationId: op.operationId,
        roles: op['x-roles'] ?? [],
        stepUp: op['x-step-up'] === true,
      });
    }
  }
  return out;
}

interface ContractDoc {
  paths: Record<
    string,
    Record<
      string,
      {
        operationId?: string;
        responses?: Record<
          string,
          { headers?: Record<string, unknown>; content?: Record<string, { schema?: { oneOf?: { $ref: string }[] } }> }
        >;
      }
    >
  >;
  components: { schemas: Record<string, { required?: string[]; properties?: Record<string, unknown> }> };
}

function contractDoc(): ContractDoc {
  const file = fileURLToPath(new URL('../../../contracts/openapi/pos-api.v1.yaml', import.meta.url));
  return parse(readFileSync(file, 'utf8')) as ContractDoc;
}

/** Ответ 201 операции: имена схем `oneOf` и заголовки. */
function contractSchemaOf(operationId: string): { oneOf: string[]; headers: string[] } {
  for (const ops of Object.values(contractDoc().paths)) {
    for (const op of Object.values(ops)) {
      if (op?.operationId !== operationId) continue;
      const created = op.responses?.['201'];
      const oneOf = created?.content?.['application/json']?.schema?.oneOf ?? [];
      return { oneOf: oneOf.map((s) => s.$ref.split('/').pop() ?? ''), headers: Object.keys(created?.headers ?? {}) };
    }
  }
  throw new Error(`операция ${operationId} не найдена в контракте`);
}

function contractSchemaProps(name: string): { required: string[]; properties: string[] } {
  const s = contractDoc().components.schemas[name];
  return { required: s?.required ?? [], properties: Object.keys(s?.properties ?? {}) };
}

describe('admin/users + admin/invitations: RBAC, step-up, политика целей, аудит (RM-D-006; 08 §4.18)', () => {
  const t = new AdminTestApp();
  const actors = {} as Record<(typeof ROLES)[number], Actor>;

  beforeAll(async () => {
    await t.start('admin_users_e2e');
    for (const r of ROLES) actors[r] = await t.actor(r);
  });

  afterAll(async () => {
    await t.stop();
  });

  const admin = () => actors.admin;
  const owner = () => actors.owner;

  // ------------------------------------------------------------------------------------------------------------
  it('T-SEC-016: матрица endpoint × роль из контракта (x-roles): вне перечня — 403 FORBIDDEN, в перечне — не FORBIDDEN (deny by default)', async () => {
    const ops = contractOps();
    expect(ops.map((o) => o.operationId).sort()).toEqual(
      [
        'admin_invitations_create',
        'admin_invitations_list',
        'admin_invitations_revoke',
        'admin_users_block',
        'admin_users_create',
        'admin_users_emergency_login_code_issue',
        'admin_users_get',
        'admin_users_list',
        'admin_users_logout_all',
        'admin_users_pin_reset',
        'admin_users_roles_set',
        'admin_users_update',
      ].sort(),
    );
    const target = await t.actor('seller');
    const matrix: string[] = [];
    for (const op of ops) {
      const path = op.path.replace('{id}', op.path.startsWith('/admin/invitations') ? randomUUID() : target.userId);
      for (const role of ROLES) {
        const r = await t
          .req(op.method, path, actors[role], { idem: op.method === 'post' ? true : undefined })
          .send({});
        const allowed = op.roles.includes(role);
        const cell = `${op.operationId} × ${role}: ${r.status} ${r.body?.code ?? ''}`;
        matrix.push(cell);
        if (allowed) {
          expect(r.body?.code, cell).not.toBe('FORBIDDEN');
          if (op.stepUp) expect(r.body?.code, cell).toBe('STEP_UP_REQUIRED');
          else expect(r.status, cell).toBe(200);
        } else {
          expect(r.status, cell).toBe(403);
          expect(r.body.code, cell).toBe('FORBIDDEN');
        }
      }
    }
    // owner и admin не получают кассовых прав здесь не проверяются (вне маршрутов модуля); матрица — в логе теста
    expect(matrix.length).toBe(ops.length * ROLES.length);
  });

  it('без Bearer → 401 UNAUTHENTICATED раньше 403', async () => {
    const r = await t.req('get', '/admin/users');
    expect(r.status).toBe(401);
    expect(r.body.code).toBe('UNAUTHENTICATED');
  });

  // ------------------------------------------------------------------------------------------------------------
  describe('step-up (08 §2.12; RM-D-006 критерий 2)', () => {
    it('T-SEC-020: смена роли и создание приглашения без step-up → 403 STEP_UP_REQUIRED {operation, allowedMethods}', async () => {
      const target = await t.actor('seller');
      const r1 = await t
        .req('put', `/admin/users/${target.userId}/roles`, admin())
        .send({ roles: ['cashier'], reason: 'перевод на кассу', rowVersion: 1 });
      expect(r1.status).toBe(403);
      expect(r1.body).toMatchObject({
        code: 'STEP_UP_REQUIRED',
        stepUp: { operation: 'users.roles.assign', allowedMethods: ['pin', 'otp'] },
      });
      const r2 = await t
        .req('post', '/admin/invitations', admin(), { idem: true })
        .send({ phone: testPhone(), roles: ['seller'], fullName: 'Петров Пётр' });
      expect(r2.status).toBe(403);
      expect(r2.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: 'invitations.manage' } });
    });

    it('T-SEC-045: токен чужой области, чужой сессии, другого устройства, устаревшего pv, отозванный, просроченный → STEP_UP_REQUIRED', async () => {
      const target = await t.actor('seller');
      const path = `/admin/users/${target.userId}/roles`;
      const body = { roles: ['cashier'], reason: 'перевод на кассу', rowVersion: 1 };
      const other = await t.actor('admin');
      const wrongScope = await t.stepUp(admin(), 'users.manage');
      const foreignSession = await t.stepUp(other, 'users.roles.assign');
      const wrongDevice = await t.stepUp(admin(), 'users.roles.assign', 'pin', { deviceId: randomUUID() });
      const sameSubjectOtherSid = await t.stepUp(admin(), 'users.roles.assign', 'pin', { sid: randomUUID() });
      const bioMethod = await t.stepUp(admin(), 'users.roles.assign', 'pin', { method: 'bio' });
      // D-MN-01 (единая StepUpTokenVerifier): устаревший `pv`, без `deviceId`, `scope` строкой, без `method`
      const stalePv = await t.stepUp(admin(), 'users.roles.assign', 'pin', { pv: 999 });
      const noPv = await t.stepUp(admin(), 'users.roles.assign', 'pin', { pv: undefined });
      const noDevice = await t.stepUp(admin(), 'users.roles.assign', 'pin', { deviceId: undefined });
      const stringScope = await t.stepUp(admin(), 'users.roles.assign', 'pin', { scope: 'users.roles.assign' });
      const noMethod = await t.stepUp(admin(), 'users.roles.assign', 'pin', { method: undefined });
      for (const token of [
        wrongScope,
        foreignSession,
        wrongDevice,
        sameSubjectOtherSid,
        bioMethod,
        stalePv,
        noPv,
        noDevice,
        stringScope,
        noMethod,
        'garbage',
      ]) {
        const r = await t.req('put', path, admin(), { stepUp: token }).send(body);
        expect(r.status).toBe(403);
        expect(r.body.code).toBe('STEP_UP_REQUIRED');
      }
      const revokedToken = await t.stepUp(admin(), 'users.roles.assign');
      const jti = (await t.jwt.verifyPurpose(revokedToken, 'step_up')).jti;
      await t.q(
        "INSERT INTO token_denylist (jti, token_kind, expires_at, reason) VALUES ($1, 'step_up', now() + interval '1 hour', 'revoked')",
        [jti],
      );
      expect((await t.req('put', path, admin(), { stepUp: revokedToken }).send(body)).body.code).toBe(
        'STEP_UP_REQUIRED',
      );
      const expiring = await t.stepUp(admin(), 'users.roles.assign');
      t.clock.advance(16 * 60_000);
      try {
        // access-токен тоже 15 мин — перевыпускаем его, step-up остаётся просроченным
        const fresh = { ...admin(), token: await t.accessToken(admin()) };
        expect((await t.req('put', path, fresh, { stepUp: expiring }).send(body)).body.code).toBe('STEP_UP_REQUIRED');
      } finally {
        t.clock.advance(-16 * 60_000);
      }
    });
  });

  // ------------------------------------------------------------------------------------------------------------
  describe('PUT /admin/users/{id}/roles (08 §4.18.2; SEC-040, SEC-043; ядро §21 п. 3; 12 T-SEC-043)', () => {
    const put = async (
      actor: Actor,
      target: string,
      role: string,
      rowVersion = 1,
      reason = 'перевод по служебной записке',
    ) =>
      t
        .req('put', `/admin/users/${target}/roles`, actor, { stepUp: await t.stepUp(actor, 'users.roles.assign') })
        .send({ roles: [role], reason, rowVersion });

    it('owner назначает cashier → 403 FORBIDDEN (owner_scope_limited) + authz.denied; owner назначает admin → 200', async () => {
      const target = await t.actor('seller');
      const denied = await put(owner(), target.userId, 'cashier');
      expect(denied.status).toBe(403);
      expect(denied.body).toMatchObject({ code: 'FORBIDDEN', reason: 'owner_scope_limited' });
      const audit = await t.auditRows('authz.denied', target.userId);
      expect(audit.at(-1)).toMatchObject({
        result: 'denied',
        actor_user_id: owner().userId,
        after: { operation: 'users.roles.assign', reason: 'owner_scope_limited' },
      });
      expect(t.logs.text).toContain('"alert":"authz.denied"');

      const ok = await put(owner(), target.userId, 'admin');
      expect(ok.status).toBe(200);
      expect(ok.body).toMatchObject({ id: target.userId, roles: ['admin'], permissionsVersion: 2 });
      // owner видит маску телефона, admin — полный номер (08 §4.18.1)
      expect(ok.body.phoneMasked).toMatch(/^\+996 \d\*\* \*\*\* \*\d{2}$/);
    });

    it('admin: назначить owner (в т. ч. себе) → 403 owner_role_reserved; роль цели owner → 403; сменить свою роль → 403 self_target', async () => {
      const target = await t.actor('seller');
      expect((await put(admin(), target.userId, 'owner')).body).toMatchObject({
        code: 'FORBIDDEN',
        reason: 'owner_role_reserved',
      });
      expect((await put(admin(), admin().userId, 'owner')).body).toMatchObject({ reason: 'owner_role_reserved' });
      expect((await put(admin(), owner().userId, 'admin')).body).toMatchObject({ reason: 'owner_role_reserved' });
      expect((await put(admin(), admin().userId, 'seller')).body).toMatchObject({ reason: 'self_target' });
    });

    it('integration → 422 integration_role; pending_activation → 422 user_pending_activation; две роли → 400', async () => {
      const target = await t.actor('seller');
      const r1 = await put(admin(), target.userId, 'integration');
      expect(r1.status).toBe(422);
      expect(r1.body.errors[0]).toMatchObject({ rule: 'integration_role' });
      const pending = await t.actor('customer', { status: 'pending_activation' });
      const r2 = await put(admin(), pending.userId, 'seller');
      expect(r2.status).toBe(422);
      expect(r2.body.errors[0]).toMatchObject({ rule: 'user_pending_activation' });
      const r3 = await t
        .req('put', `/admin/users/${target.userId}/roles`, admin(), {
          stepUp: await t.stepUp(admin(), 'users.roles.assign'),
        })
        .send({ roles: ['seller', 'cashier'], reason: 'две роли сразу', rowVersion: 1 });
      expect(r3.status).toBe(400);
      expect(r3.body.code).toBe('VALIDATION_FAILED');
    });

    it('T-SEC-013: admin меняет seller → cashier: permissionsVersion++, старый токен цели → TOKEN_STALE, аудит с причиной, уведомление; повтор → 200 без изменений', async () => {
      const target = await t.actor('seller');
      const before = await t.req('get', `/admin/users/${target.userId}`, admin());
      expect(before.body).toMatchObject({ roles: ['seller'], permissionsVersion: 1, rowVersion: 1 });
      expect(before.body.phoneMasked).toBe(target.phone);

      const noReason = await t
        .req('put', `/admin/users/${target.userId}/roles`, admin(), {
          stepUp: await t.stepUp(admin(), 'users.roles.assign'),
        })
        .send({ roles: ['cashier'], rowVersion: 1 });
      expect(noReason.status).toBe(400);
      expect(noReason.body.errors[0]).toMatchObject({ field: 'reason', rule: 'reason_required' });

      const conflict = await put(admin(), target.userId, 'cashier', 7);
      expect(conflict.status).toBe(409);
      expect(conflict.body).toMatchObject({ code: 'VERSION_CONFLICT', current: { rowVersion: 1 } });

      const ok = await put(admin(), target.userId, 'cashier', 1);
      expect(ok.status).toBe(200);
      expect(ok.body).toMatchObject({ roles: ['cashier'], permissionsVersion: 2, rowVersion: 2 });
      const stale = await t.req('get', '/admin/users', target);
      expect(stale.status).toBe(401);
      expect(stale.body.code).toBe('TOKEN_STALE');

      const audit = await t.auditRows('user.role_changed', target.userId);
      const app = audit.filter((a) => a.level === 'app');
      expect(app.at(-1)).toMatchObject({
        reason: 'перевод по служебной записке',
        step_up_method: 'pin',
        actor_user_id: admin().userId,
        before: { roles: ['seller'] },
        after: { roles: ['cashier'] },
      });
      const notes = await t.q(
        "SELECT title_ru FROM notifications WHERE user_id = $1 AND dedupe_key LIKE 'user.role_changed:%'",
        [target.userId],
      );
      expect(notes).toHaveLength(1);

      const again = await put(admin(), target.userId, 'cashier', 1);
      expect(again.status).toBe(200);
      expect(again.body).toMatchObject({ roles: ['cashier'], permissionsVersion: 2 });
    });

    it('клиент → сотрудник явным действием admin (SEC-136 п. 4): kind=staff, сессии клиента отозваны', async () => {
      const cust = await t.actor('customer');
      const ok = await put(admin(), cust.userId, 'seller', 1);
      expect(ok.status).toBe(200);
      expect(ok.body).toMatchObject({ kind: 'staff', roles: ['seller'] });
      const r = await t.req('get', '/admin/users', cust);
      expect(r.status).toBe(401); // kind в токене ≠ БД → UNAUTHENTICATED (AuthGuard), сессии отозваны в БД
      expect(['UNAUTHENTICATED', 'SESSION_REVOKED']).toContain(r.body.code);
      const live = await t.q('SELECT 1 FROM sessions WHERE user_id = $1 AND revoked_at IS NULL', [cust.userId]);
      expect(live).toHaveLength(0);
      const reasons = await t.q<{ revoke_reason: string }>('SELECT revoke_reason FROM sessions WHERE user_id = $1', [
        cust.userId,
      ]);
      expect(reasons.map((x) => x.revoke_reason)).toEqual(['role_changed']);
    });
  });

  // ------------------------------------------------------------------------------------------------------------
  describe('logout-all, block, сброс PIN, PATCH (08 §4.18.1, §4.18.3, §4.18.9; 11 SEC-043)', () => {
    it('T-SEC-012: logout-all: все сессии цели отозваны → следующий запрос SESSION_REVOKED; аудит session.revoked; повтор → 204', async () => {
      const target = await t.actor('cashier');
      expect((await t.req('get', '/admin/users', target)).status).toBe(403); // cashier: нет users.read, но сессия жива
      const r = await t
        .req('post', `/admin/users/${target.userId}/logout-all`, admin(), {
          stepUp: await t.stepUp(admin(), 'session.revoke.any'),
        })
        .send();
      expect(r.status).toBe(204);
      const after = await t.req('get', '/admin/users', target);
      expect(after.status).toBe(401);
      expect(after.body.code).toBe('SESSION_REVOKED');
      const audit = await t.auditRows('session.revoked', target.userId);
      expect(audit.at(-1)).toMatchObject({ after: { revokedSessions: 1 }, actor_user_id: admin().userId });
      const again = await t
        .req('post', `/admin/users/${target.userId}/logout-all`, admin(), {
          stepUp: await t.stepUp(admin(), 'session.revoke.any'),
        })
        .send();
      expect(again.status).toBe(204);
    });

    it('logout-all: admin над owner → 403; owner над seller → 403; owner над admin → 204; себя → 403', async () => {
      const su = async (a: Actor) => ({ stepUp: await t.stepUp(a, 'session.revoke.any') });
      expect(
        (await t.req('post', `/admin/users/${owner().userId}/logout-all`, admin(), await su(admin())).send()).body,
      ).toMatchObject({ code: 'FORBIDDEN', reason: 'owner_role_reserved' });
      const seller = await t.actor('seller');
      expect(
        (await t.req('post', `/admin/users/${seller.userId}/logout-all`, owner(), await su(owner())).send()).body,
      ).toMatchObject({ code: 'FORBIDDEN', reason: 'owner_scope_limited' });
      const otherAdmin = await t.actor('admin');
      expect(
        (await t.req('post', `/admin/users/${otherAdmin.userId}/logout-all`, owner(), await su(owner())).send()).status,
      ).toBe(204);
      expect(
        (await t.req('post', `/admin/users/${admin().userId}/logout-all`, admin(), await su(admin())).send()).body,
      ).toMatchObject({ code: 'FORBIDDEN', reason: 'self_target' });
    });

    it('T-SESS-018, T-SEC-012: block: статус blocked, сессии отозваны, приглашения номера аннулированы, аудит user.blocked; повтор → 200; unblock → active', async () => {
      const target = await t.actor('senior_seller');
      const su = async () => ({ stepUp: await t.stepUp(admin(), 'users.manage') });
      const noReason = await t
        .req('post', `/admin/users/${target.userId}/block`, admin(), await su())
        .send({ blocked: true });
      expect(noReason.status).toBe(400);
      expect(noReason.body.errors[0]).toMatchObject({ rule: 'reason_required' });
      const r = await t
        .req('post', `/admin/users/${target.userId}/block`, admin(), await su())
        .send({ blocked: true, reason: 'увольнение сотрудника' });
      expect(r.status).toBe(200);
      expect(r.body).toMatchObject({ status: 'blocked', permissionsVersion: 2 });
      expect((await t.req('get', '/admin/users', target)).body.code).toBe('SESSION_REVOKED');
      expect((await t.auditRows('user.blocked', target.userId)).filter((a) => a.level === 'app').at(-1)).toMatchObject({
        reason: 'увольнение сотрудника',
        before: { status: 'active' },
        after: { status: 'blocked', revokedSessions: 1 },
      });
      const repeat = await t
        .req('post', `/admin/users/${target.userId}/block`, admin(), await su())
        .send({ blocked: true });
      expect(repeat.status).toBe(200);
      const unblock = await t
        .req('post', `/admin/users/${target.userId}/block`, admin(), await su())
        .send({ blocked: false, reason: 'восстановлен на работе' });
      expect(unblock.body).toMatchObject({ status: 'active' });
      expect((await t.auditRows('user.unblocked', target.userId)).filter((a) => a.level === 'app')).toHaveLength(1);
    });

    it('block: себя → 403 self_target; owner → 403 owner_role_reserved (+ authz.denied)', async () => {
      const su = { stepUp: await t.stepUp(admin(), 'users.manage') };
      const self = await t
        .req('post', `/admin/users/${admin().userId}/block`, admin(), su)
        .send({ blocked: true, reason: 'проверка запрета' });
      expect(self.body).toMatchObject({ code: 'FORBIDDEN', reason: 'self_target' });
      const own = await t
        .req('post', `/admin/users/${owner().userId}/block`, admin(), su)
        .send({ blocked: true, reason: 'проверка запрета' });
      expect(own.body).toMatchObject({ code: 'FORBIDDEN', reason: 'owner_role_reserved' });
      expect((await t.auditRows('authz.denied', owner().userId)).length).toBeGreaterThan(0);
    });

    it('T-BIO-013 (сброс администратором): DELETE /admin/users/{id}/pin: app_pins удалён (сотрудник обязан задать PIN заново), повтор → 204; customer/owner/себя → 403', async () => {
      const target = await t.actor('cashier');
      const h = await t.app.get(PinHasher).hash('5820', target.userId);
      await t.q(
        "INSERT INTO app_pins (user_id, pin_hash, pepper_version, pin_length, failed_attempts, locked_until, changed_at) VALUES ($1,$2,$3,$4,5, now() + interval '1 hour', now())",
        [target.userId, h.pinHash, h.pepperVersion, h.pinLength],
      );
      const su = async () => ({ stepUp: await t.stepUp(admin(), 'users.pin.reset') });
      const bad = await t
        .req('delete', `/admin/users/${target.userId}/pin`, admin(), await su())
        .send({ reason: 'abc' });
      expect(bad.status).toBe(400);
      const r = await t
        .req('delete', `/admin/users/${target.userId}/pin`, admin(), await su())
        .send({ reason: 'сотрудник забыл PIN' });
      expect(r.status).toBe(204);
      expect(await t.q('SELECT 1 FROM app_pins WHERE user_id = $1', [target.userId])).toHaveLength(0);
      const audit = await t.auditRows('auth.pin.reset', target.userId);
      expect(audit).toHaveLength(1);
      expect(audit[0]).toMatchObject({ reason: 'сотрудник забыл PIN', after: { pinSet: false } });
      expect(JSON.stringify(audit)).not.toContain(h.pinHash);
      expect(
        (
          await t
            .req('delete', `/admin/users/${target.userId}/pin`, admin(), await su())
            .send({ reason: 'повторный сброс' })
        ).status,
      ).toBe(204);
      for (const [who, reason] of [
        [actors.customer.userId, 'customer_target'],
        [owner().userId, 'owner_role_reserved'],
        [admin().userId, 'self_target'],
      ] as const) {
        const d = await t
          .req('delete', `/admin/users/${who}/pin`, admin(), await su())
          .send({ reason: 'проверка запрета' });
        expect(d.body).toMatchObject({ code: 'FORBIDDEN', reason });
      }
    });

    it('PATCH: ФИО с rowVersion (409 при конфликте); discountLimitPercent → 400 forbidden_field; admin над owner → 403', async () => {
      const target = await t.actor('seller');
      const su = async () => ({ stepUp: await t.stepUp(admin(), 'users.manage') });
      const ok = await t
        .req('patch', `/admin/users/${target.userId}`, admin(), await su())
        .send({ fullName: 'Иванов Иван', rowVersion: 1 });
      expect(ok.status).toBe(200);
      expect(ok.body).toMatchObject({ fullName: 'Иванов Иван', rowVersion: 2 });
      const conflict = await t
        .req('patch', `/admin/users/${target.userId}`, admin(), await su())
        .send({ fullName: 'Другое Имя', rowVersion: 1 });
      expect(conflict.status).toBe(409);
      const forbidden = await t
        .req('patch', `/admin/users/${target.userId}`, admin(), await su())
        .send({ fullName: 'Иванов Иван', rowVersion: 2, discountLimitPercent: '15.00', warehouseIds: [] });
      expect(forbidden.status).toBe(400);
      expect((forbidden.body.errors as { rule: string }[]).map((e) => e.rule)).toEqual([
        'forbidden_field',
        'forbidden_field',
      ]);
      const own = await t
        .req('patch', `/admin/users/${owner().userId}`, admin(), await su())
        .send({ fullName: 'Владелец', rowVersion: 1 });
      expect(own.body).toMatchObject({ code: 'FORBIDDEN', reason: 'owner_role_reserved' });
      expect((await t.auditRows('user.updated', target.userId))[0]).toMatchObject({
        before: { fullName: 'Т. S. Т.' },
        after: { fullName: 'И. И.' },
      });
    });
  });

  // ------------------------------------------------------------------------------------------------------------
  describe('GET /admin/users: фильтры, курсор, видимость телефона', () => {
    it('фильтр role/kind, q по телефону, keyset-курсор; подделанный курсор → 400 rule cursor; owner видит маску', async () => {
      const page1 = await t.req('get', '/admin/users?kind=staff&limit=2', admin());
      expect(page1.status).toBe(200);
      expect(page1.body.items).toHaveLength(2);
      expect(page1.body.hasMore).toBe(true);
      const page2 = await t.req(
        'get',
        `/admin/users?kind=staff&limit=2&cursor=${encodeURIComponent(page1.body.nextCursor)}`,
        admin(),
      );
      expect(page2.status).toBe(200);
      const ids1 = (page1.body.items as { id: string }[]).map((i) => i.id);
      for (const i of page2.body.items as { id: string }[]) expect(ids1).not.toContain(i.id);
      const tampered = `${(page1.body.nextCursor as string).slice(0, -2)}00`;
      const bad = await t.req('get', `/admin/users?cursor=${encodeURIComponent(tampered)}`, admin());
      expect(bad.status).toBe(400);
      expect(bad.body.errors[0]).toMatchObject({ rule: 'cursor' });

      const byRole = await t.req('get', '/admin/users?role=customer', admin());
      expect((byRole.body.items as { roles: string[] }[]).every((i) => i.roles[0] === 'customer')).toBe(true);
      const byPhone = await t.req('get', `/admin/users?q=${actors.seller.phone.slice(-7)}`, admin());
      expect((byPhone.body.items as { id: string }[]).map((i) => i.id)).toContain(actors.seller.userId);
      const asOwner = await t.req('get', `/admin/users/${actors.seller.userId}`, owner());
      expect(asOwner.body.phoneMasked).toBe(`+996 ${actors.seller.phone[4]}** *** *${actors.seller.phone.slice(-2)}`);
      expect((await t.req('get', '/admin/users?role=bogus', admin())).status).toBe(400);
      expect((await t.req('get', `/admin/users/${randomUUID()}`, admin())).status).toBe(404);
      expect((await t.req('get', '/admin/users/not-a-uuid', admin())).body.errors[0]).toMatchObject({ rule: 'uuid' });
    });
  });

  // ------------------------------------------------------------------------------------------------------------
  describe('приглашения (08 §4.18.4; D-07, ядро §24.2; 11 SEC-136; 12 T-REG-017)', () => {
    const su = async () => ({ stepUp: await t.stepUp(admin(), 'invitations.manage') });

    it('POST → 201 pending, expiresAt = now + 30 дней, аудит invitation.created; дубль → 409; повтор с тем же ключом → тот же ответ', async () => {
      const phone = testPhone();
      const key = randomUUID();
      const r = await t.req('post', '/admin/invitations', admin(), { ...(await su()), idem: key }).send({
        phone: `${phone.slice(0, 4)} ${phone.slice(4, 7)} ${phone.slice(7)}`,
        roles: ['seller'],
        fullName: 'Сидоров Сидор',
      });
      expect(r.status).toBe(201);
      expect(r.body).toMatchObject({ roles: ['seller'], status: 'pending', appliedToUserId: null });
      expect(r.body.phoneMasked).toBe(`+996 ${phone[4]}** *** *${phone.slice(-2)}`);
      expect(Date.parse(r.body.expiresAt) - t.clock.now().getTime()).toBe(30 * 86_400_000);
      expect(r.body.createdBy).toMatchObject({ id: admin().userId, role: 'admin' });
      const audit = await t.auditRows('invitation.created', r.body.id);
      expect(audit).toHaveLength(1);
      expect(JSON.stringify(audit[0])).not.toContain(phone);

      const replay = await t.req('post', '/admin/invitations', admin(), { ...(await su()), idem: key }).send({
        phone: `${phone.slice(0, 4)} ${phone.slice(4, 7)} ${phone.slice(7)}`,
        roles: ['seller'],
        fullName: 'Сидоров Сидор',
      });
      expect(replay.status).toBe(201);
      expect(replay.headers['idempotent-replayed']).toBe('true');
      expect(replay.body.id).toBe(r.body.id);

      const dup = await t
        .req('post', '/admin/invitations', admin(), { ...(await su()), idem: true })
        .send({ phone, roles: ['cashier'], fullName: 'Сидоров Сидор' });
      expect(dup.status).toBe(409);
      expect(dup.body).toMatchObject({ code: 'PHONE_ALREADY_REGISTERED', reason: 'invitation_pending' });

      const list = await t.req('get', '/admin/invitations?limit=200', owner());
      expect(list.status).toBe(200);
      expect((list.body.items as { id: string }[]).map((i) => i.id)).toContain(r.body.id);
    });

    it('T-REG-026 (3): роль owner → 403 owner_role_reserved; admin → 403 role_not_invitable; две роли/без ФИО → 422; без Idempotency-Key → 400', async () => {
      const send = async (body: Record<string, unknown>, idem: boolean | string = true) =>
        t
          .req('post', '/admin/invitations', admin(), {
            ...(await su()),
            idem: idem === false ? undefined : (idem as true),
          })
          .send(body);
      expect((await send({ phone: testPhone(), roles: ['owner'], fullName: 'Владелец Второй' })).body).toMatchObject({
        code: 'FORBIDDEN',
        reason: 'owner_role_reserved',
      });
      expect((await send({ phone: testPhone(), roles: ['admin'], fullName: 'Админ Второй' })).body).toMatchObject({
        code: 'FORBIDDEN',
        reason: 'role_not_invitable',
      });
      const two = await send({ phone: testPhone(), roles: ['seller', 'cashier'], fullName: 'Два Роли' });
      expect(two.status).toBe(422);
      expect(two.body.errors[0]).toMatchObject({ field: 'roles', rule: 'max_items' });
      const noName = await send({ phone: testPhone(), roles: ['seller'] });
      expect(noName.status).toBe(422);
      expect(noName.body.errors[0]).toMatchObject({ field: 'fullName', rule: 'required' });
      const integration = await send({ phone: testPhone(), roles: ['integration'], fullName: 'Интеграция' });
      expect(integration.status).toBe(400);
      const badPhone = await send({ phone: '+7 999 000 00 00', roles: ['seller'], fullName: 'Иностранец' });
      expect(badPhone.body.errors[0]).toMatchObject({ field: 'phone', rule: 'phone_e164' });
      const noKey = await send({ phone: testPhone(), roles: ['seller'], fullName: 'Без Ключа' }, false);
      expect(noKey.status).toBe(400);
      expect(noKey.body.errors[0]).toMatchObject({ rule: 'idempotency_key_required' });
      const past = await send({
        phone: testPhone(),
        roles: ['seller'],
        fullName: 'Прошлое',
        expiresAt: '2020-01-01T00:00:00Z',
      });
      expect(past.status).toBe(422);
      expect(past.body.errors[0]).toMatchObject({ rule: 'date_range' });
    });

    it('номер pending_activation → приглашение применяется сразу: active, staff, роль, accepted, аудит user.activated + user.role_changed', async () => {
      const pending = await t.actor('customer', { status: 'pending_activation', kind: 'customer' });
      await t.q('UPDATE user_roles SET revoked_at = now() WHERE user_id = $1', [pending.userId]);
      const r = await t
        .req('post', '/admin/invitations', admin(), { ...(await su()), idem: true })
        .send({ phone: pending.phone, roles: ['cashier'], fullName: 'Кассиров Касс' });
      expect(r.status).toBe(201);
      expect(r.body).toMatchObject({ status: 'accepted', appliedToUserId: pending.userId, roles: ['cashier'] });
      const u = await new UsersRepository(t.fdb.db).findById(pending.userId);
      expect(u).toMatchObject({ status: 'active', kind: 'staff', invitationId: r.body.id, permissionsVersion: 2 });
      const view = await t.req('get', `/admin/users/${pending.userId}`, admin());
      expect(view.body).toMatchObject({ roles: ['cashier'], invitation: { status: 'accepted' } });
      expect(await t.auditRows('user.activated', pending.userId)).toHaveLength(1);
      expect((await t.auditRows('user.role_changed', pending.userId)).filter((a) => a.level === 'app')).toHaveLength(1);
    });

    it('номер клиента → 409 customer_account (SEC-136 п. 4); номер сотрудника → 409 staff_account', async () => {
      const c = await t.req('post', '/admin/invitations', admin(), { ...(await su()), idem: true }).send({
        phone: actors.customer.phone,
        roles: ['seller'],
        fullName: 'Клиентов Клиент',
      });
      expect(c.body).toMatchObject({ code: 'PHONE_ALREADY_REGISTERED', reason: 'customer_account' });
      const s = await t.req('post', '/admin/invitations', admin(), { ...(await su()), idem: true }).send({
        phone: actors.seller.phone,
        roles: ['cashier'],
        fullName: 'Продавцов Продавец',
      });
      expect(s.body).toMatchObject({ code: 'PHONE_ALREADY_REGISTERED', reason: 'staff_account' });
    });

    it('DELETE → 204, статус revoked, аудит invitation.revoked; повтор → 204; неизвестный → 404; без step-up → STEP_UP_REQUIRED', async () => {
      const created = await t.req('post', '/admin/invitations', admin(), { ...(await su()), idem: true }).send({
        phone: testPhone(),
        roles: ['senior_seller'],
        fullName: 'Старший Продавец',
      });
      expect(created.status).toBe(201);
      const noStepUp = await t.req('delete', `/admin/invitations/${created.body.id}`, admin()).send();
      expect(noStepUp.body.code).toBe('STEP_UP_REQUIRED');
      expect((await t.req('delete', `/admin/invitations/${created.body.id}`, admin(), await su()).send()).status).toBe(
        204,
      );
      expect((await t.q('SELECT status FROM user_invitations WHERE id = $1', [created.body.id]))[0]).toMatchObject({
        status: 'revoked',
      });
      expect(await t.auditRows('invitation.revoked', created.body.id)).toHaveLength(1);
      expect((await t.req('delete', `/admin/invitations/${created.body.id}`, admin(), await su()).send()).status).toBe(
        204,
      );
      expect((await t.req('delete', `/admin/invitations/${randomUUID()}`, admin(), await su()).send()).status).toBe(
        404,
      );
    });

    it('POST /admin/users: pending_activation → 201 AdminUser (активация); новый номер → 201 Invitation; forbidden_field → 400', async () => {
      const usu = async () => ({ stepUp: await t.stepUp(admin(), 'users.manage') });
      const pending = await t.actor('customer', { status: 'pending_activation', kind: 'customer' });
      await t.q('UPDATE user_roles SET revoked_at = now() WHERE user_id = $1', [pending.userId]);
      const act = await t.req('post', '/admin/users', admin(), { ...(await usu()), idem: true }).send({
        phone: pending.phone,
        fullName: 'Активируемый Сотрудник',
        roles: ['seller'],
      });
      expect(act.status).toBe(201);
      expect(act.body).toMatchObject({ id: pending.userId, status: 'active', kind: 'staff', roles: ['seller'] });
      expect(act.headers.location).toBe(`/api/v1/admin/users/${pending.userId}`);
      expect((await t.auditRows('user.invited')).length).toBeGreaterThan(0);

      const fresh = await t.req('post', '/admin/users', admin(), { ...(await usu()), idem: true }).send({
        phone: testPhone(),
        fullName: 'Новый Сотрудник',
        roles: ['cashier'],
      });
      expect(fresh.status).toBe(201);
      expect(fresh.body).toMatchObject({ status: 'pending', roles: ['cashier'] });
      expect(fresh.headers.location).toBe(`/api/v1/admin/invitations/${fresh.body.id}`);

      // admin A-03: контракт 1.1.0 — 201 oneOf [AdminUser, Invitation] + Location; тела — по своим схемам
      const create = contractSchemaOf('admin_users_create');
      expect(create.oneOf).toEqual(['AdminUser', 'Invitation']);
      expect(create.headers).toContain('Location');
      const adminUser = contractSchemaProps('AdminUser');
      const invitation = contractSchemaProps('Invitation');
      expect(adminUser.required.every((k) => k in act.body)).toBe(true);
      expect(Object.keys(act.body).filter((k) => !adminUser.properties.includes(k))).toEqual([]);
      expect(act.body).toHaveProperty('kind'); // признак AdminUser для клиента (у Invitation поля kind нет)
      expect(invitation.properties).not.toContain('kind');
      expect(invitation.required.every((k) => k in fresh.body)).toBe(true);
      expect(Object.keys(fresh.body).filter((k) => !invitation.properties.includes(k))).toEqual([]);

      const forbidden = await t.req('post', '/admin/users', admin(), { ...(await usu()), idem: true }).send({
        phone: testPhone(),
        fullName: 'Лимит Скидки',
        roles: ['seller'],
        discountLimitPercent: '10.00',
      });
      expect(forbidden.status).toBe(400);
      expect(forbidden.body.errors[0]).toMatchObject({ field: 'discountLimitPercent', rule: 'forbidden_field' });
      const ownerRole = await t.req('post', '/admin/users', admin(), { ...(await usu()), idem: true }).send({
        phone: testPhone(),
        fullName: 'Ещё Владелец',
        roles: ['owner'],
      });
      expect(ownerRole.body).toMatchObject({ code: 'FORBIDDEN', reason: 'owner_role_reserved' });
    });
  });

  // ------------------------------------------------------------------------------------------------------------
  it('T-SEC-030: audit_logs append-only: UPDATE под ролью приложения → ошибка БД (RM-D-006 критерий 3); цепочка цела', async () => {
    await expect(t.q("UPDATE audit_logs SET reason = 'подмена' WHERE action = 'user.role_changed'")).rejects.toThrow(
      /append-only/,
    );
    await expect(t.q("DELETE FROM audit_logs WHERE action = 'authz.denied'")).rejects.toThrow(/append-only/);
    const chain = await t.q<{ ok: boolean }>('SELECT ok FROM audit_verify_chain(1, 9223372036854775807)');
    expect(chain[0]?.ok).toBe(true);
  });
});
