import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { AdminUsersModule } from '../../src/admin/users/admin-users.module.js';
import {
  canAssignRole,
  canBlock,
  canIssueEmergencyCode,
  canLogoutAll,
  canResetPin,
  canUpdateProfile,
  canViewTarget,
  type PolicyTarget,
} from '../../src/admin/users/shared/target-policy.js';
import { KIOSK_ACCESS_GUARD } from '../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import type { PosActor } from '../support/pos-fixture.js';
import { KioskTestApp } from './support/kiosk-fixture.js';

/**
 * Технический пользователь планшета магазина и `/admin/users/*` (08 §4.18 «Планшеты магазина в модуле admin», §9;
 * 09 §8.9 п. 9; 11 SEC-043, SEC-136 п. 6, SEC-142; ADR-115 п. 19; 10 KIOSK-002) — **тестовые данные** стенда
 * `kiosk-fixture` (embedded PostgreSQL 17; номера сотрудников — вымышленные `+99677…` стенда):
 * - T-KIOSK-007: роль `kiosk` не назначается (`is_assignable=false`); каждая операция `/admin/users/{id}/*` над
 *   `kind=kiosk` (карточка, `PATCH`, роли, блокировка, PIN, сессии, аварийный код) → `403 FORBIDDEN`
 *   `reason: kiosk_target` + `authz.denied`; смена ролей не превращает планшет в `staff`; в списке и фильтрах SCR-45
 *   планшетов нет. Паритет: клиент → сотрудник `setRoles` по-прежнему переводит в `staff`.
 * Планшет подключается настоящим `POST /admin/store-tablets` (WP-S2A).
 */
type Method = 'get' | 'post' | 'put' | 'patch' | 'delete';

interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
}

async function call(
  t: KioskTestApp,
  method: Method,
  path: string,
  a: Pick<PosActor, 'token' | 'deviceKey'>,
  o: { readonly body?: unknown; readonly stepUp?: string; readonly idem?: string } = {},
): Promise<Res> {
  const r = t.req(method, path, a, { ...(o.stepUp ? { stepUp: o.stepUp } : {}), ...(o.idem ? { idem: o.idem } : {}) });
  const res = await (o.body !== undefined ? r.send(o.body as object) : r);
  return { status: res.status, body: (res.body ?? {}) as Res['body'] };
}

