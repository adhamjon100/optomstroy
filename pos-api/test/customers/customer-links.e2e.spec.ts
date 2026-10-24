import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import request from 'supertest';
import { CustomerLinksService } from '../../src/customers/links/customer-links.service.js';
import { buildOpenApiDocument } from '../../src/health/openapi.document.js';
import { CUSTOMER_MATCHING, type CustomerMatching } from '../../src/customers/matching/customer-matching.port.js';
import { contract, deepKeys, validateAgainst } from '../settings/support/openapi-check.js';
import { type Actor, LinksTestApp, nextPhone } from './support/links-app.js';

/** Номер из фикстуры contracts/onec/fixtures/customers-search.200.json (тестовые данные). */
const FIXTURE_PHONE = '+996700000001';
const FIXTURE_REF = 'c3d4e5f6-0000-4000-8000-000000000001';

/** Поля, которых не должно быть в ответах клиенту до `confirmed` (09 REG-031/REG-032, 11 SEC-031). */
const FINANCIAL_KEYS = [
  'receivable',
  'balance',
  'overdueAmount',
  'creditLimit',
  'limitRemaining',
  'hasDebt',
  'isOverdue',
  'creditAllowed',
  'documents',
  'ordersCount',
  'lastOrderAt',
  'history',
  'orders',
  'discountPercent',
  'priceList',
  'phones',
  'inn',
];

