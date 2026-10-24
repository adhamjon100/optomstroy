import { Inject, Injectable } from '@nestjs/common';
import { and, eq, gt, lt } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { tokenDenylist } from '../db/schema/index.js';
import type { DeniedTokenKind, DenyReason } from './users.types.js';

export interface DenyTokenInput {
  readonly jti: string;
  readonly tokenKind: DeniedTokenKind;
  readonly expiresAt: Date;
  readonly reason: DenyReason;
  readonly sessionId?: string | null;
}

/**
 * `token_denylist` (07 §5.10; ядро §17.3, §18.2 п. 6): отзыв `jti` access/step-up до `exp` (logout, отзыв сессии,
 * смена ролей) и одноразовость `registration_token` (`reason='used'`, только `token_kind='registration'` — CHECK).
 * После записи вызывающий также сообщает AuthStateCache.denyJti() — отзыв действует в процессе сразу.
 */
@Injectable()
export class TokenDenylistRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  /**
   * Добавляет `jti`. Возвращает true, если запись создана этим вызовом; false — `jti` уже в списке
   * (для `registration_token` это и есть проверка одноразовости: второй вызов → REGISTRATION_TOKEN_INVALID).
   */
  async add(input: DenyTokenInput, ex: DbExecutor = this.db): Promise<boolean> {
    const rows = await ex
      .insert(tokenDenylist)
      .values({
        jti: input.jti,
        tokenKind: input.tokenKind,
        expiresAt: input.expiresAt,
        reason: input.reason,
        sessionId: input.sessionId ?? null,
      })
      .onConflictDoNothing({ target: tokenDenylist.jti })
      .returning({ jti: tokenDenylist.jti });
    return rows.length === 1;
  }

  /** `jti` отозван и запись ещё действует (`expires_at > now`). */
  async isDenied(jti: string, now: Date = new Date(), ex: DbExecutor = this.db): Promise<boolean> {
    const rows = await ex
      .select({ jti: tokenDenylist.jti })
      .from(tokenDenylist)
      .where(and(eq(tokenDenylist.jti, jti), gt(tokenDenylist.expiresAt, now)))
      .limit(1);
    return rows.length === 1;
  }

  /** Очистка истёкших записей (токен после `exp` и так отвергается подписью). */
  async purgeExpired(now: Date = new Date(), ex: DbExecutor = this.db): Promise<number> {
    const rows = await ex
      .delete(tokenDenylist)
      .where(lt(tokenDenylist.expiresAt, now))
      .returning({ jti: tokenDenylist.jti });
    return rows.length;
  }
}
