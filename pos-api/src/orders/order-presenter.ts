import { sql } from 'drizzle-orm';
import { Money } from '../common/money/money.js';
import type { OrderDocumentsAvailability, PaymentSummary, SalesActor, SalesTx } from '../common/ports/index.js';
import { customerDisplayName } from '../common/presenters/customer-name.js';
import type { PermissionCode } from '../common/rbac/permissions.generated.js';
import { decideOrderCancel, isOrderPayable } from '../sales-domain/order/order-status.js';
import { type HistoryRow, type OrderItemRow, type OrderOutboxRow, type OrderRow, pgArray } from './order.repository.js';

/** Деньги API (08 §3.1). */
export function money(amount: string | null | undefined): { amount: string; currency: 'KGS' } {
  return Money.of(amount ?? '0').toJSON();
}

function iso(d: Date | null | undefined): string | null {
  return d ? new Date(d).toISOString() : null;
}

export interface UserRefDto {
  readonly id: string;
  readonly displayName: string;
  readonly role?: string;
}

/** `UserRef` (08 §3.5): без телефона. */
export async function loadUserRefs(tx: SalesTx, ids: readonly (string | null)[]): Promise<Map<string, UserRefDto>> {
  const uniq = [...new Set(ids.filter((x): x is string => typeof x === 'string'))];
  const out = new Map<string, UserRefDto>();
  if (uniq.length === 0) return out;
  const r = await tx.execute<{
    id: string;
    display_name: string | null;
    full_name: string | null;
    role: string | null;
  }>(sql`
    SELECT u.id, p.display_name, p.full_name,
           (SELECT ro.code::text FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
             WHERE ur.user_id = u.id AND ur.revoked_at IS NULL LIMIT 1) AS role
      FROM users u LEFT JOIN user_profiles p ON p.user_id = u.id
     WHERE u.id = ANY(${pgArray(uniq)}::uuid[])`);
  for (const row of r.rows) {
    out.set(row.id, {
      id: row.id,
      displayName: row.display_name ?? row.full_name ?? 'Пользователь',
      ...(row.role ? { role: row.role } : {}),
    });
  }
  return out;
}

export interface CustomerBriefRow extends Record<string, unknown> {
  id: string;
  name: string;
  customer_type: string;
  onec_code: string | null;
  is_retail_default: boolean;
  discount_percent: string | null;
  credit_allowed: boolean;
}

export async function loadCustomers(tx: SalesTx, ids: readonly string[]): Promise<Map<string, CustomerBriefRow>> {
  const uniq = [...new Set(ids)];
  if (uniq.length === 0) return new Map();
  const r = await tx.execute<CustomerBriefRow>(sql`
    SELECT id, name, customer_type::text AS customer_type, onec_code, is_retail_default,
           discount_percent::text AS discount_percent, credit_allowed
      FROM customers WHERE id = ANY(${pgArray(uniq)}::uuid[])`);
  return new Map(r.rows.map((c) => [c.id, c]));
}

/** Ролевое представление `Customer` без сумм долга (08 §3.7: в `Order.customer` — только флаги). */
export function presentCustomer(c: CustomerBriefRow | undefined): Record<string, unknown> | null {
  if (!c) return null;
  return {
    id: c.id,
    name: c.name,
    displayName: customerDisplayName(c.name),
    customerType: c.customer_type,
    ...(c.onec_code ? { onecCode: c.onec_code } : {}),
    isRetailDefault: c.is_retail_default,
    ...(c.discount_percent ? { discountPercent: c.discount_percent } : {}),
    creditAllowed: c.credit_allowed,
  };
}

/**
 * `Payment` (08 §3.10) из `PaymentSummary` порта платежей. Поле `qr` — только при `payment.qr.show` (08 §3.15); в
 * `PaymentSummary` порта его нет (FQ-ORD-04) — берётся из реализации, если она его возвращает.
 */
export function presentPayment(
  p: PaymentSummary,
  orderId: string,
  canSeeQr: boolean,
  customerMode = false,
): Record<string, unknown> {
  const extra = p as PaymentSummary & { qr?: unknown; receivedAmount?: string | null; changeAmount?: string | null };
  // Клиенту — только динамический QR провайдера (10 PAY-022, CUST-024; ревью F-security-1).
  const qr = extra.qr as { provider?: string } | null | undefined;
  const qrForViewer = customerMode && qr && qr.provider !== 'onec' && qr.provider !== 'bakai' ? null : (qr ?? null);
  return {
    id: p.paymentId,
    publicNumber: p.publicNumber,
    orderId,
    method: p.method,
    status: p.status,
    amount: money(p.amount),
    receivedAmount: extra.receivedAmount ? money(extra.receivedAmount) : null,
    changeAmount: extra.changeAmount ? money(extra.changeAmount) : null,
    confirmedAt: iso(p.receivedAt),
    reviewReason: p.reviewReason,
    ...(canSeeQr && p.method === 'qr_bakai' ? { qr: qrForViewer } : {}),
  };
}

