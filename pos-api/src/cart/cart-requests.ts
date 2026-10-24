import type { PaymentMethod } from '../common/enums.js';
import { MONEY_AMOUNT_RE, QUANTITY_RE } from '../common/money/money.js';
import type { ProblemFieldError } from '../common/problem-details/problem.exception.js';
import { CLIENT_FORBIDDEN_MONEY_FIELDS } from '../sales-domain/pricing/client-money-fields.js';
import { isUuidString, PHONE_E164_RE, validationFailed } from './cart-common.js';

/**
 * Разбор тел запросов корзины по OpenAPI (`additionalProperties: false`; 08 §2.14). Ошибки схемы — все одним
 * ответом `400 VALIDATION_FAILED` с `errors[]`. Клиент не передаёт цены и итоги (D-23, 10 DISC-011): поля `price`,
 * `unitPrice`, `total`, `subtotal`, `discountAmount`, `lineTotal`, `amount` → rule `forbidden_field` (+ аудит
 * `price.override_attempt` — пишет контроллер).
 */
export const FORBIDDEN_PRICE_FIELDS: readonly string[] = CLIENT_FORBIDDEN_MONEY_FIELDS;

type Obj = Record<string, unknown>;

const isObj = (v: unknown): v is Obj => v !== null && typeof v === 'object' && !Array.isArray(v);

/** Пути запрещённых денежных полей в теле (верхний уровень и вложенные объекты, кроме `exempt`). */
export function forbiddenPriceFields(body: unknown, exempt: readonly string[] = []): string[] {
  const found: string[] = [];
  const walk = (v: unknown, path: string) => {
    if (!isObj(v)) return;
    for (const [k, child] of Object.entries(v)) {
      const p = path ? `${path}.${k}` : k;
      if (exempt.includes(p)) continue;
      if (FORBIDDEN_PRICE_FIELDS.includes(k)) found.push(p);
      if (isObj(child)) walk(child, p);
    }
  };
  walk(body, '');
  return found;
}

class Errors {
  readonly list: ProblemFieldError[] = [];
  add(field: string, rule: string, message: string): void {
    this.list.push({ field, rule, message });
  }
  throwIfAny(): void {
    if (this.list.length > 0) validationFailed(this.list);
  }
}

function requireObject(body: unknown): Obj {
  if (!isObj(body)) validationFailed([{ field: '$', rule: 'type', message: 'Тело запроса — объект JSON.' }]);
  return body;
}

function onlyKeys(
  e: Errors,
  obj: Obj,
  allowed: readonly string[],
  prefix = '',
  forbidden: readonly string[] = [],
): void {
  for (const k of Object.keys(obj)) {
    const p = prefix ? `${prefix}.${k}` : k;
    if (allowed.includes(k)) continue;
    if (FORBIDDEN_PRICE_FIELDS.includes(k) || forbidden.includes(k)) {
      e.add(p, 'forbidden_field', `Поле ${k} не принимается: цены и итоги считает сервер.`);
    } else if (!allowed.includes(k)) e.add(p, 'additional_properties', `Поле ${k} не допускается.`);
  }
}

function rowVersionOf(e: Errors, v: unknown, field = 'rowVersion'): number {
  if (typeof v !== 'number' || !Number.isInteger(v) || v < 0 || v > 2_147_483_647) {
    e.add(field, 'type', `${field} — целое число ≥ 0.`);
    return -1;
  }
  return v;
}

function uuidOf(e: Errors, v: unknown, field: string, nullable = false): string | null {
  if (v === null && nullable) return null;
  if (!isUuidString(v)) {
    e.add(field, 'uuid', `${field} — UUID.`);
    return null;
  }
  return v.toLowerCase();
}

export function percentOk(v: unknown): v is string {
  return typeof v === 'string' && /^(\d{1,2}(\.\d{1,2})?|100(\.0{1,2})?)$/.test(v);
}

// ------------------------------------------------------------------------------------------- PUT /cart/items

export interface PutItemRequest {
  readonly value: string;
  readonly unitId: string;
  readonly packagingId: string | null;
  readonly priceSnapshot: string | null;
  readonly rowVersion: number;
  readonly mode: 'set' | 'increment';
}

