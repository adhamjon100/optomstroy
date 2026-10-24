import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  formatDate,
  formatMoney,
  formatQuantity,
  invoiceModel,
  type OrderDocRow,
  type OrderItemDocRow,
  receiptModel,
  type ReceivedPaymentRow,
} from '../../src/orders/documents/document-model.js';
import { defaultDocumentAssets } from '../../src/orders/documents/documents-assets.js';
import { PdfRenderer } from '../../src/orders/documents/pdf/pdf-renderer.js';
import { parseTemplate, PdfTemplateStore, TemplateError } from '../../src/orders/documents/pdf/pdf-template.js';
import { fill, truthy } from '../../src/orders/documents/pdf/placeholders.js';
import { parsePdf } from './support/pdf-text.js';

/**
 * RM-F-004 (unit, без БД): шаблоны печатных форм, модель документа, PdfRenderer (pdfkit + Inter), 80 мм, кириллица,
 * пометка нефискальности, детерминизм (ETag), время рендера ≤ 2 с. **Тестовые данные** — макет корзины 10 §0
 * (5 товаров на 16 850,00 сом, скидка 5 % → 842,50, итого 16 007,50).
 */
const assets = defaultDocumentAssets();
const store = new PdfTemplateStore(assets.templatesDir);
const renderer = new PdfRenderer({ regular: assets.fontRegular, bold: assets.fontBold });
/** Пробелы → неразрывные (U+00A0), как в суммах печатных форм. */
const nb = (s: string) => s.replace(/ /g, String.fromCharCode(0xa0));
const squash = (s: string) => s.replace(/\s+/g, '');
/** Перенос строки в ячейке/абзаце PDF — как пробел. */
const norm = (s: string) => s.replace(/\s+/g, ' ');

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

// Строки — тестовые данные; суммы строк сходятся в итог (коррекция в последней строке, C-CR-01).
const ITEMS: OrderItemDocRow[] = [
  ['Смеситель для раковины «Аква»', 'SM-100', '2', 'шт', '3250.00', '6500.00', '325.00', '6175.00'],
  ['Труба ПП 20 мм', 'TR-20', '10', 'м', '85.00', '850.00', '42.50', '807.50'],
  ['Унитаз компакт «Нева»', 'UN-7', '1', 'шт', '7400.00', '7400.00', '370.00', '7030.00'],
  ['Кран шаровой ½″', 'KR-12', '4', 'шт', '275.00', '1100.00', '55.00', '1045.00'],
  ['Герметик силиконовый 280 мл', 'GS-280', '2', 'шт', '500.00', '1000.00', '50.00', '950.00'],
].map(([productName, sku, quantity, unit, unitPrice, lineSubtotal, discountAmount, lineTotal], i) => ({
  lineNo: i + 1,
  productName: productName,
  variantName: null,
  packagingName: null,
  sku: sku,
  quantity: quantity,
  unit: unit,
  unitPrice: unitPrice,
  lineSubtotal: lineSubtotal,
  discountAmount: discountAmount,
  lineTotal: lineTotal,
}));

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

describe('формат денег, количеств и дат печатных форм (D-19: без float)', () => {
  it('деньги: разделитель тысяч — неразрывный пробел, запятая, знак «−»', () => {
    expect(formatMoney('16007.50')).toBe(nb('16 007,50'));
    expect(formatMoney('842.5')).toBe('842,50');
    expect(formatMoney('1234567.05')).toBe(nb('1 234 567,05'));
    expect(formatMoney('-92.50')).toBe('−92,50');
    expect(formatMoney('0')).toBe('0,00');
  });

  it('количество без лишних нулей, дата — Asia/Bishkek', () => {
    expect(formatQuantity('2.000')).toBe('2');
    expect(formatQuantity('2.500')).toBe('2,5');
    expect(formatQuantity('0.125')).toBe('0,125');
    expect(formatDate(new Date('2026-10-21T19:30:00Z'))).toBe('22.10.2026');
  });
});

