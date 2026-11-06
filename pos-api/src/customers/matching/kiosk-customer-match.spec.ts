import { randomUUID } from 'node:crypto';
import { KIOSK_CUSTOMER_MATCH_VALUES } from '../../common/enums.js';
import type { CardLinkFacts, CustomerCardRow, CustomerLinksRepository } from '../links/customer-links.repository.js';
import type {
  CustomerMatching,
  CustomerMatchResult,
  FindByPhoneOptions,
  MatchCandidate,
} from './customer-matching.port.js';
import {
  classifyKioskMatch,
  KioskCustomerMatcher,
  type KioskMatchDecision,
  type KioskMatchInput,
} from './kiosk-customer-match.js';

/**
 * 10 KIOSK-014 (AC-KIOSK-014), P-002 §8.6, 05 ONEC-110, 11 SEC-130 «Планшет магазина»; решения Р-04 (а), Р-23 (а):
 * классификатор без БД — таблица §8.6 по признакам карточки и привязок, отказ по умолчанию (`ambiguous`), правило
 * реплики Q-347; поиск вне транзакции (без исполнителя), карточка читается только при одном кандидате.
 * Сценарии на реплике и фейке 1С — test/customers/kiosk-customer-match.spec.ts (T-KIOSK-019, -020, -021, -038).
 */
const PHONE = '+996555000101';
const OTHER = '+996555000102';
const NO_LINKS: CardLinkFacts = { confirmedUserPhones: [], hasOpenConflict: false };

/** Карточка из полной синхронизации 1С: физлицо, основной телефон — `PHONE` (тестовые данные). */
function card(over: Partial<CustomerCardRow> = {}): CustomerCardRow {
  return {
    id: randomUUID(),
    name: 'Тестов Тест',
    customerType: 'individual',
    onecRef: randomUUID(),
    onecCode: 'T-0001',
    source: 'onec',
    onecStatus: 'n_a',
    primaryPhoneE164: PHONE,
    phonesNorm: [PHONE],
    inn: null,
    isRetailDefault: false,
    creditAllowed: false,
    syncedAt: new Date('2026-11-01T00:00:00Z'),
    ...over,
  };
}

function single(
  row: CustomerCardRow,
  links: CardLinkFacts = NO_LINKS,
  kind: MatchCandidate['matchKind'] = 'primary',
): KioskMatchInput {
  return {
    phoneE164: PHONE,
    candidates: [{ customerId: row.id, matchKind: kind, onecRef: row.onecRef }],
    card: { row, links },
  };
}

const ambiguous = (reason: KioskMatchDecision['reason']) => ({ customerId: null, match: 'ambiguous', reason });

