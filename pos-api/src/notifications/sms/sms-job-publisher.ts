import { sql } from 'drizzle-orm';
import { type Db, fromDrizzle, type PgBoss, type SendOptions } from 'pg-boss';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { SMS_QUEUE_OPTIONS } from './sms-queues.js';

/**
 * Публикация заданий SMS в pg-boss (D-44). `sms.send` ставится **в той же транзакции**, что `sms_outbox`
 * (и `otp_challenges` у вызывающего): 06 §4.5.3, §7.5 — опция `db` pg-boss поверх исполнителя Drizzle.
 */
export interface SmsJobOptions {
  readonly startAfterSeconds?: number;
  readonly singletonKey?: string;
}

export interface SmsJobPublisher {
  publish(queue: string, data: object, options?: SmsJobOptions, executor?: DbExecutor): Promise<string | null>;
}

export const SMS_JOB_PUBLISHER = 'SmsJobPublisher' as const;

/** `Db` pg-boss поверх исполнителя Drizzle (клиент или транзакция): штатный адаптер `fromDrizzle` pg-boss 12. */
export function drizzleBossDb(executor: DbExecutor): Db {
  return fromDrizzle(executor, sql);
}

/** Публикатор поверх экземпляра pg-boss процесса (API: PgBossService.instance; worker: WorkerRuntime.boss). */
export class PgBossSmsJobPublisher implements SmsJobPublisher {
  private readonly ensured = new Set<string>();

  constructor(private readonly boss: () => PgBoss | undefined) {}

  async publish(
    queue: string,
    data: object,
    options: SmsJobOptions = {},
    executor?: DbExecutor,
  ): Promise<string | null> {
    const boss = this.boss();
    if (!boss) throw new Error('pg-boss не запущен: задание SMS не поставлено');
    await this.ensureQueue(boss, queue);
    const send: SendOptions = {
      ...(options.startAfterSeconds !== undefined ? { startAfter: options.startAfterSeconds } : {}),
      ...(options.singletonKey ? { singletonKey: options.singletonKey } : {}),
      ...(executor ? { db: drizzleBossDb(executor) } : {}),
    };
    return boss.send(queue, data, send);
  }

  private async ensureQueue(boss: PgBoss, queue: string): Promise<void> {
    if (this.ensured.has(queue)) return;
    if (!(await boss.getQueue(queue))) await boss.createQueue(queue, SMS_QUEUE_OPTIONS[queue] ?? {});
    this.ensured.add(queue);
  }
}
