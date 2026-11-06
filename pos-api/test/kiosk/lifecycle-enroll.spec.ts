import { createHash, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { AuthPolicyService } from '../../src/auth/common/auth-policy.js';
import { OTP_PROVIDER, type OtpProvider } from '../../src/auth/otp/otp.provider.js';
import {
  maxSessions,
  nextIdleExpiry,
  SessionIssuer,
  sessionTerms,
} from '../../src/auth/sessions/session-issuer.service.js';
import { STEP_UP_OPERATIONS } from '../../src/auth/step-up/step-up.operations.js';
import { CartModule } from '../../src/cart/cart.module.js';
import { AuthStateCache } from '../../src/common/auth/auth-state.js';
import { ExitCodeFormatError, ExitCodeHasher } from '../../src/common/crypto/exit-code-hasher.service.js';
import { EXIT_CODE_LENGTH, generateExitCode } from '../../src/common/crypto/random.js';
import { parseSecretRing } from '../../src/common/crypto/secret-ring.js';
import { KIOSK_ACCESS_GUARD } from '../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import { PublicSettingsModule } from '../../src/settings/public-settings.module.js';
import { DevicesRepository } from '../../src/users/devices.repository.js';
import { UsersRepository } from '../../src/users/users.repository.js';
import { testSecret } from '../foundation/support/keys.js';
import type { PosActor, SaleableVariant } from '../support/pos-fixture.js';
import { KioskTestApp } from './support/kiosk-fixture.js';

/**
 * Подключение, список, изменение и отключение планшета магазина `/admin/store-tablets*` (08 §4.18.11–§4.18.14, §2.7;
 * 09 §8.9; 07 §5.65; 10 KIOSK-002…KIOSK-004, KIOSK-031; 11 SEC-136, SEC-139…SEC-142; ADR-115; FLOW-043, SCR-54) —
 * **тестовые данные** стенда `kiosk-fixture` (embedded PostgreSQL 17, синтетический каталог; номера покупателей —
 * вымышленные `+996 555 003 xxx`; коды из SMS — из `dev_outbox` поддельного шлюза):
 * - T-KIOSK-001: одна транзакция подключения — пользователь `kind=kiosk` без телефона, профиль, роль, устройство,
 *   сессия `standard`, `store_tablets` (`lock_task_enabled = NULL`), сессия администратора на устройстве завершена,
 *   его access — в denylist, аудит `kiosk.enrolled`; в `idempotency_keys` — только идентификаторы; повтор тем же
 *   ключом — новые токены и новый аварийный код, один раз;
 * - T-KIOSK-002: step-up `kiosk.manage`, только `admin`; `owner` — список 200, подключение и отключение 403;
 * - T-KIOSK-006 (сессия): одна сессия планшета, сроки 180 дн / 7 дн; сроки и лимиты staff/customer — прежние;
 * - T-KIOSK-066: `kiosk.updated` (было/стало) и `kiosk.revoked` без ПДн;
 * - T-KIOSK-033: при `KIOSK_MODE=false` подключение — `403 KIOSK_DISABLED`, список, изменение и отключение — 200;
 * - T-KIOSK-050 / T-KIOSK-068: `appVersion` и `lockTaskEnabled` (NULL после подключения) — в `GET /admin/store-tablets`.
 * Прикладная часть T-KIOSK-001/-002/-033 — `pos-app/test/features/admin/tablets/*` (WP-A05).
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

const NOTICE = '2026-11-04';
const DEV_OUTBOX_SQL = fileURLToPath(new URL('../../db/migrations-dev/0001_dev_outbox.sql', import.meta.url));
const DAY = 24 * 3600_000;
const TABLET_KEYS = [
  'appVersion',
  'enrolledAt',
  'expiresAt',
  'id',
  'lastSeenAt',
  'lockTaskEnabled',
  'name',
  'reconnectedAt',
  'revokedAt',
  'status',
  'warehouseId',
];

let phoneSeq = 0;
/** Вымышленный мобильный номер КР `+996 555 003 xxx` (тестовые данные). */
function freshPhone(): string {
  phoneSeq += 1;
  return `+996555003${String(100 + phoneSeq)}`;
}

async function call(t: KioskTestApp, method: Method, path: string, a?: Subject, o: CallOpts = {}): Promise<Res> {
  let r = t.req(method, path, a, { ...(o.stepUp ? { stepUp: o.stepUp } : {}), ...(o.idem ? { idem: o.idem } : {}) });
  for (const [k, v] of Object.entries(o.headers ?? {})) r = r.set(k, v);
  const res = await (o.body !== undefined ? r.send(o.body as object) : r);
  return {
    status: res.status,
    body: (res.body ?? {}) as Res['body'],
    headers: res.headers,
  };
}

function claimsOf(token: string): Record<string, unknown> {
  const part = token.split('.')[1] ?? '';
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8')) as Record<string, unknown>;
}

/** Поля ответа и записей без номеров телефонов (11 SEC-062, SEC-141). */
function noPii(v: unknown): void {
  expect(JSON.stringify(v)).not.toMatch(/\+?996\d{9}/);
}

async function enroll(
  t: KioskTestApp,
  admin: PosActor,
  body: unknown,
  o: { readonly idem?: string; readonly stepUp?: string | false } = {},
): Promise<Res> {
  const stepUp = o.stepUp === false ? undefined : (o.stepUp ?? (await t.stepUp(admin, 'kiosk.manage')));
  return call(t, 'post', '/admin/store-tablets', admin, { body, stepUp, idem: o.idem ?? randomUUID() });
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
    lock_task_enabled: boolean | null;
    enrolled_by_user_id: string;
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
    kind: string;
    amr: string[];
    created_from_challenge_id: string | null;
    unlocked_until: Date | null;
    revoked_at: Date | null;
    revoke_reason: string | null;
    issued_at: Date;
    expires_at: Date;
    idle_expires_at: Date;
    superseded_refresh_hash: Buffer | null;
    grace_used_at: Date | null;
  }>(
    `SELECT id, kind::text AS kind, amr::text[] AS amr, created_from_challenge_id, unlocked_until, revoked_at,
            revoke_reason, issued_at, expires_at, idle_expires_at, superseded_refresh_hash, grace_used_at
       FROM sessions WHERE user_id = $1 ORDER BY issued_at, id`,
    [userId],
  );
}

