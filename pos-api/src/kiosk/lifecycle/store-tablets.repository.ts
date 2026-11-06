import { Inject, Injectable } from '@nestjs/common';
import { and, eq, sql, type SQL } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { storeTablets, users } from '../../db/schema/index.js';
import type { UserRow } from '../../users/users.types.js';
import type { StoreTabletStatus, StoreTabletView } from './store-tablets.dto.js';

/** Строка `store_tablets` (07 §5.65; Drizzle-схема src/db/schema/auth.ts). */
export type StoreTabletRow = typeof storeTablets.$inferSelect;

export interface NewStoreTablet {
  /** `store_tablets.id` задаётся заранее: он входит в хэш аварийного кода (`pepper ‖ код ‖ tablet_id`, SEC-140). */
  readonly id: string;
  readonly userId: string;
  readonly deviceId: string;
  readonly exitCodeHash: string;
  readonly exitCodePepperVersion: number;
  readonly enrolledByUserId: string;
  readonly enrolledAt: Date;
}

interface RawView {
  id: string;
  user_id: string;
  name: string | null;
  warehouse_id: string | null;
  status: StoreTabletStatus;
  enrolled_at: Date | string;
  reconnected_at: Date | string | null;
  revoked_at: Date | string | null;
  last_seen_at: Date | string | null;
  lock_task_enabled: boolean | null;
  last_app_version: string | null;
  expires_at: Date | string | null;
  [k: string]: unknown;
}

const toDate = (v: Date | string | null): Date | null => (v === null ? null : v instanceof Date ? v : new Date(v));

/**
 * Данные планшетов магазина (07 §5.65; 08 §4.18.11–§4.18.14; ADR-115): `store_tablets`, технический пользователь
 * `users.kind='kiosk'` (без телефона — `users_kiosk_phone_chk`), проекция `StoreTablet` (имя и склад —
 * `user_profiles`, срок — действующая сессия). Профиль, роль, устройство и сессии — репозитории src/users и
 * SessionIssuer модуля auth; здесь — то, чего там нет. Правила (кто, когда, аудит) — StoreTabletsService.
 */
