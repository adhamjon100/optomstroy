import { z } from 'zod';
import { RETURN_REASON_VALUES, type PaymentMethod, type ReturnReason } from '../common/enums.js';
import { ProblemException, type ProblemFieldError } from '../common/problem-details/problem.exception.js';

/**
 * Разбор тел и параметров модуля `returns` (OpenAPI `ReturnsCreateRequest`, `ReturnsUpdateRequest`,
 * `ReturnsSubmitRequest`, `ReturnsAcceptRequest`, `ReturnsRejectRequest`; 08 §4.15, §2.14): `additionalProperties:
 * false` — лишнее поле (в том числе сумма строки — суммы считает сервер, 08 §4.15.1) → 400 `VALIDATION_FAILED`.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const UUID = z.string().regex(UUID_RE, 'uuid');
const QTY = z.string().regex(/^\d{1,11}(\.\d{1,3})?$/, 'quantity');
const REASON = z.enum(RETURN_REASON_VALUES);
const REFUND = z.enum(['cash', 'qr_bakai', 'credit']).nullable().optional();
const ROW_VERSION = z.number().int().min(0);

/**
 * Минимальная длина комментария при `reasonCode=other` — 10 символов (10 RET-004; значение «[НЕ ПОДТВЕРЖДЕНО, Q-176]»,
 * в OpenAPI длина не задана — GQ-TXR-04).
 */
export const OTHER_COMMENT_MIN = 10;

const ITEMS = z
  .array(
    z.strictObject({
      orderLineNo: z.number().int().min(1).max(32767),
      quantity: z.strictObject({
        value: QTY,
        unitId: UUID,
        packagingId: UUID.nullable().optional(),
      }),
    }),
  )
  .min(1)
  .max(200);

const createSchema = z.strictObject({
  orderId: UUID,
  reasonCode: REASON,
  reasonComment: z.string().max(500).optional(),
  items: ITEMS,
  refundKind: REFUND,
});

const updateSchema = z.strictObject({
  reasonCode: REASON.optional(),
  reasonComment: z.string().max(500).optional(),
  items: ITEMS.optional(),
  refundKind: REFUND,
  rowVersion: ROW_VERSION,
});

const submitSchema = z.strictObject({ rowVersion: ROW_VERSION, comment: z.string().max(200).optional() });
const acceptSchema = z.strictObject({ rowVersion: ROW_VERSION, comment: z.string().max(500).nullable().optional() });
const rejectSchema = z.strictObject({ rowVersion: ROW_VERSION, reason: z.string().trim().min(5).max(500) });

export interface ReturnItemInput {
  readonly orderLineNo: number;
  readonly quantity: { readonly value: string; readonly unitId: string; readonly packagingId: string | null };
}

export interface CreateReturnBody {
  readonly orderId: string;
  readonly reasonCode: ReturnReason;
  readonly reasonComment: string | null;
  readonly items: readonly ReturnItemInput[];
  readonly refundKind: PaymentMethod | null;
}

export interface UpdateReturnBody {
  readonly reasonCode?: ReturnReason;
  /** `undefined` — не менять; иначе новый текст (пустая строка → `null`). */
  readonly reasonComment?: string | null;
  readonly items?: readonly ReturnItemInput[];
  /** `undefined` — не менять. */
  readonly refundKind?: PaymentMethod | null;
  readonly rowVersion: number;
}

