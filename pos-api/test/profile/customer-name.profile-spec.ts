import * as common from '../../src/common/presenters/customer-name.js';
import * as customers from '../../src/customers/links/customer-link.presenter.js';
import { type CustomerMatchView, toMeCustomerLink } from '../../src/profile/customer-link.reader.js';

/**
 * D PR-09 (бэклог E_spec_sync.md §3): одна карточка 1С — одна форма имени. `Me.customerLink` (profile) и
 * `RegistrationCustomerMatch` / `Customer.displayName` (customers) строятся по общим правилам
 * `common/presenters/customer-name.ts`: `displayName` — значимая часть без формы собственности и кавычек (08 §3.7),
 * `displayNameMasked` — форма + 3 символа + `***` (08 §4.2.2).
 */
const NAMES = [
  'ОсОО «Стройснаб»',
  'ОсОО "Тест-Строй"',
  'ОсОО«Бетонстрой»',
  'ИП Асанов Бакыт',
  'Асанов Бакыт',
  'ОАО  «Кыргызтелеком»',
  'ЧП Ли',
  'ОсОО',
  'Ли',
  '  «Цитата» ',
  'КХ «Ак-Суу»',
  'ОсДО «Мега»',
];

describe('PR-09: единый presenter наименования карточки клиента (profile ↔ customers)', () => {
  it('displayName и displayNameMasked совпадают с правилами модуля customers на наборе форм', () => {
    for (const n of NAMES) {
      expect(common.customerDisplayName(n), n).toBe(customers.customerDisplayName(n));
      expect(common.maskCustomerName(n), n).toBe(customers.maskCustomerName(n));
      expect(common.parseCustomerName(n), n).toEqual(customers.parseCustomerName(n));
    }
    expect(common.customerDisplayName('ОсОО «Неизменный»')).toBe('Неизменный');
    expect(common.maskCustomerName('ОсОО «Стройснаб»')).toBe('ОсОО «Стр***»');
  });

  it('Me.customerLink при confirmed отдаёт displayName по 08 §3.7, до confirmed — только маску', () => {
    const confirmed: CustomerMatchView = {
      status: 'confirmed',
      linkId: '0192f3a1-6c3e-7a1b-9f00-000000000011',
      customer: {
        displayNameMasked: common.maskCustomerName('ОсОО «Бетонстрой»'),
        id: '0192f3a1-6c3e-7a1b-9f00-000000000012',
        displayName: common.customerDisplayName('ОсОО «Бетонстрой»'),
      },
      nextStep: 'confirmed',
    };
    expect(toMeCustomerLink(confirmed)).toEqual({
      linkId: confirmed.linkId,
      status: 'confirmed',
      displayNameMasked: 'ОсОО «Бет***»',
      customerId: '0192f3a1-6c3e-7a1b-9f00-000000000012',
      displayName: 'Бетонстрой',
    });
    const proposed = toMeCustomerLink({
      status: 'proposed',
      linkId: confirmed.linkId,
      customer: { displayNameMasked: 'ОсОО «Бет***»', id: 'x', displayName: 'Бетонстрой' },
      nextStep: 'wait_admin',
    });
    expect(proposed).toEqual({ linkId: confirmed.linkId, status: 'proposed', displayNameMasked: 'ОсОО «Бет***»' });
  });
});
