import { PDFParse } from 'pdf-parse';
import { Money } from '../../src/common/money/money.js';
import {
  invoiceModel,
  type OrderDocRow,
  type OrderItemDocRow,
  receiptModel,
  type ReceivedPaymentRow,
} from '../../src/orders/documents/document-model.js';
import { defaultDocumentAssets } from '../../src/orders/documents/documents-assets.js';
import { PdfRenderer } from '../../src/orders/documents/pdf/pdf-renderer.js';
import { PdfTemplateStore } from '../../src/orders/documents/pdf/pdf-template.js';

/**
 * RM-F-004 критерий 1 (snapshot-тест PDF: «текст извлекается `pdf-parse`»): счёт и товарный чек (A4 и 80 мм)
 * рендерятся `PdfRenderer` и читаются независимой библиотекой `pdf-parse` (pdf.js), а не разборщиком тестов
 * `support/pdf-text.ts`: номер документа, клиент, строки, суммы и их арифметика (Σ строк = итог; подытог − скидка =
 * итог; получено − итог = сдача), пометка «Нефискальный документ» (критерий 2) и время генерации ≤ 2 с (критерий 3).
 * **Тестовые данные** — макет корзины 10 §0: 16 850,00 − 5 % (842,50) = 16 007,50 сом.
 */
const assets = defaultDocumentAssets();
const store = new PdfTemplateStore(assets.templatesDir);
const renderer = new PdfRenderer({ regular: assets.fontRegular, bold: assets.fontBold });

const ORDER: OrderDocRow = {
  id: '01900000-0000-7000-8000-000000000001',
  publicNumber: 'POS-2026-000123',
  status: 'awaiting_payment',
  onecNumber: 'ОС00-004512',
  onecDate: new Date('2026-10-21T07:40:00Z'),
  createdAt: new Date('2026-10-21T07:35:00Z'),
  updatedAt: new Date('2026-10-21T07:41:00Z'),
  rowVersion: 3,
  paymentMethod: 'cash',
  creditDueDate: null,
  subtotal: '16850.00',
  discountTotal: '842.50',
  customerDiscountTotal: '0.00',
  manualDiscountTotal: '842.50',
  discountPercent: '5.00',
  customerDiscountPercent: null,
  total: '16007.50',
  customerName: 'ОсОО «Сантехмонтаж»',
  customerInn: '01234567890123',
  createdById: '01900000-0000-7000-8000-000000000099',
};

const LINES: readonly (readonly [string, string, string, string, string, string, string, string])[] = [
  ['Смеситель для раковины «Аква»', 'SM-100', '2', 'шт', '3250.00', '6500.00', '325.00', '6175.00'],
  ['Труба ПП 20 мм', 'TR-20', '10', 'м', '85.00', '850.00', '42.50', '807.50'],
  ['Унитаз компакт «Нева»', 'UN-7', '1', 'шт', '7400.00', '7400.00', '370.00', '7030.00'],
  ['Кран шаровой', 'KR-12', '4', 'шт', '275.00', '1100.00', '55.00', '1045.00'],
  ['Герметик силиконовый 280 мл', 'GS-280', '2', 'шт', '500.00', '1000.00', '50.00', '950.00'],
];
const ITEMS: OrderItemDocRow[] = LINES.map(
  ([productName, sku, quantity, unit, unitPrice, lineSubtotal, discountAmount, lineTotal], i) => ({
    lineNo: i + 1,
    productName,
    variantName: null,
    packagingName: null,
    sku,
    quantity,
    unit,
    unitPrice,
    lineSubtotal,
    discountAmount,
    lineTotal,
  }),
);
const CASH: ReceivedPaymentRow[] = [
  {
    id: '01900000-0000-7000-8000-000000000201',
    method: 'cash',
    amount: '16007.50',
    receivedAmount: '16100.00',
    changeAmount: '92.50',
    receivedAt: new Date('2026-10-21T07:45:00Z'),
    receivedByName: 'Айгуль К.',
  },
];
const SELLER = { name: 'ОсОО «Оптомстрой» (тест)', inn: '02109200610045', address: 'г. Бишкек, ул. Тестовая, 1' };