async function denied(t: KioskTestApp, jti: string): Promise<boolean> {
  return (await t.q(`SELECT 1 FROM token_denylist WHERE jti = $1`, [jti])).length === 1;
}

function sha256(s: string): Buffer {
  return createHash('sha256').update(s).digest();
}

// ------------------------------------------------------------------------------------------------- без БД

describe('kiosk: аварийный код выхода — CSPRNG и Argon2id(pepper ∥ код ∥ tablet_id) (11 SEC-140)', () => {
  const ring = parseSecretRing('PIN_PEPPER', testSecret(), 1, 'staging');
  const hasher = new ExitCodeHasher(ring);

  it('T-KIOSK-001 exit code: 8 цифр CSPRNG с ведущими нулями; хэш — PHC Argon2id, код и tablet_id в материале', async () => {
    expect(EXIT_CODE_LENGTH).toBe(8);
    const codes = Array.from({ length: 200 }, () => generateExitCode());
    for (const c of codes) expect(c).toMatch(/^\d{8}$/);
    expect(new Set(codes).size).toBeGreaterThan(195);
    const tabletId = randomUUID();
    const code = '01234567';
    const h = await hasher.hash(code, tabletId);
    expect(h.pepperVersion).toBe(1);
    expect(h.exitCodeHash).toMatch(/^\$argon2id\$v=19\$m=19456,t=2,p=1\$/);
    expect(h.exitCodeHash).not.toContain(code);
    expect(await hasher.verify(code, tabletId, h.exitCodeHash, 1)).toEqual({ ok: true, needsRehash: false });
    expect(await hasher.verify(code, tabletId.toUpperCase(), h.exitCodeHash, 1)).toMatchObject({ ok: true });
    expect(await hasher.verify('01234568', tabletId, h.exitCodeHash, 1)).toMatchObject({ ok: false });
    expect(await hasher.verify(code, randomUUID(), h.exitCodeHash, 1)).toMatchObject({ ok: false }); // другой планшет
    expect(await hasher.verify(code, tabletId, h.exitCodeHash, 7)).toMatchObject({ ok: false }); // версии pepper нет
    expect(await hasher.verify('1234567', tabletId, h.exitCodeHash, 1)).toMatchObject({ ok: false });
    expect(await hasher.verify(code, tabletId, 'повреждённый', 1)).toMatchObject({ ok: false });
    await expect(hasher.hash('1234', tabletId)).rejects.toBeInstanceOf(ExitCodeFormatError);
    // другой pepper — другой хэш, прежний код с ним не проходит
    const other = new ExitCodeHasher(parseSecretRing('PIN_PEPPER', testSecret(), 1, 'staging'));
    expect(await other.verify(code, tabletId, h.exitCodeHash, 1)).toMatchObject({ ok: false });
  });

  it('step-up kiosk.manage — операция 08 §2.12 (26 значений, ADR-115)', () => {
    expect(STEP_UP_OPERATIONS).toContain('kiosk.manage');
    expect(STEP_UP_OPERATIONS).toHaveLength(26);
  });
});

// ------------------------------------------------------------------------------------------------- KIOSK_MODE=true

