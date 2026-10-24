import type pg from 'pg';
import type { PgBoss } from 'pg-boss';
import { type CatalogChangedPayload, QUEUES } from '../../common/jobs/contracts/queues.js';

/**
 * Варианты, у которых синхронизация изменила цену или остаток (05 SYNC-070; 06 §5.2 «Предупреждения», §7.5) — копятся
 * в `ApplyScope.catalogChanges` при записи реплик `prices` / `stock_balances` и публикуются **в транзакции применения**
 * задачами `catalog.prices-changed` / `catalog.stock-changed` (обработчик — модуль `cart`: флаги строк корзин и
 * уведомления `cart_price_changed` / `cart_stock_changed`). Ревью F-trace-3, FQ-INT-02.
 */
export interface CatalogChangeSink {
  readonly prices: Set<string>;
  readonly stock: Set<string>;
}

export function newCatalogChangeSink(): CatalogChangeSink {
  return { prices: new Set(), stock: new Set() };
}

export interface CatalogChangePublisher {
  /** Публикация в транзакции `client` (до COMMIT); сбой публикации не откатывает применение реплики. */
  publish(client: pg.PoolClient, changes: CatalogChangeSink): Promise<void>;
}

/** Вариантов в одной задаче (обработчик корзин выбирает строки по `variant_id = ANY(...)`). */
export const CATALOG_CHANGED_CHUNK = 1000;

interface PublisherLog {
  warn(obj: object, msg?: string): void;
}

/**
 * Публикатор поверх pg-boss процесса-исполнителя синхронизации. Экземпляр pg-boss появляется при старте
 * `WorkerRuntime` — `attach(boss)` (до него публикация пропускается: корзины всё равно перепроверяют цены и остатки
 * при открытии и в `checkout-preview`). Задача пишется через `db` клиента транзакции под SAVEPOINT: нет очереди или
 * иной сбой — откат только SAVEPOINT и запись в журнал.
 */
export class PgBossCatalogChangePublisher implements CatalogChangePublisher {
  private boss: PgBoss | undefined;

  constructor(private readonly log: PublisherLog) {}

  attach(boss: PgBoss): void {
    this.boss = boss;
  }

  async publish(client: pg.PoolClient, changes: CatalogChangeSink): Promise<void> {
    const boss = this.boss;
    if (!boss) return;
    const kinds: readonly ['prices' | 'stock', string][] = [
      ['prices', QUEUES.catalogPricesChanged],
      ['stock', QUEUES.catalogStockChanged],
    ];
    for (const [kind, queue] of kinds) {
      const ids = [...changes[kind]];
      for (let i = 0; i < ids.length; i += CATALOG_CHANGED_CHUNK) {
        const payload: CatalogChangedPayload = { variantIds: ids.slice(i, i + CATALOG_CHANGED_CHUNK) };
        await client.query('SAVEPOINT catalog_changed');
        try {
          await boss.send(queue, payload, {
            db: {
              executeSql: async (text: string, values?: unknown[]) => {
                const r = await client.query(text, values);
                return { rows: r.rows };
              },
            },
          });
          await client.query('RELEASE SAVEPOINT catalog_changed');
        } catch (err) {
          await client.query('ROLLBACK TO SAVEPOINT catalog_changed');
          this.log.warn({ err, queue, variants: payload.variantIds.length }, 'sync.catalog_changed.publish_failed');
        }
      }
    }
  }
}

/** Опубликовать накопленные изменения (если есть публикатор и изменения). */
export async function publishCatalogChanges(
  publisher: CatalogChangePublisher | undefined,
  client: pg.PoolClient,
  changes: CatalogChangeSink | undefined,
): Promise<void> {
  if (!publisher || !changes || (changes.prices.size === 0 && changes.stock.size === 0)) return;
  await publisher.publish(client, changes);
}
