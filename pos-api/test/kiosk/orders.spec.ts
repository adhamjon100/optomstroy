import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import YAML from 'yaml';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { OTP_PROVIDER, type OtpProvider } from '../../src/auth/otp/otp.provider.js';
import { CartModule } from '../../src/cart/cart.module.js';
import { signPreviewToken } from '../../src/cart/preview-token.js';
import { FixedClock } from '../../src/common/auth/clock.js';
import { OtpHmacService } from '../../src/common/crypto/otp-hmac.service.js';
import type { OnecCallOptions, OnecJsonObject } from '../../src/integrations/onec/onec-gateway.js';
import { KIOSK_ACCESS_GUARD } from '../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import { KIOSK_ONEC_REJECTED_DETAIL } from '../../src/kiosk/common/kiosk-problem.sanitizer.js';
import { kioskNoticeSha256, NOTICE_CATALOG } from '../../src/kiosk/otp/notice-catalog.js';
import { NotificationCenterModule } from '../../src/notifications/center/notification-center.module.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { PaymentsModule } from '../../src/payments/payments.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import { PublicSettingsModule } from '../../src/settings/public-settings.module.js';
import { contractErrors } from '../cashier-foundation/support/onec-contract.js';
import { type PosActor, RETAIL_CUSTOMER_ID, type SaleableVariant } from '../support/pos-fixture.js';
import { type KioskTablet, KioskTestApp } from './support/kiosk-fixture.js';

/**
 * `POST /kiosk/orders` в три шага и `GET /kiosk/orders?idempotencyKey=` — заявка с планшета магазина (08 §4.25.2,
 * §4.25.3, §2.4 «Коды и отказы планшета магазина», §2.7; 09 §5.3; 10 KIOSK-011, KIOSK-013…KIOSK-018, KIOSK-022;
 * 11 SEC-141; P-002 §8.5; ADR-115; задача TAB-1-05) — **тестовые данные** стенда `kiosk-fixture` (embedded
 * PostgreSQL 17 со всеми миграциями, синтетический каталог, `ScriptedOnecGateway`; номера покупателей — вымышленные
 * `+996 555 002 xxx`, номера сотрудников стенда — `+996 77x xxx xxx`; коды из SMS — из `dev_outbox` поддельного
 * шлюза). Стенд — модули корзины, заказов, платежей, центра уведомлений, профиля (через него — `auth`), публичных
 * настроек и `kiosk`; прочие порты — заглушки. Время — `FixedClock` (окно повтора кода 60 с, срок предпросмотра 5 мин).
 * - T-KIOSK-013: верный код не создаёт ни токенов, ни `users`/`devices`/`sessions`/`customer_links`/`consents`;
 * - T-KIOSK-014: номер сотрудника — заявка как у покупателя, сессия сотрудника не открыта;
 * - T-KIOSK-015: назначения кода не смешиваются (код планшета во входе и код входа в заявке — `404`);
 * - T-KIOSK-016: код другого планшета и чужой корзины — `404` без попытки; `409`, `422`; тот же код в окне 60 с;
 * - T-KIOSK-019 / -021 / -022 / -038 / -035: клиент заявки по карточке, 1С молчит, цена карточки в outbox, «Мои заказы»;
 * - T-KIOSK-023: повтор ключа, `409 IDEMPOTENCY_IN_PROGRESS`, восстановление по ключу ≤ 15 мин, под ключом — номер;
 * - T-KIOSK-024 / -053: отказ 1С без `onec` и текста 1С; медленная 1С укладывается в бюджет;
 * - T-KIOSK-036 / -047: попытки кода учитываются всегда, 1С — только после верного кода, блокировок во время 1С нет;
 *   два запроса с одним кодом — одна заявка;
 * - T-KIOSK-041 / -043: `pd_notice_*`, канал, комментарий 1С по шаблону контракта, `createdByUserCode`, уведомления;
 * - T-KIOSK-058 / -059 / -062: конфликты без цены карточки, предпросмотр без итога, ORD-022 для планшета не действует.
 */
type Method = 'get' | 'post' | 'put' | 'delete';

interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
  readonly headers: Record<string, string>;
}

interface Attempt {
  readonly challengeId: string;
  readonly code: string;
  readonly cartId: string;
  readonly cartRowVersion: number;
  readonly previewToken: string;
}

interface OrderDb {
  id: string;
  status: string;
  customer_id: string;
  created_by_user_id: string;
  created_via: string;
  payment_method: string;
  delivery_method: string;
  receiver_kind: string;
  receiver_name: string | null;
  receiver_phone_e164: string | null;
  kiosk_customer_match: string | null;
  pd_notice_version: string | null;
  pd_notice_sha256: string | null;
  price_list_id: string;
  warehouse_id: string;
  total: string;
  customer_discount_percent: string | null;
  manual_discount_total: string;
  idempotency_key: string;
  cart_id: string;
  onec_sync_state: string;
}

const NOTICE = '2026-11-04';
const DEV_OUTBOX_SQL = fileURLToPath(new URL('../../db/migrations-dev/0001_dev_outbox.sql', import.meta.url));
const ONEC_CONTRACT = fileURLToPath(new URL('../../../contracts/onec/onec-http-service.v1.yaml', import.meta.url));
const PUBLIC_NUMBER = /^POS-\d{4}-\d{6}$/;
const TIMEOUT_MS = 1500;

let phoneSeq = 0;
/** Вымышленный мобильный номер КР `+996 555 002 xxx` (тестовые данные). */
function buyerPhone(): string {
  phoneSeq += 1;
  return `+996555002${String(100 + phoneSeq).padStart(3, '0')}`;
}

/** Другой код той же длины (неверный ввод). */
function wrong(code: string): string {
  return code.slice(0, 5) + String((Number(code[5]) + 1) % 10);
}

/** Отложенное обещание (порядок шагов параллельного запроса). */
function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

