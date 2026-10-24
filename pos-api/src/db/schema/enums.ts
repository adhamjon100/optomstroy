// СГЕНЕРИРОВАНО test/db/codegen/gen-drizzle-schema.ts из каталога PostgreSQL 17 после migrations/*.sql
// (RM-C-006) — вручную не править: новая миграция → `npx tsx test/db/codegen/gen-drizzle-schema.ts`.
// Сверка с БД — test/db/migrate-seed.db-spec.ts («Drizzle-схема совпадает с БД»).

import { pgEnum } from 'drizzle-orm/pg-core';

/** Enum-типы БД (07 §6.1; имена и порядок значений — как в migrations/0001_init.sql). */
export const attributeValueTypeEnum = pgEnum('attribute_value_type', ['text', 'number', 'boolean', 'list']);
export const auditLevelEnum = pgEnum('audit_level', ['app', 'db']);
export const barcodeTypeEnum = pgEnum('barcode_type', ['EAN13', 'EAN8', 'UPC', 'CODE128', 'CODE39', 'QR', 'other']);
export const cartStatusEnum = pgEnum('cart_status', ['active', 'parked', 'converted', 'cleared']);
export const consentKindEnum = pgEnum('consent_kind', [
  'personal_data',
  'sms',
  'biometrics_device',
  'activity_sphere',
  'face_scan',
]);
export const contactKindEnum = pgEnum('contact_kind', ['phone', 'address', 'email', 'other']);
export const customerLinkStatusEnum = pgEnum('customer_link_status', ['proposed', 'confirmed', 'rejected', 'conflict']);
export const customerOnecStatusEnum = pgEnum('customer_onec_status', [
  'n_a',
  'pending',
  'confirmed',
  'rejected',
  'duplicate',
]);
export const customerSourceEnum = pgEnum('customer_source', ['onec', 'pos']);
export const customerTypeEnum = pgEnum('customer_type', ['individual', 'entrepreneur', 'legal']);
export const deliveryMethodEnum = pgEnum('delivery_method', ['pickup', 'delivery']);
export const devicePlatformEnum = pgEnum('device_platform', ['android', 'ios', 'windows']);
export const discountKindEnum = pgEnum('discount_kind', ['percent', 'fixed_amount', 'price_list']);
export const discountSourceEnum = pgEnum('discount_source', ['onec', 'pos']);
export const idempotencyStatusEnum = pgEnum('idempotency_status', ['in_progress', 'completed']);
export const imageStatusEnum = pgEnum('image_status', ['pending', 'downloading', 'ready', 'failed', 'missing_source']);
export const invitationStatusEnum = pgEnum('invitation_status', ['pending', 'accepted', 'revoked', 'expired']);
export const linkMatchMethodEnum = pgEnum('link_match_method', ['phone', 'manual_admin', 'onec_created']);
export const notificationKindEnum = pgEnum('notification_kind', [
  'sync_error',
  'order_status',
  'cart_price_changed',
  'cart_stock_changed',
  'credit_blocked',
  'system',
  'payment_status',
  'return_status',
]);
export const onecSyncStateEnum = pgEnum('onec_sync_state', ['unknown', 'pending', 'linked', 'missing', 'ambiguous']);
export const orderStatusEnum = pgEnum('order_status', [
  'draft',
  'submitting',
  'submit_failed',
  'pending_approval',
  'awaiting_payment',
  'approved',
  'awaiting_shipment',
  'shipped',
  'partially_returned',
  'closed',
  'cancelled',
]);
export const otpPurposeEnum = pgEnum('otp_purpose', [
  'login_or_register',
  'step_up',
  'phone_change_old',
  'phone_change_new',
  'customer_link',
]);
export const otpStatusEnum = pgEnum('otp_status', [
  'sent',
  'verified',
  'expired',
  'locked',
  'failed_delivery',
  'superseded',
]);
export const outboxAggregateEnum = pgEnum('outbox_aggregate', ['order', 'payment', 'customer', 'return_request']);
export const outboxStatusEnum = pgEnum('outbox_status', [
  'pending',
  'sending',
  'sent',
  'confirmed',
  'failed',
  'dead',
  'cancelled',
]);
export const paymentMethodEnum = pgEnum('payment_method', ['cash', 'qr_bakai', 'credit']);
export const paymentStatusEnum = pgEnum('payment_status', [
  'initiated',
  'cash_pending',
  'qr_pending',
  'qr_shown',
  'qr_expired',
  'manual_confirm',
  'credit',
  'received',
  'voided',
  'refunded',
]);
export const printDocumentKindEnum = pgEnum('print_document_kind', ['invoice', 'waybill', 'receipt']);
export const printJobStatusEnum = pgEnum('print_job_status', ['queued', 'ready', 'failed', 'unavailable_onec']);
export const receiverKindEnum = pgEnum('receiver_kind', ['customer', 'other_person']);
export const returnReasonEnum = pgEnum('return_reason', [
  'defect',
  'wrong_item',
  'not_suitable',
  'surplus',
  'seller_error',
  'other',
]);
export const returnRequestStatusEnum = pgEnum('return_request_status', [
  'draft',
  'submitted',
  'accepted',
  'rejected',
  'completed',
]);
export const roleCodeEnum = pgEnum('role_code', [
  'seller',
  'cashier',
  'senior_seller',
  'admin',
  'owner',
  'customer',
  'integration',
]);
export const sessionKindEnum = pgEnum('session_kind', ['standard', 'biometric']);
export const smsStatusEnum = pgEnum('sms_status', ['queued', 'sent', 'delivered', 'failed', 'expired']);
export const statusChangeSourceEnum = pgEnum('status_change_source', [
  'pos_user',
  'pos_system',
  'onec_sync',
  'onec_response',
]);
export const stepUpMethodEnum = pgEnum('step_up_method', ['pin', 'biometric', 'otp']);
export const syncEntityEnum = pgEnum('sync_entity', [
  'categories',
  'products',
  'variants',
  'attributes',
  'units',
  'barcodes',
  'images',
  'warehouses',
  'stock',
  'prices',
  'customers',
  'receivables',
  'sales_history',
  'order_status',
  'discounts',
  'payment_docs',
  'return_docs',
]);
export const syncModeEnum = pgEnum('sync_mode', ['full', 'incremental', 'manual', 'reconcile']);
export const syncRunStatusEnum = pgEnum('sync_run_status', ['queued', 'running', 'success', 'partial', 'failed']);
export const syncTriggerEnum = pgEnum('sync_trigger', ['schedule', 'manual', 'retry', 'dependency']);
export const transactionKindEnum = pgEnum('transaction_kind', [
  'order_created',
  'order_cancelled',
  'payment_received',
  'payment_voided',
  'refund',
  'discount_override',
  'credit_sale_approved',
  'manual_qr_confirm',
  'return_requested',
]);
export const transactionSourceEnum = pgEnum('transaction_source', ['pos', 'onec']);
export const userKindEnum = pgEnum('user_kind', ['staff', 'customer']);
export const userStatusEnum = pgEnum('user_status', ['pending', 'pending_activation', 'active', 'blocked', 'deleted']);