describe('kiosk: /admin/store-tablets — подключение, список, изменение, отключение (KIOSK_MODE=true)', () => {
  const t = new KioskTestApp();
  let warehouseId: string;
  let warehouse2: string;
  let variant: SaleableVariant;
  let owner: PosActor;

  beforeAll(async () => {
    // Как startKiosk стенда; пробные маршруты /kiosk/* не нужны — контроллеры подключения, кода и сброса настоящие.
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
    const ins = await t.q<{ id: string }>(
      `INSERT INTO warehouses (synced_at, source_hash, name, sort_order)
       VALUES (now(), 'kiosk-test', 'Склад стенда у кассы', 97) RETURNING id`,
    );
    warehouse2 = ins[0].id;
    variant = (await t.saleableVariants(1))[0];
    owner = await t.actor({ role: 'owner' });
  });

  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-001 enroll creates kiosk user, profile, device, standard session; ends admin session; audit kiosk.enrolled', async () => {
    const admin = await t.actor({ role: 'admin' });
    const adminJti = String(claimsOf(admin.token).jti);
    const idem = randomUUID();
    const logsBefore = t.logs.lines.length;
    const r = await enroll(t, admin, { name: '  Планшет у входа  ', warehouseId }, { idem });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
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
    const { tablet, accessToken, refreshToken, exitCode, sid } = r.body as {
      tablet: Record<string, unknown>;
      accessToken: string;
      refreshToken: string;
      exitCode: string;
      sid: string;
    };
    expect(exitCode).toMatch(/^\d{8}$/);
    expect(r.body.accessExpiresIn).toBe(900);
    expect(Object.keys(tablet).sort()).toEqual(TABLET_KEYS);
    expect(tablet).toMatchObject({
      name: 'Планшет у входа',
      warehouseId,
      status: 'active',
      reconnectedAt: null,
      revokedAt: null,
      lastSeenAt: null,
      lockTaskEnabled: null,
      appVersion: null,
    });
    expect(Date.parse(String(tablet.expiresAt))).toBe(Date.parse(String(r.body.refreshExpiresAt)));

    // access-JWT планшета: kind=kiosk, роль kiosk, amr ["pin"], то же устройство
    const c = claimsOf(accessToken);
    expect(c).toMatchObject({ kind: 'kiosk', roles: ['kiosk'], amr: ['pin'], sid, deviceId: admin.deviceKey });

    // технический пользователь: kind=kiosk, без телефона, active (значение по умолчанию — pending), профиль, роль kiosk
    const st = await tabletRow(t, String(tablet.id));
    expect(c.sub).toBe(st.user_id);
    expect(
      await t.q(`SELECT kind::text AS kind, status::text AS status, phone_e164 FROM users WHERE id = $1`, [st.user_id]),
    ).toEqual([{ kind: 'kiosk', status: 'active', phone_e164: null }]);
    expect(
      await t.q(`SELECT full_name, home_warehouse_id FROM user_profiles WHERE user_id = $1`, [st.user_id]),
    ).toEqual([{ full_name: 'Планшет у входа', home_warehouse_id: warehouseId }]);
    expect(
      await t.q(
        `SELECT r.code::text AS code, ur.granted_by_user_id FROM user_roles ur JOIN roles r ON r.id = ur.role_id
          WHERE ur.user_id = $1 AND ur.revoked_at IS NULL`,
        [st.user_id],
      ),
    ).toEqual([{ code: 'kiosk', granted_by_user_id: admin.userId }]);
    // устройство — тот же device_key, своя строка devices технического пользователя
    const dev = await t.q<{ id: string; device_key: string; platform: string }>(
      `SELECT id, device_key, platform::text AS platform FROM devices WHERE user_id = $1`,
      [st.user_id],
    );
    expect(dev).toEqual([{ id: st.device_id, device_key: admin.deviceKey, platform: 'android' }]);
    // одна сессия standard, amr pin, без челленджа и без idle-блокировки
    const sessions = await sessionsOf(t, st.user_id);
    expect(sessions).toHaveLength(1);
    expect(sessions[0]).toMatchObject({
      id: sid,
      kind: 'standard',
      amr: ['pin'],
      created_from_challenge_id: null,
      unlocked_until: null,
      revoked_at: null,
    });
    // store_tablets: active, хэш кода (не сам код), версия pepper, lock_task_enabled = NULL, кто подключил
    expect(st).toMatchObject({
      status: 'active',
      exit_code_pepper_version: 1,
      exit_code_used_at: null,
      exit_failed_attempts: 0,
      lock_task_enabled: null,
      enrolled_by_user_id: admin.userId,
      revoked_at: null,
      revoke_reason: null,
    });
    expect(st.exit_code_hash).toMatch(/^\$argon2id\$/);
    expect(st.exit_code_hash).not.toContain(exitCode);
    const hasher = t.app.get(ExitCodeHasher, { strict: false });
    expect((await hasher.verify(exitCode, st.id, st.exit_code_hash, st.exit_code_pepper_version)).ok).toBe(true);

    // сессия администратора на этом устройстве завершена (logout), его access — в token_denylist
    expect(
      await t.q(`SELECT revoke_reason FROM sessions WHERE id = $1 AND revoked_at IS NOT NULL`, [admin.sessionId]),
    ).toEqual([{ revoke_reason: 'logout' }]);
    expect(await denied(t, adminJti)).toBe(true);
    const gone = await call(t, 'get', '/admin/store-tablets', admin);
    expect(gone.status).toBe(401);
    expect(gone.body.code).toBe('SESSION_REVOKED');

    // токен планшета работает: GET /me — форма планшета
    const tab = { token: accessToken, deviceKey: admin.deviceKey };
    const me = await call(t, 'get', '/me', tab);
    expect(me.status, JSON.stringify(me.body)).toBe(200);
    expect(me.body).toEqual({ kind: 'kiosk', tablet: { id: tablet.id, name: 'Планшет у входа', warehouseId } });

    // аудит kiosk.enrolled: актор — admin, step-up pin; без токенов и кода
    const audit = await t.auditRows('kiosk.enrolled', String(tablet.id));
    expect(audit).toEqual([
      {
        action: 'kiosk.enrolled',
        result: 'ok',
        actor_user_id: admin.userId,
        step_up_method: 'pin',
        entity_id: tablet.id,
        after: {
          tabletId: tablet.id,
          name: 'Планшет у входа',
          warehouseId,
          userId: st.user_id,
          deviceId: st.device_id,
          revokedAdminSessions: 1,
          revokedTabletSessions: 0,
        },
      },
    ]);
    const auditText = JSON.stringify(
      await t.q(`SELECT before, after, reason FROM audit_logs WHERE request_id IS NOT NULL ORDER BY chain_seq`),
    );
    for (const secret of [exitCode, accessToken, refreshToken]) expect(auditText).not.toContain(secret);

    // хранилище идемпотентности: только идентификаторы (08 §2.7, 11 SEC-141 п. 5)
    const keys = await t.q<{ status: string; response_status: number; body: string; resource_id: string }>(
      `SELECT status, response_status, response_body::text AS body, resource_id FROM idempotency_keys WHERE key = $1`,
      [idem],
    );
    expect(keys).toHaveLength(1);
    expect(keys[0]).toMatchObject({ status: 'completed', response_status: 201, resource_id: tablet.id });
    expect(Object.keys(JSON.parse(keys[0].body) as object).sort()).toEqual([
      'accessExpiresAt',
      'accessJti',
      'sessionId',
      'tabletId',
      'userId',
    ]);
    for (const secret of [exitCode, accessToken, refreshToken, 'eyJ']) expect(keys[0].body).not.toContain(secret);

    // журналы — без токенов и кода (11 SEC-062, SEC-140)
    const logs = t.logs.lines.slice(logsBefore).join('\n');
    for (const secret of [exitCode, accessToken, refreshToken]) expect(logs).not.toContain(secret);
    expect(logs).toContain('kiosk.enrolled');
  });

  it('T-KIOSK-001 registration-style replay: тот же ключ — новые токены и новый код один раз, затем 422 replay_used', async () => {
    const admin = await t.actor({ role: 'admin' });
    const cache = t.app.get(AuthStateCache, { strict: false });
    const adminJti = String(claimsOf(admin.token).jti);
    // снимок «другого процесса» до подключения (кэш AuthGuard ≤ 60 с, 08 §2.7, §2.2)
    const stale = await cache.snapshot({ userId: admin.userId, sessionId: admin.sessionId, jti: adminJti });
    const stepUp = await t.stepUp(admin, 'kiosk.manage');
    const idem = randomUUID();
    const body = { name: 'Планшет у кассы', warehouseId };
    const first = await enroll(t, admin, body, { idem, stepUp });
    expect(first.status, JSON.stringify(first.body)).toBe(201);
    const tabletId = String(first.body.tablet.id);
    const before = await tabletRow(t, tabletId);

    // этот процесс: access администратора уже в denylist — 401 раньше хранилища идемпотентности
    const local = await enroll(t, admin, body, { idem, stepUp });
    expect(local.status).toBe(401);
    expect(local.body.code).toBe('SESSION_REVOKED');

    const original = cache.snapshot.bind(cache);
    const spy = vi
      .spyOn(cache, 'snapshot')
      .mockImplementation((q) => (q.jti === adminJti ? Promise.resolve(stale) : original(q)));
    try {
      const replay = await enroll(t, admin, body, { idem, stepUp });
      expect(replay.status, JSON.stringify(replay.body)).toBe(201);
      expect(replay.headers['idempotent-replayed']).toBe('true');
      expect(replay.body.tablet.id).toBe(tabletId);
      expect(replay.body.sid).toBe(first.body.sid);
      expect(replay.body.accessToken).not.toBe(first.body.accessToken);
      expect(replay.body.refreshToken).not.toBe(first.body.refreshToken);
      expect(replay.body.exitCode).toMatch(/^\d{8}$/);

      // новый код действует, прежний — нет (хэш заменён); второго планшета нет
      const after = await tabletRow(t, tabletId);
      expect(after.exit_code_hash).not.toBe(before.exit_code_hash);
      const hasher = t.app.get(ExitCodeHasher, { strict: false });
      expect((await hasher.verify(String(replay.body.exitCode), tabletId, after.exit_code_hash, 1)).ok).toBe(true);
      if (replay.body.exitCode !== first.body.exitCode) {
        expect((await hasher.verify(String(first.body.exitCode), tabletId, after.exit_code_hash, 1)).ok).toBe(false);
      }
      expect(await t.q(`SELECT id FROM store_tablets WHERE enrolled_by_user_id = $1`, [admin.userId])).toHaveLength(1);

      // сессия ротирована «вбок»: прежний refresh — вытеснен, прежний access — в denylist
      const s = (await sessionsOf(t, before.user_id))[0];
      expect(s.superseded_refresh_hash?.equals(sha256(String(first.body.refreshToken)))).toBe(true);
      expect(s.grace_used_at).not.toBeNull();
      expect(await denied(t, String(claimsOf(String(first.body.accessToken)).jti))).toBe(true);

      // второй повтор — отказ: планшет подключают заново
      const second = await enroll(t, admin, body, { idem, stepUp });
      expect(second.status).toBe(422);
      expect(second.body).toMatchObject({ code: 'IDEMPOTENCY_KEY_REUSED', reason: 'replay_used' });
      expect(second.body.accessToken).toBeUndefined();
      // тот же ключ с другим телом — 422 по отпечатку
      const other = await enroll(t, admin, { ...body, name: 'Другой планшет' }, { idem, stepUp });
      expect(other.status).toBe(422);
      expect(other.body.code).toBe('IDEMPOTENCY_KEY_REUSED');
    } finally {
      spy.mockRestore();
    }

    // в хранилище по-прежнему только идентификаторы
    const keys = await t.q<{ body: string }>(
      `SELECT response_body::text AS body FROM idempotency_keys WHERE key = $1`,
      [idem],
    );
    expect(keys).toHaveLength(1);
    expect(keys[0].body).not.toContain('eyJ');
    const tab = { token: String(first.body.accessToken), deviceKey: admin.deviceKey };
    expect((await call(t, 'get', '/me', tab)).status).toBe(401); // прежний access планшета — в denylist
  });

  it('T-KIOSK-001 replay after the tablet session was used → 422 replay_used, код не меняется', async () => {
    const admin = await t.actor({ role: 'admin' });
    const cache = t.app.get(AuthStateCache, { strict: false });
    const adminJti = String(claimsOf(admin.token).jti);
    const stale = await cache.snapshot({ userId: admin.userId, sessionId: admin.sessionId, jti: adminJti });
    const stepUp = await t.stepUp(admin, 'kiosk.manage');
    const idem = randomUUID();
    const body = { name: 'Планшет у склада', warehouseId };
    const first = await enroll(t, admin, body, { idem, stepUp });
    expect(first.status).toBe(201);
    const tabletId = String(first.body.tablet.id);
    await t.q(`UPDATE sessions SET last_used_at = now() WHERE id = $1`, [first.body.sid]);
    const hashBefore = (await tabletRow(t, tabletId)).exit_code_hash;
    const original = cache.snapshot.bind(cache);
    const spy = vi
      .spyOn(cache, 'snapshot')
      .mockImplementation((q) => (q.jti === adminJti ? Promise.resolve(stale) : original(q)));
    try {
      const replay = await enroll(t, admin, body, { idem, stepUp });
      expect(replay.status).toBe(422);
      expect(replay.body).toMatchObject({ code: 'IDEMPOTENCY_KEY_REUSED', reason: 'replay_used' });
    } finally {
      spy.mockRestore();
    }
    expect((await tabletRow(t, tabletId)).exit_code_hash).toBe(hashBefore);
  });

  it('T-KIOSK-006 one session, kiosk terms: 180 дн / 7 дн простоя, одна сессия; staff и customer — прежние сроки', async () => {
    const admin = await t.actor({ role: 'admin' });
    const r = await enroll(t, admin, { name: 'Планшет сроков', warehouseId });
    expect(r.status).toBe(201);
    const st = await tabletRow(t, String(r.body.tablet.id));
    const [s] = await sessionsOf(t, st.user_id);
    expect(s.expires_at.getTime() - s.issued_at.getTime()).toBeGreaterThan(180 * DAY - 5_000);
    expect(s.expires_at.getTime() - s.issued_at.getTime()).toBeLessThan(180 * DAY + 5_000);
    expect(s.idle_expires_at.getTime() - s.issued_at.getTime()).toBeGreaterThan(7 * DAY - 5_000);
    expect(s.idle_expires_at.getTime() - s.issued_at.getTime()).toBeLessThan(7 * DAY + 5_000);

    // политика: kiosk 180 / 7 / 1; staff и customer — 7 дн / 24 ч / 3 и 30 / 14 дн / 5 (паритет)
    const p = t.app.get(AuthPolicyService, { strict: false }).base().session;
    expect(p).toMatchObject({ refreshTtlKioskDays: 180, idleKioskDays: 7, maxSessionsKiosk: 1 });
    const now = new Date('2026-11-04T09:00:00Z');
    const span = (k: 'staff' | 'customer' | 'kiosk') => {
      const x = sessionTerms(k, p, now);
      return [x.expiresAt.getTime() - now.getTime(), x.idleExpiresAt.getTime() - now.getTime()];
    };
    expect(span('staff')).toEqual([7 * DAY, 24 * 3600_000]);
    expect(span('customer')).toEqual([30 * DAY, 14 * DAY]);
    expect(span('kiosk')).toEqual([180 * DAY, 7 * DAY]);
    expect([maxSessions('staff', p), maxSessions('customer', p), maxSessions('kiosk', p)]).toEqual([3, 5, 1]);
    expect(() => sessionTerms('integration' as never, p, now)).toThrow();
    // простой не выходит за абсолютный срок
    const late = new Date(s.expires_at.getTime() - DAY);
    expect(nextIdleExpiry({ expiresAt: s.expires_at } as never, 'kiosk', p, late).getTime()).toBe(
      s.expires_at.getTime(),
    );

    // refresh планшета: простой продлевается на 7 дн, абсолютный срок не меняется
    const refreshed = await call(t, 'post', '/auth/refresh', undefined, {
      body: { refreshToken: r.body.refreshToken },
      headers: { 'X-Device-Id': admin.deviceKey },
    });
    expect(refreshed.status, JSON.stringify(refreshed.body)).toBe(200);
    const [s2] = await sessionsOf(t, st.user_id);
    expect(s2.expires_at.getTime()).toBe(s.expires_at.getTime());
    expect(s2.idle_expires_at.getTime() - Date.now()).toBeGreaterThan(7 * DAY - 60_000);
    expect(claimsOf(String(refreshed.body.accessToken))).toMatchObject({ kind: 'kiosk', amr: ['pin'] });

    // одна сессия: новая на том же устройстве вытесняет прежнюю (logout), на другом — по лимиту (session_limit)
    const issuer = t.app.get(SessionIssuer, { strict: false });
    const user = await new UsersRepository(t.db).findById(st.user_id);
    if (!user) throw new Error('нет пользователя планшета');
    const devices = new DevicesRepository(t.db);
    const same = await devices.findByKey(st.user_id, admin.deviceKey);
    if (!same) throw new Error('нет устройства планшета');
    await t.db.transaction((tx) =>
      issuer.createKioskSession({ user, roles: ['kiosk'], device: same, ip: null, userAgent: null }, tx),
    );
    const otherDevice = await devices.upsert({ userId: st.user_id, deviceKey: randomUUID(), platform: 'android' });
    await t.db.transaction((tx) =>
      issuer.createKioskSession({ user, roles: ['kiosk'], device: otherDevice, ip: null, userAgent: null }, tx),
    );
    const all = await sessionsOf(t, st.user_id);
    expect(all.map((x) => x.revoke_reason)).toEqual(['logout', 'session_limit', null]);
    expect(all.filter((x) => x.revoked_at === null)).toHaveLength(1);
    // createKioskSession — только для kind=kiosk
    const staff = await new UsersRepository(t.db).findById(admin.userId);
    if (!staff) throw new Error('нет администратора');
    await expect(
      t.db.transaction((tx) =>
        issuer.createKioskSession({ user: staff, roles: ['admin'], device: same, ip: null, userAgent: null }, tx),
      ),
    ).rejects.toThrow('kind=kiosk');
  });

  it('T-KIOSK-002 step-up, admin only, owner list 200 revoke 403', async () => {
    const admin = await t.actor({ role: 'admin' });
    const body = { name: 'Планшет у окна', warehouseId };

    // без step-up и со step-up другой операции → 403 STEP_UP_REQUIRED; ключ не захвачен, планшета нет
    const idem = randomUUID();
    const noStep = await enroll(t, admin, body, { idem, stepUp: false });
    expect(noStep.status).toBe(403);
    expect(noStep.body).toMatchObject({
      code: 'STEP_UP_REQUIRED',
      stepUp: { operation: 'kiosk.manage', allowedMethods: ['pin', 'otp'] },
    });
    const wrongScope = await enroll(t, admin, body, { idem, stepUp: await t.stepUp(admin, 'users.manage') });
    expect(wrongScope.status).toBe(403);
    expect(wrongScope.body.code).toBe('STEP_UP_REQUIRED');
    expect(await t.q(`SELECT 1 FROM idempotency_keys WHERE key = $1`, [idem])).toHaveLength(0);
    expect(await t.q(`SELECT 1 FROM store_tablets WHERE enrolled_by_user_id = $1`, [admin.userId])).toHaveLength(0);

    // Idempotency-Key обязателен; формат — UUID v4
    const stepUp = await t.stepUp(admin, 'kiosk.manage');
    const noKey = await call(t, 'post', '/admin/store-tablets', admin, { body, stepUp });
    expect(noKey.status).toBe(400);
    expect(noKey.body.errors).toEqual([expect.objectContaining({ rule: 'idempotency_key_required' })]);
    const badKey = await enroll(t, admin, body, { idem: 'not-a-uuid', stepUp });
    expect(badKey.status).toBe(400);
    expect(badKey.body.errors).toEqual([expect.objectContaining({ rule: 'idempotency_key_format' })]);

    // тело: лишние поля, имя, склад
    const rules = async (b: unknown) => {
      const x = await enroll(t, admin, b, { stepUp });
      expect(x.status, JSON.stringify(x.body)).toBe(400);
      return (x.body.errors as { field: string; rule: string }[]).map((e) => `${e.field}:${e.rule}`).sort();
    };
    expect(await rules({ ...body, role: 'cashier', phone: freshPhone() })).toEqual([
      'phone:forbidden_field',
      'role:forbidden_field',
    ]);
    expect(await rules({ name: 'А', warehouseId })).toEqual(['name:length']);
    expect(await rules({ name: 'x'.repeat(151), warehouseId })).toEqual(['name:length']);
    expect(await rules({ name: 'Планшет', warehouseId: 'склад' })).toEqual(['warehouseId:uuid']);
    expect(await rules({})).toEqual(['name:type', 'warehouseId:uuid']);
    expect(await rules([])).toEqual(['body:type']);

    // склад не существует или неактивен → 404; ключ освобождён, сессия администратора не тронута
    const key404 = randomUUID();
    const missing = await enroll(t, admin, { ...body, warehouseId: randomUUID() }, { idem: key404, stepUp });
    expect(missing.status).toBe(404);
    expect(missing.body.code).toBe('NOT_FOUND');
    const closed = await t.q<{ id: string }>(
      `INSERT INTO warehouses (synced_at, source_hash, name, is_active, sort_order)
       VALUES (now(), 'kiosk-test', 'Закрытый склад стенда', false, 98) RETURNING id`,
    );
    const inactive = await enroll(t, admin, { ...body, warehouseId: closed[0].id }, { stepUp });
    expect(inactive.status).toBe(404);
    expect(await t.q(`SELECT 1 FROM idempotency_keys WHERE key = $1`, [key404])).toHaveLength(0);
    expect((await call(t, 'get', '/admin/store-tablets', admin)).status).toBe(200);

    // прочие роли: подключение — 403 FORBIDDEN (RBAC до step-up); owner читает список
    for (const role of ['owner', 'seller', 'cashier', 'senior_seller', 'customer'] as const) {
      const a = await t.actor({ role });
      const x = await enroll(t, a, body, { stepUp: false });
      expect(x.status, role).toBe(403);
      expect(x.body.code, role).toBe('FORBIDDEN');
      const list = await call(t, 'get', '/admin/store-tablets', a);
      expect(list.status, role).toBe(role === 'owner' ? 200 : 403);
    }

    // admin подключает; owner видит планшет, но изменить и отключить не может
    const ok = await enroll(t, admin, body, { stepUp });
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    const id = String(ok.body.tablet.id);
    const list = await call(t, 'get', '/admin/store-tablets', owner);
    expect(list.status).toBe(200);
    expect((list.body.items as { id: string }[]).map((x) => x.id)).toContain(id);
    const ownerRevoke = await call(t, 'post', `/admin/store-tablets/${id}/revoke`, owner, { body: {} });
    expect(ownerRevoke.status).toBe(403);
    expect(ownerRevoke.body.code).toBe('FORBIDDEN');
    const ownerPatch = await call(t, 'patch', `/admin/store-tablets/${id}`, owner, { body: { name: 'Чужое имя' } });
    expect(ownerPatch.status).toBe(403);
    expect((await tabletRow(t, id)).status).toBe('active');

    // отключение — тоже step-up kiosk.manage
    const admin2 = await t.actor({ role: 'admin' });
    const noStepRevoke = await call(t, 'post', `/admin/store-tablets/${id}/revoke`, admin2, { body: {} });
    expect(noStepRevoke.status).toBe(403);
    expect(noStepRevoke.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: 'kiosk.manage' } });

    // токен планшета: /admin/store-tablets* вне закрытого списка
    const tab = { token: String(ok.body.accessToken), deviceKey: admin.deviceKey };
    const self = await call(t, 'get', '/admin/store-tablets', tab);
    expect(self.status).toBe(403);
    expect(self.body).toMatchObject({ code: 'FORBIDDEN', reason: 'kiosk_closed_list' });
  });

  it('T-KIOSK-066 kiosk.revoked, kiosk.updated (before/after, no PII)', async () => {
    const enroller = await t.actor({ role: 'admin' });
    const r = await enroll(t, enroller, { name: 'Планшет у входа', warehouseId });
    expect(r.status).toBe(201);
    const id = String(r.body.tablet.id);
    const st = await tabletRow(t, id);
    const tab = { token: String(r.body.accessToken), deviceKey: enroller.deviceKey };
    const admin = await t.actor({ role: 'admin' });

    // PATCH без step-up: имя, затем склад; тот же состав — без аудита
    const p1 = await call(t, 'patch', `/admin/store-tablets/${id}`, admin, { body: { name: 'Планшет у кассы' } });
    expect(p1.status, JSON.stringify(p1.body)).toBe(200);
    expect(Object.keys(p1.body).sort()).toEqual(TABLET_KEYS);
    expect(p1.body).toMatchObject({ id, name: 'Планшет у кассы', warehouseId, status: 'active' });
    const same = await call(t, 'patch', `/admin/store-tablets/${id}`, admin, {
      body: { name: 'Планшет у кассы', warehouseId },
    });
    expect(same.status).toBe(200);
    const p2 = await call(t, 'patch', `/admin/store-tablets/${id}`, admin, { body: { warehouseId: warehouse2 } });
    expect(p2.status).toBe(200);
    expect(p2.body.warehouseId).toBe(warehouse2);
    expect(
      await t.q(`SELECT full_name, home_warehouse_id FROM user_profiles WHERE user_id = $1`, [st.user_id]),
    ).toEqual([{ full_name: 'Планшет у кассы', home_warehouse_id: warehouse2 }]);
    const updated = await t.auditRows('kiosk.updated', id);
    expect(updated.map((a) => [a.actor_user_id, a.step_up_method, a.after])).toEqual([
      [admin.userId, null, { name: 'Планшет у кассы' }],
      [admin.userId, null, { warehouseId: warehouse2 }],
    ]);
    const before = await t.q<{ before: unknown }>(
      `SELECT before FROM audit_logs WHERE action = 'kiosk.updated' AND entity_id = $1 ORDER BY chain_seq`,
      [id],
    );
    expect(before.map((b) => b.before)).toEqual([{ name: 'Планшет у входа' }, { warehouseId }]);
    // новый склад действует сразу: GET /me планшета
    expect((await call(t, 'get', '/me', tab)).body.tablet).toEqual({
      id,
      name: 'Планшет у кассы',
      warehouseId: warehouse2,
    });
    const back = await call(t, 'patch', `/admin/store-tablets/${id}`, admin, { body: { warehouseId } });
    expect(back.status).toBe(200);

    // ошибки PATCH: пустое тело, лишнее поле, неизвестный планшет и склад, не UUID
    const patchRule = async (b: unknown) => {
      const x = await call(t, 'patch', `/admin/store-tablets/${id}`, admin, { body: b });
      expect(x.status, JSON.stringify(x.body)).toBe(400);
      return (x.body.errors as { field: string; rule: string }[]).map((e) => `${e.field}:${e.rule}`);
    };
    expect(await patchRule({})).toEqual(['body:min_properties']);
    expect(await patchRule({ name: 'Планшет', status: 'revoked' })).toEqual(['status:forbidden_field']);
    expect(await patchRule({ name: ' ' })).toEqual(['name:length']);
    const unknownWh = await call(t, 'patch', `/admin/store-tablets/${id}`, admin, {
      body: { warehouseId: randomUUID() },
    });
    expect(unknownWh.status).toBe(404);
    expect(
      (await call(t, 'patch', `/admin/store-tablets/${randomUUID()}`, admin, { body: { name: 'Нет' } })).status,
    ).toBe(404);
    expect((await call(t, 'patch', `/admin/store-tablets/nope`, admin, { body: { name: 'Нет' } })).status).toBe(400);

    // действующий код планшета (код к заявке на номер покупателя) — для проверки погашения при отключении
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

    // отключение: step-up, причина — только в аудит
    const stepUp = await t.stepUp(admin, 'kiosk.manage');
    const badReason = await call(t, 'post', `/admin/store-tablets/${id}/revoke`, admin, {
      body: { reason: 'x'.repeat(201) },
      stepUp,
    });
    expect(badReason.status).toBe(400);
    expect(badReason.body.errors).toEqual([expect.objectContaining({ field: 'reason', rule: 'max_length' })]);
    const extra = await call(t, 'post', `/admin/store-tablets/${id}/revoke`, admin, {
      body: { reason: null, status: 'active' },
      stepUp,
    });
    expect(extra.status).toBe(400);
    const rv = await call(t, 'post', `/admin/store-tablets/${id}/revoke`, admin, {
      body: { reason: 'Планшет на обновление' },
      stepUp,
    });
    expect(rv.status, JSON.stringify(rv.body)).toBe(200);
    expect(Object.keys(rv.body).sort()).toEqual(TABLET_KEYS);
    expect(rv.body).toMatchObject({ id, status: 'revoked', expiresAt: null });
    expect(rv.body.revokedAt).not.toBeNull();
    const row = await tabletRow(t, id);
    expect(row).toMatchObject({ status: 'revoked', revoked_by_user_id: admin.userId, revoke_reason: 'kiosk.revoked' });
    expect((await sessionsOf(t, st.user_id)).map((s) => s.revoke_reason)).toEqual(['kiosk_revoked']);
    expect(
      await t.q(`SELECT status::text AS status FROM otp_challenges WHERE id = $1`, [otp.body.challengeId]),
    ).toEqual([{ status: 'superseded' }]);
    const revoked = await t.auditRows('kiosk.revoked', id);
    expect(revoked).toEqual([
      {
        action: 'kiosk.revoked',
        result: 'ok',
        actor_user_id: admin.userId,
        step_up_method: 'pin',
        entity_id: id,
        after: { status: 'revoked', revokedSessions: 1, gashedKioskCodes: 1 },
      },
    ]);
    const full = await t.q<{ before: unknown; reason: string | null }>(
      `SELECT before, reason FROM audit_logs WHERE action = 'kiosk.revoked' AND entity_id = $1`,
      [id],
    );
    expect(full).toEqual([{ before: { status: 'active' }, reason: 'Планшет на обновление' }]);
    noPii(await t.q(`SELECT before, after, reason FROM audit_logs WHERE entity_id = $1`, [id]));
    noPii(rv.body);

    // следующий запрос планшета — 401 (KIOSK_REVOKED — с WP-S2B; до него SESSION_REVOKED)
    const next = await call(t, 'get', '/cart', tab);
    expect(next.status).toBe(401);
    expect(['SESSION_REVOKED', 'KIOSK_REVOKED']).toContain(next.body.code);

    // повтор — 200 с текущим состоянием, без повторного аудита; изменение отключённого планшета работает
    const again = await call(t, 'post', `/admin/store-tablets/${id}/revoke`, admin, { stepUp });
    expect(again.status).toBe(200);
    expect(again.body).toMatchObject({ id, status: 'revoked', revokedAt: rv.body.revokedAt });
    expect(await t.auditRows('kiosk.revoked', id)).toHaveLength(1);
    const renamed = await call(t, 'patch', `/admin/store-tablets/${id}`, admin, {
      body: { name: 'Планшет на складе' },
    });
    expect(renamed.status).toBe(200);
    expect(renamed.body).toMatchObject({ status: 'revoked', name: 'Планшет на складе' });
    expect((await call(t, 'post', `/admin/store-tablets/${randomUUID()}/revoke`, admin, { stepUp })).status).toBe(404);
  });

  it('T-KIOSK-068 / T-KIOSK-050 GET /admin/store-tablets: lockTaskEnabled NULL после подключения, затем X-Kiosk-Lock и X-App-Version', async () => {
    const admin = await t.actor({ role: 'admin' });
    const r = await enroll(t, admin, { name: 'Планшет у витрины', warehouseId });
    expect(r.status).toBe(201);
    const id = String(r.body.tablet.id);
    const tab = { token: String(r.body.accessToken), deviceKey: admin.deviceKey };
    const viewer = await t.actor({ role: 'admin' });
    const find = async (q = '') => {
      const l = await call(t, 'get', `/admin/store-tablets${q}`, viewer);
      expect(l.status, JSON.stringify(l.body)).toBe(200);
      expect(Object.keys(l.body)).toEqual(['items']);
      return (l.body.items as Record<string, unknown>[]).find((x) => x.id === id);
    };
    const enrolled = await find();
    expect(enrolled).toMatchObject({ lockTaskEnabled: null, lastSeenAt: null, appVersion: null, status: 'active' });
    expect(Object.keys(enrolled ?? {}).sort()).toEqual(TABLET_KEYS);

    // опрос GET /settings/public планшета с закреплением и версией приложения → отметка связи
    const ping = await call(t, 'get', '/settings/public', tab, {
      headers: { 'X-Kiosk-Lock': 'on', 'X-App-Version': '1.4.2+87', 'X-Platform': 'android' },
    });
    expect(ping.status).toBe(200);
    const seen = await find();
    expect(seen).toMatchObject({ lockTaskEnabled: true, appVersion: '1.4.2+87' });
    expect(seen?.lastSeenAt).not.toBeNull();
    noPii(seen);

    // фильтр status; неизвестное значение и параметр → 400
    expect(await find('?status=active')).toBeDefined();
    expect(await find('?status=revoked')).toBeUndefined();
    expect((await call(t, 'get', '/admin/store-tablets?status=lost', viewer)).status).toBe(400);
    expect((await call(t, 'get', '/admin/store-tablets?limit=5', viewer)).status).toBe(400);
  });
});

