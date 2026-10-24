import { Inject, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { StepUpTokenVerifier } from '../auth/step-up/step-up-token.verifier.js';
import { type AuditContext, applyAuditGucs } from '../common/audit/audit-context.js';
import { AuditService, type AuditStepUpMethod } from '../common/audit/audit.service.js';
import type { DbExecutor } from '../common/audit/db-executor.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import { OtpHmacService } from '../common/crypto/otp-hmac.service.js';
import { DRIZZLE, type Database } from '../common/db/database.module.js';
import { isReturnRequestStatus, type ReturnRequestStatus } from '../common/enums.js';
import { transactionDedupeKey } from '../common/journal/index.js';
import { Money, Quantity } from '../common/money/money.js';
import { MoneyMath } from '../common/money/money-math.js';
import {
  NOTIFICATIONS_PORT,
  type NotificationsPort,
  ONEC_OUTBOX_WRITER,
  type OnecOutboxWriter,
  type SalesActor,
  TRANSACTIONS_WRITER,
  type TransactionsWriter,
} from '../common/ports/index.js';
import { ProblemException, type ProblemFieldError } from '../common/problem-details/problem.exception.js';
import type { PermissionCode } from '../common/rbac/permissions.generated.js';
import { decideAccept, decideReject } from './domain/return-status.js';
import {
  RETURN_REASON_RU,
  returnRequestPayload,
  type UnlinkedReturnLine,
  unlinkedReturnLines,
} from './return-onec-payload.js';
import { ReturnsCursorCodec } from './returns-cursor.js';
import type { ReturnsStepUp } from './returns.guard.js';
import { loadUserRefs, presentReturn, remainingQty } from './returns.presenter.js';
import { type ReturnItemRow, type ReturnRow, ReturnsRepository, type ShipmentLineRow } from './returns.repository.js';
import {
  assertReasonComment,
  type CreateReturnBody,
  type ReturnItemInput,
  parseSubmitBody,
  type UpdateReturnBody,
  validationFailed,
} from './returns.request.js';
import { ReturnsSettings } from './returns.settings.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const LIMIT_DEFAULT = 50;
const LIMIT_MAX = 200;
const MAX_RANGE_MS = 366 * 86_400_000;
const STEP_UP_HEADER_DETAIL = 'Подтвердите отправку заявки на возврат PIN-кодом или кодом из SMS.';

/** Субъект запроса модуля `returns`. */
export interface ReturnsCaller {
  readonly principal: AuthenticatedPrincipal;
  readonly userId: string;
  readonly perms: ReadonlySet<PermissionCode>;
  readonly audit: AuditContext;
  readonly actor: SalesActor;
}

export type ReturnDto = Record<string, unknown>;

function notFound(): ProblemException {
  return new ProblemException('NOT_FOUND', { detail: 'Заявка на возврат не найдена.' });
}

function stateInvalid(reason: string, currentStatus: string, detail: string): ProblemException {
  return new ProblemException('ORDER_STATE_INVALID', { detail, resource: 'return_request', reason, currentStatus });
}

function versionConflict(r: ReturnRow): ProblemException {
  return new ProblemException('VERSION_CONFLICT', {
    detail: 'Заявка изменена другим пользователем — обновите данные.',
    current: { rowVersion: Number(r.row_version), status: r.status }, // money-double: allow — версия строки
  });
}

function qtyExceeded(errors: ProblemFieldError[]): ProblemException {
  return new ProblemException('RETURN_QTY_EXCEEDED', {
    detail: 'Количество к возврату больше остатка: отгружено − уже возвращено − в других заявках.',
    errors,
  });
}

/**
 * Ошибка данных при отправке (98 п. 74; ТЗ для 1С 6.17): у товара строки нет ссылки 1С — передать заявку нельзя.
 * `422 VALIDATION_FAILED`, `rule: not_linked_to_onec`; поле — строка заказа (`items[].orderLineNo`).
 */
function notLinkedToOnec(lines: readonly UnlinkedReturnLine[]): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 422,
    detail:
      'Товар заявки не связан с 1С — заявку нельзя передать в 1С. Администратор уведомлён; отправьте заявку после ' +
      'синхронизации каталога.',
    errors: lines.map((l) => ({
      field: `items[${l.itemIndex}].orderLineNo`,
      message: `«${l.productName}»: нет ссылки 1С (${l.missing === 'productRef' ? 'номенклатура' : 'характеристика'}).`,
      rule: 'not_linked_to_onec',
      params: { orderLineNo: l.orderLineNo, shipmentLineNumber: l.shipmentLineNumber, missing: l.missing },
    })),
  });
}

