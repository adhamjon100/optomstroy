import type {
  IdempotencyExecutor,
  IdempotencyScope,
  IdempotencyStore,
  StoredIdempotencyRecord,
} from './idempotency.store.js';

/** In-memory реализация IdempotencyStore — для unit-тестов модулей (не для продакшена: нет межпроцессной блокировки). */
export class InMemoryIdempotencyStore implements IdempotencyStore {
  private readonly rows = new Map<string, StoredIdempotencyRecord & { resourceId: string | null }>();
  /** Число следующих вызовов complete(), которые завершатся ошибкой (имитация сбоя БД в тестах). */
  failNextCompletes = 0;
  /** Число вызовов complete() и последний executor (тесты B-AR-04). */
  completeCalls = 0;
  lastExecutor: IdempotencyExecutor | undefined;

  constructor(private readonly now: () => number = Date.now) {}

  private id(s: IdempotencyScope): string {
    return `${s.key}\u0000${s.subjectKey}\u0000${s.route}`;
  }

  acquire(scope: IdempotencyScope, requestHash: Buffer, ttlMs: number): Promise<StoredIdempotencyRecord | null> {
    const id = this.id(scope);
    const existing = this.rows.get(id);
    if (existing && existing.expiresAt.getTime() > this.now()) return Promise.resolve(existing);
    this.rows.set(id, {
      requestHash,
      status: 'in_progress',
      responseStatus: null,
      responseBody: null,
      expiresAt: new Date(this.now() + ttlMs),
      resourceId: null,
    });
    return Promise.resolve(null);
  }

  complete(
    scope: IdempotencyScope,
    responseStatus: number,
    responseBody: unknown,
    resourceId?: string | null,
    executor?: IdempotencyExecutor,
  ): Promise<void> {
    this.completeCalls++;
    this.lastExecutor = executor;
    if (this.failNextCompletes > 0) {
      this.failNextCompletes--;
      return Promise.reject(new Error('complete failed (simulated)'));
    }
    const id = this.id(scope);
    const row = this.rows.get(id);
    if (row) {
      // JSON-раунд как у jsonb: сохраняется сериализуемое представление тела.
      const body: unknown = JSON.parse(JSON.stringify(responseBody ?? null));
      this.rows.set(id, {
        ...row,
        status: 'completed',
        responseStatus,
        responseBody: body,
        resourceId: resourceId ?? null,
      });
    }
    return Promise.resolve();
  }

  release(scope: IdempotencyScope): Promise<void> {
    const id = this.id(scope);
    if (this.rows.get(id)?.status === 'in_progress') this.rows.delete(id);
    return Promise.resolve();
  }

  purgeExpired(): Promise<number> {
    let n = 0;
    for (const [id, row] of this.rows) {
      if (row.expiresAt.getTime() <= this.now()) {
        this.rows.delete(id);
        n++;
      }
    }
    return Promise.resolve(n);
  }

  /** Статус строки (для тестов). */
  statusOf(scope: IdempotencyScope): StoredIdempotencyRecord['status'] | undefined {
    return this.rows.get(this.id(scope))?.status;
  }

  size(): number {
    return this.rows.size;
  }
}