describe('kiosk: POST /kiosk/orders в три шага и GET /kiosk/orders?idempotencyKey= (KIOSK_MODE=true)', () => {
  const t = new KioskTestApp();
  const clock = new FixedClock(new Date());
  let v: SaleableVariant[];
  let w1: string;
  let defaultPl: string;
  let hmac: OtpHmacService;
  let cashier: PosActor;
  let senior: PosActor;
  let seller: PosActor;

  async function call(method: Method, path: string, a?: PosActor, body?: unknown, idem?: string): Promise<Res> {
    const r = t.req(method, path, a, idem ? { idem } : {});
    const res = await (body !== undefined ? r.send(body as object) : r);
    return {
      status: res.status,
      body: (res.body ?? {}) as Res['body'],
      headers: res.headers,
    };
  }

  async function putItem(tab: PosActor, x: SaleableVariant, value: string): Promise<void> {
    const c0 = await call('get', '/cart', tab);
    const r = await call('put', `/cart/items/${x.variantId}`, tab, {
      quantity: { value, unitId: x.unitId, packagingId: null },
      rowVersion: c0.body.rowVersion as number,
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
  }

  /** Предпросмотр планшета (08 §4.7.7): наличные, самовывоз, без синхронного `/check` (ORD-008). */
  async function preview(tab: PosActor): Promise<Res> {
    const c = await call('get', '/cart', tab);
    const r = await call('post', '/cart/checkout-preview', tab, {
      cartId: c.body.id as string,
      cartRowVersion: c.body.rowVersion as number,
      paymentMethod: 'cash',
      delivery: { method: 'pickup' },
      receiver: { kind: 'customer' },
      manualDiscountPercent: '0.00',
      syncCheckWithOnec: false,
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return r;
  }

  function provider(): OtpProvider {
    return t.app.get<OtpProvider>(OTP_PROVIDER, { strict: false });
  }

  /** Код из SMS (`dev_outbox` поддельного шлюза) — после фоновой отправки. */
  async function codeOf(challengeId: string): Promise<string> {
    await provider().drain();
    const r = await t.q<{ text: string }>(
      `SELECT d.text FROM dev_outbox d JOIN otp_challenges c ON c.sms_outbox_id = d.sms_outbox_id WHERE c.id = $1`,
      [challengeId],
    );
    const m = /(\d{6})/.exec(r[0]?.text ?? '');
    if (!m?.[1]) throw new Error(`код для ${challengeId} не найден в dev_outbox`);
    return m[1];
  }

  async function requestCode(tab: PosActor, phone: string): Promise<{ challengeId: string; code: string }> {
    const c = await call('get', '/cart', tab);
    const r = await call('post', '/kiosk/order-otp', tab, {
      phone,
      cartId: c.body.id as string,
      noticeVersion: NOTICE,
    });
    expect(r.status, JSON.stringify(r.body)).toBe(202);
    const challengeId = r.body.challengeId as string;
    return { challengeId, code: await codeOf(challengeId) };
  }

  /** Попытка по свежему предпросмотру с кодом `c`. */
  async function attemptOf(tab: PosActor, c: { challengeId: string; code: string }): Promise<Attempt> {
    const p = await preview(tab);
    return {
      challengeId: c.challengeId,
      code: c.code,
      cartId: p.body.cartId as string,
      cartRowVersion: p.body.cartRowVersion as number,
      previewToken: p.body.previewToken as string,
    };
  }

  /** Планшет (или переданный), корзина, код на номер и свежий предпросмотр — как SCR-52 перед «Отправить заявку». */
  async function ready(
    o: {
      readonly tab?: KioskTablet;
      readonly phone?: string;
      readonly items?: readonly (readonly [SaleableVariant, string])[];
      readonly name?: string;
    } = {},
  ): Promise<{ tab: KioskTablet; phone: string; attempt: Attempt }> {
    const tab = o.tab ?? (await t.tablet({ ...(o.name ? { name: o.name } : {}), warehouseId: w1 }));
    for (const [x, q] of o.items ?? [[v[0], '1'] as const]) await putItem(tab, x, q);
    const phone = o.phone ?? buyerPhone();
    const code = await requestCode(tab, phone);
    return { tab, phone, attempt: await attemptOf(tab, code) };
  }

  function submit(tab: PosActor, a: Attempt, key: string = randomUUID()): Promise<Res> {
    return call('post', '/kiosk/orders', tab, a, key);
  }

  async function orderOf(publicNumber: string): Promise<OrderDb> {
    const r = await t.q<OrderDb & Record<string, unknown>>(
      `SELECT o.id, o.status::text AS status, o.customer_id, o.created_by_user_id, o.created_via,
              o.payment_method::text AS payment_method, o.delivery_method::text AS delivery_method,
              o.receiver_kind::text AS receiver_kind, o.receiver_name, o.receiver_phone_e164, o.kiosk_customer_match,
              o.pd_notice_version, o.pd_notice_sha256, o.price_list_id, o.warehouse_id, o.total::text AS total,
              o.customer_discount_percent::text AS customer_discount_percent,
              o.manual_discount_total::text AS manual_discount_total, o.idempotency_key, o.cart_id,
              o.onec_sync_state::text AS onec_sync_state
         FROM orders o WHERE o.public_number = $1`,
      [publicNumber],
    );
    if (!r[0]) throw new Error(`заявка ${publicNumber} не найдена`);
    return r[0];
  }

  async function outboxOf(orderId: string) {
    return t.q<{ status: string; payload: Record<string, unknown>; requested_by_user_id: string | null }>(
      `SELECT status::text AS status, payload, requested_by_user_id FROM onec_outbox
        WHERE aggregate_type = 'order' AND aggregate_id = $1 AND operation = 'create'`,
      [orderId],
    );
  }

  async function challengeOf(id: string) {
    const r = await t.q<{ status: string; attempts: number; replayed_at: Date | null; verified_at: Date | null }>(
      `SELECT status::text AS status, attempts, replayed_at, verified_at FROM otp_challenges WHERE id = $1`,
      [id],
    );
    return r[0];
  }

  async function ordersOfTablet(tab: PosActor): Promise<number> {
    const r = await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM orders WHERE created_by_user_id = $1`, [
      tab.userId,
    ]);
    return r[0].n;
  }

  /** Карточка клиента из полной синхронизации 1С (`source=onec`, `onec_ref`, `synced_at`), номер — основной. */
  async function card(o: {
    readonly phone: string;
    readonly name?: string;
    readonly type?: 'individual' | 'entrepreneur' | 'legal';
    readonly priceListId?: string | null;
    readonly discountPercent?: string | null;
    readonly agreementRef?: string | null;
  }): Promise<string> {
    const r = await t.q<{ id: string }>(
      `INSERT INTO customers (onec_ref, onec_code, source, name, customer_type, primary_phone_e164, phones_norm,
                              synced_at, source_hash, onec_status, discount_percent, default_price_list_id,
                              onec_agreement_ref)
       VALUES ($1::uuid, $2, 'onec', $3, $4::customer_type, $5, ARRAY[$5::text], now(), 'test', 'n_a', $6::numeric,
               $7::uuid, $8::uuid)
       RETURNING id`,
      [
        randomUUID(),
        `T-${randomUUID().slice(0, 8)}`,
        o.name ?? 'Асанова Айгуль (тест)',
        o.type ?? 'individual',
        o.phone,
        o.discountPercent ?? null,
        o.priceListId ?? null,
        o.agreementRef ?? null,
      ],
    );
    return r[0].id;
  }

  async function onecRefOf(customerId: string): Promise<string> {
    return (await t.q<{ ref: string }>(`SELECT onec_ref::text AS ref FROM customers WHERE id = $1`, [customerId]))[0]
      .ref;
  }

  async function phoneOf(a: PosActor): Promise<string> {
    return (await t.q<{ p: string }>(`SELECT phone_e164 AS p FROM users WHERE id = $1`, [a.userId]))[0].p;
  }

  /** Подтверждённая привязка покупателя к карточке (как после SCR-06, 07 §5.21). */
  async function link(userId: string, customerId: string, phone: string): Promise<void> {
    await t.q(
      `INSERT INTO customer_links (user_id, customer_id, status, match_method, matched_phone_e164, confirmed_at)
       VALUES ($1::uuid, $2::uuid, 'confirmed', 'phone', $3, now())`,
      [userId, customerId, phone],
    );
  }

  /** Вид цены соглашения карточки (`visible_to_roles` — по умолчанию, роли kiosk там нет) с ценой на варианты. */
  async function cardPriceList(name: string, prices: readonly (readonly [SaleableVariant, string])[]): Promise<string> {
    const pl = await t.q<{ id: string }>(
      `INSERT INTO price_lists (onec_ref, synced_at, source_hash, name, sort_order)
       VALUES ($1::uuid, now(), 'kiosk-test', $2, 60) RETURNING id`,
      [randomUUID(), name],
    );
    for (const [x, price] of prices) await t.setPrice(x.variantId, price, pl[0].id);
    return pl[0].id;
  }

  /** Строка свободна от блокировок (другой сеанс берёт её `FOR UPDATE NOWAIT`). */
  async function lockFree(table: 'otp_challenges' | 'carts', id: string): Promise<boolean> {
    const c = await t.pool.connect();
    try {
      await c.query('BEGIN');
      await c.query(`SELECT 1 FROM ${table} WHERE id = $1 FOR UPDATE NOWAIT`, [id]);
      return true;
    } catch (e) {
      if ((e as { code?: string }).code === '55P03') return false;
      throw e;
    } finally {
      await c.query('ROLLBACK').catch(() => undefined);
      c.release();
    }
  }

  /**
   * `dev_outbox` (07 §5.63) — только в dev/test-схеме: dev-миграция применяется к БД стенда в сеансе с
   * `app.env=test` (как test/kiosk/order-otp.spec.ts; файл миграции не меняется). Без неё FakeSmsGateway — CONFIG_ERROR.
   */
  async function createDevOutbox(): Promise<void> {
    const c = await t.pool.connect();
    try {
      await c.query(`SELECT set_config('app.env', 'test', false)`);
      await c.query(readFileSync(DEV_OUTBOX_SQL, 'utf8'));
    } finally {
      await c.query('RESET app.env').catch(() => undefined);
      c.release();
    }
  }

  /** Ответ поиска 1С (контракт `CustomerCandidate`, фикстура customers-search.200) с заданными Ref и номером. */
  function onecAnswers(phone: string, refs: readonly string[]) {
    const [base] = t.onec.fixture('customers-search.200').body as OnecJsonObject[];
    return vi.spyOn(t.onec, 'findCustomersByPhone').mockResolvedValue({
      status: 200,
      body: refs.map((ref) => ({ ...base, ref, code: `K-${ref.slice(0, 8)}`, contractorRef: null, phone })),
    });
  }

  /** 1С «молчит» при поиске: ответа нет до сигнала таймаута; `entered` — запрос дошёл до 1С. */
  function onecHangs(): { entered: Promise<void> } {
    const e = deferred();
    vi.spyOn(t.onec, 'findCustomersByPhone').mockImplementation(
      (_phone: string, opts?: OnecCallOptions) =>
        new Promise<never>((_resolve, reject) => {
          e.resolve();
          const signal = opts?.signal;
          if (signal) signal.addEventListener('abort', () => reject(signal.reason as Error), { once: true });
          else reject(new Error('тест: вызов 1С без сигнала таймаута'));
        }),
    );
    return { entered: e.promise };
  }

  beforeAll(async () => {
    await t.start({
      env: {
        QR_PROVIDER: 'none',
        KIOSK_MODE: 'true',
        OTP_GLOBAL_PER_MIN: '100000',
        ONEC_SYNC_CHECK_TIMEOUT_MS: String(TIMEOUT_MS),
      },
      skuCount: 40,
      modules: [
        CartModule,
        OrdersModule,
        PaymentsModule,
        NotificationCenterModule,
        ProfileModule,
        PublicSettingsModule,
        KioskModule,
      ],
      guards: [KIOSK_ACCESS_GUARD],
      fakePorts: true,
      jobs: false,
      clock,
    });
    await createDevOutbox();
    hmac = t.app.get(OtpHmacService, { strict: false });
    w1 = await t.defaultWarehouseId();
    defaultPl = await t.defaultPriceListId();
    v = await t.saleableVariants(14, { warehouseId: w1 });
    for (const x of v) await t.setPrice(x.variantId, '100.00');
    // Остатки покупателю — числом: конфликт нехватки до очистки содержит `requested`/`available` (их и убирают).
    await t.setSetting('customer_stock_display', '"quantity"');
    cashier = await t.actor({ role: 'cashier' });
    senior = await t.actor({ role: 'senior_seller' });
    seller = await t.actor({ role: 'seller' });
  });

  afterAll(async () => {
    await t.stop();
  });

  beforeEach(() => {
    t.onec.reset();
    t.onec.useFixture('findCustomersByPhone', 'customers-search.empty.200');
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('T-KIOSK-013 no tokens, no users/devices/sessions/customer_links/consents rows', async () => {
    const tab = await t.tablet({ warehouseId: w1 });
    const counts = async () =>
      (
        await t.q<Record<string, number>>(
          `SELECT (SELECT count(*) FROM users)::int AS users, (SELECT count(*) FROM devices)::int AS devices,
                  (SELECT count(*) FROM sessions)::int AS sessions,
                  (SELECT count(*) FROM customer_links)::int AS links,
                  (SELECT count(*) FROM consents)::int AS consents`,
        )
      )[0];
    const before = await counts();
    const { attempt } = await ready({ tab });
    const r = await submit(tab, attempt);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    // Ответ — только номер (KioskOrderAccepted): ни токенов, ни статуса, ни сумм, ни клиента.
    expect(Object.keys(r.body)).toEqual(['publicNumber']);
    expect(r.body.publicNumber).toMatch(PUBLIC_NUMBER);
    expect(r.headers['cache-control']).toBe('no-store');
    expect(await counts()).toEqual(before);
    const ch = await t.q<{ registration_token_hash: unknown; issued_jti: string | null; user_id: string | null }>(
      `SELECT registration_token_hash, issued_jti, user_id FROM otp_challenges WHERE id = $1`,
      [attempt.challengeId],
    );
    expect(ch[0]).toEqual({ registration_token_hash: null, issued_jti: null, user_id: null });
  });

  it('T-KIOSK-014 staff phone → buyer order, no staff session', async () => {
    const staffPhone = await phoneOf(seller);
    const sessions = async () =>
      (await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM sessions WHERE user_id = $1`, [seller.userId]))[0].n;
    const before = await sessions();
    const { tab, attempt } = await ready({ phone: staffPhone });
    const r = await submit(tab, attempt);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(Object.keys(r.body)).toEqual(['publicNumber']);
    const o = await orderOf(r.body.publicNumber as string);
    expect(o).toMatchObject({
      created_by_user_id: tab.userId,
      created_via: 'kiosk',
      customer_id: RETAIL_CUSTOMER_ID,
      kiosk_customer_match: 'none',
      receiver_kind: 'customer',
      receiver_name: null,
      receiver_phone_e164: staffPhone,
    });
    expect(await sessions()).toBe(before);
  });

  it('T-KIOSK-015 kiosk code in /auth/otp/verify 404; login code in /kiosk/orders 404', async () => {
    const phone = buyerPhone();
    const tab = await t.tablet({ warehouseId: w1 });
    const sessionsBefore = (await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM sessions`))[0].n;
    // Код входа на тот же номер (назначение login_or_register) — с устройства планшета.
    const login = await t
      .req('post', '/auth/otp/request')
      .set('X-Device-Id', tab.deviceKey)
      .set('X-App-Version', '1.4.2')
      .set('X-Platform', 'android')
      .send({ phone, purpose: 'login_or_register', locale: 'ru' });
    expect(login.status, JSON.stringify(login.body)).toBe(202);
    const loginId = (login.body as { challengeId: string }).challengeId;
    const loginCode = await codeOf(loginId);
    const { attempt } = await ready({ tab, phone });

    // Код планшета во входе — назначение не совпало: 404, сессии нет, попытка не потрачена.
    const verify = await t
      .req('post', '/auth/otp/verify')
      .set('X-Device-Id', randomUUID())
      .set('X-App-Version', '1.4.2')
      .set('X-Platform', 'android')
      .send({
        challengeId: attempt.challengeId,
        code: attempt.code,
        device: { name: 'Тестовый телефон', platform: 'android', appVersion: '1.4.2' },
      });
    expect(verify.status, JSON.stringify(verify.body)).toBe(404);
    expect((verify.body as { code: string }).code).toBe('NOT_FOUND');
    expect(await challengeOf(attempt.challengeId)).toMatchObject({ status: 'sent', attempts: 0 });

    // Код входа в заявке — 404 (шаг (2): назначение), попытка кода входа не потрачена.
    const asLogin = await submit(tab, { ...attempt, challengeId: loginId, code: loginCode });
    expect(asLogin.status, JSON.stringify(asLogin.body)).toBe(404);
    expect(asLogin.body.code).toBe('NOT_FOUND');
    expect(await challengeOf(loginId)).toMatchObject({ status: 'sent', attempts: 0 });
    expect((await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM sessions`))[0].n).toBe(sessionsBefore);

    // Код планшета по-прежнему годен для заявки.
    const ok = await submit(tab, attempt);
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
  });

  it('T-KIOSK-016 other tablet/cart 404 without attempt, 409, 422, same code within 60 s, keys', async () => {
    const statuses: { code: string | undefined; status: number }[] = [];
    const keys = new Set<string>();
    const send = async (tab: PosActor, a: Attempt): Promise<Res> => {
      const key = randomUUID();
      keys.add(key);
      const r = await submit(tab, a, key);
      statuses.push({ code: r.body.code as string | undefined, status: r.status });
      return r;
    };
    const x = v[5];
    const { tab: t1, attempt } = await ready({ items: [[x, '1']] });
    const t2 = await t.tablet({ warehouseId: w1 });
    await putItem(t2, v[1], '1');
    const p2 = await preview(t2);

    // Код T1 с планшета T2 — 404, попытка не учтена, сессия T2 не завершена.
    const foreign = await send(t2, {
      ...attempt,
      cartId: p2.body.cartId as string,
      cartRowVersion: p2.body.cartRowVersion as number,
      previewToken: p2.body.previewToken as string,
    });
    expect(foreign.status, JSON.stringify(foreign.body)).toBe(404);
    expect(foreign.body.code).toBe('NOT_FOUND');
    expect(await challengeOf(attempt.challengeId)).toMatchObject({ status: 'sent', attempts: 0 });
    expect((await call('get', '/cart', t2)).status).toBe(200);

    // Код T1 с другим cartId (токен предпросмотра на этот cartId подписан сервером) — 404 по полю cart_id кода.
    const otherCart = randomUUID();
    const token = signPreviewToken(hmac, {
      cartId: otherCart,
      cartRowVersion: 1,
      total: '100.00',
      paymentMethod: 'cash',
      validUntil: new Date(clock.now().getTime() + 60_000).toISOString(),
      onecCheckAt: null,
      onecResult: 'unavailable',
    });
    const alien = await send(t1, { ...attempt, cartId: otherCart, cartRowVersion: 1, previewToken: token });
    expect(alien.status, JSON.stringify(alien.body)).toBe(404);
    expect(await challengeOf(attempt.challengeId)).toMatchObject({ status: 'sent', attempts: 0 });

    // Неверный код — 422 OTP_INVALID, попытка учтена.
    const bad = await send(t1, { ...attempt, code: wrong(attempt.code) });
    expect(bad.status).toBe(422);
    expect(bad.body).toMatchObject({ code: 'OTP_INVALID', attemptsLeft: 4 });
    expect(await challengeOf(attempt.challengeId)).toMatchObject({ status: 'sent', attempts: 1 });

    // Корзина изменилась после предпросмотра — 409 VERSION_CONFLICT без current; код проверен, не погашен.
    await putItem(t1, v[2], '1');
    const conflict = await send(t1, attempt);
    expect(conflict.status, JSON.stringify(conflict.body)).toBe(409);
    expect(conflict.body.code).toBe('VERSION_CONFLICT');
    expect(conflict.body).not.toHaveProperty('current');
    expect(await challengeOf(attempt.challengeId)).toMatchObject({
      status: 'verified',
      attempts: 2,
      replayed_at: null,
    });

    // Нехватка остатка — 422 STOCK_INSUFFICIENT, conflicts[] только variantId, kind, stockLevel.
    await putItem(t1, x, '3');
    await t.setStock(x.variantId, '1', w1);
    const short = await send(t1, await attemptOf(t1, attempt));
    expect(short.status, JSON.stringify(short.body)).toBe(422);
    expect(short.body.code).toBe('STOCK_INSUFFICIENT');
    expect(short.body.conflicts).toEqual([
      { variantId: x.variantId, kind: 'stock_insufficient', stockLevel: expect.any(String) },
    ]);

    // Исправить корзину → новый предпросмотр, новый ключ, тот же код (окно 60 с после первого верного ввода).
    await putItem(t1, x, '1');
    clock.advance(30_000);
    const ok = await send(t1, await attemptOf(t1, attempt));
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    expect(await challengeOf(attempt.challengeId)).toMatchObject({ status: 'verified' });
    expect((await challengeOf(attempt.challengeId)).replayed_at).not.toBeNull();

    // Позже окна 60 с тот же код — 422 OTP_EXPIRED (другой планшет: отказ корзины, затем 61 с).
    const late = await ready({ items: [[v[3], '1']] });
    await putItem(late.tab, v[4], '1');
    const stale = await send(late.tab, late.attempt);
    expect(stale.status).toBe(409);
    clock.advance(61_000);
    const expired = await send(late.tab, await attemptOf(late.tab, late.attempt));
    expect(expired.status, JSON.stringify(expired.body)).toBe(422);
    expect(expired.body.code).toBe('OTP_EXPIRED');
    expect(await ordersOfTablet(late.tab)).toBe(0);

    // У каждой попытки свой ключ; IDEMPOTENCY_KEY_REUSED и DEVICE_MISMATCH не возникали.
    expect(keys.size).toBe(statuses.length);
    expect(statuses.map((s) => s.code)).not.toContain('IDEMPOTENCY_KEY_REUSED');
    expect(statuses.map((s) => s.code)).not.toContain('DEVICE_MISMATCH');
    expect(statuses.map((s) => s.status)).not.toContain(500);
  });

  it('T-KIOSK-016 body and access: forbidden fields 400 (prices — price.override_attempt), staff and buyer 403', async () => {
    const { tab, attempt } = await ready();
    for (const extra of [{ customerId: RETAIL_CUSTOMER_ID }, { paymentMethod: 'cash' }, { noticeVersion: NOTICE }]) {
      const r = await submit(tab, { ...attempt, ...extra });
      expect(r.status, JSON.stringify(r.body)).toBe(400);
      expect(r.body.errors[0]).toMatchObject({ field: Object.keys(extra)[0], rule: 'forbidden_field' });
    }
    const priced = await submit(tab, { ...attempt, total: '1.00' } as unknown as Attempt);
    expect(priced.status).toBe(400);
    expect(priced.body.errors[0]).toMatchObject({ field: 'total', rule: 'forbidden_field' });
    const audit = (await t.auditRows('price.override_attempt')).filter((a) => a.actor_user_id === tab.userId);
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({ result: 'denied', after: { fields: ['total'], route: 'POST /kiosk/orders' } });
    const badCode = await submit(tab, { ...attempt, code: '12345' });
    expect(badCode.status).toBe(400);
    expect(badCode.body.errors[0]).toMatchObject({ field: 'code', rule: 'otp_format' });
    const noKey = await t.req('post', '/kiosk/orders', tab).send(attempt);
    expect(noKey.status).toBe(400);
    expect((noKey.body as { errors: { rule: string }[] }).errors[0].rule).toBe('idempotency_key_required');
    const buyer = await t.actor({ role: 'customer' });
    for (const a of [seller, buyer]) {
      expect((await submit(a, attempt)).status).toBe(403);
      expect((await call('get', `/kiosk/orders?idempotencyKey=${randomUUID()}`, a)).status).toBe(403);
    }
    // Ни одна из этих попыток не тратила код.
    expect(await challengeOf(attempt.challengeId)).toMatchObject({ status: 'sent', attempts: 0 });
  });

  it('T-KIOSK-019 order on the card, customer.ref in outbox', async () => {
    const phone = buyerPhone();
    const cardId = await card({ phone, name: 'Токтогулов Бакыт (тест)' });
    const ref = await onecRefOf(cardId);
    const spy = onecAnswers(phone, [ref]);
    const { tab, attempt } = await ready({ phone });
    const r = await submit(tab, attempt);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(spy).toHaveBeenCalledTimes(1);
    const o = await orderOf(r.body.publicNumber as string);
    expect(o).toMatchObject({ customer_id: cardId, kiosk_customer_match: 'single', receiver_phone_e164: phone });
    const [x] = await outboxOf(o.id);
    expect((x.payload.customer as Record<string, unknown>).ref).toBe(ref);
    expect(JSON.stringify(r.body)).not.toContain(cardId);
  });

  it('T-KIOSK-021 order submitting, outbox retries', async () => {
    const phone = buyerPhone();
    const cardId = await card({ phone });
    const { tab, attempt } = await ready({ phone });
    onecHangs();
    t.onec.always('checkCart', { transport: true });
    const r = await submit(tab, attempt);
    // 1С не ответила ни на поиск, ни на /check: решение по реплике, 202, заявка ждёт outbox.
    expect(r.status, JSON.stringify(r.body)).toBe(202);
    expect(Object.keys(r.body)).toEqual(['publicNumber']);
    const o = await orderOf(r.body.publicNumber as string);
    expect(o).toMatchObject({ status: 'submitting', onec_sync_state: 'pending', customer_id: cardId });
    expect(o.kiosk_customer_match).toBe('single');
    const out = await outboxOf(o.id);
    expect(out).toHaveLength(1);
    expect(out[0]).toMatchObject({ status: 'pending', requested_by_user_id: tab.userId });
    expect(t.logs.text).not.toContain(phone);
  });

  it('T-KIOSK-022 priceListRef/agreementRef in the outbox order/create, tablet cart untouched', async () => {
    const x = v[6];
    const y = v[7];
    const pl = await cardPriceList('Договорная (тест 022)', [
      [x, '80.00'],
      [y, '80.00'],
    ]);
    const agreement = randomUUID();
    const phone = buyerPhone();
    const cardId = await card({ phone, priceListId: pl, discountPercent: '5.00', agreementRef: agreement });
    const prepared = await ready({
      phone,
      items: [
        [x, '2'],
        [y, '1'],
      ],
    });
    const tab = prepared.tab;
    // Предпросмотр планшета — по обычной цене (3 × 100.00); его токен — в попытку.
    const p = await preview(tab);
    expect((p.body.total as { amount: string }).amount).toBe('300.00');
    const attempt: Attempt = {
      ...prepared.attempt,
      cartRowVersion: p.body.cartRowVersion as number,
      previewToken: p.body.previewToken as string,
    };
    const calls0 = t.onec.callsOf('checkCart').length;
    const r = await submit(tab, attempt);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(Object.keys(r.body)).toEqual(['publicNumber']);
    const o = await orderOf(r.body.publicNumber as string);
    // Строки — по виду цены карточки со скидкой клиента 1С: 3 × 80.00 − 5 % = 228.00 (≠ итогу предпросмотра 300.00).
    expect(o).toMatchObject({
      customer_id: cardId,
      price_list_id: pl,
      total: '228.00',
      customer_discount_percent: '5.00',
      manual_discount_total: '0.00',
    });
    const items = await t.q<{ unit_price: string }>(
      `SELECT unit_price::text AS unit_price FROM order_items WHERE order_id = $1 ORDER BY line_no`,
      [o.id],
    );
    expect(items.map((i) => i.unit_price)).toEqual(['80.00', '80.00']);
    // /check 1С — с customerRef и priceListRef карточки, без agreementRef (Q-345).
    const checks = t.onec.callsOf('checkCart').slice(calls0);
    expect(checks).toHaveLength(1);
    const plRef = (await t.q<{ ref: string }>(`SELECT onec_ref::text AS ref FROM price_lists WHERE id = $1`, [pl]))[0]
      .ref;
    expect(checks[0][0]).toMatchObject({ customerRef: await onecRefOf(cardId), priceListRef: plRef });
    expect(checks[0][0]).not.toHaveProperty('agreementRef');
    // Задача outbox order/create — с priceListRef и agreementRef карточки (ADR-115 п. 5).
    const [job] = await outboxOf(o.id);
    expect(job.payload.priceListRef).toBe(plRef);
    expect(job.payload.customer).toMatchObject({ ref: await onecRefOf(cardId), agreementRef: agreement });
    // Корзина планшета после заявки — новая, без клиента и с обычным видом цены.
    const after = await call('get', '/cart', tab);
    expect(after.body).toMatchObject({ customer: null, priceListId: defaultPl });
    expect(after.body.id).not.toBe(attempt.cartId);
    for (const leak of [cardId, pl, '80.00', '228.00']) expect(JSON.stringify(after.body)).not.toContain(leak);
  });

  it('T-KIOSK-023 same key replay, GET by key ≤ 15 min, 409 IDEMPOTENCY_IN_PROGRESS, stored body only publicNumber', async () => {
    const { tab, attempt } = await ready();
    const key = randomUUID();
    const entered = deferred();
    const release = deferred();
    vi.spyOn(t.onec, 'findCustomersByPhone').mockImplementation(async () => {
      entered.resolve();
      await release.promise;
      return { status: 200, body: [] };
    });
    const first = submit(tab, attempt, key);
    await entered.promise;
    // Пока первый запрос ждёт 1С: тот же ключ — 409 IDEMPOTENCY_IN_PROGRESS; восстановление по ключу — 404.
    const parallel = await submit(tab, attempt, key);
    expect(parallel.status, JSON.stringify(parallel.body)).toBe(409);
    expect(parallel.body).toMatchObject({ code: 'IDEMPOTENCY_IN_PROGRESS', retryAfter: 2 });
    expect(parallel.headers['retry-after']).toBe('2');
    expect((await call('get', `/kiosk/orders?idempotencyKey=${key}`, tab)).status).toBe(404);
    release.resolve();
    const done = await first;
    expect(done.status, JSON.stringify(done.body)).toBe(201);
    const publicNumber = done.body.publicNumber as string;

    // Повтор той же попытки тем же ключом — тот же номер из хранилища ключа.
    const replay = await submit(tab, attempt, key);
    expect(replay.status).toBe(201);
    expect(replay.body).toEqual({ publicNumber });
    expect(replay.headers['idempotent-replayed']).toBe('true');
    const stored = await t.q<{ response_status: number; response_body: unknown }>(
      `SELECT response_status, response_body FROM idempotency_keys WHERE key = $1 AND user_id = $2`,
      [key, tab.userId],
    );
    expect(stored).toEqual([{ response_status: 201, response_body: { publicNumber } }]);

    // Восстановление по ключу: только номер; другой планшет, неверный и отсутствующий ключ — нет.
    const found = await call('get', `/kiosk/orders?idempotencyKey=${key}`, tab);
    expect(found.status, JSON.stringify(found.body)).toBe(200);
    expect(found.body).toEqual({ publicNumber });
    expect(found.headers['cache-control']).toBe('no-store');
    const other = await t.tablet({ warehouseId: w1 });
    expect((await call('get', `/kiosk/orders?idempotencyKey=${key}`, other)).status).toBe(404);
    const noParam = await call('get', '/kiosk/orders', tab);
    expect(noParam.status).toBe(400);
    expect(noParam.body.errors[0]).toMatchObject({ field: 'idempotencyKey', rule: 'required' });
    expect((await call('get', '/kiosk/orders?idempotencyKey=not-a-uuid', tab)).status).toBe(400);
    // Старше 15 мин — 404.
    await t.q(`UPDATE orders SET created_at = now() - interval '16 minutes' WHERE public_number = $1`, [publicNumber]);
    expect((await call('get', `/kiosk/orders?idempotencyKey=${key}`, tab)).status).toBe(404);
  });

  it('T-KIOSK-024 ONEC_REJECTED without onec.message', async () => {
    const { tab, attempt } = await ready();
    t.onec.script('checkCart', {
      error: 422,
      code: 'POS_E_VALIDATION',
      message: 'Превышен лимит долга клиента (тест)',
    });
    const key = randomUUID();
    const r = await submit(tab, attempt, key);
    expect(r.status, JSON.stringify(r.body)).toBe(422);
    expect(r.body.code).toBe('ONEC_REJECTED');
    expect(r.body.detail).toBe(KIOSK_ONEC_REJECTED_DETAIL);
    expect(r.body).not.toHaveProperty('onec');
    expect(JSON.stringify(r.body)).not.toContain('долга');
    // Под ключом — тот же очищенный Problem; код не погашен (после исправления годен в окне повтора).
    const stored = await t.q<{ response_body: Record<string, unknown> }>(
      `SELECT response_body FROM idempotency_keys WHERE key = $1 AND user_id = $2`,
      [key, tab.userId],
    );
    expect(stored[0].response_body).toMatchObject({ code: 'ONEC_REJECTED', detail: KIOSK_ONEC_REJECTED_DETAIL });
    expect(stored[0].response_body).not.toHaveProperty('onec');
    expect(await challengeOf(attempt.challengeId)).toMatchObject({ status: 'verified', replayed_at: null });
    expect(await ordersOfTablet(tab)).toBe(0);
  });

  it('T-KIOSK-035 order on confirmed card visible in «Мои заказы»', async () => {
    const customer1 = await t.actor({ role: 'customer' });
    const phone = await phoneOf(customer1);
    const cardId = await card({ phone, name: 'Покупатель с привязкой (тест)' });
    await link(customer1.userId, cardId, phone);
    const { tab, attempt } = await ready({ phone });
    const r = await submit(tab, attempt);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const publicNumber = r.body.publicNumber as string;
    const o = await orderOf(publicNumber);
    expect(o).toMatchObject({ customer_id: cardId, kiosk_customer_match: 'single' });
    // «Мои заказы» покупателя на телефоне: заявка с планшета на его подтверждённую карточку видна.
    const list = await call('get', '/orders', customer1);
    expect(list.status, JSON.stringify(list.body)).toBe(200);
    expect((list.body.items as { publicNumber: string }[]).map((i) => i.publicNumber)).toContain(publicNumber);
    const one = await call('get', `/orders/${o.id}`, customer1);
    expect(one.status, JSON.stringify(one.body)).toBe(200);
    expect(one.body).toMatchObject({ publicNumber, createdVia: 'kiosk' });
  });

  it('T-KIOSK-036 attempts counted even on rollback, no 1C call on wrong code, no locks while 1C hangs', async () => {
    const { tab, attempt } = await ready();
    const search0 = t.onec.callsOf('findCustomersByPhone').length;
    const check0 = t.onec.callsOf('checkCart').length;
    const left: number[] = [];
    for (let i = 0; i < 5; i++) {
      const r = await submit(tab, { ...attempt, code: wrong(attempt.code) });
      expect(r.status, JSON.stringify(r.body)).toBe(422);
      expect(r.body.code).toBe('OTP_INVALID');
      left.push(r.body.attemptsLeft as number);
      // Ошибка — после COMMIT: попытка сохранена.
      expect((await challengeOf(attempt.challengeId)).attempts).toBe(i + 1);
    }
    expect(left).toEqual([4, 3, 2, 1, 0]);
    const locked = await submit(tab, attempt);
    expect(locked.status, JSON.stringify(locked.body)).toBe(423);
    expect(locked.body.code).toBe('OTP_LOCKED');
    expect(await challengeOf(attempt.challengeId)).toMatchObject({ status: 'locked', attempts: 5 });
    // Перебор кода не вызывает 1С.
    expect(t.onec.callsOf('findCustomersByPhone').length).toBe(search0);
    expect(t.onec.callsOf('checkCart').length).toBe(check0);
    const failed = await t.auditRows('auth.otp.failed', attempt.challengeId);
    expect(failed).toHaveLength(4);
    expect(failed[0].after).toMatchObject({ purpose: 'kiosk_order', kioskId: tab.tabletId, reason: 'invalid' });
    expect(await t.auditRows('auth.otp.locked', attempt.challengeId)).toHaveLength(1);
    expect(JSON.stringify(failed)).not.toContain(attempt.code);

    // Верный код при отказе корзины: проверка кода зафиксирована (verified), заявки нет, код не погашен.
    const x = v[8];
    const short = await ready({ items: [[x, '2']] });
    await t.setStock(x.variantId, '1', w1);
    const refused = await submit(short.tab, short.attempt);
    expect(refused.status).toBe(422);
    expect(await challengeOf(short.attempt.challengeId)).toMatchObject({
      status: 'verified',
      attempts: 1,
      replayed_at: null,
    });

    // 1С «зависла» на поиске карточки: строки кода и корзины не заблокированы, ответ — по реплике.
    const hang = await ready();
    const { entered } = onecHangs();
    const started = performance.now();
    const pending = submit(hang.tab, hang.attempt);
    await entered;
    expect(await lockFree('otp_challenges', hang.attempt.challengeId)).toBe(true);
    expect(await lockFree('carts', hang.attempt.cartId)).toBe(true);
    const r = await pending;
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(performance.now() - started).toBeGreaterThanOrEqual(TIMEOUT_MS - 100);
  });

  it("T-KIOSK-038 order not in that user's «Мои заказы»", async () => {
    // Карточка с подтверждённой привязкой к customer1 с другим телефоном → ambiguous, «Розничный покупатель».
    const customer1 = await t.actor({ role: 'customer' });
    const phone = buyerPhone();
    const linked = await card({ phone, name: 'Карточка чужой привязки (тест)' });
    await link(customer1.userId, linked, await phoneOf(customer1));
    const a = await ready({ phone });
    const r = await submit(a.tab, a.attempt);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const o = await orderOf(r.body.publicNumber as string);
    expect(o).toMatchObject({ customer_id: RETAIL_CUSTOMER_ID, kiosk_customer_match: 'ambiguous' });
    const list = await call('get', '/orders', customer1);
    expect(list.status).toBe(200);
    expect((list.body.items as { publicNumber: string }[]).map((i) => i.publicNumber)).not.toContain(
      r.body.publicNumber,
    );
    expect((await call('get', `/orders/${o.id}`, customer1)).status).toBe(404);

    // Юрлицо с основным подтверждённым телефоном → ambiguous (Р-04 (а)).
    const legalPhone = buyerPhone();
    await card({ phone: legalPhone, name: 'ОсОО «Тест»', type: 'legal' });
    const b = await ready({ phone: legalPhone });
    const rl = await submit(b.tab, b.attempt);
    expect(rl.status).toBe(201);
    expect(await orderOf(rl.body.publicNumber as string)).toMatchObject({
      customer_id: RETAIL_CUSTOMER_ID,
      kiosk_customer_match: 'ambiguous',
    });
  });

  it('T-KIOSK-041 pd_notice_version and pd_notice_sha256 in the order', async () => {
    const { tab, attempt } = await ready();
    const r = await submit(tab, attempt);
    expect(r.status).toBe(201);
    const o = await orderOf(r.body.publicNumber as string);
    const ch = await t.q<{ notice_version: string }>(`SELECT notice_version FROM otp_challenges WHERE id = $1`, [
      attempt.challengeId,
    ]);
    expect(o.pd_notice_version).toBe(ch[0].notice_version);
    expect(o.pd_notice_version).toBe(NOTICE);
    expect(o.pd_notice_sha256).toBe(kioskNoticeSha256(NOTICE));
    expect(o.pd_notice_sha256).toBe(
      NOTICE_CATALOG.kiosk_order_notice.versions.find((x) => x.version === NOTICE)?.sha256,
    );
  });

  it('T-KIOSK-043 created_via kiosk, comment passes contract pattern, createdByUserCode', async () => {
    const name = 'Планшет у входа (тест 043)';
    const { tab, phone, attempt } = await ready({ name });
    const r = await submit(tab, attempt);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const publicNumber = r.body.publicNumber as string;
    const o = await orderOf(publicNumber);
    expect(o).toMatchObject({
      created_via: 'kiosk',
      payment_method: 'cash',
      delivery_method: 'pickup',
      warehouse_id: w1,
    });
    const [job] = await outboxOf(o.id);
    const doc = YAML.parse(readFileSync(ONEC_CONTRACT, 'utf8')) as {
      components: { schemas: { OrderCreateRequest: { properties: Record<string, Record<string, unknown>> } } };
    };
    const props = doc.components.schemas.OrderCreateRequest.properties;
    const comment = job.payload.comment as string;
    expect(comment).toBe(`POS ${o.id} · ${publicNumber} · Заявка с планшета «${name}»`);
    expect(comment).toMatch(new RegExp(props.comment['x-comment-pattern'] as string));
    expect(job.payload.createdByUserCode).toBe(tab.userId);
    expect(job.payload.createdByUserCode).toMatch(new RegExp(props.createdByUserCode.pattern as string));
    expect(job.payload).toMatchObject({ paymentMethod: 'cash', delivery: { method: 'pickup', receiverName: null } });
    expect((job.payload.delivery as Record<string, unknown>).receiverPhone).toBe(phone);
    expect(contractErrors('OrderCreateRequest', job.payload)).toEqual([]);

    // Уведомление kiosk_order — кассиру и старшему продавцу, без телефона и сумм; планшету и продавцу — нет.
    const notes = await t.q<{ user_id: string; kind: string; title_ru: string; body_ru: string; payload: unknown }>(
      `SELECT user_id, kind::text AS kind, title_ru, body_ru, payload FROM notifications WHERE dedupe_key = $1`,
      [`kiosk_order:${o.id}`],
    );
    const to = notes.map((n) => n.user_id);
    expect(to).toContain(cashier.userId);
    expect(to).toContain(senior.userId);
    expect(to).not.toContain(tab.userId);
    expect(to).not.toContain(seller.userId);
    for (const n of notes) {
      expect(n).toMatchObject({ kind: 'kiosk_order', title_ru: `Новая заявка с планшета № ${publicNumber}` });
      expect(n.payload).toEqual({ orderId: o.id });
      expect(JSON.stringify(n)).not.toContain(phone);
      expect(JSON.stringify(n)).not.toContain(o.total);
    }
    // Аудит: order.created — канал и итог поиска без телефона; auth.otp.verified — с kioskId.
    const created = await t.auditRows('order.created', o.id);
    expect(created).toHaveLength(1);
    expect(created[0]).toMatchObject({
      actor_user_id: tab.userId,
      after: { createdVia: 'kiosk', customerMatch: 'none' },
    });
    expect(JSON.stringify(created[0].after)).not.toContain(phone);
    const verified = await t.auditRows('auth.otp.verified', attempt.challengeId);
    expect(verified).toHaveLength(1);
    expect(verified[0].after).toMatchObject({ purpose: 'kiosk_order', kioskId: tab.tabletId });
  });

  it('T-KIOSK-047 two parallel requests one code → one order, second 422 OTP_EXPIRED', async () => {
    const { tab, attempt } = await ready();
    const [a, b] = await Promise.all([submit(tab, attempt), submit(tab, attempt)]);
    const results = [a, b].map((r): [number, string] => [r.status, String(r.body.code ?? 'created')]).sort();
    expect(results, JSON.stringify([a.body, b.body])).toEqual([
      [201, 'created'],
      [422, 'OTP_EXPIRED'],
    ]);
    expect(await ordersOfTablet(tab)).toBe(1);
    const jobs = await t.q<{ n: number }>(
      `SELECT count(*)::int AS n FROM onec_outbox x JOIN orders o ON o.id = x.aggregate_id
        WHERE x.aggregate_type = 'order' AND o.created_by_user_id = $1`,
      [tab.userId],
    );
    expect(jobs[0].n).toBe(1);
  });

  it('T-KIOSK-053 slow 1C under 30 s, ONEC_REJECTED sanitized', async () => {
    const { tab, attempt } = await ready();
    t.onec.script('findCustomersByPhone', { delayMs: 400, then: { fixture: 'customers-search.empty.200' } });
    t.onec.script('checkCart', {
      delayMs: 400,
      then: { error: 422, code: 'POS_E_VALIDATION', message: 'Клиент заблокирован в 1С (тест)' },
    });
    const started = performance.now();
    const r = await submit(tab, attempt);
    const elapsed = performance.now() - started;
    expect(r.status, JSON.stringify(r.body)).toBe(422);
    expect(r.body).toMatchObject({ code: 'ONEC_REJECTED', detail: KIOSK_ONEC_REJECTED_DETAIL });
    expect(r.body).not.toHaveProperty('onec');
    expect(JSON.stringify(r.body)).not.toContain('заблокирован');
    expect(elapsed).toBeGreaterThanOrEqual(700);
    expect(elapsed).toBeLessThan(30_000);
  });

  it('T-KIOSK-058 order by card after fix', async () => {
    const x = v[9];
    const y = v[10];
    const pl = await cardPriceList('Договорная (тест 058)', [
      [x, '70.00'],
      [y, '70.00'],
    ]);
    const phone = buyerPhone();
    const cardId = await card({ phone, priceListId: pl });
    const { tab, attempt } = await ready({
      phone,
      items: [
        [x, '1'],
        [y, '3'],
      ],
    });
    // Обычная цена изменилась после предпросмотра (price_changed против снимка), остатка y не хватает.
    await t.setPrice(x.variantId, '105.00');
    await t.setStock(y.variantId, '1', w1);
    const key = randomUUID();
    const short = await submit(tab, attempt, key);
    expect(short.status, JSON.stringify(short.body)).toBe(422);
    expect(short.body.code).toBe('STOCK_INSUFFICIENT');
    expect(short.body.conflicts).toEqual([
      { variantId: y.variantId, kind: 'stock_insufficient', stockLevel: expect.any(String) },
    ]);
    const stored = await t.q<{ response_body: unknown }>(
      `SELECT response_body FROM idempotency_keys WHERE key = $1 AND user_id = $2`,
      [key, tab.userId],
    );
    for (const text of [JSON.stringify(short.body), JSON.stringify(stored[0].response_body)]) {
      for (const leak of ['oldPrice', 'newPrice', 'available', 'requested', '70.00', cardId, pl]) {
        expect(text).not.toContain(leak);
      }
    }
    // Исправить корзину → новый предпросмотр → тот же код: заявка по цене карточки.
    await putItem(tab, y, '1');
    const ok = await submit(tab, await attemptOf(tab, attempt));
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    const o = await orderOf(ok.body.publicNumber as string);
    expect(o).toMatchObject({ customer_id: cardId, price_list_id: pl, total: '140.00' });
  });

  it('T-KIOSK-059 preview older than 5 min, cart changed, total differs', async () => {
    const tab = await t.tablet({ warehouseId: w1 });
    await putItem(tab, v[11], '1');
    const old = await preview(tab);
    clock.advance(4 * 60_000);
    const code = await requestCode(tab, buyerPhone());
    clock.advance(62_000);
    const stale: Attempt = {
      ...code,
      cartId: old.body.cartId as string,
      cartRowVersion: old.body.cartRowVersion as number,
      previewToken: old.body.previewToken as string,
    };
    // Предпросмотр старше 5 мин — 422 PRICE_CHANGED preview_token_invalid, без сумм; попытка кода не потрачена.
    const expired = await submit(tab, stale);
    expect(expired.status, JSON.stringify(expired.body)).toBe(422);
    expect(expired.body).toMatchObject({ code: 'PRICE_CHANGED', reason: 'preview_token_invalid', conflicts: [] });
    expect(expired.body).not.toHaveProperty('total');
    expect(expired.body).not.toHaveProperty('previewTotal');
    expect(await challengeOf(code.challengeId)).toMatchObject({ status: 'sent', attempts: 0 });

    // Корзина изменилась после предпросмотра: текущая версия корзины и прежний токен — preview_cart_changed.
    const fresh = await preview(tab);
    await putItem(tab, v[12], '1');
    const cart = await call('get', '/cart', tab);
    const changed = await submit(tab, {
      ...code,
      cartId: cart.body.id as string,
      cartRowVersion: cart.body.rowVersion as number,
      previewToken: fresh.body.previewToken as string,
    });
    expect(changed.status, JSON.stringify(changed.body)).toBe(422);
    expect(changed.body).toMatchObject({ code: 'PRICE_CHANGED', reason: 'preview_cart_changed', conflicts: [] });
    expect(await challengeOf(code.challengeId)).toMatchObject({ status: 'sent', attempts: 0 });

    // Новый предпросмотр и одна повторная отправка — заявка создана.
    const ok = await submit(tab, await attemptOf(tab, code));
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
  });

  it('T-KIOSK-062 two buyers same cart within 60 s → two orders', async () => {
    // Окно ORD-022 (60 с) сверяет `orders.created_at` (время БД) с часами сервиса — часы стенда к текущему времени,
    // планшет (и его токен) — после этого.
    clock.set(new Date());
    const tab = await t.tablet({ warehouseId: w1 });
    const first = await ready({ tab, items: [[v[13], '1']] });
    const r1 = await submit(tab, first.attempt);
    expect(r1.status, JSON.stringify(r1.body)).toBe(201);
    // Та же корзина (тот же состав, «Розничный покупатель», наличные, итог) другим покупателем сразу после первой.
    const second = await ready({ tab, items: [[v[13], '1']] });
    const r2 = await submit(tab, second.attempt);
    expect(r2.status, JSON.stringify(r2.body)).toBe(201);
    expect(r2.body.code).toBeUndefined();
    expect(r2.body.publicNumber).not.toBe(r1.body.publicNumber);
    const [o1, o2] = [await orderOf(r1.body.publicNumber as string), await orderOf(r2.body.publicNumber as string)];
    expect([o1.customer_id, o2.customer_id]).toEqual([RETAIL_CUSTOMER_ID, RETAIL_CUSTOMER_ID]);
    expect(o1.total).toBe(o2.total);
    expect(await ordersOfTablet(tab)).toBe(2);
  });
});
