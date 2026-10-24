import type { Logger } from 'pino';
import { type OrderOnecStatusChangedPayload, QUEUES } from '../../common/jobs/contracts/queues.js';
import type { SyncEntity } from '../../common/enums.js';
import type { ApplyScope, ChangeItemHandler } from './apply.types.js';
import type { ChangeJobPublisher } from './change-job-publisher.js';
import { type ForeignItemError, uuidOrNull, writeForeignErrors } from './foreign-errors.js';

export const CUSTOMER_ORDER_TYPE = 'Document_ЗаказКлиента';

function text(v: unknown): string | null {
  return typeof v === 'string' && v.trim() !== '' ? v : null;
}

/**
 * Элементы `Document_ЗаказКлиента` плана обмена (контракт `OrderChange`; 05 §6.2, §5.1b ONEC-021; разбор
 * расхождений п. 8) → задача `orders.onec-status-changed` модулю `orders` **в транзакции сообщения** (ядро §22.8:
 * регистрация снимается только после того, как элемент сохранён для применения). Модуль `orders` применяет документ
 * той же процедурой, что и опрос `POST /orders/status` (`OrderStatusSyncHandler.applyDocument`: проекция D-20,
 * история, уведомление, `onec_sync_state=linked`, outbox `sent → confirmed`), идемпотентно с опросом.
 *
 * Применяются только заказы POS — элементы с `externalId` известного заказа (`orders.id`):
 * - `externalId = null` — заказ создан в 1С вне POS (вариант «все заказы», ТЗ 5.1, вопрос 55): POS такие заказы не
 *   ведёт — пропуск (журнал, счётчик);
 * - `externalId` не GUID — ошибка позиции `VALIDATION`; GUID без заказа в POS — `NOT_FOUND_LOCAL` (`order_status`);
 * - `ObjectDeletion` документа — статус не применяется: физическое удаление заказа выявляет опрос статусов
 *   (`notFound` → `onec_sync_state=missing`, статус заказа не меняется; 05 §6.5, 404).
 * Прогон `sync_runs` не открывается (`entityOf` → `undefined`): `order_status` — singleton опроса статусов.
 */
export class CustomerOrderChangeHandler implements ChangeItemHandler {
  readonly types: readonly string[] = [CUSTOMER_ORDER_TYPE];

  constructor(
    private readonly publisher: ChangeJobPublisher,
    private readonly log?: Pick<Logger, 'info'>,
  ) {}

  entityOf(): SyncEntity | undefined {
    return undefined;
  }

  async apply(scope: ApplyScope, items: readonly Readonly<Record<string, unknown>>[]): Promise<void> {
    const errors: ForeignItemError[] = [];
    const docs: { orderId: string; item: Readonly<Record<string, unknown>> }[] = [];
    let foreignOrders = 0;
    let deletions = 0;
    for (const it of items) {
      if (it.type !== CUSTOMER_ORDER_TYPE) {
        deletions += 1;
        continue;
      }
      if (it.externalId === null || it.externalId === undefined) {
        foreignOrders += 1;
        continue;
      }
      const orderId = uuidOrNull(it.externalId);
      if (!orderId) {
        errors.push({
          entity: 'order_status',
          errorCode: 'VALIDATION',
          severity: 'warning',
          message: 'заказ клиента /changes: externalId не GUID — элемент не применён',
          onecRef: uuidOrNull(it.ref),
        });
        continue;
      }
      docs.push({ orderId, item: it });
    }
    if (docs.length > 0) {
      const known = await scope.client.query<{ id: string }>(
        `SELECT id::text AS id FROM orders WHERE id = ANY($1::uuid[])`,
        [docs.map((d) => d.orderId)],
      );
      const ids = new Set(known.rows.map((r) => r.id));
      for (const d of docs) {
        if (!ids.has(d.orderId)) {
          errors.push({
            entity: 'order_status',
            errorCode: 'NOT_FOUND_LOCAL',
            severity: 'warning',
            message: 'заказ клиента /changes: заказ POS с таким externalId не найден — элемент не применён',
            onecRef: uuidOrNull(d.item.ref),
            payload: { externalId: d.orderId },
          });
          continue;
        }
        const payload: OrderOnecStatusChangedPayload = { orderId: d.orderId, document: documentOf(d.item) };
        await this.publisher.publish(scope.client, QUEUES.ordersOnecStatusChanged, payload);
      }
    }
    await writeForeignErrors(scope.client, errors);
    if (foreignOrders > 0 || deletions > 0) {
      this.log?.info(
        { foreignOrders, deletions },
        'onec.changes.orders_skipped: заказы вне POS и удаления документов статус не меняют',
      );
    }
  }
}

function documentOf(it: Readonly<Record<string, unknown>>): OrderOnecStatusChangedPayload['document'] {
  return {
    ref: typeof it.ref === 'string' ? it.ref : '',
    number: text(it.number),
    date: text(it.date),
    status: text(it.status),
    approved: typeof it.approved === 'boolean' ? it.approved : null,
    deletionMark: it.deletionMark === true,
    total: text(it.total),
    fulfillmentState: text(it.fulfillmentState),
    shipments: Array.isArray(it.shipments) ? it.shipments : [],
  };
}
