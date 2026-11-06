import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { KioskCustomerMatcher } from '../../src/customers/matching/kiosk-customer-match.js';
import type { OnecCallOptions, OnecJsonObject } from '../../src/integrations/onec/onec-gateway.js';
import { LinksTestApp, nextPhone } from './support/links-app.js';

/**
 * Поиск карточки клиента для заявки с планшета магазина (TAB-1-13; P-002 §8.6; 10 KIOSK-014, AC-KIOSK-014;
 * 05 ONEC-110; 11 SEC-130 «Планшет магазина»; решения Р-02 (а), Р-04 (а), Р-23 (а); Q-347) — **тестовые данные**,
 * реплика `customers` в embedded PostgreSQL 17 и FakeOnecGateway (`ONEC_MODE=fixtures`):
 * - T-KIOSK-019 — одна карточка из полной синхронизации 1С, номер — её основной телефон → `single` на эту карточку;
 * - T-KIOSK-020 — две карточки, второй контакт, `verified=false`, только живой поиск 1С → `ambiguous`; карточек нет →
 *   `none`; задачи `customer/create`, `customer_links` и `users` не создаются;
 * - T-KIOSK-021 — 1С не отвечает дольше `ONEC_SYNC_CHECK_TIMEOUT_MS` → решение по реплике;
 * - T-KIOSK-038 — карточка юрлица и карточка с подтверждённой привязкой к пользователю с другим телефоном →
 *   `ambiguous` (часть «поиск»; заявка и «Мои заказы» — test/kiosk/orders.spec.ts, WP-S4C).
 * Единственная допустимая запись — прежняя строка-заглушка реплики `findByPhone` для карточки, известной только 1С.
 */
