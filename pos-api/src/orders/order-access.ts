import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import type { SalesActor } from '../common/ports/index.js';
import type { PermissionCatalog } from '../common/rbac/permission-catalog.js';
import type { PermissionCode } from '../common/rbac/permissions.generated.js';
import type { OrderRow } from './order.repository.js';

/** Субъект запроса для портов этапа F. */
export function salesActorOf(p: AuthenticatedPrincipal, requestId?: string | null): SalesActor {
  return {
    userId: p.userId,
    roles: p.roles,
    isCustomer: p.kind === 'customer',
    sessionId: p.sessionId,
    deviceId: p.deviceId,
    requestId: requestId ?? null,
  };
}

export interface OrderViewer {
  readonly actor: SalesActor;
  readonly permissions: ReadonlySet<PermissionCode>;
  /** Подтверждённая карточка 1С клиента-покупателя (`customer_links.status='confirmed'`), иначе `null`. */
  readonly linkedCustomerId: string | null;
}

export function permissionsOf(catalog: PermissionCatalog, p: AuthenticatedPrincipal): ReadonlySet<PermissionCode> {
  return catalog.effectivePermissions(p);
}

/**
 * Видимость заказа (08 §4.8.2–§4.8.3; 11 SEC-030): `order.read.all` — все; `order.read.own` — созданные субъектом;
 * `customer` — также заказы своей карточки при `customer_links.status='confirmed'`. Невидимый заказ — `404`.
 */
export function canSeeOrder(v: OrderViewer, o: Pick<OrderRow, 'created_by_user_id' | 'customer_id'>): boolean {
  if (v.permissions.has('order.read.all')) return true;
  if (!v.permissions.has('order.read.own')) return false;
  if (o.created_by_user_id === v.actor.userId) return true;
  return v.actor.isCustomer && v.linkedCustomerId !== null && o.customer_id === v.linkedCustomerId;
}
