import {
  customerDisplayName,
  isPhoneVerified,
  maskCustomerName,
  parseCustomerName,
} from '../../src/customers/links/customer-link.presenter.js';
import type { CustomerCardRow } from '../../src/customers/links/customer-links.repository.js';
import { decodeCursor, encodeCursor } from '../../src/customers/links/customer-links.service.js';
import { camelProjection } from '../../src/settings/public-settings.map.js';

describe('RM-D-005 представление привязки (08 §4.2.2 displayNameMasked, §3.7 displayName, phones[].verified)', () => {
  it('маска: форма собственности + первые 3 символа значимой части + *** (ОсОО «Стр***»)', () => {
    expect(maskCustomerName('ОсОО «Стройснаб»')).toBe('ОсОО «Стр***»');
    expect(maskCustomerName('ИП Асанов Бакыт')).toBe('ИП Аса***');
    expect(maskCustomerName('Асанов Бакыт')).toBe('Аса***');
    expect(maskCustomerName('ОсОО "Тест-Строй"')).toBe('ОсОО «Тес***»');
    expect(maskCustomerName('Ли')).toBe('Ли***');
  });

  it('displayName — без формы собственности и кавычек', () => {
    expect(customerDisplayName('ОсОО «Тестовый клиент»')).toBe('Тестовый клиент');
    expect(customerDisplayName('Асанов Бакыт')).toBe('Асанов Бакыт');
    expect(parseCustomerName('ОсОО').form).toBeNull();
  });

  it('verified: только основной телефон карточки 1С из полной синхронизации', () => {
    const base: CustomerCardRow = {
      id: '0192e0b2-0000-7000-8000-000000000001',
      name: 'Асанов Бакыт',
      customerType: 'individual',
      onecRef: '8d2e0000-0000-0000-0000-000000000001',
      onecCode: '00-1',
      source: 'onec',
      onecStatus: 'n_a',
      primaryPhoneE164: '+996700123456',
      phonesNorm: ['+996700123456', '+996555000001'],
      inn: null,
      isRetailDefault: false,
      creditAllowed: false,
      syncedAt: new Date(),
    };
    expect(isPhoneVerified(base, '+996700123456')).toBe(true);
    expect(isPhoneVerified(base, '+996555000001')).toBe(false);
    expect(isPhoneVerified({ ...base, source: 'pos' }, '+996700123456')).toBe(false);
    expect(isPhoneVerified({ ...base, syncedAt: null }, '+996700123456')).toBe(false);
  });

  it('курсор очереди: base64url {c: uuid}; мусор → 400 VALIDATION_FAILED', () => {
    const id = '0192e0b2-0000-7000-8000-000000000001';
    expect(decodeCursor(encodeCursor(id))).toBe(id);
    expect(() => decodeCursor('not-a-cursor')).toThrow();
  });

  it('camelCase-проекция ключей app_settings (ядро §19.2): каждый сегмент отдельно', () => {
    expect(camelProjection('receivables.max_age_minutes')).toBe('receivables.maxAgeMinutes');
    expect(camelProjection('sync_interval.stock')).toBe('syncInterval.stock');
    expect(camelProjection('qr.enabled')).toBe('qr.enabled');
    expect(camelProjection('low_stock_threshold')).toBe('lowStockThreshold');
  });
});
