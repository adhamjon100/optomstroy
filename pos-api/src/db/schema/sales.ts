// СГЕНЕРИРОВАНО test/db/codegen/gen-drizzle-schema.ts из каталога PostgreSQL 17 после migrations/*.sql
// (RM-C-006) — вручную не править: новая миграция → `npx tsx test/db/codegen/gen-drizzle-schema.ts`.
// Сверка с БД — test/db/migrate-seed.db-spec.ts («Drizzle-схема совпадает с БД»).

// Домен sales (07 §5.D)

import { sql } from 'drizzle-orm';
import {
  boolean,
  char,
  date,
  inet,
  integer,
  jsonb,
  numeric,
  pgTable,
  point,
  primaryKey,
  smallint,
  text,
  time,
  timestamp,
  uuid,
} from 'drizzle-orm/pg-core';
import {
  cartStatusEnum,
  deliveryMethodEnum,
  onecSyncStateEnum,
  orderStatusEnum,
  paymentMethodEnum,
  paymentStatusEnum,
  receiverKindEnum,
  returnReasonEnum,
  returnRequestStatusEnum,
  statusChangeSourceEnum,
  transactionKindEnum,
  transactionSourceEnum,
} from './enums.js';

/** carts — 07 §5.35 */
export const carts = pgTable('carts', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  ownerUserId: uuid('owner_user_id').notNull(),
  createdByUserId: uuid('created_by_user_id').notNull(),
  deviceId: uuid('device_id'),
  customerId: uuid('customer_id'),
  warehouseId: uuid('warehouse_id').notNull(),
  priceListId: uuid('price_list_id').notNull(),
  status: cartStatusEnum('status')
    .notNull()
    .default(sql`'active'::cart_status`),
  name: text('name'),
  requestedDiscountPercent: numeric('requested_discount_percent', { precision: 5, scale: 2 })
    .notNull()
    .default(sql`0`),
  discountApprovedByUserId: uuid('discount_approved_by_user_id'),
  discountApprovedAt: timestamp('discount_approved_at', { withTimezone: true }),
  comment: text('comment'),
  itemsCountCache: integer('items_count_cache')
    .notNull()
    .default(sql`0`),
  subtotalCache: numeric('subtotal_cache', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  lastPriceCheckAt: timestamp('last_price_check_at', { withTimezone: true }),
  convertedOrderId: uuid('converted_order_id'),
  restoredFromOrderId: uuid('restored_from_order_id'),
  parkedAt: timestamp('parked_at', { withTimezone: true }),
  resumedAt: timestamp('resumed_at', { withTimezone: true }),
  clearedAt: timestamp('cleared_at', { withTimezone: true }),
  expiresAt: timestamp('expires_at', { withTimezone: true }),
  rowVersion: integer('row_version')
    .notNull()
    .default(sql`1`),
  localCartId: uuid('local_cart_id'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  receiverKind: receiverKindEnum('receiver_kind')
    .notNull()
    .default(sql`'customer'::receiver_kind`),
  receiverName: text('receiver_name'),
  receiverPhoneE164: text('receiver_phone_e164'),
  discountOverrideReason: text('discount_override_reason'),
});

/** cart_items — 07 §5.36 */
export const cartItems = pgTable('cart_items', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  cartId: uuid('cart_id').notNull(),
  variantId: uuid('variant_id').notNull(),
  packagingId: uuid('packaging_id'),
  quantity: numeric('quantity', { precision: 14, scale: 3 }).notNull(),
  baseQuantity: numeric('base_quantity', { precision: 14, scale: 3 }).notNull(),
  priceSnapshot: numeric('price_snapshot', { precision: 14, scale: 2 }).notNull(),
  stockSnapshot: numeric('stock_snapshot', { precision: 14, scale: 3 }),
  priceChanged: boolean('price_changed')
    .notNull()
    .default(sql`false`),
  stockInsufficient: boolean('stock_insufficient')
    .notNull()
    .default(sql`false`),
  lineNo: smallint('line_no').notNull(),
  addedAt: timestamp('added_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  localItemId: uuid('local_item_id'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** orders — 07 §5.37 */
export const orders = pgTable('orders', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  publicNumber: text('public_number').notNull(),
  cartId: uuid('cart_id'),
  status: orderStatusEnum('status')
    .notNull()
    .default(sql`'draft'::order_status`),
  customerId: uuid('customer_id').notNull(),
  customerNameSnapshot: text('customer_name_snapshot'),
  customerPhoneSnapshot: text('customer_phone_snapshot'),
  createdByUserId: uuid('created_by_user_id').notNull(),
  createdVia: text('created_via')
    .notNull()
    .default(sql`'staff'::text`),
  deviceId: uuid('device_id'),
  warehouseId: uuid('warehouse_id').notNull(),
  priceListId: uuid('price_list_id').notNull(),
  currency: char('currency', { length: 3 })
    .notNull()
    .default(sql`'KGS'::bpchar`),
  subtotal: numeric('subtotal', { precision: 14, scale: 2 }).notNull(),
  discountPercent: numeric('discount_percent', { precision: 5, scale: 2 })
    .notNull()
    .default(sql`0`),
  customerDiscountPercent: numeric('customer_discount_percent', { precision: 5, scale: 2 }),
  customerDiscountTotal: numeric('customer_discount_total', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  manualDiscountTotal: numeric('manual_discount_total', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  discountTotal: numeric('discount_total', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  total: numeric('total', { precision: 14, scale: 2 }).notNull(),
  onecTotal: numeric('onec_total', { precision: 14, scale: 2 }),
  totalsDiffer: boolean('totals_differ').generatedAlwaysAs(sql`((onec_total IS NOT NULL) AND (onec_total <> total))`),
  discountRuleId: uuid('discount_rule_id'),
  discountApprovedByUserId: uuid('discount_approved_by_user_id'),
  discountApprovedAt: timestamp('discount_approved_at', { withTimezone: true }),
  discountReason: text('discount_reason'),
  paymentMethod: paymentMethodEnum('payment_method').notNull(),
  creditApprovedByUserId: uuid('credit_approved_by_user_id'),
  creditApprovedAt: timestamp('credit_approved_at', { withTimezone: true }),
  creditReason: text('credit_reason'),
  creditDueDate: date('credit_due_date', { mode: 'string' }),
  paidAmount: numeric('paid_amount', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  paidAt: timestamp('paid_at', { withTimezone: true }),
  isPaid: boolean('is_paid').generatedAlwaysAs(sql`((paid_amount >= total) AND (total > (0)::numeric))`),
  deliveryMethod: deliveryMethodEnum('delivery_method').notNull(),
  receiverKind: receiverKindEnum('receiver_kind')
    .notNull()
    .default(sql`'customer'::receiver_kind`),
  receiverName: text('receiver_name'),
  receiverPhoneE164: text('receiver_phone_e164'),
  deliveryRecipientPhoneE164: text('delivery_recipient_phone_e164'),
  deliveryAddress: text('delivery_address'),
  deliveryGeo: point('delivery_geo', { mode: 'xy' }),
  deliveryComment: text('delivery_comment'),
  deliveryDate: date('delivery_date', { mode: 'string' }),
  deliveryTimeFrom: time('delivery_time_from'),
  deliveryTimeTo: time('delivery_time_to'),
  printOptions: jsonb('print_options')
    .notNull()
    .default(sql`'{"invoice": true, "receipt": true, "waybill": true}'::jsonb`),
  comment: text('comment'),
  onecNumber: text('onec_number'),
  onecDate: timestamp('onec_date', { withTimezone: true }),
  onecStatusRaw: text('onec_status_raw'),
  onecLastSyncAt: timestamp('onec_last_sync_at', { withTimezone: true }),
  onecLinkedByUserId: uuid('onec_linked_by_user_id'),
  onecLinkedAt: timestamp('onec_linked_at', { withTimezone: true }),
  onecSyncState: onecSyncStateEnum('onec_sync_state')
    .notNull()
    .default(sql`'unknown'::onec_sync_state`),
  priceCheckAt: timestamp('price_check_at', { withTimezone: true }),
  onecCheckResult: jsonb('onec_check_result'),
  submittedAt: timestamp('submitted_at', { withTimezone: true }),
  approvedAt: timestamp('approved_at', { withTimezone: true }),
  shippedAt: timestamp('shipped_at', { withTimezone: true }),
  closedAt: timestamp('closed_at', { withTimezone: true }),
  cancelledAt: timestamp('cancelled_at', { withTimezone: true }),
  cancelReason: text('cancel_reason'),
  cancelReasonCode: text('cancel_reason_code'),
  refundIntent: text('refund_intent'),
  cancelRequestedAt: timestamp('cancel_requested_at', { withTimezone: true }),
  cancelRequestedByUserId: uuid('cancel_requested_by_user_id'),
  submitErrorCode: text('submit_error_code'),
  submitErrorMessage: text('submit_error_message'),
  idempotencyKey: text('idempotency_key'),
  rowVersion: integer('row_version')
    .notNull()
    .default(sql`1`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** order_items — 07 §5.38 */
export const orderItems = pgTable('order_items', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  orderId: uuid('order_id').notNull(),
  lineNo: smallint('line_no').notNull(),
  variantId: uuid('variant_id').notNull(),
  productId: uuid('product_id').notNull(),
  packagingId: uuid('packaging_id'),
  quantity: numeric('quantity', { precision: 14, scale: 3 }).notNull(),
  baseQuantity: numeric('base_quantity', { precision: 14, scale: 3 }).notNull(),
  unitCodeSnapshot: text('unit_code_snapshot').notNull(),
  packagingNameSnapshot: text('packaging_name_snapshot'),
  packagingFactorSnapshot: numeric('packaging_factor_snapshot', { precision: 14, scale: 3 }),
  unitPrice: numeric('unit_price', { precision: 14, scale: 2 }).notNull(),
  lineSubtotal: numeric('line_subtotal', { precision: 14, scale: 2 }).notNull(),
  discountPercent: numeric('discount_percent', { precision: 5, scale: 2 })
    .notNull()
    .default(sql`0`),
  customerDiscountAmount: numeric('customer_discount_amount', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  manualDiscountAmount: numeric('manual_discount_amount', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  discountAmount: numeric('discount_amount', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  lineTotal: numeric('line_total', { precision: 14, scale: 2 }).notNull(),
  productNameSnapshot: text('product_name_snapshot').notNull(),
  variantNameSnapshot: text('variant_name_snapshot'),
  skuSnapshot: text('sku_snapshot'),
  barcodeSnapshot: text('barcode_snapshot'),
  onecLineNo: smallint('onec_line_no'),
  onecLineTotal: numeric('onec_line_total', { precision: 14, scale: 2 }),
  shippedQuantity: numeric('shipped_quantity', { precision: 14, scale: 3 })
    .notNull()
    .default(sql`0`),
  returnedQuantity: numeric('returned_quantity', { precision: 14, scale: 3 })
    .notNull()
    .default(sql`0`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** order_status_history — 07 §5.39 */
export const orderStatusHistory = pgTable('order_status_history', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  orderId: uuid('order_id').notNull(),
  fromStatus: orderStatusEnum('from_status'),
  toStatus: orderStatusEnum('to_status').notNull(),
  source: statusChangeSourceEnum('source').notNull(),
  actorUserId: uuid('actor_user_id'),
  onecStatusRaw: text('onec_status_raw'),
  reason: text('reason'),
  errorCode: text('error_code'),
  occurredAt: timestamp('occurred_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  requestId: text('request_id'),
  syncRunId: uuid('sync_run_id'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** payments — 07 §5.40 */
export const payments = pgTable('payments', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  publicNumber: text('public_number').notNull(),
  orderId: uuid('order_id'),
  customerId: uuid('customer_id'),
  method: paymentMethodEnum('method').notNull(),
  qrProvider: text('qr_provider'),
  status: paymentStatusEnum('status')
    .notNull()
    .default(sql`'initiated'::payment_status`),
  amount: numeric('amount', { precision: 14, scale: 2 }).notNull(),
  currency: char('currency', { length: 3 })
    .notNull()
    .default(sql`'KGS'::bpchar`),
  createdByUserId: uuid('created_by_user_id').notNull(),
  receivedByUserId: uuid('received_by_user_id'),
  receivedAt: timestamp('received_at', { withTimezone: true }),
  receivedAmount: numeric('received_amount', { precision: 14, scale: 2 }),
  changeAmount: numeric('change_amount', { precision: 14, scale: 2 }),
  bankAmount: numeric('bank_amount', { precision: 14, scale: 2 }),
  qrPayload: text('qr_payload'),
  qrExpiresAt: timestamp('qr_expires_at', { withTimezone: true }),
  qrProviderRef: text('qr_provider_ref'),
  bankReference: text('bank_reference'),
  qrStatusCheckedAt: timestamp('qr_status_checked_at', { withTimezone: true }),
  qrProviderStatusRaw: text('qr_provider_status_raw'),
  manualConfirmedByUserId: uuid('manual_confirmed_by_user_id'),
  manualConfirmedAt: timestamp('manual_confirmed_at', { withTimezone: true }),
  manualReason: text('manual_reason'),
  reviewReason: text('review_reason'),
  voidedByUserId: uuid('voided_by_user_id'),
  voidedAt: timestamp('voided_at', { withTimezone: true }),
  voidReason: text('void_reason'),
  allocation: jsonb('allocation'),
  onecDocType: text('onec_doc_type'),
  onecNumber: text('onec_number'),
  onecDate: timestamp('onec_date', { withTimezone: true }),
  idempotencyKey: text('idempotency_key').notNull(),
  requestId: text('request_id'),
  rowVersion: integer('row_version')
    .notNull()
    .default(sql`1`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  qrIssuedAt: timestamp('qr_issued_at', { withTimezone: true }),
  qrRefHistory: text('qr_ref_history')
    .array()
    .notNull()
    .default(sql`'{}'::text[]`),
});

/** payment_webhook_events — 07 §5.41 (ядро §17.3, условно Q-014) */
export const paymentWebhookEvents = pgTable('payment_webhook_events', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  provider: text('provider')
    .notNull()
    .default(sql`'bakai'::text`),
  providerEventId: text('provider_event_id').notNull(),
  paymentId: uuid('payment_id'),
  signatureValid: boolean('signature_valid').notNull(),
  payload: jsonb('payload').notNull(),
  receivedAt: timestamp('received_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  processedAt: timestamp('processed_at', { withTimezone: true }),
  processingError: text('processing_error'),
  sourceIp: inet('source_ip'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** shipments — 07 §5.42 (ядро §17.3) */
export const shipments = pgTable('shipments', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref').notNull(),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  onecDocType: text('onec_doc_type').notNull(),
  onecDate: timestamp('onec_date', { withTimezone: true }).notNull(),
  posted: boolean('posted').notNull(),
  orderId: uuid('order_id'),
  customerId: uuid('customer_id').notNull(),
  warehouseId: uuid('warehouse_id'),
  total: numeric('total', { precision: 14, scale: 2 }).notNull(),
  discountTotal: numeric('discount_total', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  currency: char('currency', { length: 3 })
    .notNull()
    .default(sql`'KGS'::bpchar`),
  paymentDueDate: date('payment_due_date', { mode: 'string' }),
  returnedTotal: numeric('returned_total', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  comment: text('comment'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** shipment_items — 07 §5.43 (ядро §17.3) */
export const shipmentItems = pgTable('shipment_items', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  shipmentId: uuid('shipment_id').notNull(),
  onecLineNo: smallint('onec_line_no').notNull(),
  variantId: uuid('variant_id'),
  productNameSnapshot: text('product_name_snapshot').notNull(),
  packagingId: uuid('packaging_id'),
  quantity: numeric('quantity', { precision: 14, scale: 3 }).notNull(),
  baseQuantity: numeric('base_quantity', { precision: 14, scale: 3 }).notNull(),
  unitPrice: numeric('unit_price', { precision: 14, scale: 2 }).notNull(),
  lineTotal: numeric('line_total', { precision: 14, scale: 2 }).notNull(),
  discountAmount: numeric('discount_amount', { precision: 14, scale: 2 }).notNull(),
  returnedQuantity: numeric('returned_quantity', { precision: 14, scale: 3 })
    .notNull()
    .default(sql`0`),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** transactions — 07 §5.44 */
export const transactions = pgTable('transactions', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  kind: transactionKindEnum('kind').notNull(),
  source: transactionSourceEnum('source').notNull(),
  orderId: uuid('order_id'),
  paymentId: uuid('payment_id'),
  returnRequestId: uuid('return_request_id'),
  shipmentId: uuid('shipment_id'),
  customerId: uuid('customer_id'),
  actorUserId: uuid('actor_user_id'),
  amount: numeric('amount', { precision: 14, scale: 2 }).notNull(),
  currency: char('currency', { length: 3 })
    .notNull()
    .default(sql`'KGS'::bpchar`),
  paymentMethod: paymentMethodEnum('payment_method'),
  statusSnapshot: text('status_snapshot').notNull(),
  titleRu: text('title_ru').notNull(),
  details: jsonb('details')
    .notNull()
    .default(sql`'{}'::jsonb`),
  occurredAt: timestamp('occurred_at', { withTimezone: true }).notNull(),
  onecNumber: text('onec_number'),
  onecDocType: text('onec_doc_type'),
  dedupeKey: text('dedupe_key').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** return_requests — 07 §5.45 */
export const returnRequests = pgTable('return_requests', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  publicNumber: text('public_number').notNull(),
  shipmentId: uuid('shipment_id').notNull(),
  orderId: uuid('order_id'),
  customerId: uuid('customer_id').notNull(),
  status: returnRequestStatusEnum('status')
    .notNull()
    .default(sql`'draft'::return_request_status`),
  reason: returnReasonEnum('reason').notNull(),
  reasonComment: text('reason_comment'),
  total: numeric('total', { precision: 14, scale: 2 }).notNull(),
  refundMethodExpected: paymentMethodEnum('refund_method_expected'),
  createdByUserId: uuid('created_by_user_id').notNull(),
  approvedByUserId: uuid('approved_by_user_id'),
  approvedAt: timestamp('approved_at', { withTimezone: true }),
  acceptedAt: timestamp('accepted_at', { withTimezone: true }),
  acceptedByUserId: uuid('accepted_by_user_id'),
  approvalReason: text('approval_reason'),
  submittedAt: timestamp('submitted_at', { withTimezone: true }),
  completedAt: timestamp('completed_at', { withTimezone: true }),
  rejectedAt: timestamp('rejected_at', { withTimezone: true }),
  onecNumber: text('onec_number'),
  onecDate: timestamp('onec_date', { withTimezone: true }),
  onecStatusRaw: text('onec_status_raw'),
  onecResult: text('onec_result'),
  rejectReason: text('reject_reason'),
  rejectedByUserId: uuid('rejected_by_user_id'),
  idempotencyKey: text('idempotency_key'),
  rowVersion: integer('row_version')
    .notNull()
    .default(sql`1`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** return_request_items — 07 §5.46 */
export const returnRequestItems = pgTable('return_request_items', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  returnRequestId: uuid('return_request_id').notNull(),
  shipmentItemId: uuid('shipment_item_id').notNull(),
  variantId: uuid('variant_id').notNull(),
  quantity: numeric('quantity', { precision: 14, scale: 3 }).notNull(),
  unitPrice: numeric('unit_price', { precision: 14, scale: 2 }).notNull(),
  lineTotal: numeric('line_total', { precision: 14, scale: 2 }).notNull(),
  reasonOverride: returnReasonEnum('reason_override'),
  productNameSnapshot: text('product_name_snapshot').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** favorites_products — 07 §5.47 */
export const favoritesProducts = pgTable(
  'favorites_products',
  {
    userId: uuid('user_id').notNull(),
    productId: uuid('product_id').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
  },
  (t) => [primaryKey({ name: 'favorites_products_pkey', columns: [t.userId, t.productId] })],
);

/** favorites_customers — 07 §5.48 */
export const favoritesCustomers = pgTable(
  'favorites_customers',
  {
    userId: uuid('user_id').notNull(),
    customerId: uuid('customer_id').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
  },
  (t) => [primaryKey({ name: 'favorites_customers_pkey', columns: [t.userId, t.customerId] })],
);

/** recent_products — 07 §5.49 */
export const recentProducts = pgTable(
  'recent_products',
  {
    userId: uuid('user_id').notNull(),
    productId: uuid('product_id').notNull(),
    lastViewedAt: timestamp('last_viewed_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    viewCount: integer('view_count')
      .notNull()
      .default(sql`1`),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
  },
  (t) => [primaryKey({ name: 'recent_products_pkey', columns: [t.userId, t.productId] })],
);