export function validationFailed(errors: ProblemFieldError[], status: 400 | 422 = 400): ProblemException {
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

function parse<T>(schema: z.ZodType<T>, body: unknown): T {
  const r = schema.safeParse(body ?? {});
  if (!r.success) throw validationFailed(zodErrors(r.error));
  return r.data;
}

function normComment(v: string | undefined): string | null | undefined {
  if (v === undefined) return undefined;
  const t = v.trim();
  return t === '' ? null : t;
}

function items(v: z.infer<typeof ITEMS>): ReturnItemInput[] {
  const seen = new Set<number>();
  const errors: ProblemFieldError[] = [];
  const out = v.map((it, idx) => {
    if (seen.has(it.orderLineNo)) {
      errors.push({ field: `items[${idx}].orderLineNo`, rule: 'unique', message: 'Строка указана дважды.' });
    }
    seen.add(it.orderLineNo);
    if (/^0+(\.0+)?$/.test(it.quantity.value)) {
      errors.push({ field: `items[${idx}].quantity.value`, rule: 'min', message: 'Количество больше нуля.' });
    }
    return {
      orderLineNo: it.orderLineNo,
      quantity: {
        value: it.quantity.value,
        unitId: it.quantity.unitId.toLowerCase(),
        packagingId: it.quantity.packagingId ? it.quantity.packagingId.toLowerCase() : null,
      },
    };
  });
  if (errors.length > 0) throw validationFailed(errors);
  return out;
}

/** RET-004: при `other` комментарий обязателен (≥ `OTHER_COMMENT_MIN` символов). */
export function assertReasonComment(reason: ReturnReason, comment: string | null): void {
  if (reason === 'other' && (comment === null || comment.length < OTHER_COMMENT_MIN)) {
    throw validationFailed([
      {
        field: 'reasonComment',
        rule: comment === null ? 'required' : 'min_length',
        message: `Для причины «Иное» опишите причину (не короче ${OTHER_COMMENT_MIN} символов).`,
        params: { min: OTHER_COMMENT_MIN },
      },
    ]);
  }
}

export function parseCreateReturnBody(body: unknown): CreateReturnBody {
  const v = parse(createSchema, body);
  const comment = normComment(v.reasonComment) ?? null;
  assertReasonComment(v.reasonCode, comment);
  return {
    orderId: v.orderId.toLowerCase(),
    reasonCode: v.reasonCode,
    reasonComment: comment,
    items: items(v.items),
    refundKind: v.refundKind ?? null,
  };
}

export function parseUpdateReturnBody(body: unknown): UpdateReturnBody {
  const v = parse(updateSchema, body);
  return {
    ...(v.reasonCode !== undefined ? { reasonCode: v.reasonCode } : {}),
    ...(v.reasonComment !== undefined ? { reasonComment: normComment(v.reasonComment) ?? null } : {}),
    ...(v.items !== undefined ? { items: items(v.items) } : {}),
    ...(v.refundKind !== undefined ? { refundKind: v.refundKind } : {}),
    rowVersion: v.rowVersion,
  };
}

export function parseSubmitBody(body: unknown): { rowVersion: number; comment: string | null } {
  const v = parse(submitSchema, body);
  return { rowVersion: v.rowVersion, comment: normComment(v.comment) ?? null };
}

export function parseAcceptBody(body: unknown): { rowVersion: number; comment: string | null } {
  const v = parse(acceptSchema, body);
  return { rowVersion: v.rowVersion, comment: v.comment ? (normComment(v.comment) ?? null) : null };
}

export function parseRejectBody(body: unknown): { rowVersion: number; reason: string } {
  const v = parse(rejectSchema, body);
  return { rowVersion: v.rowVersion, reason: v.reason };
}

export function parseUuidPath(v: string): string {
  // 08 §4.16.2 (уточнение F): `{id}` не UUID → 404 (существование не раскрывается).
  if (!UUID_RE.test(v)) throw new ProblemException('NOT_FOUND', { detail: 'Заявка на возврат не найдена.' });
  return v.toLowerCase();
}

/** `?rowVersion=` (DELETE, 08 §4.15.4): обязательное целое ≥ 0. */
export function parseRowVersionQuery(v: unknown): number {
  const s: unknown = Array.isArray(v) ? (v as unknown[])[0] : v;
  if (typeof s !== 'string' || !/^\d{1,9}$/.test(s)) {
    throw validationFailed([{ field: 'rowVersion', rule: 'required', message: 'Укажите rowVersion (целое ≥ 0).' }]);
  }
  return Number(s); // money-double: allow — версия строки, не сумма
}
