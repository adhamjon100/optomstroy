import type pg from 'pg';
import type { Logger } from 'pino';
import type { OutboxAggregate, SyncEntity } from '../../common/enums.js';
import {
  type OnecConfirmedPayload,
  type OnecFailedPayload,
  QUEUES,
  type QueueName,
} from '../../common/jobs/contracts/queues.js';
import { outboxPayloadHash } from '../../sync/outbox/onec-outbox.writer.js';
import { outboxBackoffMs, outboxDeadReason } from '../../sync/scheduler/outbox-backoff.js';
import type { OutboxConfig } from '../../sync/scheduler/scheduler.config.js';
import { type SyncErrorCode, writeSyncError } from '../sync-errors.writer.js';
import type { OutboxDeliveryPort, OutboxDeliveryResult, OutboxRow } from './outbox-delivery.port.js';

/** Публикация job в транзакции вызывающего (pg-boss `send` с опцией `db`, 06 §7.5). */
export interface TxJobPublisher {
  send(
    name: string,
    data: object,
    options: { db: { executeSql(text: string, values?: unknown[]): Promise<{ rows: unknown[] }> } },
  ): Promise<string | null>;
}

/** Очереди событий результата по типу агрегата (06 §7.4 п. (б), 07 §8.2). */
export const RESULT_QUEUES: Readonly<Record<OutboxAggregate, { confirmed: QueueName; failed: QueueName }>> = {
  order: { confirmed: QUEUES.ordersOnecConfirmed, failed: QUEUES.ordersOnecFailed },
  payment: { confirmed: QUEUES.paymentsOnecConfirmed, failed: QUEUES.paymentsOnecFailed },
  customer: { confirmed: QUEUES.customersOnecConfirmed, failed: QUEUES.customersOnecFailed },
  return_request: { confirmed: QUEUES.returnsOnecConfirmed, failed: QUEUES.returnsOnecFailed },
};

/**
 * `sync_errors.entity` (NOT NULL) для ошибок outbox: ближайшая сущность синхронизации, которая подтверждает
 * документ (05 SYNC-045). `[ДОПУЩЕНИЕ RM-C-007]` — в 07 соответствие не задано.
 */
export const OUTBOX_ERROR_ENTITY: Readonly<Record<OutboxAggregate, SyncEntity>> = {
  order: 'order_status',
  payment: 'payment_docs',
  customer: 'customers',
  return_request: 'return_docs',
};

/**
 * Хуки модулей-владельцев агрегатов (этап F): вызываются **после COMMIT** перехода строки; ошибка хука не влияет на
 * автомат outbox (только журнал). `onDead` — уведомление `sync_error` администратору и автору документа (07 §8.2,
 * 10 ORD-031): модуль `notifications` в воркере доступен владельцу агрегата, а не диспетчеру.
 */
export interface OutboxDispatcherHooks {
  onDead?(
    row: OutboxRow,
    info: { readonly code: SyncErrorCode; readonly message: string; readonly reason: string },
  ): Promise<void>;
}

export interface TickResult {
  readonly claimed: number;
  readonly sent: number;
  readonly retried: number;
  readonly failed: number;
  readonly dead: number;
}

interface ClaimedRow {
  id: string;
  aggregate_type: OutboxAggregate;
  aggregate_id: string;
  external_id: string;
  operation: 'create' | 'cancel';
  payload: unknown;
  payload_hash?: Buffer | null;
  attempts: number;
  created_at: Date;
  dep_customer?: { ref: string | null; contractorRef: string | null; agreementRef: string | null } | null;
}

/**
 * Исход обработки строки диспетчером: исход доставки в 1С или несовпадение `payload_hash` (07 DATA-228, 12 T-SYNC-037):
 * тело изменено после постановки — в 1С не отправляется, строка → `dead` + `sync_errors (HASH_MISMATCH)`.
 */
type DispatchOutcome = OutboxDeliveryResult | { readonly kind: 'hash_mismatch'; readonly message: string };

/**
 * Сверка `payload_hash` (07 DATA-228, §5.55; SYNC-047): SHA-256 канонического JSON прочитанного `payload` равен
 * сохранённому при постановке (`OnecOutboxWriterService.enqueue`/`requeue`). Хеша нет (строка не захвачена этим
 * диспетчером) — сверка не выполняется.
 */
