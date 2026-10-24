import { Money, Quantity } from '../../common/money/money.js';

/**
 * Модель печатной формы (08 §7.3 `InvoiceDoc` / `ReceiptDoc`; 10 PRINT-002, PRINT-005, PRINT-007): плоский объект
 * строк для подстановки в шаблон. Деньги — только `Money` (decimal.js, NUMERIC-строки из БД), без float (D-19);
 * наименования и артикулы — снимки строк заказа (`product_name_snapshot`, `sku_snapshot`), поэтому переименование
 * товара не меняет напечатанный документ (PRINT-007).
 */
export const DOCUMENT_TIME_ZONE = 'Asia/Bishkek';
export const CURRENCY_LABEL = 'сом';
const NBSP = String.fromCharCode(0xa0);

/** «16 007,50» (разделитель тысяч — неразрывный пробел, дробная часть — запятая); отрицательное — «−». */
export function formatMoney(amount: string): string {
  const s = Money.of(amount).toString();
  const neg = s.startsWith('-');
  const [int = '0', frac = '00'] = (neg ? s.slice(1) : s).split('.');
  const grouped = int.replace(/\B(?=(\d{3})+(?!\d))/g, NBSP);
  return `${neg ? '−' : ''}${grouped},${frac}`;
}

/** Количество без лишних нулей: «2», «2,5», «0,125». */
export function formatQuantity(value: string): string {
  const s = Quantity.of(value).toString();
  const trimmed = s.includes('.') ? s.replace(/0+$/, '').replace(/\.$/, '') : s;
  return trimmed.replace('.', ',');
}

/** Процент скидки «5», «7,5» (NUMERIC(5,2) строкой). */
export function formatPercent(value: string): string {
  const t = value.includes('.') ? value.replace(/0+$/, '').replace(/\.$/, '') : value;
  return t.replace('.', ',');
}

const DATE_FMT = new Intl.DateTimeFormat('ru-RU', {
  timeZone: DOCUMENT_TIME_ZONE,
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
});
const TIME_FMT = new Intl.DateTimeFormat('ru-RU', {
  timeZone: DOCUMENT_TIME_ZONE,
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
});

export function formatDate(d: Date): string {
  return DATE_FMT.format(d);
}

export function formatDateTime(d: Date): string {
  return `${DATE_FMT.format(d)} ${TIME_FMT.format(d)}`;
}

/** `credit_due_date` (`date`, строка `YYYY-MM-DD`) → «ДД.ММ.ГГГГ». */
export function formatIsoDate(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  return m ? `${m[3]}.${m[2]}.${m[1]}` : iso;
}

export const PAYMENT_METHOD_LABELS: Readonly<Record<string, string>> = {
  cash: 'Наличные',
  qr_bakai: 'QR-код (Бакай Банк)',
  credit: 'В долг (отсрочка платежа)',
};

/** Реквизиты организации-продавца (`app_settings.print.organization`, Q-019). */
export interface SellerRequisites {
  readonly name: string;
  readonly inn?: string;
  readonly address?: string;
  readonly phone?: string;
  readonly bankName?: string;
  readonly bic?: string;
  readonly account?: string;
}

export interface OrderDocRow {
  readonly id: string;
  readonly publicNumber: string;
  readonly status: string;
  readonly onecNumber: string | null;
  readonly onecDate: Date | null;
  readonly createdAt: Date;
  readonly updatedAt: Date;
  readonly rowVersion: number;
  readonly paymentMethod: string;
  readonly creditDueDate: string | null;
  readonly subtotal: string;
  readonly discountTotal: string;
  readonly customerDiscountTotal: string;
  readonly manualDiscountTotal: string;
  readonly discountPercent: string;
  readonly customerDiscountPercent: string | null;
  readonly total: string;
  readonly customerName: string;
  readonly customerInn: string | null;
  readonly createdById: string;
}

export interface OrderItemDocRow {
  readonly lineNo: number;
  readonly productName: string;
  readonly variantName: string | null;
  readonly packagingName: string | null;
  readonly sku: string | null;
  readonly quantity: string;
  readonly unit: string;
  readonly unitPrice: string;
  readonly lineSubtotal: string;
  readonly discountAmount: string;
  readonly lineTotal: string;
}

export interface ReceivedPaymentRow {
  readonly id: string;
  readonly method: string;
  readonly amount: string;
  readonly receivedAmount: string | null;
  readonly changeAmount: string | null;
  readonly receivedAt: Date | null;
  readonly receivedByName: string | null;
}

export type DocumentModel = Readonly<Record<string, unknown>>;

