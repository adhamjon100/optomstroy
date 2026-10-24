import { sql } from 'drizzle-orm';
import type { PaymentMethod } from '../common/enums.js';
import type { CheckoutCartSnapshot, SalesTx } from '../common/ports/index.js';
import { pgArray } from './order.repository.js';

/** Дата-время контракта 1С: ISO 8601 с `+06:00` (ONEC-058; Бишкек без перехода на летнее время). */
export function toOnecDateTime(d: Date): string {
  const shifted = new Date(d.getTime() + 6 * 3600_000);
  return `${shifted.toISOString().slice(0, 19)}+06:00`;
}

export interface OnecOrderPayloadInput {
  readonly orderId: string;
  readonly publicNumber: string;
  readonly createdAt: Date;
  readonly createdByUserId: string;
  readonly createdVia: 'staff' | 'customer';
  readonly customerId: string;
  readonly paymentMethod: PaymentMethod;
  readonly snapshot: CheckoutCartSnapshot;
  readonly delivery: {
    readonly method: 'pickup' | 'delivery';
    readonly address: string | null;
    readonly receiverName: string | null;
    readonly receiverPhone: string | null;
    readonly desiredDate: string | null;
    readonly timeFrom: string | null;
    readonly timeTo: string | null;
    readonly courierComment: string | null;
  };
  readonly comment: string | null;
}

/**
 * Тело `POST /pos/v1/orders` (контракт `OrderCreateRequest`, 05 §6.4; ONEC-020, ONEC-040): ссылки 1С берутся из
 * реплик каталога/клиентов, строки и итоги — из снимка сервера (`order_items`), а не от клиента (D-23).
 * `Комментарий` содержит `POS <uuid>` (ONEC-040); заявка клиента помечена «заявка клиента» — в 1С создаётся
 * «Заказ клиента» в статусе по умолчанию «Не согласован» (ядро §24.2, ORD-024; статус в запросе контракт не передаёт).
 */
export async function buildOnecOrderPayload(tx: SalesTx, i: OnecOrderPayloadInput): Promise<Record<string, unknown>> {
  const refs = await tx.execute<{
    customer_ref: string | null;
    contractor_ref: string | null;
    agreement_ref: string | null;
    warehouse_ref: string | null;
    price_list_ref: string | null;
  }>(sql`
    SELECT c.onec_ref::text AS customer_ref, c.onec_counterparty_ref::text AS contractor_ref,
           c.onec_agreement_ref::text AS agreement_ref,
           (SELECT w.onec_ref::text FROM warehouses w WHERE w.id = ${i.snapshot.warehouseId}::uuid) AS warehouse_ref,
           (SELECT p.onec_ref::text FROM price_lists p WHERE p.id = ${i.snapshot.priceListId}::uuid) AS price_list_ref
      FROM customers c WHERE c.id = ${i.customerId}::uuid`);
  const ref = refs.rows[0];
  const variantIds = i.snapshot.lines.map((l) => l.variantId);
  const packagingIds = i.snapshot.lines.map((l) => l.packagingId).filter((p): p is string => p !== null);
  const lineRefs = await tx.execute<{ variant_id: string; variant_ref: string | null; product_ref: string | null }>(sql`
    SELECT v.id AS variant_id, v.onec_ref::text AS variant_ref, p.onec_ref::text AS product_ref
      FROM product_variants v JOIN products p ON p.id = v.product_id
     WHERE v.id = ANY(${pgArray(variantIds)}::uuid[])`);
  const byVariant = new Map(lineRefs.rows.map((r) => [r.variant_id, r]));
  const packRefs =
    packagingIds.length > 0
      ? await tx.execute<{ id: string; onec_ref: string | null }>(sql`
          SELECT id, onec_ref::text AS onec_ref FROM packagings WHERE id = ANY(${pgArray(packagingIds)}::uuid[])`)
      : { rows: [] as { id: string; onec_ref: string | null }[] };
  const byPack = new Map(packRefs.rows.map((r) => [r.id, r.onec_ref]));
  const s = i.snapshot;
  const desired = (time: string | null): string | null =>
    i.delivery.desiredDate && time ? `${i.delivery.desiredDate}T${time}:00+06:00` : null;
  const commentParts = [`POS ${i.orderId}`, i.publicNumber];
  if (i.createdVia === 'customer') commentParts.push('заявка клиента');
  if (i.comment) commentParts.push(i.comment);
  return {
    externalId: i.orderId,
    createdAt: toOnecDateTime(i.createdAt),
    createdByUserCode: i.createdByUserId,
    customer: {
      ref: ref?.customer_ref ?? null,
      contractorRef: ref?.contractor_ref ?? null,
      agreementRef: ref?.agreement_ref ?? null,
    },
    warehouseRef: ref?.warehouse_ref ?? null,
    organizationRef: null,
    priceListRef: ref?.price_list_ref ?? null,
    paymentMethod: i.paymentMethod,
    paymentTerms: i.paymentMethod === 'credit' ? 'credit' : 'prepayment',
    delivery: {
      method: i.delivery.method,
      address: i.delivery.address,
      receiverName: i.delivery.receiverName,
      receiverPhone: i.delivery.receiverPhone,
      desiredFrom: desired(i.delivery.timeFrom),
      desiredTo: desired(i.delivery.timeTo),
      courierComment: i.delivery.courierComment,
    },
    discountPercent: s.manualDiscountPercent,
    comment: commentParts.join(' · ').slice(0, 1000),
    lines: s.lines.map((l) => {
      const r = byVariant.get(l.variantId);
      return {
        lineNumber: l.lineNo,
        productRef: r?.product_ref ?? null,
        variantRef: r?.variant_ref ?? null,
        packagingRef: l.packagingId ? (byPack.get(l.packagingId) ?? null) : null,
        quantity: formatQty(l.baseQuantity),
        packQuantity: l.packagingId ? formatQty(l.quantity) : null,
        price: l.unitPrice,
        discountPercent: s.manualDiscountPercent,
        amount: l.lineTotal,
        supplyOption: 'КОбеспечению',
      };
    }),
    totals: { subtotal: s.subtotal, discount: s.discountTotal, total: s.total, currency: 'KGS' },
    clientChecks: { pricesSnapshotAt: null, stockSnapshotAt: null },
  };
}

/**
 * Зависимость заказа от карточки нового POS-клиента (05 SYNC-042, SYNC-049, AC-SYNC-049 «заказ нового клиента не
 * уходит раньше его карточки»; ревью G-customers-1c-1): строка outbox `customer/create` клиента, у которого ещё нет
 * `onec_ref`. Заказ ставится с `depends_on_outbox_id` — диспетчер берёт его только после `sent|confirmed` клиента.
 */
export async function customerCreateDependency(tx: SalesTx, customerId: string): Promise<string | null> {
  const r = await tx.execute<{ id: string }>(sql`
    SELECT x.id FROM onec_outbox x JOIN customers c ON c.id = x.aggregate_id
     WHERE x.aggregate_type = 'customer' AND x.operation = 'create' AND x.aggregate_id = ${customerId}::uuid
       AND c.onec_ref IS NULL AND x.status <> 'cancelled'
     LIMIT 1`);
  return r.rows[0]?.id ?? null;
}

/** Количество контракта 1С: строка с 3 знаками (`"2.000"`). */
function formatQty(q: string): string {
  const [int, frac = ''] = q.split('.');
  return `${int}.${(frac + '000').slice(0, 3)}`;
}
