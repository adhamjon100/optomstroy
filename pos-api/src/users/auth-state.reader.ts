import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import type { AuthSnapshot, AuthSnapshotQuery, AuthStateReader, UserStatus } from '../common/auth/auth-state.js';
import { DRIZZLE } from '../common/db/database.module.js';

type Row = {
  user_status: UserStatus | null;
  user_kind: 'staff' | 'customer' | null;
  permissions_version: number | null;
  session_user_id: string | null;
  session_revoked_at: Date | string | null;
  session_expires_at: Date | string | null;
  device_key: string | null;
  jti_denied: boolean;
};

const toDate = (v: Date | string): Date => (v instanceof Date ? v : new Date(v));

/**
 * Реализация порта `AUTH_STATE_READER` (common/auth) одним запросом: пользователь, сессия `sid` с `device_key`
 * её устройства, действующая запись `jti` в `token_denylist`. Кэш 60 с — в AuthStateCache.
 */
@Injectable()
export class PgAuthStateReader implements AuthStateReader {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async snapshot(q: AuthSnapshotQuery): Promise<AuthSnapshot> {
    const res = await this.db.execute<Row>(sql`
      SELECT u.status AS user_status, u.kind AS user_kind, u.permissions_version,
             s.user_id AS session_user_id, s.revoked_at AS session_revoked_at, s.expires_at AS session_expires_at,
             d.device_key,
             EXISTS (SELECT 1 FROM token_denylist t WHERE t.jti = ${q.jti}::uuid AND t.expires_at > now()) AS jti_denied
        FROM (SELECT 1) one
        LEFT JOIN users u ON u.id = ${q.userId}::uuid
        LEFT JOIN sessions s ON s.id = ${q.sessionId}::uuid
        LEFT JOIN devices d ON d.id = s.device_id`);
    const r = res.rows[0];
    if (!r) return { user: null, session: null, jtiDenied: false };
    return {
      user:
        r.user_status !== null && r.user_kind !== null && r.permissions_version !== null
          ? { status: r.user_status, kind: r.user_kind, permissionsVersion: Number(r.permissions_version) }
          : null,
      session:
        r.session_user_id !== null && r.session_expires_at !== null
          ? {
              userId: r.session_user_id,
              revokedAt: r.session_revoked_at === null ? null : toDate(r.session_revoked_at),
              expiresAt: toDate(r.session_expires_at),
              deviceKey: r.device_key,
            }
          : null,
      jtiDenied: r.jti_denied === true,
    };
  }
}
