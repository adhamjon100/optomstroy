import { createHash, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { OTP_PROVIDER, type OtpProvider } from '../../src/auth/otp/otp.provider.js';
import { CartModule } from '../../src/cart/cart.module.js';
import { AuthStateCache } from '../../src/common/auth/auth-state.js';
import { ExitCodeHasher } from '../../src/common/crypto/exit-code-hasher.service.js';
import { KIOSK_ACCESS_GUARD } from '../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import { PublicSettingsModule } from '../../src/settings/public-settings.module.js';
import type { PosActor, SaleableVariant } from '../support/pos-fixture.js';
import { KioskTestApp } from './support/kiosk-fixture.js';

/**
 * Отключение, срок сессии, подключение заново планшета магазина и `401 KIOSK_REVOKED` (08 §2.2, §2.7, §4.1.3,
 * §4.18.14, §4.18.15, §4.25.5; 09 §8.9 п. 4, п. 6, п. 8; 07 §5.65; 10 KIOSK-004, KIOSK-031; 11 SEC-139, SEC-140;
 * ADR-115; FLOW-043 A2, SCR-54) — **тестовые данные** стенда `kiosk-fixture` (embedded PostgreSQL 17, синтетический
 * каталог; номера покупателей — вымышленные `+996 555 004 xxx`; коды из SMS — из `dev_outbox` поддельного шлюза):
 * - T-KIOSK-003: после `POST /admin/store-tablets/{id}/revoke` следующий запрос планшета с живым access — `401
 *   KIOSK_REVOKED` от AuthGuard (и через denylist `jti`); прочие отзывы сессии планшета — `SESSION_REVOKED`;
 * - T-KIOSK-060: `POST /auth/refresh` после отзыва — `401 KIOSK_REVOKED` по любому из трёх хэшей; срок вышел — `401
 *   SESSION_REVOKED` (`expired`);
 * - T-KIOSK-049: простой 7 дн / 180 дн → `SESSION_REVOKED`; аварийный выход и `POST …/{id}/reconnect` — та же строка
 *   `store_tablets` и тот же `users.id`, новая сессия и новый аварийный код (прежний → 422), `lock_task_enabled` NULL,
 *   аудит `kiosk.reconnected`, срок `expiresAt` в списке (напоминание за 30 дней — SCR-54); подключение с другого
 *   устройства — новая строка `devices`, копия на прежнем — `KIOSK_REVOKED`; повтор ключа — один раз;
 * - T-KIOSK-066: аудит `kiosk.exit_code_used` (без кода);
 * - T-KIOSK-033: при `KIOSK_MODE=false` подключение заново и `POST /kiosk/exit` — `403 KIOSK_DISABLED`.
 * Прикладная часть — `pos-app/test/core/session/kiosk_session_test.dart`, `kiosk_revoked_interceptor_test.dart`,
 * `features/admin/tablets/admin_tablets_screen_test.dart` (WP-A04, WP-A05).
 */
type Method = 'get' | 'post' | 'put' | 'patch' | 'delete';

interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
  readonly headers: Record<string, string | string[] | undefined>;
}

interface CallOpts {
  readonly body?: unknown;
  readonly stepUp?: string;
  readonly idem?: string;
  readonly headers?: Record<string, string>;
}

type Subject = Pick<PosActor, 'token' | 'deviceKey'>;

interface Enrolled {
  readonly admin: PosActor;
  readonly id: string;
  readonly userId: string;
  readonly tab: Subject;
  readonly refreshToken: string;
  readonly exitCode: string;
  readonly sid: string;
}

const NOTICE = '2026-11-04';
const DEV_OUTBOX_SQL = fileURLToPath(new URL('../../db/migrations-dev/0001_dev_outbox.sql', import.meta.url));
const DAY = 24 * 3600_000;

let phoneSeq = 0;
/** Вымышленный мобильный номер КР `+996 555 004 xxx` (тестовые данные). */
function freshPhone(): string {
  phoneSeq += 1;
  return `+996555004${String(100 + phoneSeq)}`;
}

async function call(t: KioskTestApp, method: Method, path: string, a?: Subject, o: CallOpts = {}): Promise<Res> {
  let r = t.req(method, path, a, { ...(o.stepUp ? { stepUp: o.stepUp } : {}), ...(o.idem ? { idem: o.idem } : {}) });
  for (const [k, v] of Object.entries(o.headers ?? {})) r = r.set(k, v);
  const res = await (o.body !== undefined ? r.send(o.body as object) : r);
  return { status: res.status, body: (res.body ?? {}) as Res['body'], headers: res.headers };
}

function claimsOf(token: string): Record<string, unknown> {
  const part = token.split('.')[1] ?? '';
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8')) as Record<string, unknown>;
}

function noPii(v: unknown): void {
  expect(JSON.stringify(v)).not.toMatch(/\+?996\d{9}/);
}

function sha256(s: string): Buffer {
  return createHash('sha256').update(s).digest();
}

