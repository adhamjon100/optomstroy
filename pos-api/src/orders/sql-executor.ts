import { type SQL, sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import type { IdempotencyExecutor } from '../common/idempotency/idempotency.store.js';

/**
 * Позиционные запросы `$1…$n` поверх Drizzle-исполнителя — для фундамента, который принимает клиент node-postgres
 * (`IdempotencyService.recordInTransaction`, B-AR-04): итог `POST /orders` пишется в транзакции заказа.
 */
function positionalSql(text: string, params: readonly unknown[]): SQL {
  const parts = text.split(/\$(\d+)/);
  const chunks: SQL[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 0) {
      if (parts[i] !== '') chunks.push(sql.raw(parts[i]));
    } else {
      chunks.push(sql`${params[Number(parts[i]) - 1]}`); // money-double: allow — номер параметра запроса
    }
  }
  return sql.join(chunks, sql.raw(''));
}

export function idempotencyExecutor(tx: DbExecutor): IdempotencyExecutor {
  return { query: (text: string, params?: unknown[]) => tx.execute(positionalSql(text, params ?? [])) };
}
