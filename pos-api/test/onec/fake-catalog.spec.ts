import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import {
  ean13,
  isValidEan13,
  SYNTHETIC_ANCHORS,
  SyntheticCatalog,
} from '../../src/integrations/onec/synthetic-catalog.js';

describe('SyntheticCatalog — детерминированный синтетический каталог (тестовые данные)', () => {
  it('одинаковые параметры → одинаковый каталог; другой seed — другие ссылки', () => {
    const a = new SyntheticCatalog({ skuCount: 500, seed: 7 });
    const b = new SyntheticCatalog({ skuCount: 500, seed: 7 });
    const c = new SyntheticCatalog({ skuCount: 500, seed: 8 });
    expect(JSON.stringify(a.allItems())).toBe(JSON.stringify(b.allItems()));
    expect(JSON.stringify(a.priceSlice())).toBe(JSON.stringify(b.priceSlice()));
    expect(JSON.stringify(a.stockSlice())).toBe(JSON.stringify(b.stockSlice()));
    expect(a.productItems()[10].ref).not.toBe(c.productItems()[10].ref);
  });

  it('состав: дерево категорий, варианты с атрибутами, единицы, упаковки с кратностью, EAN-13, склады, виды цен, цены, остатки, резервы, deletion_mark', () => {
    const cat = new SyntheticCatalog({ skuCount: 2000, seed: 1 });
    const s = cat.stats();
    expect(s.products).toBe(2000);
    expect(s.warehouses).toBe(3);
    expect(s.priceLists).toBe(3);
    expect(s.units).toBe(8);
    expect(s.categories).toBeGreaterThan(40);
    expect(s.variants).toBeGreaterThan(200);
    expect(s.packagings).toBeGreaterThan(300);
    expect(s.productsDeleted).toBeGreaterThan(0);
    // Дерево: у дочерних групп родитель — группа каталога.
    const refs = new Set(cat.categories.map((c) => c.ref));
    expect(cat.categories.filter((c) => c.parentRef).every((c) => refs.has(c.parentRef!))).toBe(true);
    expect(
      cat.categories.some((c) => c.parentRef && cat.categories.find((p) => p.ref === c.parentRef)?.parentRef),
    ).toBe(true);
    // Штрихкоды EAN-13 с верной контрольной цифрой, уникальны.
    const codes = cat.barcodes().map((b) => b.barcode);
    expect(codes.every(isValidEan13)).toBe(true);
    expect(new Set(codes).size).toBe(codes.length);
    // Варианты несут атрибут оси (Цвет/Размер); упаковки — коэффициент > 1 в формате 0.000.
    expect(cat.variants().every((v) => (v.attributes ?? []).length === 1)).toBe(true);
    expect(cat.packagings().every((p) => /^\d+\.000$/.test(p.factor) && Number.parseInt(p.factor, 10) > 1)).toBe(true);
    // Деньги — строки с 2 знаками, количества — с 3; есть резервы и строки без available (вычисляет БД).
    expect(cat.priceSlice().every((p) => /^\d+\.\d{2}$/.test(p.price))).toBe(true);
    expect(cat.stockSlice().every((r) => /^\d+\.\d{3}$/.test(r.onHand) && /^\d+\.\d{3}$/.test(r.reserved))).toBe(true);
    expect(cat.stockSlice().some((r) => r.reserved !== '0.000')).toBe(true);
    expect(cat.stockSlice().some((r) => r.available === null)).toBe(true);
    // Якорные товары для тестов поиска.
    for (const a of SYNTHETIC_ANCHORS)
      expect(cat.productItems().some((p) => p.sku === a.sku && p.description === a.name)).toBe(true);
  });

  it('ean13: контрольная цифра', () => {
    expect(ean13('460123456789')).toBe('4601234567893');
    expect(isValidEan13('4601234567893')).toBe(true);
    // Прежний штрихкод фикстур 1.0.0 («4600000000017») — с неверной контрольной цифрой (тип `other`);
    // с контракта 1.1.0 фикстуры используют «4600000000015» (ТЗ для 1С §5.4).
    expect(isValidEan13('4600000000017')).toBe(false);
    expect(isValidEan13('4600000000015')).toBe(true);
  });

  it('50 000 SKU генерируются в памяти за секунды (вход бенчмарка RM-E-005)', () => {
    const t0 = performance.now();
    const cat = new SyntheticCatalog({ skuCount: 50_000, seed: 1 });
    const ms = performance.now() - t0;
    const s = cat.stats();
    expect(s.products).toBe(50_000);
    expect(s.barcodes).toBeGreaterThan(50_000);
    expect(ms).toBeLessThan(20_000);
  });
});

