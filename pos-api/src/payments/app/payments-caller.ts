import type { AuditContext } from '../../common/audit/audit-context.js';
import type { SalesActor } from '../../common/ports/index.js';
import type { PermissionCode } from '../../common/rbac/permissions.generated.js';

/**
 * Субъект операции модуля `payments`: права (11 §4.3, `PermissionCatalog`), контекст аудита и представление
 * `SalesActor` для портов (`OrderStatusPort`, `NotificationsPort`). `userId = null` — система (воркер, автовоид).
 */
export interface PaymentsCaller {
  readonly userId: string | null;
  readonly roles: readonly string[];
  readonly isCustomer: boolean;
  readonly perms: ReadonlySet<PermissionCode>;
  readonly audit: AuditContext;
  readonly requestId: string | null;
  readonly sessionId: string | null;
  readonly deviceId: string | null;
}

export function toSalesActor(c: PaymentsCaller): SalesActor {
  return {
    userId: c.userId,
    roles: c.roles,
    isCustomer: c.isCustomer,
    sessionId: c.sessionId,
    deviceId: c.deviceId,
    requestId: c.requestId,
  };
}

/** Видит ли субъект все заказы/платежи (а не только свои — `own`, 11 §4.4). */
export function seesAllOrders(c: PaymentsCaller): boolean {
  return c.perms.has('order.read.all');
}

export function seesAllPayments(c: PaymentsCaller): boolean {
  return c.perms.has('payment.read.all');
}