describe('KIOSK-014 поиск карточки для заявки с планшета (embedded PG17 + FakeOnecGateway)', () => {
  const t = new LinksTestApp();
  let matcher: KioskCustomerMatcher;

  /** Счётчики таблиц, которые поиск не должен трогать (customers — кроме заглушки реплики). */
  type Writes = {
    links: number;
    users: number;
    customers: number;
    customerOutbox: number;
    notifications: number;
    audit: number;
  };
  const writes = async (): Promise<Writes> =>
    (
      await t.db.execute<Writes>(sql`
        SELECT (SELECT count(*) FROM customer_links)::int AS links,
               (SELECT count(*) FROM users)::int AS users,
               (SELECT count(*) FROM customers)::int AS customers,
               (SELECT count(*) FROM onec_outbox WHERE aggregate_type = 'customer')::int AS "customerOutbox",
               (SELECT count(*) FROM notifications)::int AS notifications,
               (SELECT count(*) FROM audit_logs)::int AS audit`)
    ).rows[0];

  const onecRefOf = async (customerId: string): Promise<string> =>
    (await t.db.execute<{ ref: string }>(sql`SELECT onec_ref::text AS ref FROM customers WHERE id = ${customerId}`))
      .rows[0].ref;

  /**
   * Ответ поиска 1С (контракт `CustomerCandidate`, фикстура customers-search.200) с заданными Ref и номером; код
   * карточки уникален (`customers_onec_code_uq`), как в 1С.
   */
  const onecAnswers = (phone: string, refs: readonly string[]) => {
    const [base] = t.onec.fixture('customers-search.200').body as OnecJsonObject[];
    return vi.spyOn(t.onec, 'findCustomersByPhone').mockResolvedValue({
      status: 200,
      body: refs.map((ref) => ({ ...base, ref, code: `K-${ref.slice(0, 8)}`, contractorRef: null, phone })),
    });
  };

  /** 1С «молчит»: ответа нет, пока не сработает сигнал таймаута вызывающего. */
  const onecHangs = () =>
    vi.spyOn(t.onec, 'findCustomersByPhone').mockImplementation(
      (_phone: string, opts?: OnecCallOptions) =>
        new Promise<never>((_resolve, reject) => {
          const signal = opts?.signal;
          if (signal) signal.addEventListener('abort', () => reject(signal.reason as Error), { once: true });
          else reject(new Error('тест: вызов 1С без сигнала таймаута'));
        }),
    );

  beforeAll(async () => {
    await t.start('kiosk_customer_match');
    matcher = t.app.get(KioskCustomerMatcher);
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

  describe('T-KIOSK-019 single on primary verified phone', () => {
    it('T-KIOSK-019 карточка физлица из полной синхронизации, номер — основной; 1С знает ту же карточку → single', async () => {
      const phone = nextPhone();
      const cardId = await t.card({ name: 'Асанов Бакыт', primaryPhone: phone });
      const spy = onecAnswers(phone, [await onecRefOf(cardId)]);
      const before = await writes();
      const res = await matcher.matchKioskCustomer(phone, { requestId: 'req-kiosk-019' });
      expect(res).toEqual({ customerId: cardId, match: 'single', reason: 'matched', onec: 'ok' });
      expect(await writes()).toEqual(before);
      // Синхронный запрос в 1С: тот же номер, X-Request-Id и сигнал таймаута.
      expect(spy).toHaveBeenCalledTimes(1);
      expect(spy.mock.calls[0][0]).toBe(phone);
      expect(spy.mock.calls[0][1]).toMatchObject({ requestId: 'req-kiosk-019' });
      expect(spy.mock.calls[0][1]?.signal).toBeInstanceOf(AbortSignal);
    });

    it('T-KIOSK-019 карточка ИП; привязка к пользователю с тем же номером; 1С ответила «не найдено» → single', async () => {
      const phone = nextPhone();
      const ip = await t.card({ name: 'ИП Токтогулов', type: 'entrepreneur', primaryPhone: phone });
      expect(await matcher.matchKioskCustomer(phone)).toMatchObject({ customerId: ip, match: 'single', onec: 'ok' });

      const phone2 = nextPhone();
      const own = await t.card({ name: 'Садыкова Айгуль', primaryPhone: phone2, phones: [nextPhone()] });
      const owner = await t.actor({ role: 'customer', phone: phone2 });
      await t.link(owner.userId, own, 'confirmed', phone2);
      const before = await writes();
      expect(await matcher.matchKioskCustomer(phone2)).toEqual({
        customerId: own,
        match: 'single',
        reason: 'matched',
        onec: 'ok',
      });
      expect(await writes()).toEqual(before);
    });
  });

  describe('T-KIOSK-020 two cards, secondary contact, unverified, none → retail, no customer/create', () => {
    it('T-KIOSK-020 две карточки с одним номером → ambiguous, клиент — «Розничный покупатель» (customerId null)', async () => {
      const phone = nextPhone();
      await t.card({ name: 'Первая Карточка', primaryPhone: phone });
      await t.card({ name: 'Вторая Карточка', primaryPhone: phone });
      const before = await writes();
      expect(await matcher.matchKioskCustomer(phone)).toEqual({
        customerId: null,
        match: 'ambiguous',
        reason: 'several_cards',
        onec: 'ok',
      });
      expect(await writes()).toEqual(before);
    });

    it('T-KIOSK-020 номер — второй контакт карточки (phones_norm и customer_contacts) → ambiguous', async () => {
      const phone = nextPhone();
      await t.card({ name: 'Второй Контакт', primaryPhone: nextPhone(), phones: [phone] });
      expect(await matcher.matchKioskCustomer(phone)).toMatchObject({
        customerId: null,
        match: 'ambiguous',
        reason: 'not_primary_phone',
      });

      const phone2 = nextPhone();
      const viaContact = await t.card({ name: 'Контакт Карточки', primaryPhone: nextPhone() });
      await t.contact(viaContact, phone2, false);
      expect(await matcher.matchKioskCustomer(phone2)).toMatchObject({ customerId: null, match: 'ambiguous' });

      // Основной контакт customer_contacts, но primary_phone_e164 карточки — другой номер.
      const phone3 = nextPhone();
      const primaryContact = await t.card({ name: 'Основной Контакт', primaryPhone: nextPhone() });
      await t.contact(primaryContact, phone3, true);
      expect(await matcher.matchKioskCustomer(phone3)).toMatchObject({
        customerId: null,
        match: 'ambiguous',
        reason: 'not_primary_phone',
      });
    });

    it('T-KIOSK-020 verified=false: карточка POS и карточка 1С без полной синхронизации → ambiguous (Р-23 (а))', async () => {
      const pos = nextPhone();
      await t.card({ name: 'Карточка Кассы', source: 'pos', primaryPhone: pos });
      expect(await matcher.matchKioskCustomer(pos)).toEqual({
        customerId: null,
        match: 'ambiguous',
        reason: 'phone_not_verified',
        onec: 'ok',
      });
      const unsynced = nextPhone();
      await t.card({ name: 'Без Синхронизации', primaryPhone: unsynced, synced: false });
      expect(await matcher.matchKioskCustomer(unsynced)).toMatchObject({
        customerId: null,
        match: 'ambiguous',
        reason: 'phone_not_verified',
      });
    });

    it('T-KIOSK-020 карточек нет ни в реплике, ни в 1С → none; ничего не создаётся', async () => {
      const phone = nextPhone();
      const before = await writes();
      expect(await matcher.matchKioskCustomer(phone)).toEqual({
        customerId: null,
        match: 'none',
        reason: 'no_cards',
        onec: 'ok',
      });
      expect(await writes()).toEqual(before);
      expect(t.onec.calls.map((c) => c.operation)).toEqual(['findCustomersByPhone']);
    });

    it('T-KIOSK-020 карточка только из живого поиска 1С (Q-347) → ambiguous; запись — только заглушка реплики', async () => {
      const phone = nextPhone();
      const ref = randomUUID();
      onecAnswers(phone, [ref]);
      const before = await writes();
      const res = await matcher.matchKioskCustomer(phone);
      expect(res).toEqual({ customerId: null, match: 'ambiguous', reason: 'legal_entity', onec: 'ok' });
      // Прежнее поведение findByPhone: строка реплики legal без synced_at; ни привязки, ни customer/create, ни users.
      expect(await writes()).toEqual({ ...before, customers: before.customers + 1 });
      const stub = await t.db.execute<{ source: string; customer_type: string; synced_at: Date | null }>(
        sql`SELECT source, customer_type, synced_at FROM customers WHERE onec_ref = ${ref}::uuid`,
      );
      expect(stub.rows).toEqual([{ source: 'onec', customer_type: 'legal', synced_at: null }]);
      expect(t.onec.calls.some((c) => c.operation === 'createCustomer')).toBe(false);
      // Повторный поиск — та же строка, без новой записи.
      await matcher.matchKioskCustomer(phone);
      expect((await writes()).customers).toBe(before.customers + 1);
    });

    it('T-KIOSK-020 реплика + 1С: карточка реплики и другая карточка 1С с тем же номером → ambiguous', async () => {
      const phone = nextPhone();
      await t.card({ name: 'Реплика Одна', primaryPhone: phone });
      onecAnswers(phone, [randomUUID()]);
      expect(await matcher.matchKioskCustomer(phone)).toMatchObject({
        customerId: null,
        match: 'ambiguous',
        reason: 'several_cards',
        onec: 'ok',
      });
    });
  });

  describe('T-KIOSK-021 1C timeout → replica decision', () => {
    it('T-KIOSK-021 1С не ответила за ONEC_SYNC_CHECK_TIMEOUT_MS → по реплике: single, onec=unavailable; номер не в журнале', async () => {
      const phone = nextPhone();
      const cardId = await t.card({ name: 'Реплика Надёжная', primaryPhone: phone });
      const realTimeout = AbortSignal.timeout.bind(AbortSignal);
      const timeout = vi.spyOn(AbortSignal, 'timeout').mockImplementation(() => realTimeout(50));
      onecHangs();
      const before = await writes();
      const res = await matcher.matchKioskCustomer(phone, { requestId: 'req-kiosk-021' });
      expect(res).toEqual({ customerId: cardId, match: 'single', reason: 'matched', onec: 'unavailable' });
      expect(timeout).toHaveBeenCalledWith(t.config.ONEC_SYNC_CHECK_TIMEOUT_MS);
      expect(await writes()).toEqual(before);
      expect(t.logs.text).toContain('customer_match.onec_unavailable');
      expect(t.logs.text).not.toContain(phone);
      expect(t.logs.text).not.toContain(phone.slice(1));
    });

    it('T-KIOSK-021 1С молчит, карточка только в 1С → none без заглушки; две карточки реплики → ambiguous', async () => {
      const phone = nextPhone();
      const realTimeout = AbortSignal.timeout.bind(AbortSignal);
      vi.spyOn(AbortSignal, 'timeout').mockImplementation(() => realTimeout(50));
      onecHangs();
      const before = await writes();
      expect(await matcher.matchKioskCustomer(phone)).toEqual({
        customerId: null,
        match: 'none',
        reason: 'no_cards',
        onec: 'unavailable',
      });
      expect(await writes()).toEqual(before);

      vi.restoreAllMocks();
      const phone2 = nextPhone();
      await t.card({ name: 'Реплика Первая', primaryPhone: phone2 });
      await t.card({ name: 'Реплика Вторая', primaryPhone: phone2 });
      vi.spyOn(t.onec, 'findCustomersByPhone').mockRejectedValue(new Error('1С не ответила (тест)'));
      expect(await matcher.matchKioskCustomer(phone2)).toEqual({
        customerId: null,
        match: 'ambiguous',
        reason: 'several_cards',
        onec: 'unavailable',
      });
    });
  });

  describe('T-KIOSK-038 legal card and card linked to another phone → ambiguous', () => {
    it('T-KIOSK-038 основной телефон карточки юрлица из полной синхронизации → ambiguous (Р-04 (а))', async () => {
      const phone = nextPhone();
      const legal = await t.card({ name: 'ОсОО «Курулуш»', type: 'legal', primaryPhone: phone });
      onecAnswers(phone, [await onecRefOf(legal)]);
      const before = await writes();
      expect(await matcher.matchKioskCustomer(phone)).toEqual({
        customerId: null,
        match: 'ambiguous',
        reason: 'legal_entity',
        onec: 'ok',
      });
      expect(await writes()).toEqual(before);
    });

    it('T-KIOSK-038 карточка с подтверждённой привязкой к customer1 с другим телефоном → ambiguous', async () => {
      const phone = nextPhone();
      const cardId = await t.card({ name: 'Жумабаев Эрлан', primaryPhone: phone });
      const customer1 = await t.actor({ role: 'customer', phone: nextPhone() });
      const linkId = await t.link(customer1.userId, cardId, 'confirmed', customer1.phone);
      const before = await writes();
      expect(await matcher.matchKioskCustomer(phone)).toEqual({
        customerId: null,
        match: 'ambiguous',
        reason: 'linked_to_other_phone',
        onec: 'ok',
      });
      expect(await writes()).toEqual(before);
      expect(await t.linkStatus(linkId)).toBe('confirmed');
    });

    it('KIOSK-014 открытый conflict привязки → ambiguous; отклонённая или предложенная привязка — не помеха', async () => {
      const phone = nextPhone();
      const cardId = await t.card({ name: 'Конфликт Привязки', primaryPhone: phone });
      const other = await t.actor({ role: 'customer', phone: nextPhone() });
      await t.link(other.userId, cardId, 'conflict', other.phone);
      expect(await matcher.matchKioskCustomer(phone)).toMatchObject({
        customerId: null,
        match: 'ambiguous',
        reason: 'link_conflict',
      });

      const phone2 = nextPhone();
      const free = await t.card({ name: 'Свободная Карточка', primaryPhone: phone2 });
      const a = await t.actor({ role: 'customer', phone: nextPhone() });
      const b = await t.actor({ role: 'customer', phone: nextPhone() });
      await t.link(a.userId, free, 'rejected', a.phone);
      await t.link(b.userId, free, 'proposed', b.phone);
      expect(await matcher.matchKioskCustomer(phone2)).toMatchObject({ customerId: free, match: 'single' });
    });
  });
});
