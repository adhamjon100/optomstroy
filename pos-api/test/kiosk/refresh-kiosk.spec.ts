import { createHash, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CartModule } from '../../src/cart/cart.module.js';
import { generateOpaqueToken } from '../../src/common/crypto/random.js';
import { KIOSK_ACCESS_GUARD } from '../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import { PublicSettingsModule } from '../../src/settings/public-settings.module.js';
import type { PosActor } from '../support/pos-fixture.js';
import { KioskTestApp } from './support/kiosk-fixture.js';

/**
 * Потерянный ответ `POST /auth/refresh` у планшета магазина (08 §4.1.3 «Сессия планшета магазина» (2); 09 §8.3,
 * §8.9 п. 3; 10 KIOSK-031; 11 SEC-139 (4); P-002 §8.2 п. 5; ADR-115) — **тестовые данные** стенда `kiosk-fixture`
 * (embedded PostgreSQL 17; планшет подключается через `POST /admin/store-tablets`, сотрудник и покупатель — фикстура):
 * - T-KIOSK-067: поздний повтор прежнего refresh (позже окна грации 30 с) при неиспользованном новом токене — `200`,
 *   новая пара, `grace_used_at`, сессия не отозвана; второй поздний повтор подряд — `401 SESSION_REVOKED`
 *   `reuse_detected`, аудит `session.reuse_detected`; после обычной ротации грация снова доступна (один раз на
 *   ротацию); чужой `X-Device-Id` — `401 SESSION_REVOKED` `device_mismatch`; покупатель без PIN — как прежде
 *   `refresh_replay`, сотрудник с PIN — `UNLOCK_REQUIRED` `refresh_replay` (паритет 09 §8.3).
 * Тест с БД, поэтому в наборе планшета, а не в `test/auth` (там — unit без БД, test/auth/vitest.config.ts).
 */
interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
}

interface Tablet {
  readonly id: string;
  readonly userId: string;
  readonly sid: string;
  readonly deviceKey: string;
  readonly refreshToken: string;
}

function sha256(s: string): Buffer {
  return createHash('sha256').update(s).digest();
}