export function parsePutItem(body: unknown): PutItemRequest {
  const b = requireObject(body);
  const e = new Errors();
  onlyKeys(e, b, ['quantity', 'priceSnapshot', 'rowVersion', 'mode']);
  const q = b.quantity;
  let value = '';
  let unitId = '';
  let packagingId: string | null = null;
  if (!isObj(q)) e.add('quantity', 'required', 'quantity — объект Quantity.');
  else {
    onlyKeys(e, q, ['value', 'unitId', 'packagingId', 'baseValue'], 'quantity');
    if (typeof q.value !== 'string' || !QUANTITY_RE.test(q.value)) {
      e.add('quantity.value', 'quantity_format', 'Количество строкой, не более 3 знаков после точки.');
    } else value = q.value;
    unitId = uuidOf(e, q.unitId, 'quantity.unitId') ?? '';
    if (q.packagingId !== undefined) packagingId = uuidOf(e, q.packagingId, 'quantity.packagingId', true);
  }
  let priceSnapshot: string | null = null;
  if (b.priceSnapshot !== undefined && b.priceSnapshot !== null) {
    const m = b.priceSnapshot;
    if (!isObj(m)) e.add('priceSnapshot', 'type', 'priceSnapshot — объект Money.');
    else {
      onlyKeys(e, m, ['amount', 'currency'], 'priceSnapshot');
      if (typeof m.amount !== 'string' || !MONEY_AMOUNT_RE.test(m.amount) || m.amount.startsWith('-')) {
        e.add('priceSnapshot.amount', 'money_format', 'Сумма строкой с 2 знаками.');
      } else priceSnapshot = m.amount;
      if (m.currency !== 'KGS') e.add('priceSnapshot.currency', 'currency', 'Валюта — KGS.');
    }
  }
  const rowVersion = rowVersionOf(e, b.rowVersion);
  const mode = b.mode === undefined ? 'set' : b.mode;
  if (mode !== 'set' && mode !== 'increment') e.add('mode', 'enum', 'mode — set или increment.');
  e.throwIfAny();
  return { value, unitId, packagingId, priceSnapshot, rowVersion, mode: mode as 'set' | 'increment' };
}

// ------------------------------------------------------------------------------------------- PATCH /cart

export function parseUpdate(body: unknown): { warehouseId: string; rowVersion: number } {
  const b = requireObject(body);
  const e = new Errors();
  for (const k of Object.keys(b)) {
    if (k !== 'warehouseId' && k !== 'rowVersion') {
      e.add(k, 'forbidden_field', `Поле ${k} не изменяется: PATCH /cart меняет только warehouseId.`);
    }
  }
  const warehouseId = uuidOf(e, b.warehouseId, 'warehouseId') ?? '';
  const rowVersion = rowVersionOf(e, b.rowVersion);
  e.throwIfAny();
  return { warehouseId, rowVersion };
}

// ------------------------------------------------------------------------------------------- Receiver

export interface ReceiverInput {
  readonly kind: 'customer' | 'other_person';
  readonly name: string | null;
  readonly phone: string | null;
}

function receiverOf(e: Errors, v: unknown, field: string): ReceiverInput | null {
  if (!isObj(v)) {
    e.add(field, 'type', `${field} — объект Receiver.`);
    return null;
  }
  onlyKeys(e, v, ['kind', 'name', 'phone'], field);
  if (v.kind !== 'customer' && v.kind !== 'other_person') {
    e.add(`${field}.kind`, 'enum', 'kind — customer или other_person.');
    return null;
  }
  const name = typeof v.name === 'string' && v.name.trim() !== '' ? v.name.trim() : null;
  if (v.name !== undefined && v.name !== null && typeof v.name !== 'string')
    e.add(`${field}.name`, 'type', 'name — строка.');
  if (name !== null && name.length > 150) e.add(`${field}.name`, 'max_length', 'Имя — не более 150 символов.');
  let phone: string | null = null;
  if (v.phone !== undefined && v.phone !== null) {
    const raw = typeof v.phone === 'string' ? v.phone.replace(/[\s()-]/g, '') : '';
    if (!PHONE_E164_RE.test(raw)) e.add(`${field}.phone`, 'phone_e164', 'Телефон в формате +996XXXXXXXXX.');
    else phone = raw;
  }
  if (v.kind === 'other_person') {
    if (name === null) e.add(`${field}.name`, 'required', 'Укажите имя получателя.');
    if (phone === null && (v.phone === undefined || v.phone === null)) {
      e.add(`${field}.phone`, 'required', 'Укажите телефон получателя.');
    }
    return { kind: 'other_person', name, phone };
  }
  return { kind: 'customer', name: null, phone: null };
}

// ------------------------------------------------------------------------------------------- POST /cart/customer

