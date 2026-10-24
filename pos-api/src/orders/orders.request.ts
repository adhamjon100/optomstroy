import { z } from 'zod';
import { ProblemException, type ProblemFieldError } from '../common/problem-details/problem.exception.js';
import { CLIENT_FORBIDDEN_MONEY_FIELDS } from '../sales-domain/pricing/client-money-fields.js';

/**
 * Разбор тел запросов модуля `orders` (OpenAPI `OrdersCreateRequest`, `OrdersCancelRequest`, `OrdersOnecLinkRequest`;
 * 08 §2.11, §2.14: лишние поля → 400 `VALIDATION_FAILED`). Тела принимаются как `unknown` (без DTO-класса), чтобы
 * отличить запрещённые денежные поля (`forbidden_field` + аудит `price.override_attempt`, POS-073) от прочих лишних.
 */

const UUID = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, 'uuid');
const PHONE = z.string().regex(/^\+996\d{9}$/, 'phone_e164');
const PERCENT = z.string().regex(/^(\d{1,2}(\.\d{1,2})?|100(\.0{1,2})?)$/, 'percent_range');
const QTY = z.string().regex(/^\d{1,11}(\.\d{1,3})?$/, 'quantity');
const TIME = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'time');
const DATE = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'date');
const OVERRIDE = z
  .strictObject({ reason: z.string().min(1).max(500) })
  .nullable()
  .optional();

const createSchema = z.strictObject({
  cartId: UUID,
  cartRowVersion: z.number().int().min(0),
  previewToken: z.string().max(512).optional(),
  customerId: UUID.nullable().optional(),
  receiver: z.strictObject({
    kind: z.enum(['customer', 'other_person']),
    name: z.string().min(1).max(150).nullable().optional(),
    phone: PHONE.nullable().optional(),
  }),
  delivery: z.strictObject({
    method: z.enum(['pickup', 'delivery']),
    address: z.string().max(300).optional(),
    recipientPhone: PHONE.optional(),
    courierComment: z.string().max(200).optional(),
    desiredDate: DATE.optional(),
    timeFrom: TIME.optional(),
    timeTo: TIME.optional(),
  }),
  paymentMethod: z.enum(['cash', 'qr_bakai', 'credit']),
  manualDiscountPercent: PERCENT.optional(),
  discountOverride: OVERRIDE,
  creditOverride: OVERRIDE,
  printOptions: z
    .strictObject({ invoice: z.boolean().optional(), waybill: z.boolean().optional(), receipt: z.boolean().optional() })
    .optional(),
  comment: z.string().max(500).optional(),
  confirmDuplicate: z.boolean().optional(),
  items: z
    .array(
      z.strictObject({
        variantId: UUID,
        quantity: z.strictObject({
          value: QTY,
          unitId: UUID,
          packagingId: UUID.nullable().optional(),
        }),
      }),
    )
    .min(1)
    .max(200),
});

export type CreateOrderBody = z.infer<typeof createSchema>;

const cancelSchema = z.strictObject({
  reason: z.string().trim().min(1).max(500),
  reasonCode: z.enum(['customer_refused', 'duplicate', 'error', 'other']),
  refundIntent: z.enum(['none', 'refund', 'advance']).optional(),
});
export type CancelOrderBody = z.infer<typeof cancelSchema>;

const onecLinkSchema = z.strictObject({
  onecNumber: z.string().trim().min(1).max(32),
  onecDate: DATE.nullable().optional(),
  reason: z.string().trim().min(5).max(500),
});
export type OnecLinkBody = z.infer<typeof onecLinkSchema>;

/** Денежные поля, которые клиент не передаёт (D-23, ORD-020, 08 §4.8.1) — общий перечень с корзиной. */
export const FORBIDDEN_MONEY_FIELDS: readonly string[] = CLIENT_FORBIDDEN_MONEY_FIELDS;
/** Поля, которые сервер молча игнорирует: канал `created_via` ставит сервер (07 DATA-136, RM-F-015 п. 2). */
const IGNORED_FIELDS = ['createdVia', 'created_via'];

