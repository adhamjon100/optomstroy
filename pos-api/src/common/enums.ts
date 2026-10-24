// GENERATED FILE — DO NOT EDIT.
// Source: contracts/enums.json (optomstroy-pos-enums 1.2.0, sha256 3e1a7b459ff5b94974e57aa4b3b82b2b88942b0c84fb3e21f8a60b1198357d0a)
// Generator: scripts/gen_enums.py (RM-B-009). Owners: 07 §6.1/§6.1.1, 08 §2.4/§3.8 (R0 §18.1).
/* eslint-disable */

export const ENUMS_CONTRACT_VERSION = '1.2.0' as const;

// ===== 07 §6.1 — типы PostgreSQL (CREATE TYPE … AS ENUM) =====

/**
 * user_kind — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
 * Используется: users.kind.
 */
export const USER_KIND_VALUES = [
  'staff',
  'customer',
] as const;
export type UserKind = (typeof USER_KIND_VALUES)[number];
export function isUserKind(value: unknown): value is UserKind {
  return typeof value === 'string' && (USER_KIND_VALUES as readonly string[]).includes(value);
}

/**
 * user_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
 * Используется: users.status.
 */
export const USER_STATUS_VALUES = [
  'pending',
  'pending_activation',
  'active',
  'blocked',
  'deleted',
] as const;
export type UserStatus = (typeof USER_STATUS_VALUES)[number];
export function isUserStatus(value: unknown): value is UserStatus {
  return typeof value === 'string' && (USER_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * role_code — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
 * Используется: roles.code, user_invitations.role, role_discount_limits.role, price_lists.visible_to_roles[], audit_logs.actor_role.
 */
export const ROLE_CODE_VALUES = [
  'seller',
  'cashier',
  'senior_seller',
  'admin',
  'owner',
  'customer',
  'integration',
] as const;
export type RoleCode = (typeof ROLE_CODE_VALUES)[number];
export function isRoleCode(value: unknown): value is RoleCode {
  return typeof value === 'string' && (ROLE_CODE_VALUES as readonly string[]).includes(value);
}

/**
 * customer_link_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
 * Используется: customer_links.status.
 */
export const CUSTOMER_LINK_STATUS_VALUES = [
  'proposed',
  'confirmed',
  'rejected',
  'conflict',
] as const;
export type CustomerLinkStatus = (typeof CUSTOMER_LINK_STATUS_VALUES)[number];
export function isCustomerLinkStatus(value: unknown): value is CustomerLinkStatus {
  return typeof value === 'string' && (CUSTOMER_LINK_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * cart_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
 * Используется: carts.status.
 */
export const CART_STATUS_VALUES = [
  'active',
  'parked',
  'converted',
  'cleared',
] as const;
export type CartStatus = (typeof CART_STATUS_VALUES)[number];
export function isCartStatus(value: unknown): value is CartStatus {
  return typeof value === 'string' && (CART_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * order_status — 07 §6.1 (CREATE TYPE). Источник: D-20.
 * Используется: orders.status, order_status_history.from_status/to_status.
 */
export const ORDER_STATUS_VALUES = [
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
] as const;
export type OrderStatus = (typeof ORDER_STATUS_VALUES)[number];
export function isOrderStatus(value: unknown): value is OrderStatus {
  return typeof value === 'string' && (ORDER_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * delivery_method — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
 * Используется: orders.delivery_method.
 */
export const DELIVERY_METHOD_VALUES = [
  'pickup',
  'delivery',
] as const;
export type DeliveryMethod = (typeof DELIVERY_METHOD_VALUES)[number];
export function isDeliveryMethod(value: unknown): value is DeliveryMethod {
  return typeof value === 'string' && (DELIVERY_METHOD_VALUES as readonly string[]).includes(value);
}

/**
 * receiver_kind — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
 * Используется: orders.receiver_kind.
 */
export const RECEIVER_KIND_VALUES = [
  'customer',
  'other_person',
] as const;
export type ReceiverKind = (typeof RECEIVER_KIND_VALUES)[number];
export function isReceiverKind(value: unknown): value is ReceiverKind {
  return typeof value === 'string' && (RECEIVER_KIND_VALUES as readonly string[]).includes(value);
}

/**
 * payment_method — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
 * Используется: orders.payment_method, payments.method, transactions.payment_method, return_requests.refund_method_expected.
 */
export const PAYMENT_METHOD_VALUES = [
  'cash',
  'qr_bakai',
  'credit',
] as const;
export type PaymentMethod = (typeof PAYMENT_METHOD_VALUES)[number];
export function isPaymentMethod(value: unknown): value is PaymentMethod {
  return typeof value === 'string' && (PAYMENT_METHOD_VALUES as readonly string[]).includes(value);
}

/**
 * payment_status — 07 §6.1 (CREATE TYPE). Источник: D-21.
 * Используется: payments.status.
 */
export const PAYMENT_STATUS_VALUES = [
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
] as const;
export type PaymentStatus = (typeof PAYMENT_STATUS_VALUES)[number];
export function isPaymentStatus(value: unknown): value is PaymentStatus {
  return typeof value === 'string' && (PAYMENT_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * return_request_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
 * Используется: return_requests.status.
 */
export const RETURN_REQUEST_STATUS_VALUES = [
  'draft',
  'submitted',
  'accepted',
  'rejected',
  'completed',
] as const;
export type ReturnRequestStatus = (typeof RETURN_REQUEST_STATUS_VALUES)[number];
export function isReturnRequestStatus(value: unknown): value is ReturnRequestStatus {
  return typeof value === 'string' && (RETURN_REQUEST_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * transaction_kind — 07 §6.1 (CREATE TYPE). Источник: ядро §6 + §17.3, §18.2 п.10 (return_requested — could).
 * Используется: transactions.kind.
 */
export const TRANSACTION_KIND_VALUES = [
  'order_created',
  'order_cancelled',
  'payment_received',
  'payment_voided',
  'refund',
  'discount_override',
  'credit_sale_approved',
  'manual_qr_confirm',
  'return_requested',
] as const;
export type TransactionKind = (typeof TRANSACTION_KIND_VALUES)[number];
export function isTransactionKind(value: unknown): value is TransactionKind {
  return typeof value === 'string' && (TRANSACTION_KIND_VALUES as readonly string[]).includes(value);
}

/**
 * sync_entity — 07 §6.1 (CREATE TYPE). Источник: ядро §6 + §17.3.
 * Используется: sync_runs.entity, sync_state.entity, sync_errors.entity, sync_entity_versions.entity.
 */
export const SYNC_ENTITY_VALUES = [
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
] as const;
export type SyncEntity = (typeof SYNC_ENTITY_VALUES)[number];
export function isSyncEntity(value: unknown): value is SyncEntity {
  return typeof value === 'string' && (SYNC_ENTITY_VALUES as readonly string[]).includes(value);
}

/**
 * sync_mode — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
 * Используется: sync_runs.mode.
 */
export const SYNC_MODE_VALUES = [
  'full',
  'incremental',
  'manual',
  'reconcile',
] as const;
export type SyncMode = (typeof SYNC_MODE_VALUES)[number];
export function isSyncMode(value: unknown): value is SyncMode {
  return typeof value === 'string' && (SYNC_MODE_VALUES as readonly string[]).includes(value);
}

/**
 * sync_run_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
 * Используется: sync_runs.status.
 */
export const SYNC_RUN_STATUS_VALUES = [
  'queued',
  'running',
  'success',
  'partial',
  'failed',
] as const;
export type SyncRunStatus = (typeof SYNC_RUN_STATUS_VALUES)[number];
export function isSyncRunStatus(value: unknown): value is SyncRunStatus {
  return typeof value === 'string' && (SYNC_RUN_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * outbox_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6 + v1.7 §22.1 (cancelled).
 * Используется: onec_outbox.status; автомат — §6.5.
 */
export const OUTBOX_STATUS_VALUES = [
  'pending',
  'sending',
  'sent',
  'confirmed',
  'failed',
  'dead',
  'cancelled',
] as const;
export type OutboxStatus = (typeof OUTBOX_STATUS_VALUES)[number];
export function isOutboxStatus(value: unknown): value is OutboxStatus {
  return typeof value === 'string' && (OUTBOX_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * notification_kind — 07 §6.1 (CREATE TYPE). Источник: ядро §6 + §17.3.
 * Используется: notifications.kind.
 */
export const NOTIFICATION_KIND_VALUES = [
  'sync_error',
  'order_status',
  'cart_price_changed',
  'cart_stock_changed',
  'credit_blocked',
  'system',
  'payment_status',
  'return_status',
] as const;
export type NotificationKind = (typeof NOTIFICATION_KIND_VALUES)[number];
export function isNotificationKind(value: unknown): value is NotificationKind {
  return typeof value === 'string' && (NOTIFICATION_KIND_VALUES as readonly string[]).includes(value);
}

/**
 * invitation_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.3.
 * Используется: user_invitations.status.
 */
export const INVITATION_STATUS_VALUES = [
  'pending',
  'accepted',
  'revoked',
  'expired',
] as const;
export type InvitationStatus = (typeof INVITATION_STATUS_VALUES)[number];
export function isInvitationStatus(value: unknown): value is InvitationStatus {
  return typeof value === 'string' && (INVITATION_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * device_platform — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.8.
 * Используется: devices.platform.
 */
export const DEVICE_PLATFORM_VALUES = [
  'android',
  'ios',
  'windows',
] as const;
export type DevicePlatform = (typeof DEVICE_PLATFORM_VALUES)[number];
export function isDevicePlatform(value: unknown): value is DevicePlatform {
  return typeof value === 'string' && (DEVICE_PLATFORM_VALUES as readonly string[]).includes(value);
}

/**
 * session_kind — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.9, R6 §2.2.
 * Используется: sessions.kind.
 */
export const SESSION_KIND_VALUES = [
  'standard',
  'biometric',
] as const;
export type SessionKind = (typeof SESSION_KIND_VALUES)[number];
export function isSessionKind(value: unknown): value is SessionKind {
  return typeof value === 'string' && (SESSION_KIND_VALUES as readonly string[]).includes(value);
}

/**
 * step_up_method — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.9.
 * Используется: sessions.step_up_method, audit_logs.step_up_method.
 */
export const STEP_UP_METHOD_VALUES = [
  'pin',
  'biometric',
  'otp',
] as const;
export type StepUpMethod = (typeof STEP_UP_METHOD_VALUES)[number];
export function isStepUpMethod(value: unknown): value is StepUpMethod {
  return typeof value === 'string' && (STEP_UP_METHOD_VALUES as readonly string[]).includes(value);
}

/**
 * otp_purpose — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3, §18.2 п.7; карточка §5.11.
 * Используется: otp_challenges.purpose; тело POST /auth/otp/request (08).
 * Не используются: login.
 */
export const OTP_PURPOSE_VALUES = [
  'login_or_register',
  'step_up',
  'phone_change_old',
  'phone_change_new',
  'customer_link',
] as const;
export type OtpPurpose = (typeof OTP_PURPOSE_VALUES)[number];
export function isOtpPurpose(value: unknown): value is OtpPurpose {
  return typeof value === 'string' && (OTP_PURPOSE_VALUES as readonly string[]).includes(value);
}

/**
 * otp_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.11.
 * Используется: otp_challenges.status.
 */
export const OTP_STATUS_VALUES = [
  'sent',
  'verified',
  'expired',
  'locked',
  'failed_delivery',
  'superseded',
] as const;
export type OtpStatus = (typeof OTP_STATUS_VALUES)[number];
export function isOtpStatus(value: unknown): value is OtpStatus {
  return typeof value === 'string' && (OTP_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * consent_kind — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3, §19.3; карточка §5.14.
 * Используется: consents.kind; DTO consents[].kind в POST /registration/complete (08).
 */
export const CONSENT_KIND_VALUES = [
  'personal_data',
  'sms',
  'biometrics_device',
  'activity_sphere',
  'face_scan',
] as const;
export type ConsentKind = (typeof CONSENT_KIND_VALUES)[number];
export function isConsentKind(value: unknown): value is ConsentKind {
  return typeof value === 'string' && (CONSENT_KIND_VALUES as readonly string[]).includes(value);
}

/**
 * attribute_value_type — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.18.
 * Используется: product_attributes.value_type.
 */
export const ATTRIBUTE_VALUE_TYPE_VALUES = [
  'text',
  'number',
  'boolean',
  'list',
] as const;
export type AttributeValueType = (typeof ATTRIBUTE_VALUE_TYPE_VALUES)[number];
export function isAttributeValueType(value: unknown): value is AttributeValueType {
  return typeof value === 'string' && (ATTRIBUTE_VALUE_TYPE_VALUES as readonly string[]).includes(value);
}

/**
 * barcode_type — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.22.
 * Используется: barcodes.type.
 */
export const BARCODE_TYPE_VALUES = [
  'EAN13',
  'EAN8',
  'UPC',
  'CODE128',
  'CODE39',
  'QR',
  'other',
] as const;
export type BarcodeType = (typeof BARCODE_TYPE_VALUES)[number];
export function isBarcodeType(value: unknown): value is BarcodeType {
  return typeof value === 'string' && (BARCODE_TYPE_VALUES as readonly string[]).includes(value);
}

/**
 * image_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.23.
 * Используется: product_images.status.
 */
export const IMAGE_STATUS_VALUES = [
  'pending',
  'downloading',
  'ready',
  'failed',
  'missing_source',
] as const;
export type ImageStatus = (typeof IMAGE_STATUS_VALUES)[number];
export function isImageStatus(value: unknown): value is ImageStatus {
  return typeof value === 'string' && (IMAGE_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * customer_source — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.28.
 * Используется: customers.source.
 */
export const CUSTOMER_SOURCE_VALUES = [
  'onec',
  'pos',
] as const;
export type CustomerSource = (typeof CUSTOMER_SOURCE_VALUES)[number];
export function isCustomerSource(value: unknown): value is CustomerSource {
  return typeof value === 'string' && (CUSTOMER_SOURCE_VALUES as readonly string[]).includes(value);
}

/**
 * customer_type — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3, §19.4; карточка §5.28.
 * Используется: customers.customer_type.
 */
export const CUSTOMER_TYPE_VALUES = [
  'individual',
  'entrepreneur',
  'legal',
] as const;
export type CustomerType = (typeof CUSTOMER_TYPE_VALUES)[number];
export function isCustomerType(value: unknown): value is CustomerType {
  return typeof value === 'string' && (CUSTOMER_TYPE_VALUES as readonly string[]).includes(value);
}

/**
 * customer_onec_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.28.
 * Используется: customers.onec_status.
 */
export const CUSTOMER_ONEC_STATUS_VALUES = [
  'n_a',
  'pending',
  'confirmed',
  'rejected',
  'duplicate',
] as const;
export type CustomerOnecStatus = (typeof CUSTOMER_ONEC_STATUS_VALUES)[number];
export function isCustomerOnecStatus(value: unknown): value is CustomerOnecStatus {
  return typeof value === 'string' && (CUSTOMER_ONEC_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * contact_kind — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.29.
 * Используется: customer_contacts.kind.
 */
export const CONTACT_KIND_VALUES = [
  'phone',
  'address',
  'email',
  'other',
] as const;
export type ContactKind = (typeof CONTACT_KIND_VALUES)[number];
export function isContactKind(value: unknown): value is ContactKind {
  return typeof value === 'string' && (CONTACT_KIND_VALUES as readonly string[]).includes(value);
}

/**
 * link_match_method — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.30.
 * Используется: customer_links.match_method.
 */
export const LINK_MATCH_METHOD_VALUES = [
  'phone',
  'manual_admin',
  'onec_created',
] as const;
export type LinkMatchMethod = (typeof LINK_MATCH_METHOD_VALUES)[number];
export function isLinkMatchMethod(value: unknown): value is LinkMatchMethod {
  return typeof value === 'string' && (LINK_MATCH_METHOD_VALUES as readonly string[]).includes(value);
}

/**
 * discount_source — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.33.
 * Используется: discount_rules.source.
 */
export const DISCOUNT_SOURCE_VALUES = [
  'onec',
  'pos',
] as const;
export type DiscountSource = (typeof DISCOUNT_SOURCE_VALUES)[number];
export function isDiscountSource(value: unknown): value is DiscountSource {
  return typeof value === 'string' && (DISCOUNT_SOURCE_VALUES as readonly string[]).includes(value);
}

/**
 * discount_kind — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.33.
 * Используется: discount_rules.kind.
 */
export const DISCOUNT_KIND_VALUES = [
  'percent',
  'fixed_amount',
  'price_list',
] as const;
export type DiscountKind = (typeof DISCOUNT_KIND_VALUES)[number];
export function isDiscountKind(value: unknown): value is DiscountKind {
  return typeof value === 'string' && (DISCOUNT_KIND_VALUES as readonly string[]).includes(value);
}

/**
 * status_change_source — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.39.
 * Используется: order_status_history.source.
 */
export const STATUS_CHANGE_SOURCE_VALUES = [
  'pos_user',
  'pos_system',
  'onec_sync',
  'onec_response',
] as const;
export type StatusChangeSource = (typeof STATUS_CHANGE_SOURCE_VALUES)[number];
export function isStatusChangeSource(value: unknown): value is StatusChangeSource {
  return typeof value === 'string' && (STATUS_CHANGE_SOURCE_VALUES as readonly string[]).includes(value);
}

/**
 * transaction_source — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.44.
 * Используется: transactions.source.
 */
export const TRANSACTION_SOURCE_VALUES = [
  'pos',
  'onec',
] as const;
export type TransactionSource = (typeof TRANSACTION_SOURCE_VALUES)[number];
export function isTransactionSource(value: unknown): value is TransactionSource {
  return typeof value === 'string' && (TRANSACTION_SOURCE_VALUES as readonly string[]).includes(value);
}

/**
 * return_reason — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.45, R7 §6, ядро §17.3.
 * Используется: return_requests.reason, return_request_items.reason_override.
 * Не используются: excess.
 */
export const RETURN_REASON_VALUES = [
  'defect',
  'wrong_item',
  'not_suitable',
  'surplus',
  'seller_error',
  'other',
] as const;
export type ReturnReason = (typeof RETURN_REASON_VALUES)[number];
export function isReturnReason(value: unknown): value is ReturnReason {
  return typeof value === 'string' && (RETURN_REASON_VALUES as readonly string[]).includes(value);
}

/**
 * sync_trigger — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.51.
 * Используется: sync_runs.trigger.
 */
export const SYNC_TRIGGER_VALUES = [
  'schedule',
  'manual',
  'retry',
  'dependency',
] as const;
export type SyncTrigger = (typeof SYNC_TRIGGER_VALUES)[number];
export function isSyncTrigger(value: unknown): value is SyncTrigger {
  return typeof value === 'string' && (SYNC_TRIGGER_VALUES as readonly string[]).includes(value);
}

/**
 * outbox_aggregate — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.55, ядро §17.3.
 * Используется: onec_outbox.aggregate_type (отмена заказа — order + operation='cancel').
 */
export const OUTBOX_AGGREGATE_VALUES = [
  'order',
  'payment',
  'customer',
  'return_request',
] as const;
export type OutboxAggregate = (typeof OUTBOX_AGGREGATE_VALUES)[number];
export function isOutboxAggregate(value: unknown): value is OutboxAggregate {
  return typeof value === 'string' && (OUTBOX_AGGREGATE_VALUES as readonly string[]).includes(value);
}

/**
 * idempotency_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.56.
 * Используется: idempotency_keys.status.
 */
export const IDEMPOTENCY_STATUS_VALUES = [
  'in_progress',
  'completed',
] as const;
export type IdempotencyStatus = (typeof IDEMPOTENCY_STATUS_VALUES)[number];
export function isIdempotencyStatus(value: unknown): value is IdempotencyStatus {
  return typeof value === 'string' && (IDEMPOTENCY_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * audit_level — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.57.
 * Используется: audit_logs.level.
 */
export const AUDIT_LEVEL_VALUES = [
  'app',
  'db',
] as const;
export type AuditLevel = (typeof AUDIT_LEVEL_VALUES)[number];
export function isAuditLevel(value: unknown): value is AuditLevel {
  return typeof value === 'string' && (AUDIT_LEVEL_VALUES as readonly string[]).includes(value);
}

/**
 * print_document_kind — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.60.
 * Используется: print_jobs.document_kind.
 */
export const PRINT_DOCUMENT_KIND_VALUES = [
  'invoice',
  'waybill',
  'receipt',
] as const;
export type PrintDocumentKind = (typeof PRINT_DOCUMENT_KIND_VALUES)[number];
export function isPrintDocumentKind(value: unknown): value is PrintDocumentKind {
  return typeof value === 'string' && (PRINT_DOCUMENT_KIND_VALUES as readonly string[]).includes(value);
}

/**
 * print_job_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.60.
 * Используется: print_jobs.status.
 */
export const PRINT_JOB_STATUS_VALUES = [
  'queued',
  'ready',
  'failed',
  'unavailable_onec',
] as const;
export type PrintJobStatus = (typeof PRINT_JOB_STATUS_VALUES)[number];
export function isPrintJobStatus(value: unknown): value is PrintJobStatus {
  return typeof value === 'string' && (PRINT_JOB_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * sms_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.61.
 * Используется: sms_outbox.status.
 */
export const SMS_STATUS_VALUES = [
  'queued',
  'sent',
  'delivered',
  'failed',
  'expired',
] as const;
export type SmsStatus = (typeof SMS_STATUS_VALUES)[number];
export function isSmsStatus(value: unknown): value is SmsStatus {
  return typeof value === 'string' && (SMS_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * onec_sync_state — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §20.2 п.10; карточка §5.37, §6.5.
 * Используется: orders.onec_sync_state.
 */
export const ONEC_SYNC_STATE_VALUES = [
  'unknown',
  'pending',
  'linked',
  'missing',
  'ambiguous',
] as const;
export type OnecSyncState = (typeof ONEC_SYNC_STATE_VALUES)[number];
export function isOnecSyncState(value: unknown): value is OnecSyncState {
  return typeof value === 'string' && (ONEC_SYNC_STATE_VALUES as readonly string[]).includes(value);
}

// ===== 07 §6.1.1 — CHECK-перечни текстовых полей =====

/**
 * locale — 07 §6.1.1 (CHECK). Поля: user_profiles.locale.
 * Источник: проектное.
 */
export const LOCALE_VALUES = [
  'ru',
  'ky',
  'en',
] as const;
export type Locale = (typeof LOCALE_VALUES)[number];
export function isLocale(value: unknown): value is Locale {
  return typeof value === 'string' && (LOCALE_VALUES as readonly string[]).includes(value);
}

/**
 * invitation_role — 07 §6.1.1 (CHECK). Поля: user_invitations.role.
 * Источник: D-07, D-15.
 */
export const INVITATION_ROLE_VALUES = [
  'seller',
  'cashier',
  'senior_seller',
  'admin',
  'owner',
] as const;
export type InvitationRole = (typeof INVITATION_ROLE_VALUES)[number];
export function isInvitationRole(value: unknown): value is InvitationRole {
  return typeof value === 'string' && (INVITATION_ROLE_VALUES as readonly string[]).includes(value);
}

/**
 * session_revoke_reason — 07 §6.1.1 (CHECK). Поля: sessions.revoke_reason.
 * Источник: D-12, ядро §18.2 п.8; 09 §8.3, миграция 0003 (EQ-AUTH-03, ADR-088).
 */
export const SESSION_REVOKE_REASON_VALUES = [
  'logout',
  'logout_all',
  'reuse_detected',
  'admin',
  'phone_changed',
  'role_changed',
  'expired',
  'device_revoked',
  'blocked',
  'session_limit',
  'device_mismatch',
  'biometric_invalidated',
  'refresh_replay',
] as const;
export type SessionRevokeReason = (typeof SESSION_REVOKE_REASON_VALUES)[number];
export function isSessionRevokeReason(value: unknown): value is SessionRevokeReason {
  return typeof value === 'string' && (SESSION_REVOKE_REASON_VALUES as readonly string[]).includes(value);
}

/**
 * token_kind — 07 §6.1.1 (CHECK). Поля: token_denylist.token_kind.
 * Источник: ядро §17.3, §18.2 п.6.
 */
export const TOKEN_KIND_VALUES = [
  'access',
  'registration',
  'step_up',
] as const;
export type TokenKind = (typeof TOKEN_KIND_VALUES)[number];
export function isTokenKind(value: unknown): value is TokenKind {
  return typeof value === 'string' && (TOKEN_KIND_VALUES as readonly string[]).includes(value);
}

/**
 * token_deny_reason — 07 §6.1.1 (CHECK). Поля: token_denylist.reason.
 * Источник: ядро §18.2 п.6.
 */
export const TOKEN_DENY_REASON_VALUES = [
  'logout',
  'logout_all',
  'role_changed',
  'blocked',
  'used',
  'revoked',
] as const;
export type TokenDenyReason = (typeof TOKEN_DENY_REASON_VALUES)[number];
export function isTokenDenyReason(value: unknown): value is TokenDenyReason {
  return typeof value === 'string' && (TOKEN_DENY_REASON_VALUES as readonly string[]).includes(value);
}

/**
 * rate_limit_scope — 07 §6.1.1 (CHECK). Поля: rate_limit_counters.scope.
 * Источник: D-10, D-44; миграция 0003 (EQ-AUTH-01, ADR-088).
 */
export const RATE_LIMIT_SCOPE_VALUES = [
  'otp_phone_15m',
  'otp_phone_24h',
  'otp_ip_1h',
  'otp_device_24h',
  'login_ip_1h',
  'step_up_user_1h',
  'webhook_ip_1m',
  'otp_ip_10m',
  'otp_ip_24h',
  'otp_device_10m',
  'otp_global_1m',
  'otp_verify_ip_10m',
  'pin_user_device_10m',
  'admin_user_1m',
] as const;
export type RateLimitScope = (typeof RATE_LIMIT_SCOPE_VALUES)[number];
export function isRateLimitScope(value: unknown): value is RateLimitScope {
  return typeof value === 'string' && (RATE_LIMIT_SCOPE_VALUES as readonly string[]).includes(value);
}

/**
 * integration_token_scope — 07 §6.1.1 (CHECK). Поля: integration_tokens.scope.
 * Источник: ядро §17.3.
 */
export const INTEGRATION_TOKEN_SCOPE_VALUES = [
  'onec_inbound',
] as const;
export type IntegrationTokenScope = (typeof INTEGRATION_TOKEN_SCOPE_VALUES)[number];
export function isIntegrationTokenScope(value: unknown): value is IntegrationTokenScope {
  return typeof value === 'string' && (INTEGRATION_TOKEN_SCOPE_VALUES as readonly string[]).includes(value);
}

/**
 * integration_token_source — 07 §6.1.1 (CHECK). Поля: integration_tokens.source.
 * Источник: ядро §18.2 п.4.
 */
export const INTEGRATION_TOKEN_SOURCE_VALUES = [
  'operator_script',
] as const;
export type IntegrationTokenSource = (typeof INTEGRATION_TOKEN_SOURCE_VALUES)[number];
export function isIntegrationTokenSource(value: unknown): value is IntegrationTokenSource {
  return typeof value === 'string' && (INTEGRATION_TOKEN_SOURCE_VALUES as readonly string[]).includes(value);
}

/**
 * integration_token_revoke_reason — 07 §6.1.1 (CHECK). Поля: integration_tokens.revoke_reason.
 * Источник: ядро §18.2 п.4.
 */
export const INTEGRATION_TOKEN_REVOKE_REASON_VALUES = [
  'rotated',
  'incident',
  'disabled',
  'expired',
] as const;
export type IntegrationTokenRevokeReason = (typeof INTEGRATION_TOKEN_REVOKE_REASON_VALUES)[number];
export function isIntegrationTokenRevokeReason(value: unknown): value is IntegrationTokenRevokeReason {
  return typeof value === 'string' && (INTEGRATION_TOKEN_REVOKE_REASON_VALUES as readonly string[]).includes(value);
}

/**
 * receivable_document_kind — 07 §6.1.1 (CHECK). Поля: receivable_documents.kind.
 * Источник: ядро §19.2.
 */
export const RECEIVABLE_DOCUMENT_KIND_VALUES = [
  'invoice',
  'payment',
  'return',
  'discount',
  'adjustment',
] as const;
export type ReceivableDocumentKind = (typeof RECEIVABLE_DOCUMENT_KIND_VALUES)[number];
export function isReceivableDocumentKind(value: unknown): value is ReceivableDocumentKind {
  return typeof value === 'string' && (RECEIVABLE_DOCUMENT_KIND_VALUES as readonly string[]).includes(value);
}

/**
 * receivable_document_status — 07 §6.1.1 (CHECK). Поля: receivable_documents.status.
 * Источник: ядро §19.2 (DEBT-003).
 */
export const RECEIVABLE_DOCUMENT_STATUS_VALUES = [
  'posted',
  'not_posted',
  'due',
] as const;
export type ReceivableDocumentStatus = (typeof RECEIVABLE_DOCUMENT_STATUS_VALUES)[number];
export function isReceivableDocumentStatus(value: unknown): value is ReceivableDocumentStatus {
  return typeof value === 'string' && (RECEIVABLE_DOCUMENT_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * review_reason — 07 §6.1.1 (CHECK). Поля: payments.review_reason.
 * Источник: ядро §17.2 (D-21), v1.7 §22.2, v1.8 §23.4.
 */
export const REVIEW_REASON_VALUES = [
  'amount_mismatch',
  'unknown_reference',
  'no_webhook',
  'late_payment',
] as const;
export type ReviewReason = (typeof REVIEW_REASON_VALUES)[number];
export function isReviewReason(value: unknown): value is ReviewReason {
  return typeof value === 'string' && (REVIEW_REASON_VALUES as readonly string[]).includes(value);
}

/**
 * cancel_reason_code — 07 §6.1.1 (CHECK). Поля: orders.cancel_reason_code.
 * Источник: ядро v1.7 §22.9; DTO reasonCode 08 §4.8.4.
 */
export const CANCEL_REASON_CODE_VALUES = [
  'customer_refused',
  'duplicate',
  'error',
  'other',
] as const;
export type CancelReasonCode = (typeof CANCEL_REASON_CODE_VALUES)[number];
export function isCancelReasonCode(value: unknown): value is CancelReasonCode {
  return typeof value === 'string' && (CANCEL_REASON_CODE_VALUES as readonly string[]).includes(value);
}

/**
 * refund_intent — 07 §6.1.1 (CHECK). Поля: orders.refund_intent.
 * Источник: ядро v1.7 §22.9; DTO refundIntent 08 §4.8.4.
 */
export const REFUND_INTENT_VALUES = [
  'none',
  'refund',
  'advance',
] as const;
export type RefundIntent = (typeof REFUND_INTENT_VALUES)[number];
export function isRefundIntent(value: unknown): value is RefundIntent {
  return typeof value === 'string' && (REFUND_INTENT_VALUES as readonly string[]).includes(value);
}

/**
 * order_created_via — 07 §6.1.1 (CHECK). Поля: orders.created_via.
 * Источник: ядро v1.9 §24.2.
 */
export const ORDER_CREATED_VIA_VALUES = [
  'staff',
  'customer',
] as const;
export type OrderCreatedVia = (typeof ORDER_CREATED_VIA_VALUES)[number];
export function isOrderCreatedVia(value: unknown): value is OrderCreatedVia {
  return typeof value === 'string' && (ORDER_CREATED_VIA_VALUES as readonly string[]).includes(value);
}

/**
 * qr_provider_mode — 07 §6.1.1 (CHECK). Поля: payments.qr_provider.
 * Источник: ядро v1.9 §24.4.
 */
export const QR_PROVIDER_MODE_VALUES = [
  'none',
  'onec',
  'bakai',
] as const;
export type QrProviderMode = (typeof QR_PROVIDER_MODE_VALUES)[number];
export function isQrProviderMode(value: unknown): value is QrProviderMode {
  return typeof value === 'string' && (QR_PROVIDER_MODE_VALUES as readonly string[]).includes(value);
}

/**
 * return_onec_result — 07 §6.1.1 (CHECK). Поля: return_requests.onec_result.
 * Источник: R7 §6.
 */
export const RETURN_ONEC_RESULT_VALUES = [
  'money_refunded',
  'offset_against_debt',
  'pending',
] as const;
export type ReturnOnecResult = (typeof RETURN_ONEC_RESULT_VALUES)[number];
export function isReturnOnecResult(value: unknown): value is ReturnOnecResult {
  return typeof value === 'string' && (RETURN_ONEC_RESULT_VALUES as readonly string[]).includes(value);
}

/**
 * return_approval_reason — 07 §6.1.1 (CHECK). Поля: return_requests.approval_reason.
 * Источник: ядро §19.2.
 */
export const RETURN_APPROVAL_REASON_VALUES = [
  'return_threshold_exceeded',
] as const;
export type ReturnApprovalReason = (typeof RETURN_APPROVAL_REASON_VALUES)[number];
export function isReturnApprovalReason(value: unknown): value is ReturnApprovalReason {
  return typeof value === 'string' && (RETURN_APPROVAL_REASON_VALUES as readonly string[]).includes(value);
}

/**
 * notification_severity — 07 §6.1.1 (CHECK). Поля: notifications.severity.
 * Источник: проектное.
 */
export const NOTIFICATION_SEVERITY_VALUES = [
  'info',
  'warning',
  'error',
] as const;
export type NotificationSeverity = (typeof NOTIFICATION_SEVERITY_VALUES)[number];
export function isNotificationSeverity(value: unknown): value is NotificationSeverity {
  return typeof value === 'string' && (NOTIFICATION_SEVERITY_VALUES as readonly string[]).includes(value);
}

/**
 * sync_error_code — 07 §6.1.1 (CHECK). Поля: sync_errors.error_code, onec_outbox.last_error_code, sync_node_state.last_error_code.
 * Источник: 08 §2.4 абзац «Коды журнала синхронизации» (владелец, порядок); 07 §6.1.1 (CHECK); ядро §17.4, §18.2 п.10; перечень в API — 08 §2.4 (отдельный абзац).
 */
export const SYNC_ERROR_CODE_VALUES = [
  'DUPLICATE_SUSPECTED',
  'OUTBOX_UNCONFIRMED',
  'BARCODE_CONFLICT',
  'PAYMENT_DOC_VOIDED',
  'ORDER_MATCH_AMBIGUOUS',
  'NO_WRITE_CHANNEL',
  'QR_PAID_AFTER_VOID',
  'NOT_FOUND_LOCAL',
  'VALIDATION',
  'ONEC_REJECTED',
  'ONEC_UNAVAILABLE',
  'IMAGE_DOWNLOAD',
  'HASH_MISMATCH',
  'COUNT_MISMATCH',
  'OTHER',
] as const;
export type SyncErrorCode = (typeof SYNC_ERROR_CODE_VALUES)[number];
export function isSyncErrorCode(value: unknown): value is SyncErrorCode {
  return typeof value === 'string' && (SYNC_ERROR_CODE_VALUES as readonly string[]).includes(value);
}

/**
 * sync_error_severity — 07 §6.1.1 (CHECK). Поля: sync_errors.severity.
 * Источник: проектное.
 */
export const SYNC_ERROR_SEVERITY_VALUES = [
  'warning',
  'error',
] as const;
export type SyncErrorSeverity = (typeof SYNC_ERROR_SEVERITY_VALUES)[number];
export function isSyncErrorSeverity(value: unknown): value is SyncErrorSeverity {
  return typeof value === 'string' && (SYNC_ERROR_SEVERITY_VALUES as readonly string[]).includes(value);
}

/**
 * outbox_operation — 07 §6.1.1 (CHECK). Поля: onec_outbox.operation.
 * Источник: D-28, ядро v1.7 §22.1.
 * Не используются: update_status.
 */
export const OUTBOX_OPERATION_VALUES = [
  'create',
  'cancel',
] as const;
export type OutboxOperation = (typeof OUTBOX_OPERATION_VALUES)[number];
export function isOutboxOperation(value: unknown): value is OutboxOperation {
  return typeof value === 'string' && (OUTBOX_OPERATION_VALUES as readonly string[]).includes(value);
}

/**
 * audit_result — 07 §6.1.1 (CHECK). Поля: audit_logs.result.
 * Источник: D-36.
 */
export const AUDIT_RESULT_VALUES = [
  'ok',
  'denied',
  'error',
] as const;
export type AuditResult = (typeof AUDIT_RESULT_VALUES)[number];
export function isAuditResult(value: unknown): value is AuditResult {
  return typeof value === 'string' && (AUDIT_RESULT_VALUES as readonly string[]).includes(value);
}

/**
 * audit_severity — 07 §6.1.1 (CHECK). Поля: audit_logs.severity.
 * Источник: D-36.
 */
export const AUDIT_SEVERITY_VALUES = [
  'info',
  'warning',
  'critical',
] as const;
export type AuditSeverity = (typeof AUDIT_SEVERITY_VALUES)[number];
export function isAuditSeverity(value: unknown): value is AuditSeverity {
  return typeof value === 'string' && (AUDIT_SEVERITY_VALUES as readonly string[]).includes(value);
}

/**
 * setting_value_type — 07 §6.1.1 (CHECK). Поля: app_settings.value_type.
 * Источник: проектное.
 */
export const SETTING_VALUE_TYPE_VALUES = [
  'boolean',
  'integer',
  'string',
  'json',
  'duration',
  'money',
  'percent',
] as const;
export type SettingValueType = (typeof SETTING_VALUE_TYPE_VALUES)[number];
export function isSettingValueType(value: unknown): value is SettingValueType {
  return typeof value === 'string' && (SETTING_VALUE_TYPE_VALUES as readonly string[]).includes(value);
}

/**
 * customer_stock_display — 07 §6.1.1 (CHECK). Поля: app_settings.customer_stock_display.
 * Источник: ядро v1.9 §24.2.
 */
export const CUSTOMER_STOCK_DISPLAY_VALUES = [
  'status',
  'quantity',
] as const;
export type CustomerStockDisplay = (typeof CUSTOMER_STOCK_DISPLAY_VALUES)[number];
export function isCustomerStockDisplay(value: unknown): value is CustomerStockDisplay {
  return typeof value === 'string' && (CUSTOMER_STOCK_DISPLAY_VALUES as readonly string[]).includes(value);
}

/**
 * print_paper — 07 §6.1.1 (CHECK). Поля: print_jobs.paper.
 * Источник: D-27.
 */
export const PRINT_PAPER_VALUES = [
  'a4',
  'thermal80',
] as const;
export type PrintPaper = (typeof PRINT_PAPER_VALUES)[number];
export function isPrintPaper(value: unknown): value is PrintPaper {
  return typeof value === 'string' && (PRINT_PAPER_VALUES as readonly string[]).includes(value);
}

/**
 * sms_template_key — 07 §6.1.1 (CHECK). Поля: sms_outbox.template_key.
 * Источник: D-11.
 */
export const SMS_TEMPLATE_KEY_VALUES = [
  'otp_login',
  'otp_step_up',
  'otp_phone_change',
  'otp_customer_link',
] as const;
export type SmsTemplateKey = (typeof SMS_TEMPLATE_KEY_VALUES)[number];
export function isSmsTemplateKey(value: unknown): value is SmsTemplateKey {
  return typeof value === 'string' && (SMS_TEMPLATE_KEY_VALUES as readonly string[]).includes(value);
}

/**
 * sms_provider — 07 §6.1.1 (CHECK). Поля: sms_outbox.provider.
 * Источник: D-11, ядро §17.3.
 */
export const SMS_PROVIDER_VALUES = [
  'smspro',
  'fake',
] as const;
export type SmsProvider = (typeof SMS_PROVIDER_VALUES)[number];
export function isSmsProvider(value: unknown): value is SmsProvider {
  return typeof value === 'string' && (SMS_PROVIDER_VALUES as readonly string[]).includes(value);
}

// ===== 08 §2.4, §3.8 — перечни контракта API =====

/**
 * credit_reason — 08 §3.8 paymentChecks.creditReason (enum CreditReason), §5.5; ядро §22.4 в редакции §23 п.5; владелец правила — 10 PAY-031.
 * Не используются: not_identified, onec_inbound_mode, not_allowed, no_data, receivables_stale, onec_unavailable.
 */
export const CREDIT_REASON_VALUES = [
  'forbidden_role',
  'credit_not_allowed',
  'overdue',
  'limit_exceeded',
  'stale_snapshot',
] as const;
export type CreditReason = (typeof CREDIT_REASON_VALUES)[number];
export function isCreditReason(value: unknown): value is CreditReason {
  return typeof value === 'string' && (CREDIT_REASON_VALUES as readonly string[]).includes(value);
}

/**
 * warning_code — 08 §2.4 «Предупреждения (не ошибки)» — warnings[].code успешного ответа; не входят в Problem.code.
 */
export const WARNING_CODE_VALUES = [
  'STALE_DATA',
  'QR_UNAVAILABLE',
  'PAYMENT_AMOUNT_MISMATCH',
] as const;
export type WarningCode = (typeof WARNING_CODE_VALUES)[number];
export function isWarningCode(value: unknown): value is WarningCode {
  return typeof value === 'string' && (WARNING_CODE_VALUES as readonly string[]).includes(value);
}

/**
 * problem_resource — 08 §2.4 ORDER_STATE_INVALID — поле resource; 08 §8 Problem.resource.
 */
export const PROBLEM_RESOURCE_VALUES = [
  'order',
  'cart',
  'return_request',
  'outbox_item',
] as const;
export type ProblemResource = (typeof PROBLEM_RESOURCE_VALUES)[number];
export function isProblemResource(value: unknown): value is ProblemResource {
  return typeof value === 'string' && (PROBLEM_RESOURCE_VALUES as readonly string[]).includes(value);
}

// ===== 08 §2.4 — коды ошибок Problem.code =====

/**
 * problem_code — Problem.code, 08 §2.4 (владелец словаря, ядро §18.1).
 * Клиент ветвится только по code и HTTP-статусу; неизвестный code — как INTERNAL того же класса.
 */
export const PROBLEM_CODE_VALUES = [
  'VALIDATION_FAILED',
  'OTP_INVALID',
  'OTP_EXPIRED',
  'OTP_LOCKED',
  'OTP_RATE_LIMITED',
  'SMS_PROVIDER_ERROR',
  'REGISTRATION_TOKEN_INVALID',
  'PHONE_ALREADY_REGISTERED',
  'UNAUTHENTICATED',
  'TOKEN_STALE',
  'SESSION_REVOKED',
  'DEVICE_MISMATCH',
  'STEP_UP_REQUIRED',
  'FORBIDDEN',
  'VERSION_CONFLICT',
  'IDEMPOTENCY_KEY_REUSED',
  'IDEMPOTENCY_IN_PROGRESS',
  'PRICE_CHANGED',
  'STOCK_INSUFFICIENT',
  'VARIANT_UNAVAILABLE',
  'QTY_NOT_MULTIPLE',
  'QTY_BELOW_MIN',
  'DISCOUNT_LIMIT_EXCEEDED',
  'CREDIT_BLOCKED',
  'CREDIT_LIMIT_EXCEEDED',
  'RECEIVABLES_STALE',
  'ONEC_UNAVAILABLE',
  'ONEC_REJECTED',
  'ORDER_STATE_INVALID',
  'PAYMENT_STATE_INVALID',
  'CUSTOMER_LINK_CONFLICT',
  'CUSTOMER_DUPLICATE_SUSPECTED',
  'SYNC_ALREADY_RUNNING',
  'NOT_FOUND',
  'RATE_LIMITED',
  'INTERNAL',
  'APP_UPDATE_REQUIRED',
  'PAYLOAD_TOO_LARGE',
  'UNSUPPORTED_MEDIA_TYPE',
  'METHOD_NOT_ALLOWED',
  'CUSTOMER_NOT_IDENTIFIED',
  'CART_EMPTY',
  'PIN_INVALID',
  'PIN_LOCKED',
  'UNLOCK_REQUIRED',
  'RETURN_QTY_EXCEEDED',
  'WEBHOOK_SIGNATURE_INVALID',
  'QR_UNAVAILABLE',
  'CONSENT_REQUIRED',
  'APP_READ_ONLY',
] as const;
export type ProblemCode = (typeof PROBLEM_CODE_VALUES)[number];
export function isProblemCode(value: unknown): value is ProblemCode {
  return typeof value === 'string' && (PROBLEM_CODE_VALUES as readonly string[]).includes(value);
}

/** HTTP-статусы для каждого Problem.code (08 §2.4, столбец «HTTP»). */
export const PROBLEM_CODE_HTTP_STATUS: { readonly [K in ProblemCode]: readonly number[] } = {
  VALIDATION_FAILED: [400, 422],
  OTP_INVALID: [422],
  OTP_EXPIRED: [422],
  OTP_LOCKED: [423],
  OTP_RATE_LIMITED: [429],
  SMS_PROVIDER_ERROR: [503],
  REGISTRATION_TOKEN_INVALID: [401],
  PHONE_ALREADY_REGISTERED: [409],
  UNAUTHENTICATED: [401],
  TOKEN_STALE: [401],
  SESSION_REVOKED: [401],
  DEVICE_MISMATCH: [409],
  STEP_UP_REQUIRED: [403],
  FORBIDDEN: [403],
  VERSION_CONFLICT: [409],
  IDEMPOTENCY_KEY_REUSED: [422],
  IDEMPOTENCY_IN_PROGRESS: [409],
  PRICE_CHANGED: [422],
  STOCK_INSUFFICIENT: [422],
  VARIANT_UNAVAILABLE: [422],
  QTY_NOT_MULTIPLE: [422],
  QTY_BELOW_MIN: [422],
  DISCOUNT_LIMIT_EXCEEDED: [422],
  CREDIT_BLOCKED: [422],
  CREDIT_LIMIT_EXCEEDED: [422],
  RECEIVABLES_STALE: [422],
  ONEC_UNAVAILABLE: [503],
  ONEC_REJECTED: [422],
  ORDER_STATE_INVALID: [409],
  PAYMENT_STATE_INVALID: [409],
  CUSTOMER_LINK_CONFLICT: [409],
  CUSTOMER_DUPLICATE_SUSPECTED: [409],
  SYNC_ALREADY_RUNNING: [409],
  NOT_FOUND: [404],
  RATE_LIMITED: [429],
  INTERNAL: [500],
  APP_UPDATE_REQUIRED: [426],
  PAYLOAD_TOO_LARGE: [413],
  UNSUPPORTED_MEDIA_TYPE: [415],
  METHOD_NOT_ALLOWED: [405],
  CUSTOMER_NOT_IDENTIFIED: [422],
  CART_EMPTY: [422],
  PIN_INVALID: [401],
  PIN_LOCKED: [423],
  UNLOCK_REQUIRED: [401],
  RETURN_QTY_EXCEEDED: [422],
  WEBHOOK_SIGNATURE_INVALID: [401],
  QR_UNAVAILABLE: [503],
  CONSENT_REQUIRED: [422],
  APP_READ_ONLY: [503],
};

/** Реестр типов PostgreSQL: имя типа → значения в порядке CREATE TYPE (07 §6.1; тест pg_enum, DATA-200). */
export const DB_ENUMS = {
  user_kind: USER_KIND_VALUES,
  user_status: USER_STATUS_VALUES,
  role_code: ROLE_CODE_VALUES,
  customer_link_status: CUSTOMER_LINK_STATUS_VALUES,
  cart_status: CART_STATUS_VALUES,
  order_status: ORDER_STATUS_VALUES,
  delivery_method: DELIVERY_METHOD_VALUES,
  receiver_kind: RECEIVER_KIND_VALUES,
  payment_method: PAYMENT_METHOD_VALUES,
  payment_status: PAYMENT_STATUS_VALUES,
  return_request_status: RETURN_REQUEST_STATUS_VALUES,
  transaction_kind: TRANSACTION_KIND_VALUES,
  sync_entity: SYNC_ENTITY_VALUES,
  sync_mode: SYNC_MODE_VALUES,
  sync_run_status: SYNC_RUN_STATUS_VALUES,
  outbox_status: OUTBOX_STATUS_VALUES,
  notification_kind: NOTIFICATION_KIND_VALUES,
  invitation_status: INVITATION_STATUS_VALUES,
  device_platform: DEVICE_PLATFORM_VALUES,
  session_kind: SESSION_KIND_VALUES,
  step_up_method: STEP_UP_METHOD_VALUES,
  otp_purpose: OTP_PURPOSE_VALUES,
  otp_status: OTP_STATUS_VALUES,
  consent_kind: CONSENT_KIND_VALUES,
  attribute_value_type: ATTRIBUTE_VALUE_TYPE_VALUES,
  barcode_type: BARCODE_TYPE_VALUES,
  image_status: IMAGE_STATUS_VALUES,
  customer_source: CUSTOMER_SOURCE_VALUES,
  customer_type: CUSTOMER_TYPE_VALUES,
  customer_onec_status: CUSTOMER_ONEC_STATUS_VALUES,
  contact_kind: CONTACT_KIND_VALUES,
  link_match_method: LINK_MATCH_METHOD_VALUES,
  discount_source: DISCOUNT_SOURCE_VALUES,
  discount_kind: DISCOUNT_KIND_VALUES,
  status_change_source: STATUS_CHANGE_SOURCE_VALUES,
  transaction_source: TRANSACTION_SOURCE_VALUES,
  return_reason: RETURN_REASON_VALUES,
  sync_trigger: SYNC_TRIGGER_VALUES,
  outbox_aggregate: OUTBOX_AGGREGATE_VALUES,
  idempotency_status: IDEMPOTENCY_STATUS_VALUES,
  audit_level: AUDIT_LEVEL_VALUES,
  print_document_kind: PRINT_DOCUMENT_KIND_VALUES,
  print_job_status: PRINT_JOB_STATUS_VALUES,
  sms_status: SMS_STATUS_VALUES,
  onec_sync_state: ONEC_SYNC_STATE_VALUES,
} as const;

/** Реестр CHECK-перечней: поле таблицы → допустимые значения (07 §6.1.1). */
export const CHECK_LISTS = {
  'user_profiles.locale': LOCALE_VALUES,
  'user_invitations.role': INVITATION_ROLE_VALUES,
  'sessions.revoke_reason': SESSION_REVOKE_REASON_VALUES,
  'token_denylist.token_kind': TOKEN_KIND_VALUES,
  'token_denylist.reason': TOKEN_DENY_REASON_VALUES,
  'rate_limit_counters.scope': RATE_LIMIT_SCOPE_VALUES,
  'integration_tokens.scope': INTEGRATION_TOKEN_SCOPE_VALUES,
  'integration_tokens.source': INTEGRATION_TOKEN_SOURCE_VALUES,
  'integration_tokens.revoke_reason': INTEGRATION_TOKEN_REVOKE_REASON_VALUES,
  'receivable_documents.kind': RECEIVABLE_DOCUMENT_KIND_VALUES,
  'receivable_documents.status': RECEIVABLE_DOCUMENT_STATUS_VALUES,
  'payments.review_reason': REVIEW_REASON_VALUES,
  'orders.cancel_reason_code': CANCEL_REASON_CODE_VALUES,
  'orders.refund_intent': REFUND_INTENT_VALUES,
  'orders.created_via': ORDER_CREATED_VIA_VALUES,
  'payments.qr_provider': QR_PROVIDER_MODE_VALUES,
  'return_requests.onec_result': RETURN_ONEC_RESULT_VALUES,
  'return_requests.approval_reason': RETURN_APPROVAL_REASON_VALUES,
  'notifications.severity': NOTIFICATION_SEVERITY_VALUES,
  'sync_errors.error_code': SYNC_ERROR_CODE_VALUES,
  'onec_outbox.last_error_code': SYNC_ERROR_CODE_VALUES,
  'sync_node_state.last_error_code': SYNC_ERROR_CODE_VALUES,
  'sync_errors.severity': SYNC_ERROR_SEVERITY_VALUES,
  'onec_outbox.operation': OUTBOX_OPERATION_VALUES,
  'audit_logs.result': AUDIT_RESULT_VALUES,
  'audit_logs.severity': AUDIT_SEVERITY_VALUES,
  'app_settings.value_type': SETTING_VALUE_TYPE_VALUES,
  'app_settings.customer_stock_display': CUSTOMER_STOCK_DISPLAY_VALUES,
  'print_jobs.paper': PRINT_PAPER_VALUES,
  'sms_outbox.template_key': SMS_TEMPLATE_KEY_VALUES,
  'sms_outbox.provider': SMS_PROVIDER_VALUES,
} as const;