async function refresh(t: KioskTestApp, refreshToken: string, deviceKey: string): Promise<Res> {
  return call(t, 'post', '/auth/refresh', undefined, { body: { refreshToken }, headers: { 'X-Device-Id': deviceKey } });
}

/** `dev_outbox` (07 §5.63) в БД стенда — как `order-otp.spec.ts` (файл dev-миграции не меняется). */
async function createDevOutbox(t: KioskTestApp): Promise<void> {
  const c = await t.pool.connect();
  try {
    await c.query(`SELECT set_config('app.env', 'test', false)`);
    await c.query(readFileSync(DEV_OUTBOX_SQL, 'utf8'));
  } finally {
    await c.query('RESET app.env').catch(() => undefined);
    c.release();
  }
}

async function tabletRow(t: KioskTestApp, id: string) {
  const r = await t.q<{
    id: string;
    user_id: string;
    device_id: string;
    status: string;
    exit_code_hash: string;
    exit_code_pepper_version: number;
    exit_code_used_at: Date | null;
    exit_failed_attempts: number;
    exit_locked_until: Date | null;
    lock_task_enabled: boolean | null;
    reconnected_at: Date | null;
    reconnected_by_user_id: string | null;
    revoked_at: Date | null;
    revoked_by_user_id: string | null;
    revoke_reason: string | null;
  }>(`SELECT * FROM store_tablets WHERE id = $1`, [id]);
  const row = r[0];
  if (!row) throw new Error(`store_tablets ${id} нет`);
  return row;
}

async function sessionsOf(t: KioskTestApp, userId: string) {
  return t.q<{
    id: string;
    device_id: string;
    revoked_at: Date | null;
    revoke_reason: string | null;
    expires_at: Date;
  }>(
    `SELECT id, device_id, revoked_at, revoke_reason, expires_at FROM sessions WHERE user_id = $1 ORDER BY issued_at, id`,
    [userId],
  );
}