function presentItem(i: OrderItemRow): Record<string, unknown> {
  return {
    lineNo: Number(i.line_no), // money-double: allow — номер строки, не количество
    variantId: i.variant_id,
    productId: i.product_id,
    productName: i.product_name_snapshot,
    ...(i.variant_name_snapshot ? { variantName: i.variant_name_snapshot } : {}),
    ...(i.sku_snapshot ? { sku: i.sku_snapshot } : {}),
    quantity: {
      value: i.quantity,
      unitId: i.unit_id,
      packagingId: i.packaging_id,
      baseValue: i.base_quantity,
    },
    baseQuantity: i.base_quantity,
    unitCode: i.unit_code_snapshot,
    unitPrice: money(i.unit_price),
    lineSubtotal: money(i.line_subtotal),
    discountPercent: i.discount_percent,
    discountAmount: money(i.discount_amount),
    lineTotal: money(i.line_total),
    shippedQuantity: i.shipped_quantity,
    returnedQuantity: i.returned_quantity,
  };
}

export type OrderAllowedAction = 'cancel' | 'pay' | 'print_invoice' | 'print_receipt' | 'return_request';

export interface PresentContext {
  readonly actor: SalesActor;
  readonly permissions: ReadonlySet<PermissionCode>;
  readonly customer: CustomerBriefRow | undefined;
  readonly users: Map<string, UserRefDto>;
  readonly payments: readonly PaymentSummary[];
  readonly documents: OrderDocumentsAvailability;
  readonly createOutbox: OrderOutboxRow | null;
  readonly items?: readonly OrderItemRow[];
  readonly history?: readonly HistoryRow[];
  readonly include?: ReadonlySet<'items' | 'payments' | 'history' | 'documents'>;
  readonly warnings?: readonly { readonly code: string; readonly message: string }[];
}

/** Действия, доступные по статусу и правам (08 §4.8.3; клиент — для кнопок, сервер проверяет заново). */
export function allowedActions(o: OrderRow, c: PresentContext): OrderAllowedAction[] {
  const out: OrderAllowedAction[] = [];
  const isOwn = o.created_by_user_id === c.actor.userId;
  try {
    decideOrderCancel({
      status: o.status,
      hasOnecRef: o.onec_ref !== null,
      createOutbox: c.createOutbox
        ? { status: c.createOutbox.status, attempts: Number(c.createOutbox.attempts) }
        : null,
      hasReceivedPayments: Money.of(o.paid_amount).compare(Money.ZERO) > 0,
      isOwn,
      cancelAlreadyRequested: o.cancel_requested_at !== null,
      canCancelOwn: c.permissions.has('order.cancel.own'),
      canRequestAny: c.permissions.has('order.cancel.request.any'),
    });
    out.push('cancel');
  } catch {
    // отмена недоступна
  }
  const canPay =
    (c.permissions.has('payment.cash.receive') || c.permissions.has('payment.qr.show')) &&
    o.payment_method !== 'credit';
  if (canPay && isOrderPayable(o.status) && !o.is_paid && !c.actor.isCustomer) out.push('pay');
  if (c.permissions.has('order.documents.print')) {
    if (c.documents.invoice) out.push('print_invoice');
    if (c.documents.receipt) out.push('print_receipt');
  }
  if (c.permissions.has('return.create') && (o.status === 'shipped' || o.status === 'partially_returned')) {
    out.push('return_request');
  }
  return out;
}

