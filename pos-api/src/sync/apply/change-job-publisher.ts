import type pg from 'pg';
import type { PgBoss } from 'pg-boss';

/**
 * Публикация задачи модулю-владельцу агрегата **в транзакции сообщения** плана обмена (06 §7.4 п. (б), §7.5;
 * ядро §22.8): задача пишется в таблицу pg-boss через соединение транзакции, поэтому видна обработчику только после
 * COMMIT сообщения, а при ROLLBACK исчезает вместе с ним. Сбой публикации — исключение: сообщение откатывается, ack
 * не уходит, и следующий цикл получит то же сообщение (регистрация в 1С не снимается без применения элемента).
 */
export interface ChangeJobPublisher {
  publish(
    client: pg.PoolClient,
    queue: string,
    payload: object,
    options?: { readonly singletonKey?: string },
  ): Promise<void>;
}

/** Публикатор недоступен (pg-boss процесса не подключён): применять элемент некуда — сообщение не подтверждается. */
export class ChangeJobPublisherUnavailableError extends Error {
  override readonly name = 'ChangeJobPublisherUnavailableError';
}

/**
 * Публикатор поверх pg-boss процесса-исполнителя синхронизации (pos-worker): экземпляр появляется при старте
 * `WorkerRuntime` (`attach`). До подключения публикация невозможна — `ChangeJobPublisherUnavailableError`.
 */
export class PgBossChangeJobPublisher implements ChangeJobPublisher {
  private boss: PgBoss | undefined;

  constructor(private readonly prepare?: (boss: PgBoss) => Promise<void>) {}

  /** Подключить pg-boss; `prepare` создаёт нужные очереди (идемпотентно). */
  async attach(boss: PgBoss): Promise<void> {
    if (this.prepare) await this.prepare(boss);
    this.boss = boss;
  }

  get attached(): boolean {
    return this.boss !== undefined;
  }

  async publish(
    client: pg.PoolClient,
    queue: string,
    payload: object,
    options: { readonly singletonKey?: string } = {},
  ): Promise<void> {
    const boss = this.boss;
    if (!boss) {
      throw new ChangeJobPublisherUnavailableError(
        `onec.changes: pg-boss не подключён — задача ${queue} не опубликована, сообщение не подтверждается`,
      );
    }
    await boss.send(queue, payload, {
      ...(options.singletonKey ? { singletonKey: options.singletonKey } : {}),
      db: {
        executeSql: async (text: string, values?: unknown[]) => {
          const r = await client.query(text, values);
          return { rows: r.rows };
        },
      },
    });
  }
}