/** Код ошибки PostgreSQL по цепочке `cause` (Drizzle оборачивает ошибку драйвера). */
function pgError(e: unknown): { code?: string; message?: string } | null {
  let cur: unknown = e;
  for (let i = 0; i < 5 && cur; i++) {
    const c = cur as { code?: unknown; message?: unknown; cause?: unknown };
    if (typeof c.code === 'string' && /^[0-9A-Z]{5}$/.test(c.code)) {
      return { code: c.code, message: typeof c.message === 'string' ? c.message : '' };
    }
    cur = c.cause;
  }
  return null;
}

interface BuiltItem {
  readonly shipmentItemId: string;
  readonly variantId: string;
  readonly quantity: string;
  readonly unitPrice: string;
  readonly lineTotal: string;
  readonly productName: string;
}

/**
 * Заявки на возврат (D-25; R1 must — ядро §21 п. 1; автомат — ядро §22.11, владелец 10 RET; 08 §4.15; 13 RM-G-005,
 * RM-G-011): черновик по исходной продаже, правка/удаление черновика, отправка со step-up (сверх порога —
 * держатель `return.approve`), согласование и отклонение в POS, передача в 1С через outbox `return_request` только при
 * `RETURNS_FROM_POS_ENABLED=true`. Документ возврата и деньги — только 1С (`refund` пишет проекция `return_docs`).
 */
