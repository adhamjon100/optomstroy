/**
 * Хранилище ключей идемпотентности — таблица `idempotency_keys` (07 §5.56, DDL 0001_init.sql; 08 §2.7).
 * Скоуп — `(key, subject_key, route)`: `subject_key` = `user:<users.id>` для аутентифицированных запросов или
 * `reg:<sha256(jti registration_token)>` для публичного `POST /registration/complete` (B-AR-01).
 */
export const IDEMPOTENCY_STORE = Symbol('IDEMPOTENCY_STORE');

/** Срок хранения ключа — 24 ч (08 §2.7 «Хранение»). */
export const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;

export interface IdempotencyScope {
  readonly key: string;
  readonly subjectKey: string;
  /** `users.id` для `user:` (CHECK idempotency_keys_subject_user_chk), `null` для `reg:`. */
  readonly userId: string | null;
  /** `METHOD /шаблон/пути` (без префикса /api/v1, параметры как `{}`). */
  readonly route: string;
}

/** Минимальный интерфейс клиента PostgreSQL (pg.Pool / pg.PoolClient в транзакции). */
export interface IdempotencyExecutor {
  query(sql: string, params?: unknown[]): Promise<unknown>;
}

/** Предел повторов `acquire` при гонке «строку освободили между INSERT и SELECT» (ревью C-MN-08). */
export const IDEMPOTENCY_ACQUIRE_MAX_ATTEMPTS = 5;

export interface StoredIdempotencyRecord {
  readonly requestHash: Buffer;
  readonly status: 'in_progress' | 'completed';
  readonly responseStatus: number | null;
  readonly responseBody: unknown;
  readonly expiresAt: Date;
}

export interface IdempotencyStore {
  /**
   * Атомарно захватывает ключ: вставляет строку `in_progress` или заменяет просроченную. Возвращает `null`,
   * если ключ захвачен этим вызовом, иначе — действующую запись другого запроса.
   */
  acquire(scope: IdempotencyScope, requestHash: Buffer, ttlMs: number): Promise<StoredIdempotencyRecord | null>;
  /**
   * Сохраняет итог (`completed`, статус, тело) для повтора. `executor` — клиент открытой транзакции бизнес-операции
   * (B-AR-04: итог фиксируется атомарно с побочным эффектом); без него — отдельная команда пула.
   */
  complete(
    scope: IdempotencyScope,
    responseStatus: number,
    responseBody: unknown,
    resourceId?: string | null,
    executor?: IdempotencyExecutor,
  ): Promise<void>;
  /** Снимает захват (сбой до результата, 5xx/401/403/429): повтор с тем же ключом выполнится заново. */
  release(scope: IdempotencyScope): Promise<void>;
  /** Очистка просроченных ключей (job ежечасно, 08 §2.7). Возвращает число удалённых строк. */
  purgeExpired(): Promise<number>;
}
