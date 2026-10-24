import { Inject, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { StepUpTokenVerifier } from '../auth/step-up/step-up-token.verifier.js';
import { applyAuditGucs, auditContextFromRequest } from '../common/audit/audit-context.js';
import { AuditService } from '../common/audit/audit.service.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import { APP_CONFIG, type AppConfig } from '../common/config/app-config.js';
import { DRIZZLE, type Database } from '../common/db/database.module.js';
import type { OrderStatus } from '../common/enums.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { IdempotencyService } from '../common/idempotency/idempotency.service.js';
import {
  CART_READER,
  type CartReader,
  NOTIFICATIONS_PORT,
  type NotificationsPort,
  ONEC_OUTBOX_WRITER,
  type OnecOutboxWriter,
} from '../common/ports/index.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { isOnecError } from '../integrations/onec/onec-error.js';
import { ONEC_GATEWAY, type OnecGateway, type OnecJsonObject } from '../integrations/onec/onec-gateway.js';
import { toProblemException } from '../sales-domain/problem.js';
import { type OnecOrderDocument, OrderProjector, parseOnecOrderDocument } from './order-projection.js';
import { releaseRestoredCart } from './order-retry.js';
import { OrderViewService } from './order-view.service.js';
import { findOrder } from './order.repository.js';
import { parseOnecLinkBody } from './orders.request.js';
import { idempotencyExecutor } from './sql-executor.js';

/** Страниц `GET /pos/v1/external-ids` при поиске документа по номеру (по 500 записей). */
const MAX_PAGES = 20;

/**
 * Ручная привязка заказа к документу «Заказ клиента» 1С — `POST /orders/{id}/onec-link` (08 §4.8.7; ядро §19.2,
 * §23 п. 1; 10 ORD-034; 07 §6.5): элемент outbox `create` `pending | failed | dead → sent` (как `POS_E_DUPLICATE`),
 * заказ получает `onec_ref`/номер, `onec_sync_state=linked` и статус по проекции 10 §2.2; далее `sent → confirmed`
 * обычной синхронизацией. Документ ищется в 1С синхронно (≤ `ONEC_SYNC_CHECK_TIMEOUT_MS`) — `listExternalIds`
 * (регистр `ВнешниеИдентификаторыPOS`, тип «Заказ») по номеру; статус документа — `getOrderStatus` (FQ-ORD-02).
 */
@Injectable()
export class OrderOnecLinkService {
  private readonly logger = new Logger('orders.onec_link');
  private readonly projector: OrderProjector;

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(ONEC_GATEWAY) private readonly onec: OnecGateway,
    @Inject(ONEC_OUTBOX_WRITER) private readonly outbox: OnecOutboxWriter,
    @Inject(NOTIFICATIONS_PORT) private readonly notifications: NotificationsPort,
    @Inject(CART_READER) private readonly cart: CartReader,
    private readonly audit: AuditService,
    private readonly idempotency: IdempotencyService,
    private readonly stepUp: StepUpTokenVerifier,
    private readonly views: OrderViewService,
  ) {
    this.projector = new OrderProjector(notifications, (msg, data) => this.logger.warn(data ?? {}, msg));
  }

  async link(
    principal: AuthenticatedPrincipal,
    req: RequestWithContext & { ip?: string },
    orderId: string,
    rawBody: unknown,
    stepUpToken: string | undefined,
  ): Promise<Record<string, unknown>> {
    const body = parseOnecLinkBody(rawBody);
    const viewer = await this.views.viewer(principal, typeof req.id === 'string' ? req.id : null);
    const verified = await this.stepUp.verify(stepUpToken, principal, { operation: 'order.onec_link' });
    const auditCtx = auditContextFromRequest(req);

    const o = await this.views.loadVisible(this.db, viewer, orderId);
    if (o.onec_ref) {
      if (o.onec_number === body.onecNumber) return this.views.present(this.db, viewer, o);
      throw stateInvalid(o.status, 'already_linked', 'Заказ уже привязан к другому документу 1С.');
    }
    this.assertLinkable(o.status);

    // Поиск документа в 1С — вне транзакции БД (08 §4.8: внешние вызовы в транзакции запрещены).
    const doc = await this.findDocument(o.id, body.onecNumber, body.onecDate ?? null);

    try {
      await this.db.transaction(async (tx) => {
        await applyAuditGucs(tx, auditCtx);
        const locked = await findOrder(tx, o.id, true);
        if (!locked) throw new ProblemException('NOT_FOUND', { detail: 'Заказ не найден.' });
        if (locked.onec_ref) {
          if (locked.onec_ref === doc.ref) return;
          throw stateInvalid(locked.status, 'already_linked', 'Заказ уже привязан к другому документу 1С.');
        }
        this.assertLinkable(locked.status);
        const elsewhere = await tx.execute<{ id: string }>(sql`
          SELECT id FROM orders WHERE onec_ref = ${doc.ref}::uuid AND id <> ${o.id}::uuid LIMIT 1`);
        if (elsewhere.rows[0]) {
          throw stateInvalid(locked.status, 'document_linked_elsewhere', 'Документ 1С уже привязан к другому заказу.');
        }
        const ob = await this.outbox.lock(tx, { aggregateType: 'order', aggregateId: o.id, operation: 'create' });
        if (!ob) throw stateInvalid(locked.status, 'invalid_transition', 'У заказа нет задачи отправки в 1С.');
        if (ob.status === 'sending') {
          throw new ProblemException('ORDER_STATE_INVALID', {
            detail: 'Заказ сейчас отправляется в 1С — повторите привязку позже.',
            resource: 'outbox_item',
            reason: 'in_progress',
            currentStatus: ob.status,
          });
        }
        if (!['pending', 'failed', 'dead'].includes(ob.status)) {
          throw stateInvalid(locked.status, 'invalid_transition', 'Задача отправки в 1С не допускает привязку.');
        }
        // Привязка из `failed` (заказ `submit_failed`): восстановленная корзина — как при техническом повторе
        // (10 ORD-034, ORD-027): не изменялась → `cleared` с уведомлением, иначе 409 (ревью F-orders-1c-1).
        if (locked.status === 'submit_failed') {
          await releaseRestoredCart(tx, { cart: this.cart, notifications: this.notifications }, locked, 'onec_link');
        }
        await this.outbox.markSentManually(tx, {
          outboxId: ob.outboxId,
          onecRef: doc.ref,
          onecNumber: doc.number,
        });
        const preSteps: { from: OrderStatus; to: OrderStatus }[] =
          locked.status === 'submit_failed' ? [{ from: 'submit_failed', to: 'submitting' }] : [];
        const applied = await this.projector.apply(tx, {
          orderId: o.id,
          source: 'pos_user',
          actorUserId: principal.userId,
          onec: doc,
          syncState: 'linked',
          linkedByUserId: principal.userId,
          preSteps,
          locked,
          requestId: auditCtx.requestId ?? null,
          reason: body.reason,
        });
        await this.audit.write(
          auditCtx,
          {
            action: 'order.onec_linked',
            entityType: 'order',
            entityId: o.id,
            onecRef: doc.ref,
            before: { onecRef: null, status: locked.status, outboxStatus: ob.status },
            after: { onecRef: doc.ref, onecNumber: doc.number, status: applied.to, outboxStatus: 'sent' },
            reason: body.reason,
            stepUpMethod: verified.method,
            severity: 'warning',
          },
          tx,
        );
        const row = await findOrder(tx, o.id);
        if (row) {
          const out = await this.views.present(tx, viewer, row);
          await this.idempotency.recordInTransaction(idempotencyExecutor(tx), req, 200, out, o.id);
        }
      });
    } catch (e) {
      throw toProblemException(e);
    }
    this.logger.log({ event: 'order.onec_linked', orderId: o.id, onecNumber: doc.number });
    return this.views.presentById(viewer, o.id);
  }

  private assertLinkable(status: OrderStatus): void {
    if (status !== 'submitting' && status !== 'submit_failed') {
      throw stateInvalid(status, 'invalid_transition', 'Привязка возможна только для заказа, не созданного в 1С.');
    }
  }

  /** Документ «Заказ клиента» 1С по номеру (и дате): `404` — не найден, `503` — 1С не ответила. */
  private async findDocument(
    orderId: string,
    number: string,
    date: string | null,
  ): Promise<OnecOrderDocument & { ref: string }> {
    const signal = AbortSignal.timeout(this.config.ONEC_SYNC_CHECK_TIMEOUT_MS);
    try {
      let cursor: string | undefined;
      let found: Record<string, unknown> | undefined;
      for (let page = 0; page < MAX_PAGES && !found; page++) {
        const r = await this.onec.listExternalIds(
          { type: 'Заказ', limit: 500, ...(cursor ? { cursor } : {}) },
          { signal },
        );
        const items = Array.isArray(r.body.items) ? (r.body.items as Record<string, unknown>[]) : [];
        found = items.find(
          (it) =>
            it.number === number &&
            (it.objectType === undefined || it.objectType === 'Заказ') &&
            (date === null || (typeof it.date === 'string' && it.date.startsWith(date))),
        );
        cursor = r.body.hasMore === true && typeof r.body.cursor === 'string' ? r.body.cursor : undefined;
        if (!cursor) break;
      }
      if (!found || typeof found.ref !== 'string') {
        throw new ProblemException('NOT_FOUND', { detail: 'Документ 1С с таким номером не найден.' });
      }
      const ref = found.ref;
      let status: OnecJsonObject | null = null;
      try {
        const externalId = typeof found.externalId === 'string' ? found.externalId : orderId;
        status = (await this.onec.getOrderStatus(externalId, { signal })).body;
      } catch (e) {
        this.logger.warn({ err: e, orderId }, 'orders.onec_link.status_unavailable');
      }
      const parsed = parseOnecOrderDocument(status && status.ref === ref ? status : { ...found });
      return {
        ...parsed,
        ref,
        number: typeof found.number === 'string' ? found.number : number,
        date: parsed.date ?? (typeof found.date === 'string' ? found.date : null),
        deletionMark: parsed.deletionMark || found.deletionMark === true,
      };
    } catch (e) {
      if (e instanceof ProblemException) throw e;
      if (isOnecError(e) && (e.retryable || e.status === 0)) {
        throw new ProblemException('ONEC_UNAVAILABLE', { detail: '1С не ответила — привязка не выполнена.' });
      }
      if (isOnecError(e) && e.status === 404) {
        throw new ProblemException('NOT_FOUND', { detail: 'Документ 1С с таким номером не найден.' });
      }
      throw new ProblemException('ONEC_UNAVAILABLE', { detail: '1С не ответила — привязка не выполнена.' });
    }
  }
}

function stateInvalid(currentStatus: OrderStatus, reason: string, detail: string): ProblemException {
  return new ProblemException('ORDER_STATE_INVALID', { detail, resource: 'order', reason, currentStatus });
}
