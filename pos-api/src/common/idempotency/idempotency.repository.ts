import { Inject, Injectable } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../db/database.module.js';
import {
  IDEMPOTENCY_ACQUIRE_MAX_ATTEMPTS,
  type IdempotencyExecutor,
  type IdempotencyScope,
  type IdempotencyStore,
  type StoredIdempotencyRecord,
} from './idempotency.store.js';

interface Row {
  request_hash: Buffer;
  status: 'in_progress' | 'completed';
  response_status: number | null;
  response_body: unknown;
  expires_at: Date;
}

/**
 * Репозиторий `idempotency_keys` на PostgreSQL (SQL без ORM: Drizzle-схема таблиц — RM-C-006).
 * Захват атомарен: `INSERT … ON CONFLICT DO UPDATE … WHERE expires_at <= now()` — просроченная строка
 * переиспользуется, действующая остаётся неизменной и читается вторым запросом.
 */
@Injectable()
export class PgIdempotencyStore implements IdempotencyStore {
  constructor(@Inject(PG_POOL) private readonly db: Pick<pg.Pool, 'query'>) {}

  async acquire(scope: IdempotencyScope, requestHash: Buffer, ttlMs: number): Promise<StoredIdempotencyRecord | null> {
    // Повтор — только при гонке «строку освободили между INSERT и SELECT»; число попыток ограничено (C-MN-08).
    for (let attempt = 1; attempt <= IDEMPOTENCY_ACQUIRE_MAX_ATTEMPTS; attempt++) {
      const result = await this.tryAcquire(scope, requestHash, ttlMs);
      if (result !== 'retry') return result;
    }
    throw new Error(`idempotency acquire: строка исчезала ${IDEMPOTENCY_ACQUIRE_MAX_ATTEMPTS} раз подряд`);
  }

  private async tryAcquire(
    scope: IdempotencyScope,
    requestHash: Buffer,
    ttlMs: number,
  ): Promise<StoredIdempotencyRecord | null | 'retry'> {
    const ins = await this.db.query(
      `INSERT INTO idempotency_keys (key, subject_key, user_id, route, request_hash, status, expires_at)
       VALUES ($1, $2, $3, $4, $5, 'in_progress', now() + make_interval(secs => $6::double precision / 1000))
       ON CONFLICT (key, subject_key, route) DO UPDATE
         SET request_hash = EXCLUDED.request_hash,
             user_id = EXCLUDED.user_id,
             status = 'in_progress',
             response_status = NULL,
             response_body = NULL,
             resource_id = NULL,
             expires_at = EXCLUDED.expires_at,
             created_at = now()
         WHERE idempotency_keys.expires_at <= now()`,
      [scope.key, scope.subjectKey, scope.userId, scope.route, requestHash, ttlMs],
    );
    if (ins.rowCount === 1) return null;
    const sel = await this.db.query<Row>(
      `SELECT request_hash, status, response_status, response_body, expires_at
         FROM idempotency_keys WHERE key = $1 AND subject_key = $2 AND route = $3`,
      [scope.key, scope.subjectKey, scope.route],
    );
    const row = sel.rows[0];
    // Строку освободили между INSERT и SELECT — пробуем захватить ещё раз (вызывающий ограничивает попытки).
    if (!row) return 'retry';
    return {
      requestHash: row.request_hash,
      status: row.status,
      responseStatus: row.response_status,
      responseBody: row.response_body,
      expiresAt: row.expires_at,
    };
  }

  async complete(
    scope: IdempotencyScope,
    responseStatus: number,
    responseBody: unknown,
    resourceId?: string | null,
    executor?: IdempotencyExecutor,
  ): Promise<void> {
    await (executor ?? this.db).query(
      `UPDATE idempotency_keys
          SET status = 'completed', response_status = $4, response_body = $5::jsonb, resource_id = $6
        WHERE key = $1 AND subject_key = $2 AND route = $3`,
      [
        scope.key,
        scope.subjectKey,
        scope.route,
        responseStatus,
        JSON.stringify(responseBody ?? null),
        resourceId ?? null,
      ],
    );
  }

  async release(scope: IdempotencyScope): Promise<void> {
    await this.db.query(
      `DELETE FROM idempotency_keys WHERE key = $1 AND subject_key = $2 AND route = $3 AND status = 'in_progress'`,
      [scope.key, scope.subjectKey, scope.route],
    );
  }

  async purgeExpired(): Promise<number> {
    const res = await this.db.query(`DELETE FROM idempotency_keys WHERE expires_at <= now()`);
    return res.rowCount ?? 0;
  }
}
