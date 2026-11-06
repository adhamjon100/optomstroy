import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CartModule } from '../../src/cart/cart.module.js';
import { ExitCodeHasher } from '../../src/common/crypto/exit-code-hasher.service.js';
import { parseSecretRing } from '../../src/common/crypto/secret-ring.js';
import { ProblemException } from '../../src/common/problem-details/problem.exception.js';
import { KIOSK_ACCESS_GUARD } from '../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import {
  KIOSK_EXIT_LOCK_MS,
  KIOSK_EXIT_MAX_ATTEMPTS,
  parseKioskExitBody,
} from '../../src/kiosk/lifecycle/kiosk-exit.service.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import { PublicSettingsModule } from '../../src/settings/public-settings.module.js';
import { testSecret } from '../foundation/support/keys.js';
import type { PosActor } from '../support/pos-fixture.js';
import { KioskTestApp } from './support/kiosk-fixture.js';

/**
 * Аварийный выход планшета магазина со связью — `POST /kiosk/exit {code}` (08 §4.25.5, §2.4, §2.9 RL-PIN; 09 §8.9
 * п. 4–5; 07 §5.65; 10 KIOSK-004; 11 SEC-139, SEC-140, SEC-047; ADR-115 п. 28) — **тестовые данные** стенда
 * `kiosk-fixture` (embedded PostgreSQL 17; планшет подключается через `POST /admin/store-tablets`, код — из ответа):
 * - T-KIOSK-004: верный код — `200 {}`, код погашен (`exit_code_used_at`), сессии → `kiosk_revoked`, строка →
 *   `revoked` (`kiosk.exit_code_used`, без администратора), повтор — `401 KIOSK_REVOKED`; уже использованный код —
 *   `422`; 1-я…4-я неверная — `422 KIOSK_EXIT_CODE_INVALID {attemptsLeft}`, 5-я — `423 KIOSK_EXIT_LOCKED
 *   {retryAfter}` на 15 мин (и с верным кодом), счётчик и пауза — в `store_tablets` (переживают рестарт); после паузы
 *   — новая серия; хэш — Argon2id с серверным pepper (другой pepper код не принимает), кода в открытом виде нет в БД,
 *   логах и аудите. Проверка на устройстве (без связи) — `pos-app/test/features/kiosk/emergency_exit_test.dart`.
 */
type Method = 'get' | 'post';

interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
  readonly headers: Record<string, string | string[] | undefined>;
}

type Subject = Pick<PosActor, 'token' | 'deviceKey'>;

interface Enrolled {
  readonly id: string;
  readonly userId: string;
  readonly tab: Subject;
  readonly exitCode: string;
}

async function call(
  t: KioskTestApp,
  method: Method,
  path: string,
  a?: Subject,
  o: { body?: unknown; stepUp?: string; idem?: string } = {},
): Promise<Res> {
  const r = t.req(method, path, a, { ...(o.stepUp ? { stepUp: o.stepUp } : {}), ...(o.idem ? { idem: o.idem } : {}) });
  const res = await (o.body !== undefined ? r.send(o.body as object) : r);
  return { status: res.status, body: (res.body ?? {}) as Res['body'], headers: res.headers };
}

/** Другой 8-значный код (не совпадает с выданным). */
function wrongCode(code: string): string {
  return code === '00000000' ? '11111111' : '00000000';
}

