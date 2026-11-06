import { randomUUID } from 'node:crypto';
import { vi } from 'vitest';
import { JwtService } from '../../../src/common/auth/jwt.service.js';
import { OnecError } from '../../../src/integrations/onec/onec-error.js';
import {
  KIOSK_CONFLICT_FIELDS,
  KIOSK_ONEC_REJECTED_DETAIL,
} from '../../../src/kiosk/common/kiosk-problem.sanitizer.js';
import {
  buyerPhone,
  KioskE2eApp,
  OTP_TEST_CODE,
  type Res,
  type SaleableVariant,
  type Subject,
  type Tablet,
} from './support/kiosk-e2e.js';

/**
 * Проверки безопасности планшета магазина T-SEC-070…T-SEC-073 (12 §3.23, группа «Безопасность планшета»; 11 SEC-016,
 * SEC-013, SEC-139, SEC-141; 09 §5.3, §5.4, §8.9; 08 §2.2, §2.4, §2.7, §4.25; 10 KIOSK-011, KIOSK-012, KIOSK-016,
 * KIOSK-031; P-002 §8, §12; ADR-115) на **всём приложении** AppModule (`createApp`: все модули, глобальные guard-ы
 * ReadOnly → Auth → SessionActivity → KioskAccess → RBAC, идемпотентность, Problem):
 * - T-SEC-070: после кода `kiosk_order` и заявки ни одна операция не выдаёт токенов; строк `users`, `devices`,
 *   `sessions`, `customer_links`, `consents` для покупателя нет (номер без учётной записи и номер сотрудника);
 *   код `kiosk_order` в `POST /auth/otp/verify` — `404`;
 * - T-SEC-071: лимит кодов считается по токену планшета (`otp_kiosk_tablet_1h`, `otp_kiosk_tablet_24h`); лимиты IP
 *   и `X-Device-Id` к планшету не применяются, смена `X-Device-Id` лимит не обходит; лимит одного планшета не тратит
 *   лимит другого за тем же IP; лимиты номера, IP входа и глобальный — как прежде;
 * - T-SEC-072: `401 KIOSK_REVOKED` и от AuthGuard (denylist `jti` и `revoked_at` сессии), и от `/auth/refresh`
 *   (живой и истёкший access); иная причина отзыва сессии планшета — `401 SESSION_REVOKED`;
 * - T-SEC-073: в ответах планшету (`/kiosk/*`, `/cart*`, `GET /me`, каталог) и в `idempotency_keys` планшета нет
 *   телефона, ФИО, клиента, сумм заявки и цен соглашения; `conflicts[]` — только `variantId`, `kind`, `stockLevel`;
 *   `ONEC_REJECTED` — без `onec` и текста 1С.
 * Модульные проверки тех же правил — `test/kiosk/orders.spec.ts`, `order-otp.spec.ts`, `lifecycle-reconnect.spec.ts`.
 * **Тестовые данные**: embedded PostgreSQL 17, синтетический каталог, фейк 1С (`ONEC_MODE=fixtures`), тестовый код
 * SMS 09 §5.8; номера покупателей — вымышленные `+996 555 07x xxx`, карточка «Асанова Айгуль (тест)».
 */
const IP_LIMIT_10M = 2;
const DEVICE_LIMIT_10M = 2;
const TABLET_PER_HOUR = 4;

/** Ключи токенов и сессии в любом месте тела ответа (09 §8, 11 SEC-062). */
const TOKEN_KEYS = /"(accessToken|refreshToken|registrationToken|stepUpToken|sid|sessionId)"\s*:/;