function itemsModel(items: readonly OrderItemDocRow[]) {
  return items.map((i) => {
    const name = [i.productName, i.variantName, i.packagingName ? `(${i.packagingName})` : null]
      .filter((p): p is string => typeof p === 'string' && p.trim() !== '')
      .join(' ');
    const discount = Money.of(i.discountAmount);
    return {
      lineNo: String(i.lineNo),
      name,
      sku: i.sku ?? '',
      quantity: formatQuantity(i.quantity),
      unit: i.unit,
      price: formatMoney(i.unitPrice),
      subtotal: formatMoney(i.lineSubtotal),
      discount: discount.isZero() ? '' : formatMoney(i.discountAmount),
      sum: formatMoney(i.lineTotal),
      qtyPrice: `${formatQuantity(i.quantity)} ${i.unit} × ${formatMoney(i.unitPrice)}`,
    };
  });
}

function totalsModel(o: OrderDocRow) {
  const discount = Money.of(o.discountTotal);
  const pct: string[] = [];
  if (o.customerDiscountPercent && !Money.of(o.customerDiscountTotal).isZero()) {
    pct.push(`клиента ${formatPercent(o.customerDiscountPercent)} %`);
  }
  if (!Money.of(o.manualDiscountTotal).isZero()) pct.push(`${formatPercent(o.discountPercent)} %`);
  return {
    subtotal: formatMoney(o.subtotal),
    discount: formatMoney(o.discountTotal),
    hasDiscount: !discount.isZero(),
    discountLabel: pct.length > 0 ? `Скидка (${pct.join(', ')})` : 'Скидка',
    total: formatMoney(o.total),
  };
}

function common(o: OrderDocRow, seller: SellerRequisites, items: readonly OrderItemDocRow[], copy: boolean) {
  return {
    copy: copy ? 'КОПИЯ' : '',
    currency: CURRENCY_LABEL,
    seller: { ...seller },
    customer: { name: o.customerName, inn: o.customerInn ?? '' },
    paymentMethod: PAYMENT_METHOD_LABELS[o.paymentMethod] ?? o.paymentMethod,
    items: itemsModel(items),
    itemsCount: String(items.length),
    totals: totalsModel(o),
    nonFiscalMark: 'Не является фискальным документом',
  };
}

/** Счёт на оплату (PRINT-002/003): номер — номер «Заказа клиента» 1С (обязателен; проверка — в сервисе). */
export function invoiceModel(
  o: OrderDocRow,
  seller: SellerRequisites,
  items: readonly OrderItemDocRow[],
  copy: boolean,
): DocumentModel {
  const number = o.onecNumber ?? '';
  return {
    ...common(o, seller, items, copy),
    kind: 'invoice',
    number,
    date: formatDate(o.onecDate ?? o.createdAt),
    posNumber: o.publicNumber,
    purpose: `Оплата по заказу № ${number}`,
    dueDate: o.paymentMethod === 'credit' && o.creditDueDate ? formatIsoDate(o.creditDueDate) : '',
  };
}

/**
 * Нефискальный товарный чек (PRINT-005, D-26): только по полученным платежам; номер — номер заказа 1С, а до его
 * получения — внутренний номер POS (10 PRINT-005: «номер заказа»); «Получено/Сдача» — для наличных (PAY-014).
 */
export function receiptModel(
  o: OrderDocRow,
  seller: SellerRequisites,
  items: readonly OrderItemDocRow[],
  payments: readonly ReceivedPaymentRow[],
  copy: boolean,
): DocumentModel {
  let paid = Money.ZERO;
  for (const p of payments) paid = paid.plus(Money.of(p.amount));
  const last = payments[payments.length - 1];
  const remaining = Money.of(o.total).minus(paid);
  return {
    ...common(o, seller, items, copy),
    kind: 'receipt',
    number: o.onecNumber ?? o.publicNumber,
    orderNumber: o.onecNumber ? `${o.onecNumber} (${o.publicNumber})` : o.publicNumber,
    date: formatDateTime(last?.receivedAt ?? o.createdAt),
    cashier: last?.receivedByName ?? '',
    paid: formatMoney(paid.toString()),
    remaining: remaining.isNegative() || remaining.isZero() ? '' : formatMoney(remaining.toString()),
    payments: payments.map((p) => ({
      method: PAYMENT_METHOD_LABELS[p.method] ?? p.method,
      amount: formatMoney(p.amount),
      received: p.method === 'cash' && p.receivedAmount ? formatMoney(p.receivedAmount) : '',
      change: p.method === 'cash' && p.changeAmount !== null ? formatMoney(p.changeAmount) : '',
      receivedAt: p.receivedAt ? formatDateTime(p.receivedAt) : '',
    })),
    nonFiscalTitle: '(не является фискальным документом)',
    nonFiscalMark: 'Нефискальный документ. Не является фискальным документом',
  };
}
