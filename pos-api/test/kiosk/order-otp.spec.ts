import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { OtpChallengesRepository } from '../../src/auth/otp/otp-challenges.repository.js';
import { OTP_PROVIDER, type OtpProvider } from '../../src/auth/otp/otp.provider.js';
import { type OtpCheck, OtpService } from '../../src/auth/otp/otp.service.js';
import { KIOSK_ORDER_SMS_TEMPLATE } from '../../src/auth/otp/sms-texts.js';
import { CartModule } from '../../src/cart/cart.module.js';
import { FixedClock } from '../../src/common/auth/clock.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { KIOSK_ACCESS_GUARD } from '../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import { PublicSettingsModule } from '../../src/settings/public-settings.module.js';
import type { PosActor, SaleableVariant } from '../support/pos-fixture.js';
import { type KioskTablet, KioskTestApp } from './support/kiosk-fixture.js';

/**
 * `POST /kiosk/order-otp` — код к заявке с планшета магазина (08 §4.25.1; 09 §5.3, §5.4, §6.7; 10 KIOSK-011,
 * KIOSK-012, KIOSK-022; 11 SEC-016, SEC-017, PRIV-032; ADR-115) — **тестовые данные** стенда `kiosk-fixture`
 * (embedded PostgreSQL 17, синтетический каталог; номера покупателей — вымышленные `+996 555 1xx xxx`, номера
 * сотрудников стенда — `+996 77x xxx xxx`; коды из SMS читаются из `dev_outbox` поддельного шлюза):
 * - T-KIOSK-011: пустая, чужая, несуществующая корзина → `422 CART_EMPTY`, SMS нет;
 * - T-KIOSK-012: номер с карточкой, без карточки и номер сотрудника → одинаковые статус, тело и время (T-SEC-006);
 * - T-KIOSK-017: лимиты номера (`429 OTP_RATE_LIMITED`) и планшета за час и за сутки (`429 KIOSK_RATE_LIMITED`,
 *   аудит `kiosk.limit_reached` без телефона, алерт `security.alert`); алерт по расписанию — WP-S5;
 * - T-KIOSK-018: три планшета за одним NAT, 25 кодов — лимиты IP и устройства не применяются;
 * - T-KIOSK-037: свой текст SMS, `sms_outbox.template_key = otp_kiosk_order`, в `dev_outbox` — `otp_login`;
 * - T-KIOSK-041: `notice_version` в строке кода и в аудите `auth.otp.sent`, неизвестная версия → 422 до SMS;
 * - T-KIOSK-052: «Изменить номер» вытесняет прежний код, один `sent` на планшет, тот же номер раньше 60 с → 429;
 *   одновременные запросы — без `23505` (блокировка «планшет → номер»); погашение кодов `gashKioskCodes`.
 * Время стенда — `FixedClock` с началом часа (окна лимитов — фиксированные, 07 §5.12), чтобы окна не менялись внутри
 * теста; `OTP_GLOBAL_PER_MIN` стенда поднят — все коды файла укладываются в одну минуту часов стенда.
 */
type Method = 'get' | 'post' | 'put' | 'patch' | 'delete';

interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
  readonly headers: Record<string, string>;
}

const NOTICE = '2026-11-04';
const DEV_OUTBOX_SQL = fileURLToPath(new URL('../../db/migrations-dev/0001_dev_outbox.sql', import.meta.url));
const HOUR_MS = 3_600_000;

let phoneSeq = 0;
/** Вымышленный мобильный номер КР `+996 555 1xx xxx` (тестовые данные). */
function freshPhone(): string {
  phoneSeq += 1;
  return `+996555${String(100_000 + phoneSeq)}`;
}

async function call(t: KioskTestApp, method: Method, path: string, a?: PosActor, body?: unknown): Promise<Res> {
  const r = t.req(method, path, a);
  const res = await (body !== undefined ? r.send(body as object) : r);
  return { status: res.status, body: (res.body ?? {}) as Res['body'], headers: res.headers };
}

function orderOtp(t: KioskTestApp, a: PosActor, body: unknown): Promise<Res> {
  return call(t, 'post', '/kiosk/order-otp', a, body);
}

/** Корзина планшета с одной строкой (как SCR-51 → SCR-52); возвращает `cartId`. */
async function fillCart(t: KioskTestApp, a: PosActor, v: SaleableVariant): Promise<string> {
  const c0 = await call(t, 'get', '/cart', a);
  expect(c0.status).toBe(200);
  const put = await call(t, 'put', `/cart/items/${v.variantId}`, a, {
    quantity: { value: '1', unitId: v.unitId, packagingId: null },
    rowVersion: c0.body.rowVersion as number,
  });
  expect(put.status, JSON.stringify(put.body)).toBe(200);
  return c0.body.id as string;
}