describe('kiosk e2e: безопасность планшета магазина (T-SEC-070…T-SEC-073)', () => {
  const t = new KioskE2eApp();
  let v: SaleableVariant[];
  let seller: Subject;

  beforeAll(async () => {
    await t.start(
      'kiosk_security_e2e',
      {
        // Лимиты IP и устройства запроса кода (09 §5.4) — низкие: применись они к планшету, сработали бы на 3-м коде.
        OTP_MAX_SENDS_PER_IP_10M: String(IP_LIMIT_10M),
        OTP_MAX_SENDS_PER_DEVICE_10M: String(DEVICE_LIMIT_10M),
      },
      30,
    );
    v = await t.saleableVariants(4);
    seller = await t.subject('seller');
  });

  afterAll(async () => {
    vi.restoreAllMocks();
    await t.stop();
  });

  async function count(table: string, where = 'true', params: unknown[] = []): Promise<number> {
    return (await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM ${table} WHERE ${where}`, params))[0].n;
  }

  async function counter(scope: string, subject?: string): Promise<number> {
    const r = await t.q<{ n: string }>(
      `SELECT coalesce(sum(count), 0)::text AS n FROM rate_limit_counters WHERE scope = $1 ${subject ? 'AND subject = $2' : ''}`,
      subject ? [scope, subject] : [scope],
    );
    return Number(r[0]?.n ?? '0');
  }

  it('T-SEC-070 no session or accounts after kiosk code: номер без учётной записи и номер seller1; код в /auth/otp/verify — 404', async () => {
    const tab = await t.enroll({ name: 'Планшет у входа' });
    const sellerPhone = await t.phoneOf(seller.userId);
    const stranger = buyerPhone('07');
    const tables = ['users', 'devices', 'sessions', 'customer_links', 'consents'] as const;
    const before = Object.fromEntries(await Promise.all(tables.map(async (x) => [x, await count(x)] as const)));
    const sellerSessions = await count('sessions', 'user_id = $1', [seller.userId]);

    const responses: Res[] = [];
    for (const phone of [stranger, sellerPhone]) {
      await t.putItem(tab, v[0]);
      const otp = await t.orderOtp(tab, phone);
      expect(otp.status, JSON.stringify(otp.body)).toBe(202);
      expect(Object.keys(otp.body).sort()).toEqual(['challengeId', 'resendAfterSec']);
      const p = await t.preview(tab);
      expect(p.status, JSON.stringify(p.body)).toBe(200);
      const key = randomUUID();
      const order = await t.submit(
        tab,
        {
          challengeId: String(otp.body.challengeId),
          code: OTP_TEST_CODE,
          cartId: String(p.body.cartId),
          cartRowVersion: Number(p.body.cartRowVersion),
          previewToken: String(p.body.previewToken),
        },
        key,
      );
      expect(order.status, JSON.stringify(order.body)).toBe(201);
      expect(Object.keys(order.body)).toEqual(['publicNumber']);
      const found = await t.call('get', `/kiosk/orders?idempotencyKey=${key}`, tab);
      expect([found.status, found.body]).toEqual([200, { publicNumber: order.body.publicNumber }]);
      responses.push(otp, p, order, found);
    }
    // Ни одна операция не выдала токенов, сессии или учётной записи.
    for (const r of responses) expect(r.text).not.toMatch(TOKEN_KEYS);
    const after = Object.fromEntries(await Promise.all(tables.map(async (x) => [x, await count(x)] as const)));
    expect(after).toEqual(before);
    expect(await count('users', 'phone_e164 = $1', [stranger])).toBe(0);
    expect(await count('users', 'phone_e164 = $1', [sellerPhone])).toBe(1);
    expect(await count('sessions', 'user_id = $1', [seller.userId])).toBe(sellerSessions);
    // Заявки — от технического пользователя планшета, на номер покупателя; коды — без пользователя.
    expect(await count('orders', `created_via = 'kiosk' AND created_by_user_id = $1`, [tab.userId])).toBe(2);
    expect(await count('otp_challenges', `purpose = 'kiosk_order' AND user_id IS NOT NULL`)).toBe(0);

    // Код kiosk_order во входе — 404 (назначения не смешиваются), и без Bearer, и с Bearer планшета.
    await t.putItem(tab, v[1]);
    const fresh = await t.orderOtp(tab, buyerPhone('07'));
    expect(fresh.status).toBe(202);
    const device = { name: 'Планшет e2e', platform: 'android', appVersion: '99.0.0' };
    const auths: Record<string, string>[] = [{}, { Authorization: `Bearer ${tab.token}` }];
    for (const auth of auths) {
      const r = await t.call('post', '/auth/otp/verify', undefined, {
        headers: { 'X-Device-Id': tab.deviceKey, ...auth },
        body: { challengeId: fresh.body.challengeId, code: OTP_TEST_CODE, device },
      });
      expect([r.status, r.body.code]).toEqual([404, 'NOT_FOUND']);
      expect(r.text).not.toMatch(TOKEN_KEYS);
    }
    expect(Object.fromEntries(await Promise.all(tables.map(async (x) => [x, await count(x)] as const)))).toEqual(
      before,
    );
    // Код не потрачен входом: остаётся `sent` для заявки этого планшета.
    expect(
      await t.q(`SELECT status::text AS status, attempts FROM otp_challenges WHERE id = $1`, [fresh.body.challengeId]),
    ).toEqual([{ status: 'sent', attempts: 0 }]);
  });

  it('T-SEC-071 tablet limits replace IP/device: лимит по токену планшета, X-Device-Id его не обходит, два планшета за одним IP', async () => {
    await t.setSetting('kiosk_otp_per_hour', String(TABLET_PER_HOUR));
    try {
      const a = await t.enroll({ name: 'Планшет A' });
      const b = await t.enroll({ name: 'Планшет B' });
      for (const x of [a, b]) await t.putItem(x, v[0]);
      const ipBefore = await counter('otp_ip_10m');
      const globalBefore = await counter('otp_global_1m');

      // Все запросы — с одного адреса (127.0.0.1 стенда): лимит IP (2 / 10 мин) и устройства (2 / 10 мин) сработал
      // бы на 3-м коде; у планшета — только свой лимит за час (4).
      const phones: string[] = [];
      for (let i = 0; i < TABLET_PER_HOUR; i += 1) {
        const phone = buyerPhone('07');
        phones.push(phone);
        const r = await t.orderOtp(a, phone);
        expect(r.status, `код ${i + 1}: ${JSON.stringify(r.body)}`).toBe(202);
      }
      const over = await t.orderOtp(a, buyerPhone('07'));
      expect([over.status, over.body.code]).toEqual([429, 'KIOSK_RATE_LIMITED']);
      expect(Number(over.body.retryAfter)).toBeGreaterThan(0);
      expect(over.headers['retry-after']).toBe(String(over.body.retryAfter));
      expect(await counter('otp_kiosk_tablet_1h', a.tabletId)).toBe(TABLET_PER_HOUR);
      expect(await counter('otp_kiosk_tablet_24h', a.tabletId)).toBe(TABLET_PER_HOUR);
      expect(await counter('otp_ip_10m')).toBe(ipBefore);
      expect(
        await count(`rate_limit_counters`, `scope IN ('otp_device_10m', 'otp_device_24h') AND subject = $1`, [
          a.deviceKey,
        ]),
      ).toBe(0);

      // Смена X-Device-Id лимит не обходит: токен планшета привязан к своему устройству — AuthGuard отвечает
      // 401 SESSION_REVOKED (reason device_mismatch, 08 §2.2/§2.4) до лимитов, кода нет, счётчик планшета не тронут.
      const codesBefore = await count('otp_challenges', 'kiosk_tablet_id = $1', [a.tabletId]);
      const spoofed = await t.orderOtp({ token: a.token, deviceKey: randomUUID() }, buyerPhone('07'));
      expect([spoofed.status, spoofed.body.code]).toEqual([401, 'SESSION_REVOKED']);
      expect(await count('otp_challenges', 'kiosk_tablet_id = $1', [a.tabletId])).toBe(codesBefore);
      expect(await counter('otp_kiosk_tablet_1h', a.tabletId)).toBe(TABLET_PER_HOUR);
      // Сессия планшета жива (отказ не отзывает её): тот же токен со своим X-Device-Id — снова лимит планшета, а не 401.
      const genuine = await t.orderOtp(a, buyerPhone('07'));
      expect([genuine.status, genuine.body.code]).toEqual([429, 'KIOSK_RATE_LIMITED']);
      expect(await count('otp_challenges', 'kiosk_tablet_id = $1', [a.tabletId])).toBe(codesBefore);
      expect(await counter('otp_kiosk_tablet_1h', a.tabletId)).toBe(TABLET_PER_HOUR);

      // Второй планшет за тем же IP: свой лимит, исчерпанный лимит планшета A его не тратит.
      const second = await t.orderOtp(b, buyerPhone('07'));
      expect(second.status, JSON.stringify(second.body)).toBe(202);
      expect(await counter('otp_kiosk_tablet_1h', b.tabletId)).toBe(1);

      // Лимиты номера — как прежде: тот же номер с другого планшета в паузе повторной отправки — 429 OTP_RATE_LIMITED.
      const samePhone = await t.orderOtp(b, phones[0]);
      expect([samePhone.status, samePhone.body.code]).toEqual([429, 'OTP_RATE_LIMITED']);
      // Глобальный лимит — как прежде: каждый выданный код списан (4 + 1).
      expect((await counter('otp_global_1m')) - globalBefore).toBe(TABLET_PER_HOUR + 1);

      // Лимит IP входа (SEC-016) — как прежде и не потрачен кодами планшетов: 2 кода входа с этого IP, 3-й — 429.
      const login = (phone: string) =>
        t.call('post', '/auth/otp/request', undefined, {
          headers: { 'X-Device-Id': randomUUID() },
          body: { phone, purpose: 'login_or_register', locale: 'ru' },
        });
      for (let i = 0; i < IP_LIMIT_10M; i += 1) {
        const r = await login(buyerPhone('07'));
        expect(r.status, `вход ${i + 1}: ${JSON.stringify(r.body)}`).toBe(202);
      }
      const ipOver = await login(buyerPhone('07'));
      expect([ipOver.status, ipOver.body.code]).toEqual([429, 'RATE_LIMITED']);
      // Аудит отказа лимита планшета — без номеров (11 §7.2.1): два отказа планшета A (до и после попытки с чужим
      // X-Device-Id); сама попытка (401 AuthGuard) строки не пишет.
      const audit = await t.q<{ after: Record<string, unknown> }>(
        `SELECT after FROM audit_logs WHERE action = 'kiosk.limit_reached' AND entity_id = $1 ORDER BY chain_seq`,
        [a.tabletId],
      );
      const limitRow = { after: { kioskId: a.tabletId, scope: 'otp_kiosk_tablet_1h', limit: TABLET_PER_HOUR } };
      expect(audit).toEqual([limitRow, limitRow]);
    } finally {
      await t.setSetting('kiosk_otp_per_hour', null);
    }
  });

  it('T-SEC-072 KIOSK_REVOKED on refresh and AuthGuard: denylist jti и revoked_at; живой и истёкший access; иная причина — SESSION_REVOKED', async () => {
    const tab = await t.enroll({ name: 'Планшет у кассы' });
    expect((await t.call('get', '/cart', tab)).status).toBe(200);
    const revoked = await t.revoke(tab.tabletId);
    expect(revoked.status, JSON.stringify(revoked.body)).toBe(200);
    expect(await t.q(`SELECT revoke_reason FROM sessions WHERE user_id = $1 ORDER BY issued_at`, [tab.userId])).toEqual(
      [{ revoke_reason: 'kiosk_revoked' }],
    );

    // AuthGuard: живой access (его jti — в denylist после отключения) → 401 KIOSK_REVOKED на любом маршруте списка.
    for (const path of ['/cart', '/me', '/settings/public', '/catalog/products?limit=1']) {
      const r = await t.call('get', path, tab);
      expect([r.status, r.body.code], path).toEqual([401, 'KIOSK_REVOKED']);
    }
    const exit = await t.call('post', '/kiosk/exit', tab, { body: { code: tab.exitCode } });
    expect([exit.status, exit.body.code]).toEqual([401, 'KIOSK_REVOKED']);
    // AuthGuard: новый access той же сессии (jti не в denylist) — отказ по revoked_at сессии, тот же код.
    const jwt = t.app.get(JwtService);
    const pv = (await t.q<{ v: number }>(`SELECT permissions_version AS v FROM users WHERE id = $1`, [tab.userId]))[0]
      .v;
    const fresh = (
      await jwt.signAccess({
        sub: tab.userId,
        kind: 'kiosk',
        roles: ['kiosk'],
        permissionsVersion: pv,
        deviceId: tab.deviceKey,
        sid: tab.sessionId,
        amr: ['pin'],
      })
    ).token;
    t.clearAuthCache();
    const byRow = await t.call('get', '/cart', { token: fresh, deviceKey: tab.deviceKey });
    expect([byRow.status, byRow.body.code]).toEqual([401, 'KIOSK_REVOKED']);

    // /auth/refresh: refresh планшета после отключения → 401 KIOSK_REVOKED (так приложение узнаёт об отключении и
    // при истёкшем access: access истёк → refresh → KIOSK_REVOKED).
    const refresh = () =>
      t.call('post', '/auth/refresh', undefined, {
        headers: { 'X-Device-Id': tab.deviceKey },
        body: { refreshToken: tab.refreshToken },
      });
    const rf = await refresh();
    expect([rf.status, rf.body.code]).toEqual([401, 'KIOSK_REVOKED']);
    expect(rf.text).not.toMatch(TOKEN_KEYS);
    expect([(await refresh()).body.code]).toEqual(['KIOSK_REVOKED']);

    // Иная причина отзыва сессии планшета (выход, срок) — 401 SESSION_REVOKED и от AuthGuard, и от /auth/refresh.
    const other = await t.enroll({ name: 'Планшет у витрины' });
    expect((await t.call('get', '/cart', other)).status).toBe(200);
    await t.q(`UPDATE sessions SET revoked_at = now(), revoke_reason = 'logout' WHERE id = $1`, [other.sessionId]);
    t.clearAuthCache();
    const g2 = await t.call('get', '/cart', other);
    expect([g2.status, g2.body.code]).toEqual([401, 'SESSION_REVOKED']);
    const r2 = await t.call('post', '/auth/refresh', undefined, {
      headers: { 'X-Device-Id': other.deviceKey },
      body: { refreshToken: other.refreshToken },
    });
    expect([r2.status, r2.body.code]).toEqual([401, 'SESSION_REVOKED']);
    // Планшет по-прежнему «активен» (отключения не было) — отказ только из-за сессии.
    expect(await t.q(`SELECT status::text AS status FROM store_tablets WHERE id = $1`, [other.tabletId])).toEqual([
      { status: 'active' },
    ]);
    // Паритет: сотрудник с отозванной сессией — SESSION_REVOKED, как прежде.
    const cashier = await t.subject('cashier');
    await t.q(`UPDATE sessions SET revoked_at = now(), revoke_reason = 'logout' WHERE id = $1`, [cashier.sessionId]);
    t.clearAuthCache();
    expect((await t.call('get', '/cart', cashier)).body.code).toBe('SESSION_REVOKED');
  });

  it('T-SEC-073 no PII or prices in tablet responses and idempotency_keys rows: заявка на карточку с соглашением, отказы шага 2, ONEC_REJECTED', async () => {
    const tab: Tablet = await t.enroll({ name: 'Планшет у стойки' });
    const phone = buyerPhone('07');
    const cardName = 'Асанова Айгуль (тест)';
    // Вид цены соглашения карточки с заметными ценами (их не должно быть ни в одном ответе планшету).
    const cardPrices: Record<string, string> = { [v[0].variantId]: '777.13', [v[1].variantId]: '555.17' };
    const pl = await t.q<{ id: string }>(
      `INSERT INTO price_lists (onec_ref, synced_at, source_hash, name, sort_order)
       VALUES ($1::uuid, now(), 'kiosk-e2e', 'Соглашение карточки (тест)', 70) RETURNING id`,
      [randomUUID()],
    );
    for (const [variantId, price] of Object.entries(cardPrices)) {
      await t.q(
        `INSERT INTO prices (variant_id, price_list_id, packaging_id, price, synced_at, source_hash)
         VALUES ($1::uuid, $2::uuid, NULL, $3::numeric, now(), 'kiosk-e2e')`,
        [variantId, pl[0].id, price],
      );
    }
    const agreementRef = randomUUID();
    const customer = await t.q<{ id: string; onec_ref: string }>(
      `INSERT INTO customers (onec_ref, onec_code, source, name, customer_type, primary_phone_e164, phones_norm,
                              synced_at, source_hash, onec_status, discount_percent, default_price_list_id,
                              onec_agreement_ref)
       VALUES ($1::uuid, $2, 'onec', $3, 'individual', $4, ARRAY[$4::text], now(), 'kiosk-e2e', 'n_a', 3.00, $5::uuid,
               $6::uuid)
       RETURNING id, onec_ref::text AS onec_ref`,
      [randomUUID(), `T-${randomUUID().slice(0, 8)}`, cardName, phone, pl[0].id, agreementRef],
    );
    const forbidden = [
      phone,
      phone.slice(1),
      phone.slice(-9),
      cardName,
      'Асанова',
      customer[0].id,
      customer[0].onec_ref,
      agreementRef,
      pl[0].id,
      ...Object.values(cardPrices),
    ];
    const seen: { label: string; r: Res }[] = [];
    const keep = (label: string, r: Res) => {
      seen.push({ label, r });
      return r;
    };

    // Каталог и корзина — обычная цена, без клиента.
    keep('GET /me', await t.call('get', '/me', tab));
    keep('GET /catalog/products/{id}', await t.call('get', `/catalog/products/${v[0].productId}`, tab));
    keep('PUT /cart/items (1)', await t.putItem(tab, v[0], '2'));
    keep('PUT /cart/items (2)', await t.putItem(tab, v[1], '1'));
    const cart = keep('GET /cart', await t.call('get', '/cart', tab));
    expect(cart.body.customer ?? null).toBeNull();

    // Отказ шага 2 — нехватка остатка: conflicts[] только variantId, kind, stockLevel.
    const otp1 = keep('POST /kiosk/order-otp', await t.orderOtp(tab, phone));
    expect(otp1.status, JSON.stringify(otp1.body)).toBe(202);
    await t.q(
      `UPDATE stock_balances SET quantity = 1, reserved = 0, available_onec = 1 WHERE variant_id = $1 AND warehouse_id = $2`,
      [v[0].variantId, tab.warehouseId],
    );
    const p1 = keep('POST /cart/checkout-preview (1)', await t.preview(tab));
    const attempt = {
      challengeId: String(otp1.body.challengeId),
      code: OTP_TEST_CODE,
      cartId: String(p1.body.cartId),
      cartRowVersion: Number(p1.body.cartRowVersion),
      previewToken: String(p1.body.previewToken),
    };
    const shortKey = randomUUID();
    const short = keep('POST /kiosk/orders (остаток)', await t.submit(tab, attempt, shortKey));
    expect([short.status, short.body.code], JSON.stringify(short.body)).toEqual([422, 'STOCK_INSUFFICIENT']);
    expect((short.body.conflicts as Record<string, unknown>[]).length).toBeGreaterThan(0);
    for (const c of short.body.conflicts as Record<string, unknown>[]) {
      expect(Object.keys(c).filter((k) => !(KIOSK_CONFLICT_FIELDS as readonly string[]).includes(k))).toEqual([]);
    }
    await t.q(
      `UPDATE stock_balances SET quantity = 100, available_onec = 100 WHERE variant_id = $1 AND warehouse_id = $2`,
      [v[0].variantId, tab.warehouseId],
    );

    // ONEC_REJECTED (/check 1С по карточке отказал, причина — о долге): нейтральный текст, без `onec`. Корзина
    // меняется перед попыткой — новый `rowVersion`, ответ `/check` прошлой попытки (кэш 60 с) не переиспользуется.
    keep('PUT /cart/items (3)', await t.putItem(tab, v[1], '2'));
    const p2 = keep('POST /cart/checkout-preview (2)', await t.preview(tab));
    const spy = vi
      .spyOn(t.onec(), 'checkCart')
      .mockRejectedValueOnce(
        new OnecError('checkCart', 422, 'POS_E_VALIDATION', 'Превышен лимит долга клиента (тест)'),
      );
    const rejectedKey = randomUUID();
    const rejected = keep(
      'POST /kiosk/orders (ONEC_REJECTED)',
      await t.submit(
        tab,
        { ...attempt, cartRowVersion: Number(p2.body.cartRowVersion), previewToken: String(p2.body.previewToken) },
        rejectedKey,
      ),
    );
    const checkCalls = spy.mock.calls.length;
    spy.mockRestore();
    expect(checkCalls).toBeGreaterThan(0);
    expect([rejected.status, rejected.body.code], JSON.stringify(rejected.body)).toEqual([422, 'ONEC_REJECTED']);
    expect(rejected.body.detail).toBe(KIOSK_ONEC_REJECTED_DETAIL);
    expect(rejected.body).not.toHaveProperty('onec');
    expect(rejected.text).not.toContain('долга');

    // Заявка на карточку: 201 только с номером; восстановление по ключу — тот же номер.
    keep('PUT /cart/items (4)', await t.putItem(tab, v[1], '1'));
    const p3 = keep('POST /cart/checkout-preview (3)', await t.preview(tab));
    const okKey = randomUUID();
    const ok = keep(
      'POST /kiosk/orders (201)',
      await t.submit(
        tab,
        { ...attempt, cartRowVersion: Number(p3.body.cartRowVersion), previewToken: String(p3.body.previewToken) },
        okKey,
      ),
    );
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    expect(Object.keys(ok.body)).toEqual(['publicNumber']);
    keep('GET /kiosk/orders', await t.call('get', `/kiosk/orders?idempotencyKey=${okKey}`, tab));
    keep('GET /cart (после заявки)', await t.call('get', '/cart', tab));
    // Заявка действительно оформлена на карточку по цене соглашения (сервер), но планшет этого не видит.
    const order = await t.q<{ customer_id: string; total: string; receiver_phone_e164: string | null }>(
      `SELECT customer_id, total::text AS total, receiver_phone_e164 FROM orders WHERE public_number = $1`,
      [ok.body.publicNumber],
    );
    expect(order[0].customer_id).toBe(customer[0].id);
    const lines = await t.q<{ unit_price: string }>(
      `SELECT oi.unit_price::text AS unit_price FROM order_items oi JOIN orders o ON o.id = oi.order_id
        WHERE o.public_number = $1 ORDER BY oi.line_no`,
      [ok.body.publicNumber],
    );
    expect(lines.map((l) => l.unit_price)).toEqual(expect.arrayContaining(['777.13']));
    forbidden.push(order[0].total);
    const cartReset = await t.call('get', '/cart', tab);
    keep(
      'POST /kiosk/reset',
      await t.call('post', '/kiosk/reset', tab, { body: { cartId: cartReset.body.id }, idem: true }),
    );

    // Ни в одном ответе планшету — ни номера, ни ФИО, ни клиента, ни цен и суммы соглашения.
    const leaks: string[] = [];
    for (const { label, r } of seen) {
      expect(r.status, `${label}: ${r.text.slice(0, 300)}`).toBeLessThan(500);
      for (const f of forbidden) if (r.text.includes(f)) leaks.push(`${label}: «${f}»`);
      if (/\+?996\d{9}/.test(r.text)) leaks.push(`${label}: номер телефона`);
      if (TOKEN_KEYS.test(r.text)) leaks.push(`${label}: токен`);
    }
    expect(leaks).toEqual([]);

    // Сохранённые ответы под ключами идемпотентности планшета — только {publicNumber} или очищенный Problem.
    const stored = await t.q<{ key: string; response_status: number; response_body: Record<string, unknown> | null }>(
      `SELECT key::text AS key, response_status, response_body FROM idempotency_keys WHERE user_id = $1 ORDER BY created_at`,
      [tab.userId],
    );
    expect(stored.map((s) => s.key)).toEqual(expect.arrayContaining([shortKey, rejectedKey, okKey]));
    const byKey = new Map(stored.map((s) => [s.key, s]));
    expect(byKey.get(okKey)?.response_body).toEqual({ publicNumber: ok.body.publicNumber });
    expect(byKey.get(rejectedKey)?.response_body).toMatchObject({
      code: 'ONEC_REJECTED',
      detail: KIOSK_ONEC_REJECTED_DETAIL,
    });
    expect(byKey.get(rejectedKey)?.response_body).not.toHaveProperty('onec');
    expect(byKey.get(shortKey)?.response_body).toMatchObject({ code: 'STOCK_INSUFFICIENT' });
    for (const c of (byKey.get(shortKey)?.response_body?.conflicts ?? []) as Record<string, unknown>[]) {
      expect(Object.keys(c).filter((k) => !(KIOSK_CONFLICT_FIELDS as readonly string[]).includes(k))).toEqual([]);
    }
    const storedText = JSON.stringify(stored);
    expect(forbidden.filter((f) => storedText.includes(f))).toEqual([]);
    expect(storedText).not.toMatch(/\+?996\d{9}/);
    expect(storedText).not.toMatch(TOKEN_KEYS);
    expect(storedText).not.toContain('долга');
  });
});
