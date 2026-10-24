import type { PaymentStatus, ReviewReason } from '../../common/enums.js';
import { isUuid } from '../../common/ids/uuid.js';
import { Money } from '../../common/money/money.js';
import type { PaymentSummary } from '../../common/ports/index.js';
import type { PermissionCode } from '../../common/rbac/permissions.generated.js';
import { PAYMENT_USER_VOIDABLE } from '../../sales-domain/payment/payment-status.js';
import type { UserRefView } from '../infra/payments-lookups.js';
import type { PaymentRow } from '../infra/payments.repository.js';

export interface MoneyDto {
  readonly amount: string;
  readonly currency: 'KGS';
}

export interface WarningDto {
  readonly code: 'STALE_DATA' | 'QR_UNAVAILABLE' | 'PAYMENT_AMOUNT_MISMATCH';
  readonly message: string;
}

export interface QrInfoDto {
  readonly provider: 'onec' | 'bakai' | 'elqr_static' | 'none';
  readonly payload: string | null;
  readonly imageUrl: string | null;
  readonly bankReference: string | null;
  readonly amount: MoneyDto;
  readonly expiresAt: string | null;
  readonly issuedAt: string;
  readonly autoConfirm: boolean;
}

/** `Payment` (08 §3.10; OpenAPI `Payment`). */
export interface PaymentDto {
  readonly id: string;
  readonly orderId: string | null;
  readonly customerId: string | null;
  readonly method: PaymentRow['method'];
  readonly status: PaymentStatus;
  readonly amount: MoneyDto;
  readonly receivedAmount: MoneyDto | null;
  readonly changeAmount: MoneyDto | null;
  readonly qr: QrInfoDto | null;
  readonly externalRef?: string | null;
  readonly confirmedBy: UserRefView | null;
  readonly confirmedAt: string | null;
  readonly confirmationKind: 'webhook' | 'manual' | 'cash' | null;
  readonly reviewReason: ReviewReason | null;
  readonly bankAmount: MoneyDto | null;
  readonly voidReason: string | null;
  readonly warnings: readonly WarningDto[];
  readonly allocation: readonly unknown[];
  readonly onec: { readonly ref: string | null; readonly docType: string | null };
  readonly idempotencyKey?: string;
  /** Строка журнала платежа — переход UI-24-008 к SCR-37 (FQ-FEORD-12, F-KI-21; этап G). */
  readonly transactionId?: string | null;
}

export type AllowedAction = 'confirm_manual' | 'void' | 'reissue_qr';

const QR_VISIBLE: ReadonlySet<PaymentStatus> = new Set(['qr_shown', 'qr_expired']);

export function money(v: string): MoneyDto {
  return { amount: Money.of(v).toString(), currency: 'KGS' };
}

function moneyOrNull(v: string | null): MoneyDto | null {
  return v === null ? null : money(v);
}

/** QR провайдера (`onec`) — есть референс QR; статический/ручной QR — без референса (08 §3.10). */
export function isProviderQr(p: PaymentRow): boolean {
  return p.qrProviderRef !== null && (p.qrProvider === 'onec' || p.qrProvider === 'bakai');
}

export interface PresentOptions {
  /** `payment.qr.show` (08 §3.15): поле `qr` сериализуется только с этим правом. */
  readonly showQr: boolean;
  /** `externalRef` не отдаётся по `payment.read.own` (11 §4.3 №64). */
  readonly showExternalRef: boolean;
  /** Текущий статический QR (`app_settings.qr.static_payload`) для ручного QR. */
  readonly staticPayload: string | null;
  /**
   * Клиент-покупатель (режим клиента, ядро §24.2, §24.4): видит только динамический QR провайдера; статический QR
   * магазина и ручной режим ему не показываются (10 PAY-022, PAY-020, CUST-024; 11 §4.4; ревью F-security-1).
   */
  readonly customerMode?: boolean;
  readonly users: ReadonlyMap<string, UserRefView>;
  readonly warnings?: readonly WarningDto[];
  /**
   * Последняя строка журнала `transactions` по платежу (`payment_id`); задаётся только субъекту с правом чтения журнала
   * (`transactions.read.all|own`) — иначе поле `transactionId` не сериализуется (этап G, RM-G-004; FQ-FEORD-12).
   */
  readonly transactionIds?: ReadonlyMap<string, string>;
}

export function confirmationKind(p: PaymentRow): PaymentDto['confirmationKind'] {
  if (p.status !== 'received' && p.status !== 'refunded') return null;
  if (p.method === 'cash') return 'cash';
  if (p.manualConfirmedByUserId !== null) return 'manual';
  return 'webhook';
}

/** Пользователи, на которых ссылается представление (`confirmedBy`). */
export function referencedUsers(p: PaymentRow): string[] {
  const kind = confirmationKind(p);
  if (kind === 'manual' && p.manualConfirmedByUserId) return [p.manualConfirmedByUserId];
  if (kind === 'cash' && p.receivedByUserId) return [p.receivedByUserId];
  return [];
}