describe('RM-D-005 привязка к клиенту 1С: customer_links, SCR-06, SCR-45 (embedded PG17 + FakeOnecGateway)', () => {
  const t = new LinksTestApp();
  let service: CustomerLinksService;
  let admin: Actor;

  const http = () => request(t.app.getHttpServer());
  const as = (a: Actor) => ({
    get: (path: string) =>
      http().get(`/api/v1${path}`).set('Authorization', `Bearer ${a.token}`).set('X-Device-Id', a.deviceKey),
    post: (path: string, body?: object, headers: Record<string, string> = {}) => {
      let r = http().post(`/api/v1${path}`).set('Authorization', `Bearer ${a.token}`).set('X-Device-Id', a.deviceKey);
      for (const [k, v] of Object.entries(headers)) r = r.set(k, v);
      return body === undefined ? r : r.send(body);
    },
  });

  beforeAll(async () => {
    await t.start('customer_links');
    service = t.app.get(CustomerLinksService);
    admin = await t.actor({ role: 'admin', fullName: 'Админ Тестов' });
  });

  afterAll(async () => {
    await t.stop();
  });

  beforeEach(() => {
    t.flag.value = true;
    t.onec.reset();
    t.onec.useFixture('findCustomersByPhone', 'customers-search.empty.200');
  });

  describe('критерий 1: один клиент по телефону → proposed (FakeOnecGateway)', () => {
    it('карточка только в 1С (фикстура customers-search.200) → строка реплики + proposed; ответ без финансов', async () => {
      t.onec.useFixture('findCustomersByPhone', 'customers-search.200');
      const c = await t.actor({ role: 'customer', phone: FIXTURE_PHONE, fullName: 'Клиент Пример' });
      const summary = await service.proposeForUser({ userId: c.userId, phoneE164: c.phone });
      // Тип карточки из поиска 1С неизвестен → консервативно legal → решает admin (SEC-130).
      expect(summary).toMatchObject({ status: 'proposed', nextStep: 'wait_admin' });
      expect(summary.linkId).toMatch(/^[0-9a-f-]{36}$/);
      const replica = await t.db.execute<{ id: string; source: string; customer_type: string }>(
        sql`SELECT id, source, customer_type FROM customers WHERE onec_ref = ${FIXTURE_REF}::uuid`,
      );
      expect(replica.rows[0]).toMatchObject({ source: 'onec', customer_type: 'legal' });
      const linkRow = await t.db.execute<{ status: string; match_method: string; customer_id: string }>(
        sql`SELECT status, match_method, customer_id FROM customer_links WHERE user_id = ${c.userId}`,
      );
      expect(linkRow.rows).toEqual([{ status: 'proposed', match_method: 'phone', customer_id: replica.rows[0].id }]);

      const r = await as(c).get('/registration/customer-match');
      expect(r.status).toBe(200);
      expect(r.headers['cache-control']).toBe('no-store');
      expect(r.body).toEqual({
        status: 'proposed',
        linkId: summary.linkId,
        customer: { displayNameMasked: 'Кли***' },
        nextStep: 'wait_admin',
      });
      expect(validateAgainst('RegistrationCustomerMatch', r.body)).toEqual([]);
      // Повторный поиск идемпотентен: та же привязка, без дублей.
      const again = await service.proposeForUser({ userId: c.userId, phoneE164: c.phone });
      expect(again.linkId).toBe(summary.linkId);
    });

    it('карточка из реплики (основной телефон, verified) → proposed с nextStep confirm_or_reject', async () => {
      const phone = nextPhone();
      const cardId = await t.card({ name: 'Иманов Нурлан', primaryPhone: phone, balance: '1500.00' });
      const c = await t.actor({ role: 'customer', phone });
      const summary = await service.proposeForUser({ userId: c.userId, phoneE164: phone });
      expect(summary).toMatchObject({ status: 'proposed', nextStep: 'confirm_or_reject' });
      const r = await as(c).get('/registration/customer-match');
      expect(r.body).toMatchObject({ status: 'proposed', customer: { displayNameMasked: 'Има***' } });
      expect(JSON.stringify(r.body)).not.toContain(cardId);
      expect(t.onec.calls.some((x) => x.operation === 'findCustomersByPhone')).toBe(true);
    });

    it('0 совпадений → customer_links не создаётся, status none', async () => {
      const c = await t.actor({ role: 'customer' });
      expect(await service.proposeForUser({ userId: c.userId, phoneE164: c.phone })).toEqual({
        status: 'none',
        linkId: null,
        nextStep: 'none',
      });
      expect((await as(c).get('/registration/customer-match')).body).toEqual({
        status: 'none',
        linkId: null,
        customer: null,
        nextStep: 'none',
      });
    });

    it('1С недоступна (таймаут/ошибка) → поиск по реплике, onec=unavailable; телефон не попадает в журнал', async () => {
      const phone = nextPhone();
      await t.card({ name: 'Реплика Только', primaryPhone: phone });
      const original = t.onec.findCustomersByPhone.bind(t.onec);
      t.onec.findCustomersByPhone = () => Promise.reject(new Error('AbortError'));
      try {
        const matching = t.app.get<CustomerMatching>(CUSTOMER_MATCHING);
        const res = await matching.findByPhone(phone);
        expect(res.onec).toBe('unavailable');
        expect(res.candidates).toHaveLength(1);
        expect(res.candidates[0].matchKind).toBe('primary');
      } finally {
        t.onec.findCustomersByPhone = original;
      }
      expect(t.logs.text).toContain('customer_match.onec_unavailable');
      expect(t.logs.text).not.toContain(phone);
      expect(t.logs.text).not.toContain(phone.slice(1));
    });

    it('таймаут поиска в 1С — ONEC_SYNC_CHECK_TIMEOUT_MS (6 с, ТЗ для 1С 4.9; разбор 98 п. 58), не 5 с', async () => {
      expect(t.config.ONEC_SYNC_CHECK_TIMEOUT_MS).toBe(6000);
      const phone = nextPhone();
      const spy = vi.spyOn(AbortSignal, 'timeout');
      const original = t.onec.findCustomersByPhone.bind(t.onec);
      let signal: AbortSignal | undefined;
      t.onec.findCustomersByPhone = (p, opts) => {
        signal = opts?.signal;
        return original(p, opts);
      };
      try {
        const res = await t.app.get<CustomerMatching>(CUSTOMER_MATCHING).findByPhone(phone);
        expect(res.onec).toBe('ok');
        expect(spy).toHaveBeenCalledTimes(1);
        expect(spy).toHaveBeenCalledWith(t.config.ONEC_SYNC_CHECK_TIMEOUT_MS);
        expect(signal).toBe(spy.mock.results[0]?.value);
      } finally {
        spy.mockRestore();
        t.onec.findCustomersByPhone = original;
      }
    });

    it('сотрудник: proposeForUser не создаёт привязку, GET customer-match → none', async () => {
      const phone = nextPhone();
      await t.card({ name: 'Карточка Сотрудника', primaryPhone: phone });
      const s = await t.actor({ role: 'seller', phone });
      expect((await service.proposeForUser({ userId: s.userId, phoneE164: phone })).status).toBe('none');
      expect((await as(s).get('/registration/customer-match')).body.status).toBe('none');
    });
  });

  describe('критерий 2: два совпадения → conflict + уведомление администратору', () => {
    it('реплика + 1С: две карточки → две записи conflict с conflict_candidates; уведомление admin; SCR-06 — wait_admin', async () => {
      const p2 = nextPhone();
      // Ответ 1С — фикстура customers-search.200 (тестовые данные) с номером этого теста и новой ссылкой 1С.
      const fixture = t.onec.fixture('customers-search.200').body as Record<string, unknown>[];
      const onecRef = randomUUID();
      const original = t.onec.findCustomersByPhone.bind(t.onec);
      t.onec.findCustomersByPhone = () =>
        Promise.resolve({
          status: 200,
          body: fixture.map((f) => ({ ...f, ref: onecRef, code: null, phone: p2 })) as never,
        });
      const own = await t.card({ name: 'ОсОО «Строймаркет»', type: 'legal', primaryPhone: p2 });
      const c = await t.actor({ role: 'customer', phone: p2 });
      const summary = await service.proposeForUser({ userId: c.userId, phoneE164: p2 });
      expect(summary).toMatchObject({ status: 'conflict', nextStep: 'wait_admin' });
      const rows = await t.db.execute<{ customer_id: string; status: string; conflict_candidates: string[] }>(
        sql`SELECT customer_id, status, conflict_candidates FROM customer_links WHERE user_id = ${c.userId} ORDER BY customer_id`,
      );
      expect(rows.rows.map((r) => r.status)).toEqual(['conflict', 'conflict']);
      const second = (
        await t.db.execute<{ id: string }>(sql`SELECT id FROM customers WHERE onec_ref = ${onecRef}::uuid`)
      ).rows[0].id;
      const byCustomer = new Map(rows.rows.map((r) => [r.customer_id, r.conflict_candidates]));
      expect(byCustomer.get(own)).toEqual([second]);
      expect(byCustomer.get(second)).toEqual([own]);

      const notes = await t.db.execute<{
        user_id: string;
        kind: string;
        payload: Record<string, unknown>;
        body_ru: string;
      }>(
        sql`SELECT user_id, kind, payload, body_ru FROM notifications WHERE dedupe_key = ${`customer_link.conflict:${c.userId}`}`,
      );
      expect(notes.rows.map((n) => n.user_id)).toContain(admin.userId);
      expect(notes.rows[0]).toMatchObject({ kind: 'system', payload: { target: 'customer_link', userId: c.userId } });
      expect(notes.rows[0].body_ru).not.toContain(p2);

      const r = await as(c).get('/registration/customer-match');
      expect(r.body).toEqual({ status: 'conflict', linkId: summary.linkId, customer: null, nextStep: 'wait_admin' });

      // Повторный поиск — без повторного уведомления (dedupe_key).
      await service.proposeForUser({ userId: c.userId, phoneE164: p2 });
      const count = await t.db.execute<{ n: number }>(
        sql`SELECT count(*)::int AS n FROM notifications WHERE dedupe_key = ${`customer_link.conflict:${c.userId}`}`,
      );
      expect(count.rows[0].n).toBe(notes.rows.length);
      t.onec.findCustomersByPhone = original;
    });
  });

  describe('критерий 3: до confirmed ответ не содержит долга и истории', () => {
    it('T-SEC-017 (часть D), T-SEC-055 (часть D), T-REG-019 (часть D): proposed: GET customer-match без финансовых полей; GET /customers/{id}/links клиентом → 404; после confirmed — только id/displayName', async () => {
      const phone = nextPhone();
      const cardId = await t.card({ name: 'Осмонов Талант', primaryPhone: phone, balance: '25000.00' });
      const c = await t.actor({ role: 'customer', phone });
      const { linkId } = await service.proposeForUser({ userId: c.userId, phoneE164: phone });

      const before = await as(c).get('/registration/customer-match');
      const keys = deepKeys(before.body);
      for (const k of FINANCIAL_KEYS) expect(keys.has(k)).toBe(false);
      expect(before.body.customer).toEqual({ displayNameMasked: 'Осм***' });
      expect(JSON.stringify(before.body)).not.toMatch(/25000|Осмонов|\+99677/);

      const links = await as(c).get(`/customers/${cardId}/links`);
      expect(links.status).toBe(404);
      expect(links.body.code).toBe('NOT_FOUND');

      const confirmed = await as(c).post('/registration/customer-match/confirm', { linkId });
      expect(confirmed.status).toBe(200);
      expect(confirmed.body).toEqual({
        status: 'confirmed',
        linkId,
        customer: { id: cardId, displayName: 'Осмонов Талант' },
        nextStep: 'confirmed',
      });
      for (const k of FINANCIAL_KEYS) expect(deepKeys(confirmed.body).has(k)).toBe(false);
      expect(validateAgainst('RegistrationCustomerMatch', confirmed.body)).toEqual([]);

      const own = await as(c).get(`/customers/${cardId}/links`);
      expect(own.status).toBe(200);
      expect(own.body.items).toHaveLength(1);
      expect(own.body.items[0]).toMatchObject({ id: linkId, userId: c.userId, status: 'confirmed' });
      expect(validateAgainst('CustomersLinksResponse', own.body)).toEqual([]);
    });
  });

  describe('критерий 4: POST /registration/customer-match → 405', () => {
    it('405 METHOD_NOT_ALLOWED, Allow: GET (и без Bearer)', async () => {
      const c = await t.actor({ role: 'customer' });
      const r = await as(c).post('/registration/customer-match', {});
      expect(r.status).toBe(405);
      expect(r.body.code).toBe('METHOD_NOT_ALLOWED');
      expect(r.headers.allow).toBe('GET');
      const anon = await http().post('/api/v1/registration/customer-match').send({});
      expect(anon.status).toBe(405);
    });

    it('GET без Bearer → 401; pending_activation → 200 none', async () => {
      expect((await http().get('/api/v1/registration/customer-match')).status).toBe(401);
      const p = await t.actor({ kind: 'customer', role: null, status: 'pending_activation' });
      const r = await as(p).get('/registration/customer-match');
      expect(r.status).toBe(200);
      expect(r.body.status).toBe('none');
    });
  });

  describe('самоподтверждение клиентом (08 §4.2.4; 11 SEC-130; T-REG-024, AC-AUTH-087)', () => {
    it('L1 verified → 200 confirmed без step-up, аудит selfResolved=true; повтор → 200 тот же ответ', async () => {
      const phone = nextPhone();
      const cardId = await t.card({ name: 'Жумабаев Эрлан', primaryPhone: phone });
      const a = await t.actor({ role: 'customer', phone });
      const l1 = await t.link(a.userId, cardId, 'proposed', phone);
      expect((await as(a).get('/registration/customer-match')).body.nextStep).toBe('confirm_or_reject');
      const r = await as(a).post('/registration/customer-match/confirm', { linkId: l1 });
      expect(r.status).toBe(200);
      expect(r.body).toMatchObject({ status: 'confirmed', nextStep: 'confirmed', customer: { id: cardId } });
      const audit = await t.auditRows(l1);
      expect(audit).toHaveLength(1);
      expect(audit[0]).toMatchObject({
        action: 'customer.link.confirmed',
        actor_user_id: a.userId,
        actor_role: 'customer',
        step_up_method: null,
        after: { status: 'confirmed', selfResolved: true, linkId: l1 },
      });
      const again = await as(a).post('/registration/customer-match/confirm', { linkId: l1 });
      expect(again.status).toBe(200);
      expect(again.body).toEqual(r.body);
      expect(await t.auditRows(l1)).toHaveLength(1);
    });

    it('reject своей proposed → 200 {rejected, customer:null, nextStep:none}; повтор → 200', async () => {
      const phone = nextPhone();
      const cardId = await t.card({ name: 'Садыкова Мээрим', primaryPhone: phone });
      const a = await t.actor({ role: 'customer', phone });
      const l = await t.link(a.userId, cardId, 'proposed', phone);
      const r = await as(a).post('/registration/customer-match/reject', { linkId: l });
      expect(r.status).toBe(200);
      expect(r.body).toEqual({ status: 'rejected', linkId: l, customer: null, nextStep: 'none' });
      expect((await as(a).post('/registration/customer-match/reject', { linkId: l })).status).toBe(200);
      expect((await t.auditRows(l))[0]).toMatchObject({
        action: 'customer.link.rejected',
        after: { status: 'rejected', selfResolved: true },
      });
      // rejected по тому же номеру не возрождается повторным поиском (09 §7.9).
      await service.proposeForUser({ userId: a.userId, phoneE164: phone });
      expect(await t.linkStatus(l)).toBe('rejected');
      expect((await as(a).get('/registration/customer-match')).body).toMatchObject({
        status: 'rejected',
        nextStep: 'none',
      });
    });

    it('409 CUSTOMER_LINK_CONFLICT (wait_admin): verified=false, legal, второй контакт, conflict, карточка привязана к другому', async () => {
      const cases: { name: string; reason: string; setup: (phone: string, userId: string) => Promise<string> }[] = [
        {
          name: 'verified=false (карточка POS)',
          reason: 'phone_not_verified',
          setup: async (phone, userId) =>
            t.link(
              userId,
              await t.card({ name: 'Пос Карточка', primaryPhone: phone, source: 'pos' }),
              'proposed',
              phone,
            ),
        },
        {
          name: 'legal',
          reason: 'legal_entity',
          setup: async (phone, userId) =>
            t.link(
              userId,
              await t.card({ name: 'ОсОО «Юрлицо»', type: 'legal', primaryPhone: phone }),
              'proposed',
              phone,
            ),
        },
        {
          name: 'второй контакт ЮЛ',
          reason: 'secondary_contact',
          setup: async (phone, userId) => {
            const id = await t.card({ name: 'Контакт Второй', primaryPhone: nextPhone(), phones: [phone] });
            await t.contact(id, phone);
            return t.link(userId, id, 'proposed', phone);
          },
        },
        {
          name: 'conflict',
          reason: 'conflict',
          setup: async (phone, userId) =>
            t.link(userId, await t.card({ name: 'Конфликт Один', primaryPhone: phone }), 'conflict', phone),
        },
        {
          name: 'карточка уже привязана к другому пользователю',
          reason: 'already_linked',
          setup: async (phone, userId) => {
            const id = await t.card({ name: 'Занятая Карточка', primaryPhone: phone });
            const other = await t.actor({ role: 'customer' });
            await t.link(other.userId, id, 'confirmed', other.phone);
            return t.link(userId, id, 'proposed', phone);
          },
        },
      ];
      for (const c of cases) {
        const phone = nextPhone();
        const a = await t.actor({ role: 'customer', phone });
        const linkId = await c.setup(phone, a.userId);
        const match = await as(a).get('/registration/customer-match');
        expect(match.body.nextStep, c.name).toBe('wait_admin');
        const r = await as(a).post('/registration/customer-match/confirm', { linkId });
        expect(r.status, c.name).toBe(409);
        expect(r.body, c.name).toMatchObject({
          code: 'CUSTOMER_LINK_CONFLICT',
          nextStep: 'wait_admin',
          reason: c.reason,
        });
        expect(await t.linkStatus(linkId), c.name).not.toBe('confirmed');
      }
    });

    it('T-SEC-015: IDOR: чужая привязка LB → 404 (как несуществующая); неверный UUID → 400', async () => {
      const pa = nextPhone();
      const pb = nextPhone();
      const a = await t.actor({ role: 'customer', phone: pa });
      const b = await t.actor({ role: 'customer', phone: pb });
      const lb = await t.link(b.userId, await t.card({ name: 'Карточка Бэ', primaryPhone: pb }), 'proposed', pb);
      const foreign = await as(a).post('/registration/customer-match/confirm', { linkId: lb });
      const unknown = await as(a).post('/registration/customer-match/confirm', { linkId: randomUUID() });
      expect(foreign.status).toBe(404);
      expect(unknown.status).toBe(404);
      expect(foreign.body.code).toBe(unknown.body.code);
      expect(foreign.body.detail).toBe(unknown.body.detail);
      expect(await t.linkStatus(lb)).toBe('proposed');
      const bad = await as(a).post('/registration/customer-match/confirm', { linkId: 'x' });
      expect(bad.status).toBe(400);
      expect(bad.body.code).toBe('VALIDATION_FAILED');
      const extra = await as(a).post('/registration/customer-match/confirm', { linkId: lb, force: true });
      expect(extra.status).toBe(400);
    });

    it('T-SEC-055 (часть D): staff (cashier, admin) → 403; CUSTOMER_SELF_SERVICE=false → 403 reason self_service_disabled; staff-путь клиентом → 403', async () => {
      const phone = nextPhone();
      const cardId = await t.card({ name: 'Флагов Тест', primaryPhone: phone });
      const a = await t.actor({ role: 'customer', phone });
      const l = await t.link(a.userId, cardId, 'proposed', phone);
      const cashier = await t.actor({ role: 'cashier' });
      for (const s of [cashier, admin]) {
        const r = await as(s).post('/registration/customer-match/confirm', { linkId: l });
        expect(r.status).toBe(403);
        expect(r.body.code).toBe('FORBIDDEN');
      }
      t.flag.value = false;
      const off = await as(a).post('/registration/customer-match/confirm', { linkId: l });
      expect(off.status).toBe(403);
      expect(off.body).toMatchObject({ code: 'FORBIDDEN', reason: 'self_service_disabled', nextStep: 'wait_admin' });
      expect((await as(a).get('/registration/customer-match')).body.nextStep).toBe('wait_admin');
      t.flag.value = true;
      const staffPath = await as(a).post(
        `/customers/${cardId}/links/${l}/confirm`,
        {},
        {
          'X-Step-Up-Token': await t.stepUp(a),
        },
      );
      expect(staffPath.status).toBe(403);
      expect(staffPath.body.code).toBe('FORBIDDEN');
      expect(await t.linkStatus(l)).toBe('proposed');
    });
  });

  describe('подтверждение сотрудником — только admin со step-up (08 §4.11.7; 11 код 32)', () => {
    async function proposedCase(opts: { source?: 'onec' | 'pos' } = {}) {
      const phone = nextPhone();
      const cardId = await t.card({
        name: 'ОсОО «Админ Кейс»',
        type: 'legal',
        primaryPhone: phone,
        source: opts.source,
      });
      const c = await t.actor({ role: 'customer', phone, fullName: 'Клиентов Клиент' });
      const linkId = await t.link(c.userId, cardId, 'proposed', phone);
      return { phone, cardId, c, linkId };
    }

    it('без X-Step-Up-Token → 403 STEP_UP_REQUIRED {operation, allowedMethods}; чужой scope/сессия → 403 STEP_UP_REQUIRED', async () => {
      const { cardId, linkId } = await proposedCase();
      const no = await as(admin).post(`/customers/${cardId}/links/${linkId}/confirm`, {});
      expect(no.status).toBe(403);
      expect(no.body).toMatchObject({
        code: 'STEP_UP_REQUIRED',
        stepUp: { operation: 'customer.link.resolve', allowedMethods: ['pin', 'otp'] },
      });
      const wrongScope = await as(admin).post(
        `/customers/${cardId}/links/${linkId}/confirm`,
        {},
        {
          'X-Step-Up-Token': await t.stepUp(admin, ['users.manage']),
        },
      );
      expect(wrongScope.body.code).toBe('STEP_UP_REQUIRED');
      const otherAdmin = await t.actor({ role: 'admin' });
      const foreignToken = await as(admin).post(
        `/customers/${cardId}/links/${linkId}/confirm`,
        {},
        {
          'X-Step-Up-Token': await t.stepUp(otherAdmin),
        },
      );
      expect(foreignToken.body.code).toBe('STEP_UP_REQUIRED');
      const garbage = await as(admin).post(
        `/customers/${cardId}/links/${linkId}/confirm`,
        {},
        {
          'X-Step-Up-Token': 'eyJhbGciOiJub25lIn0.e30.', // check-secrets: allow — тестовое значение
        },
      );
      expect(garbage.body.code).toBe('STEP_UP_REQUIRED');
      expect(await t.linkStatus(linkId)).toBe('proposed');
    });

    it('cashier, senior_seller, owner, seller со step-up → 403 FORBIDDEN', async () => {
      const { cardId, linkId } = await proposedCase();
      for (const role of ['cashier', 'senior_seller', 'owner', 'seller'] as const) {
        const s = await t.actor({ role });
        const r = await as(s).post(
          `/customers/${cardId}/links/${linkId}/confirm`,
          {},
          {
            'X-Step-Up-Token': await t.stepUp(s),
          },
        );
        expect(r.status, role).toBe(403);
        expect(r.body.code, role).toBe('FORBIDDEN');
      }
    });

    it('T-REG-020: admin со step-up подтверждает proposed (случай verified=false) → 200 CustomerLink, аудит со stepUpMethod; повтор → 200 без нового аудита', async () => {
      const { cardId, linkId, c } = await proposedCase({ source: 'pos' });
      const token = await t.stepUp(admin);
      const r = await as(admin).post(
        `/customers/${cardId}/links/${linkId}/confirm`,
        { comment: 'Проверен ИНН' },
        {
          'X-Step-Up-Token': token,
        },
      );
      expect(r.status).toBe(200);
      expect(r.body).toMatchObject({
        id: linkId,
        userId: c.userId,
        customerId: cardId,
        status: 'confirmed',
        matchedBy: 'phone',
        resolvedBy: { id: admin.userId, displayName: 'Админ Тестов' },
      });
      expect(validateAgainst('CustomerLink', r.body)).toEqual([]);
      const audit = await t.auditRows(linkId);
      expect(audit).toHaveLength(1);
      expect(audit[0]).toMatchObject({
        action: 'customer.link.confirmed',
        actor_user_id: admin.userId,
        actor_role: 'admin',
        step_up_method: 'pin',
        reason: 'Проверен ИНН',
        before: { status: 'proposed' },
        after: { status: 'confirmed', selfResolved: false },
      });
      // Токен step-up многоразовый в своей области 15 мин (ядро §18.2 п. 6); повтор — 200 без изменений.
      const again = await as(admin).post(
        `/customers/${cardId}/links/${linkId}/confirm`,
        {},
        { 'X-Step-Up-Token': token },
      );
      expect(again.status).toBe(200);
      expect(await t.auditRows(linkId)).toHaveLength(1);
      // Клиент теперь видит confirmed.
      expect((await as(c).get('/registration/customer-match')).body.status).toBe('confirmed');
    });

    it('T-REG-020: conflict: без причины → 400 reason_required; с причиной → выбранная confirmed, остальные rejected, аудит conflict_resolved', async () => {
      const phone = nextPhone();
      const c1 = await t.card({ name: 'ОсОО «Первая»', type: 'legal', primaryPhone: phone });
      const c2 = await t.card({ name: 'ОсОО «Вторая»', type: 'legal', primaryPhone: phone });
      const cust = await t.actor({ role: 'customer', phone });
      const summary = await service.proposeForUser({ userId: cust.userId, phoneE164: phone });
      expect(summary.status).toBe('conflict');
      const rows = await t.db.execute<{ id: string; customer_id: string }>(
        sql`SELECT id, customer_id FROM customer_links WHERE user_id = ${cust.userId}`,
      );
      const l1 = rows.rows.find((r) => r.customer_id === c1)!.id;
      const l2 = rows.rows.find((r) => r.customer_id === c2)!.id;
      const token = await t.stepUp(admin);
      const noReason = await as(admin).post(`/customers/${c1}/links/${l1}/confirm`, {}, { 'X-Step-Up-Token': token });
      expect(noReason.status).toBe(400);
      expect(noReason.body.errors[0]).toMatchObject({ field: 'comment', rule: 'reason_required' });
      const ok = await as(admin).post(
        `/customers/${c1}/links/${l1}/confirm`,
        { comment: 'Доверенность проверена' },
        {
          'X-Step-Up-Token': token,
        },
      );
      expect(ok.status).toBe(200);
      expect(await t.linkStatus(l1)).toBe('confirmed');
      expect(await t.linkStatus(l2)).toBe('rejected');
      expect((await t.auditRows(l1))[0]).toMatchObject({
        action: 'customer.link.conflict_resolved',
        step_up_method: 'pin',
        reason: 'Доверенность проверена',
        before: { status: 'conflict' },
        after: { status: 'confirmed', rejectedLinkIds: [l2] },
      });
      // Неверный customerId в пути → 404 (привязка выбирается с фильтром customer_id).
      expect(
        (await as(admin).post(`/customers/${c2}/links/${l1}/confirm`, {}, { 'X-Step-Up-Token': token })).status,
      ).toBe(404);
    });

    it('другая confirmed-привязка: 409 без force; force=true → прежняя rejected (superseded); reject proposed → 200', async () => {
      const phone = nextPhone();
      const cust = await t.actor({ role: 'customer', phone });
      const old = await t.card({ name: 'Старая Карточка', primaryPhone: phone });
      const neu = await t.card({ name: 'Новая Карточка', primaryPhone: nextPhone() });
      const third = await t.card({ name: 'Третья Карточка', primaryPhone: nextPhone() });
      const lOld = await t.link(cust.userId, old, 'confirmed', phone);
      const lNew = await t.link(cust.userId, neu, 'proposed', phone);
      const lThird = await t.link(cust.userId, third, 'proposed', phone);
      const token = await t.stepUp(admin);
      const conflict = await as(admin).post(
        `/customers/${neu}/links/${lNew}/confirm`,
        {},
        { 'X-Step-Up-Token': token },
      );
      expect(conflict.status).toBe(409);
      expect(conflict.body).toMatchObject({ code: 'CUSTOMER_LINK_CONFLICT', reason: 'user_has_confirmed_link' });
      const forced = await as(admin).post(
        `/customers/${neu}/links/${lNew}/confirm`,
        { force: true },
        {
          'X-Step-Up-Token': token,
        },
      );
      expect(forced.status).toBe(200);
      expect(await t.linkStatus(lOld)).toBe('rejected');
      expect(await t.linkStatus(lNew)).toBe('confirmed');
      const rej = await as(admin).post(
        `/customers/${third}/links/${lThird}/reject`,
        { comment: 'Не клиент' },
        {
          'X-Step-Up-Token': token,
        },
      );
      expect(rej.status).toBe(200);
      expect(rej.body).toMatchObject({ status: 'rejected', resolvedBy: { id: admin.userId } });
      expect((await t.auditRows(lThird))[0]).toMatchObject({ action: 'customer.link.rejected', step_up_method: 'pin' });
      // Решённую (confirmed) отклонить этим путём нельзя → 409.
      const late = await as(admin).post(`/customers/${neu}/links/${lNew}/reject`, {}, { 'X-Step-Up-Token': token });
      expect(late.status).toBe(409);
    });
  });

  describe('GET /customers/{id}/links и очередь GET /customers?linkStatus (08 §4.11.1, §4.11.7)', () => {
    it('cashier/owner/admin видят привязки с user {id, displayName, phoneMasked}; seller → 403; нет карточки → 404', async () => {
      const phone = nextPhone();
      const cardId = await t.card({ name: 'Просмотр Привязок', primaryPhone: phone });
      const c = await t.actor({ role: 'customer', phone, fullName: 'Абдыкадыров Улан' });
      const linkId = await t.link(c.userId, cardId, 'proposed', phone);
      for (const role of ['cashier', 'senior_seller', 'owner'] as const) {
        const s = await t.actor({ role });
        const r = await as(s).get(`/customers/${cardId}/links`);
        expect(r.status, role).toBe(200);
        expect(r.body.items, role).toHaveLength(1);
      }
      const r = await as(admin).get(`/customers/${cardId}/links`);
      expect(r.body.items[0]).toMatchObject({
        id: linkId,
        status: 'proposed',
        user: { id: c.userId, displayName: 'Абдыкадыров Улан', phoneMasked: `+996 7** *** *${phone.slice(-2)}` },
      });
      expect(JSON.stringify(r.body)).not.toContain(phone);
      expect(validateAgainst('CustomersLinksResponse', r.body)).toEqual([]);
      const seller = await t.actor({ role: 'seller' });
      expect((await as(seller).get(`/customers/${cardId}/links`)).status).toBe(403);
      expect((await as(admin).get(`/customers/${randomUUID()}/links`)).status).toBe(404);
      expect((await as(admin).get('/customers/not-a-uuid/links')).status).toBe(400);
    });

    it('admin: ?linkStatus=proposed,conflict → карточки с links[] только в этих статусах, без сумм; курсор; иные роли → 403; неверное значение → 400', async () => {
      const r = await as(admin).get('/customers?linkStatus=proposed,conflict&limit=200');
      expect(r.status).toBe(200);
      expect(r.body.items.length).toBeGreaterThan(0);
      for (const item of r.body.items as { links: { status: string }[]; [k: string]: unknown }[]) {
        expect(item.links.length).toBeGreaterThan(0);
        for (const l of item.links) expect(['proposed', 'conflict']).toContain(l.status);
        expect(item).not.toHaveProperty('receivable');
        expect(validateAgainst('CustomersListItem', item)).toEqual([]);
      }
      expect(validateAgainst('Page', { ...r.body, items: [] })).toEqual([]);

      const onlyConflict = await as(admin).get('/customers?linkStatus=conflict');
      for (const item of onlyConflict.body.items as { links: { status: string }[] }[]) {
        for (const l of item.links) expect(l.status).toBe('conflict');
      }

      const page1 = await as(admin).get('/customers?linkStatus=proposed&limit=1');
      expect(page1.body.items).toHaveLength(1);
      expect(page1.body.hasMore).toBe(true);
      const page2 = await as(admin).get(`/customers?linkStatus=proposed&limit=1&cursor=${page1.body.nextCursor}`);
      expect(page2.body.items[0].id).not.toBe(page1.body.items[0].id);

      const cashier = await t.actor({ role: 'cashier' });
      expect((await as(cashier).get('/customers?linkStatus=proposed')).status).toBe(403);
      const cust = await t.actor({ role: 'customer' });
      expect((await as(cust).get('/customers?linkStatus=proposed')).status).toBe(403);
      const bad = await as(admin).get('/customers?linkStatus=confirmed');
      expect(bad.status).toBe(400);
      expect(bad.body.errors[0]).toMatchObject({ field: 'linkStatus', rule: 'enum' });
      expect((await as(admin).get('/customers?linkStatus=proposed&limit=0')).status).toBe(400);
    });
  });

  it('экспорт OpenAPI маршрутов RM-D-005/RM-D-015 ⊆ контракт (RM-C-005 п. 5); 405-обработчик в экспорт не входит', () => {
    const exported = buildOpenApiDocument(t.app).document as unknown as {
      paths?: Record<string, Record<string, unknown>>;
    };
    const norm = (p: string) => p.replace(/\{[^}]+\}/g, '{}');
    const paths = (contract() as unknown as { paths: Record<string, Record<string, unknown>> }).paths;
    const contractOps = new Set(
      Object.entries(paths).flatMap(([p, ops]) => Object.keys(ops).map((m) => `${m.toUpperCase()} ${norm(p)}`)),
    );
    const methods = new Set(['get', 'post', 'put', 'patch', 'delete']);
    const exportedOps = Object.entries(exported.paths ?? {}).flatMap(([p, ops]) =>
      Object.keys(ops)
        .filter((m) => methods.has(m))
        .map((m) => `${m.toUpperCase()} ${norm(p)}`),
    );
    expect(exportedOps).toEqual(
      expect.arrayContaining([
        'GET /registration/customer-match',
        'POST /registration/customer-match/confirm',
        'POST /registration/customer-match/reject',
        'GET /customers/{}/links',
        'POST /customers/{}/links/{}/confirm',
        'POST /customers/{}/links/{}/reject',
        'GET /customers',
        'GET /settings/public',
      ]),
    );
    expect(exportedOps.filter((op) => !contractOps.has(op))).toEqual([]);
  });

  it('T-SEC-029: журнал: полные номера телефонов и токены не пишутся (11 SEC-062)', () => {
    expect(t.logs.text).not.toMatch(/\+99677\d{7}/);
    expect(t.logs.text).not.toMatch(/eyJ[A-Za-z0-9_-]{10,}\./);
  });
});
