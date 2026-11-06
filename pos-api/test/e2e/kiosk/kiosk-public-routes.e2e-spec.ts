import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';
import { KIOSK_CLOSED_LIST } from '../../../src/kiosk/common/kiosk-routes.js';
import { buyerPhone, type Method, type Res, type Subject, type Tablet, KioskE2eApp } from './support/kiosk-e2e.js';

/**
 * T-KIOSK-005 (3) — публичные маршруты SEC-013 с токеном планшета магазина и без него (12 §3.23; 11 SEC-013,
 * SEC-137 (3); 08 §4.25 «Закрытый список»; P-002 §8.3; ADR-115) на **всём приложении** AppModule (`createApp`,
 * глобальные guard-ы ReadOnly → Auth → SessionActivity → KioskAccess → RBAC): закрытый список планшета их не
 * проверяет (`@Public()` guard пропускает), поэтому ответ с Bearer планшета тот же, что без него (статус, код ошибки,
 * причина, набор полей). Защита публичных маршрутов от планшета — закрепление устройства (P-002 §13) и правило G-15
 * приложения, не сервер. Перечень публичных операций — из контракта `contracts/openapi/pos-api.v1.yaml`
 * (`security: []`); сверка «публичные ∩ закрытый список = ∅».
 * **Тестовые данные**: embedded PostgreSQL 17, синтетический каталог, фейк 1С; номера — вымышленные `+996 555 05x xxx`.
 */
interface ContractOp {
  readonly method: Method;
  readonly path: string;
  readonly operationId: string;
  readonly isPublic: boolean;
}

function contractOps(): ContractOp[] {
  const file = fileURLToPath(new URL('../../../../contracts/openapi/pos-api.v1.yaml', import.meta.url));
  const doc = parse(readFileSync(file, 'utf8')) as {
    security?: unknown[];
    paths: Record<string, Record<string, { operationId?: string; security?: unknown[] }>>;
  };
  const out: ContractOp[] = [];
  for (const [path, ops] of Object.entries(doc.paths)) {
    for (const [method, op] of Object.entries(ops)) {
      if (!op?.operationId) continue;
      const security = op.security ?? doc.security ?? [];
      out.push({ method: method as Method, path, operationId: op.operationId, isPublic: security.length === 0 });
    }
  }
  return out;
}

const key = (o: { method: string; path: string }) => `${o.method.toUpperCase()} ${o.path}`;

/** Сравнимая часть ответа: статус, код и причина Problem, набор полей верхнего уровня (значения — разные). */
function shape(r: Res): string {
  const b = r.body ?? {};
  return JSON.stringify({
    status: r.status,
    code: b.code ?? null,
    reason: b.reason ?? null,
    fields: Object.keys(b).sort(),
    errors: Array.isArray(b.errors)
      ? (b.errors as { field?: string; rule?: string }[]).map((e) => `${e.field}:${e.rule}`)
      : null,
  });
}