function qrInfo(p: PaymentRow, staticPayload: string | null): QrInfoDto | null {
  if (p.method !== 'qr_bakai' || !QR_VISIBLE.has(p.status)) return null;
  const provider = isProviderQr(p);
  const payload = provider ? p.qrPayload : (p.qrPayload ?? staticPayload);
  return {
    provider: provider ? (p.qrProvider === 'bakai' ? 'bakai' : 'onec') : payload ? 'elqr_static' : 'none',
    payload,
    imageUrl: null,
    bankReference: provider ? p.qrProviderRef : null,
    amount: money(p.amount),
    expiresAt: p.qrExpiresAt ? p.qrExpiresAt.toISOString() : null,
    issuedAt: (p.qrIssuedAt ?? p.createdAt).toISOString(),
    autoConfirm: provider,
  };
}

export function presentPayment(p: PaymentRow, o: PresentOptions): PaymentDto {
  const kind = confirmationKind(p);
  const confirmerId = referencedUsers(p)[0];
  const confirmedAt = kind === null ? null : (p.receivedAt ?? p.manualConfirmedAt);
  return {
    id: p.id,
    orderId: p.orderId,
    customerId: p.customerId,
    method: p.method,
    status: p.status,
    amount: money(p.amount),
    receivedAmount: moneyOrNull(p.receivedAmount),
    changeAmount: moneyOrNull(p.changeAmount),
    qr: o.showQr && (!o.customerMode || isProviderQr(p)) ? qrInfo(p, o.staticPayload) : null,
    ...(o.showExternalRef ? { externalRef: p.bankReference ?? p.qrProviderRef } : {}),
    confirmedBy: confirmerId ? (o.users.get(confirmerId) ?? { id: confirmerId, displayName: 'Сотрудник' }) : null,
    confirmedAt: confirmedAt ? confirmedAt.toISOString() : null,
    confirmationKind: kind,
    reviewReason: p.reviewReason,
    bankAmount: moneyOrNull(p.bankAmount),
    voidReason: p.voidReason,
    warnings: o.warnings ?? [],
    allocation: [],
    onec: { ref: p.onecRef, docType: p.onecDocType },
    ...(isUuid(p.idempotencyKey) ? { idempotencyKey: p.idempotencyKey } : {}),
    ...(o.transactionIds ? { transactionId: o.transactionIds.get(p.id) ?? null } : {}),
  };
}

/** `allowedActions` (08 §4.9.2) — по статусу и правам субъекта; клиенту — без действий ручного (статического) QR. */
export function allowedActions(
  p: PaymentRow,
  perms: ReadonlySet<PermissionCode>,
  customerMode = false,
): AllowedAction[] {
  const out: AllowedAction[] = [];
  if (p.method === 'qr_bakai' && (p.status === 'qr_shown' || p.status === 'manual_confirm')) {
    if (perms.has('payment.qr.confirm_manual')) out.push('confirm_manual');
  }
  if (PAYMENT_USER_VOIDABLE.has(p.status) && perms.has('payment.void')) out.push('void');
  if (
    p.method === 'qr_bakai' &&
    perms.has('payment.qr.show') &&
    (p.status === 'qr_pending' || p.status === 'qr_expired' || (p.status === 'qr_shown' && isProviderQr(p))) &&
    !(customerMode && (p.qrProvider !== 'onec' || (p.status !== 'qr_pending' && !isProviderQr(p))))
  ) {
    out.push('reissue_qr');
  }
  return out;
}

/** `PaymentSummary` порта `PaymentsPort` (06 §7.4). */
export function toSummary(p: PaymentRow): PaymentSummary {
  return {
    paymentId: p.id,
    publicNumber: p.publicNumber,
    method: p.method,
    status: p.status,
    amount: Money.of(p.amount).toString(),
    receivedAt: p.receivedAt,
    reviewReason: p.reviewReason,
    qrProvider: p.qrProvider,
  };
}

/**
 * `PaymentSummary` порта с полями представления `Order.payments[]` (08 §3.10: `qr`, `receivedAmount`,
 * `changeAmount`; FQ-ORD-04). Модуль `orders` выводит их структурно (`presentPayment` в order-presenter), право
 * `payment.qr.show` проверяет `orders`. `staticPayload` — статический QR магазина (`QR_PROVIDER=none` / `manualOnly`).
 */
export function toOrderSummary(
  p: PaymentRow,
  staticPayload: string | null,
): PaymentSummary & {
  readonly qr: QrInfoDto | null;
  readonly receivedAmount: string | null;
  readonly changeAmount: string | null;
} {
  return {
    ...toSummary(p),
    qr: qrInfo(p, staticPayload),
    receivedAmount: p.receivedAmount === null ? null : Money.of(p.receivedAmount).toString(),
    changeAmount: p.changeAmount === null ? null : Money.of(p.changeAmount).toString(),
  };
}