export function parseCustomerSet(body: unknown): {
  customerId: string;
  receiver: ReceiverInput | null;
  rowVersion: number;
} {
  const b = requireObject(body);
  const e = new Errors();
  onlyKeys(e, b, ['customerId', 'receiver', 'rowVersion']);
  const customerId = uuidOf(e, b.customerId, 'customerId') ?? '';
  const receiver = b.receiver === undefined || b.receiver === null ? null : receiverOf(e, b.receiver, 'receiver');
  const rowVersion = rowVersionOf(e, b.rowVersion);
  e.throwIfAny();
  return { customerId, receiver, rowVersion };
}

// ------------------------------------------------------------------------------------------- POST /cart/discount

export interface DiscountRequest {
  readonly percent: string;
  readonly ruleId: string | null;
  readonly rowVersion: number;
  readonly override: { readonly reason: string } | null;
}

function overrideOf(e: Errors, v: unknown, field: string): { reason: string } | null {
  if (v === undefined || v === null) return null;
  if (!isObj(v)) {
    e.add(field, 'type', `${field} — объект {reason}.`);
    return null;
  }
  onlyKeys(e, v, ['reason'], field);
  if (typeof v.reason !== 'string' || v.reason.trim().length < 1) {
    e.add(`${field}.reason`, 'required', 'Укажите причину.');
    return null;
  }
  if (v.reason.length > 500) e.add(`${field}.reason`, 'max_length', 'Причина — не более 500 символов.');
  return { reason: v.reason.trim() };
}

export function parseDiscount(body: unknown): DiscountRequest {
  const b = requireObject(body);
  const e = new Errors();
  onlyKeys(e, b, ['percent', 'ruleId', 'rowVersion', 'override']);
  if (!percentOk(b.percent)) e.add('percent', 'percent_range', 'Процент — от 0 до 100, не более 2 знаков.');
  const ruleId = b.ruleId === undefined || b.ruleId === null ? null : uuidOf(e, b.ruleId, 'ruleId');
  const rowVersion = rowVersionOf(e, b.rowVersion);
  const override = overrideOf(e, b.override, 'override');
  e.throwIfAny();
  return { percent: b.percent as string, ruleId, rowVersion, override };
}

// ------------------------------------------------------------------------------------------- park / resume

export function parsePark(body: unknown): { name: string | null; rowVersion: number } {
  const b = requireObject(body);
  const e = new Errors();
  onlyKeys(e, b, ['name', 'rowVersion']);
  let name: string | null = null;
  if (b.name !== undefined && b.name !== null) {
    if (typeof b.name !== 'string') e.add('name', 'type', 'name — строка.');
    else {
      // eslint-disable-next-line no-control-regex
      const t = b.name.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
      if (t.length > 80) e.add('name', 'max_length', 'Имя отложенной корзины — не более 80 символов.');
      name = t === '' ? null : t;
    }
  }
  const rowVersion = rowVersionOf(e, b.rowVersion);
  e.throwIfAny();
  return { name, rowVersion };
}

export function parseResume(body: unknown): { replaceActive: boolean } {
  if (body === undefined || body === null || (isObj(body) && Object.keys(body).length === 0)) {
    return { replaceActive: false };
  }
  const b = requireObject(body);
  const e = new Errors();
  onlyKeys(e, b, ['replaceActive'], '', ['merge']);
  if (b.replaceActive !== undefined && typeof b.replaceActive !== 'boolean') {
    e.add('replaceActive', 'type', 'replaceActive — true или false.');
  }
  e.throwIfAny();
  return { replaceActive: b.replaceActive === true };
}

// ------------------------------------------------------------------------------------------- checkout-preview

export interface DeliveryInput {
  readonly method: 'pickup' | 'delivery';
  readonly address: string | null;
  readonly recipientPhone: string | null;
  readonly courierComment: string | null;
  readonly desiredDate: string | null;
  readonly timeFrom: string | null;
  readonly timeTo: string | null;
}

export interface PreviewRequest {
  readonly cartId: string;
  readonly cartRowVersion: number;
  readonly paymentMethod: PaymentMethod;
  readonly delivery: DeliveryInput;
  readonly receiver: ReceiverInput;
  readonly manualDiscountPercent: string | null;
  readonly creditOverride: { readonly reason: string } | null;
  readonly syncCheckWithOnec: boolean;
  readonly strict: boolean;
}