describe('kiosk: POST /auth/refresh — потерянный ответ, грация один раз на ротацию (T-KIOSK-067)', () => {
  const t = new KioskTestApp();
  let warehouseId: string;

  beforeAll(async () => {
    await t.start({
      env: { QR_PROVIDER: 'none', KIOSK_MODE: 'true' },
      skuCount: 10,
      modules: [CartModule, OrdersModule, ProfileModule, PublicSettingsModule, KioskModule],
      guards: [KIOSK_ACCESS_GUARD],
      fakePorts: true,
      jobs: false,
    });
    warehouseId = await t.defaultWarehouseId();
  });

  afterAll(async () => {
    await t.stop();
  });

  async function refresh(refreshToken: string, deviceKey: string): Promise<Res> {
    const res = await t.req('post', '/auth/refresh').set('X-Device-Id', deviceKey).send({ refreshToken });
    return { status: res.status, body: (res.body ?? {}) as Res['body'] };
  }

  async function enroll(name: string): Promise<Tablet> {
    const admin = await t.actor({ role: 'admin' });
    const res = await t
      .req('post', '/admin/store-tablets', admin, { stepUp: await t.stepUp(admin, 'kiosk.manage'), idem: true })
      .send({ name, warehouseId });
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    const b = res.body as { tablet: { id: string }; sid: string; refreshToken: string };
    const rows = await t.q<{ user_id: string }>(`SELECT user_id FROM store_tablets WHERE id = $1`, [b.tablet.id]);
    return {
      id: b.tablet.id,
      userId: rows[0].user_id,
      sid: b.sid,
      deviceKey: admin.deviceKey,
      refreshToken: b.refreshToken,
    };
  }

  /** Ротация была `seconds` секунд назад (часы сдвинуты: позже окна грации `AUTH_REFRESH_GRACE_SECONDS` = 30). */
  async function rotatedAgo(sid: string, seconds: number): Promise<void> {
    await t.q(`UPDATE sessions SET rotated_at = now() - make_interval(secs => $2) WHERE id = $1`, [sid, seconds]);
  }

  async function session(sid: string) {
    const r = await t.q<{
      revoked_at: Date | null;
      revoke_reason: string | null;
      grace_used_at: Date | null;
      superseded_refresh_hash: Buffer | null;
    }>(`SELECT revoked_at, revoke_reason, grace_used_at, superseded_refresh_hash FROM sessions WHERE id = $1`, [sid]);
    return r[0];
  }

  /** Сессия фикстуры с известным refresh-токеном (сотрудник или покупатель; `devices.platform = android`). */
  async function withRefresh(a: PosActor): Promise<string> {
    const token = generateOpaqueToken();
    await t.q(`UPDATE sessions SET refresh_hash = $1 WHERE id = $2`, [sha256(token), a.sessionId]);
    return token;
  }

  it('T-KIOSK-067 lost response once → grace, twice → reuse_detected', async () => {
    const k = await enroll('Планшет у входа');
    const r1 = k.refreshToken;
    // ротация выполнена, ответ до планшета не дошёл (R2 потерян)
    const lost = await refresh(r1, k.deviceKey);
    expect(lost.status, JSON.stringify(lost.body)).toBe(200);
    await rotatedAgo(k.sid, 60);
    const logsBefore = t.logs.lines.length;
    // поздний повтор прежним токеном через 60 с — путь грации: 200, новая пара, сессия та же
    const late = await refresh(r1, k.deviceKey);
    expect(late.status, JSON.stringify(late.body)).toBe(200);
    expect(late.body.sid).toBe(k.sid);
    expect(late.body.refreshToken).not.toBe(lost.body.refreshToken);
    const s1 = await session(k.sid);
    expect(s1.revoked_at).toBeNull();
    expect(s1.grace_used_at).not.toBeNull();
    expect(s1.superseded_refresh_hash?.equals(sha256(String(lost.body.refreshToken)))).toBe(true);
    const logs = t.logs.lines.slice(logsBefore).join('\n');
    expect(logs).toContain('auth.refresh.kiosk_late_grace');
    expect(logs).not.toContain('auth.refresh.replay');
    expect(logs).not.toContain(r1);
    // новый access работает
    const me = await t.req('get', '/me', { token: String(late.body.accessToken), deviceKey: k.deviceKey }).send();
    expect(me.status).toBe(200);

    // снова потерянный ответ и поздний повтор подряд — reuse: отзыв семьи и аудит session.reuse_detected (critical)
    await rotatedAgo(k.sid, 60);
    const second = await refresh(r1, k.deviceKey);
    expect([second.status, second.body.code, second.body.reason]).toEqual([401, 'SESSION_REVOKED', 'reuse_detected']);
    expect(await session(k.sid)).toMatchObject({ revoke_reason: 'reuse_detected' });
    const audit = await t.q<{ severity: string; result: string }>(
      `SELECT severity::text AS severity, result::text AS result FROM audit_logs
        WHERE action = 'session.reuse_detected' AND entity_id = $1`,
      [k.sid],
    );
    expect(audit).toEqual([{ severity: 'critical', result: 'denied' }]);
    // и уже выданный в грации токен больше не действует (вся семья отозвана; не KIOSK_REVOKED)
    expect((await refresh(String(late.body.refreshToken), k.deviceKey)).body.code).toBe('SESSION_REVOKED');
  });

  it('T-KIOSK-067 once per rotation: после обычной ротации поздний повтор снова идёт путём грации; в окне 30 с — как прежде', async () => {
    const k = await enroll('Планшет у кассы');
    // в окне грации (< 30 с) — прежняя грация
    const a = await refresh(k.refreshToken, k.deviceKey);
    expect(a.status).toBe(200);
    const inWindow = await refresh(k.refreshToken, k.deviceKey);
    expect(inWindow.status, JSON.stringify(inWindow.body)).toBe(200);
    // ответ дошёл: обычная ротация сбрасывает grace_used_at
    const b = await refresh(String(inWindow.body.refreshToken), k.deviceKey);
    expect(b.status).toBe(200);
    expect((await session(k.sid)).grace_used_at).toBeNull();
    // потерянный ответ после этой ротации — поздний повтор снова принимается (один раз на ротацию)
    await rotatedAgo(k.sid, 120);
    const late = await refresh(String(inWindow.body.refreshToken), k.deviceKey);
    expect(late.status, JSON.stringify(late.body)).toBe(200);
    expect((await session(k.sid)).revoked_at).toBeNull();
  });

  it('T-KIOSK-067 device mismatch: refresh планшета с другим X-Device-Id — 401 SESSION_REVOKED device_mismatch', async () => {
    const k = await enroll('Планшет у склада');
    const r = await refresh(k.refreshToken, randomUUID());
    expect([r.status, r.body.code, r.body.reason]).toEqual([401, 'SESSION_REVOKED', 'device_mismatch']);
    expect(await session(k.sid)).toMatchObject({ revoke_reason: 'device_mismatch' });
    // поздний повтор после потерянного ответа не обходит проверку устройства
    const k2 = await enroll('Планшет у витрины');
    expect((await refresh(k2.refreshToken, k2.deviceKey)).status).toBe(200);
    await rotatedAgo(k2.sid, 60);
    const late = await refresh(k2.refreshToken, randomUUID());
    expect([late.status, late.body.reason]).toEqual([401, 'device_mismatch']);
  });

  it('T-KIOSK-067 customer unchanged: покупатель без PIN — refresh_replay, сотрудник с PIN — UNLOCK_REQUIRED refresh_replay', async () => {
    // покупатель без PIN: поздний повтор отзывает только эту сессию (09 §8.3), как до планшета
    const customer = await t.actor({ role: 'customer' });
    const c1 = await withRefresh(customer);
    expect((await refresh(c1, customer.deviceKey)).status).toBe(200);
    await rotatedAgo(customer.sessionId, 60);
    const cLate = await refresh(c1, customer.deviceKey);
    expect([cLate.status, cLate.body.code, cLate.body.reason]).toEqual([401, 'SESSION_REVOKED', 'refresh_replay']);
    expect(await session(customer.sessionId)).toMatchObject({ revoke_reason: 'refresh_replay', grace_used_at: null });

    // сотрудник с PIN: UNLOCK_REQUIRED refresh_replay, сессия не отзывается
    const seller = await t.actor({ role: 'seller' });
    await t.q(
      `INSERT INTO app_pins (user_id, pin_hash, pepper_version, pin_length, changed_at)
       VALUES ($1, 'fixture-pin-hash-placeholder', 1, 6, now())`,
      [seller.userId],
    );
    const s1 = await withRefresh(seller);
    expect((await refresh(s1, seller.deviceKey)).status).toBe(200);
    await rotatedAgo(seller.sessionId, 60);
    const sLate = await refresh(s1, seller.deviceKey);
    expect([sLate.status, sLate.body.code, sLate.body.reason]).toEqual([401, 'UNLOCK_REQUIRED', 'refresh_replay']);
    expect(await session(seller.sessionId)).toMatchObject({ revoked_at: null, grace_used_at: null });
    // логи грации планшета у них нет
    expect(t.logs.text).toContain('auth.refresh.replay');
  });
});