describe('KIOSK-014 classifyKioskMatch: таблица P-002 §8.6', () => {
  it('итоги — ровно перечень kiosk_customer_match контракта (07 §6.1.1)', () => {
    expect([...KIOSK_CUSTOMER_MATCH_VALUES]).toEqual(['single', 'ambiguous', 'none']);
  });

  it('T-KIOSK-019 одна карточка физлица из полной синхронизации, номер — основной → single на эту карточку', () => {
    const row = card();
    expect(classifyKioskMatch(single(row))).toEqual({ customerId: row.id, match: 'single', reason: 'matched' });
    const ip = card({ customerType: 'entrepreneur' });
    expect(classifyKioskMatch(single(ip)).match).toBe('single');
    // Подтверждённая привязка к пользователю с тем же номером — тот же человек: заявку на карточку не запрещает.
    expect(classifyKioskMatch(single(row, { confirmedUserPhones: [PHONE], hasOpenConflict: false })).match).toBe(
      'single',
    );
  });

  it('T-KIOSK-020 карточек нет → none; несколько → ambiguous; карточка не читается', () => {
    expect(classifyKioskMatch({ phoneE164: PHONE, candidates: [] })).toEqual({
      customerId: null,
      match: 'none',
      reason: 'no_cards',
    });
    const a = card();
    const b = card();
    expect(
      classifyKioskMatch({
        phoneE164: PHONE,
        candidates: [
          { customerId: a.id, matchKind: 'primary', onecRef: a.onecRef },
          { customerId: b.id, matchKind: 'secondary', onecRef: b.onecRef },
        ],
        card: { row: a, links: NO_LINKS },
      }),
    ).toEqual(ambiguous('several_cards'));
  });

  it('T-KIOSK-020 номер не основной: второй контакт, только ответ 1С, основной контакт ≠ primary_phone → ambiguous', () => {
    const second = card({ primaryPhoneE164: OTHER, phonesNorm: [OTHER, PHONE] });
    expect(classifyKioskMatch(single(second, NO_LINKS, 'secondary'))).toEqual(ambiguous('not_primary_phone'));
    // Основной контакт customer_contacts при другом primary_phone_e164 (поиск отметил primary).
    expect(classifyKioskMatch(single(second, NO_LINKS, 'primary'))).toEqual(ambiguous('not_primary_phone'));
    // Полная карточка, найденная только ответом 1С (реплика с устаревшим телефоном).
    expect(classifyKioskMatch(single(card(), NO_LINKS, 'onec'))).toEqual(ambiguous('not_primary_phone'));
  });

  it('T-KIOSK-020 verified=false (Р-23 (а)): карточка POS, без synced_at или без onec_ref → ambiguous', () => {
    for (const row of [
      card({ source: 'pos', onecStatus: 'confirmed' }),
      card({ syncedAt: null }),
      card({ onecRef: null }),
    ]) {
      expect(classifyKioskMatch(single(row))).toEqual(ambiguous('phone_not_verified'));
    }
  });

  it('Q-347: строка реплики только из живого поиска 1С (legal, без synced_at) single не даёт', () => {
    const stub = card({ customerType: 'legal', syncedAt: null, onecCode: null });
    expect(classifyKioskMatch(single(stub, NO_LINKS, 'onec')).match).toBe('ambiguous');
  });

  it('T-KIOSK-038 юрлицо (Р-04 (а)) и привязка к пользователю с другим телефоном → ambiguous', () => {
    expect(classifyKioskMatch(single(card({ customerType: 'legal' })))).toEqual(ambiguous('legal_entity'));
    const row = card();
    expect(classifyKioskMatch(single(row, { confirmedUserPhones: [OTHER], hasOpenConflict: false }))).toEqual(
      ambiguous('linked_to_other_phone'),
    );
    expect(classifyKioskMatch(single(row, { confirmedUserPhones: [PHONE, OTHER], hasOpenConflict: false }))).toEqual(
      ambiguous('linked_to_other_phone'),
    );
    // Пользователь без телефона — «другой телефон» (отказ по умолчанию).
    expect(classifyKioskMatch(single(row, { confirmedUserPhones: [null], hasOpenConflict: false }))).toEqual(
      ambiguous('linked_to_other_phone'),
    );
  });

  it('KIOSK-014 открытый conflict привязки и признак дубля → ambiguous', () => {
    expect(classifyKioskMatch(single(card(), { confirmedUserPhones: [], hasOpenConflict: true }))).toEqual(
      ambiguous('link_conflict'),
    );
    expect(classifyKioskMatch(single(card({ onecStatus: 'duplicate' })))).toEqual(ambiguous('duplicate'));
  });

  it('отказ по умолчанию: снимка карточки нет или он другой карточки → ambiguous', () => {
    const row = card();
    expect(
      classifyKioskMatch({
        phoneE164: PHONE,
        candidates: [{ customerId: row.id, matchKind: 'primary', onecRef: row.onecRef }],
      }),
    ).toEqual(ambiguous('card_missing'));
    expect(
      classifyKioskMatch({
        phoneE164: PHONE,
        candidates: [{ customerId: randomUUID(), matchKind: 'primary', onecRef: null }],
        card: { row, links: NO_LINKS },
      }),
    ).toEqual(ambiguous('card_missing'));
  });

  it('другой номер кода — не основной телефон карточки → ambiguous', () => {
    const row = card();
    expect(classifyKioskMatch({ ...single(row), phoneE164: OTHER })).toEqual(ambiguous('not_primary_phone'));
  });
});

