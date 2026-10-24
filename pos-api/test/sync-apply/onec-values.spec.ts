import {
  attributeCode,
  attributeValueType,
  barcodeType,
  canonicalJson,
  milliToNumeric,
  moneyToTyiyn,
  onecRef,
  OnecValueError,
  qtyToMilli,
  sourceHash,
  tyiynToNumeric,
  unitPrecision,
} from '../../src/sync/apply/onec-values.js';

describe('Значения 1С → реплика: деньги/количества без float, ссылки, хэш, штрихкоды (RM-E-001)', () => {
  // 12 T-ONEC-017 (деньги — строки), T-SYNC-014 (цена с 3 знаками → ошибка позиции)
  it('деньги: строка 1С → тыйыны (bigint) → NUMERIC(14,2); больше 2 знаков и мусор — ошибка позиции', () => {
    expect(moneyToTyiyn('2350.00')).toBe(235000n);
    expect(moneyToTyiyn('0.1')).toBe(10n);
    expect(moneyToTyiyn('12600')).toBe(1260000n);
    expect(moneyToTyiyn(2350.5)).toBe(235050n);
    expect(tyiynToNumeric(235050n)).toBe('2350.50');
    expect(tyiynToNumeric(5n)).toBe('0.05');
    expect(tyiynToNumeric(-120n)).toBe('-1.20');
    expect(() => moneyToTyiyn('1.005')).toThrow(OnecValueError);
    expect(() => moneyToTyiyn('1e3')).toThrow(OnecValueError);
    expect(() => moneyToTyiyn('100000000000000.00')).toThrow(/NUMERIC\(14,2\)/);
    // Классическая ловушка float (0.1 + 0.2) невозможна: суммируем целые тыйыны.
    expect(tyiynToNumeric(moneyToTyiyn('0.1') + moneyToTyiyn('0.2'))).toBe('0.30');
  });

  it('количества: тысячные; формат NUMERIC(14,3)', () => {
    expect(qtyToMilli('6.000')).toBe(6000n);
    expect(qtyToMilli('-2.5')).toBe(-2500n);
    expect(milliToNumeric(14000n)).toBe('14.000');
    expect(milliToNumeric(-2500n)).toBe('-2.500');
    expect(() => qtyToMilli('0.0001')).toThrow(OnecValueError);
  });

  // 12 T-ONEC-017 (UUID в нижнем регистре)
  it('ссылки: нижний регистр, нулевая ссылка → null, не GUID — ошибка', () => {
    expect(onecRef('A1B2C3D4-0000-4000-8000-0000000000AA')).toBe('a1b2c3d4-0000-4000-8000-0000000000aa');
    expect(onecRef('00000000-0000-0000-0000-000000000000')).toBeNull();
    expect(onecRef(null)).toBeNull();
    expect(() => onecRef('not-a-guid')).toThrow(OnecValueError);
  });

  it('source_hash: канонический JSON (порядок ключей не важен), SHA-256 hex', () => {
    expect(canonicalJson({ b: 1, a: [2, { d: null, c: 'x' }] })).toBe('{"a":[2,{"c":"x","d":null}],"b":1}');
    expect(sourceHash({ a: 1, b: 2 })).toBe(sourceHash({ b: 2, a: 1 }));
    expect(sourceHash({ a: 1 })).toMatch(/^[0-9a-f]{64}$/);
    expect(sourceHash({ a: 1 })).not.toBe(sourceHash({ a: 2 }));
  });

  it('тип штрихкода по контрольной цифре; точность единицы; код свойства; тип значения', () => {
    expect(barcodeType('4601234567893')).toBe('EAN13');
    expect(barcodeType('4600000000017')).toBe('other');
    expect(barcodeType('96385074')).toBe('EAN8');
    expect(barcodeType('036000291452')).toBe('UPC');
    expect(barcodeType('ABC-123', 'Code128')).toBe('CODE128');
    expect(unitPrecision('796', 'шт')).toBe(0);
    expect(unitPrecision('006', 'м')).toBe(3);
    expect(unitPrecision(null, 'кг')).toBe(3);
    expect(attributeCode('Цвет')).toBe('tsvet');
    expect(attributeCode('Гарантия, лет')).toBe('garantiya_let');
    expect(attributeValueType('Catalog_ЗначенияСвойствОбъектов')).toBe('list');
    expect(attributeValueType('Edm.Double')).toBe('number');
    expect(attributeValueType('Edm.Boolean')).toBe('boolean');
    expect(attributeValueType(null)).toBe('text');
  });
});
