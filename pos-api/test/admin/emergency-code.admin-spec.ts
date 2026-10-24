import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { EmergencyChallengesRepository } from '../../src/auth/otp/emergency-challenges.repository.js';
import { OtpHmacService } from '../../src/common/crypto/otp-hmac.service.js';
import { type Actor, AdminTestApp } from './support/admin-app.js';

/**
 * RM-D-016: аварийный одноразовый код входа (08 §4.18.10; 09 §6.13, SMS-035, AC-AUTH-086; 11 SEC-131, SEC-043).
 * Вход по коду (`/auth/otp/request` → `/auth/otp/verify`) — модуль auth (сквозной сценарий — test/e2e/auth/
 * emergency-login.e2e-spec.ts); здесь — выдача, хранение, ограничения и сторона чтения auth.
 */
describe('POST /admin/users/{id}/emergency-login-code (RM-D-016)', () => {
  const t = new AdminTestApp();
  let admin: Actor;
  let owner: Actor;

  beforeAll(async () => {
    await t.start('admin_emergency_e2e');
    admin = await t.actor('admin');
    owner = await t.actor('owner');
  });

  afterAll(async () => {
    await t.stop();
  });

  const issue = async (
    actor: Actor,
    targetId: string,
    body: Record<string, unknown>,
    opts: { method?: 'pin' | 'otp'; idem?: string } = {},
  ) =>
    t
      .req('post', `/admin/users/${targetId}/emergency-login-code`, actor, {
        stepUp: await t.stepUp(actor, 'users.emergency_code.issue', opts.method ?? 'pin'),
        ...(opts.idem ? { idem: opts.idem } : {}),
      })
      .send(body);

  it('T-ADMIN-010 (а, б-отказ): без step-up → 403 STEP_UP_REQUIRED (только pin); step-up по OTP → STEP_UP_REQUIRED; owner/seller → 403 FORBIDDEN', async () => {
    const target = await t.actor('cashier');
    const r = await t
      .req('post', `/admin/users/${target.userId}/emergency-login-code`, admin)
      .send({ reason: 'sms_unavailable' });
    expect(r.status).toBe(403);
    expect(r.body).toMatchObject({
      code: 'STEP_UP_REQUIRED',
      stepUp: { operation: 'users.emergency_code.issue', allowedMethods: ['pin'] },
    });
    expect((await issue(admin, target.userId, { reason: 'sms_unavailable' }, { method: 'otp' })).body.code).toBe(
      'STEP_UP_REQUIRED',
    );
    const byOwner = await issue(owner, target.userId, { reason: 'sms_unavailable' });
    expect(byOwner.status).toBe(403);
    expect(byOwner.body.code).toBe('FORBIDDEN');
    const seller = await t.actor('seller');
    expect((await issue(seller, target.userId, { reason: 'sms_unavailable' })).body.code).toBe('FORBIDDEN');
  });

  it('T-ADMIN-010 (б): со step-up → 201 {code, expiresAt, phoneMasked}; otp_challenges без sms_outbox, только HMAC; аудит без кода; уведомления; no-store', async () => {
    const target = await t.actor('cashier');
    const key = randomUUID();
    const r = await issue(admin, target.userId, { reason: 'sms_unavailable' }, { idem: key });
    expect(r.status).toBe(201);
    expect(r.headers['cache-control']).toBe('no-store');
    expect(r.body.code).toMatch(/^\d{6}$/);
    expect(Date.parse(r.body.expiresAt) - t.clock.now().getTime()).toBe(10 * 60_000);
    expect(r.body.phoneMasked).toBe(`+996 ${target.phone[4]}** *** *${target.phone.slice(-2)}`);
    const code: string = r.body.code;

    const rows = await t.q<{
      id: string;
      purpose: string;
      status: string;
      sms_outbox_id: string | null;
      code_hmac: Buffer;
      pepper_version: number;
      user_id: string;
      device_key: string | null;
    }>('SELECT * FROM otp_challenges WHERE user_id = $1', [target.userId]);
    expect(rows).toHaveLength(1);
    const ch = rows[0];
    expect(ch).toMatchObject({ purpose: 'login_or_register', status: 'sent', sms_outbox_id: null, device_key: null });
    const hmac = t.app.get(OtpHmacService);
    expect(hmac.verifyCode(ch.id, code, ch.code_hmac, ch.pepper_version)).toBe(true);
    expect(hmac.verifyCode(ch.id, code === '000000' ? '000001' : '000000', ch.code_hmac, ch.pepper_version)).toBe(
      false,
    );
    expect(await t.q('SELECT 1 FROM sms_outbox')).toHaveLength(0);

    // код не хранится и не пишется: otp_challenges (текстом), audit_logs, notifications, idempotency_keys, логи
    const dump = JSON.stringify([
      await t.q('SELECT * FROM otp_challenges'),
      await t.q('SELECT * FROM audit_logs'),
      await t.q('SELECT * FROM notifications'),
      await t.q('SELECT * FROM idempotency_keys'),
    ]);
    // как отдельное число (без ложных совпадений внутри длинных цифровых строк — телефонов, epoch-времени)
    const standalone = new RegExp(`(?<![0-9])${code}(?![0-9])`);
    expect(dump).not.toMatch(standalone);
    expect(await t.q('SELECT 1 FROM idempotency_keys WHERE key = $1', [key])).toHaveLength(0);
    expect(t.logs.text).not.toMatch(standalone);
    expect(t.logs.text).toContain('"alert":"auth.emergency_code.issued"');

    const audit = await t.auditRows('auth.emergency_code.issued', target.userId);
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({
      actor_user_id: admin.userId,
      step_up_method: 'pin',
      reason: 'sms_unavailable: SMS недоступны',
      after: { challengeId: ch.id, reasonCode: 'sms_unavailable', targetRole: 'cashier' },
    });
    const notes = await t.q<{ user_id: string }>(
      'SELECT user_id FROM notifications WHERE dedupe_key = $1 ORDER BY user_id',
      [`auth.emergency_code.issued:${ch.id}`],
    );
    expect(notes.map((n) => n.user_id).sort()).toEqual([target.userId, owner.userId].sort());

    // повтор (тот же Idempotency-Key) — не идемпотентен: новый код, прежний челлендж superseded
    const again = await issue(admin, target.userId, { reason: 'sim_lost' }, { idem: key });
    expect(again.status).toBe(201);
    expect(again.headers['idempotent-replayed']).toBeUndefined();
    const statuses = await t.q<{ id: string; status: string }>(
      'SELECT id, status FROM otp_challenges WHERE user_id = $1 ORDER BY created_at, id',
      [target.userId],
    );
    expect(statuses.map((s) => s.status)).toEqual(['superseded', 'sent']);
  });

  it('T-ADMIN-010 (д, е), T-SEC-016.A17: цели: себе, другому admin, owner → 403; customer, заблокированный → 422; reason=other без comment → 400', async () => {
    const otherAdmin = await t.actor('admin');
    for (const [id, reason] of [
      [admin.userId, 'self_target'],
      [otherAdmin.userId, 'privileged_target'],
      [owner.userId, 'privileged_target'],
    ] as const) {
      const r = await issue(admin, id, { reason: 'sms_unavailable' });
      expect(r.status).toBe(403);
      expect(r.body).toMatchObject({ code: 'FORBIDDEN', reason });
    }
    expect((await t.auditRows('authz.denied', owner.userId)).at(-1)).toMatchObject({
      after: { operation: 'users.emergency_code.issue', reason: 'privileged_target' },
    });
    const customer = await t.actor('customer');
    const c = await issue(admin, customer.userId, { reason: 'sms_unavailable' });
    expect(c.status).toBe(422);
    expect(c.body.errors[0]).toMatchObject({ rule: 'target_not_active_staff' });
    const blocked = await t.actor('seller', { status: 'blocked' });
    expect((await issue(admin, blocked.userId, { reason: 'sms_unavailable' })).status).toBe(422);
    const target = await t.actor('seller');
    const noComment = await issue(admin, target.userId, { reason: 'other' });
    expect(noComment.status).toBe(400);
    expect(noComment.body.errors[0]).toMatchObject({ field: 'comment', rule: 'comment_required' });
    expect((await issue(admin, target.userId, { reason: 'bogus' })).status).toBe(400);
    expect((await issue(admin, randomUUID(), { reason: 'sms_unavailable' })).status).toBe(404);
    const withComment = await issue(admin, target.userId, { reason: 'other', comment: 'телефон в ремонте' });
    expect(withComment.status).toBe(201);
    expect((await t.auditRows('auth.emergency_code.issued', target.userId))[0]?.reason).toBe(
      'other: телефон в ремонте',
    );
  });

  it('T-ADMIN-010 (ж): лимит: 4-й код одному пользователю за сутки → 429 RATE_LIMITED с Retry-After', async () => {
    const target = await t.actor('senior_seller');
    for (let i = 0; i < 3; i++)
      expect((await issue(admin, target.userId, { reason: 'sms_unavailable' })).status).toBe(201);
    const r = await issue(admin, target.userId, { reason: 'sms_unavailable' });
    expect(r.status).toBe(429);
    expect(r.body).toMatchObject({ code: 'RATE_LIMITED', reason: 'per_user_daily' });
    expect(Number(r.headers['retry-after'])).toBeGreaterThan(23 * 3600);
  });

  it('лимит администратора: 20 кодов за сутки → 21-й → 429 per_admin_daily', async () => {
    const issuer = await t.actor('admin');
    for (let i = 0; i < 10; i++) {
      const target = await t.actor('seller');
      expect((await issue(issuer, target.userId, { reason: 'sms_unavailable' })).status).toBe(201);
      expect((await issue(issuer, target.userId, { reason: 'sim_lost' })).status).toBe(201);
    }
    const target = await t.actor('seller');
    const r = await issue(issuer, target.userId, { reason: 'sms_unavailable' });
    expect(r.status).toBe(429);
    expect(r.body.reason).toBe('per_admin_daily');
  });

  it('сторона входа (auth, EmergencyChallengesRepository): findLiveForPhone → bindDevice (первое устройство); через 10 мин код не живой (FixedClock)', async () => {
    const repo = new EmergencyChallengesRepository(t.fdb.db);
    const target = await t.actor('cashier');
    const r = await issue(admin, target.userId, { reason: 'sms_unavailable' });
    expect(r.status).toBe(201);
    const live = await repo.findLiveForPhone(target.phone, t.clock.now());
    expect(live).toMatchObject({ userId: target.userId, deviceKey: null, issuedByUserId: admin.userId });
    const d1 = randomUUID();
    expect(await repo.bindDevice(live!.challengeId, d1)).toBe(true);
    expect(await repo.bindDevice(live!.challengeId, d1)).toBe(true);
    expect(await repo.bindDevice(live!.challengeId, randomUUID())).toBe(false);
    expect((await repo.findIssued(live!.challengeId))?.deviceKey).toBe(d1);

    // обычный OTP-челлендж (с sms_outbox или без записи аудита выдачи) аварийным не считается
    const plain = randomUUID();
    await t.q(
      "INSERT INTO otp_challenges (id, phone_e164, user_id, purpose, code_hmac, salt, pepper_version, expires_at, status) VALUES ($1, $2, $3, 'step_up', '\\x00', '\\x00', 1, now() + interval '5 minutes', 'sent')",
      [plain, target.phone, target.userId],
    );
    expect(await repo.findIssued(plain)).toBeUndefined();

    const later = new Date(t.clock.now().getTime() + 10 * 60_000 + 1);
    expect(await repo.findLiveForPhone(target.phone, later)).toBeUndefined();
  });
});