describe('kiosk: /admin/users/* не применяются к пользователю kind=kiosk (11 SEC-142, ADR-115 п. 19)', () => {
  const t = new KioskTestApp();
  let admin: PosActor;
  let owner: PosActor;
  let kioskUserId: string;
  let tabletId: string;
  let tablet: Pick<PosActor, 'token' | 'deviceKey'>;

  beforeAll(async () => {
    await t.start({
      env: { QR_PROVIDER: 'none', KIOSK_MODE: 'true' },
      skuCount: 20,
      modules: [ProfileModule, AdminUsersModule, KioskModule],
      guards: [KIOSK_ACCESS_GUARD],
      fakePorts: true,
      jobs: false,
    });
    // Планшет — настоящим подключением с устройства отдельного администратора (его сессия на устройстве завершается).
    const enroller = await t.actor({ role: 'admin' });
    const r = await call(t, 'post', '/admin/store-tablets', enroller, {
      body: { name: 'Планшет у входа', warehouseId: await t.defaultWarehouseId() },
      stepUp: await t.stepUp(enroller, 'kiosk.manage'),
      idem: randomUUID(),
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    tabletId = String(r.body.tablet.id);
    tablet = { token: String(r.body.accessToken), deviceKey: enroller.deviceKey };
    const row = await t.q<{ user_id: string }>(`SELECT user_id FROM store_tablets WHERE id = $1`, [tabletId]);
    kioskUserId = row[0].user_id;
    admin = await t.actor({ role: 'admin' });
    owner = await t.actor({ role: 'owner' });
  });

  afterAll(async () => {
    await t.stop();
  });

  async function kioskState() {
    return {
      user: await t.q(`SELECT kind::text AS kind, status::text AS status, phone_e164 FROM users WHERE id = $1`, [
        kioskUserId,
      ]),
      roles: await t.q(
        `SELECT r.code::text AS code FROM user_roles ur JOIN roles r ON r.id = ur.role_id
          WHERE ur.user_id = $1 AND ur.revoked_at IS NULL`,
        [kioskUserId],
      ),
      sessions: await t.q(`SELECT revoked_at FROM sessions WHERE user_id = $1`, [kioskUserId]),
      tablet: await t.q(`SELECT status FROM store_tablets WHERE id = $1`, [tabletId]),
    };
  }

  it('T-KIOSK-007 role not assignable, /admin/users/* 403, hidden in list, setRoles never converts', async () => {
    const before = await kioskState();
    expect(before).toEqual({
      user: [{ kind: 'kiosk', status: 'active', phone_e164: null }],
      roles: [{ code: 'kiosk' }],
      sessions: [{ revoked_at: null }],
      tablet: [{ status: 'active' }],
    });
    const rowVersion = (
      await t.q<{ v: number }>(`SELECT row_version AS v FROM user_profiles WHERE user_id = $1`, [kioskUserId])
    )[0].v;
    const deniedBefore = (await t.auditRows('authz.denied')).length;

    // каждая операция /admin/users/{id}/* над планшетом → 403 kiosk_target (после RBAC и step-up)
    const ops: readonly (readonly [Method, string, string, unknown])[] = [
      ['patch', '', 'users.manage', { fullName: 'Кассир Планшетов', rowVersion }],
      ['put', '/roles', 'users.roles.assign', { roles: ['cashier'], reason: 'перевод на кассу', rowVersion }],
      ['post', '/block', 'users.manage', { blocked: true, reason: 'проверка блокировки' }],
      ['post', '/block', 'users.manage', { blocked: false, reason: 'проверка разблокировки' }],
      ['delete', '/pin', 'users.pin.reset', { reason: 'проверка сброса PIN' }],
      ['post', '/logout-all', 'session.revoke.any', undefined],
      ['post', '/emergency-login-code', 'users.emergency_code.issue', { reason: 'sms_unavailable' }],
    ];
    for (const [method, suffix, op, body] of ops) {
      const x = await call(t, method, `/admin/users/${kioskUserId}${suffix}`, admin, {
        body,
        stepUp: await t.stepUp(admin, op, 'pin'),
      });
      expect(x.status, `${method} ${suffix} ${JSON.stringify(x.body)}`).toBe(403);
      expect(x.body, `${method} ${suffix}`).toMatchObject({ code: 'FORBIDDEN', reason: 'kiosk_target' });
    }
    // карточка — тоже 403 (admin и owner); owner над планшетом — logout-all тоже kiosk_target
    for (const viewer of [admin, owner]) {
      const card = await call(t, 'get', `/admin/users/${kioskUserId}`, viewer);
      expect(card.status).toBe(403);
      expect(card.body).toMatchObject({ code: 'FORBIDDEN', reason: 'kiosk_target' });
    }
    const ownerLogout = await call(t, 'post', `/admin/users/${kioskUserId}/logout-all`, owner, {
      stepUp: await t.stepUp(owner, 'session.revoke.any', 'pin'),
    });
    expect(ownerLogout.body).toMatchObject({ code: 'FORBIDDEN', reason: 'kiosk_target' });

    // отказы записаны authz.denied с причиной; планшет не изменился: kind, роль, сессия, статус
    const denied = (await t.auditRows('authz.denied')).slice(deniedBefore);
    expect(denied).toHaveLength(ops.length + 3);
    for (const d of denied) expect(d).toMatchObject({ result: 'denied', entity_id: kioskUserId });
    expect(new Set(denied.map((d) => (d.after as { reason?: string }).reason))).toEqual(new Set(['kiosk_target']));
    expect(await kioskState()).toEqual(before);
    expect((await call(t, 'get', '/me', tablet)).body).toMatchObject({ kind: 'kiosk', tablet: { id: tabletId } });

    // роль kiosk не назначается никому (is_assignable=false): ни сотруднику, ни клиенту; приглашением — тоже
    const cashier = await t.actor({ role: 'cashier' });
    const cashierVersion = async () =>
      (await t.q<{ v: number }>(`SELECT row_version AS v FROM user_profiles WHERE user_id = $1`, [cashier.userId]))[0]
        ?.v ?? 0;
    const assign = await call(t, 'put', `/admin/users/${cashier.userId}/roles`, admin, {
      body: { roles: ['kiosk'], reason: 'сделать планшетом', rowVersion: await cashierVersion() },
      stepUp: await t.stepUp(admin, 'users.roles.assign', 'pin'),
    });
    expect(assign.status, JSON.stringify(assign.body)).toBe(422);
    expect(assign.body.errors).toEqual([expect.objectContaining({ field: 'roles', rule: 'role_not_assignable' })]);
    expect(
      await t.q(
        `SELECT r.code::text AS code FROM user_roles ur JOIN roles r ON r.id = ur.role_id
          WHERE ur.user_id = $1 AND ur.revoked_at IS NULL`,
        [cashier.userId],
      ),
    ).toEqual([{ code: 'cashier' }]);
    const invite = await call(t, 'post', '/admin/users', admin, {
      body: { phone: '+996555004101', fullName: 'Планшет Приглашённый', roles: ['kiosk'] },
      stepUp: await t.stepUp(admin, 'users.manage', 'pin'),
      idem: randomUUID(),
    });
    expect([400, 403, 422]).toContain(invite.status);
    expect(await t.q(`SELECT 1 FROM user_invitations WHERE phone_e164 = '+996555004101'`)).toHaveLength(0);
    expect(await t.q(`SELECT 1 FROM users WHERE kind = 'kiosk'`)).toHaveLength(1);

    // список SCR-45: планшетов нет — ни без фильтров, ни с kind=kiosk / role=kiosk (admin и owner)
    for (const viewer of [admin, owner]) {
      for (const q of [
        '?limit=200',
        '?kind=kiosk',
        '?role=kiosk',
        '?kind=staff&limit=200',
        `?q=${encodeURIComponent('Планшет')}`,
      ]) {
        const l = await call(t, 'get', `/admin/users${q}`, viewer);
        expect(l.status, `${q} ${JSON.stringify(l.body)}`).toBe(200);
        const items = l.body.items as { id: string; kind: string }[];
        expect(
          items.map((i) => i.id),
          q,
        ).not.toContain(kioskUserId);
        expect(
          items.filter((i) => i.kind === 'kiosk'),
          q,
        ).toEqual([]);
      }
    }

    // паритет: клиент → сотрудник явным действием admin (SEC-136 п. 4) — по-прежнему kind=staff
    const buyer = await t.actor({ role: 'customer' });
    const toSeller = await call(t, 'put', `/admin/users/${buyer.userId}/roles`, admin, {
      body: { roles: ['seller'], reason: 'принят продавцом', rowVersion: 0 },
      stepUp: await t.stepUp(admin, 'users.roles.assign', 'pin'),
    });
    expect(toSeller.status, JSON.stringify(toSeller.body)).toBe(200);
    expect(toSeller.body).toMatchObject({ kind: 'staff', roles: ['seller'] });
  });

  it('T-KIOSK-007 политики целей: kind=kiosk → 403 kiosk_target первой проверкой; staff и customer — как прежде', () => {
    const adminActor = { userId: randomUUID(), roles: ['admin'] };
    const ownerActor = { userId: randomUUID(), roles: ['owner'] };
    const kiosk: PolicyTarget = { id: randomUUID(), kind: 'kiosk', status: 'active', roles: ['kiosk'] };
    const deny = { ok: false, code: 'FORBIDDEN', reason: 'kiosk_target' };
    for (const actor of [adminActor, ownerActor]) {
      expect(canViewTarget(kiosk)).toEqual(deny);
      expect(canUpdateProfile(actor, kiosk)).toEqual(deny);
      expect(canBlock(actor, kiosk)).toEqual(deny);
      expect(canLogoutAll(actor, kiosk)).toEqual(deny);
      expect(canResetPin(actor, kiosk)).toEqual(deny);
      expect(canIssueEmergencyCode(actor, kiosk)).toEqual(deny);
      for (const role of ['cashier', 'seller', 'admin', 'owner', 'kiosk', 'customer', 'integration']) {
        expect(canAssignRole(actor, kiosk, role), role).toEqual(deny);
      }
    }
    // паритет: прежние решения для staff и customer
    const cashier: PolicyTarget = { id: randomUUID(), kind: 'staff', status: 'active', roles: ['cashier'] };
    const customer: PolicyTarget = { id: randomUUID(), kind: 'customer', status: 'active', roles: ['customer'] };
    expect(canViewTarget(cashier)).toEqual({ ok: true });
    expect(canViewTarget(customer)).toEqual({ ok: true });
    expect(canResetPin(adminActor, customer)).toEqual({ ok: false, code: 'FORBIDDEN', reason: 'customer_target' });
    expect(canResetPin(adminActor, cashier)).toEqual({ ok: true });
    expect(canIssueEmergencyCode(adminActor, customer)).toMatchObject({ ok: false, code: 'VALIDATION_FAILED' });
    expect(canAssignRole(adminActor, customer, 'seller')).toEqual({ ok: true });
    expect(canAssignRole(adminActor, cashier, 'kiosk')).toMatchObject({ ok: false, rule: 'role_not_assignable' });
    expect(canAssignRole(adminActor, cashier, 'integration')).toMatchObject({ ok: false, rule: 'integration_role' });
  });
});