describe('FakeOnecGateway в режиме каталога — модель плана обмена «POS» (05 §6.2)', () => {
  // 12 T-ONEC-004 (модель плана обмена: страницы, повтор без ack, ack)
  it('сообщение N+1 постранично (cursor), ack снимает регистрации ≤ N+1; повтор без ack выдаёт то же сообщение', async () => {
    const gw = new FakeOnecGateway({ catalog: { skuCount: 30, seed: 3 } });
    const p1 = await gw.getChanges({ since: 0, limit: 50 });
    expect(p1.body.messageNumber).toBe(1);
    expect(p1.body.hasMore).toBe(true);
    let total = p1.body.items.length;
    let cursor = p1.body.cursor;
    while (cursor) {
      const p = await gw.getChanges({ since: 0, limit: 50, cursor });
      expect(p.body.messageNumber).toBe(1);
      total += p.body.items.length;
      cursor = p.body.cursor;
    }
    expect(total).toBe(gw.catalog!.allItems().length);
    // Без ack — то же сообщение с начала.
    const again = await gw.getChanges({ since: 0, limit: 50 });
    expect(again.body.messageNumber).toBe(1);
    expect(again.body.items[0]).toEqual(p1.body.items[0]);
    // ack номера больше выданного → 409.
    await expect(gw.ackChanges(2)).rejects.toMatchObject({ code: 'POS_E_ACK_OUT_OF_ORDER', status: 409 });
    const ack = await gw.ackChanges(1);
    expect(ack.body.removedRegistrations).toBe(total);
    expect((await gw.getHealth()).body.lastAckMessageNumber).toBe(1);
    const empty = await gw.getChanges({ since: 1 });
    expect(empty.body.items).toHaveLength(0);
  });

  it('изменения следующей версии регистрируются; документ установки цен — с затронутыми видами цен', async () => {
    const gw = new FakeOnecGateway({ catalog: { skuCount: 30, seed: 3 }, registerAll: false });
    const r = gw.mutateCatalog({ renameProducts: 1, repricePrices: 2 });
    expect(r.priceListRefs.length).toBeGreaterThan(0);
    const page = await gw.getChanges({ since: 10 });
    expect(page.body.messageNumber).toBe(11);
    const types = page.body.items.map((i) => i.type).sort();
    expect(types).toEqual(['Catalog_Номенклатура', 'Document_УстановкаЦенНоменклатуры']);
    const doc = page.body.items.find((i) => i.type === 'Document_УстановкаЦенНоменклатуры')!;
    expect(doc.priceListRefs).toEqual(r.priceListRefs);
  });

  it('карточка товара из каталога; неизвестная ссылка → 404; инъекция ошибки страницы', async () => {
    const gw = new FakeOnecGateway({ catalog: { skuCount: 5, seed: 1 }, includeFixtureCatalog: true });
    const card = await gw.getCatalogCard('a1b2c3d4-0000-4000-8000-000000000001');
    expect((card.body.prices as unknown[]).length).toBe(3);
    await expect(gw.getCatalogCard('a1b2c3d4-0000-4000-8000-0000000009ff')).rejects.toMatchObject({
      code: 'POS_E_NOT_FOUND',
    });
    gw.exchange!.injectError(1, new OnecError('getChanges', 503, 'POS_E_MAINTENANCE', 'тест'));
    await expect(gw.getChanges({ since: 0 })).rejects.toMatchObject({ code: 'POS_E_MAINTENANCE' });
    expect((await gw.getChanges({ since: 0 })).status).toBe(200);
  });

  it('режим без каталога не изменился: статические фикстуры страниц 1–2 (RM-C-008)', async () => {
    const gw = new FakeOnecGateway();
    const p1 = await gw.getChanges({ since: 5120 });
    expect(p1.body.messageNumber).toBe(5121);
    expect(gw.catalog).toBeUndefined();
  });
});