@Injectable()
export class StoreTabletsRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  /** Список SCR-54 (08 §4.18.12): фильтр `status`, порядок — по имени, затем `id`. */
  list(status: StoreTabletStatus | undefined, now: Date, ex: DbExecutor = this.db): Promise<StoreTabletView[]> {
    return this.select(status ? sql`st.status = ${status}` : sql`TRUE`, now, ex);
  }

  async view(id: string, now: Date, ex: DbExecutor = this.db): Promise<StoreTabletView | undefined> {
    return (await this.select(sql`st.id = ${id}::uuid`, now, ex))[0];
  }

  /**
   * Проекция `StoreTablet`: `expiresAt` — абсолютный срок действующей сессии технического пользователя
   * (`max(sessions.expires_at)` не отозванных и не истёкших на `now` — как `KioskAlertsService.activeTablets`);
   * `lastSeenAt`, `lockTaskEnabled`, `appVersion` — столбцы, которые пишет `KioskPresenceService` (WP-S5).
   */
  private async select(where: SQL, now: Date, ex: DbExecutor): Promise<StoreTabletView[]> {
    const res = await ex.execute<RawView>(sql`
      SELECT st.id, st.user_id, p.full_name AS name, p.home_warehouse_id AS warehouse_id, st.status, st.enrolled_at,
             st.reconnected_at, st.revoked_at, st.last_seen_at, st.lock_task_enabled, st.last_app_version,
             (SELECT max(s.expires_at) FROM sessions s
               WHERE s.user_id = st.user_id AND s.revoked_at IS NULL
                 AND s.expires_at > ${now.toISOString()}::timestamptz) AS expires_at
        FROM store_tablets st
        LEFT JOIN user_profiles p ON p.user_id = st.user_id
       WHERE ${where}
       ORDER BY p.full_name NULLS LAST, st.id`);
    return res.rows.map((r) => ({
      id: r.id,
      userId: r.user_id,
      name: r.name,
      warehouseId: r.warehouse_id,
      status: r.status,
      enrolledAt: toDate(r.enrolled_at) ?? new Date(0),
      reconnectedAt: toDate(r.reconnected_at),
      revokedAt: toDate(r.revoked_at),
      lastSeenAt: toDate(r.last_seen_at),
      lockTaskEnabled: r.lock_task_enabled,
      appVersion: r.last_app_version,
      expiresAt: toDate(r.expires_at),
    }));
  }

  /**
   * Строка планшета под `FOR UPDATE` (сериализация изменения, отключения, подключения заново, повтора подключения и
   * аварийного выхода одного планшета; порядок блокировок — строка планшета, затем его сессии).
   */
  async lock(id: string, ex: DbExecutor): Promise<StoreTabletRow | undefined> {
    const rows = await ex.select().from(storeTablets).where(eq(storeTablets.id, id)).limit(1).for('update');
    return rows[0];
  }

  /** Склад существует и действует (`is_active`, без пометки удаления) — как склад корзины планшета (cart.repository). */
  async isActiveWarehouse(id: string, ex: DbExecutor = this.db): Promise<boolean> {
    const res = await ex.execute<{ id: string }>(
      sql`SELECT w.id FROM warehouses w WHERE w.id = ${id}::uuid AND w.is_active AND NOT w.deletion_mark`,
    );
    return res.rows.length === 1;
  }

  /**
   * Технический пользователь планшета (07 §5.1, DATA-300; 11 SEC-136 п. 6): `kind='kiosk'`, без телефона, статус
   * `active` задаётся явно (значение по умолчанию — `pending`, AuthGuard его не пропускает). Создаётся только здесь.
   */
  async insertKioskUser(ex: DbExecutor): Promise<UserRow> {
    const rows = await ex.insert(users).values({ phoneE164: null, kind: 'kiosk', status: 'active' }).returning();
    const row = rows[0];
    if (!row) throw new Error('store_tablets: INSERT users не вернул строку');
    return row;
  }

  /** Строка подключённого планшета: `active`, хэш нового кода, `lock_task_enabled = NULL` (07 §5.65). */
  async insert(t: NewStoreTablet, ex: DbExecutor): Promise<StoreTabletRow> {
    const rows = await ex
      .insert(storeTablets)
      .values({
        id: t.id,
        userId: t.userId,
        deviceId: t.deviceId,
        status: 'active',
        exitCodeHash: t.exitCodeHash,
        exitCodePepperVersion: t.exitCodePepperVersion,
        enrolledByUserId: t.enrolledByUserId,
        enrolledAt: t.enrolledAt,
        lockTaskEnabled: null,
      })
      .returning();
    const row = rows[0];
    if (!row) throw new Error('store_tablets: INSERT не вернул строку');
    return row;
  }

  /**
   * Отключение администратором (07 §5.65): `revoked`, момент, администратор, `revoke_reason` — имя события аудита
   * `kiosk.revoked`. Только из `active`; `false` — строка уже отключена.
   */
  async markRevoked(id: string, byUserId: string, at: Date, ex: DbExecutor): Promise<boolean> {
    const rows = await ex
      .update(storeTablets)
      .set({
        status: 'revoked',
        revokedAt: at,
        revokedByUserId: byUserId,
        revokeReason: 'kiosk.revoked',
        updatedAt: at,
      })
      .where(and(eq(storeTablets.id, id), eq(storeTablets.status, 'active')))
      .returning({ id: storeTablets.id });
    return rows.length === 1;
  }

  /**
   * Подключение заново (07 §5.65 «Жизненный цикл»; 08 §4.18.15; 09 §8.9 п. 6) — из `active` и из `revoked`, та же
   * строка и тот же технический пользователь: `active`, поля отключения (`revoked_*`, `revoke_reason`) → NULL,
   * `device_id` — строка `devices` текущего `device_key`, новый хэш кода (`exit_code_used_at`, попытки и пауза
   * сбрасываются), `lock_task_enabled = NULL` (закрепление включается после получения токенов, ADR-115 п. 26),
   * `reconnected_at` / `reconnected_by_user_id`.
   */
  async markReconnected(
    id: string,
    r: {
      readonly deviceId: string;
      readonly exitCodeHash: string;
      readonly pepperVersion: number;
      readonly byUserId: string;
      readonly at: Date;
    },
    ex: DbExecutor,
  ): Promise<void> {
    await ex
      .update(storeTablets)
      .set({
        status: 'active',
        deviceId: r.deviceId,
        exitCodeHash: r.exitCodeHash,
        exitCodePepperVersion: r.pepperVersion,
        exitCodeUsedAt: null,
        exitFailedAttempts: 0,
        exitLockedUntil: null,
        lockTaskEnabled: null,
        reconnectedAt: r.at,
        reconnectedByUserId: r.byUserId,
        revokedAt: null,
        revokedByUserId: null,
        revokeReason: null,
        updatedAt: r.at,
      })
      .where(eq(storeTablets.id, id));
  }

  /**
   * Неверный аварийный код `POST /kiosk/exit` (07 §5.65; 11 SEC-140): счётчик неверных попыток подряд и пауза
   * (`lockedUntil` — после 5-й, иначе NULL). Счётчик в БД переживает рестарт и общий для реплик.
   */
  async recordExitFailure(
    id: string,
    attempts: number,
    lockedUntil: Date | null,
    at: Date,
    ex: DbExecutor,
  ): Promise<void> {
    await ex
      .update(storeTablets)
      .set({ exitFailedAttempts: attempts, exitLockedUntil: lockedUntil, updatedAt: at })
      .where(eq(storeTablets.id, id));
  }

  /**
   * Аварийный выход со связью (07 §5.65; 08 §4.25.5): код погашен (`exit_code_used_at` — одноразовый), попытки и
   * пауза сброшены, строка → `revoked` без администратора (`revoked_by_user_id = NULL`), `revoke_reason` — имя
   * события аудита `kiosk.exit_code_used`. Только из `active`; `false` — строка уже отключена.
   */
  async markExitUsed(id: string, at: Date, ex: DbExecutor): Promise<boolean> {
    const rows = await ex
      .update(storeTablets)
      .set({
        status: 'revoked',
        exitCodeUsedAt: at,
        exitFailedAttempts: 0,
        exitLockedUntil: null,
        revokedAt: at,
        revokedByUserId: null,
        revokeReason: 'kiosk.exit_code_used',
        updatedAt: at,
      })
      .where(and(eq(storeTablets.id, id), eq(storeTablets.status, 'active')))
      .returning({ id: storeTablets.id });
    return rows.length === 1;
  }

  /**
   * Новый аварийный код (SEC-140: новый код делает прежний недействительным): хэш и версия pepper заменяются,
   * `exit_code_used_at`, `exit_failed_attempts`, `exit_locked_until` сбрасываются (07 §5.65).
   */
  async replaceExitCode(
    id: string,
    exitCodeHash: string,
    pepperVersion: number,
    at: Date,
    ex: DbExecutor,
  ): Promise<void> {
    await ex
      .update(storeTablets)
      .set({
        exitCodeHash,
        exitCodePepperVersion: pepperVersion,
        exitCodeUsedAt: null,
        exitFailedAttempts: 0,
        exitLockedUntil: null,
        updatedAt: at,
      })
      .where(eq(storeTablets.id, id));
  }
}