function validationFailed(errors: ProblemFieldError[], status: 400 | 422 = 400): ProblemException {
  return new ProblemException('VALIDATION_FAILED', { status, detail: 'Запрос не прошёл проверку.', errors });
}

function zodErrors(err: z.ZodError): ProblemFieldError[] {
  return err.issues.map((i) => {
    const field = i.path
      .map((p) => (typeof p === 'number' ? `[${p}]` : `.${String(p)}`))
      .join('')
      .replace(/^\./, '');
    let rule: string = i.code;
    if (i.code === 'unrecognized_keys') rule = 'additional_properties';
    else if (i.code === 'invalid_format' || i.code === 'custom') rule = i.message;
    else if (i.code === 'too_big') rule = 'max_length';
    else if (i.code === 'too_small') rule = 'min_length';
    else if (i.code === 'invalid_type') rule = i.input === undefined ? 'required' : 'type';
    else if (i.code === 'invalid_value') rule = 'enum';
    return {
      field: i.code === 'unrecognized_keys' ? [field, ...i.keys].filter(Boolean).join('.') : field,
      message: i.message,
      rule,
    };
  });
}

/** Пути запрещённых денежных полей в теле `POST /orders` (на верхнем уровне и в `items[]`). */
export function forbiddenMoneyFields(body: unknown): string[] {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) return [];
  const b = body as Record<string, unknown>;
  const out: string[] = [];
  for (const f of FORBIDDEN_MONEY_FIELDS) if (f in b) out.push(f);
  if (Array.isArray(b.items)) {
    b.items.forEach((it, idx) => {
      if (typeof it === 'object' && it !== null) {
        for (const f of FORBIDDEN_MONEY_FIELDS) if (f in it) out.push(`items[${idx}].${f}`);
      }
    });
  }
  const d = b.delivery as Record<string, unknown> | undefined;
  if (d && typeof d === 'object' && 'geo' in d) out.push('delivery.geo');
  if ('clientTotalSnapshot' in b) out.push('clientTotalSnapshot');
  return out;
}

export function forbiddenFieldError(fields: readonly string[]): ProblemException {
  return validationFailed(
    fields.map((f) => ({ field: f, rule: 'forbidden_field', message: 'Поле не принимается: суммы считает сервер.' })),
  );
}

export function parseCreateOrderBody(body: unknown): CreateOrderBody {
  const raw =
    typeof body === 'object' && body !== null && !Array.isArray(body)
      ? Object.fromEntries(Object.entries(body as Record<string, unknown>).filter(([k]) => !IGNORED_FIELDS.includes(k)))
      : body;
  const r = createSchema.safeParse(raw);
  if (!r.success) throw validationFailed(zodErrors(r.error));
  const v = r.data;
  const errors: ProblemFieldError[] = [];
  if (v.receiver.kind === 'other_person' && (!v.receiver.name || !v.receiver.phone)) {
    errors.push({ field: 'receiver', rule: 'required', message: 'Для другого получателя нужны ФИО и телефон.' });
  }
  if (v.delivery.method === 'delivery') {
    if (!v.delivery.address) errors.push({ field: 'delivery.address', rule: 'required', message: 'Укажите адрес.' });
    if (!v.delivery.recipientPhone) {
      errors.push({ field: 'delivery.recipientPhone', rule: 'required', message: 'Укажите телефон получателя.' });
    }
  }
  if (errors.length > 0) throw validationFailed(errors);
  return v;
}

export function parseCancelBody(body: unknown): CancelOrderBody {
  const r = cancelSchema.safeParse(body);
  if (!r.success) throw validationFailed(zodErrors(r.error));
  return r.data;
}

export function parseOnecLinkBody(body: unknown): OnecLinkBody {
  const r = onecLinkSchema.safeParse(body);
  if (!r.success) throw validationFailed(zodErrors(r.error));
  return r.data;
}

export { validationFailed };