describe('шаблоны печатных форм — отдельные файлы (Q-019)', () => {
  // 12: T-PRINT-008 (пометка «не является фискальным документом» во всех формах)
  it('все 4 шаблона проходят проверку и содержат пометку нефискальности', () => {
    for (const kind of ['invoice', 'receipt'] as const) {
      for (const paper of ['a4', 'thermal80'] as const) {
        const t = store.get(kind, paper);
        expect(t.kind).toBe(kind);
        expect(t.paper).toBe(paper);
        const raw = readFileSync(join(assets.templatesDir, `${kind}.${paper}.json`), 'utf8');
        expect(raw).toContain('{{nonFiscalMark}}');
        expect(raw).not.toMatch(/ККМ|онлайн-касс|фискальный чек/i);
      }
    }
    expect(store.get('receipt', 'thermal80').page.width).toBeCloseTo(226.77, 2);
    expect(store.get('receipt', 'thermal80').page.height).toBeUndefined();
  });

  it('неверный шаблон → TemplateError (неизвестный блок, доли колонок > 1)', () => {
    const base = {
      kind: 'invoice',
      paper: 'a4',
      title: 't',
      fontSize: 9,
      page: { width: 595, margins: { top: 1, right: 1, bottom: 1, left: 1 } },
    };
    expect(() => parseTemplate({ ...base, blocks: [{ type: 'image' }] }, 'x')).toThrow(TemplateError);
    expect(() =>
      parseTemplate(
        {
          ...base,
          blocks: [
            {
              type: 'table',
              rows: 'items',
              columns: [
                { header: 'a', value: 'b', width: 0.7 },
                { header: 'c', value: 'd', width: 0.5 },
              ],
            },
          ],
        },
        'x',
      ),
    ).toThrow(/сумма долей/);
    expect(() => parseTemplate({ ...base, kind: 'waybill', blocks: [] }, 'x')).toThrow(TemplateError);
  });

  it('подстановки {{путь}} и условия when', () => {
    const scopes = [{ name: 'строка' }, { seller: { inn: '123' }, empty: '', list: [] }];
    expect(fill('ИНН {{seller.inn}}, {{name}}, {{missing}}.', scopes)).toBe('ИНН 123, строка, .');
    expect(truthy('seller.inn', scopes)).toBe(true);
    expect(truthy('empty', scopes)).toBe(false);
    expect(truthy('list', scopes)).toBe(false);
    expect(truthy(undefined, scopes)).toBe(true);
  });

  it('замена шаблона без изменения кода: свой каталог шаблонов → новый текст в PDF', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'pdf-tpl-'));
    try {
      cpSync(assets.templatesDir, dir, { recursive: true });
      const file = join(dir, 'invoice.a4.json');
      const t = JSON.parse(readFileSync(file, 'utf8')) as { blocks: unknown[] };
      t.blocks.unshift({ type: 'text', text: 'Образец заказчика (Q-019) № {{number}}' });
      writeFileSync(file, JSON.stringify(t));
      const custom = new PdfTemplateStore(dir);
      const pdf = await renderer.render(custom.get('invoice', 'a4'), invoiceModel(ORDER, SELLER, ITEMS, false), {
        creationDate: ORDER.createdAt,
        title: 'Счёт',
      });
      expect(parsePdf(pdf.bytes).text).toContain('Образец заказчика (Q-019) № ОС00-004512');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('PdfRenderer: счёт и нефискальный товарный чек', () => {
  it('счёт A4: реквизиты, номер 1С, клиент, строки и суммы с корректной арифметикой, кириллица (Inter)', async () => {
    const started = Date.now();
    const pdf = await renderer.render(store.get('invoice', 'a4'), invoiceModel(ORDER, SELLER, ITEMS, false), {
      creationDate: ORDER.createdAt,
      title: 'Счёт на оплату',
    });
    expect(Date.now() - started).toBeLessThanOrEqual(2000);
    const p = parsePdf(pdf.bytes);
    expect(p.pages[0].width).toBeCloseTo(595.28, 1);
    expect(p.fonts.some((f) => f.includes('Inter'))).toBe(true);
    const flat = squash(p.text);
    expect(p.text).toContain('Счёт на оплату № ОС00-004512 от 21.10.2026');
    expect(p.text).toContain('ИНН');
    expect(flat).toContain(squash(SELLER.inn));
    expect(flat).toContain(squash('ОсОО «Сантехмонтаж»'));
    expect(flat).toContain(squash('Оплата по заказу № ОС00-004512'));
    for (const i of ITEMS) {
      expect(flat).toContain(squash(i.productName));
      expect(flat).toContain(squash(formatMoney(i.lineTotal)));
    }
    expect(flat).toContain(squash('16 850,00'));
    expect(flat).toContain(squash('−842,50'));
    expect(flat).toContain(squash('Итого к оплате: 16 007,50'));
    expect(p.text).toContain('Не является фискальным документом');
  });

  it('товарный чек 80 мм: ширина 226,77 pt, «Получено/Сдача», пометка «Нефискальный документ», ≤ 2 с', async () => {
    const started = Date.now();
    const pdf = await renderer.render(
      store.get('receipt', 'thermal80'),
      receiptModel(ORDER, SELLER, ITEMS, CASH, false),
      { creationDate: ORDER.createdAt, title: 'Товарный чек' },
    );
    expect(Date.now() - started).toBeLessThanOrEqual(2000);
    const p = parsePdf(pdf.bytes);
    expect(p.pages).toHaveLength(1);
    expect(p.pages[0].width).toBeCloseTo(226.77, 2);
    expect(p.pages[0].height).toBeGreaterThan(200);
    expect(p.pages[0].height).toBeLessThan(1500);
    const flat = squash(p.text);
    expect(p.text).toContain('ТОВАРНЫЙ ЧЕК № ОС00-004512');
    expect(p.text).toContain('(не является фискальным документом)');
    expect(norm(p.text)).toContain('Нефискальный документ. Не является фискальным документом');
    expect(flat).toContain(squash('Получено16 100,00'));
    expect(flat).toContain(squash('Сдача92,50'));
    expect(flat).toContain(squash('ИТОГО16 007,50 сом'));
    expect(flat).toContain(squash('Кассир Айгуль К.'));
    expect(flat).toContain(squash('2 шт × 3 250,00'));
  });

  it('товарный чек A4 до получения номера 1С — внутренний номер POS; «Копия»', async () => {
    const pdf = await renderer.render(
      store.get('receipt', 'a4'),
      receiptModel({ ...ORDER, onecNumber: null, status: 'submitting' }, SELLER, ITEMS, CASH, true),
      { creationDate: ORDER.createdAt, title: 'Товарный чек' },
    );
    const p = parsePdf(pdf.bytes);
    expect(p.text).toContain('КОПИЯ');
    expect(p.text).toContain('Товарный чек № POS-2026-000123');
    expect(p.text).toContain('Нефискальный документ');
  });

  it('детерминизм: одинаковые данные → одинаковый SHA-256 (ETag), «Копия» → другой', async () => {
    const t = store.get('invoice', 'thermal80');
    const opts = { creationDate: ORDER.createdAt, title: 'Счёт' };
    const a = await renderer.render(t, invoiceModel(ORDER, SELLER, ITEMS, false), opts);
    const b = await renderer.render(t, invoiceModel(ORDER, SELLER, ITEMS, false), opts);
    const c = await renderer.render(t, invoiceModel(ORDER, SELLER, ITEMS, true), opts);
    expect(a.sha256).toBe(b.sha256);
    expect(c.sha256).not.toBe(a.sha256);
    expect(a.pageWidth).toBeCloseTo(226.77, 2);
  });

  it('A4 с 150 строками — несколько страниц, все строки на месте, шапка таблицы повторяется', async () => {
    const many: OrderItemDocRow[] = Array.from({ length: 150 }, (_, i) => ({
      ...ITEMS[i % ITEMS.length],
      lineNo: i + 1,
      productName: `Позиция-${String(i + 1).padStart(3, '0')}`,
    }));
    const pdf = await renderer.render(store.get('invoice', 'a4'), invoiceModel(ORDER, SELLER, many, false), {
      creationDate: ORDER.createdAt,
      title: 'Счёт',
    });
    const p = parsePdf(pdf.bytes);
    expect(pdf.pages).toBeGreaterThan(2);
    expect(p.pages.length).toBe(pdf.pages);
    expect(p.text).toContain('Позиция-001');
    expect(p.text).toContain('Позиция-150');
    expect(p.lines.filter((l) => l === 'Наименование').length).toBe(pdf.pages);
  });
});
