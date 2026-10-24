import { Inject, Injectable } from '@nestjs/common';
import { CLOCK, type Clock } from './clock.js';

/**
 * Состояние субъекта для проверки access-токена (09 §8.1 «Проверка на сервере»; 08 §2.2): статус и
 * `permissions_version` пользователя, сессия `sid`, отзыв `jti`. Порт реализует src/users (`PgAuthStateReader`) —
 * common/auth не зависит от модулей данных (06 §7.4, MOD-022).
 */
export type UserStatus = 'pending' | 'pending_activation' | 'active' | 'blocked' | 'deleted';

export interface AuthUserState {
  readonly status: UserStatus;
  readonly kind: 'staff' | 'customer';
  readonly permissionsVersion: number;
}

export interface AuthSessionState {
  readonly userId: string;
  readonly revokedAt: Date | null;
  readonly expiresAt: Date;
  /** `devices.device_key` устройства сессии (= `X-Device-Id`, claim `deviceId`). */
  readonly deviceKey: string | null;
}

export interface AuthSnapshot {
  readonly user: AuthUserState | null;
  readonly session: AuthSessionState | null;
  readonly jtiDenied: boolean;
}

export interface AuthSnapshotQuery {
  readonly userId: string;
  readonly sessionId: string;
  readonly jti: string;
}

export interface AuthStateReader {
  snapshot(q: AuthSnapshotQuery): Promise<AuthSnapshot>;
}

export const AUTH_STATE_READER = Symbol('AUTH_STATE_READER');

/** Кэш проверки `permissionsVersion` и `sid` — 60 с (09 §8.1, §8.7; 08 §2.2: окно ≤ 60 с — остаточный риск ASVS 8.3.2). */
export const AUTH_STATE_CACHE_TTL_MS = 60_000;
export const AUTH_STATE_CACHE_MAX_ENTRIES = 10_000;

interface Entry {
  readonly snapshot: AuthSnapshot;
  readonly loadedAt: number;
  readonly userId: string;
  readonly sessionId: string;
}

/**
 * Кэш снимков по `jti` (TTL 60 с) + локальный denylist `jti` (09 §8.6: «in-memory + таблица для реплик»).
 * Модули sessions/admin после logout, отзыва сессии, смены ролей, блокировки вызывают `invalidate*`/`denyJti`,
 * чтобы изменение действовало в этом процессе сразу, а не через 60 с.
 */
@Injectable()
export class AuthStateCache {
  private readonly entries = new Map<string, Entry>();
  private readonly deniedJti = new Map<string, number>();
  private readonly inflight = new Map<string, Promise<AuthSnapshot>>();
  /** Поколение инвалидаций: снимок, загруженный до invalidate*, в кэш не кладётся (гонка «загрузка ↔ отзыв»). */
  private generation = 0;

  constructor(
    @Inject(AUTH_STATE_READER) private readonly reader: AuthStateReader,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {}

  async snapshot(q: AuthSnapshotQuery): Promise<AuthSnapshot> {
    const now = this.clock.now().getTime();
    const deniedUntil = this.deniedJti.get(q.jti);
    if (deniedUntil !== undefined) {
      if (deniedUntil > now) {
        const cached = this.entries.get(q.jti)?.snapshot;
        return { user: cached?.user ?? null, session: cached?.session ?? null, jtiDenied: true };
      }
      this.deniedJti.delete(q.jti);
    }
    const hit = this.entries.get(q.jti);
    if (
      hit &&
      now - hit.loadedAt < AUTH_STATE_CACHE_TTL_MS &&
      hit.userId === q.userId &&
      hit.sessionId === q.sessionId
    ) {
      return hit.snapshot;
    }
    const pending = this.inflight.get(q.jti);
    if (pending) return pending;
    const gen = this.generation;
    const p = this.reader
      .snapshot(q)
      .then((snapshot) => {
        if (gen === this.generation) this.store(q, snapshot, this.clock.now().getTime());
        return snapshot;
      })
      .finally(() => this.inflight.delete(q.jti));
    this.inflight.set(q.jti, p);
    return p;
  }

  /** Сброс снимков пользователя (смена ролей/прав, блокировка, logout-all). */
  invalidateUser(userId: string): void {
    this.generation += 1;
    for (const [jti, e] of this.entries) if (e.userId === userId) this.entries.delete(jti);
  }

  /** Сброс снимков сессии (logout, отзыв сессии). */
  invalidateSession(sessionId: string): void {
    this.generation += 1;
    for (const [jti, e] of this.entries) if (e.sessionId === sessionId) this.entries.delete(jti);
  }

  /** Локальный отзыв `jti` до `expiresAt` (запись в token_denylist выполняет вызывающий в своей транзакции). */
  denyJti(jti: string, expiresAt: Date): void {
    this.deniedJti.set(jti, expiresAt.getTime());
    if (this.deniedJti.size > AUTH_STATE_CACHE_MAX_ENTRIES) {
      const now = this.clock.now().getTime();
      for (const [k, until] of this.deniedJti) if (until <= now) this.deniedJti.delete(k);
    }
  }

  clear(): void {
    this.generation += 1;
    this.entries.clear();
    this.deniedJti.clear();
  }

  private store(q: AuthSnapshotQuery, snapshot: AuthSnapshot, at: number): void {
    if (this.entries.size >= AUTH_STATE_CACHE_MAX_ENTRIES) {
      const oldest = this.entries.keys().next();
      if (!oldest.done) this.entries.delete(oldest.value);
    }
    this.entries.set(q.jti, { snapshot, loadedAt: at, userId: q.userId, sessionId: q.sessionId });
  }
}
