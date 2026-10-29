import { sql } from 'drizzle-orm';
import { type NotificationInput, type NotificationsPort, PortNotBoundError } from '../../common/ports/index.js';
import type { PosDatabase } from '../../db/database.js';
import type { BlockedDependent } from '../../jobs/outbox/outbox-dispatcher.js';
import { findOrder } from '../order.repository.js';
import type { OrdersWorkerLog } from './order-onec-results.handler.js';

export interface OrderDependencyNotifierDeps {
  readonly db: PosDatabase;
  readonly notifications: NotificationsPort | null;
  readonly log: OrdersWorkerLog;
}

/** Состояние основания — словами для уведомления. */
const DEPENDENCY_STATE: Readonly<Record<BlockedDependent['dependency']['status'], string>> = {
  failed: '1С отклонила создание клиента',
  dead: 'карточка клиента не доставлена в 1С (попытки исчерпаны)',
  cancelled: 'отправка клиента в 1С отозвана',
};

/** Получатели уведомления `sync_error` об отказе/недоставке элемента outbox по ролям (05 §7.6.1). */
const ROLE_RECIPIENTS = ['admin', 'senior_seller'] as const;

/**
 * Уведомление о заказе, который не уходит в 1С, потому что его основание — `customer/create` POS-клиента — в
 * `failed`/`dead`/`cancelled` (05 SYNC-042, SYNC-049; 07 §5.55 «Клиент в failed — заказ ждёт ручного повтора
 * клиента»; known_issues G-KI-12). Хук диспетчера `onDependencyBlocked` вызывается после парковки элемента заказа
 * (`next_attempt_at = NULL`, причина в `last_error`). Получатели — по 05 §7.6.1 для отказа/недоставки элемента
 * outbox: `admin`, `senior_seller` и авторы агрегатов (сотрудник, создавший заказ, и сотрудник, создавший клиента).
 * Статус заказа не меняется (`submitting`): после ручного повтора клиента (`POST /sync/outbox/{id}/retry`) и его
 * доставки парковка снимается и заказ уходит в 1С автоматически. Идемпотентно: ключ дедупликации — элемент, основание,
 * его статус и момент перехода. Сбой уведомления не влияет на outbox (только журнал); пропущенное уведомление
 * повторяет сверщик `outbox.reconcile-aggregates` (`reconcile()`) по запаркованным элементам.
 */
export class OrderDependencyNotifier {
  constructor(private readonly d: OrderDependencyNotifierDeps) {}

  /**
   * Сверщик (`outbox.reconcile-aggregates`, 07 §8.2): уведомление по **уже запаркованным** заказам POS-клиента
   * повторяется — хук диспетчера вызывается один раз, после COMMIT парковки, и при его сбое (или падении процесса
   * между парковкой и хуком) уведомление иначе потерялось бы. Идемпотентно: ключ дедупликации тот же, что у хука
   * (элемент, основание, статус, `updated_at` основания), повтор дублей не создаёт. Возвращает число элементов.
   */
  async reconcile(limit = 200): Promise<number> {
    if (!this.d.notifications) return 0;
    const r = await this.d.db.execute<{
      id: string;
      aggregate_id: string;
      last_error: string | null;
      dep_id: string;
      dep_aggregate_id: string;
      dep_status: BlockedDependent['dependency']['status'];
      dep_code: string | null;
      dep_error: string | null;
      dep_changed_ms: string;
    }>(sql`
      SELECT o.id::text AS id, o.aggregate_id::text AS aggregate_id, o.last_error, d.id::text AS dep_id,
             d.aggregate_id::text AS dep_aggregate_id, d.status::text AS dep_status, d.last_error_code AS dep_code,
             d.last_error AS dep_error,
             -- мс как у pg-парсера Date в диспетчере (дробная часть отбрасывается) — тот же ключ дедупликации
             floor(extract(epoch FROM d.updated_at) * 1000)::bigint::text AS dep_changed_ms
        FROM onec_outbox o JOIN onec_outbox d ON d.id = o.depends_on_outbox_id
       WHERE o.aggregate_type = 'order' AND o.operation = 'create' AND o.status = 'pending'
         AND o.next_attempt_at IS NULL AND o.last_error_code IS DISTINCT FROM 'NO_WRITE_CHANNEL'
         AND d.aggregate_type = 'customer' AND d.status IN ('failed', 'dead', 'cancelled')
       ORDER BY o.created_at LIMIT ${limit}`);
    const items: BlockedDependent[] = r.rows.map((x) => ({
      id: x.id,
      aggregateType: 'order',
      aggregateId: x.aggregate_id,
      operation: 'create',
      reason: x.last_error ?? '',
      dependency: {
        id: x.dep_id,
        aggregateType: 'customer',
        aggregateId: x.dep_aggregate_id,
        operation: 'create',
        status: x.dep_status,
        lastErrorCode: x.dep_code,
        lastError: x.dep_error,
        changedAt: new Date(Number(x.dep_changed_ms)),
      },
    }));
    if (items.length > 0) await this.onBlocked(items);
    return items.length;
  }

  async onBlocked(items: readonly BlockedDependent[]): Promise<void> {
    const notifications = this.d.notifications;
    if (!notifications) return;
    for (const it of items) {
      if (it.aggregateType !== 'order' || it.operation !== 'create' || it.dependency.aggregateType !== 'customer') {
        continue;
      }
      try {
        const o = await findOrder(this.d.db, it.aggregateId);
        if (!o) continue;
        const c = await this.d.db.execute<{ created_by_user_id: string | null }>(
          sql`SELECT created_by_user_id::text AS created_by_user_id FROM customers WHERE id = ${o.customer_id}::uuid`,
        );
        const detail = it.dependency.lastError ? ` (${it.dependency.lastError.slice(0, 300)})` : '';
        const input: Omit<NotificationInput, 'userId'> = {
          kind: 'sync_error',
          severity: 'warning',
          title: `Заказ ${o.public_number} ждёт клиента в 1С`,
          body:
            `Заказ ${o.public_number} не отправлен в 1С: ${DEPENDENCY_STATE[it.dependency.status]}${detail}. ` +
            'Заказ уйдёт в 1С автоматически после повтора отправки клиента в очереди «в 1С».',
          payload: { orderId: o.id, outboxId: it.id, dependsOnOutboxId: it.dependency.id },
          dedupeKey: `outbox_blocked:${it.id}:${it.dependency.id}:${it.dependency.status}:${it.dependency.changedAt.getTime()}`,
        };
        const authors = new Set([o.created_by_user_id, c.rows[0]?.created_by_user_id ?? null]);
        for (const userId of authors) {
          if (userId) await notifications.notify(null, { ...input, userId });
        }
        for (const role of ROLE_RECIPIENTS) await notifications.notifyRole(null, role, input);
      } catch (e) {
        if (e instanceof PortNotBoundError) return;
        this.d.log.error({ err: e, outboxId: it.id }, 'orders.outbox_blocked.notify_failed');
      }
    }
  }
}