/**
 * `dev_outbox` (07 §5.63) — только в dev/test-схеме: как `test/e2e/auth/support/auth-e2e.ts`, dev-миграция применяется
 * к БД стенда в сеансе с `app.env=test` (файл миграции не меняется). Без неё FakeSmsGateway вернул бы CONFIG_ERROR.
 */
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

function provider(t: KioskTestApp): OtpProvider {
  return t.app.get<OtpProvider>(OTP_PROVIDER, { strict: false });
}

/** Код из SMS (`dev_outbox` поддельного шлюза) — после фоновой отправки. */
async function codeOf(t: KioskTestApp, challengeId: string): Promise<string> {
  await provider(t).drain();
  const r = await t.q<{ text: string }>(
    `SELECT d.text FROM dev_outbox d JOIN otp_challenges c ON c.sms_outbox_id = d.sms_outbox_id WHERE c.id = $1`,
    [challengeId],
  );
  const m = /(\d{6})/.exec(r[0]?.text ?? '');
  if (!m?.[1]) throw new Error(`код для ${challengeId} не найден в dev_outbox`);
  return m[1];
}

/** Проверка кода так, как её сделает `POST /kiosk/orders` (WP-S4C): назначение `kiosk_order`, устройство планшета. */
async function checkCode(t: KioskTestApp, tab: KioskTablet, challengeId: string, code: string): Promise<OtpCheck> {
  const otp = t.app.get(OtpService, { strict: false });
  return t.db.transaction((tx) =>
    otp.check(tx, { challengeId, code, deviceKey: tab.deviceKey, purpose: 'kiosk_order', allowReplay: true }),
  );
}

async function challengeRows(t: KioskTestApp, where: string, params: unknown[]) {
  return t.q<{
    id: string;
    phone_e164: string;
    status: string;
    kiosk_tablet_id: string | null;
    cart_id: string | null;
    notice_version: string | null;
    user_id: string | null;
    issued_by_user_id: string | null;
    device_key: string;
    replayed_at: Date | null;
  }>(
    `SELECT id, phone_e164, status::text AS status, kiosk_tablet_id, cart_id, notice_version, user_id,
            issued_by_user_id, device_key, replayed_at
       FROM otp_challenges WHERE ${where} ORDER BY created_at, id`,
    params,
  );
}

async function sentOfTablet(t: KioskTestApp, tabletId: string): Promise<number> {
  const r = await challengeRows(t, `kiosk_tablet_id = $1 AND status = 'sent'`, [tabletId]);
  return r.length;
}

async function counter(t: KioskTestApp, scope: string, subject: string): Promise<number> {
  const r = await t.q<{ n: string }>(
    `SELECT coalesce(sum(count), 0)::text AS n FROM rate_limit_counters WHERE scope = $1 AND subject = $2`,
    [scope, subject],
  );
  return Number(r[0]?.n ?? '0');
}

function quantile(xs: readonly number[], q: number): number {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil(q * s.length) - 1))] ?? 0;
}