describe('kiosk: разбор тела POST /kiosk/exit (08 §4.25.5) — без БД', () => {
  const rules = (raw: unknown): string[] => {
    try {
      parseKioskExitBody(raw);
      return [];
    } catch (e) {
      expect(e).toBeInstanceOf(ProblemException);
      const p = e as ProblemException;
      expect(p.getStatus()).toBe(400);
      return (p.extensions.errors ?? []).map((x) => `${x.field}:${x.rule}`);
    }
  };

  it('T-KIOSK-004 body: ровно 8 цифр; иные поля и не объект — 400; значение кода в ошибку не копируется', () => {
    expect(parseKioskExitBody({ code: '01234567' })).toEqual({ code: '01234567' });
    expect(rules({ code: '1234567' })).toEqual(['code:exit_code_format']);
    expect(rules({ code: '123456789' })).toEqual(['code:exit_code_format']);
    expect(rules({ code: '1234567a' })).toEqual(['code:exit_code_format']);
    expect(rules({ code: 12345678 })).toEqual(['code:exit_code_format']);
    expect(rules({})).toEqual(['code:exit_code_format']);
    expect(rules({ code: '12345678', tabletId: 'x' })).toEqual(['tabletId:forbidden_field']);
    expect(rules(null)).toEqual(['body:type']);
    expect(rules(['12345678'])).toEqual(['body:type']);
    try {
      parseKioskExitBody({ code: '9876543x' });
    } catch (e) {
      expect(JSON.stringify((e as ProblemException).extensions)).not.toContain('9876543x');
    }
    expect([KIOSK_EXIT_MAX_ATTEMPTS, KIOSK_EXIT_LOCK_MS]).toEqual([5, 15 * 60_000]);
  });
});