// ------------------------------------------------------------------------------------------------- KIOSK_MODE=false

describe('kiosk: /admin/store-tablets при KIOSK_MODE=false — путь отката (P-002 §23, ADR-115 п. 28)', () => {
  const t = new KioskTestApp();

  beforeAll(async () => {
    await t.startKiosk({ kioskMode: false });
  });

  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-033 flag off: enroll 403 KIOSK_DISABLED, list 200, revoke 200', async () => {
    const admin = await t.actor({ role: 'admin' });
    const warehouseId = await t.defaultWarehouseId();
    const body = { name: 'Планшет у входа', warehouseId };

    // подключение: 403 KIOSK_DISABLED до step-up и до захвата ключа; ничего не создано
    const idem = randomUUID();
    const off = await call(t, 'post', '/admin/store-tablets', admin, { body, idem });
    expect(off.status).toBe(403);
    expect(off.body.code).toBe('KIOSK_DISABLED');
    const offStep = await call(t, 'post', '/admin/store-tablets', admin, {
      body,
      idem,
      stepUp: await t.stepUp(admin, 'kiosk.manage'),
    });
    expect(offStep.status).toBe(403);
    expect(offStep.body.code).toBe('KIOSK_DISABLED');
    expect(await t.q(`SELECT 1 FROM idempotency_keys WHERE key = $1`, [idem])).toHaveLength(0);
    expect(await t.q(`SELECT 1 FROM store_tablets WHERE enrolled_by_user_id = $1`, [admin.userId])).toHaveLength(0);
    expect(await t.q(`SELECT revoked_at FROM sessions WHERE id = $1`, [admin.sessionId])).toEqual([
      { revoked_at: null },
    ]);
    // прочие роли — по-прежнему RBAC
    const owner = await t.actor({ role: 'owner' });
    expect((await call(t, 'post', '/admin/store-tablets', owner, { body, idem: randomUUID() })).body.code).toBe(
      'FORBIDDEN',
    );

    // планшеты, подключённые до выключения флага: список (по имени), изменение и отключение работают
    const tab = await t.tablet({ name: 'Планшет у кассы', warehouseId });
    const first = await t.tablet({ name: 'Аптечный угол', warehouseId });
    const list = await call(t, 'get', '/admin/store-tablets', owner);
    expect(list.status).toBe(200);
    expect(list.body.items).toEqual([
      expect.objectContaining({ id: first.tabletId, name: 'Аптечный угол', status: 'active' }),
      expect.objectContaining({ id: tab.tabletId, name: 'Планшет у кассы', status: 'active' }),
    ]);
    const patched = await call(t, 'patch', `/admin/store-tablets/${tab.tabletId}`, admin, {
      body: { name: 'Планшет 2' },
    });
    expect(patched.status, JSON.stringify(patched.body)).toBe(200);
    expect(patched.body.name).toBe('Планшет 2');
    const rv = await call(t, 'post', `/admin/store-tablets/${tab.tabletId}/revoke`, admin, {
      body: { reason: 'Режим планшета выключен' },
      stepUp: await t.stepUp(admin, 'kiosk.manage'),
    });
    expect(rv.status, JSON.stringify(rv.body)).toBe(200);
    expect(rv.body.status).toBe('revoked');
    expect(await t.q(`SELECT revoke_reason FROM sessions WHERE user_id = $1`, [tab.userId])).toEqual([
      { revoke_reason: 'kiosk_revoked' },
    ]);
    expect(await t.auditRows('kiosk.revoked', tab.tabletId)).toHaveLength(1);
  });
});