describe('kiosk: POST /kiosk/order-otp — код к заявке с планшета (KIOSK_MODE=true)', () => {
  const t = new KioskTestApp();
  // Начало часа: окна 1 мин / 15 мин / 1 ч / 24 ч стенда не сменятся внутри файла (сдвиги часов — минуты).
  const clock = new FixedClock(new Date(Math.floor(Date.now() / HOUR_MS) * HOUR_MS + 1_000));
  let variant: SaleableVariant;
  let seller: PosActor;
  let customer: PosActor;

  const setSetting = async (key: string, value: number | null): Promise<void> => {
    if (value === null) await t.q(`DELETE FROM app_settings WHERE key = $1`, [key]);
    else await t.setSetting(key, String(value));
    t.app.get(SettingsReader).invalidate();
  };

  async function tabletWithCart(): Promise<{ tab: KioskTablet; cartId: string }> {
    const tab = await t.tablet();
    return { tab, cartId: await fillCart(t, tab, variant) };
  }

  beforeAll(async () => {
    // Как startKiosk стенда, плюс часы и глобальный лимит; пробные маршруты /kiosk/* не нужны — контроллер настоящий.
    await t.start({
      env: { QR_PROVIDER: 'none', KIOSK_MODE: 'true', OTP_GLOBAL_PER_MIN: '100000' },
      skuCount: 40,
      modules: [CartModule, OrdersModule, ProfileModule, PublicSettingsModule, KioskModule],
      guards: [KIOSK_ACCESS_GUARD],
      fakePorts: true,
      jobs: false,
      clock,
    });
    await createDevOutbox(t);
    variant = (await t.saleableVariants(1))[0];
    seller = await t.actor({ role: 'seller' });
    customer = await t.actor({ role: 'customer' });
  });

  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-011 empty cart 422 CART_EMPTY, no SMS: пустая, чужая, несуществующая корзина; тело и права', async () => {
    const tab = await t.tablet();
    const empty = await call(t, 'get', '/cart', tab);
    expect(empty.status).toBe(200);
    const other = await tabletWithCart();
    const sellerCart = await fillCart(t, seller, variant);
    const phone = freshPhone();
    for (const cartId of [empty.body.id as string, other.cartId, sellerCart, randomUUID()]) {
      const r = await orderOtp(t, tab, { phone, cartId, noticeVersion: NOTICE });
      expect([r.status, r.body.code], cartId).toEqual([422, 'CART_EMPTY']);
    }
    // SMS нет: ни кода, ни строки журнала SMS; квоты номера и планшета не тронуты
    expect(await challengeRows(t, 'phone_e164 = $1', [phone])).toEqual([]);
    expect(await t.q(`SELECT 1 FROM sms_outbox WHERE phone_e164 = $1`, [phone])).toEqual([]);
    expect(await counter(t, 'otp_kiosk_tablet_1h', tab.tabletId)).toBe(0);
    const phoneSubject = t.app.get(OtpService, { strict: false }).phoneSubject(phone);
    expect(await counter(t, 'otp_phone_15m', phoneSubject)).toBe(0);

    // Тело (OpenAPI KioskOrderOtpRequest, additionalProperties: false): 400 с правилами 08 §2.14
    const rule = async (body: unknown) => {
      const r = await orderOtp(t, other.tab, body);
      expect(r.status, JSON.stringify(body)).toBe(400);
      expect(r.body.code).toBe('VALIDATION_FAILED');
      return (r.body.errors as { field: string; rule: string }[]).map((e) => `${e.field}:${e.rule}`).sort();
    };
    const ok = { phone: freshPhone(), cartId: other.cartId, noticeVersion: NOTICE };
    expect(await rule({ ...ok, customerId: randomUUID() })).toEqual(['customerId:forbidden_field']);
    expect(await rule({ ...ok, phone: '+996312000000' })).toEqual(['phone:phone_e164']); // стационарный — не мобильный
    expect(await rule({ cartId: ok.cartId, noticeVersion: NOTICE })).toEqual(['phone:phone_e164']);
    expect(await rule({ ...ok, cartId: 'not-a-uuid' })).toEqual(['cartId:uuid']);
    expect(await rule({ phone: ok.phone, cartId: ok.cartId })).toEqual(['noticeVersion:max_length']);
    expect(await rule([ok])).toEqual(['body:type']);
    expect(await challengeRows(t, 'phone_e164 = $1', [ok.phone])).toEqual([]);

    // Право kiosk.order.submit — только у kind=kiosk (11 SEC-138): сотрудник и покупатель → 403 FORBIDDEN
    for (const a of [seller, customer]) {
      const r = await orderOtp(t, a, ok);
      expect([r.status, r.body.code], a.kind).toEqual([403, 'FORBIDDEN']);
    }
  });

  it('T-KIOSK-041 notice_version in code row and audit, unknown version 422 (до SMS)', async () => {
    const { tab, cartId } = await tabletWithCart();
    const phone = freshPhone();
    const unknown = await orderOtp(t, tab, { phone, cartId, noticeVersion: '2026-11-05' });
    expect([unknown.status, unknown.body.code]).toEqual([422, 'VALIDATION_FAILED']);
    expect(unknown.body.errors).toEqual([expect.objectContaining({ field: 'noticeVersion', rule: 'notice_version' })]);
    expect(await challengeRows(t, 'phone_e164 = $1', [phone])).toEqual([]);
    expect(await t.q(`SELECT 1 FROM sms_outbox WHERE phone_e164 = $1`, [phone])).toEqual([]);

    const r = await orderOtp(t, tab, { phone, cartId, noticeVersion: NOTICE });
    expect(r.status).toBe(202);
    const rows = await challengeRows(t, 'id = $1', [r.body.challengeId]);
    expect(rows).toEqual([
      expect.objectContaining({
        phone_e164: phone,
        status: 'sent',
        kiosk_tablet_id: tab.tabletId,
        cart_id: cartId,
        notice_version: NOTICE,
        user_id: null,
        issued_by_user_id: null,
        device_key: tab.deviceKey,
      }),
    ]);
    const audit = await t.auditRows('auth.otp.sent', r.body.challengeId as string);
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({
      result: 'ok',
      actor_user_id: tab.userId,
      after: { purpose: 'kiosk_order', kioskId: tab.tabletId, noticeVersion: NOTICE, testMode: false },
    });
    // номер в аудите — только маска (11 SEC-063)
    expect(JSON.stringify(audit[0]?.after)).not.toContain(phone.slice(4));
  });

  it('T-KIOSK-037 sms_outbox template otp_kiosk_order: свой текст, одна часть; код входа на тот же номер — прежний текст; dev_outbox — otp_login', async () => {
    const { tab, cartId } = await tabletWithCart();
    const phone = freshPhone();
    const k = await orderOtp(t, tab, { phone, cartId, noticeVersion: NOTICE });
    expect(k.status).toBe(202);
    const login = await t
      .req('post', '/auth/otp/request')
      .set('X-Device-Id', randomUUID())
      .send({ phone, purpose: 'login_or_register' });
    expect(login.status).toBe(202);
    const kioskCode = await codeOf(t, k.body.challengeId as string);
    const loginCode = await codeOf(t, login.body.challengeId as string);

    const sms = await t.q<{ otp_challenge_id: string; template_key: string; status: string; sms_parts: number }>(
      `SELECT otp_challenge_id, template_key, status::text AS status, sms_parts FROM sms_outbox WHERE phone_e164 = $1`,
      [phone],
    );
    const byChallenge = new Map(sms.map((s) => [s.otp_challenge_id, s]));
    expect(byChallenge.get(k.body.challengeId as string)).toMatchObject({
      template_key: 'otp_kiosk_order',
      status: 'sent',
      sms_parts: 1,
    });
    expect(byChallenge.get(login.body.challengeId as string)).toMatchObject({ template_key: 'otp_login' });

    const dev = await t.q<{ challenge: string; template_key: string; text: string }>(
      `SELECT c.id AS challenge, d.template_key, d.text FROM dev_outbox d
         JOIN otp_challenges c ON c.sms_outbox_id = d.sms_outbox_id WHERE d.phone_e164 = $1`,
      [phone],
    );
    const texts = new Map(dev.map((d) => [d.challenge, d]));
    // dev CHECK не меняется (ADR-115 п. 25): ключ в dev_outbox — otp_login, текст — настоящий
    expect(texts.get(k.body.challengeId as string)).toEqual({
      challenge: k.body.challengeId,
      template_key: 'otp_login',
      text: KIOSK_ORDER_SMS_TEMPLATE.replace('{code}', kioskCode),
    });
    expect(texts.get(login.body.challengeId as string)?.text).toBe(`Kod: ${loginCode}. Optomstroy`);
    // статус доставки SMS кода планшета — GET /auth/otp/challenges/{id} с X-Device-Id планшета (08 §4.1.9)
    const status = await call(t, 'get', `/auth/otp/challenges/${k.body.challengeId as string}`, tab);
    expect([status.status, status.body.delivery, status.body.channel]).toEqual([200, 'sent', 'sms']);
    // код и номер — не в журналах (09 §6.9, SEC-062)
    expect(t.logs.text).not.toContain(kioskCode);
    expect(t.logs.text).not.toContain(loginCode);
    expect(t.logs.text).not.toContain(phone.slice(4));
  });

  it('T-KIOSK-017 phone 429 OTP_RATE_LIMITED: 4-й запрос на номер за 15 мин; квоты номера общие для назначений', async () => {
    const { tab, cartId } = await tabletWithCart();
    const phone = freshPhone();
    const window15 = Math.floor(clock.now().getTime() / 900_000);
    for (let i = 0; i < 3; i += 1) {
      const r = await orderOtp(t, tab, { phone, cartId, noticeVersion: NOTICE });
      expect(r.status, `запрос ${i + 1}`).toBe(202);
      clock.advance(61_000); // после cooldown 60 с
    }
    const fourth = await orderOtp(t, tab, { phone, cartId, noticeVersion: NOTICE });
    expect(Math.floor(clock.now().getTime() / 900_000)).toBe(window15); // одно окно 15 мин
    expect([fourth.status, fourth.body.code]).toEqual([429, 'OTP_RATE_LIMITED']);
    expect(fourth.body.retryAfter).toBeGreaterThan(0);
    const audit = (await t.auditRows('auth.otp.rate_limited')).filter((a) => a.after?.kioskId === tab.tabletId);
    expect(audit).toEqual([
      expect.objectContaining({ result: 'denied', after: expect.objectContaining({ scope: 'otp_phone_15m' }) }),
    ]);
    expect(await t.auditRows('kiosk.limit_reached', tab.tabletId)).toEqual([]);
    expect(await sentOfTablet(t, tab.tabletId)).toBe(1);
  });

  it('T-KIOSK-017 tablet 429 KIOSK_RATE_LIMITED, audit kiosk.limit_reached: 31-й код за час; другой планшет — свой лимит', async () => {
    await setSetting('kiosk_otp_per_hour', null);
    await setSetting('kiosk_otp_per_day', null);
    const { tab, cartId } = await tabletWithCart();
    for (let i = 0; i < 30; i += 1) {
      const r = await orderOtp(t, tab, { phone: freshPhone(), cartId, noticeVersion: NOTICE });
      expect(r.status, `код ${i + 1}`).toBe(202);
    }
    const phone = freshPhone();
    const over = await orderOtp(t, tab, { phone, cartId, noticeVersion: NOTICE });
    expect([over.status, over.body.code]).toEqual([429, 'KIOSK_RATE_LIMITED']);
    expect(over.body.retryAfter).toBeGreaterThan(0);
    expect(over.body.retryAfter).toBeLessThanOrEqual(3600);
    expect(over.headers['retry-after']).toBe(String(over.body.retryAfter));
    // отказ квоты не расходует: кода нет, счётчики номера и планшета прежние
    expect(await challengeRows(t, 'phone_e164 = $1', [phone])).toEqual([]);
    const otp = t.app.get(OtpService, { strict: false });
    expect(await counter(t, 'otp_phone_15m', otp.phoneSubject(phone))).toBe(0);
    expect(await counter(t, 'otp_kiosk_tablet_1h', tab.tabletId)).toBe(30);
    expect(await sentOfTablet(t, tab.tabletId)).toBe(1);

    const audit = await t.auditRows('kiosk.limit_reached', tab.tabletId);
    expect(audit).toEqual([
      expect.objectContaining({
        result: 'denied',
        // актор — система (11 §7.2.1), как у kiosk.network_denied; сеанс планшета остаётся в контексте записи
        actor_user_id: null,
        after: { kioskId: tab.tabletId, scope: 'otp_kiosk_tablet_1h', limit: 30 },
      }),
    ]);
    expect(
      await t.q(
        `SELECT actor_role::text AS actor_role, session_id FROM audit_logs
          WHERE action = 'kiosk.limit_reached' AND entity_id = $1`,
        [tab.tabletId],
      ),
    ).toEqual([{ actor_role: null, session_id: tab.sessionId }]);
    expect(JSON.stringify(audit)).not.toContain('+996');
    const alerts = t.logs
      .json()
      .filter((e) => e.event === 'security.alert' && e.alert === 'kiosk.limit_reached' && e.kioskId === tab.tabletId);
    expect(alerts).toEqual([expect.objectContaining({ scope: 'otp_kiosk_tablet_1h', limit: 30 })]);
    expect(JSON.stringify(alerts)).not.toContain('+996');

    // лимит одного планшета не тратит лимит другого (T-SEC-071)
    const second = await tabletWithCart();
    const r2 = await orderOtp(t, second.tab, { phone: freshPhone(), cartId: second.cartId, noticeVersion: NOTICE });
    expect(r2.status).toBe(202);
  });

  it('T-KIOSK-017 tablet 429 KIOSK_RATE_LIMITED — лимит за сутки из app_settings (kiosk_otp_per_day)', async () => {
    await setSetting('kiosk_otp_per_day', 3);
    try {
      const { tab, cartId } = await tabletWithCart();
      for (let i = 0; i < 3; i += 1) {
        expect((await orderOtp(t, tab, { phone: freshPhone(), cartId, noticeVersion: NOTICE })).status).toBe(202);
      }
      const over = await orderOtp(t, tab, { phone: freshPhone(), cartId, noticeVersion: NOTICE });
      expect([over.status, over.body.code]).toEqual([429, 'KIOSK_RATE_LIMITED']);
      expect(await t.auditRows('kiosk.limit_reached', tab.tabletId)).toEqual([
        expect.objectContaining({ after: { kioskId: tab.tabletId, scope: 'otp_kiosk_tablet_24h', limit: 3 } }),
      ]);
    } finally {
      await setSetting('kiosk_otp_per_day', null);
    }
  });

  it('T-KIOSK-018 three tablets behind one NAT, 25 codes, IP rule not applied (и правило X-Device-Id тоже)', async () => {
    const tabs = [await tabletWithCart(), await tabletWithCart(), await tabletWithCart()];
    const sumScopes = async (scopes: string[]) =>
      Number(
        (
          await t.q<{ n: string }>(
            `SELECT coalesce(sum(count), 0)::text AS n FROM rate_limit_counters WHERE scope = ANY($1::text[])`,
            [scopes],
          )
        )[0]?.n ?? '0',
      );
    const ipBefore = await sumScopes(['otp_ip_10m', 'otp_ip_24h']);
    const globalBefore = await counter(t, 'otp_global_1m', 'global');
    // Все запросы — с одного адреса стенда (127.0.0.1): IP-лимит 20 / 10 мин сработал бы на 21-м, лимит устройства
    // 5 / 10 мин — на 6-м коде планшета.
    for (let i = 0; i < 25; i += 1) {
      const x = tabs[i % 3];
      const r = await orderOtp(t, x.tab, { phone: freshPhone(), cartId: x.cartId, noticeVersion: NOTICE });
      expect(r.status, `код ${i + 1}`).toBe(202);
    }
    expect(await sumScopes(['otp_ip_10m', 'otp_ip_24h'])).toBe(ipBefore);
    const deviceRows = await t.q(
      `SELECT 1 FROM rate_limit_counters WHERE scope IN ('otp_device_10m', 'otp_device_24h') AND subject = ANY($1::text[])`,
      [tabs.map((x) => x.tab.deviceKey)],
    );
    expect(deviceRows).toEqual([]);
    expect(await Promise.all(tabs.map((x) => counter(t, 'otp_kiosk_tablet_1h', x.tab.tabletId)))).toEqual([9, 8, 8]);
    expect(await Promise.all(tabs.map((x) => counter(t, 'otp_kiosk_tablet_24h', x.tab.tabletId)))).toEqual([9, 8, 8]);
    // глобальный лимит — как есть: те же 25 списаний
    expect((await counter(t, 'otp_global_1m', 'global')) - globalBefore).toBe(25);
    for (const x of tabs) expect(await sentOfTablet(t, x.tab.tabletId)).toBe(1);
  });

  it('T-KIOSK-052 change number supersedes, one sent code, same phone < 60 s 429 retryAfter', async () => {
    const { tab, cartId } = await tabletWithCart();
    const a = freshPhone();
    const b = freshPhone();
    const ra = await orderOtp(t, tab, { phone: a, cartId, noticeVersion: NOTICE });
    expect(ra.status).toBe(202);
    const codeA = await codeOf(t, ra.body.challengeId as string);
    const rb = await orderOtp(t, tab, { phone: b, cartId, noticeVersion: NOTICE });
    expect(rb.status).toBe(202);
    const codeB = await codeOf(t, rb.body.challengeId as string);
    const rows = await challengeRows(t, 'kiosk_tablet_id = $1', [tab.tabletId]);
    expect(rows.map((r) => [r.phone_e164, r.status])).toEqual([
      [a, 'superseded'],
      [b, 'sent'],
    ]);
    // код A больше не действует (422 OTP_EXPIRED, «Код больше не действует»), код B работает
    const checkA = await checkCode(t, tab, ra.body.challengeId as string, codeA);
    expect(checkA.kind).toBe('expired');
    if (checkA.kind === 'expired') {
      const p = OtpService.toProblem(checkA);
      expect([p.getStatus(), p.code]).toEqual([422, 'OTP_EXPIRED']);
    }
    // снова A раньше 60 с — таймер, а не ошибка: 429 OTP_RATE_LIMITED с retryAfter
    const again = await orderOtp(t, tab, { phone: a, cartId, noticeVersion: NOTICE });
    expect([again.status, again.body.code, again.body.retryAfter]).toEqual([429, 'OTP_RATE_LIMITED', 60]);
    expect(again.headers['retry-after']).toBe('60');
    expect(await sentOfTablet(t, tab.tabletId)).toBe(1);
    expect((await checkCode(t, tab, rb.body.challengeId as string, codeB)).kind).toBe('ok');

    // код на тот же номер с другого планшета (после cooldown) вытесняет код первого планшета (один sent на номер)
    const c = freshPhone();
    const first = await orderOtp(t, tab, { phone: c, cartId, noticeVersion: NOTICE });
    expect(first.status).toBe(202);
    clock.advance(61_000);
    const other = await tabletWithCart();
    const second = await orderOtp(t, other.tab, { phone: c, cartId: other.cartId, noticeVersion: NOTICE });
    expect(second.status).toBe(202);
    expect((await challengeRows(t, 'id = $1', [first.body.challengeId]))[0]?.status).toBe('superseded');
    expect(await sentOfTablet(t, tab.tabletId)).toBe(0);
    expect(await sentOfTablet(t, other.tab.tabletId)).toBe(1);
  });

  it('T-KIOSK-052 Idempotency-Key ignored: тот же ключ на два номера — два кода (202, разные challengeId), в idempotency_keys ничего', async () => {
    const { tab, cartId } = await tabletWithCart();
    const key = randomUUID();
    const send = async (phone: string) => {
      const res = await t
        .req('post', '/kiosk/order-otp', tab, { idem: key })
        .send({ phone, cartId, noticeVersion: NOTICE });
      return { status: res.status, body: (res.body ?? {}) as Res['body'] };
    };
    const first = await send(freshPhone());
    const second = await send(freshPhone());
    expect([first.status, second.status], JSON.stringify([first.body, second.body])).toEqual([202, 202]);
    expect(typeof first.body.challengeId).toBe('string');
    expect(second.body.challengeId).not.toBe(first.body.challengeId);
    // новый запрос — новый код: первый вытеснен (один sent на планшет), ключ не сохранён (номер — в теле запроса)
    expect((await challengeRows(t, 'id = $1', [first.body.challengeId]))[0]?.status).toBe('superseded');
    expect(await sentOfTablet(t, tab.tabletId)).toBe(1);
    expect(await t.q(`SELECT count(*)::int AS n FROM idempotency_keys WHERE route = 'POST /kiosk/order-otp'`)).toEqual([
      { n: 0 },
    ]);
  });

  it('T-KIOSK-052 одновременные запросы: блокировка «планшет → номер», без 23505 и 500; один sent на планшет', async () => {
    const { tab, cartId } = await tabletWithCart();
    // Порядок блокировок 09 §5.4 — сначала планшет, затем номер (код входа планшет не блокирует)
    const repo = t.app.get(OtpChallengesRepository, { strict: false });
    const locks: string[] = [];
    const lockTablet = vi.spyOn(repo, 'lockKioskTablet');
    const lockPhone = vi.spyOn(repo, 'lockPhone');
    lockTablet.mockImplementation(async (id, ex) => {
      locks.push(`tablet:${id === tab.tabletId}`);
      await ex.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${`otp:kiosk:${id}`}, 0))`);
    });
    lockPhone.mockImplementation(async (phone, purpose, ex) => {
      locks.push(`phone:${purpose}`);
      await ex.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${`otp:${purpose}:${phone}`}, 0))`);
    });
    try {
      expect((await orderOtp(t, tab, { phone: freshPhone(), cartId, noticeVersion: NOTICE })).status).toBe(202);
      const login = await t
        .req('post', '/auth/otp/request')
        .set('X-Device-Id', randomUUID())
        .send({ phone: freshPhone(), purpose: 'login_or_register' });
      expect(login.status).toBe(202);
      expect(locks.slice(0, 2)).toEqual(['tablet:true', 'phone:kiosk_order']);
      // вход: только блокировка номера (её берут и аварийный код, и выпуск кода), планшет не блокируется
      expect(locks.slice(2).length).toBeGreaterThan(0);
      expect(new Set(locks.slice(2))).toEqual(new Set(['phone:login_or_register']));
    } finally {
      lockTablet.mockRestore();
      lockPhone.mockRestore();
    }

    const phones = Array.from({ length: 6 }, () => freshPhone());
    const burst = await Promise.all(phones.map((phone) => orderOtp(t, tab, { phone, cartId, noticeVersion: NOTICE })));
    expect(burst.map((r) => r.status)).toEqual(phones.map(() => 202));
    expect(await sentOfTablet(t, tab.tabletId)).toBe(1);
    const rows = await challengeRows(t, 'kiosk_tablet_id = $1', [tab.tabletId]);
    // код проверки порядка блокировок и 5 из 6 одновременных кодов вытеснены
    expect(rows.filter((r) => r.status === 'superseded')).toHaveLength(6);

    // два планшета на один номер одновременно и тот же планшет на другой номер: один код номера, без взаимоблокировки
    const other = await tabletWithCart();
    const x = freshPhone();
    const y = freshPhone();
    const mixed = await Promise.all([
      orderOtp(t, tab, { phone: x, cartId, noticeVersion: NOTICE }),
      orderOtp(t, other.tab, { phone: x, cartId: other.cartId, noticeVersion: NOTICE }),
      orderOtp(t, tab, { phone: y, cartId, noticeVersion: NOTICE }),
    ]);
    expect(mixed.every((r) => r.status === 202 || (r.status === 429 && r.body.code === 'OTP_RATE_LIMITED'))).toBe(true);
    expect(
      mixed
        .slice(0, 2)
        .map((r) => r.status)
        .sort(),
    ).toEqual([202, 429]);
    expect(mixed[2]?.status).toBe(202);
    expect((await challengeRows(t, `phone_e164 = $1 AND status = 'sent'`, [x])).length).toBeLessThanOrEqual(1);
    expect(await sentOfTablet(t, tab.tabletId)).toBeLessThanOrEqual(1);
    expect(await sentOfTablet(t, other.tab.tabletId)).toBeLessThanOrEqual(1);
    expect(t.logs.text).not.toContain('23505');
  });

  it('gashKioskCodes (AUTH-054; для сброса, отключения, выхода и подключения заново): sent → superseded, verified → replayed_at', async () => {
    const { tab, cartId } = await tabletWithCart();
    const other = await tabletWithCart();
    const r1 = await orderOtp(t, tab, { phone: freshPhone(), cartId, noticeVersion: NOTICE });
    const code1 = await codeOf(t, r1.body.challengeId as string);
    expect((await checkCode(t, tab, r1.body.challengeId as string, code1)).kind).toBe('ok'); // верный, не погашен
    const r2 = await orderOtp(t, tab, { phone: freshPhone(), cartId, noticeVersion: NOTICE });
    const code2 = await codeOf(t, r2.body.challengeId as string);
    const rOther = await orderOtp(t, other.tab, { phone: freshPhone(), cartId: other.cartId, noticeVersion: NOTICE });
    expect([r1.status, r2.status, rOther.status]).toEqual([202, 202, 202]);

    const repo = new OtpChallengesRepository(t.db);
    const at = clock.now();
    const res = await t.db.transaction((tx) => repo.gashKioskCodes(tx, tab.tabletId, at));
    expect(res).toEqual({ superseded: 1, replayed: 1 });
    const rows = await challengeRows(t, 'kiosk_tablet_id = $1', [tab.tabletId]);
    expect(rows.map((r) => [r.id, r.status, r.replayed_at !== null])).toEqual([
      [r1.body.challengeId, 'verified', true],
      [r2.body.challengeId, 'superseded', false],
    ]);
    // погашенный код → 422 OTP_EXPIRED (в том числе повтор верного кода в окне allowReplay)
    expect((await checkCode(t, tab, r1.body.challengeId as string, code1)).kind).toBe('expired');
    expect((await checkCode(t, tab, r2.body.challengeId as string, code2)).kind).toBe('expired');
    // чужой планшет не затронут; повтор — без изменений
    expect(await sentOfTablet(t, other.tab.tabletId)).toBe(1);
    expect(await t.db.transaction((tx) => repo.gashKioskCodes(tx, tab.tabletId, at))).toEqual({
      superseded: 0,
      replayed: 0,
    });
  });

  it('T-KIOSK-012 same status, body and time for card/no card/staff phone (T-SEC-006 tolerance)', async () => {
    await setSetting('kiosk_otp_per_hour', 1000);
    try {
      const { tab, cartId } = await tabletWithCart();
      const n = 20;
      const card: string[] = [];
      const staff: string[] = [];
      for (let i = 0; i < n; i += 1) {
        const p = freshPhone();
        await t.createOnecCustomer({ phoneE164: p, name: `ООО «Тестовая карточка ${i}»` });
        card.push(p);
        const s = await t.actor({ role: 'seller' });
        const row = await t.q<{ phone_e164: string }>(`SELECT phone_e164 FROM users WHERE id = $1`, [s.userId]);
        staff.push(row[0]?.phone_e164);
      }
      const none = Array.from({ length: n }, () => freshPhone());
      const groups = { card, none, staff } as const;
      const usersBefore = (await t.q(`SELECT 1 FROM users`)).length;
      const sessionsBefore = (await t.q(`SELECT 1 FROM sessions`)).length;

      for (let i = 0; i < 5; i += 1) await orderOtp(t, tab, { phone: freshPhone(), cartId, noticeVersion: NOTICE });
      await provider(t).drain();
      const times: Record<keyof typeof groups, number[]> = { card: [], none: [], staff: [] };
      const shapes = new Set<string>();
      const order: (keyof typeof groups)[] = ['card', 'none', 'staff'];
      for (let i = 0; i < n; i += 1) {
        for (let j = 0; j < order.length; j += 1) {
          const g = order[(i + j) % order.length];
          const phone = groups[g][i];
          const t0 = performance.now();
          const r = await orderOtp(t, tab, { phone, cartId, noticeVersion: NOTICE });
          times[g].push(performance.now() - t0);
          expect(r.status, `${g} ${i}`).toBe(202);
          expect(Object.keys(r.body).sort()).toEqual(['challengeId', 'resendAfterSec']);
          expect(JSON.stringify(r.body)).not.toContain(phone.slice(4));
          shapes.add(JSON.stringify({ ...r.body, challengeId: 'x' }));
          await provider(t).drain(); // фоновая отправка — вне замера
        }
      }
      expect([...shapes]).toEqual([JSON.stringify({ challengeId: 'x', resendAfterSec: 60 })]);
      const med = Object.values(times).map((xs) => quantile(xs, 0.5));
      const p95 = Object.values(times).map((xs) => quantile(xs, 0.95));
      expect(Math.max(...med) - Math.min(...med), `медианы ${med.join(', ')}`).toBeLessThan(20);
      expect(Math.max(...p95) - Math.min(...p95), `p95 ${p95.join(', ')}`).toBeLessThan(50);
      // путь обработки одинаков: у всех кодов user_id NULL, учётные записи и сессии не созданы
      const all = [...card, ...none, ...staff];
      const rows = await challengeRows(t, 'phone_e164 = ANY($1::text[])', [all]);
      expect(rows).toHaveLength(3 * n);
      expect(rows.every((r) => r.user_id === null && r.kiosk_tablet_id === tab.tabletId)).toBe(true);
      expect((await t.q(`SELECT 1 FROM users`)).length).toBe(usersBefore);
      expect((await t.q(`SELECT 1 FROM sessions`)).length).toBe(sessionsBefore);
    } finally {
      await setSetting('kiosk_otp_per_hour', null);
    }
  });
});