/** Текст PDF через pdf-parse; пробелы (в т. ч. неразрывные) схлопываются — сравнение без учёта переносов. */
async function extract(bytes: Buffer): Promise<{ text: string; flat: string; pages: number }> {
  const parser = new PDFParse({ data: new Uint8Array(bytes) });
  try {
    const r = await parser.getText();
    const text = r.text.replaceAll(String.fromCharCode(0xa0), ' ');
    return { text, flat: text.replace(/\s+/g, ''), pages: r.total };
  } finally {
    await parser.destroy();
  }
}

/** Каноническая строка суммы `Money` («16007.50»). */
const money = (s: string): string => Money.of(s).toString();
/** Сумма, как её печатает форма, без пробелов-разделителей тысяч: «16 007,50» → «16007,50». */
const printed = (amount: string): string => Money.of(amount).toString().replace('.', ',');

describe('RM-F-004: печатные формы читаются pdf-parse (номер, клиент, строки, суммы, нефискальность)', () => {
  // 12: T-ORD-027 (итог в PDF счёта = итог заказа)
  it('счёт A4: номер 1С, клиент, все строки, Σ строк = итог, подытог − скидка = итог', async () => {
    const started = Date.now();
    const pdf = await renderer.render(store.get('invoice', 'a4'), invoiceModel(ORDER, SELLER, ITEMS, false), {
      creationDate: ORDER.createdAt,
      title: 'Счёт на оплату',
    });
    expect(Date.now() - started).toBeLessThanOrEqual(2000);
    const p = await extract(pdf.bytes);
    expect(p.pages).toBe(1);
    expect(p.flat).toContain('ОС00-004512');
    expect(p.flat).toContain('ОсОО«Сантехмонтаж»'.replace(/\s+/g, ''));
    for (const [name, sku, , , , , , lineTotal] of LINES) {
      expect(p.flat).toContain(name.replace(/\s+/g, ''));
      expect(p.flat).toContain(sku);
      expect(p.flat).toContain(printed(lineTotal));
    }
    // Арифметика по данным, которые напечатаны (D-19: decimal, не float).
    const sumLines = LINES.reduce((acc, l) => acc.plus(Money.of(l[7])), Money.ZERO);
    expect(sumLines.toString()).toBe(money(ORDER.total));
    expect(Money.of(ORDER.subtotal).minus(Money.of(ORDER.discountTotal)).toString()).toBe(money(ORDER.total));
    expect(p.flat).toContain(printed(ORDER.subtotal));
    expect(p.flat).toContain(printed(ORDER.discountTotal));
    expect(p.flat).toContain(printed(ORDER.total));
    expect(p.text).toMatch(/не является фискальным/i);
  });

  it('товарный чек 80 мм: «Нефискальный документ», получено − итог = сдача, ≤ 2 с', async () => {
    const started = Date.now();
    const pdf = await renderer.render(
      store.get('receipt', 'thermal80'),
      receiptModel(ORDER, SELLER, ITEMS, CASH, false),
      { creationDate: ORDER.createdAt, title: 'Товарный чек' },
    );
    expect(Date.now() - started).toBeLessThanOrEqual(2000);
    const p = await extract(pdf.bytes);
    expect(p.text).toContain('Нефискальный документ');
    expect(p.flat).toContain('ТОВАРНЫЙЧЕК№ОС00-004512');
    for (const [name] of LINES) expect(p.flat).toContain(name.replace(/\s+/g, ''));
    const pay = CASH[0];
    expect(Money.of(pay.receivedAmount!).minus(Money.of(ORDER.total)).toString()).toBe(money(pay.changeAmount!));
    expect(p.flat).toContain(`Получено${printed(pay.receivedAmount!)}`);
    expect(p.flat).toContain(`Сдача${printed(pay.changeAmount!)}`);
    expect(p.flat).toContain(`ИТОГО${printed(ORDER.total)}`);
  });

  it('товарный чек A4: тот же текст при повторном рендере (детерминизм — snapshot по тексту)', async () => {
    const render = () =>
      renderer.render(store.get('receipt', 'a4'), receiptModel(ORDER, SELLER, ITEMS, CASH, false), {
        creationDate: ORDER.createdAt,
        title: 'Товарный чек',
      });
    const [a, b] = await Promise.all([render(), render()]);
    expect(a.sha256).toBe(b.sha256);
    const ta = await extract(a.bytes);
    expect(ta.text).toContain('Нефискальный документ');
    expect(ta.flat).toContain(printed(ORDER.total));
    expect((await extract(b.bytes)).text).toBe(ta.text);
  });
});