const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function deliveryOf(e: Errors, v: unknown): DeliveryInput | null {
  if (!isObj(v)) {
    e.add('delivery', 'required', 'delivery — объект Delivery.');
    return null;
  }
  onlyKeys(
    e,
    v,
    ['method', 'address', 'recipientPhone', 'courierComment', 'desiredDate', 'timeFrom', 'timeTo'],
    'delivery',
    ['geo'],
  );
  if (v.method !== 'pickup' && v.method !== 'delivery') {
    e.add('delivery.method', 'enum', 'method — pickup или delivery.');
    return null;
  }
  const str = (k: string, max: number): string | null => {
    const x = v[k];
    if (x === undefined || x === null) return null;
    if (typeof x !== 'string') {
      e.add(`delivery.${k}`, 'type', `${k} — строка.`);
      return null;
    }
    // eslint-disable-next-line no-control-regex
    const t = x.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
    if (t.length > max) e.add(`delivery.${k}`, 'max_length', `${k} — не более ${max} символов.`);
    return t === '' ? null : t;
  };
  const address = str('address', 300);
  const courierComment = str('courierComment', 200);
  let recipientPhone: string | null = null;
  if (v.recipientPhone !== undefined && v.recipientPhone !== null) {
    const raw = typeof v.recipientPhone === 'string' ? v.recipientPhone.replace(/[\s()-]/g, '') : '';
    if (!PHONE_E164_RE.test(raw)) e.add('delivery.recipientPhone', 'phone_e164', 'Телефон в формате +996XXXXXXXXX.');
    else recipientPhone = raw;
  }
  const desiredDate = typeof v.desiredDate === 'string' ? v.desiredDate : null;
  if (v.desiredDate !== undefined && v.desiredDate !== null && (desiredDate === null || !DATE_RE.test(desiredDate))) {
    e.add('delivery.desiredDate', 'date', 'desiredDate — дата YYYY-MM-DD.');
  }
  const t = (k: 'timeFrom' | 'timeTo'): string | null => {
    const x = v[k];
    if (x === undefined || x === null) return null;
    if (typeof x !== 'string' || !TIME_RE.test(x)) {
      e.add(`delivery.${k}`, 'time', `${k} — время HH:MM.`);
      return null;
    }
    return x;
  };
  const timeFrom = t('timeFrom');
  const timeTo = t('timeTo');
  if (timeFrom !== null && timeTo !== null && timeFrom >= timeTo) {
    e.add('delivery.timeTo', 'time_range', 'Время «до» должно быть позже «с».');
  }
  if (v.method === 'delivery') {
    if (address === null) e.add('delivery.address', 'required', 'Для доставки укажите адрес.');
    if (recipientPhone === null && (v.recipientPhone === undefined || v.recipientPhone === null)) {
      e.add('delivery.recipientPhone', 'required', 'Для доставки укажите телефон получателя.');
    }
  }
  return { method: v.method, address, recipientPhone, courierComment, desiredDate, timeFrom, timeTo };
}

export function parsePreview(body: unknown): PreviewRequest {
  const b = requireObject(body);
  const e = new Errors();
  onlyKeys(
    e,
    b,
    [
      'cartId',
      'cartRowVersion',
      'paymentMethod',
      'delivery',
      'receiver',
      'manualDiscountPercent',
      'creditOverride',
      'syncCheckWithOnec',
      'strict',
    ],
    '',
    ['clientTotalSnapshot'],
  );
  const cartId = uuidOf(e, b.cartId, 'cartId') ?? '';
  const cartRowVersion = rowVersionOf(e, b.cartRowVersion, 'cartRowVersion');
  const pm = b.paymentMethod;
  if (pm !== 'cash' && pm !== 'qr_bakai' && pm !== 'credit') {
    e.add('paymentMethod', 'enum', 'paymentMethod — cash, qr_bakai или credit.');
  }
  const delivery = deliveryOf(e, b.delivery);
  const receiver =
    b.receiver === undefined
      ? (e.add('receiver', 'required', 'receiver обязателен.'), null)
      : receiverOf(e, b.receiver, 'receiver');
  let manualDiscountPercent: string | null = null;
  if (b.manualDiscountPercent !== undefined && b.manualDiscountPercent !== null) {
    if (!percentOk(b.manualDiscountPercent)) {
      e.add('manualDiscountPercent', 'percent_range', 'Процент — от 0 до 100, не более 2 знаков.');
    } else manualDiscountPercent = b.manualDiscountPercent;
  }
  const creditOverride = overrideOf(e, b.creditOverride, 'creditOverride');
  for (const k of ['syncCheckWithOnec', 'strict'] as const) {
    if (b[k] !== undefined && typeof b[k] !== 'boolean') e.add(k, 'type', `${k} — true или false.`);
  }
  e.throwIfAny();
  return {
    cartId,
    cartRowVersion,
    paymentMethod: pm as PaymentMethod,
    delivery: delivery!,
    receiver: receiver!,
    manualDiscountPercent,
    creditOverride,
    syncCheckWithOnec: b.syncCheckWithOnec !== false,
    strict: b.strict === true,
  };
}