describe('KIOSK-014 KioskCustomerMatcher: поиск вне транзакции, без записей', () => {
  class FakeMatching implements CustomerMatching {
    calls: { phone: string; options: FindByPhoneOptions | undefined }[] = [];
    constructor(private readonly result: CustomerMatchResult) {}
    findByPhone(phone: string, options?: FindByPhoneOptions): Promise<CustomerMatchResult> {
      this.calls.push({ phone, options });
      return Promise.resolve(this.result);
    }
  }

  function repo(rows: CustomerCardRow[], links: CardLinkFacts = NO_LINKS) {
    const calls: string[] = [];
    const fake = {
      findCard: (id: string) => {
        calls.push(`findCard:${id}`);
        return Promise.resolve(rows.find((r) => r.id === id));
      },
      linkFactsForCard: (id: string) => {
        calls.push(`linkFactsForCard:${id}`);
        return Promise.resolve(links);
      },
    };
    return { calls, repo: fake as unknown as CustomerLinksRepository };
  }

  it('один кандидат: findByPhone без исполнителя и без useOnec, с requestId; затем карточка и привязки', async () => {
    const row = card();
    const m = new FakeMatching({
      candidates: [{ customerId: row.id, matchKind: 'primary', onecRef: row.onecRef }],
      onec: 'ok',
    });
    const r = repo([row]);
    const res = await new KioskCustomerMatcher(m, r.repo).matchKioskCustomer(PHONE, { requestId: 'req-kiosk-1' });
    expect(res).toEqual({ customerId: row.id, match: 'single', reason: 'matched', onec: 'ok' });
    expect(m.calls).toEqual([{ phone: PHONE, options: { requestId: 'req-kiosk-1' } }]);
    expect(r.calls).toEqual([`findCard:${row.id}`, `linkFactsForCard:${row.id}`]);
  });

  it('T-KIOSK-021 1С недоступна → решение по реплике, onec=unavailable в итоге', async () => {
    const row = card();
    const m = new FakeMatching({
      candidates: [{ customerId: row.id, matchKind: 'primary', onecRef: row.onecRef }],
      onec: 'unavailable',
    });
    const res = await new KioskCustomerMatcher(m, repo([row]).repo).matchKioskCustomer(PHONE);
    expect(res).toMatchObject({ customerId: row.id, match: 'single', onec: 'unavailable' });
    expect(m.calls[0].options).toEqual({});
  });

  it('0 и ≥ 2 кандидатов — карточка не читается; карточка удалена после поиска → ambiguous', async () => {
    const none = repo([]);
    expect(
      await new KioskCustomerMatcher(new FakeMatching({ candidates: [], onec: 'ok' }), none.repo).matchKioskCustomer(
        PHONE,
      ),
    ).toEqual({ customerId: null, match: 'none', reason: 'no_cards', onec: 'ok' });
    const a = card();
    const b = card();
    const two = repo([a, b]);
    const res = await new KioskCustomerMatcher(
      new FakeMatching({
        candidates: [
          { customerId: a.id, matchKind: 'primary', onecRef: a.onecRef },
          { customerId: b.id, matchKind: 'primary', onecRef: b.onecRef },
        ],
        onec: 'disabled',
      }),
      two.repo,
    ).matchKioskCustomer(PHONE);
    expect(res).toEqual({ customerId: null, match: 'ambiguous', reason: 'several_cards', onec: 'disabled' });
    expect([...none.calls, ...two.calls]).toEqual([]);
    const gone = repo([]);
    const id = randomUUID();
    expect(
      await new KioskCustomerMatcher(
        new FakeMatching({ candidates: [{ customerId: id, matchKind: 'primary', onecRef: null }], onec: 'ok' }),
        gone.repo,
      ).matchKioskCustomer(PHONE),
    ).toMatchObject({ customerId: null, match: 'ambiguous', reason: 'card_missing' });
    expect(gone.calls).toEqual([`findCard:${id}`]);
  });

  it('номер не E.164 → RangeError до поиска (1С не вызывается)', async () => {
    const m = new FakeMatching({ candidates: [], onec: 'ok' });
    for (const bad of ['0555000101', '+7999000101', '', '+996 555 000 101']) {
      await expect(new KioskCustomerMatcher(m, repo([]).repo).matchKioskCustomer(bad)).rejects.toBeInstanceOf(
        RangeError,
      );
    }
    expect(m.calls).toEqual([]);
  });
});