@Injectable()
export class ReturnsService {
  private readonly logger = new Logger('returns');
  private readonly cursor: ReturnsCursorCodec;

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    private readonly repo: ReturnsRepository,
    private readonly settings: ReturnsSettings,
    private readonly audit: AuditService,
    private readonly stepUps: StepUpTokenVerifier,
    hmac: OtpHmacService,
    @Inject(ONEC_OUTBOX_WRITER) private readonly outbox: OnecOutboxWriter,
    @Inject(TRANSACTIONS_WRITER) private readonly journal: TransactionsWriter,
    @Inject(NOTIFICATIONS_PORT) private readonly notifications: NotificationsPort,
  ) {
    this.cursor = new ReturnsCursorCodec(hmac);
  }

  // ------------------------------------------------------------------------------------------------- чтение

  async get(_caller: ReturnsCaller, id: string): Promise<ReturnDto> {
    const dto = await this.view(this.db, id);
    if (!dto) throw notFound();
    return dto;
  }

  async list(_caller: ReturnsCaller, q: Record<string, unknown>): Promise<Record<string, unknown>> {
    const one = (v: unknown): string | undefined => {
      const s: unknown = Array.isArray(v) ? (v as unknown[])[0] : v;
      return typeof s === 'string' && s !== '' ? s : undefined;
    };
    const errors: ProblemFieldError[] = [];
    let statuses: ReturnRequestStatus[] | null = null;
    const st = one(q.status);
    if (st !== undefined) {
      const parts = st.split(',').map((x) => x.trim());
      if (parts.some((p) => !isReturnRequestStatus(p))) {
        errors.push({ field: 'status', rule: 'enum', message: 'Значение вне перечня статусов заявки.' });
      } else statuses = [...new Set(parts as ReturnRequestStatus[])];
    }
    const uuid = (field: string): string | undefined => {
      const v = one(q[field]);
      if (v === undefined) return undefined;
      if (!UUID_RE.test(v)) {
        errors.push({ field, rule: 'uuid', message: 'Ожидается UUID.' });
        return undefined;
      }
      return v.toLowerCase();
    };
    const date = (field: string): Date | undefined => {
      const v = one(q[field]);
      if (v === undefined) return undefined;
      const d = new Date(v);
      if (Number.isNaN(d.getTime())) {
        errors.push({ field, rule: 'date_time', message: 'Ожидается дата-время ISO-8601.' });
        return undefined;
      }
      return d;
    };
    const orderId = uuid('orderId');
    const customerId = uuid('customerId');
    const from = date('from');
    const to = date('to');
    if (from && to && (from > to || to.getTime() - from.getTime() > MAX_RANGE_MS)) {
      errors.push({ field: 'from', rule: 'date_range', message: 'Период: from ≤ to, не более 366 дней.' });
    }
    const limitRaw = one(q.limit);
    const limit = limitRaw === undefined ? LIMIT_DEFAULT : Number(limitRaw); // money-double: allow — размер страницы
    if (!Number.isInteger(limit) || limit < 1 || limit > LIMIT_MAX) {
      errors.push({ field: 'limit', rule: 'range', message: `Целое 1…${LIMIT_MAX}.` });
    }
    if (errors.length > 0) throw validationFailed(errors);
    const after = this.cursor.decode(one(q.cursor));
    const rows = await this.repo.list(this.db, {
      statuses,
      ...(orderId ? { orderId } : {}),
      ...(customerId ? { customerId } : {}),
      ...(from ? { from } : {}),
      ...(to ? { to } : {}),
      ...(after ? { after } : {}),
      limit,
    });
    const hasMore = rows.length > limit;
    const page = rows.slice(0, limit);
    const items = await this.repo.items(
      this.db,
      page.map((r) => r.id),
    );
    const users = await loadUserRefs(
      this.db,
      page.map((r) => r.created_by_user_id),
    );
    const last = page.at(-1);
    return {
      items: page.map((r) => presentReturn(r, items, users)),
      nextCursor: hasMore && last ? this.cursor.encode({ createdAt: last.created_key, id: last.id }) : null,
      hasMore,
    };
  }

  // ------------------------------------------------------------------------------------------------- черновик

  /** `POST /returns` (08 §4.15.1; 10 RET-001…RET-005). */
  async create(caller: ReturnsCaller, body: CreateReturnBody, idempotencyKey: string | null): Promise<ReturnDto> {
    const threshold = await this.settings.threshold();
    const id = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, caller.audit);
      const order = await this.repo.findOrder(tx, body.orderId, true);
      if (!order) throw new ProblemException('NOT_FOUND', { detail: 'Заказ не найден.' });
      if (order.status !== 'shipped' && order.status !== 'partially_returned') {
        throw stateInvalid(
          'order_not_shipped',
          order.status,
          'Возврат возможен только по отгруженному заказу (есть проведённая реализация в 1С).',
        );
      }
      const shipment = await this.repo.sourceShipment(tx, order.id);
      if (!shipment) {
        throw stateInvalid('order_not_shipped', order.status, 'По заказу нет проведённой реализации 1С.');
      }
      const lines = await this.repo.shipmentLines(tx, shipment.id, null);
      const built = this.buildItems(lines, await this.repo.orderLines(tx, order.id), body.items);
      const total = built.reduce((s, b) => s.plus(Money.of(b.lineTotal)), Money.ZERO);
      const requestId = await this.withQtyGuard(async () => {
        const rid = await this.repo.insertRequest(tx, {
          shipmentId: shipment.id,
          orderId: order.id,
          customerId: shipment.customer_id,
          reason: body.reasonCode,
          reasonComment: body.reasonComment,
          total: total.toString(),
          refundKind: body.refundKind,
          createdBy: caller.userId,
          approvalReason: total.compare(threshold) > 0 ? 'return_threshold_exceeded' : null,
          idempotencyKey,
        });
        await this.repo.insertItems(tx, rid, built);
        return rid;
      });
      const row = await this.repo.findById(tx, requestId);
      await this.audit.write(
        caller.audit,
        {
          action: 'return.requested',
          entityType: 'return_request',
          entityId: requestId,
          after: {
            publicNumber: row?.public_number ?? null,
            status: 'draft',
            orderId: order.id,
            orderNumber: order.public_number,
            shipmentRef: shipment.onec_ref,
            reasonCode: body.reasonCode,
            totalAmount: total.toString(),
            approvalReason: row?.approval_reason ?? null,
            items: built.length,
          },
          reason: `${RETURN_REASON_RU[body.reasonCode]}: ${body.reasonComment ?? 'заявка на возврат'}`,
        },
        tx,
      );
      return requestId;
    });
    return (await this.view(this.db, id))!;
  }

  /** `PATCH /returns/{id}` (08 §4.15.2; ядро §17.4): только `draft`, по `rowVersion`. */
  async update(caller: ReturnsCaller, id: string, body: UpdateReturnBody): Promise<ReturnDto> {
    const threshold = await this.settings.threshold();
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, caller.audit);
      const r = await this.repo.findById(tx, id, true);
      if (!r || !this.canTouchDraft(caller, r)) throw notFound();
      if (r.status !== 'draft') throw stateInvalid('not_draft', r.status, 'Изменить можно только черновик заявки.');
      if (Number(r.row_version) !== body.rowVersion) throw versionConflict(r);
      const reason = body.reasonCode ?? r.reason;
      const comment = body.reasonComment !== undefined ? body.reasonComment : r.reason_comment;
      assertReasonComment(reason, comment);
      let total = Money.of(r.total);
      if (body.items) {
        const lines = await this.repo.shipmentLines(tx, r.shipment_id, r.id);
        const built = this.buildItems(lines, r.order_id ? await this.repo.orderLines(tx, r.order_id) : [], body.items);
        total = built.reduce((s, b) => s.plus(Money.of(b.lineTotal)), Money.ZERO);
        await this.withQtyGuard(async () => {
          await this.repo.deleteItems(tx, r.id);
          await this.repo.insertItems(tx, r.id, built);
        });
      }
      const refundKind = body.refundKind !== undefined ? body.refundKind : r.refund_method_expected;
      const approvalReason = total.compare(threshold) > 0 ? 'return_threshold_exceeded' : null;
      const ok = await this.repo.updateDraft(tx, r.id, body.rowVersion, {
        reason,
        reasonComment: comment,
        total: total.toString(),
        refundKind,
        approvalReason,
      });
      if (!ok) throw versionConflict(r);
      await this.audit.write(
        caller.audit,
        {
          action: 'return.updated',
          entityType: 'return_request',
          entityId: r.id,
          before: {
            reasonCode: r.reason,
            totalAmount: Money.of(r.total).toString(),
            refundKind: r.refund_method_expected,
            rowVersion: Number(r.row_version), // money-double: allow — версия строки
          },
          after: {
            reasonCode: reason,
            totalAmount: total.toString(),
            refundKind,
            approvalReason,
            itemsChanged: body.items !== undefined,
            rowVersion: body.rowVersion + 1,
            initiatorId: r.created_by_user_id,
          },
        },
        tx,
      );
    });
    return (await this.view(this.db, id))!;
  }

  /** `DELETE /returns/{id}?rowVersion=` (08 §4.15.4; 10 RET-003): только `draft`; повтор для удалённого — 204. */
  async remove(caller: ReturnsCaller, id: string, rowVersion: number): Promise<void> {
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, caller.audit);
      const r = await this.repo.findById(tx, id, true);
      if (!r) {
        if (await this.repo.wasDeleted(tx, id)) return;
        throw notFound();
      }
      if (!this.canTouchDraft(caller, r)) throw notFound();
      if (r.status !== 'draft') throw stateInvalid('not_draft', r.status, 'Удалить можно только черновик заявки.');
      if (Number(r.row_version) !== rowVersion) throw versionConflict(r);
      if (!(await this.repo.deleteDraft(tx, id, rowVersion))) throw versionConflict(r);
      await this.audit.write(
        caller.audit,
        {
          action: 'return.updated',
          entityType: 'return_request',
          entityId: id,
          before: { status: 'draft', publicNumber: r.public_number, totalAmount: Money.of(r.total).toString() },
          after: { deleted: true, rowVersion, initiatorId: r.created_by_user_id },
        },
        tx,
      );
    });
  }

  // ------------------------------------------------------------------------------------------------- переходы

  /**
   * `POST /returns/{id}/submit` (08 §4.15.3; 10 RET-006, RET-009): `draft → submitted`. Порядок проверок (08 §2.4):
   * объект (404) → порог без `return.approve` (403 `return_threshold_exceeded`) → step-up (403 `STEP_UP_REQUIRED`) →
   * статус (409) → версия (409) → перепроверка остатка (422). Outbox — только при `RETURNS_FROM_POS_ENABLED=true`.
   */
  async submit(
    caller: ReturnsCaller,
    id: string,
    rawBody: unknown,
    stepUpToken: string | readonly string[] | undefined,
  ): Promise<ReturnDto> {
    const threshold = await this.settings.threshold();
    const pre = await this.repo.findById(this.db, id);
    if (!pre || !this.canTouchDraft(caller, pre)) throw notFound();
    this.assertThreshold(caller, Money.of(pre.total), threshold);
    const stepUp = await this.verifySubmitStepUp(caller, Money.of(pre.total).compare(threshold) > 0, stepUpToken);
    const body = parseSubmitBody(rawBody);
    const outboxEnabled = this.settings.outboxEnabled;
    let enqueued = false;
    // Ошибка данных из транзакции (присваивается в замыкании) — уведомление admin после отката.
    const failure: { unlinked?: { readonly r: ReturnRow; readonly lines: readonly UnlinkedReturnLine[] } } = {};
    try {
      await this.db.transaction(async (tx) => {
        await applyAuditGucs(tx, caller.audit);
        const r = await this.repo.findById(tx, id, true);
        if (!r || !this.canTouchDraft(caller, r)) throw notFound();
        if (r.status !== 'draft') {
          throw stateInvalid('not_draft', r.status, 'Заявка уже отправлена или закрыта.');
        }
        if (Number(r.row_version) !== body.rowVersion) throw versionConflict(r);
        const total = Money.of(r.total);
        this.assertThreshold(caller, total, threshold);
        const over = total.compare(threshold) > 0;
        const items = await this.repo.items(tx, [r.id]);
        const lines = await this.repo.shipmentLines(tx, r.shipment_id, r.id);
        this.recheckQuantities(items, lines);
        // Строка без ссылки 1С — ошибка данных: в outbox не ставится, заявка остаётся черновиком (98 п. 74).
        if (outboxEnabled) {
          const missing = unlinkedReturnLines(items, lines);
          if (missing.length > 0) {
            failure.unlinked = { r, lines: missing };
            throw notLinkedToOnec(missing);
          }
        }
        const set = over
          ? sql`, approved_by_user_id = ${caller.userId}::uuid, approved_at = now(),
              approval_reason = 'return_threshold_exceeded'`
          : sql`, approval_reason = NULL`;
        if (!(await this.repo.transition(tx, r.id, 'draft', 'submitted', body.rowVersion, set))) {
          throw versionConflict(r);
        }
        if (outboxEnabled) {
          await this.outbox.enqueue(tx, {
            aggregateType: 'return_request',
            aggregateId: r.id,
            operation: 'create',
            payload: returnRequestPayload(r, items, lines, new Date()),
            requestedByUserId: caller.userId,
          });
          enqueued = true;
        }
        await this.journal.record(tx, {
          kind: 'return_requested',
          source: 'pos',
          orderId: r.order_id,
          returnRequestId: r.id,
          shipmentId: r.shipment_id,
          customerId: r.customer_id,
          actorUserId: caller.userId,
          amount: '0.00',
          paymentMethod: r.refund_method_expected,
          statusSnapshot: 'submitted',
          title: `Заявка на возврат ${r.public_number} отправлена`,
          details: { publicNumber: r.public_number, totalAmount: total.toString(), outbox: outboxEnabled },
          dedupeKey: transactionDedupeKey.returnRequested(r.id),
        });
        await this.audit.write(
          caller.audit,
          {
            action: 'return.submitted',
            entityType: 'return_request',
            entityId: r.id,
            before: { status: 'draft' },
            after: {
              status: 'submitted',
              publicNumber: r.public_number,
              totalAmount: total.toString(),
              approvalReason: over ? 'return_threshold_exceeded' : null,
              initiatorId: r.created_by_user_id,
              outbox: outboxEnabled,
            },
            stepUpMethod: stepUp.method,
            reason: body.comment ?? 'Отправка заявки на возврат',
          },
          tx,
        );
      });
    } catch (e) {
      if (failure.unlinked) await this.notifyAdminsNotLinked(failure.unlinked.r, failure.unlinked.lines);
      throw e;
    }
    if (enqueued) await this.outbox.kickAfterCommit();
    return (await this.view(this.db, id))!;
  }

  /** `POST /returns/{id}/accept` (08 §4.15.6; 10 RET-013 (б); ядро §23 п. 8). */
  async accept(
    caller: ReturnsCaller,
    id: string,
    body: { rowVersion: number; comment: string | null },
    stepUp: ReturnsStepUp,
  ): Promise<ReturnDto> {
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, caller.audit);
      const r = await this.repo.findById(tx, id, true);
      if (!r) throw notFound();
      const d = decideAccept({ status: r.status, outboxEnabled: this.settings.outboxEnabled });
      if (d.kind === 'invalid_transition') {
        throw stateInvalid('invalid_transition', r.status, 'Согласовать можно только отправленную заявку.');
      }
      if (d.kind === 'already_in_onec') {
        throw stateInvalid('already_in_onec', r.status, 'Заявка передаётся в 1С: согласование ставит 1С.');
      }
      if (Number(r.row_version) !== body.rowVersion) throw versionConflict(r);
      const set = sql`, accepted_by_user_id = ${caller.userId}::uuid`;
      if (!(await this.repo.transition(tx, r.id, 'submitted', 'accepted', body.rowVersion, set))) {
        throw versionConflict(r);
      }
      await this.audit.write(
        caller.audit,
        {
          action: 'return.status_changed',
          entityType: 'return_request',
          entityId: r.id,
          before: { status: 'submitted' },
          after: { status: 'accepted', publicNumber: r.public_number, initiatorId: r.created_by_user_id, via: 'pos' },
          stepUpMethod: stepUp.method,
          reason: body.comment ?? 'Заявка согласована в POS',
        },
        tx,
      );
      await this.notifyAuthor(tx, r, caller.userId, 'accepted');
    });
    return (await this.view(this.db, id))!;
  }

  /** `POST /returns/{id}/reject` (08 §4.15.5; 10 RET-013 (а)). */
  async reject(
    caller: ReturnsCaller,
    id: string,
    body: { rowVersion: number; reason: string },
    stepUp: ReturnsStepUp,
  ): Promise<ReturnDto> {
    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, caller.audit);
      const r = await this.repo.findById(tx, id, true);
      if (!r) throw notFound();
      const ob = await this.repo.outboxOf(tx, r.id);
      const d = decideReject({
        status: r.status,
        outboxStatus: ob?.status ?? null,
        onecRef: r.onec_ref,
        acceptedInPos: r.accepted_by_user_id !== null,
      });
      if (d.kind === 'invalid_transition') {
        throw stateInvalid(
          'invalid_transition',
          r.status,
          r.status === 'draft' ? 'Черновик не отклоняется — удалите его.' : 'Заявка закрыта: отклонить нельзя.',
        );
      }
      if (d.kind === 'already_in_onec') {
        throw stateInvalid('already_in_onec', r.status, 'Заявка уже передана в 1С — отклоните её в 1С.');
      }
      if (Number(r.row_version) !== body.rowVersion) throw versionConflict(r);
      const from = r.status;
      const set = sql`, rejected_by_user_id = ${caller.userId}::uuid, reject_reason = ${body.reason}`;
      if (!(await this.repo.transition(tx, r.id, from, 'rejected', body.rowVersion, set))) throw versionConflict(r);
      if (d.cancelOutbox && ob) await this.outbox.cancel(tx, ob.id);
      await this.audit.write(
        caller.audit,
        {
          action: 'return.status_changed',
          entityType: 'return_request',
          entityId: r.id,
          before: { status: from },
          after: {
            status: 'rejected',
            publicNumber: r.public_number,
            initiatorId: r.created_by_user_id,
            via: 'pos',
            outboxCancelled: d.cancelOutbox,
          },
          stepUpMethod: stepUp.method,
          reason: body.reason,
        },
        tx,
      );
      await this.notifyAuthor(tx, r, caller.userId, 'rejected', body.reason);
    });
    return (await this.view(this.db, id))!;
  }

  // ------------------------------------------------------------------------------------------------- общее

  /** Представление заявки (без проверки прав — вызывающий проверил `return.read`). */
  async view(tx: DbExecutor, id: string): Promise<ReturnDto | null> {
    const r = await this.repo.findById(tx, id);
    if (!r) return null;
    const items = await this.repo.items(tx, [r.id]);
    const users = await loadUserRefs(tx, [r.created_by_user_id]);
    return presentReturn(r, items, users);
  }

  /** 11 SEC-030 (г), CASH-007: автор черновика; держатели `return.approve` — и чужой; иначе — как нет (404). */
  private canTouchDraft(caller: ReturnsCaller, r: ReturnRow): boolean {
    return r.created_by_user_id === caller.userId || caller.perms.has('return.approve');
  }

  /** 10 RET-009: сверх порога отправляет только держатель `return.approve` (кассир → 403, черновик остаётся). */
  private assertThreshold(caller: ReturnsCaller, total: Money, threshold: Money): void {
    if (total.compare(threshold) > 0 && !caller.perms.has('return.approve')) {
      throw new ProblemException('FORBIDDEN', {
        detail: 'Требуется подтверждение старшего: сумма заявки выше порога согласования.',
        reason: 'return_threshold_exceeded',
        requiresRole: 'senior_seller',
      });
    }
  }

  /**
   * Step-up отправки (08 §2.12; 11 §4.3 №68): токен операции `return.submit`; сверх порога отправляет держатель
   * `return.approve` — принимается и его токен `return.approve` (11 №74, «со step-up», ядро §22.11).
   */
  private async verifySubmitStepUp(
    caller: ReturnsCaller,
    over: boolean,
    token: string | readonly string[] | undefined,
  ): Promise<{ readonly method: AuditStepUpMethod }> {
    try {
      return await this.stepUps.verify(token, caller.principal, {
        operation: 'return.submit',
        allowedMethods: ['pin', 'otp'],
        detail: STEP_UP_HEADER_DETAIL,
      });
    } catch (e) {
      if (!over || !caller.perms.has('return.approve')) throw e;
      try {
        return await this.stepUps.verify(token, caller.principal, {
          operation: 'return.approve',
          allowedMethods: ['pin', 'otp'],
          detail: STEP_UP_HEADER_DETAIL,
        });
      } catch {
        throw e;
      }
    }
  }

  /**
   * Строки заявки → строки реализации (RET-003, RET-005): номер строки (`orderLineNo` — номер строки исходной
   * реализации 1С, GQ-TXR-02), единица/упаковка строки, количество ≤ отгружено (иначе 400) и ≤ остатка к возврату
   * (иначе 422 `RETURN_QTY_EXCEEDED`), сумма — `MoneyMath.returnLineAmount` (MNY-006).
   */
  private buildItems(
    lines: readonly ShipmentLineRow[],
    orderLines: readonly { line_no: number; variant_id: string; packaging_id: string | null }[],
    input: readonly ReturnItemInput[],
  ): BuiltItem[] {
    const byNo = new Map(orderLines.map((l) => [Number(l.line_no), l])); // money-double: allow — номер строки
    const used = new Set<string>();
    const errors: ProblemFieldError[] = [];
    const exceeded: ProblemFieldError[] = [];
    const out: BuiltItem[] = [];
    input.forEach((it, idx) => {
      const f = `items[${idx}]`;
      const ol = byNo.get(it.orderLineNo);
      if (!ol) {
        errors.push({ field: `${f}.orderLineNo`, rule: 'not_found', message: 'Нет такой строки в заказе.' });
        return;
      }
      // Строка исходной реализации того же варианта и упаковки (номера строк заказа и реализации 1С не совпадают).
      const l = lines.find(
        (x) =>
          x.variant_id === ol.variant_id && (x.packaging_id ?? null) === (ol.packaging_id ?? null) && !used.has(x.id),
      );
      if (!l) {
        errors.push({
          field: `${f}.orderLineNo`,
          rule: 'not_shipped',
          message: 'Строка заказа не найдена в реализации 1С — вернуть нельзя.',
        });
        return;
      }
      used.add(l.id);
      if (!l.variant_id) {
        errors.push({
          field: `${f}.orderLineNo`,
          rule: 'variant_unknown',
          message: 'Товар строки не найден в каталоге.',
        });
        return;
      }
      if (l.unit_id && it.quantity.unitId !== l.unit_id) {
        errors.push({
          field: `${f}.quantity.unitId`,
          rule: 'unit_mismatch',
          message: 'Единица не совпадает со строкой.',
        });
      }
      if ((it.quantity.packagingId ?? null) !== (l.packaging_id ?? null)) {
        errors.push({
          field: `${f}.quantity.packagingId`,
          rule: 'packaging_mismatch',
          message: 'Упаковка не совпадает со строкой реализации.',
        });
      }
      const q = Quantity.of(it.quantity.value);
      const shipped = Quantity.of(l.quantity);
      if (q.compare(shipped) > 0) {
        errors.push({
          field: `${f}.quantity.value`,
          rule: 'max',
          message: 'Количество больше проданного.',
          params: { max: l.quantity },
        });
        return;
      }
      const left = remainingQty(l.quantity, l.returned_quantity, l.other_open);
      if (q.compare(Quantity.of(left)) > 0) {
        exceeded.push({
          field: `${f}.quantity.value`,
          rule: 'returnable',
          message: 'Больше остатка к возврату.',
          params: { maxReturnable: left },
        });
        return;
      }
      out.push({
        shipmentItemId: l.id,
        variantId: l.variant_id,
        quantity: q.toString(),
        unitPrice: Money.of(l.unit_price).toString(),
        lineTotal: MoneyMath.returnLineAmount(Money.of(l.line_total), shipped, q).toString(),
        productName: l.product_name_snapshot,
      });
    });
    if (errors.length > 0) throw validationFailed(errors);
    if (exceeded.length > 0) throw qtyExceeded(exceeded);
    return out;
  }

  /** Перепроверка остатка при отправке (08 §4.15.3: `RETURN_QTY_EXCEEDED`). */
  private recheckQuantities(items: readonly ReturnItemRow[], lines: readonly ShipmentLineRow[]): void {
    const byId = new Map(lines.map((l) => [l.id, l]));
    const exceeded: ProblemFieldError[] = [];
    items.forEach((i, idx) => {
      const l = byId.get(i.shipment_item_id);
      if (!l) return;
      const left = remainingQty(l.quantity, l.returned_quantity, l.other_open);
      if (Quantity.of(i.quantity).compare(Quantity.of(left)) > 0) {
        exceeded.push({
          field: `items[${idx}].quantity.value`,
          rule: 'returnable',
          message: 'Больше остатка к возврату.',
          params: { maxReturnable: left, orderLineNo: Number(i.order_line_no) }, // money-double: allow — номер строки
        });
      }
    });
    if (exceeded.length > 0) throw qtyExceeded(exceeded);
  }

  /** Гонка двух заявок на остаток (RET-008): триггер `return_request_items_guard` → 422 `RETURN_QTY_EXCEEDED`. */
  private async withQtyGuard<T>(fn: () => Promise<T>): Promise<T> {
    try {
      return await fn();
    } catch (e) {
      const pe = pgError(e);
      if (pe?.code === '23514' && /exceeds returnable/.test(pe.message ?? '')) {
        throw qtyExceeded([{ field: 'items', rule: 'returnable', message: 'Остаток к возврату изменился.' }]);
      }
      throw e;
    }
  }

  /**
   * Администраторам — заявка не передана в 1С из-за товара без ссылки 1С (98 п. 74; кассиру — ответ `422`). Отдельной
   * командой после отката транзакции отправки; сбой уведомления ответ `422` не подменяет (D-41).
   */
  private async notifyAdminsNotLinked(r: ReturnRow, lines: readonly UnlinkedReturnLine[]): Promise<void> {
    const list = lines.map((l) => `«${l.productName}» (строка реализации ${l.shipmentLineNumber})`).join(', ');
    try {
      await this.notifications.notifyRole(null, 'admin', {
        kind: 'sync_error',
        severity: 'error',
        title: `Заявка на возврат ${r.public_number} не передана в 1С`,
        body: `Нет ссылки 1С у товара: ${list}. Проверьте синхронизацию каталога, затем кассир отправит заявку снова.`,
        payload: { returnRequestId: r.id },
        dedupeKey: `return_not_linked:${r.id}`,
      });
    } catch (e) {
      this.logger.warn({ err: e, returnRequestId: r.id }, 'returns.notify_failed');
    }
    this.logger.warn(
      { event: 'returns.submit.not_linked', returnRequestId: r.id, lines: lines.length },
      'return request has lines without 1C refs',
    );
  }

  private async notifyAuthor(
    tx: DbExecutor,
    r: ReturnRow,
    actorUserId: string | null,
    to: 'accepted' | 'rejected' | 'completed',
    reason?: string,
  ): Promise<void> {
    if (r.created_by_user_id === actorUserId) return;
    const title =
      to === 'accepted'
        ? `Заявка на возврат ${r.public_number} согласована`
        : to === 'rejected'
          ? `Заявка на возврат ${r.public_number} отклонена`
          : `Возврат по заявке ${r.public_number} оформлен в 1С`;
    try {
      await this.notifications.notify(tx, {
        userId: r.created_by_user_id,
        kind: 'return_status',
        severity: to === 'rejected' ? 'warning' : 'info',
        title,
        body: reason ? `Причина: ${reason}` : title,
        payload: { returnRequestId: r.id, status: to },
        dedupeKey: `return_status:${r.id}:${to}`,
      });
    } catch (e) {
      // Ошибка БД прерывает транзакцию — пробрасывается; иная (порт не привязан, проверка входа) не отменяет переход
      // (D-41: in-app — вспомогательный канал).
      if (pgError(e)) throw e;
      this.logger.warn({ err: e, returnRequestId: r.id }, 'returns.notify_failed');
    }
  }
}