describe('kiosk e2e: публичные маршруты SEC-013 с токеном планшета и без него (T-KIOSK-005 (3))', () => {
  const t = new KioskE2eApp();
  let tablet: Tablet;
  let seller: Subject;
  const ops = contractOps();
  const publicOps = ops.filter((o) => o.isPublic);

  beforeAll(async () => {
    await t.start('kiosk_public_routes_e2e', { LOG_LEVEL: 'silent' }, 20);
    tablet = await t.enroll({ name: 'Планшет у входа' });
    seller = await t.subject('seller');
  });

  afterAll(async () => {
    await t.stop();
  });

  /** Один и тот же запрос: заголовки устройства планшета, с Bearer планшета или без него. */
  async function pair(method: Method, path: string, body?: () => unknown): Promise<{ withToken: Res; without: Res }> {
    const headers = { 'X-Device-Id': tablet.deviceKey };
    const idem = method === 'get' ? undefined : randomUUID();
    const without = await t.call(method, path, undefined, {
      headers,
      ...(body ? { body: body() } : method === 'get' ? {} : { body: {} }),
      ...(idem ? { idem } : {}),
    });
    const withToken = await t.call(method, path, undefined, {
      headers: { ...headers, Authorization: `Bearer ${tablet.token}` },
      ...(body ? { body: body() } : method === 'get' ? {} : { body: {} }),
      ...(idem ? { idem: randomUUID() } : {}),
    });
    return { withToken, without };
  }

  it('T-KIOSK-005 публичные операции контракта (security: []) не входят в закрытый список; их 10', () => {
    const closed = new Set<string>(KIOSK_CLOSED_LIST);
    expect(publicOps.map(key).sort()).toEqual(
      [
        'GET /auth/otp/challenges/{challengeId}',
        'GET /health',
        'GET /health/ready',
        'GET /images/{sha}/{size}',
        'POST /auth/otp/request',
        'POST /auth/otp/verify',
        'POST /auth/refresh',
        'POST /auth/unlock',
        'POST /integrations/smspro/dlr',
        'POST /registration/complete',
      ].sort(),
    );
    expect(publicOps.filter((o) => closed.has(key(o))).map(key)).toEqual([]);
  });

  it('T-KIOSK-005 public routes same with and without tablet token (3): пустые и неверные тела, случайные id', async () => {
    const problems: string[] = [];
    for (const op of publicOps) {
      const path = op.path
        .replace('{sha}', 'a'.repeat(64))
        .replace('{size}', 'thumb')
        .replace(/\{[A-Za-z]+\}/g, () => randomUUID());
      const { withToken, without } = await pair(op.method, path);
      if (withToken.status >= 500 || without.status >= 500)
        problems.push(`${key(op)}: 5xx ${shape(without)} / ${shape(withToken)}`);
      if (shape(withToken) !== shape(without))
        problems.push(`${key(op)}: без токена ${shape(without)} ≠ с токеном ${shape(withToken)}`);
      if (withToken.body?.reason === 'kiosk_closed_list')
        problems.push(`${key(op)}: закрытый список сработал на публичном маршруте`);
    }
    expect(problems).toEqual([]);
  });

  it('T-KIOSK-005 public routes same with and without tablet token (3): рабочие запросы входа, проверки кода и обновления', async () => {
    // Запрос кода входа — 202 в обоих случаях (тестовый режим 09 §5.8, разные номера: пауза повторной отправки).
    const otpBody = () => ({ phone: buyerPhone('05'), purpose: 'login_or_register', locale: 'ru' });
    const req = await pair('post', '/auth/otp/request', otpBody);
    expect([req.without.status, req.withToken.status]).toEqual([202, 202]);
    expect(shape(req.withToken)).toBe(shape(req.without));
    // Статус кода — 200 в обоих случаях.
    const ch = await pair('get', `/auth/otp/challenges/${String(req.without.body.challengeId)}`);
    expect([ch.without.status, ch.withToken.status]).toEqual([200, 200]);
    expect(shape(ch.withToken)).toBe(shape(ch.without));
    // Неверный код — 422 OTP_INVALID в обоих случаях (по своему коду каждого запроса).
    const bad = async (challengeId: string, withToken: boolean) =>
      t.call('post', '/auth/otp/verify', undefined, {
        headers: {
          'X-Device-Id': tablet.deviceKey,
          ...(withToken ? { Authorization: `Bearer ${tablet.token}` } : {}),
        },
        body: {
          challengeId,
          code: '000000',
          device: { name: 'Планшет e2e', platform: 'android', appVersion: '99.0.0' },
        },
      });
    const v1 = await bad(String(req.without.body.challengeId), false);
    const v2 = await bad(String(req.withToken.body.challengeId), true);
    expect([v1.status, v1.body.code]).toEqual([422, 'OTP_INVALID']);
    expect(shape(v2)).toBe(shape(v1));
    // Обновление по неизвестному refresh — 401 SESSION_REVOKED в обоих случаях; настоящий refresh планшета не тратится.
    const rf = await pair('post', '/auth/refresh', () => ({ refreshToken: `unknown-${randomUUID()}` })); // check-secrets: allow — имя поля из ответа API в прогоне, не секрет
    expect([rf.without.status, rf.without.body.code]).toEqual([401, 'SESSION_REVOKED']);
    expect(shape(rf.withToken)).toBe(shape(rf.without));
    // Здоровье — 200.
    for (const p of ['/health', '/health/ready']) {
      const r = await pair('get', p);
      expect([r.without.status, r.withToken.status], p).toEqual([200, 200]);
    }
    // Планшет после всего — в работе (публичные маршруты его сессию не трогали); сотрудник — как прежде.
    expect((await t.call('get', '/me', tablet)).status).toBe(200);
    expect((await t.call('get', '/me', seller)).status).toBe(200);
  });
});