function presentCommon(o: OrderRow, c: PresentContext): Record<string, unknown> {
  const createdBy = c.users.get(o.created_by_user_id);
  return {
    id: o.id,
    publicNumber: o.public_number,
    status: o.status,
    onec: {
      number: o.onec_number,
      date: iso(o.onec_date),
      ref: o.onec_ref,
      status: o.onec_status_raw,
      lastSyncAt: iso(o.onec_last_sync_at),
    },
    onecSyncState: o.onec_sync_state,
    onecTotal: o.onec_total ? money(o.onec_total) : null,
    totalsDiffer: o.totals_differ,
    customer: presentCustomer(c.customer),
    createdVia: o.created_via,
    receiver: {
      kind: o.receiver_kind,
      name: o.receiver_name,
      phone: o.receiver_phone_e164,
    },
    delivery: {
      method: o.delivery_method,
      ...(o.delivery_address ? { address: o.delivery_address } : {}),
      ...(o.delivery_recipient_phone_e164 ? { recipientPhone: o.delivery_recipient_phone_e164 } : {}),
      ...(o.delivery_comment ? { courierComment: o.delivery_comment } : {}),
      ...(o.delivery_date ? { desiredDate: o.delivery_date } : {}),
      ...(o.delivery_time_from ? { timeFrom: o.delivery_time_from } : {}),
      ...(o.delivery_time_to ? { timeTo: o.delivery_time_to } : {}),
    },
    warehouseId: o.warehouse_id,
    priceListId: o.price_list_id,
    subtotal: money(o.subtotal),
    discountPercent: o.discount_percent,
    customerDiscountTotal: money(o.customer_discount_total),
    discountTotal: money(o.discount_total),
    total: money(o.total),
    cashRounding: '0.00',
    totalToPay: money(o.total),
    paymentMethod: o.payment_method,
    paidAmount: money(o.paid_amount),
    isPaid: o.is_paid,
    paymentDueDate: o.credit_due_date,
    paidAt: iso(o.paid_at),
    documents: c.documents,
    printOptions: o.print_options,
    comment: o.comment ?? '',
    cancelReason: o.cancel_reason,
    cancelReasonCode: o.cancel_reason_code,
    refundIntent: o.refund_intent,
    cancelRequested: o.cancel_requested_at !== null,
    cancelRequestedAt: iso(o.cancel_requested_at),
    submitError: o.submit_error_code ? { code: o.submit_error_code, message: o.submit_error_message ?? '' } : null,
    ...(o.cart_id ? { createdFromCartId: o.cart_id } : {}),
    ...(o.idempotency_key && o.created_by_user_id === c.actor.userId ? { idempotencyKey: o.idempotency_key } : {}),
    audit: {
      createdAt: iso(o.created_at),
      ...(createdBy ? { createdBy } : {}),
      updatedAt: iso(o.updated_at),
      rowVersion: Number(o.row_version), // money-double: allow — версия строки, не деньги
    },
  };
}

/** `Order` (08 §3.9, OpenAPI `Order`/`OrdersGetResponse`). */
export function presentOrder(o: OrderRow, c: PresentContext): Record<string, unknown> {
  const inc = c.include;
  const want = (k: 'items' | 'payments' | 'history' | 'documents') => !inc || inc.has(k);
  const canSeeQr = c.permissions.has('payment.qr.show');
  const base = presentCommon(o, c);
  if (!want('documents')) delete base.documents;
  return {
    ...base,
    items: want('items') ? (c.items ?? []).map(presentItem) : [],
    ...(want('payments')
      ? { payments: c.payments.map((p) => presentPayment(p, o.id, canSeeQr, c.actor.isCustomer)) }
      : {}),
    ...(want('history')
      ? {
          history: (c.history ?? []).map((h) => ({
            status: h.to_status,
            at: iso(h.occurred_at),
            by: h.actor_user_id ? (c.users.get(h.actor_user_id) ?? null) : null,
            source: h.source,
          })),
        }
      : {}),
    allowedActions: allowedActions(o, c),
    ...(c.warnings && c.warnings.length > 0 ? { warnings: c.warnings } : {}),
  };
}

/** `OrderSummary` (08 §4.8.2): без `items/history/payments`, с `itemsCount` и `paymentsSummary`. */
export function presentOrderSummary(
  o: OrderRow & { items_count?: number },
  c: PresentContext,
): Record<string, unknown> {
  const base = presentCommon(o, c);
  const open = c.payments.find((p) =>
    ['cash_pending', 'qr_pending', 'qr_shown', 'qr_expired', 'manual_confirm'].includes(p.status),
  );
  return {
    ...base,
    itemsCount: Number(o.items_count ?? 0), // money-double: allow — число строк заказа, не количество товара
    paymentsSummary: {
      count: c.payments.length,
      openPaymentId: open?.paymentId ?? null,
      openPaymentStatus: open?.status ?? null,
      lastStatus: c.payments.length > 0 ? c.payments[c.payments.length - 1].status : null,
    },
  };
}
