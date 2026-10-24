import { type SQL, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { IdempotencyExecutor } from '../../common/idempotency/idempotency.store.js';

/**
 * Позиционные запросы `$1…$n` поверх Drizzle-исполнителя (`DRIZZLE` или транзакция `db.transaction`): нужны там, где
 * фундамент принимает интерфейс клиента node-postgres (`IdempotencyService.recordInTransaction` — B-AR-04, pg-boss
 * `send(…, { db })` — задача в той же транзакции). Значения передаются параметрами (без интерполяции в текст).
 */
export function positionalSql(text: string, params: readonly unknown[] = []): SQL {
  const parts = text.split(/\$(\d+)/);
  const chunks: SQL[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 0) {
      if (parts[i] !== '') chunks.push(sql.raw(parts[i]));
    } else {
      const idx = Number(parts[i]) - 1; // money-double: allow — номер параметра запроса, не сумма
      chunks.push(sql`${params[idx]}`);
    }
  }
  return sql.join(chunks, sql.raw(''));
}

/** Клиент `{ query(text, params) }` для `IdempotencyService.recordInTransaction` в транзакции платежа. */
export function idempotencyExecutor(tx: DbExecutor): IdempotencyExecutor {
  return { query: (text: string, params?: unknown[]) => tx.execute(positionalSql(text, params ?? [])) };
}

/** Адаптер `db` pg-boss (`executeSql`) — публикация задачи в транзакции бизнес-операции. */
export function bossExecutor(tx: DbExecutor): {
  executeSql(text: string, values?: unknown[]): Promise<{ rows: unknown[] }>;
} {
  return {
    executeSql: async (text: string, values?: unknown[]) => {
      const r = await tx.execute(positionalSql(text, values ?? []));
      return { rows: r.rows };
    },
  };
}

/** Строки результата `tx.execute(sql…)` (node-postgres). */
export async function rows<T extends Record<string, unknown>>(tx: DbExecutor, query: SQL): Promise<T[]> {
  const r = await tx.execute<T>(query);
  return r.rows as unknown as T[];
}