export function outboxPayloadIntact(payload: unknown, storedHash: Buffer | null | undefined): boolean {
  if (!storedHash) return true;
  const actual = outboxPayloadHash((payload ?? {}) as Readonly<Record<string, unknown>>);
  return actual.equals(Buffer.from(storedHash));
}

const HASH_MISMATCH_MESSAGE =
  'payload_hash не совпадает с телом: payload изменён после постановки в outbox — в 1С не отправлено (DATA-228)';

/**
 * Диспетчер `onec_outbox` (job `outbox.dispatch`, 07 §8.2; автомат — 07 §6.5, ядро §22.1). Захват пачки
 * `FOR UPDATE SKIP LOCKED` с арендой и `attempts+1`; отправка — вне транзакции; результат — одна транзакция
 * на строку только в таблицах модуля `sync` (+ публикация `<aggregate>.onec-*` в той же транзакции).
 * Повторы ведёт только `onec_outbox` (`next_attempt_at`), у job pg-boss собственных повторов нет.
 */
export class OutboxDispatcher {
  private warnedNotConfigured = false;

  constructor(
    private readonly pool: Pick<pg.Pool, 'query' | 'connect'>,
    private readonly delivery: OutboxDeliveryPort,
    private readonly publisher: TxJobPublisher,
    private readonly cfg: OutboxConfig,
    private readonly workerId: string,
    private readonly log: Logger,
    private readonly hooks: OutboxDispatcherHooks = {},
  ) {}

  async tick(): Promise<TickResult> {
    const result = { claimed: 0, sent: 0, retried: 0, failed: 0, dead: 0 };
    if (!this.delivery.configured) {
      if (!this.warnedNotConfigured) {
        this.warnedNotConfigured = true;
        this.log.info(
          'outbox.dispatch.skipped: канал записи в 1С не подключён (заглушка этапа C), строки не захватываются',
        );
      }
      return result;
    }
    const rows = await this.claim();
    result.claimed = rows.length;
    for (const row of rows) {
      let outcome: DispatchOutcome;
      if (!row.payloadIntact) {
        outcome = { kind: 'hash_mismatch', message: HASH_MISMATCH_MESSAGE };
      } else {
        try {
          outcome = await this.delivery.deliver(row);
        } catch (e) {
          outcome = { kind: 'transient', message: e instanceof Error ? e.message : String(e) };
        }
      }
      const applied = await this.apply(row, outcome);
      if (applied) result[applied]++;
    }
    if (rows.length > 0) this.log.info({ ...result }, 'outbox.dispatch.tick');
    return result;
  }

  /**
   * `outbox.unlock` (07 §8.2): `sending` с истёкшей арендой → обработка как временной ошибки
   * (07 §8.2 относит истечение аренды к временным): `pending` с backoff или `dead` по порогам.
   */
  async unlockExpired(): Promise<number> {
    const r = await this.pool.query<ClaimedRow>(
      `SELECT id, aggregate_type, aggregate_id, external_id, operation, payload, attempts, created_at
         FROM onec_outbox WHERE status = 'sending' AND lease_until < now() ORDER BY lease_until LIMIT 100`,
    );
    let n = 0;
    for (const row of r.rows) {
      if (
        await this.apply(
          toRow(row),
          { kind: 'transient', message: 'истекла аренда lease_until (worker не ответил)' },
          true,
        )
      )
        n++;
    }
    if (n > 0) this.log.warn({ count: n }, 'outbox.unlock: строки с истёкшей арендой возвращены');
    return n;
  }

  private async claim(): Promise<(OutboxRow & { readonly payloadIntact: boolean })[]> {
    const r = await this.pool.query<ClaimedRow>(
      `WITH picked AS (
         SELECT o.id FROM onec_outbox o
          WHERE o.status = 'pending' AND o.next_attempt_at <= now()
            AND (o.depends_on_outbox_id IS NULL
                 OR EXISTS (SELECT 1 FROM onec_outbox d WHERE d.id = o.depends_on_outbox_id AND d.status IN ('sent','confirmed')))
          ORDER BY o.priority, o.created_at
          LIMIT $2 FOR UPDATE SKIP LOCKED)
       UPDATE onec_outbox o SET status = 'sending', lease_until = now() + make_interval(secs => $3::double precision),
              locked_by = $1, attempts = attempts + 1, updated_at = now()
         FROM picked WHERE o.id = picked.id
       RETURNING o.id, o.aggregate_type, o.aggregate_id, o.external_id, o.operation, o.payload, o.payload_hash,
                 o.attempts, o.created_at,
                 -- Клиент-зависимость (SYNC-049): ссылки 1С для тела заказа нового POS-клиента в момент доставки.
                 (SELECT json_build_object('ref', coalesce(c.onec_ref, d.onec_ref)::text,
                                           'contractorRef', c.onec_counterparty_ref::text,
                                           'agreementRef', c.onec_agreement_ref::text)
                    FROM onec_outbox d LEFT JOIN customers c ON c.id = d.aggregate_id
                   WHERE d.id = o.depends_on_outbox_id AND d.aggregate_type = 'customer') AS dep_customer`,
      [this.workerId, this.cfg.batchSize, this.cfg.leaseMs / 1000],
    );
    return r.rows.map(toRow);
  }

