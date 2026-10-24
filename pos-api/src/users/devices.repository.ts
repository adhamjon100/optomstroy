import { Inject, Injectable } from '@nestjs/common';
import { and, desc, eq, isNull, sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { devices } from '../db/schema/index.js';
import type { DevicePlatform, DeviceRow } from './users.types.js';

export interface UpsertDeviceInput {
  readonly userId: string;
  /** `X-Device-Id` (UUID v4 в нижнем регистре — CHECK `devices_device_key_chk`). */
  readonly deviceKey: string;
  readonly platform: DevicePlatform;
  readonly model?: string | null;
  readonly osVersion?: string | null;
  readonly appVersion?: string | null;
  readonly displayName?: string | null;
  readonly lastIp?: string | null;
}

/**
 * `devices` (07 §5.8; ядро §18.2 п. 3): `device_key` — UUID клиента, UNIQUE в паре с `user_id`; PK `id` — UUID v7
 * (на него ссылается `sessions.device_id`).
 */
@Injectable()
export class DevicesRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async findById(id: string, ex: DbExecutor = this.db): Promise<DeviceRow | undefined> {
    const rows = await ex.select().from(devices).where(eq(devices.id, id)).limit(1);
    return rows[0];
  }

  async findByKey(userId: string, deviceKey: string, ex: DbExecutor = this.db): Promise<DeviceRow | undefined> {
    const rows = await ex
      .select()
      .from(devices)
      .where(and(eq(devices.userId, userId), eq(devices.deviceKey, deviceKey.toLowerCase())))
      .limit(1);
    return rows[0];
  }

  /**
   * Создаёт устройство или обновляет метаданные и `last_seen_at` существующего (вход по OTP на устройстве).
   * Повторный вход на ранее отозванном устройстве снимает отзыв (`revoked_at = NULL`) — новый вход подтверждён OTP.
   */
  async upsert(input: UpsertDeviceInput, ex: DbExecutor = this.db): Promise<DeviceRow> {
    const values = {
      userId: input.userId,
      deviceKey: input.deviceKey.toLowerCase(),
      platform: input.platform,
      model: input.model ?? null,
      osVersion: input.osVersion ?? null,
      appVersion: input.appVersion ?? null,
      displayName: input.displayName ?? null,
      lastIp: input.lastIp ?? null,
      lastSeenAt: sql`now()`,
    };
    const rows = await ex
      .insert(devices)
      .values(values)
      .onConflictDoUpdate({
        target: [devices.userId, devices.deviceKey],
        set: {
          platform: input.platform,
          model: sql`coalesce(excluded.model, ${devices.model})`,
          osVersion: sql`coalesce(excluded.os_version, ${devices.osVersion})`,
          appVersion: sql`coalesce(excluded.app_version, ${devices.appVersion})`,
          displayName: sql`coalesce(excluded.display_name, ${devices.displayName})`,
          lastIp: sql`coalesce(excluded.last_ip, ${devices.lastIp})`,
          lastSeenAt: sql`now()`,
          revokedAt: null,
          revokedByUserId: null,
          updatedAt: sql`now()`,
        },
      })
      .returning();
    const row = rows[0];
    if (!row) throw new Error('devices.upsert: INSERT не вернул строку');
    return row;
  }

  async listActive(userId: string, ex: DbExecutor = this.db): Promise<DeviceRow[]> {
    return ex
      .select()
      .from(devices)
      .where(and(eq(devices.userId, userId), isNull(devices.revokedAt)))
      .orderBy(desc(devices.lastSeenAt));
  }

  async revoke(id: string, revokedByUserId: string | null, ex: DbExecutor = this.db): Promise<boolean> {
    const rows = await ex
      .update(devices)
      .set({ revokedAt: sql`now()`, revokedByUserId, updatedAt: sql`now()` })
      .where(and(eq(devices.id, id), isNull(devices.revokedAt)))
      .returning({ id: devices.id });
    return rows.length === 1;
  }

  async touch(id: string, ip: string | null, ex: DbExecutor = this.db): Promise<void> {
    await ex
      .update(devices)
      .set({ lastSeenAt: sql`now()`, ...(ip ? { lastIp: ip } : {}), updatedAt: sql`now()` })
      .where(eq(devices.id, id));
  }

  async setBiometricEnrolled(id: string, at: Date | null, ex: DbExecutor = this.db): Promise<void> {
    await ex
      .update(devices)
      .set({ biometricEnrolledAt: at, updatedAt: sql`now()` })
      .where(eq(devices.id, id));
  }
}
