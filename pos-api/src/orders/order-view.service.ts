import { Inject, Injectable, Logger } from '@nestjs/common';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import { DRIZZLE, type Database } from '../common/db/database.module.js';
import {
  DOCUMENTS_PORT,
  type DocumentsPort,
  type OrderDocumentsAvailability,
  PAYMENTS_PORT,
  type PaymentSummary,
  type PaymentsPort,
  PortNotBoundError,
  type SalesActor,
  type SalesTx,
} from '../common/ports/index.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../common/rbac/permission-catalog.js';
import { canSeeOrder, type OrderViewer, permissionsOf, salesActorOf } from './order-access.js';
import { loadCustomers, loadUserRefs, presentOrder } from './order-presenter.js';
import {
  confirmedCustomerId,
  findHistory,
  findOrder,
  findOrderItems,
  findOrderOutbox,
  type OrderRow,
} from './order.repository.js';

export type OrderInclude = 'items' | 'payments' | 'history' | 'documents';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Чтение и представление заказа (`Order` 08 §3.9) для всех операций модуля: видимость по правам (11 SEC-030),
 * платежи — через `PaymentsPort`, документы — через `DocumentsPort` (без импорта модулей payments/документов,
 * 06 §7.4). Непривязанный порт не ломает чтение заказа: платежи — пустой список, документы — правила ядра §19.4.
 */
@Injectable()
export class OrderViewService {
  private readonly logger = new Logger('orders.view');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(PAYMENTS_PORT) private readonly payments: PaymentsPort,
    @Inject(DOCUMENTS_PORT) private readonly documents: DocumentsPort,
    private readonly catalog: PermissionCatalog,
  ) {}

  async viewer(
    principal: AuthenticatedPrincipal,
    requestId?: string | null,
    tx: SalesTx = this.db,
  ): Promise<OrderViewer> {
    const actor = salesActorOf(principal, requestId);
    return {
      actor,
      permissions: permissionsOf(this.catalog, principal),
      linkedCustomerId: actor.isCustomer && actor.userId ? await confirmedCustomerId(tx, actor.userId) : null,
    };
  }

  /** Заказ, видимый субъекту; иначе `404 NOT_FOUND` (существование чужого заказа не раскрывается, SEC-030 (е)). */
  async loadVisible(tx: SalesTx, viewer: OrderViewer, id: string, forUpdate = false): Promise<OrderRow> {
    const o = UUID_RE.test(id) ? await findOrder(tx, id, forUpdate) : null;
    if (!o || o.status === 'draft' || !canSeeOrder(viewer, o)) {
      throw new ProblemException('NOT_FOUND', { detail: 'Заказ не найден.' });
    }
    return o;
  }

  async paymentsOf(orderId: string, tx?: SalesTx | null): Promise<readonly PaymentSummary[]> {
    try {
      return await this.payments.listForOrder(orderId, tx ?? null);
    } catch (e) {
      if (e instanceof PortNotBoundError) return [];
      throw e;
    }
  }

  async documentsOf(o: OrderRow, actor: SalesActor): Promise<OrderDocumentsAvailability> {
    try {
      return await this.documents.availability(o.id, actor);
    } catch (e) {
      if (!(e instanceof PortNotBoundError)) {
        this.logger.warn({ err: e, orderId: o.id }, 'orders.documents.availability_failed');
      }
      // Ядро §19.4: счёт — после номера 1С (Q-024), товарный чек — после оплаты, накладная — из 1С.
      const base = `/api/v1/orders/${o.id}/documents`;
      return {
        invoice:
          o.onec_ref && !['submitting', 'submit_failed', 'cancelled'].includes(o.status) ? `${base}/invoice.pdf` : null,
        receipt: o.is_paid ? `${base}/receipt.pdf` : null,
        waybill: { available: false, reason: 'waybill_from_onec' },
      };
    }
  }

  async present(
    tx: SalesTx,
    viewer: OrderViewer,
    o: OrderRow,
    opts: {
      readonly include?: ReadonlySet<OrderInclude>;
      readonly warnings?: readonly { readonly code: string; readonly message: string }[];
    } = {},
  ): Promise<Record<string, unknown>> {
    // Последовательно: в транзакции один клиент pg (параллельные запросы на нём не выполняются).
    const items = await findOrderItems(tx, o.id);
    const history = await findHistory(tx, o.id);
    const createOutbox = await findOrderOutbox(tx, o.id, 'create');
    const payments = await this.paymentsOf(o.id, tx);
    const documents = await this.documentsOf(o, viewer.actor);
    const customers = await loadCustomers(tx, [o.customer_id]);
    const users = await loadUserRefs(tx, [o.created_by_user_id, ...history.map((h) => h.actor_user_id)]);
    return presentOrder(o, {
      actor: viewer.actor,
      permissions: viewer.permissions,
      customer: customers.get(o.customer_id),
      users,
      payments,
      documents,
      createOutbox,
      items,
      history,
      ...(opts.include ? { include: opts.include } : {}),
      ...(opts.warnings ? { warnings: opts.warnings } : {}),
    });
  }

  async presentById(
    viewer: OrderViewer,
    id: string,
    opts: { readonly warnings?: readonly { readonly code: string; readonly message: string }[] } = {},
    tx: SalesTx = this.db,
  ): Promise<Record<string, unknown>> {
    const o = await findOrder(tx, id);
    if (!o) throw new ProblemException('NOT_FOUND', { detail: 'Заказ не найден.' });
    return this.present(tx, viewer, o, opts);
  }
}
