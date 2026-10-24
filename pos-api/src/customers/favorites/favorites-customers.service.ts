import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { PosDatabase } from '../../db/database.js';
import type { CustomerViewer } from '../common/customer-access.js';
import { CustomerCursorCodec, invalid, notFound } from '../common/customer-http.js';
import { projectCustomer } from '../common/customer-projector.js';
import { loadCustomerRows } from '../common/customer-rows.js';

/** Предел избранных клиентов пользователя (10 FAV-006, ядро §19.2: до 12 карточек; RM-G-011, T-FAV-005). */
export const FAVORITE_CUSTOMERS_MAX = 12;
export const FAVORITE_CUSTOMERS_LIMIT_DEFAULT = 50;
export const FAVORITE_CUSTOMERS_LIMIT_MAX = 200;
const CURSOR_SCOPE = 'favorites.customers:created_desc';

export interface FavoriteCustomersPage {
  readonly items: Record<string, unknown>[];
  readonly nextCursor: string | null;
  readonly hasMore: boolean;
  readonly count: number;
}

/**
 * Избранные клиенты (RM-G-004 — часть клиентов, RM-G-011; 08 §4.13.1–§4.13.2; 10 FAV-006, FAV-008; 07 §5.48
 * DATA-147): только собственный список пользователя (`user_id` — из токена, чужой список недоступен — IDOR);
 * `PUT` и `DELETE` идемпотентны по семантике (повтор → 204); клиент не существует (`deleted_at`) → 404. Не более 12
 * живых карточек: 13-я → `422 VALIDATION_FAILED` (rule `favorites_limit`; повтор уже добавленного — 204).
 * Сериализация — ролевой `Customer` без сумм долга (флаги `hasDebt`/`isOverdue`, ядро §22.13 п. 1). Клиенты,
 * помеченные на удаление в 1С, в список и счётчик не входят. В 1С не уходит (FAV-008). Аудит не пишется.
 */
@Injectable()
export class FavoritesCustomersService {
  constructor(
    @Inject(DRIZZLE) private readonly db: PosDatabase,
    private readonly cursors: CustomerCursorCodec,
  ) {}

  async list(v: CustomerViewer, q: { limit: number; cursor?: string }): Promise<FavoriteCustomersPage> {
    const after = this.cursors.decode(q.cursor, CURSOR_SCOPE);
    if (after && (typeof after[0] !== 'string' || typeof after[1] !== 'string')) {
      invalid('cursor', 'cursor', 'Курсор недействителен — запросите список заново.');
    }
    const keyset = after
      ? sql`AND (f.created_at, f.customer_id) < (${after[0] as string}::timestamptz, ${after[1] as string}::uuid)`
      : sql``;
    const [rows, total] = await Promise.all([
      this.db.execute<{ customer_id: string; ts: string }>(sql`
        SELECT f.customer_id, to_char(f.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS ts
          FROM favorites_customers f
          JOIN customers c ON c.id = f.customer_id AND c.deleted_at IS NULL AND NOT c.deletion_mark
         WHERE f.user_id = ${v.userId}::uuid ${keyset}
         ORDER BY f.created_at DESC, f.customer_id DESC
         LIMIT ${q.limit + 1}`),
      this.db.execute<{ n: number }>(sql`
        SELECT count(*)::int AS n FROM favorites_customers f
          JOIN customers c ON c.id = f.customer_id AND c.deleted_at IS NULL AND NOT c.deletion_mark
         WHERE f.user_id = ${v.userId}::uuid`),
    ]);
    const hasMore = rows.rows.length > q.limit;
    const page = rows.rows.slice(0, q.limit);
    const cards = await loadCustomerRows(
      this.db,
      page.map((r) => r.customer_id),
      v.userId,
    );
    const last = page.at(-1);
    return {
      items: cards.map((c) => projectCustomer(c, v.policy)),
      nextCursor: hasMore && last ? this.cursors.encode(CURSOR_SCOPE, [last.ts, last.customer_id]) : null,
      hasMore,
      count: Number(total.rows[0]?.n ?? 0), // money-double: allow — число карточек
    };
  }

  /** `PUT /favorites/customers/{id}`: добавить (уже есть → без изменений). */
  async add(v: CustomerViewer, customerId: string): Promise<void> {
    await this.db.transaction(async (tx) => {
      // Сериализация добавлений одного пользователя: предел 12 не обходится параллельными PUT.
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext(${`favorites_customers:${v.userId}`}))`);
      const c = await tx.execute<{ id: string }>(
        sql`SELECT id FROM customers WHERE id = ${customerId}::uuid AND deleted_at IS NULL`,
      );
      if (!c.rows[0]) notFound();
      const exists = await tx.execute<{ x: number }>(sql`
        SELECT 1 AS x FROM favorites_customers WHERE user_id = ${v.userId}::uuid AND customer_id = ${customerId}::uuid`);
      if (exists.rows[0]) return;
      const n = await tx.execute<{ n: number }>(sql`
        SELECT count(*)::int AS n FROM favorites_customers f
          JOIN customers c ON c.id = f.customer_id AND c.deleted_at IS NULL AND NOT c.deletion_mark
         WHERE f.user_id = ${v.userId}::uuid`);
      if (Number(n.rows[0]?.n ?? 0) >= FAVORITE_CUSTOMERS_MAX) {
        invalid('id', 'favorites_limit', `В избранном не более ${FAVORITE_CUSTOMERS_MAX} клиентов.`, 422);
      }
      await tx.execute(sql`
        INSERT INTO favorites_customers (user_id, customer_id) VALUES (${v.userId}::uuid, ${customerId}::uuid)
        ON CONFLICT (user_id, customer_id) DO NOTHING`);
    });
  }

  /** `DELETE /favorites/customers/{id}`: удалить (нет в избранном → без изменений). */
  async remove(v: CustomerViewer, customerId: string): Promise<void> {
    const c = await this.db.execute<{ id: string }>(
      sql`SELECT id FROM customers WHERE id = ${customerId}::uuid AND deleted_at IS NULL`,
    );
    if (!c.rows[0]) notFound();
    await this.db.execute(
      sql`DELETE FROM favorites_customers WHERE user_id = ${v.userId}::uuid AND customer_id = ${customerId}::uuid`,
    );
  }
}