describe('kiosk: POST /kiosk/exit — аварийный выход со связью (KIOSK_MODE=true)', () => {
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

  async function enroll(name: string): Promise<Enrolled> {
    const admin = await t.actor({ role: 'admin' });
    const r = await call(t, 'post', '/admin/store-tablets', admin, {
      body: { name, warehouseId },
      stepUp: await t.stepUp(admin, 'kiosk.manage'),
      idem: randomUUID(),
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const id = String(r.body.tablet.id);
    const rows = await t.q<{ user_id: string }>(`SELECT user_id FROM store_tablets WHERE id = $1`, [id]);
    return {
      id,
      userId: rows[0].user_id,
      tab: { token: String(r.body.accessToken), deviceKey: admin.deviceKey },
      exitCode: String(r.body.exitCode),
    };
  }

  async function row(id: string) {
    const r = await t.q<{
      status: string;
      exit_code_hash: string;
      exit_code_pepper_version: number;
      exit_code_used_at: Date | null;
      exit_failed_attempts: number;
      exit_locked_until: Date | null;
      revoked_at: Date | null;
      revoked_by_user_id: string | null;
      revoke_reason: string | null;
    }>(`SELECT * FROM store_tablets WHERE id = $1`, [id]);
    return r[0];
  }

  const exit = (tab: Subject, code: string) => call(t, 'post', '/kiosk/exit', tab, { body: { code } });

  it('T-KIOSK-004 online exit, one-time code: верный код — 200, сессии kiosk_revoked, строка revoked; повтор — 401 KIOSK_REVOKED', async () => {
    const e = await enroll('Планшет у входа');
    const logsBefore = t.logs.lines.length;
    const bad = await exit(e.tab, wrongCode(e.exitCode));
    expect([bad.status, bad.body.code, bad.body.attemptsLeft]).toEqual([422, 'KIOSK_EXIT_CODE_INVALID', 4]);
    expect(bad.body.detail).toBe('Неверный аварийный код. Осталось попыток: 4.');
    expect((await row(e.id)).exit_failed_attempts).toBe(1);
    const malformed = await exit(e.tab, '1234');
    expect(malformed.status).toBe(400);
    expect((await row(e.id)).exit_failed_attempts).toBe(1);

    const ok = await exit(e.tab, e.exitCode);
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(ok.body).toEqual({});
    expect(String(ok.headers['cache-control'])).toContain('no-store');
    const r = await row(e.id);
    expect(r).toMatchObject({
      status: 'revoked',
      exit_failed_attempts: 0,
      exit_locked_until: null,
      revoked_by_user_id: null,
      revoke_reason: 'kiosk.exit_code_used',
    });
    expect(r.exit_code_used_at).not.toBeNull();
    expect(r.revoked_at?.getTime()).toBe(r.exit_code_used_at?.getTime());
    expect(await t.q(`SELECT revoke_reason FROM sessions WHERE user_id = $1 ORDER BY issued_at`, [e.userId])).toEqual([
      { revoke_reason: 'kiosk_revoked' },
    ]);
    expect(await t.auditRows('kiosk.exit_code_used', e.id)).toHaveLength(1);

    // повтор после «потерянного» 200: сессия отозвана — 401 KIOSK_REVOKED, ключ идемпотентности не нужен
    const again = await exit(e.tab, e.exitCode);
    expect([again.status, again.body.code]).toEqual([401, 'KIOSK_REVOKED']);
    expect((await call(t, 'get', '/cart', e.tab)).body.code).toBe('KIOSK_REVOKED');

    // кода нет в журнале и в ответах
    const logs = t.logs.lines.slice(logsBefore).join('\n');
    expect(logs).toContain('kiosk.exit_code_used');
    expect(logs).toContain('kiosk.exit_code_invalid');
    expect(logs).not.toContain(e.exitCode);
    expect(logs).not.toContain(e.tab.token);
  });

  it('T-KIOSK-004 Idempotency-Key ignored: неверный и верный код с ключом — 422 и 200, в idempotency_keys ничего (11 SEC-140 п. 6)', async () => {
    const e = await enroll('Планшет с ключом идемпотентности');
    const withKey = (code: string) => call(t, 'post', '/kiosk/exit', e.tab, { body: { code }, idem: randomUUID() });
    const bad = await withKey(wrongCode(e.exitCode));
    expect([bad.status, bad.body.code, bad.body.attemptsLeft]).toEqual([422, 'KIOSK_EXIT_CODE_INVALID', 4]);
    const ok = await withKey(e.exitCode);
    expect([ok.status, ok.body]).toEqual([200, {}]);
    expect((await row(e.id)).status).toBe('revoked');
    // Заголовок снят guard-ом до IdempotencyInterceptor: ни ответа, ни request_hash (SHA-256 тела с кодом).
    expect(await t.q(`SELECT count(*)::int AS n FROM idempotency_keys WHERE route = 'POST /kiosk/exit'`)).toEqual([
      { n: 0 },
    ]);
    expect(await t.q(`SELECT count(*)::int AS n FROM idempotency_keys WHERE user_id = $1`, [e.userId])).toEqual([
      { n: 0 },
    ]);
  });

  it('T-KIOSK-004 used code → 422: код уже погашен, а сессия ещё принимается (окно кэша) — неверная попытка', async () => {
    const e = await enroll('Планшет у кассы');
    // состояние «код погашен, сессия жива» (другой процесс в окне кэша ≤ 60 с, 09 §8.9 п. 8 (2))
    await t.q(`UPDATE store_tablets SET exit_code_used_at = now() WHERE id = $1`, [e.id]);
    const used = await exit(e.tab, e.exitCode);
    expect([used.status, used.body.code, used.body.attemptsLeft]).toEqual([422, 'KIOSK_EXIT_CODE_INVALID', 4]);
    expect(await row(e.id)).toMatchObject({ status: 'active', exit_failed_attempts: 1 });
    expect(await t.auditRows('kiosk.exit_code_used', e.id)).toEqual([]);
  });

  it('T-KIOSK-004 5 failures lock: 1–4 → 422 attemptsLeft 4…1, 5-я → 423 на 15 мин (и верный код), счётчик в БД; после паузы — новая серия', async () => {
    const e = await enroll('Планшет у витрины');
    const wrong = wrongCode(e.exitCode);
    for (let i = 1; i <= 4; i++) {
      const r = await exit(e.tab, wrong);
      expect([r.status, r.body.code, r.body.attemptsLeft], `попытка ${i}`).toEqual([
        422,
        'KIOSK_EXIT_CODE_INVALID',
        5 - i,
      ]);
    }
    const t0 = Date.now();
    const fifth = await exit(e.tab, wrong);
    expect([fifth.status, fifth.body.code]).toEqual([423, 'KIOSK_EXIT_LOCKED']);
    expect(fifth.body.retryAfter).toBeGreaterThan(890);
    expect(fifth.body.retryAfter).toBeLessThanOrEqual(900);
    expect(fifth.headers['retry-after']).toBe(String(fifth.body.retryAfter));
    expect(fifth.body.attemptsLeft).toBeUndefined();
    // счётчик и пауза — в строке store_tablets (переживают рестарт, общие для реплик), не rate_limit_counters
    const locked = await row(e.id);
    expect(locked.exit_failed_attempts).toBe(5);
    expect(locked.exit_locked_until?.getTime()).toBeGreaterThan(t0 + 15 * 60_000 - 10_000);
    expect(locked.exit_locked_until?.getTime()).toBeLessThan(Date.now() + 15 * 60_000 + 1_000);
    // во время паузы — 423 и с верным кодом; счётчик не растёт, выход не выполняется
    const correct = await exit(e.tab, e.exitCode);
    expect([correct.status, correct.body.code]).toEqual([423, 'KIOSK_EXIT_LOCKED']);
    expect(await row(e.id)).toMatchObject({ status: 'active', exit_failed_attempts: 5, exit_code_used_at: null });

    // пауза прошла (часы сдвинуты): новая серия из 5 попыток, затем верный код — выход
    await t.q(`UPDATE store_tablets SET exit_locked_until = now() - interval '1 second' WHERE id = $1`, [e.id]);
    const afterLock = await exit(e.tab, wrong);
    expect([afterLock.status, afterLock.body.attemptsLeft]).toEqual([422, 4]);
    expect(await row(e.id)).toMatchObject({ exit_failed_attempts: 1, exit_locked_until: null });
    const ok = await exit(e.tab, e.exitCode);
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(await row(e.id)).toMatchObject({ status: 'revoked', exit_failed_attempts: 0 });
  });

  it('T-KIOSK-004 pepper: хэш — Argon2id(pepper ∥ код ∥ tablet_id) с серверным pepper, кода в открытом виде нет в БД', async () => {
    const e = await enroll('Планшет pepper');
    const r = await row(e.id);
    expect(r.exit_code_hash).toMatch(/^\$argon2id\$v=19\$m=19456,t=2,p=1\$/);
    expect(r.exit_code_hash).not.toContain(e.exitCode);
    const hasher = t.app.get(ExitCodeHasher, { strict: false });
    expect((await hasher.verify(e.exitCode, e.id, r.exit_code_hash, r.exit_code_pepper_version)).ok).toBe(true);
    // тот же код с другим pepper или другим tablet_id не проходит — копии хэша без pepper мало для перебора
    const other = new ExitCodeHasher(
      parseSecretRing('PIN_PEPPER', testSecret(), r.exit_code_pepper_version, 'staging'),
    );
    expect((await other.verify(e.exitCode, e.id, r.exit_code_hash, r.exit_code_pepper_version)).ok).toBe(false);
    expect((await hasher.verify(e.exitCode, randomUUID(), r.exit_code_hash, r.exit_code_pepper_version)).ok).toBe(
      false,
    );
    // неизвестная версия pepper — неверная попытка, не 500
    await t.q(`UPDATE store_tablets SET exit_code_pepper_version = 9 WHERE id = $1`, [e.id]);
    const unknown = await exit(e.tab, e.exitCode);
    expect([unknown.status, unknown.body.code]).toEqual([422, 'KIOSK_EXIT_CODE_INVALID']);
    await t.q(`UPDATE store_tablets SET exit_code_pepper_version = $2 WHERE id = $1`, [
      e.id,
      r.exit_code_pepper_version,
    ]);
    const ok = await exit(e.tab, e.exitCode);
    expect(ok.status).toBe(200);
    // код не найден ни в одной текстовой колонке таблиц планшета, аудита и идемпотентности
    for (const table of ['store_tablets', 'audit_logs', 'idempotency_keys', 'otp_challenges']) {
      const hits = await t.q(`SELECT 1 FROM ${table} x WHERE x::text LIKE $1`, [`%${e.exitCode}%`]);
      expect(hits, table).toEqual([]);
    }
  });

  it('T-KIOSK-004 только планшет: сотрудник и покупатель — 403 FORBIDDEN (право kiosk.self.exit — только kind=kiosk)', async () => {
    for (const role of ['admin', 'seller', 'customer'] as const) {
      const a = await t.actor({ role });
      const r = await exit(a, '12345678');
      expect([r.status, r.body.code], role).toEqual([403, 'FORBIDDEN']);
    }
  });
});