  /** Переход по исходу; `expiredLease` — строка снимается с чужой (истёкшей) аренды. */
  private async apply(
    row: OutboxRow,
    outcome: DispatchOutcome,
    expiredLease = false,
  ): Promise<keyof Omit<TickResult, 'claimed'> | undefined> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const cur = await client.query<{ status: string; locked_by: string | null; attempts: number; age_ms: number }>(
        // Возраст для OUTBOX_MAX_AGE_HOURS (10 ORD-031; 16 §4.3): от создания задачи, после ручного повтора — от
        // момента последнего повтора (аудит `outbox.retried`, тот же момент, что `POST /sync/outbox/{id}/retry`).
        `SELECT o.status, o.locked_by, o.attempts,
                (extract(epoch FROM now() - GREATEST(o.created_at, COALESCE(
                   (SELECT max(a.occurred_at) FROM audit_logs a
                     WHERE a.entity_type = 'onec_outbox' AND a.entity_id = o.id
                       AND a.action = 'outbox.retried' AND a.result = 'ok'),
                   o.created_at))) * 1000)::float8 AS age_ms
           FROM onec_outbox o WHERE o.id = $1 FOR UPDATE OF o`,
        [row.id],
      );
      const c = cur.rows[0];
      const owned = c?.status === 'sending' && (expiredLease || c.locked_by === this.workerId);
      if (!c || !owned) {
        await client.query('ROLLBACK');
        this.log.warn(
          { outboxId: row.id, status: c?.status },
          'outbox.apply.skipped: строка уже не в аренде этого worker',
        );
        return undefined;
      }
      if (expiredLease) {
        const still = await client.query(`SELECT 1 FROM onec_outbox WHERE id = $1 AND lease_until < now()`, [row.id]);
        if (still.rowCount === 0) {
          await client.query('ROLLBACK');
          return undefined;
        }
      }
      const attempts = c.attempts;
      const tx = { executeSql: (text: string, values?: unknown[]) => client.query(text, values) };
      let kind: keyof Omit<TickResult, 'claimed'>;
      let dead: { code: SyncErrorCode; message: string; reason: string } | undefined;
      switch (outcome.kind) {
        case 'sent': {
          await client.query(
            `UPDATE onec_outbox SET status = 'sent', onec_ref = $2::uuid, onec_response = $3::jsonb, sent_at = now(),
                    lease_until = NULL, locked_by = NULL, last_error = NULL, last_error_code = NULL, updated_at = now()
              WHERE id = $1`,
            [row.id, outcome.onecRef, JSON.stringify(outcome.response ?? null)],
          );
          const payload: OnecConfirmedPayload = {
            outboxId: row.id,
            aggregateId: row.aggregateId,
            onecRef: outcome.onecRef,
            onecNumber: outcome.onecNumber ?? null,
            onecStatus: outcome.onecStatus ?? null,
            attempt: attempts,
          };
          await this.publisher.send(RESULT_QUEUES[row.aggregateType].confirmed, payload, { db: tx });
          kind = 'sent';
          break;
        }
        case 'rejected': {
          await client.query(
            `UPDATE onec_outbox SET status = 'failed', onec_response = $3::jsonb, last_error_code = 'ONEC_REJECTED',
                    last_error = $2, lease_until = NULL, locked_by = NULL, updated_at = now()
              WHERE id = $1`,
            [row.id, outcome.message.slice(0, 2000), JSON.stringify(outcome.response ?? null)],
          );
          await this.error(client, row, 'ONEC_REJECTED', outcome.message, { attempts });
          const payload: OnecFailedPayload = {
            outboxId: row.id,
            aggregateId: row.aggregateId,
            errorCode: 'ONEC_REJECTED',
            attempt: attempts,
          };
          await this.publisher.send(RESULT_QUEUES[row.aggregateType].failed, payload, { db: tx });
          kind = 'failed';
          break;
        }
        case 'hash_mismatch': {
          // 07 DATA-228: изменение payload после постановки → dead + sync_errors (HASH_MISMATCH); ручной повтор
          // (`requeue` с новым телом) пересчитывает хеш.
          await this.markDead(client, row, 'HASH_MISMATCH', outcome.message, { attempts, reason: 'hash_mismatch' });
          dead = { code: 'HASH_MISMATCH', message: outcome.message, reason: 'hash_mismatch' };
          kind = 'dead';
          break;
        }
        case 'fatal': {
          await this.markDead(client, row, 'OTHER', outcome.message, { attempts, reason: 'fatal' });
          dead = { code: 'OTHER', message: outcome.message, reason: 'fatal' };
          kind = 'dead';
          break;
        }
        case 'transient': {
          const reason = outboxDeadReason(attempts, c.age_ms, this.cfg);
          if (reason) {
            await this.markDead(client, row, 'ONEC_UNAVAILABLE', outcome.message, { attempts, reason });
            dead = { code: 'ONEC_UNAVAILABLE', message: outcome.message, reason };
            kind = 'dead';
          } else {
            const delayMs = outboxBackoffMs(attempts, this.cfg);
            await client.query(
              `UPDATE onec_outbox SET status = 'pending', next_attempt_at = now() + make_interval(secs => $2::double precision),
                      lease_until = NULL, locked_by = NULL, last_error_code = 'ONEC_UNAVAILABLE', last_error = $3,
                      updated_at = now()
                WHERE id = $1`,
              [row.id, delayMs / 1000, outcome.message.slice(0, 2000)],
            );
            this.log.warn(
              { outboxId: row.id, aggregateType: row.aggregateType, attempts, nextInMs: delayMs },
              'outbox.retry: временная ошибка 1С, повтор по графику backoff',
            );
            kind = 'retried';
          }
          break;
        }
      }
      await client.query('COMMIT');
      if (dead && this.hooks.onDead) {
        await this.hooks
          .onDead(row, dead)
          .catch((err: unknown) => this.log.error({ err, outboxId: row.id }, 'outbox.dead.hook_failed'));
      }
      return kind;
    } catch (e) {
      await client.query('ROLLBACK').catch(() => undefined);
      this.log.error({ err: e, outboxId: row.id }, 'outbox.apply.failed');
      return undefined;
    } finally {
      client.release();
    }
  }

  private async markDead(
    client: pg.PoolClient,
    row: OutboxRow,
    code: SyncErrorCode,
    message: string,
    details: Record<string, unknown>,
  ): Promise<void> {
    await client.query(
      `UPDATE onec_outbox SET status = 'dead', dead_at = now(), last_error_code = $2, last_error = $3,
              lease_until = NULL, locked_by = NULL, updated_at = now()
        WHERE id = $1`,
      [row.id, code, message.slice(0, 2000)],
    );
    await this.error(client, row, code, message, details);
    // Уведомление `sync_error` администратору и автору документа (07 §8.2) — модуль notifications (этап D/F);
    // до него — алерт уровнем error в журнале (мониторинг 16).
    this.log.error(
      { outboxId: row.id, aggregateType: row.aggregateType, aggregateId: row.aggregateId, code, ...details },
      'outbox.dead: элемент outbox переведён в dead (dead-letter), нужен ручной повтор',
    );
  }

  private async error(
    client: pg.PoolClient,
    row: OutboxRow,
    code: SyncErrorCode,
    message: string,
    details: Record<string, unknown>,
  ): Promise<void> {
    await writeSyncError(client, {
      entity: OUTBOX_ERROR_ENTITY[row.aggregateType],
      outboxId: row.id,
      errorCode: code,
      message,
      severity: 'error',
      payload: { aggregateType: row.aggregateType, operation: row.operation, ...details },
    });
  }
}

function toRow(r: ClaimedRow): OutboxRow & { readonly payloadIntact: boolean } {
  return {
    id: r.id,
    aggregateType: r.aggregate_type,
    aggregateId: r.aggregate_id,
    externalId: r.external_id,
    operation: r.operation,
    payload: r.payload,
    attempts: Number(r.attempts),
    createdAt: r.created_at,
    ...(r.dep_customer ? { dependencyCustomer: r.dep_customer } : {}),
    payloadIntact: outboxPayloadIntact(r.payload, r.payload_hash),
  };
}