describe('kiosk: отключение, KIOSK_REVOKED, срок и подключение заново (KIOSK_MODE=true)', () => {
  const t = new KioskTestApp();
  let warehouseId: string;
  let variant: SaleableVariant;
  let owner: PosActor;

  beforeAll(async () => {
    // Как startKiosk стенда; пробные маршруты /kiosk/* не нужны — контроллеры подключения, кода, выхода настоящие.
    await t.start({
      env: { QR_PROVIDER: 'none', KIOSK_MODE: 'true', OTP_GLOBAL_PER_MIN: '100000' },
      skuCount: 40,
      modules: [CartModule, OrdersModule, ProfileModule, PublicSettingsModule, KioskModule],
      guards: [KIOSK_ACCESS_GUARD],
      fakePorts: true,
      jobs: false,
    });
    await createDevOutbox(t);
    warehouseId = await t.defaultWarehouseId();
    variant = (await t.saleableVariants(1))[0];
    owner = await t.actor({ role: 'owner' });
  });

  afterAll(async () => {
    await t.stop();
  });

  /** Подключение через API (08 §4.18.11) администратором на «устройстве планшета» (`admin.deviceKey`). */
  async function enroll(name: string): Promise<Enrolled> {
    const admin = await t.actor({ role: 'admin' });
    const r = await call(t, 'post', '/admin/store-tablets', admin, {
      body: { name, warehouseId },
      stepUp: await t.stepUp(admin, 'kiosk.manage'),
      idem: randomUUID(),
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const id = String(r.body.tablet.id);
    return {
      admin,
      id,
      userId: (await tabletRow(t, id)).user_id,
      tab: { token: String(r.body.accessToken), deviceKey: admin.deviceKey },
      refreshToken: String(r.body.refreshToken),
      exitCode: String(r.body.exitCode),
      sid: String(r.body.sid),
    };
  }

  /** Администратор, вошедший на том же устройстве (`X-Device-Id` планшета) — SCR-54 «Подключить заново». */
  async function adminOnDevice(deviceKey: string): Promise<PosActor> {
    const a = await t.actor({ role: 'admin' });
    await t.q(`UPDATE devices SET device_key = $1 WHERE id = $2`, [deviceKey, a.deviceId]);
    const pv = (await t.q<{ v: number }>(`SELECT permissions_version AS v FROM users WHERE id = $1`, [a.userId]))[0].v;
    const { token } = await t.jwt.signAccess({
      sub: a.userId,
      kind: 'staff',
      roles: ['admin'],
      permissionsVersion: pv,
      deviceId: deviceKey,
      sid: a.sessionId,
    });
    return { ...a, deviceKey, token };
  }

  async function reconnect(admin: PosActor, id: string, o: { idem?: string; stepUp?: string; body?: unknown } = {}) {
    return call(t, 'post', `/admin/store-tablets/${id}/reconnect`, admin, {
      body: o.body ?? {},
      stepUp: o.stepUp ?? (await t.stepUp(admin, 'kiosk.manage')),
      idem: o.idem ?? randomUUID(),
    });
  }

  async function revoke(id: string): Promise<void> {
    const admin = await t.actor({ role: 'admin' });
    const r = await call(t, 'post', `/admin/store-tablets/${id}/revoke`, admin, {
      body: {},
      stepUp: await t.stepUp(admin, 'kiosk.manage'),
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
  }

  /** Действующий код `kiosk_order` планшета (код к заявке на вымышленный номер) — для проверки погашения. */
  async function kioskOrderCode(tab: Subject): Promise<string> {
    const c0 = await call(t, 'get', '/cart', tab);
    expect(c0.status, JSON.stringify(c0.body)).toBe(200);
    const put = await call(t, 'put', `/cart/items/${variant.variantId}`, tab, {
      body: {
        quantity: { value: '1', unitId: variant.unitId, packagingId: null },
        rowVersion: c0.body.rowVersion as number,
      },
    });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    const otp = await call(t, 'post', '/kiosk/order-otp', tab, {
      body: { phone: freshPhone(), cartId: c0.body.id, noticeVersion: NOTICE },
    });
    expect(otp.status, JSON.stringify(otp.body)).toBe(202);
    await t.app.get<OtpProvider>(OTP_PROVIDER, { strict: false }).drain();
    return String(otp.body.challengeId);
  }

  it('T-KIOSK-003 next request 401 KIOSK_REVOKED: живой access после отключения — KIOSK_REVOKED от AuthGuard, в том числе через denylist jti', async () => {
    const e = await enroll('Планшет у входа');
    expect((await call(t, 'get', '/cart', e.tab)).status).toBe(200);
    const code = await kioskOrderCode(e.tab);
    await revoke(e.id);
    expect((await sessionsOf(t, e.userId)).map((s) => s.revoke_reason)).toEqual(['kiosk_revoked']);
    expect(await t.q(`SELECT status::text AS status FROM otp_challenges WHERE id = $1`, [code])).toEqual([
      { status: 'superseded' },
    ]);

    const logsBefore = t.logs.lines.length;
    for (const path of ['/cart', '/me', '/settings/public']) {
      const r = await call(t, 'get', path, e.tab);
      expect([r.status, r.body.code], path).toEqual([401, 'KIOSK_REVOKED']);
      expect(r.body.detail).toBe('Планшет отключён администратором.');
    }
    expect((await call(t, 'post', '/kiosk/exit', e.tab, { body: { code: e.exitCode } })).body.code).toBe(
      'KIOSK_REVOKED',
    );
    // журнал отказа — код и причина, без токена
    const logs = t.logs.lines.slice(logsBefore).join('\n');
    expect(logs).toContain('KIOSK_REVOKED');
    expect(logs).not.toContain(e.tab.token);

    // denylist jti в БД (другой путь отзыва) — проверка KIOSK_REVOKED идёт раньше denylist (09 §8.9 п. 8 (б))
    const jti = String(claimsOf(e.tab.token).jti);
    await t.q(
      `INSERT INTO token_denylist (jti, token_kind, expires_at, reason) VALUES ($1, 'access', now() + interval '10 minutes', 'revoked')`,
      [jti],
    );
    t.app.get(AuthStateCache, { strict: false }).clear();
    expect((await call(t, 'get', '/cart', e.tab)).body.code).toBe('KIOSK_REVOKED');

    // прочие отзывы сессии планшета — SESSION_REVOKED (08 §2.2): logout в БД
    const other = await enroll('Планшет у кассы');
    await t.q(`UPDATE sessions SET revoked_at = now(), revoke_reason = 'logout' WHERE user_id = $1`, [other.userId]);
    t.app.get(AuthStateCache, { strict: false }).clear();
    const r2 = await call(t, 'get', '/cart', other.tab);
    expect([r2.status, r2.body.code]).toEqual([401, 'SESSION_REVOKED']);

    // паритет: сотрудник с отозванной сессией — SESSION_REVOKED, как прежде
    const seller = await t.actor({ role: 'seller' });
    await t.q(`UPDATE sessions SET revoked_at = now(), revoke_reason = 'logout' WHERE id = $1`, [seller.sessionId]);
    t.app.get(AuthStateCache, { strict: false }).clear();
    expect((await call(t, 'get', '/cart', seller)).body.code).toBe('SESSION_REVOKED');
  });

  it('T-KIOSK-060 refresh after revoke → KIOSK_REVOKED (текущий, предыдущий и вытесненный токен), expiry → SESSION_REVOKED', async () => {
    const e = await enroll('Планшет у витрины');
    const r1 = await refresh(t, e.refreshToken, e.admin.deviceKey);
    expect(r1.status, JSON.stringify(r1.body)).toBe(200);
    const current = String(r1.body.refreshToken);
    await revoke(e.id);
    for (const token of [current, e.refreshToken]) {
      const r = await refresh(t, token, e.admin.deviceKey);
      expect([r.status, r.body.code, r.body.reason]).toEqual([401, 'KIOSK_REVOKED', undefined]);
      expect(r.body.accessToken).toBeUndefined();
    }
    // вытесненный токен (повтор verify / грация) — та же сессия, тот же ответ
    await t.q(`UPDATE sessions SET superseded_refresh_hash = $1 WHERE id = $2`, [sha256('superseded-x'), e.sid]);
    expect((await refresh(t, 'superseded-x', e.admin.deviceKey)).body.code).toBe('KIOSK_REVOKED');
    // неизвестный токен — SESSION_REVOKED
    expect((await refresh(t, 'unknown-token', e.admin.deviceKey)).body.code).toBe('SESSION_REVOKED');

    // срок вышел: простой 7 дн и абсолютный 180 дн → SESSION_REVOKED expired, сессия отозвана с expired
    const idle = await enroll('Планшет простоя');
    await t.q(`UPDATE sessions SET idle_expires_at = now() - interval '1 second' WHERE id = $1`, [idle.sid]);
    const ri = await refresh(t, idle.refreshToken, idle.admin.deviceKey);
    expect([ri.status, ri.body.code, ri.body.reason]).toEqual([401, 'SESSION_REVOKED', 'expired']);
    const abs = await enroll('Планшет срока');
    await t.q(`UPDATE sessions SET expires_at = now() - interval '1 second' WHERE id = $1`, [abs.sid]);
    const ra = await refresh(t, abs.refreshToken, abs.admin.deviceKey);
    expect([ra.status, ra.body.code, ra.body.reason]).toEqual([401, 'SESSION_REVOKED', 'expired']);
    expect((await sessionsOf(t, abs.userId)).map((s) => s.revoke_reason)).toEqual(['expired']);
    // отозванная по сроку — уже не KIOSK_REVOKED и повторно
    expect((await refresh(t, abs.refreshToken, abs.admin.deviceKey)).body.code).toBe('SESSION_REVOKED');
    // AuthGuard: истёкшая сессия планшета — SESSION_REVOKED
    t.app.get(AuthStateCache, { strict: false }).clear();
    expect((await call(t, 'get', '/cart', abs.tab)).body.code).toBe('SESSION_REVOKED');
  });

  it('T-KIOSK-049 7/180 days expiry, reconnect same row and user, new exit code, audit kiosk.reconnected', async () => {
    const e = await enroll('Планшет у входа');
    const before = await tabletRow(t, e.id);
    const hasher = t.app.get(ExitCodeHasher, { strict: false });
    // 180 дней с подключения: абсолютный срок сессии планшета
    const [s0] = await sessionsOf(t, e.userId);
    expect(s0.expires_at.getTime() - Date.now()).toBeGreaterThan(180 * DAY - 60_000);
    // срок вышел (простой) → SESSION_REVOKED; признак планшета остаётся, выход — аварийным кодом (без связи)
    await t.q(`UPDATE sessions SET idle_expires_at = now() - interval '1 second' WHERE id = $1`, [e.sid]);
    const gone = await refresh(t, e.refreshToken, e.admin.deviceKey);
    expect([gone.status, gone.body.code, gone.body.reason]).toEqual([401, 'SESSION_REVOKED', 'expired']);
    const code = await t.q<{ id: string }>(`SELECT id FROM otp_challenges WHERE kiosk_tablet_id = $1`, [e.id]);
    expect(code).toEqual([]);

    // вход администратора на этом устройстве → «Подключить заново этот планшет»
    const admin = await adminOnDevice(e.admin.deviceKey);
    const adminJti = String(claimsOf(admin.token).jti);
    const idem = randomUUID();
    const logsBefore = t.logs.lines.length;
    const r = await reconnect(admin, e.id, { idem });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(String(r.headers['cache-control'])).toContain('no-store');
    expect(Object.keys(r.body).sort()).toEqual([
      'accessExpiresIn',
      'accessToken',
      'exitCode',
      'refreshExpiresAt',
      'refreshToken',
      'sid',
      'tablet',
    ]);
    expect(r.body.exitCode).toMatch(/^\d{8}$/);
    expect(r.body.sid).not.toBe(e.sid);
    expect(r.body.tablet).toMatchObject({ id: e.id, name: 'Планшет у входа', warehouseId, status: 'active' });
    expect(r.body.tablet.reconnectedAt).not.toBeNull();
    expect(r.body.tablet.revokedAt).toBeNull();
    expect(r.body.tablet.lockTaskEnabled).toBeNull();
    // срок подключения в списке = новый абсолютный срок сессии (напоминание SCR-54 за 30 дней — от него)
    expect(Date.parse(String(r.body.tablet.expiresAt))).toBe(Date.parse(String(r.body.refreshExpiresAt)));
    expect(Date.parse(String(r.body.refreshExpiresAt)) - Date.now()).toBeGreaterThan(180 * DAY - 60_000);
    expect(claimsOf(String(r.body.accessToken))).toMatchObject({ sub: e.userId, kind: 'kiosk', roles: ['kiosk'] });

    // та же строка и тот же технический пользователь; новый код, прежний недействителен
    const after = await tabletRow(t, e.id);
    expect(after).toMatchObject({
      user_id: e.userId,
      device_id: before.device_id,
      status: 'active',
      exit_code_used_at: null,
      exit_failed_attempts: 0,
      exit_locked_until: null,
      lock_task_enabled: null,
      reconnected_by_user_id: admin.userId,
      revoked_at: null,
      revoked_by_user_id: null,
      revoke_reason: null,
    });
    expect(after.exit_code_hash).not.toBe(before.exit_code_hash);
    expect((await hasher.verify(String(r.body.exitCode), e.id, after.exit_code_hash, 1)).ok).toBe(true);
    if (r.body.exitCode !== e.exitCode) {
      expect((await hasher.verify(e.exitCode, e.id, after.exit_code_hash, 1)).ok).toBe(false);
    }
    expect(await t.q(`SELECT id FROM users WHERE id = $1 AND kind = 'kiosk'`, [e.userId])).toHaveLength(1);
    expect(await t.q(`SELECT id FROM store_tablets WHERE user_id = $1`, [e.userId])).toHaveLength(1);
    const ss = await sessionsOf(t, e.userId);
    expect(ss.map((s) => [s.id === r.body.sid, s.revoke_reason])).toEqual([
      [false, 'expired'],
      [true, null],
    ]);

    // сессия администратора на устройстве завершена, его access — в denylist
    expect(await t.q(`SELECT revoke_reason FROM sessions WHERE id = $1`, [admin.sessionId])).toEqual([
      { revoke_reason: 'logout' },
    ]);
    expect(await t.q(`SELECT 1 FROM token_denylist WHERE jti = $1`, [adminJti])).toHaveLength(1);
    expect((await call(t, 'get', '/admin/store-tablets', admin)).status).toBe(401);

    // новые токены планшета работают; прежний код аварийного выхода — 422 (заменён), новый — 200
    const tab = { token: String(r.body.accessToken), deviceKey: admin.deviceKey };
    expect((await call(t, 'get', '/me', tab)).body).toEqual({
      kind: 'kiosk',
      tablet: { id: e.id, name: 'Планшет у входа', warehouseId },
    });
    if (r.body.exitCode !== e.exitCode) {
      const old = await call(t, 'post', '/kiosk/exit', tab, { body: { code: e.exitCode } });
      expect([old.status, old.body.code, old.body.attemptsLeft]).toEqual([422, 'KIOSK_EXIT_CODE_INVALID', 4]);
    }
    const ok = await call(t, 'post', '/kiosk/exit', tab, { body: { code: String(r.body.exitCode) } });
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);

    // аудит kiosk.reconnected: актор — администратор, step-up, без токенов и кода
    const audit = await t.auditRows('kiosk.reconnected', e.id);
    expect(audit).toEqual([
      {
        action: 'kiosk.reconnected',
        result: 'ok',
        actor_user_id: admin.userId,
        step_up_method: 'pin',
        entity_id: e.id,
        after: {
          tabletId: e.id,
          status: 'active',
          name: 'Планшет у входа',
          warehouseId,
          userId: e.userId,
          deviceId: before.device_id,
          previousDeviceId: before.device_id,
          revokedAdminSessions: 1,
          revokedTabletSessions: 0,
          gashedKioskCodes: 0,
        },
      },
    ]);
    const auditText = JSON.stringify(
      await t.q(`SELECT before, after, reason FROM audit_logs WHERE action = 'kiosk.reconnected' AND entity_id = $1`, [
        e.id,
      ]),
    );
    for (const secret of [String(r.body.exitCode), String(r.body.accessToken), String(r.body.refreshToken)]) {
      expect(auditText).not.toContain(secret);
    }
    // в хранилище идемпотентности — только идентификаторы; в журнале — без секретов
    const keys = await t.q<{ status: number; body: string }>(
      `SELECT response_status AS status, response_body::text AS body FROM idempotency_keys WHERE key = $1`,
      [idem],
    );
    expect(keys.map((k) => k.status)).toEqual([200]);
    expect(Object.keys(JSON.parse(keys[0].body) as object).sort()).toEqual([
      'accessExpiresAt',
      'accessJti',
      'sessionId',
      'tabletId',
      'userId',
    ]);
    const logs = t.logs.lines.slice(logsBefore).join('\n');
    expect(logs).toContain('kiosk.reconnected');
    for (const secret of [String(r.body.exitCode), String(r.body.accessToken), String(r.body.refreshToken)]) {
      expect(logs).not.toContain(secret);
      expect(keys[0].body).not.toContain(secret);
    }
  });

  it('T-KIOSK-049 reconnect из revoked и с заменённого устройства: новая строка devices, копия на прежнем — KIOSK_REVOKED, коды kiosk_order погашены', async () => {
    const e = await enroll('Планшет у склада');
    const challenge = await kioskOrderCode(e.tab);
    // устройство заменено: администратор входит на новом устройстве и подключает ту же запись
    const admin = await t.actor({ role: 'admin' });
    const r = await reconnect(admin, e.id);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const after = await tabletRow(t, e.id);
    const devices = await t.q<{ id: string; device_key: string }>(
      `SELECT id, device_key FROM devices WHERE user_id = $1 ORDER BY created_at, id`,
      [e.userId],
    );
    expect(devices.map((d) => d.device_key).sort()).toEqual([e.admin.deviceKey, admin.deviceKey].sort());
    expect(devices.find((d) => d.id === after.device_id)?.device_key).toBe(admin.deviceKey);
    expect(await t.q(`SELECT status::text AS status FROM otp_challenges WHERE id = $1`, [challenge])).toEqual([
      { status: 'superseded' },
    ]);
    // копия приложения на прежнем устройстве — KIOSK_REVOKED (AuthGuard и refresh)
    expect((await call(t, 'get', '/cart', e.tab)).body.code).toBe('KIOSK_REVOKED');
    expect((await refresh(t, e.refreshToken, e.admin.deviceKey)).body.code).toBe('KIOSK_REVOKED');
    const [audit] = await t.auditRows('kiosk.reconnected', e.id);
    expect(audit.after).toMatchObject({
      deviceId: after.device_id,
      previousDeviceId: devices.find((d) => d.device_key === e.admin.deviceKey)?.id,
      revokedTabletSessions: 1,
      gashedKioskCodes: 1,
    });
    const newTab = { token: String(r.body.accessToken), deviceKey: admin.deviceKey };
    expect((await call(t, 'get', '/cart', newTab)).status).toBe(200);

    // из revoked: отключение, затем подключение заново — active, поля отключения очищены
    await revoke(e.id);
    expect((await tabletRow(t, e.id)).status).toBe('revoked');
    const again = await adminOnDevice(admin.deviceKey);
    const back = await reconnect(again, e.id);
    expect(back.status, JSON.stringify(back.body)).toBe(200);
    expect(await tabletRow(t, e.id)).toMatchObject({
      status: 'active',
      revoked_at: null,
      revoked_by_user_id: null,
      revoke_reason: null,
      reconnected_by_user_id: again.userId,
    });
    const [, second] = await t.auditRows('kiosk.reconnected', e.id);
    expect(second.after).toMatchObject({ revokedTabletSessions: 0, status: 'active' });
    const before2 = await t.q<{ before: unknown }>(
      `SELECT before FROM audit_logs WHERE action = 'kiosk.reconnected' AND entity_id = $1 ORDER BY chain_seq`,
      [e.id],
    );
    expect(before2.map((b) => b.before)).toEqual([
      { status: 'active', deviceId: expect.any(String) as string },
      { status: 'revoked', deviceId: after.device_id },
    ]);
    noPii(await t.q(`SELECT before, after FROM audit_logs WHERE entity_id = $1`, [e.id]));
    const tab2 = { token: String(back.body.accessToken), deviceKey: again.deviceKey };
    expect((await call(t, 'get', '/me', tab2)).status).toBe(200);
  });

  it('T-KIOSK-049 reconnect closes the previous buyer cart (04 FLOW-045.A1): после отключения и аварийного выхода — пустая корзина с новым id, аудит cart.cleared kiosk_reconnect', async () => {
    const clearedOf = (userId: string) =>
      t.q<{ entity_id: string; after: Record<string, unknown> }>(
        `SELECT a.entity_id::text AS entity_id, a.after FROM audit_logs a
           JOIN carts c ON c.id::text = a.entity_id::text
          WHERE a.action = 'cart.cleared' AND c.owner_user_id = $1 ORDER BY a.chain_seq`,
        [userId],
      );
    for (const via of ['revoke', 'exit'] as const) {
      const e = await enroll(`Планшет корзины (${via})`);
      // покупатель посреди покупки: строка в активной корзине технического пользователя
      const c0 = await call(t, 'get', '/cart', e.tab);
      expect(c0.status, JSON.stringify(c0.body)).toBe(200);
      const oldCartId = String(c0.body.id);
      const put = await call(t, 'put', `/cart/items/${variant.variantId}`, e.tab, {
        body: {
          quantity: { value: '1', unitId: variant.unitId, packagingId: null },
          rowVersion: c0.body.rowVersion as number,
        },
      });
      expect(put.status, JSON.stringify(put.body)).toBe(200);
      if (via === 'revoke') await revoke(e.id);
      else expect((await call(t, 'post', '/kiosk/exit', e.tab, { body: { code: e.exitCode } })).status).toBe(200);
      // отключение и выход корзину не трогают (09 §8.9 п. 6) — закрывает подключение заново
      expect(await t.q(`SELECT status::text AS status FROM carts WHERE id = $1`, [oldCartId]), via).toEqual([
        { status: 'active' },
      ]);

      const admin = await adminOnDevice(e.admin.deviceKey);
      const r = await reconnect(admin, e.id);
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      expect(
        await t.q(`SELECT status::text AS status, cleared_at IS NOT NULL AS cleared FROM carts WHERE id = $1`, [
          oldCartId,
        ]),
        via,
      ).toEqual([{ status: 'cleared', cleared: true }]);
      const cleared = await clearedOf(e.userId);
      expect(cleared, via).toEqual([
        {
          entity_id: oldCartId,
          after: { cartId: oldCartId, itemsCount: 1, parked: false, reason: 'kiosk_reconnect' },
        },
      ]);
      noPii(cleared);
      expect(JSON.stringify(cleared)).not.toContain(e.exitCode);

      // ещё одно подключение заново без активной корзины — строки cart.cleared нет
      const admin2 = await adminOnDevice(e.admin.deviceKey);
      const r2 = await reconnect(admin2, e.id);
      expect(r2.status, JSON.stringify(r2.body)).toBe(200);
      expect(await clearedOf(e.userId), via).toHaveLength(1);

      // новая сессия того же users.id: GET /cart — пустая корзина с новым id, строки прошлого покупателя нет
      const tab2 = { token: String(r2.body.accessToken), deviceKey: admin2.deviceKey };
      const c1 = await call(t, 'get', '/cart', tab2);
      expect(c1.status, JSON.stringify(c1.body)).toBe(200);
      expect(c1.body.id, via).not.toBe(oldCartId);
      expect(c1.body.items, via).toEqual([]);
      expect(
        await t.q(`SELECT count(*)::int AS n FROM carts WHERE owner_user_id = $1 AND status = 'active'`, [e.userId]),
      ).toEqual([{ n: 1 }]);
    }
  });

  it('T-KIOSK-049 reconnect: отказы (step-up, owner, ключ, тело, 404) и повтор ключа один раз', async () => {
    const e = await enroll('Планшет отказов');
    const admin = await adminOnDevice(e.admin.deviceKey);
    const path = `/admin/store-tablets/${e.id}/reconnect`;
    const noStepUp = await call(t, 'post', path, admin, { body: {}, idem: randomUUID() });
    expect([noStepUp.status, noStepUp.body.code]).toEqual([403, 'STEP_UP_REQUIRED']);
    const asOwner = await call(t, 'post', path, owner, {
      body: {},
      stepUp: await t.stepUp(owner, 'kiosk.manage'),
      idem: randomUUID(),
    });
    expect([asOwner.status, asOwner.body.code]).toEqual([403, 'FORBIDDEN']);
    const stepUp = await t.stepUp(admin, 'kiosk.manage');
    const noKey = await call(t, 'post', path, admin, { body: {}, stepUp });
    expect(noKey.status).toBe(400);
    expect(noKey.body.errors).toEqual([expect.objectContaining({ rule: 'idempotency_key_required' })]);
    const extra = await call(t, 'post', path, admin, { body: { name: 'x' }, stepUp, idem: randomUUID() });
    expect(extra.status).toBe(400);
    expect(extra.body.errors).toEqual([expect.objectContaining({ field: 'name', rule: 'forbidden_field' })]);
    const missingKey = randomUUID();
    const missing = await call(t, 'post', `/admin/store-tablets/${randomUUID()}/reconnect`, admin, {
      body: {},
      stepUp,
      idem: missingKey,
    });
    expect([missing.status, missing.body.code]).toEqual([404, 'NOT_FOUND']);
    expect(await t.q(`SELECT 1 FROM idempotency_keys WHERE key = $1`, [missingKey])).toEqual([]);
    // токен планшета на /admin/* — закрытый список
    const fromTablet = await call(t, 'post', path, e.tab, { body: {}, stepUp, idem: randomUUID() });
    expect([fromTablet.status, fromTablet.body.reason]).toEqual([403, 'kiosk_closed_list']);
    // ничего не изменилось
    expect((await tabletRow(t, e.id)).reconnected_at).toBeNull();
    expect(await t.auditRows('kiosk.reconnected', e.id)).toEqual([]);

    // повтор тем же ключом (08 §2.7): «другой процесс» — снимок AuthGuard до COMMIT; один раз, затем replay_used
    const cache = t.app.get(AuthStateCache, { strict: false });
    const adminJti = String(claimsOf(admin.token).jti);
    const stale = await cache.snapshot({ userId: admin.userId, sessionId: admin.sessionId, jti: adminJti });
    const idem = randomUUID();
    const first = await reconnect(admin, e.id, { idem, stepUp });
    expect(first.status, JSON.stringify(first.body)).toBe(200);
    const local = await reconnect(admin, e.id, { idem, stepUp });
    expect([local.status, local.body.code]).toEqual([401, 'SESSION_REVOKED']);
    const original = cache.snapshot.bind(cache);
    const spy = vi
      .spyOn(cache, 'snapshot')
      .mockImplementation((q) => (q.jti === adminJti ? Promise.resolve(stale) : original(q)));
    try {
      const replay = await reconnect(admin, e.id, { idem, stepUp });
      expect(replay.status, JSON.stringify(replay.body)).toBe(200);
      expect(replay.headers['idempotent-replayed']).toBe('true');
      expect(replay.body.sid).toBe(first.body.sid);
      expect(replay.body.refreshToken).not.toBe(first.body.refreshToken);
      const second = await reconnect(admin, e.id, { idem, stepUp });
      expect(second.status).toBe(422);
      expect(second.body).toMatchObject({ code: 'IDEMPOTENCY_KEY_REUSED', reason: 'replay_used' });
    } finally {
      spy.mockRestore();
    }
    expect(await t.auditRows('kiosk.reconnected', e.id)).toHaveLength(1);
  });

  it('T-KIOSK-066 kiosk.exit_code_used: аудит аварийного выхода — актор планшет, без кода и ПДн', async () => {
    const e = await enroll('Планшет аудита');
    const challenge = await kioskOrderCode(e.tab);
    const r = await call(t, 'post', '/kiosk/exit', e.tab, { body: { code: e.exitCode } });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const row = await tabletRow(t, e.id);
    expect(row).toMatchObject({ status: 'revoked', revoked_by_user_id: null, revoke_reason: 'kiosk.exit_code_used' });
    const audit = await t.auditRows('kiosk.exit_code_used', e.id);
    expect(audit).toEqual([
      {
        action: 'kiosk.exit_code_used',
        result: 'ok',
        actor_user_id: e.userId,
        step_up_method: null,
        entity_id: e.id,
        after: {
          tabletId: e.id,
          status: 'revoked',
          exitCodeUsedAt: row.exit_code_used_at?.toISOString(),
          revokedSessions: 1,
          gashedKioskCodes: 1,
        },
      },
    ]);
    expect(await t.q(`SELECT status::text AS status FROM otp_challenges WHERE id = $1`, [challenge])).toEqual([
      { status: 'superseded' },
    ]);
    const text = JSON.stringify(await t.q(`SELECT before, after, reason FROM audit_logs WHERE entity_id = $1`, [e.id]));
    expect(text).not.toContain(e.exitCode);
    noPii(JSON.parse(text));
    // повтор после «потерянного» 200 — 401 KIOSK_REVOKED (08 §4.25.5 «Идемпотентность»)
    const again = await call(t, 'post', '/kiosk/exit', e.tab, { body: { code: e.exitCode } });
    expect([again.status, again.body.code]).toEqual([401, 'KIOSK_REVOKED']);
    expect(await t.auditRows('kiosk.exit_code_used', e.id)).toHaveLength(1);
  });
});

describe('kiosk: KIOSK_MODE=false — подключение заново и аварийный выход (ADR-115 п. 28)', () => {
  const t = new KioskTestApp();

  beforeAll(async () => {
    await t.startKiosk({ kioskMode: false });
  });

  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-033 flag off: reconnect 403 KIOSK_DISABLED, /kiosk/exit 403 KIOSK_DISABLED', async () => {
    const tablet = await t.tablet({ name: 'Планшет при выключенном режиме' });
    const admin = await t.actor({ role: 'admin' });
    const before = await t.q(`SELECT * FROM store_tablets WHERE id = $1`, [tablet.tabletId]);
    // до step-up и до ключа: администратор не подтверждает PIN ради операции, которой нет
    const bare = await call(t, 'post', `/admin/store-tablets/${tablet.tabletId}/reconnect`, admin, { body: {} });
    expect([bare.status, bare.body.code]).toEqual([403, 'KIOSK_DISABLED']);
    const full = await call(t, 'post', `/admin/store-tablets/${tablet.tabletId}/reconnect`, admin, {
      body: {},
      stepUp: await t.stepUp(admin, 'kiosk.manage'),
      idem: randomUUID(),
    });
    expect([full.status, full.body.code]).toEqual([403, 'KIOSK_DISABLED']);
    // аварийный выход со связью — 403 KIOSK_DISABLED (приложение проверяет код на устройстве)
    const exit = await call(t, 'post', '/kiosk/exit', tablet, { body: { code: '12345678' } });
    expect([exit.status, exit.body.code]).toEqual([403, 'KIOSK_DISABLED']);
    // ничего не изменилось; список и отключение работают (путь отката)
    expect(await t.q(`SELECT * FROM store_tablets WHERE id = $1`, [tablet.tabletId])).toEqual(before);
    expect((await call(t, 'get', '/admin/store-tablets', admin)).status).toBe(200);
    const rv = await call(t, 'post', `/admin/store-tablets/${tablet.tabletId}/revoke`, admin, {
      body: {},
      stepUp: await t.stepUp(admin, 'kiosk.manage'),
    });
    expect([rv.status, rv.body.status]).toEqual([200, 'revoked']);
    // отключённый планшет при выключенном режиме — 401 KIOSK_REVOKED раньше guard-а планшета
    const after = await call(t, 'get', '/me', tablet);
    expect([after.status, after.body.code]).toEqual([401, 'KIOSK_REVOKED']);
  });
});
